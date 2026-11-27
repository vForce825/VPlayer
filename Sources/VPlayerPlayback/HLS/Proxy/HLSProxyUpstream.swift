// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Reused ephemeral URLSession + serial delegate queue shared across all
/// upstream transfers of an `HLSProxySession`, avoiding per-request URLSession
/// and OperationQueue allocation/invalidation churn.
final class HLSProxyUpstreamSession: @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var delegate: Delegate?
    private var invalidated = false
    private let invalidation = HLSProxyInvalidationJoin()

    func makeDataTask(
        with request: URLRequest,
        handler: HLSProxyUpstream
    ) throws -> URLSessionDataTask {
        try lock.withLock {
            guard !invalidated else { throw CancellationError() }
            let activeSession: URLSession
            let activeDelegate: Delegate
            if let existingSession = session, let existingDelegate = delegate {
                activeSession = existingSession
                activeDelegate = existingDelegate
            } else {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpAdditionalHeaders = [:]
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 15
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let createdDelegate = Delegate(invalidation: invalidation)
                let createdSession = URLSession(
                    configuration: configuration,
                    delegate: createdDelegate,
                    delegateQueue: queue
                )
                session = createdSession
                delegate = createdDelegate
                activeSession = createdSession
                activeDelegate = createdDelegate
            }
            let task = activeSession.dataTask(with: request)
            activeDelegate.register(handler, for: task.taskIdentifier)
            return task
        }
    }

    func unregister(taskIdentifier: Int) {
        let activeDelegate = lock.withLock { delegate }
        activeDelegate?.unregister(taskIdentifier: taskIdentifier)
    }

    func invalidate() async {
        let sessionToInvalidate = lock.withLock { () -> URLSession? in
            invalidated = true
            let current = session
            session = nil
            delegate = nil
            return current
        }
        guard let sessionToInvalidate else { return }
        sessionToInvalidate.finishTasksAndInvalidate()
        await invalidation.wait()
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [Int: HLSProxyUpstream] = [:]
        private let invalidation: HLSProxyInvalidationJoin

        init(invalidation: HLSProxyInvalidationJoin) {
            self.invalidation = invalidation
        }

        func register(_ handler: HLSProxyUpstream, for taskIdentifier: Int) {
            lock.withLock { handlers[taskIdentifier] = handler }
        }

        func unregister(taskIdentifier: Int) {
            _ = lock.withLock { handlers.removeValue(forKey: taskIdentifier) }
        }

        private func handler(for task: URLSessionTask) -> HLSProxyUpstream? {
            lock.withLock { handlers[task.taskIdentifier] }
        }

        private func takeHandler(for task: URLSessionTask) -> HLSProxyUpstream? {
            lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let handler = handler(for: task) else {
                completionHandler(nil)
                return
            }
            handler.handleRedirect(task: task, newRequest: newRequest, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let handler = handler(for: dataTask) else {
                completionHandler(.cancel)
                return
            }
            handler.handleResponse(dataTask: dataTask, response: response, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            handler(for: dataTask)?.handleData(dataTask: dataTask, data: data)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            takeHandler(for: task)?.handleComplete(task: task, error: error)
        }

        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
            let invalidation = invalidation
            session.delegateQueue.addOperation { invalidation.complete() }
        }
    }
}

/// Chunked URLSessionDataDelegate consumer owning one prepaid fixed ring window.
/// Copies whole incoming Data chunks into BytePipe and suspends/resumes the
/// URLSessionDataTask when the ring fills up.
final class HLSProxyUpstream: @unchecked Sendable {
    private struct ResponseHead: Sendable {
        let bytes: Data
        let expected: Int64?
        let chunked: Bool
    }

    private let resource: HLSProxyResourceRegistry.Resource
    private let method: LoopbackHTTPRequest.Method
    private let range: String?
    private let connection: HLSProxyConnection
    private let transfer: HLSProxyBudget.Lease
    private let sharedSession: HLSProxyUpstreamSession?

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var consumer: Task<Void, any Error>?
    private var started = false
    private var stopping = false
    private var taskStarted = false
    private var failure: (any Error)?
    private var redirects: Set<URL> = []
    private let taskDone = HLSProxyInvalidationJoin()

    // Chunked pipe / backpressure state protected by chunkLock.
    private let chunkLock = NSLock()
    private var activePipe: HLSProxyBudget.BytePipe?
    private var responseHeadResult: Result<ResponseHead, any Error>?
    private var responseHeadWaiter: CheckedContinuation<ResponseHead, any Error>?
    private var writePosition: UInt64 = 0
    private var overflowChunks: [Data] = []
    private var overflowOffset = 0
    private var headerSuspended = false
    private var taskSuspended = false
    private var suspendApplied = false
    private var completedResult: Result<Void, any Error>?
    private var chunkAborted: (any Error)?
    private var readerWake: CheckedContinuation<Void, Never>?

    init(
        resource: HLSProxyResourceRegistry.Resource,
        method: LoopbackHTTPRequest.Method,
        range: String?,
        connection: HLSProxyConnection,
        transfer: HLSProxyBudget.Lease,
        sharedSession: HLSProxyUpstreamSession? = nil
    ) {
        self.resource = resource
        self.method = method
        self.range = range
        self.connection = connection
        self.transfer = transfer
        self.sharedSession = sharedSession
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
                self.consumer = value
                return value
            }
            defer { lock.withLock { self.consumer = nil; self.task = nil } }
            // Cancellation requests alone never stand in for the consumer join.
            try await consumer.value
        } onCancel: { self.cancel() }
    }

    func cancel() {
        let pending = lock.withLock { () -> (Task<Void, any Error>?, URLSessionDataTask?) in
            stopping = true
            if failure == nil { failure = CancellationError() }
            return (consumer, task)
        }
        abortChunks(CancellationError())
        pending.0?.cancel()
        pending.1?.cancel()
        connection.connection.cancel()
    }

    private func consume() async throws {
        // This happens before URLSession creates/resumes its underlying task.
        let envelope = try transfer.reserveBodyEnvelope()
        let ownedSession = sharedSession == nil ? HLSProxyUpstreamSession() : nil
        let session = sharedSession ?? ownedSession!
        lock.withLock { _ = redirects.insert(resource.url) }
        let result: Result<Void, any Error>
        do {
            try Task.checkCancellation()
            try await stream(session: session, envelope: envelope)
            try Task.checkCancellation()
            result = .success(())
        } catch {
            result = .failure(lock.withLock { failure } ?? error)
        }
        let (upstream, didStart) = lock.withLock { () -> (URLSessionDataTask?, Bool) in
            stopping = true
            return (task, taskStarted)
        }
        if case .failure = result {
            abortChunks(lock.withLock { failure } ?? CancellationError())
            upstream?.cancel()
        }
        if didStart {
            // Wait for didCompleteWithError before releasing envelope/session.
            await taskDone.wait()
        }
        if let ownedSession {
            await ownedSession.invalidate()
        }
        withExtendedLifetime(envelope) {}
        try result.get()
    }

    private func stream(session: HLSProxyUpstreamSession, envelope: HLSProxyBudget.BodyEnvelope) async throws {
        let pipe = HLSProxyBudget.BytePipe(envelope: envelope)
        chunkLock.withLock { activePipe = pipe }
        defer { chunkLock.withLock { activePipe = nil } }
        connection.io.beginReadWindow(pipe.window.capacity)
        defer { connection.io.endReadWindow(pipe.window.capacity) }

        let urlRequest = try request(resource.url)
        let upstream = try session.makeDataTask(with: urlRequest, handler: self)
        let accepted = lock.withLock { () -> Bool in
            if stopping { return false }
            task = upstream
            taskStarted = true
            return true
        }
        guard accepted else {
            session.unregister(taskIdentifier: upstream.taskIdentifier)
            upstream.cancel()
            throw CancellationError()
        }
        upstream.resume()
        defer { releaseHeaderSuspension(upstream: upstream, resumeTask: false) }

        let head = try await waitForResponseHead()
        try Task.checkCancellation()
        try await connection.beginResponse(head.bytes)

        if method == .head {
            try Task.checkCancellation()
            releaseHeaderSuspension(upstream: upstream, resumeTask: true)
            await taskDone.wait()
            let headCompletion = chunkLock.withLock { completedResult }
            if let headCompletion { try headCompletion.get() }
            if let recordedFailure = lock.withLock({ failure }) { throw recordedFailure }
            return
        }

        // Exactly one reader task for the transfer, never one task per byte or
        // span. Cancellation-handler registration also covers an already
        // cancelled consumer racing this child task's installation.
        try Task.checkCancellation()
        let reader = Task { await self.drainChunks(into: pipe, upstream: upstream) }
        releaseHeaderSuspension(upstream: upstream, resumeTask: true)

        try await withTaskCancellationHandler {
            let result: Result<Void, any Error>
            do {
                var received: Int64 = 0
                while let span = try await pipe.nextSpan(at: UInt64(received)) {
                    try Task.checkCancellation()
                    let next = received.addingReportingOverflow(Int64(span.count))
                    guard !next.overflow, head.expected.map({ next.partialValue <= $0 }) ?? true else {
                        throw HLSSourceError.network
                    }
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
                abortChunks(error)
                pipe.abort(error)
                reader.cancel()
                upstream.cancel()
                connection.connection.cancel()
                result = .failure(error)
            }
            await reader.value
            try result.get()
        } onCancel: {
            self.abortChunks(CancellationError())
            pipe.abort(CancellationError())
            reader.cancel()
            upstream.cancel()
            self.connection.connection.cancel()
        }
    }

    private func waitForResponseHead() async throws -> ResponseHead {
        try await withCheckedThrowingContinuation { continuation in
            let settled: Result<ResponseHead, any Error>? = chunkLock.withLock {
                if let existing = responseHeadResult { return existing }
                if let aborted = chunkAborted { return .failure(aborted) }
                precondition(responseHeadWaiter == nil)
                responseHeadWaiter = continuation
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }
    }

    private func releaseHeaderSuspension(upstream: URLSessionDataTask, resumeTask: Bool) {
        let (wasSuspended, wake): (Bool, CheckedContinuation<Void, Never>?) = chunkLock.withLock {
            guard headerSuspended else { return (false, nil) }
            headerSuspended = false
            defer { readerWake = nil }
            return (true, readerWake)
        }
        guard wasSuspended else { return }
        // Only resume the reader counter when we actually suspended it in handleResponse.
        connection.io.resumeReader()
        if resumeTask { upstream.resume() }
        wake?.resume()
    }

    private func drainChunks(into pipe: HLSProxyBudget.BytePipe, upstream: URLSessionDataTask) async {
        connection.io.beginUpstreamReader()
        defer {
            let needResumeReader = chunkLock.withLock { () -> Bool in
                overflowChunks.removeAll(keepingCapacity: false)
                overflowOffset = 0
                let wasSuspended = suspendApplied
                taskSuspended = false
                suspendApplied = false
                return wasSuspended
            }
            if needResumeReader { connection.io.resumeReader() }
            connection.io.endUpstreamReader()
        }

        enum Step {
            case waitForEvent
            case waitForSpace(UInt64)
            case resumeUpstream
            case finish(Result<Void, any Error>)
        }

        do {
            while true {
                try Task.checkCancellation()
                let step: Step = try chunkLock.withLock {
                    if let aborted = chunkAborted { throw aborted }
                    if headerSuspended { return .waitForEvent }
                    if taskSuspended && !suspendApplied { return .waitForEvent }

                    while !overflowChunks.isEmpty {
                        let current = overflowChunks[0]
                        let written = try pipe.publish(contentsOf: current, from: overflowOffset, at: writePosition)
                        writePosition += UInt64(written)
                        overflowOffset += written
                        if overflowOffset >= current.count {
                            overflowChunks.removeFirst()
                            overflowOffset = 0
                        } else {
                            return .waitForSpace(writePosition)
                        }
                    }

                    if taskSuspended && suspendApplied {
                        taskSuspended = false
                        suspendApplied = false
                        return .resumeUpstream
                    }

                    if let completedResult {
                        return .finish(completedResult)
                    }
                    return .waitForEvent
                }

                switch step {
                case .resumeUpstream:
                    connection.io.resumeReader()
                    try Task.checkCancellation()
                    upstream.resume()
                case let .waitForSpace(position):
                    try await pipe.waitForSpace(at: position)
                case .waitForEvent:
                    await waitForChunkEvent()
                case let .finish(result):
                    pipe.finish(result)
                    return
                }
            }
        } catch {
            pipe.finish(.failure(error))
        }
    }

    private func waitForChunkEvent() async {
        await withCheckedContinuation { continuation in
            let ready = chunkLock.withLock { () -> Bool in
                if chunkAborted != nil || completedResult != nil { return true }
                if !headerSuspended && (!taskSuspended || suspendApplied) && !overflowChunks.isEmpty { return true }
                if !headerSuspended && taskSuspended && suspendApplied && overflowChunks.isEmpty { return true }
                precondition(readerWake == nil)
                readerWake = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func abortChunks(_ error: any Error) {
        let (headWaiter, wake) = chunkLock.withLock {
            () -> (CheckedContinuation<ResponseHead, any Error>?, CheckedContinuation<Void, Never>?) in
            if chunkAborted == nil { chunkAborted = error }
            if responseHeadResult == nil { responseHeadResult = .failure(error) }
            let pendingHead = responseHeadWaiter
            responseHeadWaiter = nil
            let pendingWake = readerWake
            readerWake = nil
            return (pendingHead, pendingWake)
        }
        headWaiter?.resume(throwing: error)
        wake?.resume()
    }

    fileprivate func handleRedirect(
        task: URLSessionTask,
        newRequest: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed: URLRequest? = lock.withLock {
            guard !stopping else { return nil }
            do {
                guard let url = newRequest.url,
                      url.absoluteString.utf8.count <= 8_192,
                      redirects.count <= 5,
                      redirects.insert(url).inserted else {
                    throw HLSSourceError.redirectLimit
                }
                return try request(url)
            } catch {
                if failure == nil { failure = error }
                stopping = true
                return nil
            }
        }
        if let allowed {
            completionHandler(allowed)
        } else {
            completionHandler(nil)
            task.cancel()
        }
    }

    fileprivate func handleResponse(
        dataTask: URLSessionDataTask,
        response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard lock.withLock({ !stopping }) else {
            completionHandler(.cancel)
            return
        }
        do {
            let head = try responseHead(response)
            dataTask.suspend()
            connection.io.suspendReader()
            let waiter: CheckedContinuation<ResponseHead, any Error>? = chunkLock.withLock {
                headerSuspended = true
                responseHeadResult = .success(head)
                defer { responseHeadWaiter = nil }
                return responseHeadWaiter
            }
            waiter?.resume(returning: head)
            completionHandler(.allow)
        } catch {
            lock.withLock {
                if failure == nil { failure = error }
                stopping = true
            }
            let waiter: CheckedContinuation<ResponseHead, any Error>? = chunkLock.withLock {
                if responseHeadResult == nil { responseHeadResult = .failure(error) }
                defer { responseHeadWaiter = nil }
                return responseHeadWaiter
            }
            waiter?.resume(throwing: error)
            completionHandler(.cancel)
        }
    }

    fileprivate func handleData(dataTask: URLSessionDataTask, data: Data) {
        guard !data.isEmpty else { return }
        if method == .head {
            lock.withLock {
                if failure == nil { failure = HLSSourceError.network }
                stopping = true
            }
            abortChunks(HLSSourceError.network)
            dataTask.cancel()
            return
        }

        enum Action {
            case none
            case suspendForBackpressure
            case fail(any Error)
        }

        let action: Action = chunkLock.withLock {
            guard chunkAborted == nil, let pipe = activePipe else { return .none }
            if !headerSuspended && !taskSuspended && overflowChunks.isEmpty {
                do {
                    let written = try pipe.publish(contentsOf: data, from: 0, at: writePosition)
                    writePosition += UInt64(written)
                    if written == data.count {
                        return .none
                    }
                    overflowChunks.append(data)
                    overflowOffset = written
                    taskSuspended = true
                    return .suspendForBackpressure
                } catch {
                    chunkAborted = error
                    return .fail(error)
                }
            } else {
                overflowChunks.append(data)
                return .none
            }
        }

        switch action {
        case .none:
            break
        case .suspendForBackpressure:
            dataTask.suspend()
            connection.io.suspendReader()
            let wake: CheckedContinuation<Void, Never>? = chunkLock.withLock {
                suspendApplied = true
                defer { readerWake = nil }
                return readerWake
            }
            wake?.resume()
        case let .fail(error):
            lock.withLock {
                if failure == nil { failure = error }
                stopping = true
            }
            abortChunks(error)
            dataTask.cancel()
        }
    }

    fileprivate func handleComplete(task: URLSessionTask, error: (any Error)?) {
        let recordedFailure = lock.withLock { failure }
        let finalResult: Result<Void, any Error>
        if let recordedFailure {
            finalResult = .failure(recordedFailure)
        } else if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
               lock.withLock({ stopping }) {
                finalResult = .failure(CancellationError())
            } else {
                finalResult = .failure(HLSSourceError.network)
            }
        } else {
            finalResult = .success(())
        }

        let (headWaiter, wake) = chunkLock.withLock {
            () -> (CheckedContinuation<ResponseHead, any Error>?, CheckedContinuation<Void, Never>?) in
            if completedResult == nil { completedResult = finalResult }
            var pendingHead: CheckedContinuation<ResponseHead, any Error>?
            if responseHeadResult == nil {
                let headError: any Error
                if case let .failure(err) = finalResult { headError = err }
                else { headError = HLSSourceError.network }
                responseHeadResult = .failure(headError)
                pendingHead = responseHeadWaiter
                responseHeadWaiter = nil
            }
            let pendingWake = readerWake
            readerWake = nil
            return (pendingHead, pendingWake)
        }

        if let headWaiter {
            if case let .failure(err) = finalResult { headWaiter.resume(throwing: err) }
            else { headWaiter.resume(throwing: HLSSourceError.network) }
        }
        wake?.resume()
        taskDone.complete()
    }

    private func request(_ url: URL) throws -> URLRequest {
        _ = try PlaybackSourceOrigin(url)
        guard url.absoluteString.utf8.count <= 8_192 else { throw HLSSourceError.byteLimit }
        var request = URLRequest(url: url)
        request.httpMethod = method == .head ? "HEAD" : "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        for (name, value) in resource.source.context.headers.fields(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    private func responseHead(_ response: URLResponse) throws -> ResponseHead {
        guard let http = response as? HTTPURLResponse else { throw HLSSourceError.network }
        if [401, 403].contains(http.statusCode) { throw HLSSourceError.unauthorized }
        guard [200, 206, 416].contains(http.statusCode) else { throw HLSSourceError.network }
        try HLSProxyHTTP.validateEncoding(http.value(forHTTPHeaderField: "Content-Encoding"))
        var rangeHeader = ""
        let expected: Int64?
        if http.statusCode == 206 {
            guard let range, let value = http.value(forHTTPHeaderField: "Content-Range") else { throw HLSSourceError.network }
            let parsed = try HLSProxyHTTP.contentRange(value)
            guard let total = Int(exactly: parsed.total),
                  case let .single(selected) = try HTTPRange.parse(range, resourceLength: total),
                  Int64(selected.lowerBound) == parsed.first,
                  Int64(selected.upperBound - 1) == parsed.last else { throw HLSSourceError.network }
            expected = parsed.last - parsed.first + 1
            rangeHeader = "Content-Range: \(value)\r\n"
            if response.expectedContentLength >= 0, response.expectedContentLength != expected { throw HLSSourceError.network }
        } else if http.statusCode == 416 {
            guard let range, let value = http.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes */"),
                  let total = Int(value.dropFirst(8)), total >= 0,
                  case .unsatisfied = try HTTPRange.parse(range, resourceLength: total) else { throw HLSSourceError.network }
            rangeHeader = "Content-Range: bytes */\(total)\r\n"
            expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        } else {
            expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        }
        let chunked = expected == nil && method != .head
        let framing = expected.map { "Content-Length: \($0)\r\n" } ?? (chunked ? "Transfer-Encoding: chunked\r\n" : "")
        let mime = http.mimeType ?? "application/octet-stream"
        guard mime.utf8.count <= 128, mime.utf8.allSatisfy({ (32...126).contains($0) }) else { throw HLSSourceError.byteLimit }
        return ResponseHead(
            bytes: Data("HTTP/1.1 \(http.statusCode) OK\r\n\(framing)\(rangeHeader)Content-Type: \(mime)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8),
            expected: expected,
            chunked: chunked
        )
    }
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
