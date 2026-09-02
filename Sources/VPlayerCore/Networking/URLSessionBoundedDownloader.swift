// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public actor URLSessionBoundedDownloader:
    BoundedHTTPDownloading,
    RemoteResourceDownloading {
    
    private final class SingleDownloadDelegate: NSObject, URLSessionDataDelegate, Sendable {
        let byteLimit: Int64
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        
        init(byteLimit: Int64, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
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
            guard URLSessionBoundedDownloader.isRemoteHTTPURL(httpResponse.url) else {
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
            continuation.yield(data)
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
    
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let downloadsDirectory: URL
    
    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.configuration = configuration
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
        self.configuration = configuration
        self.fileManager = fileManager
        self.downloadsDirectory = downloadsDirectory
    }
    
    public func download(_ request: RemoteResourceRequest) async throws -> DownloadedResource {
        try await download(url: request.url, byteLimit: request.byteLimit)
    }
    
    public func download(url: URL, byteLimit: Int64) async throws -> DownloadedResource {
        guard byteLimit > 0, Self.isRemoteHTTPURL(url) else {
            throw RemoteDownloadError.invalidResponse
        }
        
        let (fileURL, fileHandle) = try makeTemporaryFile()
        
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let delegate = SingleDownloadDelegate(byteLimit: byteLimit, continuation: continuation)
        
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request)
        
        return try await withTaskCancellationHandler {
            task.resume()
            var byteCount: Int64 = 0
            do {
                for try await data in stream {
                    if Task.isCancelled {
                        throw RemoteDownloadError.cancelled
                    }
                    if byteCount + Int64(data.count) > byteLimit {
                        throw RemoteDownloadError.responseTooLarge(limit: byteLimit)
                    }
                    try fileHandle.write(contentsOf: data)
                    byteCount += Int64(data.count)
                }
                try fileHandle.close()
                if Task.isCancelled {
                    throw RemoteDownloadError.cancelled
                }
                return DownloadedResource(temporaryFileURL: fileURL, byteCount: byteCount)
            } catch {
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
