// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

/// Single source of truth for turning a profile validation failure into user
/// text. Both the editor sheet and the model-level operation alert render the
/// same wording; only their fallback for non-validation errors differs.
enum SourceProfileValidationMessage {
    /// Returns the message for a known validation failure, or `nil` when the
    /// error is not a validation error and the caller should use its own text.
    static func text(for error: any Error) -> String? {
        switch error {
        case SourceProfileValidationError.emptyName:
            "请输入数据源名称。"
        case SourceProfileValidationError.invalidURL(field: .m3u):
            "请输入有效的 M3U 地址。"
        case SourceProfileValidationError.invalidURL(field: .epg):
            "请输入有效的 EPG 地址。"
        case SourceProfileValidationError.unsupportedURL(field: .m3u):
            "M3U 地址仅支持 HTTP 或 HTTPS。"
        case SourceProfileValidationError.unsupportedURL(field: .epg):
            "EPG 地址仅支持 HTTP 或 HTTPS。"
        default:
            nil
        }
    }
}
