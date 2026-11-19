// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum RefreshInterval: Int, Codable, CaseIterable, Sendable {
    case manual = 0
    case hourly = 3_600
    case sixHours = 21_600
    case twelveHours = 43_200
    case daily = 86_400

    public func isDue(lastSuccessAt: Date?, now: Date) -> Bool {
        guard self != .manual else { return false }
        guard let lastSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccessAt) >= TimeInterval(rawValue)
    }
}

public enum RefreshResource: String, Codable, CaseIterable, Hashable, Sendable {
    case playlist
    case epg
}

public enum RefreshState: String, Codable, Sendable {
    case never
    case refreshing
    case succeeded
    case failed
}

public struct ResourceRefreshStatus: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var state: RefreshState
    public var errorSummary: String?
    public var attemptID: UUID?
    public var consecutiveFailureCount: Int

    public init(
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        state: RefreshState = .never,
        errorSummary: String? = nil,
        attemptID: UUID? = nil,
        consecutiveFailureCount: Int = 0
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.state = state
        self.errorSummary = errorSummary
        self.attemptID = attemptID
        self.consecutiveFailureCount = consecutiveFailureCount
    }

    private enum CodingKeys: String, CodingKey {
        case lastAttemptAt
        case lastSuccessAt
        case state
        case errorSummary
        case attemptID
        case consecutiveFailureCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try values.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        state = try values.decode(RefreshState.self, forKey: .state)
        errorSummary = try values.decodeIfPresent(String.self, forKey: .errorSummary)
        attemptID = try values.decodeIfPresent(UUID.self, forKey: .attemptID)
        consecutiveFailureCount = try values.decodeIfPresent(
            Int.self,
            forKey: .consecutiveFailureCount
        ) ?? 0
    }
}
