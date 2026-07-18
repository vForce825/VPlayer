// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public final class URLSessionBoundedDownloader: NSObject,
    RemoteResourceDownloading,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private final class Transfer: @unchecked Sendable {
        let continuation: CheckedContinuation<DownloadedResource, any Error>
        let fileURL: URL
        let fileHandle: FileHandle
        let byteLimit: Int64
        var task: URLSessionDataTask?
        var byteCount: Int64 = 0
        var acceptedResponse = false
        var terminalError: (any Error)?

        init(
            continuation: CheckedContinuation<DownloadedResource, any Error>,
            fileURL: URL,
            fileHandle: FileHandle,
            byteLimit: Int64
        ) {
            self.continuation = continuation
            self.fileURL = fileURL
            self.fileHandle = fileHandle
            self.byteLimit = byteLimit
        }
    }

    private final class CancellationRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private let cancelTransfer: @Sendable (Int) -> Void
        private var taskID: Int?
        private var isCancelled = false

        init(cancelTransfer: @escaping @Sendable (Int) -> Void) {
            self.cancelTransfer = cancelTransfer
        }

        func register(taskID: Int) -> Bool {
            lock.withLock {
                self.taskID = taskID
                return isCancelled
            }
        }

        func cancel() {
            let registeredTaskID = lock.withLock { () -> Int? in
                isCancelled = true
                return taskID
            }
            if let registeredTaskID {
                cancelTransfer(registeredTaskID)
            }
        }
    }

    typealias ByteLimit = @Sendable (RemoteResourceRequest) -> Int64

    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let fileManager: FileManager
    private let downloadsDirectory: URL
    private let byteLimit: ByteLimit
    private var session: URLSession?
    private var transfers: [Int: Transfer] = [:]

    public override init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        self.configuration = configuration
        fileManager = .default
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPlayerDownloads", isDirectory: true)
        byteLimit = { $0.byteLimit }
        super.init()
    }

    init(
        configuration: URLSessionConfiguration,
        fileManager: FileManager = .default,
        downloadsDirectory: URL,
        byteLimit: @escaping ByteLimit = { $0.byteLimit }
    ) {
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        self.configuration = configuration
        self.fileManager = fileManager
        self.downloadsDirectory = downloadsDirectory
        self.byteLimit = byteLimit
        super.init()
    }

    public func download(_ request: RemoteResourceRequest) async throws -> DownloadedResource {
        guard Self.isRemoteHTTPURL(request.url) else {
            throw RemoteDownloadError.invalidResponse
        }

        let (fileURL, fileHandle) = try makeTemporaryFile()
        let cancellation = CancellationRegistration { [weak self] taskID in
            self?.cancelTransfer(taskID: taskID)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let transfer = Transfer(
                    continuation: continuation,
                    fileURL: fileURL,
                    fileHandle: fileHandle,
                    byteLimit: byteLimit(request)
                )
                let task = register(transfer: transfer, request: request)
                let wasCancelled = cancellation.register(taskID: task.taskIdentifier)
                task.resume()
                if wasCancelled {
                    cancelTransfer(taskID: task.taskIdentifier)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition: URLSession.ResponseDisposition = lock.withLock {
            guard let transfer = transfers[dataTask.taskIdentifier],
                  transfer.terminalError == nil else {
                return .cancel
            }
            guard let response = response as? HTTPURLResponse else {
                transfer.terminalError = RemoteDownloadError.invalidResponse
                return .cancel
            }
            guard Self.isRemoteHTTPURL(response.url) else {
                transfer.terminalError = RemoteDownloadError.invalidResponse
                return .cancel
            }
            guard (200..<300).contains(response.statusCode) else {
                transfer.terminalError = RemoteDownloadError.httpStatus(response.statusCode)
                return .cancel
            }
            if response.expectedContentLength >= 0,
               response.expectedContentLength > transfer.byteLimit {
                transfer.terminalError = RemoteDownloadError.responseTooLarge(
                    limit: transfer.byteLimit
                )
                return .cancel
            }
            transfer.acceptedResponse = true
            return .allow
        }
        completionHandler(disposition)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let shouldFollow = lock.withLock {
            guard let transfer = transfers[task.taskIdentifier],
                  transfer.terminalError == nil else { return false }
            guard Self.isRemoteHTTPURL(request.url) else {
                transfer.terminalError = RemoteDownloadError.invalidResponse
                return false
            }
            return true
        }
        completionHandler(shouldFollow ? request : nil)
        if !shouldFollow {
            task.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        enum DataAction {
            case ignore
            case cancel(URLSessionDataTask)
            case write(Transfer)
        }

        let action: DataAction = lock.withLock {
            guard let transfer = transfers[dataTask.taskIdentifier],
                  transfer.terminalError == nil,
                  transfer.acceptedResponse else { return .ignore }
            guard Int64(data.count) <= transfer.byteLimit - transfer.byteCount else {
                transfer.terminalError = RemoteDownloadError.responseTooLarge(
                    limit: transfer.byteLimit
                )
                return .cancel(dataTask)
            }
            transfer.byteCount += Int64(data.count)
            return .write(transfer)
        }
        switch action {
        case .ignore:
            break
        case let .cancel(task):
            task.cancel()
        case let .write(transfer):
            do {
                try transfer.fileHandle.write(contentsOf: data)
            } catch {
                failTransfer(taskID: dataTask.taskIdentifier, error: error)
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let completion: (Transfer?, URLSession?) = lock.withLock {
            let transfer = transfers.removeValue(forKey: task.taskIdentifier)
            let finishedSession: URLSession?
            if transfers.isEmpty, self.session === session {
                self.session = nil
                finishedSession = session
            } else {
                finishedSession = nil
            }
            return (transfer, finishedSession)
        }

        completion.1?.finishTasksAndInvalidate()
        guard let transfer = completion.0 else { return }
        let closeError: (any Error)?
        do {
            try transfer.fileHandle.close()
            closeError = nil
        } catch {
            closeError = error
        }

        let finalError = transfer.terminalError
            ?? normalizedCompletionError(error)
            ?? closeError
            ?? (transfer.acceptedResponse ? nil : RemoteDownloadError.invalidResponse)
        if let finalError {
            try? fileManager.removeItem(at: transfer.fileURL)
            transfer.continuation.resume(throwing: finalError)
        } else {
            transfer.continuation.resume(returning: DownloadedResource(
                temporaryFileURL: transfer.fileURL,
                byteCount: transfer.byteCount
            ))
        }
    }

    private func register(
        transfer: Transfer,
        request: RemoteResourceRequest
    ) -> URLSessionDataTask {
        lock.withLock {
            let activeSession: URLSession
            if let session {
                activeSession = session
            } else {
                let created = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                session = created
                activeSession = created
            }
            let task = activeSession.dataTask(with: URLRequest(url: request.url))
            transfer.task = task
            transfers[task.taskIdentifier] = transfer
            return task
        }
    }

    private func cancelTransfer(taskID: Int) {
        let task: URLSessionDataTask? = lock.withLock {
            guard let transfer = transfers[taskID] else { return nil }
            if transfer.terminalError == nil {
                transfer.terminalError = RemoteDownloadError.cancelled
            }
            return transfer.task
        }
        task?.cancel()
    }

    private func failTransfer(taskID: Int, error: any Error) {
        let task: URLSessionDataTask? = lock.withLock {
            guard let transfer = transfers[taskID] else { return nil }
            if transfer.terminalError == nil {
                transfer.terminalError = error
            }
            return transfer.task
        }
        task?.cancel()
    }

    private func normalizedCompletionError(_ error: (any Error)?) -> (any Error)? {
        guard let error else { return nil }
        if (error as? URLError)?.code == .cancelled
            || (error as NSError).domain == NSURLErrorDomain
                && (error as NSError).code == URLError.cancelled.rawValue {
            return RemoteDownloadError.cancelled
        }
        return error
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

    private static func isRemoteHTTPURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }
}
