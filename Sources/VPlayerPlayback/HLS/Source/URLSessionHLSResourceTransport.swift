// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct URLSessionHLSResourceTransport: HLSResourceTransport {
    private let pool: PooledSourceTransportSession

    public init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        pool = PooledSourceTransportSession(makeConfiguration: makeConfiguration)
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
        let transfer = BoundedSourceTransfer(
            request: request,
            pool: pool,
            preparationDiagnostics: HLSPreparationDiagnostics.current
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response = try await transfer.run()
            try Task.checkCancellation()
            return response
        } onCancel: { transfer.cancel() }
    }
}

/// Reused ephemeral URLSession + serial delegate queue shared by all requests
/// executed through a `URLSessionHLSResourceTransport` instance.
private final class PooledSourceTransportSession: @unchecked Sendable {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let lock = NSLock()
    private var session: URLSession?
    private var multiplexer: SessionMultiplexer?

    init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.makeConfiguration = makeConfiguration
    }

    deinit {
        session?.finishTasksAndInvalidate()
    }

    func makeDataTask(
        with urlRequest: URLRequest,
        transfer: BoundedSourceTransfer
    ) -> URLSessionDataTask {
        lock.withLock {
            let activeSession: URLSession
            let activeMultiplexer: SessionMultiplexer
            if let existingSession = session, let existingMultiplexer = multiplexer {
                activeSession = existingSession
                activeMultiplexer = existingMultiplexer
            } else {
                let configuration = makeConfiguration()
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.httpShouldSetCookies = false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 10
                configuration.timeoutIntervalForResource = 10
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let createdMultiplexer = SessionMultiplexer()
                let createdSession = URLSession(
                    configuration: configuration,
                    delegate: createdMultiplexer,
                    delegateQueue: queue
                )
                session = createdSession
                multiplexer = createdMultiplexer
                activeSession = createdSession
                activeMultiplexer = createdMultiplexer
            }
            let task = activeSession.dataTask(with: urlRequest)
            activeMultiplexer.register(transfer, for: task.taskIdentifier)
            return task
        }
    }

    private final class SessionMultiplexer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var transfers: [Int: BoundedSourceTransfer] = [:]

        func register(_ transfer: BoundedSourceTransfer, for taskIdentifier: Int) {
            lock.withLock { transfers[taskIdentifier] = transfer }
        }

        private func transfer(for task: URLSessionTask) -> BoundedSourceTransfer? {
            lock.withLock { transfers[task.taskIdentifier] }
        }

        private func takeTransfer(for task: URLSessionTask) -> BoundedSourceTransfer? {
            lock.withLock { transfers.removeValue(forKey: task.taskIdentifier) }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let transfer = transfer(for: task) else {
                completionHandler(nil)
                return
            }
            transfer.handleRedirect(task: task, newRequest: newRequest, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let transfer = transfer(for: dataTask) else {
                completionHandler(.cancel)
                return
            }
            transfer.handleResponse(response: response, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            transfer(for: dataTask)?.handleData(dataTask: dataTask, data: data)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            takeTransfer(for: task)?.handleComplete(error: error)
        }
    }
}

/// Delegate-side admission occurs before appending any body bytes. Completion
/// removes the transfer from the shared multiplexer and clears diagnostics
/// before resuming the caller's continuation.
private final class BoundedSourceTransfer: @unchecked Sendable {
    private let request: HLSResourceRequest
    private let pool: PooledSourceTransportSession
    // URLSession delegates do not inherit task-local values. Cleared before
    // resuming continuation so preflight diagnostic scopes never leak.
    private var preparationDiagnostics: HLSPreparationDiagnostics?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HLSResourceResponse, any Error>?
    // Body and acquisition state belong to the serial delegate queue. Only
    // cancellation crosses queues; never hold its lock across a native hint.
    private var body = Data()
    private var acquisitionBoundary: Int
    private var reservedContinuation = false
    private var response: HTTPURLResponse?
    private var contentRange: HLSHTTPContentRange?
    private var transparentlyDecompressed = false
    private var failure: (any Error)?
    private var cancelled = false
    private var stoppedPrefix = false
    private var redirects = 0
    private var visited: Set<URL> = []

    init(
        request: HLSResourceRequest,
        pool: PooledSourceTransportSession,
        preparationDiagnostics: HLSPreparationDiagnostics?
    ) {
        self.request = request
        self.pool = pool
        acquisitionBoundary = request.maximumTSContinuationBytes == nil
            ? request.maximumBytes : min(request.maximumBytes, 16 * 1_024)
        self.preparationDiagnostics = preparationDiagnostics
    }

    func run() async throws -> HLSResourceResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled else {
                preparationDiagnostics = nil
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            let now = HLSMonotonicClock.now
            let remaining = request.deadline > now ? Double(request.deadline - now) / 1_000_000_000 : 0
            guard remaining > 0 else {
                preparationDiagnostics = nil
                lock.unlock()
                continuation.resume(throwing: HLSSourceError.deadline)
                return
            }
            self.continuation = continuation
            var urlRequest = URLRequest(url: request.url)
            configure(&urlRequest, timeoutInterval: min(10, remaining))
            visited.insert(request.url)
            let task = pool.makeDataTask(with: urlRequest, transfer: self)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }

    private func configure(_ target: inout URLRequest, timeoutInterval: TimeInterval? = nil) {
        target.httpMethod = "GET"
        target.httpShouldHandleCookies = false
        target.allHTTPHeaderFields = nil
        if let timeoutInterval { target.timeoutInterval = timeoutInterval }
        if let url = target.url {
            for (name, value) in request.headers.fields(for: url) {
                target.setValue(value, forHTTPHeaderField: name)
            }
        }
        target.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = request.range {
            target.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
        }
    }

    func handleRedirect(
        task: URLSessionTask,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed: URLRequest? = lock.withLock {
            let now = HLSMonotonicClock.now
            guard !cancelled, now < request.deadline else {
                failure = cancelled ? CancellationError() : HLSSourceError.deadline
                return nil
            }
            guard redirects < 5,
                  let url = newRequest.url,
                  (try? PlaybackSourceOrigin(url)) != nil,
                  visited.insert(url).inserted else {
                failure = HLSSourceError.redirectLimit
                return nil
            }
            redirects += 1
            let remaining = Double(request.deadline - now) / 1_000_000_000
            var next = newRequest
            configure(&next, timeoutInterval: min(10, max(0.01, remaining)))
            return next
        }
        completionHandler(allowed)
        if allowed == nil { task.cancel() }
    }

    func handleResponse(
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let accepted = lock.withLock { () -> Bool in
            guard !cancelled, HLSMonotonicClock.now < request.deadline else {
                failure = cancelled ? CancellationError() : HLSSourceError.deadline
                return false
            }
            guard let http = response as? HTTPURLResponse,
                  let url = http.url,
                  (try? PlaybackSourceOrigin(url)) != nil else {
                failure = HLSSourceError.network
                return false
            }
            guard (200...299).contains(http.statusCode) else {
                failure = HLSSourceError.httpStatus(http.statusCode)
                return false
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isDecompressed: Bool
            if encoding == nil || encoding == "" || encoding == "identity" {
                isDecompressed = false
            } else if request.range == nil, encoding == "gzip" || encoding == "deflate" {
                // 非范围请求下 Darwin URLSession 会透明解压 gzip/deflate；
                // 解压后的字节仍由 didReceive data 严格按 request.maximumBytes 限额。
                isDecompressed = true
            } else {
                preparationDiagnostics?.reject(.httpEncoding, status: Int32(clamping: http.statusCode))
                failure = HLSSourceError.unsupportedMedia
                return false
            }
            let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(HLSHTTPContentRange.init)
            if http.statusCode == 206 {
                guard let range else { failure = HLSSourceError.incompleteEvidence; return false }
                if let expected = request.range {
                    guard range.start == expected.offset, range.length == expected.length else {
                        failure = HLSSourceError.incompleteEvidence
                        return false
                    }
                } else if range.start != 0 {
                    failure = HLSSourceError.incompleteEvidence
                    return false
                }
                if !isDecompressed, http.expectedContentLength >= 0, http.expectedContentLength != range.length {
                    failure = HLSSourceError.incompleteEvidence
                    return false
                }
            } else if request.range != nil || range != nil {
                failure = HLSSourceError.incompleteEvidence
                return false
            }
            if request.mode == .complete, http.expectedContentLength > Int64(request.maximumBytes) {
                failure = HLSSourceError.byteLimit
                return false
            }
            self.response = http
            contentRange = range
            transparentlyDecompressed = isDecompressed
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func handleData(dataTask: URLSessionDataTask, data: Data) {
        if let ceiling = request.maximumTSContinuationBytes {
            if receiveAcquisitionBytes(data, ceiling: ceiling) { dataTask.cancel() }
            return
        }
        let stop = lock.withLock { () -> Bool in
            guard failure == nil, !cancelled, HLSMonotonicClock.now < request.deadline else {
                if failure == nil { failure = cancelled ? CancellationError() : HLSSourceError.deadline }
                return true
            }
            let remaining = request.maximumBytes - body.count
            if data.count > remaining {
                guard request.mode != .complete, request.range == nil else {
                    failure = HLSSourceError.byteLimit
                    return true
                }
                body.append(data.prefix(remaining))
                stoppedPrefix = true
                return true
            }
            body.append(data)
            if request.mode != .complete,
               request.range == nil,
               body.count == request.maximumBytes,
               !transparentlyDecompressed,
               let response,
               response.expectedContentLength > Int64(body.count) {
                stoppedPrefix = true
                return true
            }
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
                if acquisitionBoundary < request.maximumBytes {
                    acquisitionBoundary = request.maximumBytes
                    continue
                }
                // Non-TS keeps the original complete-at-limit contract. An
                // exact-size manifest must be allowed to deliver its EOF; a
                // later positive callback is rejected before appending bytes.
                if offset < data.count || (!transparentlyDecompressed && (response?.expectedContentLength ?? -1) > Int64(body.count)) {
                    stoppedPrefix = true
                    return true
                }
                return false
            }
            let hint = body.withUnsafeBytes { bytes in
                vp_ffmpeg_source_ts_acquisition_hint(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    { context in
                        guard let context else { return 1 }
                        let transfer = Unmanaged<BoundedSourceTransfer>.fromOpaque(context).takeUnretainedValue()
                        return transfer.isInterrupted ? 1 : 0
                    },
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
            if stopForInterruption() { return true }
            var needsMore = hint == VPFF_SOURCE_ACQUISITION_NEEDS_MORE
            if hint == VPFF_SOURCE_ACQUISITION_READY, body.count < ceiling {
                do {
                    needsMore = try FFmpegHLSContainerInspector.needsMoreTSVideoEvidence(
                        data: body,
                        deadline: request.deadline,
                        interrupted: { self.isInterrupted }
                    )
                } catch {
                    failure = error
                    return true
                }
            }
            if stopForInterruption() { return true }
            // READY 仅表示参数集齐全。扫描证据也充分后才停止采集；最终
            // inspector/planner 仍完整验证输入，且原字节/时间预算不变。
            guard needsMore, body.count < ceiling else {
                stoppedPrefix = true
                return true
            }
            // 小前缀按倍增检测，避免低码率直播盲等 1 MiB；越过初始预算后
            // 才预留扩展空间，仍受原绝对期限与 8 MiB 总上限约束。
            if acquisitionBoundary < request.maximumBytes {
                acquisitionBoundary = min(request.maximumBytes, acquisitionBoundary * 2)
            } else {
                if !reservedContinuation {
                    body.reserveCapacity(ceiling)
                    reservedContinuation = true
                }
                acquisitionBoundary = min(ceiling, acquisitionBoundary + 256 * 1_024)
            }
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

    func handleComplete(error: (any Error)?) {
        let completed: (CheckedContinuation<HLSResourceResponse, any Error>?, Result<HLSResourceResponse, any Error>) = lock.withLock {
            let finalResult: Result<HLSResourceResponse, any Error>
            if cancelled {
                finalResult = .failure(CancellationError())
            } else if let failure {
                finalResult = .failure(failure)
            } else if HLSMonotonicClock.now >= request.deadline {
                finalResult = .failure(HLSSourceError.deadline)
            } else if let error, !stoppedPrefix {
                finalResult = .failure((error as NSError).code == NSURLErrorTimedOut ? HLSSourceError.deadline : HLSSourceError.network)
            } else if let response, let url = response.url {
                let completeLength = transparentlyDecompressed
                    || response.expectedContentLength < 0
                    || response.expectedContentLength == Int64(body.count)
                let completeRange = contentRange == nil || contentRange?.length == Int64(body.count)
                if !stoppedPrefix && (!completeLength || !completeRange) {
                    finalResult = .failure(HLSSourceError.incompleteEvidence)
                } else {
                    let completeness: HLSResourceCompleteness
                    if stoppedPrefix {
                        completeness = .prefix
                    } else if request.range != nil {
                        completeness = .byteRange
                    } else if let range = contentRange {
                        completeness = range.start == 0 && range.total == Int64(body.count) ? .complete : .prefix
                    } else {
                        completeness = .complete
                    }
                    finalResult = .success(HLSResourceResponse(
                        responseURL: url,
                        data: body,
                        statusCode: response.statusCode,
                        contentType: response.mimeType,
                        completeness: completeness,
                        contentRange: contentRange
                    ))
                }
            } else {
                finalResult = .failure(HLSSourceError.network)
            }
            body = Data()
            task = nil
            preparationDiagnostics = nil
            let pendingContinuation = continuation
            continuation = nil
            return (pendingContinuation, finalResult)
        }
        completed.0?.resume(with: completed.1)
    }
}
