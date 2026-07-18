// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum ProtocolRejection: Equatable, Sendable {
    case invalidAddress
    case multicastUnsupported
    case unsupportedScheme(String)

    public var userMessage: String {
        switch self {
        case .invalidAddress: "播放地址无效"
        case .multicastUnsupported: "首版暂不支持组播地址"
        case let .unsupportedScheme(scheme): "首版暂不支持 \(scheme) 协议"
        }
    }
}

public enum StreamProtocolDecision: Equatable, Sendable {
    case allowed
    case rejected(ProtocolRejection)
}

public enum StreamProtocolPolicy {
    public static func evaluate(_ url: URL) -> StreamProtocolDecision {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .rejected(.invalidAddress)
        }
        switch scheme {
        case "http", "https": return .allowed
        case "udp", "rtp": return .rejected(.multicastUnsupported)
        default: return .rejected(.unsupportedScheme(scheme))
        }
    }
}
