// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
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

    func testDistinctAlgorithmChangesNotifyTheInstalledApplicationBinding() {
        let defaults = UserDefaults(suiteName: suite)!
        let store = PlaybackSettingsStore(defaults: defaults)
        var observed: [DeinterlaceAlgorithm] = []
        store.setDeinterlaceAlgorithmChangeHandler { observed.append($0) }

        store.deinterlaceAlgorithm = .metalYADIF2x
        store.deinterlaceAlgorithm = .metalYADIF2x
        store.deinterlaceAlgorithm = .appleTemporal

        XCTAssertEqual(observed, [.metalYADIF2x, .appleTemporal])
    }

    func testBufferLengthsDefaultAndPersistAcrossLaunches() {
        let defaults = UserDefaults(suiteName: suite)!
        var store: PlaybackSettingsStore? = PlaybackSettingsStore(defaults: defaults)
        XCTAssertEqual(store?.videoBufferSeconds, PlaybackTuning.default.videoBufferSeconds)
        XCTAssertEqual(store?.deinterlaceBufferFrames, 8)

        store?.videoBufferSeconds = 4
        store?.deinterlaceBufferFrames = 16
        store = PlaybackSettingsStore(defaults: defaults)

        XCTAssertEqual(store?.videoBufferSeconds, 4)
        XCTAssertEqual(store?.deinterlaceBufferFrames, 16)
        XCTAssertEqual(store?.tuning.videoBufferHorizon, CMTime(seconds: 4, preferredTimescale: 1_000))
    }

    // A key an older build never wrote reads back as zero, which would otherwise
    // become a zero-length buffer and stall playback outright.
    func testUnwrittenOrOutOfRangeBufferKeysFallBackToTheDefaults() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(37.5, forKey: PlaybackSettingsStore.videoBufferSecondsKey)
        defaults.set(-3, forKey: PlaybackSettingsStore.deinterlaceBufferFramesKey)

        let store = PlaybackSettingsStore(defaults: defaults)

        XCTAssertEqual(store.videoBufferSeconds, PlaybackTuning.default.videoBufferSeconds)
        XCTAssertEqual(store.deinterlaceBufferFrames, 8)
    }

    func testDistinctBufferChangesNotifyTheInstalledApplicationBinding() {
        let defaults = UserDefaults(suiteName: suite)!
        let store = PlaybackSettingsStore(defaults: defaults)
        var observed: [PlaybackTuning] = []
        store.setTuningChangeHandler { observed.append($0) }

        store.videoBufferSeconds = 4
        store.videoBufferSeconds = 4
        store.deinterlaceBufferFrames = 12

        XCTAssertEqual(observed, [
            PlaybackTuning(videoBufferSeconds: 4, deinterlaceBufferFrames: 8),
            PlaybackTuning(videoBufferSeconds: 4, deinterlaceBufferFrames: 12)
        ])
    }

    // The anchor is only meaningful relative to the buffer: anchoring further
    // back than the buffer spans overflows every arriving frame for the whole
    // session, so lengthening one has to lengthen the other.
    func testAnchorLagTracksTheConfiguredBufferLength() {
        for seconds in PlaybackTuning.videoBufferSecondsChoices {
            let tuning = PlaybackTuning(videoBufferSeconds: seconds)
            XCTAssertEqual(
                CMTimeGetSeconds(tuning.maximumAnchorLag),
                seconds * 0.5,
                accuracy: 0.001
            )
            XCTAssertLessThan(
                CMTimeGetSeconds(tuning.maximumAnchorLag),
                CMTimeGetSeconds(tuning.videoBufferHorizon)
            )
        }
    }
}
