// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

enum ChannelLogoLoadFailureKind: Equatable, Sendable {
    case transient
    case permanent
    case cancelled
}

enum ChannelLogoDataLoadResult: Equatable, Sendable {
    case data(Data)
    case failed(ChannelLogoLoadFailureKind)
}

protocol ChannelLogoDataLoading: Sendable {
    func data(for url: URL, maximumByteCount: Int) async -> Data?
    func loadData(for url: URL, maximumByteCount: Int) async -> ChannelLogoDataLoadResult
}

extension ChannelLogoDataLoading {
    func loadData(for url: URL, maximumByteCount: Int) async -> ChannelLogoDataLoadResult {
        if let data = await data(for: url, maximumByteCount: maximumByteCount) {
            return .data(data)
        }
        return Task.isCancelled ? .failed(.cancelled) : .failed(.transient)
    }
}

actor LiveChannelLogoDataLoader: ChannelLogoDataLoading {
    private struct RemoteKey: Hashable, Sendable {
        let url: URL
        let maximumByteCount: Int
    }

    private struct RemoteRequest {
        let identifier: UUID
        var waiters: [UUID: CheckedContinuation<ChannelLogoDataLoadResult, Never>]
        var task: Task<Void, Never>?
    }

    private enum RemoteBackend: Sendable {
        case boundedDownloader(any BoundedHTTPDownloading)
        case inMemoryHTTP(FastFailInMemoryLogoFetcher)
    }

    private let remoteBackend: RemoteBackend
    let fileManager: FileManager
    private let maximumConcurrentRemoteDownloads = 4
    private var remoteRequests: [RemoteKey: RemoteRequest] = [:]
    private var pendingRemoteKeys: [(key: RemoteKey, identifier: UUID)] = []
    private var activeRemoteDownloads = 0

    init(downloader: any BoundedHTTPDownloading, fileManager: FileManager) {
        self.remoteBackend = .boundedDownloader(downloader)
        self.fileManager = fileManager
    }

    private init(fetcher: FastFailInMemoryLogoFetcher) {
        self.remoteBackend = .inMemoryHTTP(fetcher)
        self.fileManager = .default
    }

    static func makeFastFail(
        configuration: URLSessionConfiguration? = nil
    ) -> LiveChannelLogoDataLoader {
        LiveChannelLogoDataLoader(
            fetcher: FastFailInMemoryLogoFetcher(configuration: configuration)
        )
    }

    func data(for url: URL, maximumByteCount: Int) async -> Data? {
        switch await loadData(for: url, maximumByteCount: maximumByteCount) {
        case let .data(data):
            return data
        case .failed:
            return nil
        }
    }

    func loadData(for url: URL, maximumByteCount: Int) async -> ChannelLogoDataLoadResult {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard maximumByteCount > 0 else { return .failed(.permanent) }

        switch url.scheme?.lowercased() {
        case "http", "https":
            return await remoteData(for: url, maximumByteCount: maximumByteCount)
        case "file":
            return await localData(for: url, maximumByteCount: maximumByteCount)
        default:
            return .failed(.permanent)
        }
    }

    private func remoteData(
        for url: URL,
        maximumByteCount: Int
    ) async -> ChannelLogoDataLoadResult {
        let key = RemoteKey(url: url, maximumByteCount: maximumByteCount)
        let waiter = UUID()
        let result: ChannelLogoDataLoadResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failed(.cancelled))
                    return
                }
                if var request = remoteRequests[key] {
                    request.waiters[waiter] = continuation
                    remoteRequests[key] = request
                } else {
                    let identifier = UUID()
                    remoteRequests[key] = RemoteRequest(
                        identifier: identifier, waiters: [waiter: continuation], task: nil
                    )
                    pendingRemoteKeys.append((key, identifier))
                    startPendingRemoteDownloads()
                }
            }
        } onCancel: {
            Task { await self.cancelRemoteWaiter(waiter, for: key) }
        }
        return Task.isCancelled ? .failed(.cancelled) : result
    }

    private func cancelRemoteWaiter(_ waiter: UUID, for key: RemoteKey) {
        guard var request = remoteRequests[key],
              let continuation = request.waiters.removeValue(forKey: waiter) else {
            return
        }
        continuation.resume(returning: .failed(.cancelled))
        if request.waiters.isEmpty {
            remoteRequests.removeValue(forKey: key)
            request.task?.cancel()
            if request.task == nil {
                // Cancelled queued work must not accumulate while all four
                // active downloads are slow or stalled.
                pendingRemoteKeys.removeAll { $0.identifier == request.identifier }
            }
        } else {
            remoteRequests[key] = request
        }
    }

    private func startPendingRemoteDownloads() {
        while activeRemoteDownloads < maximumConcurrentRemoteDownloads,
              !pendingRemoteKeys.isEmpty {
            let pending = pendingRemoteKeys.removeFirst()
            let key = pending.key
            guard var request = remoteRequests[key],
                  request.identifier == pending.identifier,
                  request.task == nil else {
                continue
            }
            let identifier = request.identifier
            activeRemoteDownloads += 1
            request.task = Task {
                let result = await loadRemoteData(for: key)
                completeRemoteRequest(key, identifier: identifier, result: result)
            }
            remoteRequests[key] = request
        }
    }

    private func completeRemoteRequest(
        _ key: RemoteKey, identifier: UUID, result: ChannelLogoDataLoadResult
    ) {
        activeRemoteDownloads -= 1
        if let request = remoteRequests[key], request.identifier == identifier {
            remoteRequests.removeValue(forKey: key)
            for continuation in request.waiters.values {
                continuation.resume(returning: result)
            }
        }
        startPendingRemoteDownloads()
    }

    private func loadRemoteData(for key: RemoteKey) async -> ChannelLogoDataLoadResult {
        switch remoteBackend {
        case let .inMemoryHTTP(fetcher):
            return await fetcher.fetch(url: key.url, maximumByteCount: key.maximumByteCount)
        case let .boundedDownloader(downloader):
            do {
                let resource = try await downloader.download(
                    url: key.url,
                    byteLimit: Int64(key.maximumByteCount)
                )
                defer { try? fileManager.removeItem(at: resource.temporaryFileURL) }
                guard !Task.isCancelled else { return .failed(.cancelled) }
                guard resource.byteCount >= 0,
                      resource.byteCount <= Int64(key.maximumByteCount),
                      let data = try? Data(
                        contentsOf: resource.temporaryFileURL,
                        options: .mappedIfSafe
                      ),
                      data.count <= key.maximumByteCount,
                      !Task.isCancelled,
                      Int64(data.count) == resource.byteCount else {
                    return Task.isCancelled ? .failed(.cancelled) : .failed(.permanent)
                }
                return .data(data)
            } catch {
                return .failed(Self.classifyDownloadError(error))
            }
        }
    }

    private static func classifyDownloadError(_ error: any Error) -> ChannelLogoLoadFailureKind {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if let downloadError = error as? RemoteDownloadError {
            switch downloadError {
            case .cancelled:
                return .cancelled
            case let .httpStatus(code):
                return (400..<500).contains(code) ? .permanent : .transient
            case .responseTooLarge, .invalidResponse:
                return .permanent
            }
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .cancelled
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == URLError.cancelled.rawValue {
            return .cancelled
        }
        return .transient
    }

    private func localData(
        for url: URL,
        maximumByteCount: Int
    ) async -> ChannelLogoDataLoadResult {
        await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return .failed(.cancelled) }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= maximumByteCount,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count == fileSize,
                  data.count <= maximumByteCount else {
                return Task.isCancelled ? .failed(.cancelled) : .failed(.permanent)
            }
            return .data(data)
        }.value
    }
}

private final class FastFailInMemoryLogoFetcher: Sendable {
    private final class SingleFetchDelegate: @unchecked Sendable {
        private let lock = NSLock()
        private let byteLimit: Int
        private let continuation: CheckedContinuation<ChannelLogoDataLoadResult, Never>
        private var acceptedResponse = false
        private var buffer = Data()
        private var finished = false

        init(
            byteLimit: Int,
            continuation: CheckedContinuation<ChannelLogoDataLoadResult, Never>
        ) {
            self.byteLimit = byteLimit
            self.continuation = continuation
        }

        func didReceive(response: URLResponse) -> URLSession.ResponseDisposition {
            lock.withLock {
                guard !finished else { return .cancel }
                guard let httpResponse = response as? HTTPURLResponse,
                      let url = httpResponse.url,
                      FastFailInMemoryLogoFetcher.isRemoteHTTPURL(url) else {
                    finishLocked(.failed(.permanent))
                    return .cancel
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let kind: ChannelLogoLoadFailureKind =
                        (400..<500).contains(httpResponse.statusCode) ? .permanent : .transient
                    finishLocked(.failed(kind))
                    return .cancel
                }
                guard httpResponse.expectedContentLength <= Int64(byteLimit) else {
                    finishLocked(.failed(.permanent))
                    return .cancel
                }
                acceptedResponse = true
                if httpResponse.expectedContentLength > 0,
                   httpResponse.expectedContentLength <= Int64(min(byteLimit, 512 * 1_024)) {
                    buffer.reserveCapacity(Int(httpResponse.expectedContentLength))
                }
                return .allow
            }
        }

        func shouldFollowRedirect(to request: URLRequest) -> Bool {
            lock.withLock {
                guard !finished else { return false }
                guard FastFailInMemoryLogoFetcher.isRemoteHTTPURL(request.url) else {
                    finishLocked(.failed(.permanent))
                    return false
                }
                return true
            }
        }

        func didReceive(data: Data) -> Bool {
            lock.withLock {
                guard !finished else { return true }
                guard acceptedResponse else {
                    finishLocked(.failed(.permanent))
                    return true
                }
                guard data.count <= byteLimit - buffer.count else {
                    finishLocked(.failed(.permanent))
                    return true
                }
                buffer.append(data)
                return false
            }
        }

        func didComplete(with error: (any Error)?) {
            lock.withLock {
                if let error {
                    if Self.isCancellation(error) {
                        finishLocked(.failed(.cancelled))
                    } else {
                        finishLocked(.failed(.transient))
                    }
                } else if acceptedResponse {
                    finishLocked(.data(buffer))
                } else {
                    finishLocked(.failed(.permanent))
                }
            }
        }

        func cancel() {
            lock.withLock {
                finishLocked(.failed(.cancelled))
            }
        }

        private func finishLocked(_ result: ChannelLogoDataLoadResult) {
            guard !finished else { return }
            finished = true
            buffer = Data()
            continuation.resume(returning: result)
        }

        private static func isCancellation(_ error: any Error) -> Bool {
            if error is CancellationError { return true }
            if let urlError = error as? URLError, urlError.code == .cancelled { return true }
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
        }
    }

    private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [Int: SingleFetchDelegate] = [:]

        func register(_ handler: SingleFetchDelegate, for task: URLSessionTask) {
            lock.withLock { handlers[task.taskIdentifier] = handler }
        }

        func unregister(_ task: URLSessionTask) {
            lock.withLock { _ = handlers.removeValue(forKey: task.taskIdentifier) }
        }

        private func handler(for task: URLSessionTask) -> SingleFetchDelegate? {
            lock.withLock { handlers[task.taskIdentifier] }
        }

        private func takeHandler(for task: URLSessionTask) -> SingleFetchDelegate? {
            lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
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
            completionHandler(handler.didReceive(response: response))
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let handler = handler(for: task) else {
                completionHandler(nil)
                return
            }
            let allowed = handler.shouldFollowRedirect(to: request)
            completionHandler(allowed ? request : nil)
            if !allowed { task.cancel() }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            if handler(for: dataTask)?.didReceive(data: data) == true {
                dataTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            takeHandler(for: task)?.didComplete(with: error)
        }
    }

    private let session: URLSession
    private let delegate: SessionDelegate

    init(configuration: URLSessionConfiguration? = nil) {
        let resolvedConfiguration: URLSessionConfiguration
        if let configuration {
            resolvedConfiguration = configuration
        } else {
            let ephemeral = URLSessionConfiguration.ephemeral
            ephemeral.waitsForConnectivity = false
            ephemeral.timeoutIntervalForRequest = 8
            ephemeral.timeoutIntervalForResource = 15
            ephemeral.urlCache = nil
            ephemeral.requestCachePolicy = .reloadIgnoringLocalCacheData
            ephemeral.httpShouldSetCookies = false
            ephemeral.httpCookieAcceptPolicy = .never
            resolvedConfiguration = ephemeral
        }
        let delegate = SessionDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: resolvedConfiguration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func fetch(url: URL, maximumByteCount: Int) async -> ChannelLogoDataLoadResult {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard Self.isRemoteHTTPURL(url), maximumByteCount > 0 else {
            return .failed(.permanent)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request)
        let box = LockedHandlerBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failed(.cancelled))
                    return
                }
                let handler = SingleFetchDelegate(
                    byteLimit: maximumByteCount,
                    continuation: continuation
                )
                box.set(handler)
                delegate.register(handler, for: task)
                task.resume()
            }
        } onCancel: {
            delegate.unregister(task)
            task.cancel()
            box.cancel()
        }
    }

    private final class LockedHandlerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: SingleFetchDelegate?
        private var cancelled = false

        func set(_ handler: SingleFetchDelegate) {
            let shouldCancel = lock.withLock { () -> Bool in
                self.handler = handler
                return cancelled
            }
            if shouldCancel {
                handler.cancel()
            }
        }

        func cancel() {
            let existing = lock.withLock { () -> SingleFetchDelegate? in
                cancelled = true
                return handler
            }
            existing?.cancel()
        }
    }

    private static func isRemoteHTTPURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
