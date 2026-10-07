// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct URLSessionHLSResourceTransport: HLSResourceTransport {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    public init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.makeConfiguration = makeConfiguration
    }
    public func fetch(_ request: HLSResourceRequest) async throws -> HLSResourceResponse {
        try Task.checkCancellation()
        _ = try PlaybackSourceOrigin(request.url)
        guard request.maximumBytes > 0, request.maximumBytes <= 8 * 1_024 * 1_024 else { throw HLSSourceError.byteLimit }
        if let ceiling = request.maximumTSContinuationBytes {
            guard request.mode == .classify, request.range == nil,
                  ceiling > request.maximumBytes, ceiling <= HLSCompatibilityProbe.maximumBytes else { throw HLSSourceError.byteLimit }
        }
        guard HLSMonotonicClock.now < request.deadline else { throw HLSSourceError.deadline }
        if let range = request.range {
            guard range.offset >= 0, range.length > 0, range.length <= Int64(request.maximumBytes),
                  !range.offset.addingReportingOverflow(range.length).overflow else { throw HLSSourceError.byteLimit }
        }
        let transfer = BoundedSourceTransfer(request: request, configuration: makeConfiguration(),
            preparationDiagnostics: HLSPreparationDiagnostics.current)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response = try await transfer.run()
            try Task.checkCancellation()
            return response
        } onCancel: { transfer.cancel() }
    }
}

/// Delegate-side admission occurs before appending any body bytes. Completion
/// waits for session invalidation on the same serial callback queue. Framework
/// internal allocation sizes still require Apple runtime footprint acceptance.
private final class BoundedSourceTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: HLSResourceRequest
    private let configuration: URLSessionConfiguration
    // URLSession delegates do not inherit task-local values. This alias is
    // joined by session invalidation before the preflight scope can return.
    private var preparationDiagnostics: HLSPreparationDiagnostics?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HLSResourceResponse, any Error>?
    private var result: Result<HLSResourceResponse, any Error>?
    // Body and acquisition state belong to the serial delegate queue. Only
    // cancellation crosses queues; never hold its lock across a native hint.
    private var body = Data()
    private var acquisitionBoundary: Int
    private var reservedContinuation = false
    private var response: HTTPURLResponse?
    private var contentRange: HLSHTTPContentRange?
    private var failure: (any Error)?
    private var cancelled = false
    private var stoppedPrefix = false
    private var redirects = 0
    private var visited: Set<URL> = []

    init(request: HLSResourceRequest, configuration: URLSessionConfiguration,
         preparationDiagnostics: HLSPreparationDiagnostics?) {
        self.request = request; self.configuration = configuration
        acquisitionBoundary = request.maximumBytes
        self.preparationDiagnostics = preparationDiagnostics
    }
    func run() async throws -> HLSResourceResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let now = HLSMonotonicClock.now
            let remaining = request.deadline > now ? Double(request.deadline - now) / 1_000_000_000 : 0
            guard remaining > 0 else { self.continuation = nil; lock.unlock(); continuation.resume(throwing: HLSSourceError.deadline); return }
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = min(10, remaining); configuration.timeoutIntervalForResource = min(10, remaining)
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            var urlRequest = URLRequest(url: request.url)
            configure(&urlRequest)
            let task = session.dataTask(with: urlRequest)
            self.task = task; visited.insert(request.url)
            lock.unlock()
            task.resume()
        }
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
    private func configure(_ target: inout URLRequest) {
        target.httpMethod = "GET"; target.httpShouldHandleCookies = false; target.allHTTPHeaderFields = nil
        if let url = target.url { for (name, value) in request.headers.fields(for: url) { target.setValue(value, forHTTPHeaderField: name) } }
        target.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = request.range { target.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed: URLRequest? = lock.withLock {
            guard !cancelled, HLSMonotonicClock.now < request.deadline else { failure = cancelled ? CancellationError() : HLSSourceError.deadline; return nil }
            guard redirects < 5, let url = newRequest.url, (try? PlaybackSourceOrigin(url)) != nil,
                  visited.insert(url).inserted else { failure = HLSSourceError.redirectLimit; return nil }
            redirects += 1
            var next = newRequest; configure(&next); return next
        }
        completionHandler(allowed)
        if allowed == nil { task.cancel() }
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let accepted = lock.withLock { () -> Bool in
            guard !cancelled, HLSMonotonicClock.now < request.deadline else { failure = cancelled ? CancellationError() : HLSSourceError.deadline; return false }
            guard let http = response as? HTTPURLResponse, let url = http.url, (try? PlaybackSourceOrigin(url)) != nil else { failure = HLSSourceError.network; return false }
            guard (200...299).contains(http.statusCode) else { failure = HLSSourceError.httpStatus(http.statusCode); return false }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else {
                preparationDiagnostics?.reject(.httpEncoding, status: Int32(clamping: http.statusCode))
                failure = HLSSourceError.unsupportedMedia; return false
            }
            let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(HLSHTTPContentRange.init)
            if http.statusCode == 206 {
                guard let range else { failure = HLSSourceError.incompleteEvidence; return false }
                if let expected = request.range {
                    guard range.start == expected.offset, range.length == expected.length else { failure = HLSSourceError.incompleteEvidence; return false }
                } else if range.start != 0 { failure = HLSSourceError.incompleteEvidence; return false }
                if http.expectedContentLength >= 0, http.expectedContentLength != range.length { failure = HLSSourceError.incompleteEvidence; return false }
            } else if request.range != nil || range != nil { failure = HLSSourceError.incompleteEvidence; return false }
            if request.mode == .complete, http.expectedContentLength > Int64(request.maximumBytes) { failure = HLSSourceError.byteLimit; return false }
            self.response = http; contentRange = range; return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let ceiling = request.maximumTSContinuationBytes {
            if receiveAcquisitionBytes(data, ceiling: ceiling) { dataTask.cancel() }
            return
        }
        let stop = lock.withLock { () -> Bool in
            guard failure == nil, !cancelled, HLSMonotonicClock.now < request.deadline else {
                if failure == nil { failure = cancelled ? CancellationError() : HLSSourceError.deadline }; return true
            }
            let remaining = request.maximumBytes - body.count
            if data.count > remaining {
                guard request.mode != .complete, request.range == nil else { failure = HLSSourceError.byteLimit; return true }
                body.append(data.prefix(remaining)); stoppedPrefix = true; return true
            }
            body.append(data)
            if request.mode != .complete, request.range == nil, body.count == request.maximumBytes,
               let response, response.expectedContentLength > Int64(body.count) { stoppedPrefix = true; return true }
            return false
        }
        if stop { dataTask.cancel() }
    }
    /// A callback may cross several milestones. Admit only the bytes up to each
    /// boundary before inspecting, then resume from the same callback offset.
    /// The body borrow ends before either append or its one extended reservation.
    private func receiveAcquisitionBytes(_ data: Data, ceiling: Int) -> Bool {
        if stoppedPrefix || stopForInterruption() { return true }
        var offset = 0
        while offset < data.count {
            if stopForInterruption() { return true }
            let remaining = acquisitionBoundary - body.count
            let count = min(data.count - offset, remaining)
            data.withUnsafeBytes { bytes in
                if let base = bytes.bindMemory(to: UInt8.self).baseAddress, count > 0 {
                    body.append(base.advanced(by: offset), count: count)
                }
            }
            offset += count
            guard body.count == acquisitionBoundary else { return false }
            if body.first != 0x47 {
                // Non-TS keeps the original complete-at-limit contract. An
                // exact-size manifest must be allowed to deliver its EOF; a
                // later positive callback is rejected before appending bytes.
                if offset < data.count || (response?.expectedContentLength ?? -1) > Int64(body.count) {
                    stoppedPrefix = true; return true
                }
                return false
            }
            let hint = body.withUnsafeBytes { bytes in
                vp_ffmpeg_source_ts_acquisition_hint(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                    { context in
                        guard let context else { return 1 }
                        let transfer = Unmanaged<BoundedSourceTransfer>.fromOpaque(context).takeUnretainedValue()
                        return transfer.isInterrupted ? 1 : 0
                    }, Unmanaged.passUnretained(self).toOpaque())
            }
            if stopForInterruption() { return true }
            // READY and STOP only end acquisition. Neither bypasses the full
            // inspector/planner. A raw TS boundary intentionally cancels even
            // when Content-Length is absent or an EOF callback is still queued.
            guard hint == VPFF_SOURCE_ACQUISITION_NEEDS_MORE,
                  body.count < ceiling else {
                stoppedPrefix = true; return true
            }
            if !reservedContinuation { body.reserveCapacity(ceiling); reservedContinuation = true }
            // Production's 1 MiB initial limit gives at most 29 hints through
            // 8 MiB; any smaller positive initial limit still gives at most 33.
            acquisitionBoundary = min(ceiling, acquisitionBoundary + 256 * 1_024)
        }
        return false
    }
    private var isInterrupted: Bool { lock.withLock { cancelled } || HLSMonotonicClock.now >= request.deadline }
    private func stopForInterruption() -> Bool {
        lock.withLock {
            if failure != nil { return true }
            if cancelled { failure = CancellationError(); return true }
            if HLSMonotonicClock.now >= request.deadline { failure = HLSSourceError.deadline; return true }
            return false
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.withLock {
            if cancelled { result = .failure(CancellationError()) }
            else if let failure { result = .failure(failure) }
            else if HLSMonotonicClock.now >= request.deadline { result = .failure(HLSSourceError.deadline) }
            else if let error, !stoppedPrefix { result = .failure((error as NSError).code == NSURLErrorTimedOut ? HLSSourceError.deadline : HLSSourceError.network) }
            else if let response, let url = response.url {
                let completeLength = response.expectedContentLength < 0 || response.expectedContentLength == Int64(body.count)
                let completeRange = contentRange == nil || contentRange?.length == Int64(body.count)
                if !stoppedPrefix && (!completeLength || !completeRange) { result = .failure(HLSSourceError.incompleteEvidence) }
                else {
                    let completeness: HLSResourceCompleteness
                    if stoppedPrefix { completeness = .prefix }
                    else if request.range != nil { completeness = .byteRange }
                    else if let range = contentRange { completeness = range.start == 0 && range.total == Int64(body.count) ? .complete : .prefix }
                    else { completeness = .complete }
                    result = .success(HLSResourceResponse(responseURL: url, data: body, statusCode: response.statusCode,
                        contentType: response.mimeType, completeness: completeness, contentRange: contentRange))
                }
            } else { result = .failure(HLSSourceError.network) }
            body = Data(); self.task = nil
        }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let completed: (CheckedContinuation<HLSResourceResponse, any Error>?, Result<HLSResourceResponse, any Error>) = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil; self.session = nil
            preparationDiagnostics = nil
            let result = self.result ?? .failure(HLSSourceError.network)
            self.result = nil; return (continuation, result)
        }
        completed.0?.resume(with: completed.1)
    }
}
