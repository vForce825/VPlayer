// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Network
@testable import VPlayerPlayback

/// Bounded ordinary loopback origin for real AVPlayer/FFmpeg transport tests.
/// Every accepted connection and send callback is joined by close().
final class NativeHLSHTTPFixture: @unchecked Sendable {
    struct Resource: Sendable {
        let data: Data
        let contentType: String
        var repetitions: Int = 1
        // Ordinary interrupted-response regression: keep the declared length,
        // then close after this many body bytes. Nil preserves normal delivery.
        var disconnectAfterBodyBytes: Int?
        var rangeErrorBody = Data()
        var omitContentLength = false
        var withholdResponse = false
        var withholdBody = false
        var chunkBytes = 32 * 1_024
        var chunkDelay: TimeInterval = 0
        var pauseAfterBodyBytes: Int?
        var length: Int { data.count * repetitions }
        var isValid: Bool {
            !data.isEmpty && data.count <= 8 * 1_024 * 1_024 && (1...64).contains(repetitions) &&
                (disconnectAfterBodyBytes.map { (0...length).contains($0) } ?? true) &&
                rangeErrorBody.count <= 64 * 1_024 && (1...32 * 1_024).contains(chunkBytes) && (0...1).contains(chunkDelay) &&
                (pauseAfterBodyBytes.map { (1..<length).contains($0) } ?? true)
        }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.vplayer.tests.native-hls-origin")
    private let lock = NSLock()
    private let connections = DispatchGroup(), callbacks = DispatchGroup()
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var pausedBodies: [ObjectIdentifier: @Sendable () -> Void] = [:]
    private var resources: [String: Resource]
    private let credential: String?
    private var closed = false
    private var listenerDone = false
    private var listenerWaiter: CheckedContinuation<Void, Never>?
    private var requestCountValue = 0, authenticatedCountValue = 0, deniedCountValue = 0, completedHeadersValue = 0
    let baseURL: URL
    var requestCount: Int { lock.withLock { requestCountValue } }
    var completedHeaders: Int { lock.withLock { completedHeadersValue } }
    var pausedBodyCount: Int { lock.withLock { pausedBodies.count } }
    func resumePausedBodies() {
        let pending = lock.withLock { let values = Array(pausedBodies.values); pausedBodies.removeAll(); return values }
        for operation in pending { queue.async(execute: operation) }
    }
    var authenticatedCount: Int { lock.withLock { authenticatedCountValue } }
    var deniedCount: Int { lock.withLock { deniedCountValue } }

    init(resources: [String: Resource], credential: String? = nil) throws {
        guard resources.count <= 32, resources.values.allSatisfy(\.isValid) else {
            throw HLSSourceError.byteLimit
        }
        self.resources = resources; self.credential = credential
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        listener = try NWListener(using: parameters)
        let gate = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed, .cancelled: gate.signal(); default: break }
        }
        // Network.framework fails startup when no connection handler exists.
        // No URL has escaped yet; reject early connections until all fixture
        // state is initialized and the ordinary serving handler is installed.
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        guard gate.wait(timeout: .now() + 5) == .success,
              case .ready = listener.state,
              let port = listener.port, port.rawValue > 0 else {
            listener.cancel()
            throw HLSSourceError.network
        }
        baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")!
        listener.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.listenerStopped() }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    }
    func url(_ path: String) -> URL { URL(string: path, relativeTo: baseURL)!.absoluteURL }
    func replace(_ path: String, resource: Resource) {
        precondition(resource.isValid)
        lock.withLock { precondition(resources[path] != nil); resources[path] = resource }
    }
    private func listenerStopped() {
        let waiter = lock.withLock { listenerDone = true; defer { listenerWaiter = nil }; return listenerWaiter }
        waiter?.resume()
    }
    private func accept(_ connection: NWConnection) {
        let admitted = lock.withLock { () -> Bool in
            guard !closed, clients.count < 16 else { return false }
            connections.enter(); clients[ObjectIdentifier(connection)] = connection; return true
        }
        guard admitted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .cancelled = state {
                let removed = self.lock.withLock { self.clients.removeValue(forKey: ObjectIdentifier(connection)) != nil }
                if removed { self.connections.leave() }
                connection.stateUpdateHandler = nil
            }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, parser: LoopbackRequestParser())
    }
    private func receive(_ connection: NWConnection, parser: LoopbackRequestParser) {
        callbacks.enter()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1_024) { [self] data, _, complete, error in
            defer { callbacks.leave() }
            guard error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            do {
                var parser = parser
                guard let request = try parser.append(data) else {
                    if complete { connection.cancel() } else { receive(connection, parser: parser) }
                    return
                }
                serve(request, connection: connection)
            } catch { connection.cancel() }
        }
    }
    private func serve(_ request: LoopbackHTTPRequest, connection: NWConnection) {
        let path = String(request.target.prefix { $0 != "?" })
        let result = lock.withLock { () -> (Resource?, Bool) in
            requestCountValue += 1
            let valid = credential == nil || request.values(forHeader: "Authorization") == [credential!]
            if valid { authenticatedCountValue += 1 } else { deniedCountValue += 1 }
            return (resources[path], valid)
        }
        guard result.1 else { sendHeader("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", connection: connection); return }
        guard let resource = result.0 else { sendHeader("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", connection: connection); return }
        guard !resource.withholdResponse else { return }
        do {
            let parsed = try request.values(forHeader: "Range").first.map { try HTTPRange.parse($0, resourceLength: resource.length) } ?? .ignoreAndServeFull
            let range: Range<Int>, status: Int, extra: String
            switch parsed {
            case .ignoreAndServeFull: range = 0..<resource.length; status = 200; extra = ""
            case let .single(value): range = value; status = 206; extra = "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(resource.length)\r\n"
            case .unsatisfied:
                sendHeader("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(resource.length)\r\n" +
                    "Content-Length: \(resource.rangeErrorBody.count)\r\nConnection: close\r\n\r\n",
                    connection: connection, body: request.method == .head ? Data() : resource.rangeErrorBody)
                return
            }
            let length = resource.omitContentLength ? "" : "Content-Length: \(range.count)\r\n"
            let header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(resource.contentType)\r\n\(length)\(extra)Accept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            callbacks.enter()
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [self] error in
                defer { callbacks.leave() }
                guard error == nil, request.method != .head else { connection.cancel(); return }
                lock.withLock { completedHeadersValue += 1 }
                guard !resource.withholdBody else { return }
                let transmitted = resource.disconnectAfterBodyBytes.map {
                    range.lowerBound..<(range.lowerBound + min($0, range.count))
                } ?? range
                send(resource, range: transmitted, connection: connection)
            })
        } catch { connection.cancel() }
    }
    private func sendHeader(_ header: String, connection: NWConnection, body: Data = Data()) {
        callbacks.enter()
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [self] _ in callbacks.leave(); connection.cancel() })
    }
    private func send(_ resource: Resource, range: Range<Int>, connection: NWConnection, didPause: Bool = false) {
        guard !range.isEmpty else { connection.cancel(); return }
        if !didPause, let stop = resource.pauseAfterBodyBytes, range.lowerBound >= stop {
            lock.withLock {
                guard !closed else { return }
                precondition(pausedBodies.count < 16)
                pausedBodies[ObjectIdentifier(connection)] = { [self] in
                    send(resource, range: range, connection: connection, didPause: true)
                }
            }
            return
        }
        let offset = range.lowerBound % resource.data.count
        let untilPause = !didPause ? resource.pauseAfterBodyBytes.map { $0 - range.lowerBound } ?? range.count : range.count
        let count = min(resource.chunkBytes, range.count, resource.data.count - offset, untilPause)
        callbacks.enter()
        let transmit: @Sendable () -> Void = { [self] in
            connection.send(content: resource.data.subdata(in: offset..<(offset + count)), completion: .contentProcessed { [self] error in
                defer { callbacks.leave() }
                guard error == nil else { connection.cancel(); return }
                send(resource, range: (range.lowerBound + count)..<range.upperBound, connection: connection, didPause: didPause)
            })
        }
        if resource.chunkDelay > 0 { queue.asyncAfter(deadline: .now() + resource.chunkDelay, execute: transmit) }
        else { transmit() }
    }
    func close() async {
        let current = lock.withLock { closed = true; pausedBodies.removeAll(); return Array(clients.values) }
        listener.cancel(); current.forEach { $0.cancel() }
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in if listenerDone { return true }; listenerWaiter = continuation; return false }
            if done { continuation.resume() }
        }
        await withCheckedContinuation { continuation in connections.notify(queue: queue) { continuation.resume() } }
        await withCheckedContinuation { continuation in callbacks.notify(queue: queue) { continuation.resume() } }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
