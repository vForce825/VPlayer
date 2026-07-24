// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#if DEBUG
import VPlayerPlayback

struct AcceptancePlaybackStatePresentation: Equatable, Sendable {
    let value: String

    init(state: PlaybackState) {
        value = switch state {
        case .idle:
            "idle"
        case .preparing:
            "preparing"
        case .playing:
            "playing"
        case .paused:
            "paused"
        case .stopped:
            "stopped"
        case let .failed(failure):
            "failed:\(failure.diagnosticCode ?? failure.code)"
        }
    }
}
#endif
