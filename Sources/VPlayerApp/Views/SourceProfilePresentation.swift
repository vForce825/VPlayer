// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

enum ResourceRefreshStatusPresentation {
    static func timestamp(for status: ResourceRefreshStatus) -> Date? {
        switch status.state {
        case .never:
            nil
        case .refreshing, .failed:
            status.lastAttemptAt
        case .succeeded:
            status.lastSuccessAt
        }
    }

    static func text(for status: ResourceRefreshStatus) -> String {
        let label = switch status.state {
        case .never: "尚未刷新"
        case .refreshing: "正在刷新"
        case .succeeded: "刷新成功"
        case .failed: "刷新失败"
        }
        guard let date = timestamp(for: status) else { return label }
        return "\(label) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

enum SourceProfileURLPresentation {
    static func m3uURL(
        profile: SourceProfile,
        protectsAcceptanceValue: Bool
    ) -> String {
        if protectsAcceptanceValue { return "Protected URL configured" }
        return RedactedURL.string(profile.m3uURL)
    }
}

