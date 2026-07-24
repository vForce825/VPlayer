// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation

@MainActor
@Observable
public final class PlaybackSettingsStore {
    public static let storageKey = "playback.deinterlaceAlgorithm"
    private let defaults: UserDefaults
    @ObservationIgnored private var algorithmChangeHandler: (@MainActor (
        DeinterlaceAlgorithm
    ) -> Void)?

    public var deinterlaceAlgorithm: DeinterlaceAlgorithm {
        didSet {
            defaults.set(deinterlaceAlgorithm.rawValue, forKey: Self.storageKey)
            guard oldValue != deinterlaceAlgorithm else { return }
            algorithmChangeHandler?(deinterlaceAlgorithm)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.deinterlaceAlgorithm = defaults.string(forKey: Self.storageKey)
            .flatMap(DeinterlaceAlgorithm.init(rawValue:)) ?? .appleTemporal
    }

    public func setDeinterlaceAlgorithmChangeHandler(
        _ handler: @escaping @MainActor (DeinterlaceAlgorithm) -> Void
    ) {
        algorithmChangeHandler = handler
    }
}
