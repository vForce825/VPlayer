// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation

@MainActor
@Observable
public final class PlaybackSettingsStore {
    public static let videoBufferSecondsKey = "playback.videoBufferSeconds"
    public static let deinterlaceBufferFramesKey = "playback.deinterlaceBufferFrames"
    #if os(iOS)
    public static let forceLandscapePlaybackKey = "playback.forceLandscape"
    public var forceLandscapePlayback: Bool {
        didSet { defaults.set(forceLandscapePlayback, forKey: Self.forceLandscapePlaybackKey) }
    }
    #endif
    private let defaults: UserDefaults
    @ObservationIgnored private var tuningChangeHandler: (@MainActor (PlaybackTuning) -> Void)?
    @ObservationIgnored private var isRestoringDefaults = false

    public var videoBufferSeconds: Double {
        didSet {
            defaults.set(videoBufferSeconds, forKey: Self.videoBufferSecondsKey)
            guard oldValue != videoBufferSeconds, !isRestoringDefaults else { return }
            tuningChangeHandler?(tuning)
        }
    }

    public var deinterlaceBufferFrames: Int {
        didSet {
            defaults.set(deinterlaceBufferFrames, forKey: Self.deinterlaceBufferFramesKey)
            guard oldValue != deinterlaceBufferFrames, !isRestoringDefaults else { return }
            tuningChangeHandler?(tuning)
        }
    }

    public var tuning: PlaybackTuning {
        PlaybackTuning(
            videoBufferSeconds: videoBufferSeconds,
            deinterlaceBufferFrames: deinterlaceBufferFrames
        )
    }

    public var isAtDefaults: Bool {
        #if os(iOS)
        tuning == .default && !forceLandscapePlayback
        #else
        tuning == .default
        #endif
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `PlaybackTuning` rejects values outside its own choices, so reading a
        // key that was never written (0) or one left behind by an older build
        // lands on the default rather than on an unusable buffer.
        let storedTuning = PlaybackTuning(
            videoBufferSeconds: defaults.double(forKey: Self.videoBufferSecondsKey),
            deinterlaceBufferFrames: defaults.integer(forKey: Self.deinterlaceBufferFramesKey)
        )
        self.videoBufferSeconds = storedTuning.videoBufferSeconds
        self.deinterlaceBufferFrames = storedTuning.deinterlaceBufferFrames
        #if os(iOS)
        self.forceLandscapePlayback = defaults.bool(forKey: Self.forceLandscapePlaybackKey)
        #endif
    }

    public func setTuningChangeHandler(
        _ handler: @escaping @MainActor (PlaybackTuning) -> Void
    ) {
        tuningChangeHandler = handler
    }

    public func restoreDefaults() {
        guard !isAtDefaults else { return }
        let tuningChanged = tuning != .default
        // 两项一起通知播放引擎，避免恢复过程中应用一份中间设置。
        isRestoringDefaults = true
        videoBufferSeconds = PlaybackTuning.default.videoBufferSeconds
        deinterlaceBufferFrames = PlaybackTuning.default.deinterlaceBufferFrames
        #if os(iOS)
        forceLandscapePlayback = false
        #endif
        isRestoringDefaults = false
        if tuningChanged { tuningChangeHandler?(tuning) }
    }
}
