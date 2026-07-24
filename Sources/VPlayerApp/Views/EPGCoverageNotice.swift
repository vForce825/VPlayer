// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Decides whether a stored EPG is worth warning about. An upstream XMLTV file
/// can import perfectly yet only describe days that already passed, which every
/// channel then reports as "暂无当前节目" with nothing pointing at the source.
enum EPGCoverageNotice {
    /// The end of EPG coverage to warn about, or nil when there is nothing to
    /// say: no programmes at all is already covered by the refresh status, and
    /// coverage reaching beyond `now` is simply working.
    static func staleCoverageEnd(
        coverageEnd: Date?,
        programmeCount: Int,
        now: Date
    ) -> Date? {
        guard programmeCount > 0, let coverageEnd, coverageEnd <= now else { return nil }
        return coverageEnd
    }

    static func text(staleCoverageEnd: Date) -> String {
        "节目单数据已过期，最新节目到 \(staleCoverageEnd.formatted(date: .abbreviated, time: .shortened))。请刷新或更换 EPG 地址。"
    }
}
