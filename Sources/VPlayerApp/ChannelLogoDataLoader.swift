// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

protocol ChannelLogoDataLoading: Sendable {
    func data(for url: URL, maximumByteCount: Int) async -> Data?
}

struct LiveChannelLogoDataLoader: ChannelLogoDataLoading, @unchecked Sendable {
    let downloader: any BoundedHTTPDownloading
    let fileManager: FileManager

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
        do {
            let resource = try await downloader.download(
                url: url,
                byteLimit: Int64(maximumByteCount)
            )
            defer { try? fileManager.removeItem(at: resource.temporaryFileURL) }
            guard resource.byteCount >= 0,
                  resource.byteCount <= Int64(maximumByteCount),
                  let data = try? Data(
                    contentsOf: resource.temporaryFileURL,
                    options: .mappedIfSafe
                  ),
                  data.count <= maximumByteCount,
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
