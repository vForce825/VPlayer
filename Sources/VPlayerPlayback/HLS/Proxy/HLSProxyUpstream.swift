// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// One AsyncBytes consumer owns one prepaid fixed window. URLSession's internal
/// buffering is opaque: this bounds app-owned payload, not SDK buffers or RSS.
/// https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:)
final class HLSProxyUpstream: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let resource: HLSProxyResourceRegistry.Resource
    private let method: LoopbackHTTPRequest.Method
    private let range: String?
    private let connection: HLSProxyConnection
    private let transfer: HLSProxyBudget.Lease
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var consumer: Task<Void, any Error>?
    private var started = false, stopping = false
    private var failure: (any Error)?
    private let invalidation = HLSProxyInvalidationJoin()
    // Only the private serial URLSession delegate queue touches redirects.
    private var redirects: Set<URL> = []

    init(resource: HLSProxyResourceRegistry.Resource, method: LoopbackHTTPRequest.Method, range: String?,
         connection: HLSProxyConnection, transfer: HLSProxyBudget.Lease) {
        self.resource = resource; self.method = method; self.range = range; self.connection = connection; self.transfer = transfer
    }
    var upstreamReceivedBytes: Int64 { lock.withLock { task?.countOfBytesReceived ?? 0 } }
    func run() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let consumer = try lock.withLock { () -> Task<Void, any Error> in
                guard !stopping else { throw CancellationError() }
                guard !started else { throw HLSSourceError.network }
                started = true
                let value = Task { try await self.consume() }
                self.consumer = value; return value
            }
            defer { lock.withLock { self.consumer = nil; task = nil } }
            // Cancellation requests alone never stand in for the consumer join.
            try await consumer.value
        } onCancel: { self.cancel() }
    }
    func cancel() {
        let pending = lock.withLock { () -> (Task<Void, any Error>?, URLSessionTask?) in
            stopping = true
            if failure == nil { failure = CancellationError() }
            return (consumer, task)
        }
        pending.0?.cancel(); pending.1?.cancel(); connection.connection.cancel()
    }
    private func consume() async throws {
        // This happens before URLSession creates/resumes its underlying task.
        let envelope = try transfer.reserveBodyEnvelope()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        redirects.insert(resource.url)
        let result: Result<Void, any Error>
        do {
            try Task.checkCancellation()
            try await stream(session: session, envelope: envelope)
            try Task.checkCancellation()
            result = .success(())
        } catch { result = .failure(lock.withLock { failure } ?? error) }
        let upstream = lock.withLock { stopping = true; return task }
        if case .failure = result { upstream?.cancel() }
        // Task cancellation is allowed while suspended. Unlike immediate
        // invalidateAndCancel notification, this waits for task/delegate drain.
        // The AsyncBytes iterator has already left stream() before this join.
        session.finishTasksAndInvalidate()
        await waitForInvalidation()
        withExtendedLifetime(envelope) {}
        try result.get()
    }
    private func stream(session: URLSession, envelope: HLSProxyBudget.BodyEnvelope) async throws {
        let pipe = HLSProxyBudget.BytePipe(envelope: envelope)
        connection.io.beginReadWindow(pipe.window.capacity)
        defer { connection.io.endReadWindow(pipe.window.capacity) }
        let (bytes, response) = try await session.bytes(for: request(resource.url), delegate: self)
        let upstream = bytes.task
        let accepted = lock.withLock { () -> Bool in task = upstream; return !stopping }
        guard accepted else { upstream.cancel(); throw CancellationError() }
        try Task.checkCancellation()
        let head = try responseHead(response)
        upstream.suspend(); connection.io.suspendReader()
        do { try await connection.beginResponse(head.bytes) }
        catch { connection.io.resumeReader(); throw error }
        connection.io.resumeReader()
        try Task.checkCancellation(); upstream.resume()
        if method == .head {
            var iterator = bytes.makeAsyncIterator()
            guard try await iterator.next() == nil else { throw HLSSourceError.network }
            return
        }
        // Exactly one reader task for the transfer, never one task per byte or
        // span. Cancellation-handler registration also covers an already
        // cancelled consumer racing this child task's installation.
        let reader = Task { await self.read(bytes, into: pipe, upstream: upstream) }
        try await withTaskCancellationHandler {
            let result: Result<Void, any Error>
            do {
                var received: Int64 = 0
                while let span = try await pipe.nextSpan(at: UInt64(received)) {
                    try Task.checkCancellation()
                    let next = received.addingReportingOverflow(Int64(span.count))
                    guard !next.overflow, head.expected.map({ next.partialValue <= $0 }) ?? true else { throw HLSSourceError.network }
                    connection.io.observeBody(upstream: upstream.countOfBytesReceived, delivered: received)
                    if head.chunked { try await connection.sendBytes(Data("\(String(span.count, radix: 16))\r\n".utf8)) }
                    try await pipe.window.send(offset: span.offset, count: span.count, to: connection)
                    if head.chunked { try await connection.sendBytes(Data("\r\n".utf8)) }
                    received = next.partialValue
                    // Data's final backing alias and native callback tail have
                    // both ended. Only now may the producer reuse these cells.
                    pipe.releaseThrough(UInt64(received))
                    connection.io.deliveredSpan(span.count)
                    connection.io.observeBody(upstream: upstream.countOfBytesReceived, delivered: received)
                }
                try Task.checkCancellation()
                guard head.expected.map({ received == $0 }) ?? true else { throw HLSSourceError.network }
                if head.chunked { try await connection.sendBytes(Data("0\r\n\r\n".utf8)) }
                result = .success(())
            } catch {
                pipe.abort(error); reader.cancel(); upstream.cancel(); connection.connection.cancel()
                result = .failure(error)
            }
            await reader.value
            try result.get()
        } onCancel: {
            pipe.abort(CancellationError()); reader.cancel(); upstream.cancel(); self.connection.connection.cancel()
        }
    }
    private func read(_ bytes: URLSession.AsyncBytes, into pipe: HLSProxyBudget.BytePipe,
                      upstream: URLSessionDataTask) async {
        var awaitingFirstByte = false
        defer { if awaitingFirstByte { connection.io.endAwaitFirstByte() } }
        do {
            var iterator = bytes.makeAsyncIterator()
            var position: UInt64 = 0
            while true {
                try Task.checkCancellation()
                if pipe.isFull(at: position) {
                    upstream.suspend(); connection.io.suspendReader()
                    do { try await pipe.waitForSpace(at: position) }
                    catch { connection.io.resumeReader(); throw error }
                    connection.io.resumeReader()
                    try Task.checkCancellation(); upstream.resume()
                }
                if position == 0 { connection.io.beginAwaitFirstByte(); awaitingFirstByte = true }
                let next = try await iterator.next()
                if awaitingFirstByte { connection.io.endAwaitFirstByte(); awaitingFirstByte = false }
                guard let byte = next else { break }
                try Task.checkCancellation()
                try pipe.publish(byte, at: position)
                // publish rejects Int64.max before increment: neither cursor
                // wraps, and downstream cumulative-length arithmetic is checked.
                position += 1
            }
            pipe.finish(.success(()))
        } catch { pipe.finish(.failure(error)) }
    }
    private func request(_ url: URL) throws -> URLRequest {
        _ = try PlaybackSourceOrigin(url)
        guard url.absoluteString.utf8.count <= 8_192 else { throw HLSSourceError.byteLimit }
        var request = URLRequest(url: url)
        request.httpMethod = method == .head ? "HEAD" : "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        for (name, value) in resource.source.context.headers.fields(for: url) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }
    private func responseHead(_ response: URLResponse) throws -> (bytes: Data, expected: Int64?, chunked: Bool) {
        guard let http = response as? HTTPURLResponse else { throw HLSSourceError.network }
        if [401, 403].contains(http.statusCode) { throw HLSSourceError.unauthorized }
        guard [200, 206, 416].contains(http.statusCode) else { throw HLSSourceError.network }
        try HLSProxyHTTP.validateEncoding(http.value(forHTTPHeaderField: "Content-Encoding"))
        var rangeHeader = ""
        let expected: Int64?
        if http.statusCode == 206 {
            guard let range, let value = http.value(forHTTPHeaderField: "Content-Range") else { throw HLSSourceError.network }
            let parsed = try HLSProxyHTTP.contentRange(value)
            guard let total = Int(exactly: parsed.total), case let .single(selected) = try HTTPRange.parse(range, resourceLength: total),
                  Int64(selected.lowerBound) == parsed.first, Int64(selected.upperBound - 1) == parsed.last else { throw HLSSourceError.network }
            expected = parsed.last - parsed.first + 1; rangeHeader = "Content-Range: \(value)\r\n"
            if response.expectedContentLength >= 0, response.expectedContentLength != expected { throw HLSSourceError.network }
        } else if http.statusCode == 416 {
            guard let range, let value = http.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes */"),
                  let total = Int(value.dropFirst(8)), total >= 0,
                  case .unsatisfied = try HTTPRange.parse(range, resourceLength: total) else { throw HLSSourceError.network }
            rangeHeader = "Content-Range: bytes */\(total)\r\n"
            expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        } else { expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil }
        let chunked = expected == nil && method != .head
        let framing = expected.map { "Content-Length: \($0)\r\n" } ?? (chunked ? "Transfer-Encoding: chunked\r\n" : "")
        let mime = http.mimeType ?? "application/octet-stream"
        guard mime.utf8.count <= 128, mime.utf8.allSatisfy({ (32...126).contains($0) }) else { throw HLSSourceError.byteLimit }
        return (Data("HTTP/1.1 \(http.statusCode) OK\r\n\(framing)\(rangeHeader)Content-Type: \(mime)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), expected, chunked)
    }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let cancel = lock.withLock { self.task = task; return stopping }
        if cancel { task.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard lock.withLock({ !stopping }) else { completionHandler(nil); return }
        do {
            guard let url = newRequest.url, url.absoluteString.utf8.count <= 8_192, redirects.count <= 5,
                  redirects.insert(url).inserted else { throw HLSSourceError.redirectLimit }
            completionHandler(try request(url))
        } catch {
            lock.withLock { if failure == nil { failure = error }; stopping = true }
            completionHandler(nil); task.cancel()
        }
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        // This resource-free join does not retain the upstream/transfer through
        // its continuation-resume tail. It runs after the final delegate call.
        let invalidation = invalidation
        session.delegateQueue.addOperation { invalidation.complete() }
    }
    private func waitForInvalidation() async { await invalidation.wait() }
}

private final class HLSProxyInvalidationJoin: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    func complete() {
        let pending = lock.withLock { finished = true; defer { waiter = nil }; return waiter }
        pending?.resume()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if finished { return true }
                precondition(waiter == nil); waiter = continuation; return false
            }
            if done { continuation.resume() }
        }
    }
}
