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

    func testBufferLengthsDefaultAndPersistAcrossLaunches() {
        let defaults = UserDefaults(suiteName: suite)!
        var store: PlaybackSettingsStore? = PlaybackSettingsStore(defaults: defaults)
        XCTAssertEqual(store?.videoBufferSeconds, PlaybackTuning.default.videoBufferSeconds)
        XCTAssertEqual(store?.videoBufferSeconds, 1)
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

    func testPreviouslySavedTwoSecondChoiceIsPreserved() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(2, forKey: PlaybackSettingsStore.videoBufferSecondsKey)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).videoBufferSeconds, 2)
    }

    func testRestoreDefaultsPersistsBothValuesAndNotifiesOnce() {
        let defaults = UserDefaults(suiteName: suite)!
        let store = PlaybackSettingsStore(defaults: defaults)
        store.videoBufferSeconds = 4
        store.deinterlaceBufferFrames = 16
        var observed: [PlaybackTuning] = []
        store.setTuningChangeHandler { observed.append($0) }

        store.restoreDefaults()
        store.restoreDefaults()

        XCTAssertEqual(observed, [.default])
        XCTAssertEqual(store.tuning, .default)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).tuning, .default)
        XCTAssertEqual(defaults.double(forKey: PlaybackSettingsStore.videoBufferSecondsKey), 1)
        XCTAssertEqual(defaults.integer(forKey: PlaybackSettingsStore.deinterlaceBufferFramesKey), 8)
    }

    #if os(iOS)
    func testForceLandscapeDefaultsOffPersistsAndDoesNotChangeEngineTuning() {
        let defaults = UserDefaults(suiteName: suite)!
        let store = PlaybackSettingsStore(defaults: defaults)
        XCTAssertFalse(store.forceLandscapePlayback)
        var observed: [PlaybackTuning] = []
        store.setTuningChangeHandler { observed.append($0) }

        store.forceLandscapePlayback = true

        XCTAssertTrue(PlaybackSettingsStore(defaults: defaults).forceLandscapePlayback)
        XCTAssertFalse(store.isAtDefaults)
        XCTAssertEqual(store.tuning, .default)
        XCTAssertTrue(observed.isEmpty)
    }

    func testRestoreDefaultsAlsoClearsForceLandscapeWithoutReconfiguringUnchangedBuffers() {
        let defaults = UserDefaults(suiteName: suite)!
        let store = PlaybackSettingsStore(defaults: defaults)
        store.forceLandscapePlayback = true
        var observed: [PlaybackTuning] = []
        store.setTuningChangeHandler { observed.append($0) }

        store.restoreDefaults()

        XCTAssertTrue(store.isAtDefaults)
        XCTAssertFalse(PlaybackSettingsStore(defaults: defaults).forceLandscapePlayback)
        XCTAssertTrue(observed.isEmpty)
    }
    #endif
}
