// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Serial delegate delivery + a single synchronous Network send supply app-held
/// backpressure. SDK queued storage remains an explicit platform measurement gate.
final class HLSProxyUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let resource: HLSProxyResourceRegistry.Resource
    private let method: LoopbackHTTPRequest.Method
    private let range: String?
    private let connection: HLSProxyConnection
    private let transfer: HLSProxyBudget.Lease
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var terminal: Result<Void, any Error>?
    // Accessed only on the private serial URLSession delegate queue after start.
    private var redirects: Set<URL> = []
    private var expected: Int64?
    private var received: Int64 = 0
    private var chunked = false

    init(resource: HLSProxyResourceRegistry.Resource, method: LoopbackHTTPRequest.Method, range: String?,
         connection: HLSProxyConnection, transfer: HLSProxyBudget.Lease) {
        self.resource = resource; self.method = method; self.range = range; self.connection = connection; self.transfer = transfer
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let terminal { lock.unlock(); continuation.resume(with: terminal); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpAdditionalHeaders = [:]; configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 15
                // Do not impose a short total resource timeout on a live byte stream.
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                do {
                    let task = session.dataTask(with: try request(resource.url))
                    self.task = task; redirects.insert(resource.url)
                    lock.unlock(); task.resume()
                } catch { lock.unlock(); finish(.failure(error)) }
            }
        } onCancel: { self.cancel() }
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
    func cancel() { finish(.failure(CancellationError())); connection.connection.cancel() }
    private func finish(_ result: Result<Void, any Error>) {
        let pending = lock.withLock { () -> (URLSession?, CheckedContinuation<Void, any Error>?) in
            guard terminal == nil else { return (nil, nil) }
            terminal = result
            guard let session else { defer { continuation = nil }; return (nil, continuation) }
            return (session, nil)
        }
        if let session = pending.0 { session.invalidateAndCancel() } else { pending.1?.resume(with: result) }
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let pending = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, Result<Void, any Error>) in
            defer { continuation = nil; self.session = nil; task = nil }
            return (continuation, terminal ?? .failure(HLSSourceError.network))
        }
        // Resume behind the terminal callback, after all older delegate callbacks.
        session.delegateQueue.addOperation { pending.0?.resume(with: pending.1) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        do {
            guard let url = newRequest.url, url.absoluteString.utf8.count <= 8_192, redirects.count <= 5,
                  redirects.insert(url).inserted else { throw HLSSourceError.redirectLimit }
            completionHandler(try request(url))
        } catch { completionHandler(nil); finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw HLSSourceError.network }
            if [401, 403].contains(http.statusCode) { throw HLSSourceError.unauthorized }
            guard [200, 206, 416].contains(http.statusCode) else { throw HLSSourceError.network }
            try HLSProxyHTTP.validateEncoding(http.value(forHTTPHeaderField: "Content-Encoding"))
            var rangeHeader = ""
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
                rangeHeader = "Content-Range: bytes */\(total)\r\n"; expected = 0
            } else { expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil }
            chunked = expected == nil && method != .head
            let framing = expected.map { "Content-Length: \($0)\r\n" } ?? (chunked ? "Transfer-Encoding: chunked\r\n" : "")
            let mime = http.mimeType ?? "application/octet-stream"
            guard mime.utf8.count <= 128, mime.utf8.allSatisfy({ (32...126).contains($0) }) else { throw HLSSourceError.byteLimit }
            try connection.sendBlocking(Data("HTTP/1.1 \(http.statusCode) OK\r\n\(framing)\(rangeHeader)Content-Type: \(mime)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), header: true)
            completionHandler(.allow)
        } catch { completionHandler(.cancel); finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        connection.io.beginCallback(data.count); dataTask.suspend()
        defer { connection.io.endCallback(data.count); if lock.withLock({ terminal == nil }) { dataTask.resume() } }
        do {
            if data.isEmpty { return }
            guard method != .head, data.count <= HLSProxyBudget.transferBufferBytes else { throw HLSSourceError.byteLimit }
            let next = received.addingReportingOverflow(Int64(data.count))
            guard !next.overflow, expected.map({ next.partialValue <= $0 }) ?? true else { throw HLSSourceError.network }
            if chunked { try connection.sendBlocking(Data("\(String(data.count, radix: 16))\r\n".utf8)) }
            try connection.sendBlocking(data)
            if chunked { try connection.sendBlocking(Data("\r\n".utf8)) }
            received = next.partialValue
        } catch { finish(.failure(error)); connection.connection.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        do {
            guard error == nil, method == .head || (expected.map({ received == $0 }) ?? true) else { throw HLSSourceError.network }
            if chunked { try connection.sendBlocking(Data("0\r\n\r\n".utf8)) }
            finish(.success(Void()))
        } catch { finish(.failure(error)) }
    }
}
