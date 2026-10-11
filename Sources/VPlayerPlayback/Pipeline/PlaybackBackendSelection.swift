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
        #if os(macOS)
        // 系统默认 AirPlay 音频设备仍由 Mac 音频 renderer 输出，不套用移动平台的长音频会话策略。
        return .sampleBuffer
        #else
        guard ports.contains(.airPlay) else { return .sampleBuffer }
        guard actualPolicy == .longFormAudio else {
            throw PlaybackBackendSelectionError.airPlayLongFormUnavailable
        }
        return .hlsAVPlayer
        #endif
    }
}
