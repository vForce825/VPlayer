// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct PlaybackSessionID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct TemporalNoticeGate: Sendable {
    private var consumedSessionIDs: Set<PlaybackSessionID> = []

    public init() {}

    public mutating func consume(sessionID: PlaybackSessionID) -> Bool {
        consumedSessionIDs.insert(sessionID).inserted
    }
}

public extension PlaybackNotice {
    static let appleTemporalUnavailable = PlaybackNotice(
        id: "apple-temporal-unavailable",
        message: "Apple 反交错不可用，可在设置中切换到 Metal YADIF 2x。",
        duration: .seconds(3),
        isFocusStealing: false
    )
}
