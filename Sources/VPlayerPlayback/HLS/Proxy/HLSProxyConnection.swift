// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Network

final class HLSProxyIOCounters: @unchecked Sendable {
    struct Snapshot: Sendable {
        var callbackBytes = 0, peakCallbackBytes = 0, largestCallback = 0
        var pendingSendAliases = 0, peakPendingSendAliases = 0, rejectedOversizedCallbacks = 0
    }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    func beginCallback(_ bytes: Int) { lock.withLock {
        value.callbackBytes += bytes; value.peakCallbackBytes = max(value.peakCallbackBytes, value.callbackBytes)
        value.largestCallback = max(value.largestCallback, bytes)
        if bytes > HLSProxyBudget.transferBufferBytes { value.rejectedOversizedCallbacks += 1 }
    } }
    func endCallback(_ bytes: Int) { lock.withLock { value.callbackBytes -= bytes } }
    func beginSend(_ bytes: Int) { lock.withLock {
        value.pendingSendAliases += bytes; value.peakPendingSendAliases = max(value.peakPendingSendAliases, value.pendingSendAliases)
    } }
    func endSend(_ bytes: Int) { lock.withLock { value.pendingSendAliases -= bytes } }
}

final class HLSProxyConnection: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    let io: HLSProxyIOCounters
    private let lease: HLSProxyBudget.Lease
    private let lock = NSLock()
    private let nativeSends = DispatchGroup()
    private var queue: DispatchQueue?
    private var work: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, any Error>?
    private var stopped: CheckedContinuation<Void, Never>?
    private var readyState = false, cancelled = false, cancelRequested = false, responseStarted = false
    private var upstream: HLSProxyUpstream?
    private var timeout: DispatchSourceTimer?

    init(connection: NWConnection, lease: HLSProxyBudget.Lease, io: HLSProxyIOCounters) {
        self.connection = connection; self.lease = lease; self.io = io
    }
    func start(queue: DispatchQueue, operation: @escaping @Sendable () async -> Void) {
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] in self?.stateChanged($0) }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30); timer.setEventHandler { [weak self] in self?.cancel() }
        lock.withLock { timeout = timer; work = Task { await operation() } }
        timer.resume()
    }
    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in readyState = true; defer { ready = nil }; return ready }
            pending?.resume()
        case .failed: connection.cancel()
        case .cancelled:
            let pending = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, CheckedContinuation<Void, Never>?) in
                cancelled = true; defer { ready = nil; stopped = nil }; return (ready, stopped)
            }
            pending.0?.resume(throwing: CancellationError()); pending.1?.resume()
        default: break
        }
    }
    func awaitReady(port: UInt16) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let state = lock.withLock { () -> Int in
                if cancelled { return -1 }; if readyState { return 1 }; ready = continuation; return 0
            }
            if state == 1 { continuation.resume() }
            if state == -1 { continuation.resume(throwing: CancellationError()) }
        }
        guard let local = connection.currentPath?.localEndpoint, let remote = connection.currentPath?.remoteEndpoint,
              LoopbackEndpointValidator.accepts(listener: .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: NWEndpoint.Port(rawValue: port)!),
                local: local, remote: remote, expectedPort: port) else { throw HLSSourceError.invalidURL }
    }
    func readRequest() async throws -> LoopbackHTTPRequest {
        var parser = LoopbackRequestParser()
        while true {
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1_024) { data, _, complete, error in
                    if error != nil || (complete && data?.isEmpty != false) { continuation.resume(throwing: HLSSourceError.network) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            touch()
            if let request = try parser.append(bytes) { return request }
            try Task.checkCancellation()
        }
    }
    private func touch() { lock.withLock { timeout?.schedule(deadline: .now() + 30) } }
    func sendBytes(_ bytes: Data) async throws {
        nativeSends.enter(); io.beginSend(bytes.count)
        let count = bytes.count
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { [nativeSends, io] error in
                io.endSend(count); nativeSends.leave()
                if error != nil { continuation.resume(throwing: HLSSourceError.network) } else { continuation.resume() }
            })
        }
        withExtendedLifetime(bytes) {}; touch()
    }
    private func claimResponse() throws {
        guard lock.withLock({ () -> Bool in guard !responseStarted else { return false }; responseStarted = true; return true }) else {
            throw HLSSourceError.network
        }
    }
    func beginResponse(_ header: Data) async throws { try claimResponse(); try await sendBytes(header) }
    func sendStatus(_ status: Int) async throws {
        try await beginResponse(Data("HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8))
    }
    func send(body: Data, method: LoopbackHTTPRequest.Method, contentType: String, range: String?) async throws {
        let selected = try range.map { try HTTPRange.parse($0, resourceLength: body.count) } ?? .ignoreAndServeFull
        let interval: Range<Int>, status: Int, rangeHeader: String
        switch selected {
        case .unsatisfied:
            try await beginResponse(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(body.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        case let .single(value):
            interval = value; status = 206; rangeHeader = "Content-Range: bytes \(value.lowerBound)-\(value.upperBound - 1)/\(body.count)\r\n"
        case .ignoreAndServeFull: interval = 0..<body.count; status = 200; rangeHeader = ""
        }
        try await beginResponse(Data("HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(interval.count)\r\n\(rangeHeader)Cache-Control: no-store\r\nConnection: close\r\n\r\n".utf8))
        guard method != .head else { return }
        try await sendSlice(body, interval: interval)
    }
    private func sendSlice(_ body: Data, interval: Range<Int>) async throws {
        var offset = interval.lowerBound
        while offset < interval.upperBound {
            try Task.checkCancellation()
            let end = min(offset + 32 * 1_024, interval.upperBound)
            try await sendBytes(body.subdata(in: offset..<end)); offset = end
        }
    }
    func send(protectedBody body: HLSProxyProtectedBody, method: LoopbackHTTPRequest.Method, range: String?) async throws {
        guard let admitted = body.range else {
            try await send(body: body.data, method: method, contentType: "application/octet-stream", range: range); return
        }
        guard let extent = body.contentRange, extent.start == admitted.offset, extent.length == admitted.length,
              admitted.offset >= 0, admitted.length > 0, admitted.offset <= Int64.max - admitted.length,
              Int64(body.data.count) == admitted.length else { throw HLSSourceError.incompleteEvidence }
        let end = admitted.offset + admitted.length
        let total = extent.total.map(String.init) ?? "*"
        if method == .head && range == nil {
            let length = extent.total.map { "Content-Length: \($0)\r\n" } ?? ""
            try await beginResponse(Data("HTTP/1.1 200 OK\r\n\(length)Content-Type: application/octet-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)); return
        }
        guard let range else { throw HLSSourceError.unsupportedMedia }
        let selected: Range<Int>
        if let length = extent.total, let whole = Int(exactly: length) {
            switch try HTTPRange.parse(range, resourceLength: whole) {
            case let .single(value): selected = value
            case .unsatisfied:
                try await beginResponse(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
            case .ignoreAndServeFull: throw HLSSourceError.unsupportedMedia
            }
        } else {
            guard range == "bytes=\(admitted.offset)-\(end - 1)", let lower = Int(exactly: admitted.offset), let upper = Int(exactly: end) else { throw HLSSourceError.unsupportedMedia }
            selected = lower..<upper
        }
        guard Int64(selected.lowerBound) >= admitted.offset, Int64(selected.upperBound) <= end else { throw HLSSourceError.unsupportedMedia }
        try await beginResponse(Data("HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Length: \(selected.count)\r\nContent-Range: bytes \(selected.lowerBound)-\(selected.upperBound - 1)/\(total)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8))
        guard method != .head else { return }
        try await sendSlice(body.data, interval: (selected.lowerBound - Int(admitted.offset))..<(selected.upperBound - Int(admitted.offset)))
    }
    /// Only called by the private serial URLSession delegate queue. One callback
    /// alias stays blocked until this native send returns; there is no task queue.
    func sendBlocking(_ bytes: Data, header: Bool = false) throws {
        if header { try claimResponse() }
        let gate = HLSProxySendGate()
        nativeSends.enter(); io.beginSend(bytes.count)
        let count = bytes.count
        connection.send(content: bytes, completion: .contentProcessed { [nativeSends, io] error in
            io.endSend(count); nativeSends.leave(); gate.complete(error == nil)
        })
        guard gate.wait() else { connection.cancel(); throw HLSSourceError.network }
        withExtendedLifetime(bytes) {}; touch()
    }
    func installUpstream(_ value: HLSProxyUpstream?) {
        let cancel = lock.withLock { () -> Bool in upstream = value; return cancelRequested }
        if cancel { value?.cancel() }
    }
    func cancel() {
        let pending = lock.withLock { () -> (Task<Void, Never>?, HLSProxyUpstream?) in
            cancelRequested = true; return (work, upstream)
        }
        pending.0?.cancel(); pending.1?.cancel(); connection.cancel()
    }
    func joinWork() async { let task = lock.withLock { work }; await task?.value }
    func closeAndJoin() async {
        let operation = lock.withLock { () -> HLSProxyUpstream? in
            timeout?.cancel(); timeout = nil; defer { upstream = nil }; return upstream
        }
        operation?.cancel(); connection.cancel()
        await withCheckedContinuation { continuation in
            let finished = lock.withLock { () -> Bool in if cancelled { return true }; stopped = continuation; return false }
            if finished { continuation.resume() }
        }
        await withCheckedContinuation { continuation in nativeSends.notify(queue: .global()) { continuation.resume() } }
        if let queue { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
        connection.stateUpdateHandler = nil
    }
}

private final class HLSProxySendGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Bool?
    func complete(_ success: Bool) {
        let first = lock.withLock { () -> Bool in guard result == nil else { return false }; result = success; return true }
        if first { semaphore.signal() }
    }
    func wait() -> Bool { semaphore.wait(timeout: .now() + 30) == .success && lock.withLock { result == true } }
}
