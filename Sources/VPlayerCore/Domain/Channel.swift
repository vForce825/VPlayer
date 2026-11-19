// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public enum ChannelIdentity {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    public static func make(profileID: UUID, streamURL: URL) -> String {
        var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        if let scheme = components?.scheme {
            components?.scheme = scheme.lowercased()
        }
        if let host = components?.host {
            components?.host = host.lowercased()
        }
        if (components?.scheme == "http" && components?.port == 80)
            || (components?.scheme == "https" && components?.port == 443) {
            components?.port = nil
        }
        components?.fragment = nil
        let normalized = components?.string ?? streamURL.absoluteString
        let digest = SHA256.hash(data: Data("\(profileID.uuidString)|\(normalized)".utf8))
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}

public struct Channel: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let sourceProfileID: UUID
    public let displayName: String
    public let streamURL: URL
    public let tvgID: String?
    public let tvgName: String?
    public let logoURL: URL?
    public let groupTitle: String?
    public let attributes: [String: String]
    public let order: Int

    public init(
        id: String,
        sourceProfileID: UUID,
        displayName: String,
        streamURL: URL,
        tvgID: String?,
        tvgName: String?,
        logoURL: URL?,
        groupTitle: String?,
        attributes: [String: String],
        order: Int
    ) {
        self.id = id
        self.sourceProfileID = sourceProfileID
        self.displayName = displayName
        self.streamURL = streamURL
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.logoURL = logoURL
        self.groupTitle = groupTitle
        self.attributes = attributes
        self.order = order
    }

    public init(
        sourceProfileID: UUID,
        displayName: String,
        streamURL: URL,
        tvgID: String?,
        tvgName: String?,
        logoURL: URL?,
        groupTitle: String?,
        attributes: [String: String],
        order: Int
    ) {
        self.init(
            id: ChannelIdentity.make(profileID: sourceProfileID, streamURL: streamURL),
            sourceProfileID: sourceProfileID,
            displayName: displayName,
            streamURL: streamURL,
            tvgID: tvgID,
            tvgName: tvgName,
            logoURL: logoURL,
            groupTitle: groupTitle,
            attributes: attributes,
            order: order
        )
    }
}
