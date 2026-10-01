// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

protocol ChannelLogoDataLoading: Sendable {
    func data(for url: URL, maximumByteCount: Int) async -> Data?
}

actor LiveChannelLogoDataLoader: ChannelLogoDataLoading {
    private struct RemoteKey: Hashable, Sendable {
        let url: URL
        let maximumByteCount: Int
    }

    private struct RemoteRequest {
        let identifier: UUID
        var waiters: [UUID: CheckedContinuation<Data?, Never>]
        var task: Task<Void, Never>?
    }

    let downloader: any BoundedHTTPDownloading
    let fileManager: FileManager
    private let maximumConcurrentRemoteDownloads = 4
    private var remoteRequests: [RemoteKey: RemoteRequest] = [:]
    private var pendingRemoteKeys: [(key: RemoteKey, identifier: UUID)] = []
    private var activeRemoteDownloads = 0

    init(downloader: any BoundedHTTPDownloading, fileManager: FileManager) {
        self.downloader = downloader
        self.fileManager = fileManager
    }

    func data(for url: URL, maximumByteCount: Int) async -> Data? {
        guard maximumByteCount > 0 else { return nil }

        switch url.scheme?.lowercased() {
        case "http", "https":
            return await remoteData(for: url, maximumByteCount: maximumByteCount)
        case "file":
            return await localData(for: url, maximumByteCount: maximumByteCount)
        default:
            return nil
        }
    }

    private func remoteData(for url: URL, maximumByteCount: Int) async -> Data? {
        let key = RemoteKey(url: url, maximumByteCount: maximumByteCount)
        let waiter = UUID()
        let data: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
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
        return Task.isCancelled ? nil : data
    }

    private func cancelRemoteWaiter(_ waiter: UUID, for key: RemoteKey) {
        guard var request = remoteRequests[key],
              let continuation = request.waiters.removeValue(forKey: waiter) else {
            return
        }
        continuation.resume(returning: nil)
        if request.waiters.isEmpty {
            remoteRequests.removeValue(forKey: key)
            request.task?.cancel()
            // 排队项保留在数组中，由启动循环跳过，避免每次取消线性搬移数组。
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
                let data = await loadRemoteData(for: key)
                completeRemoteRequest(key, identifier: identifier, data: data)
            }
            remoteRequests[key] = request
        }
    }

    private func completeRemoteRequest(
        _ key: RemoteKey, identifier: UUID, data: Data?
    ) {
        activeRemoteDownloads -= 1
        if let request = remoteRequests[key], request.identifier == identifier {
            remoteRequests.removeValue(forKey: key)
            for continuation in request.waiters.values {
                continuation.resume(returning: data)
            }
        }
        startPendingRemoteDownloads()
    }

    private func loadRemoteData(for key: RemoteKey) async -> Data? {
        do {
            let resource = try await downloader.download(
                url: key.url,
                byteLimit: Int64(key.maximumByteCount)
            )
            defer { try? fileManager.removeItem(at: resource.temporaryFileURL) }
            guard resource.byteCount >= 0,
                  resource.byteCount <= Int64(key.maximumByteCount),
                  let data = try? Data(
                    contentsOf: resource.temporaryFileURL,
                    options: .mappedIfSafe
                  ),
                  data.count <= key.maximumByteCount,
                  !Task.isCancelled,
                  Int64(data.count) == resource.byteCount else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func localData(for url: URL, maximumByteCount: Int) async -> Data? {
        return await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= maximumByteCount,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count == fileSize,
                  data.count <= maximumByteCount else {
                return nil
            }
            return data
        }.value
    }
}
