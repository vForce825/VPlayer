// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public actor URLSessionBoundedDownloader:
    BoundedHTTPDownloading,
    RemoteResourceDownloading {
    
    // 文件句柄与终态共用一把锁，取消与 URLSession 回调不会同时写入或关闭文件。
    final class SingleDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let byteLimit: Int64
        private let fileURL: URL
        private let fileHandle: FileHandle
        private let continuation: AsyncThrowingStream<DownloadedResource, any Error>.Continuation
        private var responseURL: URL?
        private var byteCount: Int64 = 0
        private var finished = false

        init(
            byteLimit: Int64,
            fileURL: URL,
            fileHandle: FileHandle,
            continuation: AsyncThrowingStream<DownloadedResource, any Error>.Continuation
        ) {
            self.byteLimit = byteLimit
            self.fileURL = fileURL
            self.fileHandle = fileHandle
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let disposition: URLSession.ResponseDisposition = lock.withLock {
                guard !finished else { return .cancel }
                guard let httpResponse = response as? HTTPURLResponse,
                      let url = httpResponse.url,
                      URLSessionBoundedDownloader.isRemoteHTTPURL(url) else {
                    finishLocked(throwing: RemoteDownloadError.invalidResponse)
                    return .cancel
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    finishLocked(throwing: RemoteDownloadError.httpStatus(httpResponse.statusCode))
                    return .cancel
                }
                guard httpResponse.expectedContentLength <= byteLimit else {
                    finishLocked(throwing: RemoteDownloadError.responseTooLarge(limit: byteLimit))
                    return .cancel
                }
                responseURL = url
                return .allow
            }
            completionHandler(disposition)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let allowed = lock.withLock {
                guard !finished else { return false }
                guard URLSessionBoundedDownloader.isRemoteHTTPURL(request.url) else {
                    finishLocked(throwing: RemoteDownloadError.invalidResponse)
                    return false
                }
                return true
            }
            completionHandler(allowed ? request : nil)
            if !allowed { task.cancel() }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            let shouldCancel = lock.withLock {
                guard !finished else { return true }
                guard responseURL != nil else {
                    finishLocked(throwing: RemoteDownloadError.invalidResponse)
                    return true
                }
                // 在接收端检查实际字节数，包含没有 Content-Length 或解压后的正文。
                // 正文直接落盘，不在异步流中积压；减法比较也避免累计计数溢出。
                guard Int64(data.count) <= byteLimit - byteCount else {
                    finishLocked(throwing: RemoteDownloadError.responseTooLarge(limit: byteLimit))
                    return true
                }
                do {
                    try fileHandle.write(contentsOf: data)
                    byteCount += Int64(data.count)
                    return false
                } catch {
                    finishLocked(throwing: error)
                    return true
                }
            }
            if shouldCancel { dataTask.cancel() }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            lock.withLock {
                finishLocked(throwing: error.map(normalizedCompletionError))
            }
        }

        func cancel() {
            lock.withLock { finishLocked(throwing: RemoteDownloadError.cancelled) }
        }

        // 调用方须持锁；保留最先出现的错误，避免被随后到达的取消回调覆盖。
        private func finishLocked(throwing error: (any Error)?) {
            guard !finished else { return }
            finished = true
            var finalError = error
            do { try fileHandle.close() }
            catch { if finalError == nil { finalError = error } }
            if let finalError {
                continuation.finish(throwing: finalError)
            } else if let responseURL {
                continuation.yield(DownloadedResource(
                    temporaryFileURL: fileURL, byteCount: byteCount, responseURL: responseURL
                ))
                continuation.finish()
            } else {
                continuation.finish(throwing: RemoteDownloadError.invalidResponse)
            }
        }

        private func normalizedCompletionError(_ error: any Error) -> any Error {
            if (error as? URLError)?.code == .cancelled
                || (error as NSError).domain == NSURLErrorDomain
                    && (error as NSError).code == URLError.cancelled.rawValue {
                return RemoteDownloadError.cancelled
            }
            return error
        }
    }

    private final class SharedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [Int: SingleDownloadDelegate] = [:]

        func register(_ handler: SingleDownloadDelegate, for task: URLSessionTask) {
            lock.withLock { handlers[task.taskIdentifier] = handler }
        }

        func unregister(_ task: URLSessionTask) {
            lock.withLock { _ = handlers.removeValue(forKey: task.taskIdentifier) }
        }

        private func handler(for task: URLSessionTask) -> SingleDownloadDelegate? {
            lock.withLock { handlers[task.taskIdentifier] }
        }

        private func takeHandler(for task: URLSessionTask) -> SingleDownloadDelegate? {
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
            handler.urlSession(
                session, dataTask: dataTask, didReceive: response,
                completionHandler: completionHandler
            )
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
            handler.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: request, completionHandler: completionHandler
            )
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            handler(for: dataTask)?.urlSession(
                session, dataTask: dataTask, didReceive: data
            )
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            takeHandler(for: task)?.urlSession(
                session, task: task, didCompleteWithError: error
            )
        }
    }
    
    private let sessionDelegate: SharedSessionDelegate
    private let session: URLSession
    private let fileManager: FileManager
    private let downloadsDirectory: URL
    
    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let delegate = SharedSessionDelegate()
        sessionDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        fileManager = .default
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPlayerDownloads", isDirectory: true)
    }
    
    init(
        configuration: URLSessionConfiguration,
        fileManager: FileManager = .default,
        downloadsDirectory: URL
    ) {
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let delegate = SharedSessionDelegate()
        sessionDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.fileManager = fileManager
        self.downloadsDirectory = downloadsDirectory
    }

    deinit { session.invalidateAndCancel() }
    
    public func download(_ request: RemoteResourceRequest) async throws -> DownloadedResource {
        try await download(url: request.url, byteLimit: request.byteLimit)
    }
    
    public func download(url: URL, byteLimit: Int64) async throws -> DownloadedResource {
        guard byteLimit > 0, Self.isRemoteHTTPURL(url) else {
            throw RemoteDownloadError.invalidResponse
        }
        
        let (fileURL, fileHandle) = try makeTemporaryFile()
        
        // 异步流只传递一个完成结果，不承载下载正文。
        let (stream, continuation) = AsyncThrowingStream<DownloadedResource, any Error>
            .makeStream(bufferingPolicy: .bufferingOldest(1))
        let delegate = SingleDownloadDelegate(
            byteLimit: byteLimit, fileURL: fileURL, fileHandle: fileHandle,
            continuation: continuation
        )

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request)
        sessionDelegate.register(delegate, for: task)
        defer { sessionDelegate.unregister(task) }
        
        return try await withTaskCancellationHandler {
            task.resume()
            do {
                var iterator = stream.makeAsyncIterator()
                guard let result = try await iterator.next() else {
                    throw RemoteDownloadError.cancelled
                }
                guard !Task.isCancelled else { throw RemoteDownloadError.cancelled }
                return result
            } catch {
                task.cancel()
                delegate.cancel()
                try? fileManager.removeItem(at: fileURL)
                if Task.isCancelled { throw RemoteDownloadError.cancelled }
                throw error
            }
        } onCancel: {
            task.cancel()
            delegate.cancel()
        }
    }
    

    private func makeTemporaryFile() throws -> (URL, FileHandle) {
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = downloadsDirectory.appendingPathComponent(UUID().uuidString)
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            return (fileURL, try FileHandle(forWritingTo: fileURL))
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }
    
    fileprivate static func isRemoteHTTPURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }
}
