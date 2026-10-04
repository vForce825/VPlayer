// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public actor URLSessionBoundedDownloader:
    BoundedHTTPDownloading,
    RemoteResourceDownloading {
    
    private enum DownloadEvent: Sendable {
        case responseURL(URL)
        case data(Data)
    }

    private final class SingleDownloadDelegate: NSObject, URLSessionDataDelegate, Sendable {
        let byteLimit: Int64
        let continuation: AsyncThrowingStream<DownloadEvent, any Error>.Continuation
        
        init(byteLimit: Int64, continuation: AsyncThrowingStream<DownloadEvent, any Error>.Continuation) {
            self.byteLimit = byteLimit
            self.continuation = continuation
        }
        
        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let httpResponse = response as? HTTPURLResponse else {
                continuation.yield(with: .failure(RemoteDownloadError.invalidResponse))
                completionHandler(.cancel)
                return
            }
            guard let responseURL = httpResponse.url,
                  URLSessionBoundedDownloader.isRemoteHTTPURL(responseURL) else {
                continuation.yield(with: .failure(RemoteDownloadError.invalidResponse))
                completionHandler(.cancel)
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                continuation.yield(with: .failure(RemoteDownloadError.httpStatus(httpResponse.statusCode)))
                completionHandler(.cancel)
                return
            }
            if httpResponse.expectedContentLength >= 0,
               httpResponse.expectedContentLength > byteLimit {
                continuation.yield(with: .failure(RemoteDownloadError.responseTooLarge(limit: byteLimit)))
                completionHandler(.cancel)
                return
            }
            continuation.yield(.responseURL(responseURL))
            completionHandler(.allow)
        }
        
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard URLSessionBoundedDownloader.isRemoteHTTPURL(request.url) else {
                continuation.yield(with: .failure(RemoteDownloadError.invalidResponse))
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }
        
        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            continuation.yield(.data(data))
        }
        
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            if let error {
                let finalError = normalizedCompletionError(error)
                continuation.finish(throwing: finalError)
            } else {
                continuation.finish()
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
        
        let (stream, continuation) = AsyncThrowingStream<DownloadEvent, any Error>.makeStream()
        let delegate = SingleDownloadDelegate(byteLimit: byteLimit, continuation: continuation)
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request)
        sessionDelegate.register(delegate, for: task)
        defer { sessionDelegate.unregister(task) }
        
        return try await withTaskCancellationHandler {
            task.resume()
            var byteCount: Int64 = 0
            var responseURL: URL?
            do {
                for try await event in stream {
                    if Task.isCancelled {
                        throw RemoteDownloadError.cancelled
                    }
                    switch event {
                    case let .responseURL(url):
                        responseURL = url
                    case let .data(data):
                        guard responseURL != nil else { throw RemoteDownloadError.invalidResponse }
                        if byteCount + Int64(data.count) > byteLimit {
                            throw RemoteDownloadError.responseTooLarge(limit: byteLimit)
                        }
                        try fileHandle.write(contentsOf: data)
                        byteCount += Int64(data.count)
                    }
                }
                try fileHandle.close()
                if Task.isCancelled {
                    throw RemoteDownloadError.cancelled
                }
                guard let responseURL else { throw RemoteDownloadError.invalidResponse }
                return DownloadedResource(
                    temporaryFileURL: fileURL, byteCount: byteCount, responseURL: responseURL
                )
            } catch {
                task.cancel()
                continuation.finish()
                try? fileHandle.close()
                try? fileManager.removeItem(at: fileURL)
                throw error
            }
        } onCancel: {
            task.cancel()
            continuation.finish(throwing: RemoteDownloadError.cancelled)
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
