// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

@MainActor
final class PlaybackSettingsStoreTests: XCTestCase {
    private let suite = "PlaybackSettingsStoreTests"

    override func setUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testDefaultsToAppleTemporalAndPersistsYADIF() {
        let defaults = UserDefaults(suiteName: suite)!
        var store: PlaybackSettingsStore? = PlaybackSettingsStore(defaults: defaults)
        XCTAssertEqual(store?.deinterlaceAlgorithm, .appleTemporal)
        store?.deinterlaceAlgorithm = .metalYADIF2x
        store = PlaybackSettingsStore(defaults: defaults)
        XCTAssertEqual(store?.deinterlaceAlgorithm, .metalYADIF2x)
    }

    func testUnknownStoredValueFallsBackToAppleTemporal() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("removed-mode", forKey: PlaybackSettingsStore.storageKey)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).deinterlaceAlgorithm, .appleTemporal)
    }
}
