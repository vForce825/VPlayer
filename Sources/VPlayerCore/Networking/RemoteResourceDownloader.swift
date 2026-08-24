// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct RemoteResourceRequest: Sendable {
    public let url: URL
    public let resource: RefreshResource

    public var byteLimit: Int64 {
        resource == .playlist ? 10 * 1_024 * 1_024 : 200 * 1_024 * 1_024
    }

    public init(url: URL, resource: RefreshResource) {
        self.url = url
        self.resource = resource
    }
}

public struct DownloadedResource: Sendable {
    public let temporaryFileURL: URL
    public let byteCount: Int64

    public init(temporaryFileURL: URL, byteCount: Int64) {
        self.temporaryFileURL = temporaryFileURL
        self.byteCount = byteCount
    }
}

public enum RemoteDownloadError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge(limit: Int64)
    case cancelled
}

public protocol BoundedHTTPDownloading: Sendable {
    func download(url: URL, byteLimit: Int64) async throws -> DownloadedResource
}

public protocol RemoteResourceDownloading: Sendable {
    func download(_ request: RemoteResourceRequest) async throws -> DownloadedResource
}
