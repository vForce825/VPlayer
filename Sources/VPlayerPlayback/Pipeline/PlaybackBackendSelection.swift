// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum PlaybackSessionAudioPolicy: Sendable, Equatable {
    case longFormAudio
    case `default`
}

enum PlaybackBackendSelectionError: Error, Sendable, Equatable {
    case airPlayLongFormUnavailable
}

enum PlaybackBackendSelection {
    static func select(
        ports: PlaybackRoutePorts,
        actualPolicy: PlaybackSessionAudioPolicy
    ) throws -> PlaybackBackendKind? {
        guard !ports.isEmpty else { return nil }
        guard ports.contains(.airPlay) else { return .sampleBuffer }
        guard actualPolicy == .longFormAudio else {
            throw PlaybackBackendSelectionError.airPlayLongFormUnavailable
        }
        return .hlsAVPlayer
    }
}
