// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest

final class LongPlaybackAcceptanceTests: XCTestCase {
    private static let requiredConfigurationKeys = [
        "VPLAYER_ACCEPTANCE_M3U_URL",
        "VPLAYER_ACCEPTANCE_EPG_URL",
        "VPLAYER_ACCEPTANCE_CHANNEL",
        "VPLAYER_ACCEPTANCE_SECONDS",
    ]

    func testPlaybackDiagnosticStateParsesOnlySanitizedVocabulary() {
        XCTAssertEqual(AcceptancePlaybackDiagnosticState(value: "idle"), .idle)
        XCTAssertEqual(AcceptancePlaybackDiagnosticState(value: "preparing"), .preparing)
        XCTAssertEqual(AcceptancePlaybackDiagnosticState(value: "playing"), .playing)
        XCTAssertEqual(AcceptancePlaybackDiagnosticState(value: "paused"), .paused)
        XCTAssertEqual(AcceptancePlaybackDiagnosticState(value: "stopped"), .stopped)
        XCTAssertEqual(
            AcceptancePlaybackDiagnosticState(value: "failed:decoder.invalid-data"),
            .failed(code: "decoder.invalid-data")
        )
        XCTAssertNil(AcceptancePlaybackDiagnosticState(value: "failed:"))
        XCTAssertNil(AcceptancePlaybackDiagnosticState(value: "failed:https://secret"))
        XCTAssertNil(AcceptancePlaybackDiagnosticState(value: "playing:Secret Channel"))
    }

    func testEPGProgrammeCountRequiresAPositiveDecimalValue() {
        XCTAssertEqual(AcceptanceEPGProgrammeCount.positiveCount(from: "17255"), 17_255)
        XCTAssertNil(AcceptanceEPGProgrammeCount.positiveCount(from: "0"))
        XCTAssertNil(AcceptanceEPGProgrammeCount.positiveCount(from: "-1"))
        XCTAssertNil(AcceptanceEPGProgrammeCount.positiveCount(from: "not-a-count"))
        XCTAssertNil(AcceptanceEPGProgrammeCount.positiveCount(from: nil))
    }

    func testFailedPlaybackStateImmediatelyProducesSanitizedFailure() {
        XCTAssertThrowsError(try AcceptanceStableRouteFailureClassifier.validate(
            state: .failed(code: "demux.invalid-data")
        )) { error in
            XCTAssertEqual(
                error as? AcceptanceFailure,
                .playbackFailed(code: "demux.invalid-data")
            )
            XCTAssertEqual(
                String(describing: error),
                "acceptance playback failed code=demux.invalid-data"
            )
            XCTAssertFalse(String(describing: error).contains("五星体育"))
            XCTAssertFalse(String(describing: error).contains("http"))
        }
    }

    func testStableRouteTimeoutClassifiesPreparationAndMissingMetrics() throws {
        try AcceptanceStableRouteFailureClassifier.validate(state: .playing)
        XCTAssertEqual(
            AcceptanceStableRouteFailureClassifier.timeoutFailure(
                lastState: .preparing,
                didDecodeMetrics: false
            ),
            .preparationTimedOut
        )
        for state in [
            AcceptancePlaybackDiagnosticState.playing,
            AcceptancePlaybackDiagnosticState.paused,
        ] {
            XCTAssertEqual(
                AcceptanceStableRouteFailureClassifier.timeoutFailure(
                    lastState: state,
                    didDecodeMetrics: false
                ),
                .metricsUnavailable
            )
        }
        XCTAssertEqual(
            AcceptanceStableRouteFailureClassifier.timeoutFailure(
                lastState: .playing,
                didDecodeMetrics: true
            ),
            .stableRouteTimedOut
        )
    }

    func testSnapshotDeltaRejectsBadCurrentMinuteAfterGoodLongPrefix() {
        let previousPresented: UInt64 = 150_000
        let previousDropped: UInt64 = 100
        let currentPresented: UInt64 = 150_049
        let currentDropped: UInt64 = 102

        XCTAssertLessThan(
            Double(currentDropped) / Double(currentPresented + currentDropped),
            0.01,
            "The cumulative session ratio intentionally remains good"
        )
        XCTAssertThrowsError(try AcceptanceSnapshotValidator.validateCounterDelta(
            previousPresented: previousPresented,
            previousDropped: previousDropped,
            currentPresented: currentPresented,
            currentDropped: currentDropped
        )) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .dropRatioExceeded)
        }
    }

    func testNavigationGuardDoesNotReadFocusOrSelectWhenElementIsAbsent() {
        var didReadFocus = false
        var didSelect = false

        XCTAssertThrowsError(try AcceptanceNavigationGuard.selectIfReady(
            target: .playlistRefresh,
            exists: false,
            hasFocus: {
                didReadFocus = true
                return true
            }()
        ) {
            didSelect = true
        }) { error in
            XCTAssertEqual(
                error as? AcceptanceNavigationFailure,
                AcceptanceNavigationFailure(
                    target: .playlistRefresh,
                    phase: .awaitExistence
                )
            )
        }
        XCTAssertFalse(didReadFocus)
        XCTAssertFalse(didSelect)
    }

    func testNavigationGuardDoesNotSelectWhenFocusIsUnavailable() {
        var didSelect = false

        XCTAssertThrowsError(try AcceptanceNavigationGuard.selectIfReady(
            target: .sourceSave,
            exists: true,
            hasFocus: false
        ) {
            didSelect = true
        }) { error in
            XCTAssertEqual(
                error as? AcceptanceNavigationFailure,
                AcceptanceNavigationFailure(target: .sourceSave, phase: .acquireFocus)
            )
        }
        XCTAssertFalse(didSelect)
    }

    func testNavigationFailureDescriptionContainsOnlyRedactedTargetAndPhase() {
        let failure = AcceptanceNavigationFailure(
            target: .requestedChannel,
            phase: .acquireFocus
        )

        XCTAssertEqual(
            failure.description,
            "navigation target=requestedChannel phase=acquireFocus"
        )
        XCTAssertFalse(failure.description.contains("五星体育"))
        XCTAssertFalse(failure.description.contains("http"))
    }

    func testAcceptanceTabsHaveStableNavigationIndexes() {
        XCTAssertEqual(AcceptanceTab.channels.rawValue, 0)
        XCTAssertEqual(AcceptanceTab.sources.rawValue, 1)
        XCTAssertEqual(AcceptanceTab.settings.rawValue, 2)
    }

    func testSteadyStatePerformanceValidationRequiresAtLeastOneMinute() {
        XCTAssertFalse(AcceptanceValidationPolicy.requiresSteadyStatePerformance(
            duration: 59.999
        ))
        XCTAssertTrue(AcceptanceValidationPolicy.requiresSteadyStatePerformance(
            duration: 60
        ))
    }

    func testTabFocusNavigatorAcquiresNormalizesAndSelectsExactlyOnce() {
        var moves: [AcceptanceTabFocusMove] = []
        var selectCount = 0

        XCTAssertNoThrow(try AcceptanceTabFocusNavigator.focusAndSelect(
            tab: .settings,
            target: .settingsTab,
            anyTabHasFocus: { moves.filter { $0 == .up }.count >= 3 },
            targetHasFocus: { true },
            move: { moves.append($0) },
            select: { selectCount += 1 }
        ))
        XCTAssertEqual(
            moves,
            [.up, .up, .up, .left, .left, .left, .right, .right]
        )
        XCTAssertEqual(selectCount, 1)
    }

    func testTabFocusNavigatorStopsAfterEightUpPressesWithoutSelecting() {
        var moves: [AcceptanceTabFocusMove] = []
        var selectCount = 0

        XCTAssertThrowsError(try AcceptanceTabFocusNavigator.focusAndSelect(
            tab: .channels,
            target: .channelTab,
            anyTabHasFocus: { false },
            targetHasFocus: { true },
            move: { moves.append($0) },
            select: { selectCount += 1 }
        )) { error in
            XCTAssertEqual(
                error as? AcceptanceNavigationFailure,
                AcceptanceNavigationFailure(target: .channelTab, phase: .acquireFocus)
            )
        }
        XCTAssertEqual(moves, Array(repeating: .up, count: 8))
        XCTAssertEqual(selectCount, 0)
    }

    func testTabFocusNavigatorRequiresTargetFocusAfterIndexMoves() {
        var moves: [AcceptanceTabFocusMove] = []
        var selectCount = 0

        XCTAssertThrowsError(try AcceptanceTabFocusNavigator.focusAndSelect(
            tab: .sources,
            target: .sourceTab,
            anyTabHasFocus: { true },
            targetHasFocus: { false },
            move: { moves.append($0) },
            select: { selectCount += 1 }
        )) { error in
            XCTAssertEqual(
                error as? AcceptanceNavigationFailure,
                AcceptanceNavigationFailure(target: .sourceTab, phase: .acquireFocus)
            )
        }
        XCTAssertEqual(moves, [.left, .left, .left, .right])
        XCTAssertEqual(selectCount, 0)
    }

    func testVerticalFocusNavigatorStopsAsSoonAsTargetAcquiresFocus() {
        var focusChecks = [false, false, true]
        var moves: [AcceptanceVerticalFocusMove] = []

        XCTAssertNoThrow(try AcceptanceVerticalFocusNavigator.acquire(
            target: .playerSettings,
            direction: .up,
            targetHasFocus: { focusChecks.removeFirst() },
            move: { moves.append($0) }
        ))
        XCTAssertEqual(moves, [.up, .up])
    }

    func testVerticalFocusNavigatorFailsWithoutSelectingAfterBoundedMoves() {
        var moves: [AcceptanceVerticalFocusMove] = []

        XCTAssertThrowsError(try AcceptanceVerticalFocusNavigator.acquire(
            target: .playerSettings,
            direction: .down,
            targetHasFocus: { false },
            move: { moves.append($0) }
        )) { error in
            XCTAssertEqual(
                error as? AcceptanceNavigationFailure,
                AcceptanceNavigationFailure(
                    target: .playerSettings,
                    phase: .acquireFocus
                )
            )
        }
        XCTAssertEqual(
            moves,
            Array(repeating: .down, count: AcceptanceVerticalFocusNavigator.maximumMoves)
        )
    }

    func testTabNavigationGuardActivatesOnceEvenWhenDestinationWasAlreadyVisible() {
        var pressCount = 0
        var outcomeReadCount = 0

        XCTAssertNoThrow(try AcceptanceTabNavigationGuard.activateIfNeeded(
            target: .sourceTab,
            destinationReady: true,
            activateTab: { pressCount += 1 },
            destinationBecameReady: {
                outcomeReadCount += 1
                return true
            }
        ))
        XCTAssertEqual(pressCount, 1)
        XCTAssertEqual(outcomeReadCount, 1)
    }

    func testTabNavigationGuardPressesOnceThenRequiresDestinationSentinel() {
        var pressCount = 0
        var destinationReady = false

        XCTAssertNoThrow(try AcceptanceTabNavigationGuard.activateIfNeeded(
            target: .settingsTab,
            destinationReady: false,
            activateTab: {
                pressCount += 1
                destinationReady = true
            },
            destinationBecameReady: { destinationReady }
        ))
        XCTAssertEqual(pressCount, 1)
    }

    func testContentActivationSelectsExactlyOnceAndRequiresRealOutcome() {
        var selectCount = 0
        var outcomeReadCount = 0

        XCTAssertNoThrow(try AcceptanceContentActivationGuard.activate(
            target: .sourceAdd,
            exists: true,
            selection: { selectCount += 1 },
            outcome: {
                outcomeReadCount += 1
                return true
            }
        ))
        XCTAssertEqual(selectCount, 1)
        XCTAssertEqual(outcomeReadCount, 1)
    }

    func testContentActivationOutcomeFailureDoesNotRepeatSelect() {
        var selectCount = 0

        XCTAssertThrowsError(try AcceptanceContentActivationGuard.activate(
            target: .playlistRefresh,
            exists: true,
            selection: { selectCount += 1 },
            outcome: { false }
        )) { error in
            XCTAssertEqual(
                error as? AcceptanceNavigationFailure,
                AcceptanceNavigationFailure(
                    target: .playlistRefresh,
                    phase: .awaitDestination
                )
            )
        }
        XCTAssertEqual(selectCount, 1)
    }

    func testContentActivationMissingElementReadsNoOutcomeAndNeverSelects() {
        var selectCount = 0
        var didReadOutcome = false

        XCTAssertThrowsError(try AcceptanceContentActivationGuard.activate(
            target: .playerSettings,
            exists: false,
            selection: { selectCount += 1 },
            outcome: {
                didReadOutcome = true
                return true
            }
        )) { error in
            XCTAssertEqual(
                error as? AcceptanceNavigationFailure,
                AcceptanceNavigationFailure(
                    target: .playerSettings,
                    phase: .awaitExistence
                )
            )
        }
        XCTAssertEqual(selectCount, 0)
        XCTAssertFalse(didReadOutcome)
    }

    func testRefreshOutcomeSuccessTimestampSelectsExactlyOnce() {
        var selectCount = 0

        XCTAssertNoThrow(try AcceptanceRefreshOutcomeGuard.activate(
            exists: true,
            selection: { selectCount += 1 },
            outcome: {
                AcceptanceRefreshOutcomeGuard.classify(
                    editorVisible: false,
                    statusLabel: "刷新成功 · Jul 23, 2026 at 9:00 PM",
                    statusValue: nil
                )
            }
        ))
        XCTAssertEqual(selectCount, 1)
    }

    func testRefreshOutcomeWrongTargetIsImmediateAndRedacted() {
        var selectCount = 0

        XCTAssertThrowsError(try AcceptanceRefreshOutcomeGuard.activate(
            exists: true,
            selection: { selectCount += 1 },
            outcome: {
                AcceptanceRefreshOutcomeGuard.classify(
                    editorVisible: true,
                    statusLabel: "尚未刷新",
                    statusValue: nil
                )
            }
        )) { error in
            let failure = error as? AcceptanceNavigationFailure
            XCTAssertEqual(
                failure,
                AcceptanceNavigationFailure(
                    target: .playlistRefreshOutcome,
                    phase: .wrongTarget
                )
            )
            XCTAssertEqual(
                failure?.description,
                "navigation target=playlistRefreshOutcome phase=wrongTarget"
            )
            XCTAssertFalse(failure?.description.contains("http") ?? true)
            XCTAssertFalse(failure?.description.contains("五星体育") ?? true)
        }
        XCTAssertEqual(selectCount, 1)
    }

    func testRefreshOutcomeFailedValueIsImmediateAndRedacted() {
        var selectCount = 0

        XCTAssertThrowsError(try AcceptanceRefreshOutcomeGuard.activate(
            exists: true,
            selection: { selectCount += 1 },
            outcome: {
                AcceptanceRefreshOutcomeGuard.classify(
                    editorVisible: false,
                    statusLabel: "",
                    statusValue: "刷新失败 · Jul 23, 2026 at 9:00 PM"
                )
            }
        )) { error in
            let failure = error as? AcceptanceNavigationFailure
            XCTAssertEqual(
                failure,
                AcceptanceNavigationFailure(
                    target: .playlistRefreshOutcome,
                    phase: .refreshFailure
                )
            )
            XCTAssertEqual(
                failure?.description,
                "navigation target=playlistRefreshOutcome phase=refreshFailure"
            )
            XCTAssertFalse(failure?.description.contains("http") ?? true)
            XCTAssertFalse(failure?.description.contains("五星体育") ?? true)
        }
        XCTAssertEqual(selectCount, 1)
    }

    @MainActor
    func testRealNetworkSourceAndEPGImport() throws {
        let configuration = try acceptanceConfiguration()
        let app = XCUIApplication()
        app.launchArguments = ["-acceptance-playback", "-uiTestResetPlaybackSettings"]
        app.launchEnvironment = configuration.encodedEnvironment
        app.launch()

        try importPrefilledProfile(in: app)
        let firstChannelButton = app.buttons.containing(
            .staticText,
            identifier: AcceptanceConfiguration.firstChannelName
        ).element
        try selectTab(
            .channels,
            target: .channelTab,
            destination: firstChannelButton,
            in: app
        )
        XCTAssertTrue(firstChannelButton.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["东方卫视 4K"].exists)
        XCTAssertTrue(app.staticTexts["五星体育 HD"].exists)
    }

    func testAsyncContentActivationPreservesOutcomeFailure() async throws {
        let diagnostic = AcceptanceFailure.playbackFailed(code: "video.decode.status.-12909")

        do {
            try await AcceptanceContentActivationGuard.activateAsync(
                target: .playerSettings,
                exists: true,
                selection: {},
                outcome: { throw diagnostic }
            )
            XCTFail("Expected the diagnostic failure to be rethrown")
        } catch let failure as AcceptanceFailure {
            XCTAssertEqual(failure.description, diagnostic.description)
        }
    }

    @MainActor
    func testLongRunningRealDevicePlayback() async throws {
        let configuration = try acceptanceConfiguration()
        let app = XCUIApplication()
        app.launchArguments = ["-acceptance-playback", "-uiTestResetPlaybackSettings"]
        app.launchEnvironment = configuration.encodedEnvironment
        app.launch()

        try importPrefilledProfile(in: app)
        let channelButton = app.buttons.containing(
            .staticText,
            identifier: configuration.channel
        ).element
        try selectTab(
            .channels,
            target: .channelTab,
            destination: channelButton,
            in: app
        )
        let firstChannelButton = app.buttons.containing(
            .staticText,
            identifier: AcceptanceConfiguration.firstChannelName
        ).element
        guard channelButton.waitForExistence(timeout: 90),
              firstChannelButton.waitForExistence(timeout: 10) else {
            throw AcceptanceNavigationFailure(
                target: .requestedChannel,
                phase: .awaitExistence
            )
        }
        guard let channelOffset = configuration.channelOffsetFromFirst else {
            throw AcceptanceNavigationFailure(
                target: .requestedChannel,
                phase: .acquireFocus
            )
        }
        // The browser lays a group's channels out left-to-right in a grid, so
        // the acceptance channels (all in the playlist's first group and within
        // one grid row) are reached with horizontal presses from the first one.
        for _ in 0..<channelOffset {
            XCUIRemote.shared.press(.right)
        }
        let fullScreenPlayer = app.otherElements["player-full-screen"]
        try activateContent(channelButton, target: .requestedChannel) {
            fullScreenPlayer.waitForExistence(timeout: 30)
        }

        let stateElement = app.otherElements["player-acceptance-state"]
        guard stateElement.waitForExistence(timeout: 30) else {
            throw AcceptanceNavigationFailure(
                target: .acceptanceState,
                phase: .awaitExistence
            )
        }
        let metricsElement = app.otherElements["player-acceptance-metrics"]
        guard metricsElement.waitForExistence(timeout: 30) else {
            throw AcceptanceNavigationFailure(
                target: .acceptanceMetrics,
                phase: .awaitExistence
            )
        }
        _ = try await awaitStableRoute(
            from: metricsElement,
            stateElement: stateElement,
            timeout: .seconds(90)
        )

        let runBaseline = try await activeHeartbeat(
            after: -Double.infinity,
            metricsElement: metricsElement,
            in: app
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let requestedDuration = Duration.milliseconds(Int64(configuration.duration * 1_000))
        let end = startedAt.advanced(by: requestedDuration)
        var nextMinute = startedAt.advanced(by: .seconds(60))
        var lastObservedElapsed = runBaseline.elapsedSeconds
        var previousSteadySnapshot = runBaseline
        var snapshots: [AcceptanceMetricsSnapshot] = []

        while clock.now < end {
            let heartbeat = try await activeHeartbeat(
                after: lastObservedElapsed,
                metricsElement: metricsElement,
                in: app
            )
            lastObservedElapsed = heartbeat.elapsedSeconds
            if clock.now >= nextMinute {
                if let prior = snapshots.last {
                    XCTAssertGreaterThan(heartbeat.elapsedSeconds, prior.elapsedSeconds)
                }
                if AcceptanceValidationPolicy.requiresSteadyStatePerformance(
                    duration: configuration.duration
                ) {
                    assertSteadyStateCounterDelta(
                        from: previousSteadySnapshot,
                        to: heartbeat
                    )
                }
                try attach(heartbeat, elapsed: elapsedSeconds(from: startedAt, clock: clock))
                assertSteadyStateThresholds(heartbeat, configuration: configuration)
                snapshots.append(heartbeat)
                previousSteadySnapshot = heartbeat
                repeat {
                    nextMinute = nextMinute.advanced(by: .seconds(60))
                } while nextMinute <= clock.now
            }
            // Sampling is not free and is not neutral. Every heartbeat walks the
            // app's accessibility tree on its main thread, which is the thread
            // the display-link callback runs on, so a one-second cadence held
            // the measured presentation rate roughly a quarter below what the
            // app achieves unobserved. Ten seconds still proves liveness between
            // the per-minute assertions without deciding the result.
            try await clock.sleep(for: .seconds(10))
        }

        let final = try await activeHeartbeat(
            after: lastObservedElapsed,
            metricsElement: metricsElement,
            in: app
        )
        if let prior = snapshots.last {
            XCTAssertGreaterThan(final.elapsedSeconds, prior.elapsedSeconds)
        }
        if AcceptanceValidationPolicy.requiresSteadyStatePerformance(
            duration: configuration.duration
        ) {
            assertSteadyStateCounterDelta(from: previousSteadySnapshot, to: final)
        }
        try attach(final, elapsed: elapsedSeconds(from: startedAt, clock: clock))
        assertSteadyStateThresholds(final, configuration: configuration)
        snapshots.append(final)

        XCTAssertGreaterThanOrEqual(final.elapsedSeconds, configuration.duration)
        XCTAssertGreaterThanOrEqual(
            final.elapsedSeconds - runBaseline.elapsedSeconds,
            configuration.duration
        )
        try assertLongRunMemoryEvidence(snapshots, configuration: configuration)
    }

    private func acceptanceConfiguration() throws -> AcceptanceConfiguration {
        var decoded: [String: String] = [:]
        var encodedEnvironment: [String: String] = [:]
        for key in Self.requiredConfigurationKeys {
            let encodedKey = "\(key)_B64"
            guard let encoded = Bundle(for: Self.self).object(
                forInfoDictionaryKey: encodedKey
            ) as? String,
                !encoded.isEmpty,
                let data = Data(base64Encoded: encoded),
                let value = String(data: data, encoding: .utf8),
                !value.isEmpty else {
                throw XCTSkip("Long device acceptance requires protected bundle configuration")
            }
            decoded[key] = value
            encodedEnvironment[encodedKey] = encoded
        }

        let sourceText = try XCTUnwrap(decoded["VPLAYER_ACCEPTANCE_M3U_URL"])
        let sourceURL = try XCTUnwrap(URL(string: sourceText))
        XCTAssertTrue(["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""))
        let epgText = try XCTUnwrap(decoded["VPLAYER_ACCEPTANCE_EPG_URL"])
        let epgURL = try XCTUnwrap(URL(string: epgText))
        XCTAssertTrue(["http", "https"].contains(epgURL.scheme?.lowercased() ?? ""))
        let channel = try XCTUnwrap(decoded["VPLAYER_ACCEPTANCE_CHANNEL"])
        let duration = try XCTUnwrap(TimeInterval(decoded["VPLAYER_ACCEPTANCE_SECONDS"] ?? ""))
        XCTAssertGreaterThan(duration, 0)
        return AcceptanceConfiguration(
            encodedEnvironment: encodedEnvironment,
            channel: channel,
            duration: duration
        )
    }

    @MainActor
    private func importPrefilledProfile(in app: XCUIApplication) throws {
        let add = app.buttons["source.add"]
        let name = app.textFields["source.editor.name"]
        let m3u = app.textFields["source.editor.m3u"]
        let epg = app.textFields["source.editor.epg"]
        try selectTab(
            .sources,
            target: .sourceTab,
            destination: add,
            in: app
        )
        try activateContent(add, target: .sourceAdd) {
            name.waitForExistence(timeout: 5)
        }

        guard name.exists, m3u.exists, epg.exists else {
            throw AcceptanceNavigationFailure(
                target: .sourceEditor,
                phase: .awaitDestination
            )
        }
        XCTAssertFalse((name.value as? String)?.isEmpty ?? true)
        XCTAssertEqual(m3u.value as? String, "Protected URL configured")
        XCTAssertEqual(epg.value as? String, "Protected URL configured")
        let save = app.buttons["source.editor.save"]
        try activateContent(save, target: .sourceSave) {
            save.waitForNonExistence(timeout: 10)
        }

        let refresh = app.buttons["source.refresh.playlist"]
        guard refresh.waitForExistence(timeout: 10) else {
            throw AcceptanceNavigationFailure(
                target: .playlistRefresh,
                phase: .awaitExistence
            )
        }
        let refreshStatus = app.staticTexts["source.status.playlist"]
        let editor = app.textFields["source.editor.name"]
        try AcceptanceRefreshOutcomeGuard.activate(
            exists: refresh.exists,
            selection: {
                selectIdleRefresh(refresh, status: refreshStatus, editor: editor)
            },
            outcome: {
                waitForRefreshOutcome(
                    status: refreshStatus,
                    editor: editor,
                    timeout: 90
                )
            }
        )

        let epgRefresh = app.buttons["source.refresh.epg"]
        guard epgRefresh.waitForExistence(timeout: 10) else {
            throw AcceptanceNavigationFailure(
                target: .epgRefresh,
                phase: .awaitExistence
            )
        }
        let epgStatus = app.staticTexts["source.status.epg"]
        try AcceptanceRefreshOutcomeGuard.activate(
            target: .epgRefresh,
            outcomeTarget: .epgRefreshOutcome,
            exists: epgRefresh.exists,
            selection: {
                selectIdleRefresh(epgRefresh, status: epgStatus, editor: editor) {
                    XCUIRemote.shared.press(.down)
                }
            },
            outcome: {
                waitForRefreshOutcome(
                    status: epgStatus,
                    editor: editor,
                    timeout: 180
                )
            }
        )
        try waitForImportedEPGProgrammes(in: app, timeout: 30)
    }

    @MainActor
    private func waitForImportedEPGProgrammes(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws {
        let countElement = app.otherElements["source.acceptance.epg-programme-count"]
        let positiveCount = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                countElement.exists
                    && AcceptanceEPGProgrammeCount.positiveCount(from: countElement.value) != nil
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [positiveCount], timeout: timeout)
        guard result == .completed,
              AcceptanceEPGProgrammeCount.positiveCount(from: countElement.value) != nil else {
            throw AcceptanceNavigationFailure(
                target: .epgProgrammeImport,
                phase: .awaitDestination
            )
        }
    }

    @MainActor
    private func waitForRefreshOutcome(
        status: XCUIElement,
        editor: XCUIElement,
        timeout: TimeInterval
    ) -> AcceptanceRefreshOutcome {
        let terminal = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.refreshOutcome(status: status, editor: editor) != .pending
            },
            object: nil
        )
        _ = XCTWaiter.wait(for: [terminal], timeout: timeout)
        return refreshOutcome(status: status, editor: editor)
    }

    /// Saving a playlist fetches it right away, so by the time the screen is up
    /// there is usually nothing to press: the button is disabled while that
    /// fetch runs and the status is already terminal once it lands. Pressing it
    /// anyway would only queue a duplicate download of the same resource.
    @MainActor
    private func selectIdleRefresh(
        _ button: XCUIElement,
        status: XCUIElement,
        editor: XCUIElement,
        acquireFocus: () -> Void = {}
    ) {
        guard button.isEnabled,
              refreshOutcome(status: status, editor: editor) == .pending else { return }
        acquireFocus()
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func refreshOutcome(
        status: XCUIElement,
        editor: XCUIElement
    ) -> AcceptanceRefreshOutcome {
        let statusExists = status.exists
        return AcceptanceRefreshOutcomeGuard.classify(
            editorVisible: editor.exists,
            statusLabel: statusExists ? status.label : "",
            statusValue: statusExists ? status.value as? String : nil
        )
    }

    @MainActor
    private func awaitStableRoute(
        from element: XCUIElement,
        stateElement: XCUIElement,
        timeout: Duration
    ) async throws -> AcceptanceMetricsSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastState: AcceptancePlaybackDiagnosticState?
        var didDecodeMetrics = false
        var lastSnapshot: AcceptanceMetricsSnapshot?
        while clock.now < deadline {
            let state = try playbackState(from: stateElement)
            try AcceptanceStableRouteFailureClassifier.validate(state: state)
            lastState = state
            if let snapshot = try? snapshot(from: element) {
                didDecodeMetrics = true
                lastSnapshot = snapshot
                if state == .playing,
                   snapshot.scanType != "unknown",
                   snapshot.activeRoute != "rawWhileClassifying",
                   routeMatches(snapshot) {
                    return snapshot
                }
            }
            try await clock.sleep(for: .milliseconds(500))
        }
        if let lastSnapshot {
            try attach(lastSnapshot, name: "playback-metrics-timeout.json")
        }
        throw AcceptanceStableRouteFailureClassifier.timeoutFailure(
            lastState: lastState,
            didDecodeMetrics: didDecodeMetrics
        )
    }

    @MainActor
    private func activeHeartbeat(
        after previousElapsed: Double,
        metricsElement: XCUIElement,
        in app: XCUIApplication
    ) async throws -> AcceptanceMetricsSnapshot {
        try assertActiveControls(in: app)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while clock.now < deadline {
            if let candidate = try? snapshot(from: metricsElement),
               candidate.elapsedSeconds > previousElapsed {
                XCTAssertGreaterThan(candidate.decoderCallbacksPerSecond, 0)
                XCTAssertGreaterThan(candidate.presentationsPerSecond, 0)
                XCTAssertGreaterThan(candidate.residentMemoryBytes, 0)
                return candidate
            }
            try await clock.sleep(for: .milliseconds(500))
        }
        throw AcceptanceFailure.metricsDidNotAdvance
    }

    @MainActor
    private func assertActiveControls(in app: XCUIApplication) throws {
        guard app.otherElements["player-full-screen"].exists,
              app.buttons["player-play-pause"].exists,
              app.buttons["player-settings"].exists,
              app.buttons.matching(identifier: "player-retry").count == 0 else {
            throw AcceptanceNavigationFailure(
                target: .activePlayerControls,
                phase: .awaitExistence
            )
        }
    }

    @MainActor
    private func selectTab(
        _ requestedTab: AcceptanceTab,
        target: AcceptanceNavigationTarget,
        destination: XCUIElement,
        in app: XCUIApplication
    ) throws {
        let tab = app.tabBars.buttons[requestedTab.name]
        let tabs = AcceptanceTab.allCases.map { app.tabBars.buttons[$0.name] }
        try AcceptanceTabNavigationGuard.activateIfNeeded(
            target: target,
            destinationReady: destination.exists,
            activateTab: {
                guard tab.waitForExistence(timeout: 10) else {
                    throw AcceptanceNavigationFailure(
                        target: target,
                        phase: .awaitExistence
                    )
                }
                try AcceptanceTabFocusNavigator.focusAndSelect(
                    tab: requestedTab,
                    target: target,
                    anyTabHasFocus: {
                        tabs.contains(where: \.hasFocus)
                    },
                    targetHasFocus: { tab.hasFocus },
                    move: { move in
                        switch move {
                        case .up:
                            XCUIRemote.shared.press(.up)
                        case .left:
                            XCUIRemote.shared.press(.left)
                        case .right:
                            XCUIRemote.shared.press(.right)
                        }
                    },
                    select: { XCUIRemote.shared.press(.select) }
                )
            },
            destinationBecameReady: {
                destination.waitForExistence(timeout: 10)
            }
        )
    }

    @MainActor
    private func snapshot(from element: XCUIElement) throws -> AcceptanceMetricsSnapshot {
        guard let json = element.value as? String,
              !json.isEmpty,
              json != "unavailable",
              let data = json.data(using: .utf8) else {
            throw AcceptanceFailure.metricsUnavailable
        }
        return try JSONDecoder().decode(AcceptanceMetricsSnapshot.self, from: data)
    }

    @MainActor
    private func playbackState(
        from element: XCUIElement
    ) throws -> AcceptancePlaybackDiagnosticState {
        guard let value = element.value as? String,
              let state = AcceptancePlaybackDiagnosticState(value: value) else {
            throw AcceptanceFailure.playbackStateUnavailable
        }
        return state
    }

    private func attach(_ snapshot: AcceptanceMetricsSnapshot, elapsed: Double) throws {
        try attach(
            snapshot,
            name: String(format: "playback-metrics-%06.0f-seconds.json", elapsed)
        )
    }

    private func attach(_ snapshot: AcceptanceMetricsSnapshot, name: String) throws {
        let data = try JSONEncoder().encode(snapshot)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func activateContent(
        _ element: XCUIElement,
        target: AcceptanceNavigationTarget,
        outcome: () -> Bool
    ) throws {
        guard element.waitForExistence(timeout: 10) else {
            throw AcceptanceNavigationFailure(target: target, phase: .awaitExistence)
        }
        try AcceptanceContentActivationGuard.activate(
            target: target,
            exists: element.exists,
            selection: { XCUIRemote.shared.press(.select) },
            outcome: outcome
        )
    }

    private func routeMatches(_ snapshot: AcceptanceMetricsSnapshot) -> Bool {
        if ["progressive", "progressiveSegmentedFrame"].contains(snapshot.scanType) {
            return snapshot.activeRoute == "bypass"
        }
        guard snapshot.scanType == "interlaced" else { return false }
        return snapshot.activeRoute == "metalYADIF2x"
    }

    private func assertSteadyStateThresholds(
        _ snapshot: AcceptanceMetricsSnapshot,
        configuration: AcceptanceConfiguration
    ) {
        XCTAssertGreaterThan(snapshot.decoderCallbacksPerSecond, 0)
        XCTAssertGreaterThan(snapshot.presentationsPerSecond, 0)
        XCTAssertGreaterThan(snapshot.residentMemoryBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.maximumPresentationQueueDepth, 12)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 4)
        XCTAssertEqual(snapshot.crossGenerationPresentationCount, 0)
        XCTAssertGreaterThan(snapshot.presentedVideoFrames, 0)
        if snapshot.elapsedSeconds >= 60 {
            XCTAssertGreaterThanOrEqual(snapshot.windowDurationSeconds, 55)
            XCTAssertLessThanOrEqual(snapshot.windowDurationSeconds, 60.5)
        }

        XCTAssertGreaterThan(snapshot.presentedVideoFrames + snapshot.droppedVideoFrames, 0)
        let validatesSteadyStatePerformance =
            AcceptanceValidationPolicy.requiresSteadyStatePerformance(
                duration: configuration.duration
            )
        if validatesSteadyStatePerformance {
            XCTAssertLessThanOrEqual(snapshot.avDriftP95Milliseconds, 40)
            XCTAssertLessThanOrEqual(snapshot.maximumAbsoluteAVDriftMilliseconds, 100)
        }

        if configuration.channel == "东方卫视 4K" {
            XCTAssertEqual(snapshot.scanType, "progressive")
            XCTAssertEqual(snapshot.activeRoute, "bypass")
            XCTAssertEqual(snapshot.yadifKernelDispatchCount, 0)
            return
        }
        if ["东方卫视 HD", "五星体育 HD"].contains(configuration.channel) {
            XCTAssertEqual(snapshot.scanType, "interlaced")
        }
        guard snapshot.scanType == "interlaced" else { return }

        XCTAssertEqual(snapshot.activeRoute, "metalYADIF2x")
        XCTAssertGreaterThan(snapshot.yadifKernelDispatchCount, 0)
        XCTAssertGreaterThan(snapshot.gpuDurationP95Milliseconds, 0)
        if validatesSteadyStatePerformance {
            XCTAssertTrue((22...28).contains(snapshot.decoderCallbacksPerSecond))
            XCTAssertTrue((45...55).contains(snapshot.presentationsPerSecond))
            XCTAssertLessThanOrEqual(snapshot.gpuDurationP95Milliseconds, 16)
        }
    }

    private func assertSteadyStateCounterDelta(
        from previous: AcceptanceMetricsSnapshot,
        to current: AcceptanceMetricsSnapshot
    ) {
        XCTAssertNoThrow(try AcceptanceSnapshotValidator.validateCounterDelta(
            previousPresented: previous.presentedVideoFrames,
            previousDropped: previous.droppedVideoFrames,
            currentPresented: current.presentedVideoFrames,
            currentDropped: current.droppedVideoFrames
        ))
    }

    private func assertLongRunMemoryEvidence(
        _ snapshots: [AcceptanceMetricsSnapshot],
        configuration: AcceptanceConfiguration
    ) throws {
        guard configuration.duration >= 7_200 else { return }
        let baseline = try XCTUnwrap(snapshots.first { $0.elapsedSeconds >= 900 })
        XCTAssertGreaterThan(baseline.residentMemoryBytes, 0)
        let secondHour = snapshots.filter { $0.elapsedSeconds >= 3_600 }
        XCTAssertFalse(secondHour.isEmpty)
        XCTAssertTrue(secondHour.allSatisfy { $0.residentMemoryBytes > 0 })
        let secondHourMaximum = try XCTUnwrap(secondHour.map(\.residentMemoryBytes).max())
        let growth = secondHourMaximum > baseline.residentMemoryBytes
            ? secondHourMaximum - baseline.residentMemoryBytes
            : 0
        XCTAssertLessThanOrEqual(growth, 32 * 1_024 * 1_024)
    }

    private func elapsedSeconds(
        from start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Double {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }










}

private enum AcceptanceValidationError: Error, Equatable {
    case counterRegressed
    case emptyCounterDelta
    case dropRatioExceeded
}

private enum AcceptanceValidationPolicy {
    static func requiresSteadyStatePerformance(duration: TimeInterval) -> Bool {
        duration >= 60
    }
}

private enum AcceptanceSnapshotValidator {
    static func validateCounterDelta(
        previousPresented: UInt64,
        previousDropped: UInt64,
        currentPresented: UInt64,
        currentDropped: UInt64
    ) throws {
        guard currentPresented >= previousPresented,
              currentDropped >= previousDropped else {
            throw AcceptanceValidationError.counterRegressed
        }
        let presentedDelta = currentPresented - previousPresented
        let droppedDelta = currentDropped - previousDropped
        let denominator = Double(presentedDelta) + Double(droppedDelta)
        guard denominator > 0 else {
            throw AcceptanceValidationError.emptyCounterDelta
        }
        guard Double(droppedDelta) / denominator <= 0.01 else {
            throw AcceptanceValidationError.dropRatioExceeded
        }
    }

}

private enum AcceptanceFailure: Error, Equatable, CustomStringConvertible {
    case metricsUnavailable
    case metricsDidNotAdvance
    case stableRouteTimedOut
    case preparationTimedOut
    case playbackStateUnavailable
    case playbackFailed(code: String)

    var description: String {
        switch self {
        case .metricsUnavailable:
            "acceptance metrics unavailable"
        case .metricsDidNotAdvance:
            "acceptance metrics did not advance"
        case .stableRouteTimedOut:
            "acceptance route did not stabilize"
        case .preparationTimedOut:
            "acceptance playback preparation timed out"
        case .playbackStateUnavailable:
            "acceptance playback state unavailable"
        case let .playbackFailed(code):
            "acceptance playback failed code=\(code)"
        }
    }
}

private enum AcceptancePlaybackDiagnosticState: Equatable {
    case idle
    case preparing
    case playing
    case paused
    case stopped
    case failed(code: String)

    init?(value: String) {
        switch value {
        case "idle":
            self = .idle
        case "preparing":
            self = .preparing
        case "playing":
            self = .playing
        case "paused":
            self = .paused
        case "stopped":
            self = .stopped
        default:
            let prefix = "failed:"
            guard value.hasPrefix(prefix) else { return nil }
            let code = String(value.dropFirst(prefix.count))
            guard !code.isEmpty,
                  code.utf8.count <= 128,
                  code.utf8.allSatisfy(Self.isAllowedCodeByte) else { return nil }
            self = .failed(code: code)
        }
    }

    private static func isAllowedCodeByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")].contains(byte)
    }
}

private enum AcceptanceStableRouteFailureClassifier {
    static func validate(state: AcceptancePlaybackDiagnosticState) throws {
        if case let .failed(code) = state {
            throw AcceptanceFailure.playbackFailed(code: code)
        }
    }

    static func timeoutFailure(
        lastState: AcceptancePlaybackDiagnosticState?,
        didDecodeMetrics: Bool
    ) -> AcceptanceFailure {
        if lastState == .preparing {
            return .preparationTimedOut
        }
        if !didDecodeMetrics,
           lastState == .playing || lastState == .paused {
            return .metricsUnavailable
        }
        return .stableRouteTimedOut
    }
}

private enum AcceptanceTab: Int, CaseIterable {
    case channels = 0
    case sources = 1
    case settings = 2

    var name: String {
        switch self {
        case .channels: "频道"
        case .sources: "播放列表"
        case .settings: "设置"
        }
    }
}

private enum AcceptanceTabFocusMove: Equatable {
    case up
    case left
    case right
}

private enum AcceptanceVerticalFocusMove: Equatable {
    case up
    case down
}

private enum AcceptanceVerticalFocusNavigator {
    static let maximumMoves = 4

    static func acquire(
        target: AcceptanceNavigationTarget,
        direction: AcceptanceVerticalFocusMove,
        targetHasFocus: () -> Bool,
        move: (AcceptanceVerticalFocusMove) -> Void
    ) throws {
        if targetHasFocus() { return }
        for _ in 0..<maximumMoves {
            move(direction)
            if targetHasFocus() { return }
        }
        throw AcceptanceNavigationFailure(target: target, phase: .acquireFocus)
    }
}

private enum AcceptanceNavigationTarget: String, Equatable {
    case sourceTab
    case sourceAdd
    case sourceEditor
    case sourceSave
    case playlistRefresh
    case playlistRefreshOutcome
    case epgRefresh
    case epgRefreshOutcome
    case epgProgrammeImport
    case settingsTab
    case channelTab
    case requestedChannel
    case fullScreenPlayer
    case acceptanceState
    case acceptanceMetrics
    case playerSettings
    case activePlayerControls
}

private enum AcceptanceEPGProgrammeCount {
    static func positiveCount(from value: Any?) -> Int? {
        guard let text = value as? String,
              let count = Int(text),
              count > 0 else { return nil }
        return count
    }
}

private enum AcceptanceNavigationPhase: String, Equatable {
    case awaitExistence
    case acquireFocus
    case awaitDismissal
    case verifySelection
    case awaitDestination
    case wrongTarget
    case refreshFailure
}

private struct AcceptanceNavigationFailure: Error, Equatable, CustomStringConvertible {
    let target: AcceptanceNavigationTarget
    let phase: AcceptanceNavigationPhase

    var description: String {
        "navigation target=\(target.rawValue) phase=\(phase.rawValue)"
    }

}

private enum AcceptanceTabFocusNavigator {
    static let maximumFocusAcquisitionPresses = 8
    static let normalizationLeftPresses = 3

    static func focusAndSelect(
        tab: AcceptanceTab,
        target: AcceptanceNavigationTarget,
        anyTabHasFocus: () -> Bool,
        targetHasFocus: () -> Bool,
        move: (AcceptanceTabFocusMove) -> Void,
        select: () -> Void
    ) throws {
        var acquisitionPresses = 0
        while acquisitionPresses < maximumFocusAcquisitionPresses,
              !anyTabHasFocus() {
            move(.up)
            acquisitionPresses += 1
        }
        guard anyTabHasFocus() else {
            throw AcceptanceNavigationFailure(target: target, phase: .acquireFocus)
        }

        for _ in 0..<normalizationLeftPresses {
            move(.left)
        }
        for _ in 0..<tab.rawValue {
            move(.right)
        }

        guard targetHasFocus() else {
            throw AcceptanceNavigationFailure(target: target, phase: .acquireFocus)
        }
        select()
    }
}

private enum AcceptanceNavigationGuard {
    static func selectIfReady(
        target: AcceptanceNavigationTarget,
        exists: Bool,
        hasFocus: @autoclosure () -> Bool,
        selection: () -> Void
    ) throws {
        guard exists else {
            throw AcceptanceNavigationFailure(target: target, phase: .awaitExistence)
        }
        guard hasFocus() else {
            throw AcceptanceNavigationFailure(target: target, phase: .acquireFocus)
        }
        selection()
    }
}

private enum AcceptanceTabNavigationGuard {
    static func activateIfNeeded(
        target: AcceptanceNavigationTarget,
        destinationReady: Bool,
        activateTab: () throws -> Void,
        destinationBecameReady: () -> Bool
    ) throws {
        _ = destinationReady
        try activateTab()
        guard destinationBecameReady() else {
            throw AcceptanceNavigationFailure(
                target: target,
                phase: .awaitDestination
            )
        }
    }
}

private enum AcceptanceContentActivationGuard {
    static func activate(
        target: AcceptanceNavigationTarget,
        exists: Bool,
        selection: () -> Void,
        outcome: () -> Bool
    ) throws {
        guard exists else {
            throw AcceptanceNavigationFailure(target: target, phase: .awaitExistence)
        }
        selection()
        guard outcome() else {
            throw AcceptanceNavigationFailure(target: target, phase: .awaitDestination)
        }
    }

    @MainActor
    static func activateAsync(
        target: AcceptanceNavigationTarget,
        exists: Bool,
        selection: () -> Void,
        outcome: () async throws -> Bool
    ) async throws {
        guard exists else {
            throw AcceptanceNavigationFailure(target: target, phase: .awaitExistence)
        }
        selection()
        guard try await outcome() else {
            throw AcceptanceNavigationFailure(target: target, phase: .awaitDestination)
        }
    }
}

private enum AcceptanceRefreshOutcome: Equatable {
    case pending
    case success
    case wrongTarget
    case failed
}

private enum AcceptanceRefreshOutcomeGuard {
    static func classify(
        editorVisible: Bool,
        statusLabel: String,
        statusValue: String?
    ) -> AcceptanceRefreshOutcome {
        if editorVisible {
            return .wrongTarget
        }
        let statusText = statusLabel.isEmpty ? statusValue ?? "" : statusLabel
        if statusText.hasPrefix("刷新成功") {
            return .success
        }
        if statusText.hasPrefix("刷新失败") {
            return .failed
        }
        return .pending
    }

    static func activate(
        target: AcceptanceNavigationTarget = .playlistRefresh,
        outcomeTarget: AcceptanceNavigationTarget = .playlistRefreshOutcome,
        exists: Bool,
        selection: () -> Void,
        outcome: () -> AcceptanceRefreshOutcome
    ) throws {
        guard exists else {
            throw AcceptanceNavigationFailure(
                target: target,
                phase: .awaitExistence
            )
        }
        selection()
        switch outcome() {
        case .success:
            return
        case .wrongTarget:
            throw AcceptanceNavigationFailure(
                target: outcomeTarget,
                phase: .wrongTarget
            )
        case .failed:
            throw AcceptanceNavigationFailure(
                target: outcomeTarget,
                phase: .refreshFailure
            )
        case .pending:
            throw AcceptanceNavigationFailure(
                target: outcomeTarget,
                phase: .awaitDestination
            )
        }
    }
}

private struct AcceptanceConfiguration {
    static let firstChannelName = "东方卫视 HD"

    let encodedEnvironment: [String: String]
    let channel: String
    let duration: TimeInterval

    var channelOffsetFromFirst: Int? {
        switch channel {
        case "东方卫视 HD": 0
        case "东方卫视 4K": 1
        case "五星体育 HD": 2
        default: nil
        }
    }
}

private struct AcceptanceMetricsSnapshot: Codable {
    let scanType: String
    let activeRoute: String
    let decoderCallbacksPerSecond: Double
    let presentationsPerSecond: Double
    let yadifKernelDispatchCount: UInt64
    let staleGenerationDropCount: UInt64
    let droppedVideoFrames: UInt64
    let videoDropCountsBySource: [UInt64]
    let lastVideoDecodeFailure: String?
    let maximumPresentationQueueDepth: Int
    let maximumYADIFInFlightCount: Int
    let maximumYADIFInputDepth: Int
    let gpuDurationP95Milliseconds: Double
    let avDriftP95Milliseconds: Double
    let residentMemoryBytes: UInt64
    let elapsedSeconds: Double
    let windowDurationSeconds: Double
    let presentedVideoFrames: UInt64
    let maximumAbsoluteAVDriftMilliseconds: Double
    let crossGenerationPresentationCount: UInt64
    let audioRoute: String
    let audioReady: Bool
    let readinessOpen: Bool
    let retainedAudioCount: Int
    let retainedVideoCount: Int
    let audioFirstPTSSeconds: Double?
    let audioDurationSeconds: Double
    let videoFirstPTSSeconds: Double?
    let videoLatestPTSSeconds: Double?
    let audioRelativeVideoPruneCount: UInt64
    let readinessCycleID: UInt64
    let readinessCloseReasonCounts: [UInt64]
    let displayResumeCount: UInt64
    let clockTimeSeconds: Double?
    let videoResyncCount: UInt64
    let audioRecoveryCount: UInt64
    let renderTickCount: UInt64
    let renderSkippedInFlightCount: UInt64
    let displayLinkCallbackCount: UInt64
    let nativeDisplayIntervalMilliseconds: Double
    let missedDisplayLinkVSyncCount: UInt64
    let displayRefreshHz: Double
    let demuxQueueFullWaitSeconds: Double
    let demuxAdmitWaitSeconds: Double
    let playbackExecutorBusySeconds: Double
    let totalVideoDecodeSubmissionMilliseconds: Double
    let maximumOutstandingDecoderOutputs: Int
    let maximumDecodeSubmissionDepth: Int
    let maximumFramesBeingDecoded: Int
    let decoderSessionSummary: String?
    let demuxPacketCount: UInt64
    let videoAccessUnitCount: UInt64
    let audioSampleCount: UInt64
    let videoDecodeSubmissionCount: UInt64
    let maximumVideoDecodeSubmissionMilliseconds: Double
}
