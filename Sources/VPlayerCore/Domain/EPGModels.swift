// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct EPGChannel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayNames: [String]
    public let iconURL: URL?
}

public struct Programme: Identifiable, Equatable, Sendable {
    public let id: String
    public let xmltvChannelID: String
    public let start: Date
    public let stop: Date
    public let title: String
    public let subtitle: String?
    public let summary: String?
    public let categories: [String]
}

public struct ManualEPGMapping: Equatable, Sendable {
    public let sourceProfileID: UUID
    public let channelID: String
    public let xmltvChannelID: String
}
