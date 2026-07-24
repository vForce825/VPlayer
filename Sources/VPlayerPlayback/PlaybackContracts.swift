// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

public enum PlaybackFoundation { public static let contractVersion = 1 }

public struct PlaybackRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceProfileID: UUID
    public let channelID: String
    public let streamURL: URL
    public let title: String

    public init(sourceProfileID: UUID, channelID: String, streamURL: URL, title: String) {
        self.id = UUID()
        self.sourceProfileID = sourceProfileID
        self.channelID = channelID
        self.streamURL = streamURL
        self.title = title
    }

    public init(channel: Channel) {
        self.init(
            sourceProfileID: channel.sourceProfileID,
            channelID: channel.id,
            streamURL: channel.streamURL,
            title: channel.displayName
        )
    }
}

public struct PlaybackFailure: Error, Equatable, Sendable {
    public let code: String
    public let userMessage: String
    public let diagnosticCode: String?

    public init(
        code: String,
        userMessage: String,
        diagnosticCode: String? = nil
    ) {
        self.code = code
        self.userMessage = userMessage
        self.diagnosticCode = diagnosticCode
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing(PlaybackRequest)
    case playing(PlaybackRequest)
    case paused(PlaybackRequest)
    case stopped
    case failed(PlaybackFailure)
}

public struct PlaybackNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: String
    public let duration: Duration
    public let isFocusStealing: Bool

    public init(id: String, message: String, duration: Duration, isFocusStealing: Bool) {
        self.id = id
        self.message = message
        self.duration = duration
        self.isFocusStealing = isFocusStealing
    }
}

public protocol PlaybackEngine: Actor {
    func events() -> AsyncStream<PlaybackState>
    func notices() -> AsyncStream<PlaybackNotice>
    func play(_ request: PlaybackRequest) async
    func setPaused(_ paused: Bool) async
    func stop() async
    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm) async
}

public enum DeinterlaceAlgorithm: String, Codable, CaseIterable, Sendable {
    case appleTemporal
    case metalYADIF2x
}
