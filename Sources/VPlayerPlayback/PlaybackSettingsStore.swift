// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation

@MainActor
@Observable
public final class PlaybackSettingsStore {
    public static let storageKey = "playback.deinterlaceAlgorithm"
    public static let videoBufferSecondsKey = "playback.videoBufferSeconds"
    public static let deinterlaceBufferFramesKey = "playback.deinterlaceBufferFrames"
    private let defaults: UserDefaults
    @ObservationIgnored private var algorithmChangeHandler: (@MainActor (
        DeinterlaceAlgorithm
    ) -> Void)?
    @ObservationIgnored private var tuningChangeHandler: (@MainActor (PlaybackTuning) -> Void)?

    public var deinterlaceAlgorithm: DeinterlaceAlgorithm {
        didSet {
            defaults.set(deinterlaceAlgorithm.rawValue, forKey: Self.storageKey)
            guard oldValue != deinterlaceAlgorithm else { return }
            algorithmChangeHandler?(deinterlaceAlgorithm)
        }
    }

    public var videoBufferSeconds: Double {
        didSet {
            defaults.set(videoBufferSeconds, forKey: Self.videoBufferSecondsKey)
            guard oldValue != videoBufferSeconds else { return }
            tuningChangeHandler?(tuning)
        }
    }

    public var deinterlaceBufferFrames: Int {
        didSet {
            defaults.set(deinterlaceBufferFrames, forKey: Self.deinterlaceBufferFramesKey)
            guard oldValue != deinterlaceBufferFrames else { return }
            tuningChangeHandler?(tuning)
        }
    }

    public var tuning: PlaybackTuning {
        PlaybackTuning(
            videoBufferSeconds: videoBufferSeconds,
            deinterlaceBufferFrames: deinterlaceBufferFrames
        )
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.deinterlaceAlgorithm = defaults.string(forKey: Self.storageKey)
            .flatMap(DeinterlaceAlgorithm.init(rawValue:)) ?? .appleTemporal
        // `PlaybackTuning` rejects values outside its own choices, so reading a
        // key that was never written (0) or one left behind by an older build
        // lands on the default rather than on an unusable buffer.
        let storedTuning = PlaybackTuning(
            videoBufferSeconds: defaults.double(forKey: Self.videoBufferSecondsKey),
            deinterlaceBufferFrames: defaults.integer(forKey: Self.deinterlaceBufferFramesKey)
        )
        self.videoBufferSeconds = storedTuning.videoBufferSeconds
        self.deinterlaceBufferFrames = storedTuning.deinterlaceBufferFrames
    }

    public func setDeinterlaceAlgorithmChangeHandler(
        _ handler: @escaping @MainActor (DeinterlaceAlgorithm) -> Void
    ) {
        algorithmChangeHandler = handler
    }

    public func setTuningChangeHandler(
        _ handler: @escaping @MainActor (PlaybackTuning) -> Void
    ) {
        tuningChangeHandler = handler
    }
}
