// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreAudio
import CryptoKit
import Foundation
import XCTest

#if !targetEnvironment(simulator)
private final class PrimingPCMInputContext {
    let channelPointers: [UnsafeRawPointer]
    let totalFrames: Int = 16_384
    var currentFrame: Int = 0

    init(channelPointers: [UnsafeRawPointer]) {
        self.channelPointers = channelPointers
    }
}

private func primingAudioConverterInputProc(
    _ inAudioConverter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }
    let context = Unmanaged<PrimingPCMInputContext>.fromOpaque(inUserData).takeUnretainedValue()
    let remaining = context.totalFrames - context.currentFrame
    let framesToProvide = min(Int(ioNumberDataPackets.pointee), remaining)
    ioNumberDataPackets.pointee = UInt32(framesToProvide)

    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    if framesToProvide > 0 {
        for ch in 0..<min(abl.count, context.channelPointers.count) {
            abl[ch].mNumberChannels = 1
            abl[ch].mDataByteSize = UInt32(framesToProvide * 4)
            abl[ch].mData = UnsafeMutableRawPointer(mutating: context.channelPointers[ch].advanced(by: context.currentFrame * 4))
        }
        context.currentFrame += framesToProvide
    } else {
        for ch in 0..<abl.count {
            abl[ch].mDataByteSize = 0
            abl[ch].mData = nil
        }
    }
    outDataPacketDescription?.pointee = nil
    return noErr
}
#endif

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
        XCTAssertEqual(AcceptancePlaybackDiagnosticState(value: "buffering"), .buffering)
        XCTAssertEqual(AcceptancePlaybackDiagnosticState(value: "recovering"), .recovering)
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
        for rawState in ["preparing", "buffering"] {
            let state = try XCTUnwrap(AcceptancePlaybackDiagnosticState(value: rawState))
            XCTAssertEqual(
                AcceptanceStableRouteFailureClassifier.timeoutFailure(
                    lastState: state,
                    didDecodeMetrics: false
                ),
                .preparationTimedOut
            )
        }
        XCTAssertEqual(
            AcceptanceStableRouteFailureClassifier.timeoutFailure(
                lastState: try XCTUnwrap(
                    AcceptancePlaybackDiagnosticState(value: "recovering")
                ),
                didDecodeMetrics: false
            ),
            .stableRouteTimedOut
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

    func testRuntimeValidationSeparatesSimulatorFunctionalityFromDevicePerformance() {
        let configuration = AcceptanceConfiguration(
            encodedEnvironment: [:],
            channel: "中天新闻",
            duration: 180
        )
        #if targetEnvironment(simulator)
        XCTAssertFalse(configuration.validatesSteadyStatePerformance)
        #else
        XCTAssertTrue(configuration.validatesSteadyStatePerformance)
        #endif
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

    @MainActor
    func testAirPlaySwitchesFromHDTo4KAfterPlayback() async throws {
        let configuration = try acceptanceConfiguration()
        let app = XCUIApplication()
        app.launchArguments = ["-acceptance-playback", "-uiTestResetPlaybackSettings"]
        app.launchEnvironment = configuration.encodedEnvironment
        app.launch()

        try importPrefilledProfile(in: app)
        let importedChannel = app.buttons.containing(
            .staticText,
            identifier: AcceptanceConfiguration.firstChannelName
        ).element
        try selectTab(
            .channels,
            target: .channelTab,
            destination: importedChannel,
            in: app
        )
        let hdChannel = app.buttons.containing(
            .staticText,
            identifier: "东方卫视 HD"
        ).element
        if importedChannel.hasFocus,
           AcceptanceConfiguration.firstChannelName == "东方卫视 4K" {
            XCUIRemote.shared.press(.left)
        }
        guard hdChannel.hasFocus else {
            throw AcceptanceNavigationFailure(
                target: .requestedChannel,
                phase: .acquireFocus
            )
        }
        let fullScreenPlayer = app.otherElements["player-full-screen"]
        try activateContent(hdChannel, target: .requestedChannel) {
            fullScreenPlayer.waitForExistence(timeout: 30)
        }

        let stateElement = app.otherElements["player-acceptance-state"]
        let metricsElement = app.otherElements["player-acceptance-metrics"]
        guard stateElement.waitForExistence(timeout: 30),
              metricsElement.waitForExistence(timeout: 30) else {
            throw AcceptanceNavigationFailure(
                target: .acceptanceMetrics,
                phase: .awaitExistence
            )
        }
        let hdSnapshot = try await awaitStableRoute(
            from: metricsElement,
            stateElement: stateElement,
            timeout: .seconds(90)
        )
        print("[ACCEPTANCE_SWITCH] first_route=\(hdSnapshot.audioRoute)")
        XCTAssertEqual(hdSnapshot.audioRoute, "airPlay", "客厅 Apple TV 当前必须使用 HomePod 输出")

        // 保持真实播放一段时间，再立即返回并选择相邻的 4K 频道。
        let playbackDuration = min(max(configuration.duration, 15), 60)
        try await ContinuousClock().sleep(
            for: .milliseconds(Int64(playbackDuration * 1_000))
        )
        XCUIRemote.shared.press(.menu)
        guard fullScreenPlayer.waitForNonExistence(timeout: 10),
              hdChannel.waitForExistence(timeout: 10) else {
            throw AcceptanceNavigationFailure(
                target: .fullScreenPlayer,
                phase: .awaitDismissal
            )
        }

        let ultraHDChannel = app.buttons.containing(
            .staticText,
            identifier: "东方卫视 4K"
        ).element
        guard ultraHDChannel.waitForExistence(timeout: 10) else {
            throw AcceptanceNavigationFailure(
                target: .requestedChannel,
                phase: .awaitExistence
            )
        }
        XCUIRemote.shared.press(.right)
        try activateContent(ultraHDChannel, target: .requestedChannel) {
            fullScreenPlayer.waitForExistence(timeout: 30)
        }

        guard stateElement.waitForExistence(timeout: 30),
              metricsElement.waitForExistence(timeout: 30) else {
            throw AcceptanceNavigationFailure(
                target: .acceptanceMetrics,
                phase: .awaitExistence
            )
        }
        let ultraHDSnapshot = try await awaitStableRoute(
            from: metricsElement,
            stateElement: stateElement,
            timeout: .seconds(120)
        )
        print("[ACCEPTANCE_SWITCH] second_route=\(ultraHDSnapshot.audioRoute)")
        XCTAssertEqual(ultraHDSnapshot.audioRoute, "airPlay")
    }

    @MainActor
    func testAirPlayRepeated4KAndHDSwitchesExposeFirstFailureStage() async throws {
        let configuration = try acceptanceConfiguration()
        let app = XCUIApplication()
        app.launchArguments = ["-acceptance-playback", "-uiTestResetPlaybackSettings"]
        app.launchEnvironment = configuration.encodedEnvironment
        app.launch()

        try importPrefilledProfile(in: app)
        let importedChannel = app.buttons.containing(
            .staticText,
            identifier: AcceptanceConfiguration.firstChannelName
        ).element
        try selectTab(
            .channels,
            target: .channelTab,
            destination: importedChannel,
            in: app
        )
        let hdChannel = app.buttons.containing(
            .staticText,
            identifier: "东方卫视 HD"
        ).element
        let ultraHDChannel = app.buttons.containing(
            .staticText,
            identifier: "东方卫视 4K"
        ).element
        guard hdChannel.waitForExistence(timeout: 10),
              ultraHDChannel.waitForExistence(timeout: 10) else {
            throw AcceptanceNavigationFailure(
                target: .requestedChannel,
                phase: .awaitExistence
            )
        }

        let fullScreenPlayer = app.otherElements["player-full-screen"]
        let stateElement = app.otherElements["player-acceptance-state"]
        let metricsElement = app.otherElements["player-acceptance-metrics"]
        let diagnosticsElement = app.otherElements["player-acceptance-diagnostics"]
        let clock = ContinuousClock()
        var failures: [String] = []

        for round in 1...3 {
            if hdChannel.hasFocus { XCUIRemote.shared.press(.right) }
            guard await waitForFocus(on: ultraHDChannel, timeout: .seconds(2)) else {
                throw AcceptanceNavigationFailure(
                    target: .requestedChannel,
                    phase: .acquireFocus
                )
            }
            let fourKStarted = clock.now
            try activateContent(ultraHDChannel, target: .requestedChannel) {
                fullScreenPlayer.waitForExistence(timeout: 30)
            }
            guard stateElement.waitForExistence(timeout: 30),
                  metricsElement.waitForExistence(timeout: 30),
                  diagnosticsElement.waitForExistence(timeout: 30) else {
                throw AcceptanceNavigationFailure(
                    target: .acceptanceMetrics,
                    phase: .awaitExistence
                )
            }
            do {
                _ = try await awaitStableRoute(
                    from: metricsElement,
                    stateElement: stateElement,
                    timeout: .seconds(90)
                )
                try await awaitDiagnosticMarker(
                    "avprep_preroll_ready",
                    from: diagnosticsElement,
                    stateElement: stateElement,
                    timeout: .seconds(15)
                )
                print("[ACCEPTANCE_DIAGNOSTICS] round=\(round) channel=4k " +
                    "history=\(diagnosticsElement.value as? String ?? "unavailable")")
                print("[ACCEPTANCE_USER_FLOW] round=\(round) channel=4k " +
                    "startup=\(elapsedSeconds(from: fourKStarted, clock: clock)) outcome=playing")
            } catch {
                let diagnostic = diagnosticsElement.value as? String ?? "unavailable"
                let attachment = XCTAttachment(string: diagnostic)
                attachment.name = "round-\(round)-4k-diagnostics.txt"
                attachment.lifetime = .keepAlways
                add(attachment)
                print("[ACCEPTANCE_USER_FLOW] round=\(round) channel=4k outcome=failed diag=\(diagnostic)")
                failures.append("round=\(round) channel=4k error=\(error) diag=\(diagnostic)")
            }

            XCUIRemote.shared.press(.menu)
            guard fullScreenPlayer.waitForNonExistence(timeout: 10),
                  ultraHDChannel.waitForExistence(timeout: 10) else {
                throw AcceptanceNavigationFailure(
                    target: .fullScreenPlayer,
                    phase: .awaitDismissal
                )
            }

            guard await waitForFocus(on: ultraHDChannel, timeout: .seconds(5)) else {
                throw AcceptanceNavigationFailure(
                    target: .requestedChannel,
                    phase: .acquireFocus
                )
            }
            XCUIRemote.shared.press(.left)
            guard await waitForFocus(on: hdChannel, timeout: .seconds(2)) else {
                throw AcceptanceNavigationFailure(
                    target: .requestedChannel,
                    phase: .acquireFocus
                )
            }
            let hdStarted = clock.now
            try activateContent(hdChannel, target: .requestedChannel) {
                fullScreenPlayer.waitForExistence(timeout: 30)
            }
            guard stateElement.waitForExistence(timeout: 30),
                  metricsElement.waitForExistence(timeout: 30),
                  diagnosticsElement.waitForExistence(timeout: 30) else {
                throw AcceptanceNavigationFailure(
                    target: .acceptanceMetrics,
                    phase: .awaitExistence
                )
            }
            do {
                _ = try await awaitStableRoute(
                    from: metricsElement,
                    stateElement: stateElement,
                    timeout: .seconds(90)
                )
                try await awaitDiagnosticMarker(
                    "avprep_preroll_ready",
                    from: diagnosticsElement,
                    stateElement: stateElement,
                    timeout: .seconds(15)
                )
                print("[ACCEPTANCE_DIAGNOSTICS] round=\(round) channel=hd " +
                    "history=\(diagnosticsElement.value as? String ?? "unavailable")")
                print("[ACCEPTANCE_USER_FLOW] round=\(round) channel=hd " +
                    "startup=\(elapsedSeconds(from: hdStarted, clock: clock)) outcome=playing")
            } catch {
                let diagnostic = diagnosticsElement.value as? String ?? "unavailable"
                let attachment = XCTAttachment(string: diagnostic)
                attachment.name = "round-\(round)-hd-diagnostics.txt"
                attachment.lifetime = .keepAlways
                add(attachment)
                print("[ACCEPTANCE_USER_FLOW] round=\(round) channel=hd outcome=failed diag=\(diagnostic)")
                failures.append("round=\(round) channel=hd error=\(error) diag=\(diagnostic)")
            }

            XCUIRemote.shared.press(.menu)
            guard fullScreenPlayer.waitForNonExistence(timeout: 10),
                  hdChannel.waitForExistence(timeout: 10) else {
                throw AcceptanceNavigationFailure(
                    target: .fullScreenPlayer,
                    phase: .awaitDismissal
                )
            }
            guard await waitForFocus(on: hdChannel, timeout: .seconds(5)) else {
                throw AcceptanceNavigationFailure(
                    target: .requestedChannel,
                    phase: .acquireFocus
                )
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    @MainActor
    private func awaitDiagnosticMarker(
        _ marker: String,
        from diagnosticsElement: XCUIElement,
        stateElement: XCUIElement,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try AcceptanceStableRouteFailureClassifier.validate(
                state: playbackState(from: stateElement)
            )
            if let diagnostics = diagnosticsElement.value as? String,
               diagnostics.contains(marker) {
                return
            }
            try await clock.sleep(for: .milliseconds(250))
        }
        throw AcceptanceFailure.playbackNotPlaying
    }

    @MainActor
    private func waitForFocus(
        on element: XCUIElement,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if element.hasFocus { return true }
            try? await clock.sleep(for: .milliseconds(100))
        }
        return element.hasFocus
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

    func testLongPlaybackMemoryMeasurementCompleteTwoHourCoverageAndThresholds() throws {
        var fixtureSamples: [LongPlaybackSample] = []
        fixtureSamples.reserveCapacity(7_200)
        let t0_ns: UInt64 = 1_000_000_000
        for n in 1...7_200 {
            let sampleTime_ns = t0_ns + UInt64(n) * 1_000_000_000 + 250_000_000
            let footprint: UInt64
            if n <= 900 {
                footprint = 500_000_000 + UInt64(n * 100)
            } else {
                footprint = 500_000_000 + UInt64(900 * 100) + UInt64(min(n - 900, 32 * 1_024 * 1_024 / 2))
            }
            fixtureSamples.append(LongPlaybackSample(
                sequence: n,
                timestampNanoseconds: sampleTime_ns,
                physicalFootprintBytes: footprint,
                availableMemoryBytes: 1_000_000_000,
                encoderBacklog: 2,
                writerBacklog: 2,
                deliveryBacklogBytes: 4 * 1_024 * 1_024,
                route: "airPlayHLS",
                lifecycleState: "active"
            ))
        }

        let measurement = try LongPlaybackMemoryMeasurement(samples: fixtureSamples)
        XCTAssertTrue(measurement.hasCompleteTwoHourCoverage)
        XCTAssertLessThanOrEqual(measurement.maximumFootprintBytes, measurement.allowedFootprintBytes)
        XCTAssertTrue(measurement.noUnboundedGrowth)
        XCTAssertNoThrow(try measurement.validate())
    }

    func testLongPlaybackTimingWindowBoundaryAndViolation() throws {
        let t0: UInt64 = 10_000_000_000
        let n = 1
        let tn = t0 + UInt64(n) * 1_000_000_000

        // Exact 500ms boundary passes
        let exact500msSample = LongPlaybackSample(
            sequence: n,
            timestampNanoseconds: tn + 500_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000
        )
        XCTAssertNoThrow(try LongPlaybackMemoryMeasurement(samples: [exact500msSample], t0Nanoseconds: t0))

        // 500ms + 1ns fails
        let overBy1nsSample = LongPlaybackSample(
            sequence: n,
            timestampNanoseconds: tn + 500_000_001,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [overBy1nsSample], t0Nanoseconds: t0)) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .sampleTimingWindowExceeded(sequence: 1, offsetNanoseconds: 500_000_001)
            )
        }

        // Before t_n (e.g. t_n - 1ns) fails
        let beforeTnSample = LongPlaybackSample(
            sequence: n,
            timestampNanoseconds: tn - 1,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [beforeTnSample], t0Nanoseconds: t0)) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .sampleTimingWindowExceeded(sequence: 1, offsetNanoseconds: -1)
            )
        }
    }

    func testLongPlaybackMissingRequiredSamples() throws {
        var samplesWithout900: [LongPlaybackSample] = []
        let t0: UInt64 = 0
        for n in 1...7_200 {
            if n == 900 { continue }
            samplesWithout900.append(LongPlaybackSample(
                sequence: n,
                timestampNanoseconds: t0 + UInt64(n) * 1_000_000_000 + 100_000,
                physicalFootprintBytes: 500_000_000,
                availableMemoryBytes: 500_000_000
            ))
        }
        let measurementWithout900 = try LongPlaybackMemoryMeasurement(samples: samplesWithout900)
        XCTAssertFalse(measurementWithout900.hasCompleteTwoHourCoverage)
        XCTAssertThrowsError(try measurementWithout900.validate()) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .missingRequiredSample(sequence: 900)
            )
        }

        var samplesWithout7200: [LongPlaybackSample] = []
        for n in 1...7_199 {
            samplesWithout7200.append(LongPlaybackSample(
                sequence: n,
                timestampNanoseconds: t0 + UInt64(n) * 1_000_000_000 + 100_000,
                physicalFootprintBytes: 500_000_000,
                availableMemoryBytes: 500_000_000
            ))
        }
        let measurementWithout7200 = try LongPlaybackMemoryMeasurement(samples: samplesWithout7200)
        XCTAssertFalse(measurementWithout7200.hasCompleteTwoHourCoverage)
        XCTAssertThrowsError(try measurementWithout7200.validate()) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .missingRequiredSample(sequence: 7_200)
            )
        }
    }

    func testLongPlaybackSequenceGapDetectionWith7200SamplesAndDuplicateSequence() throws {
        let t0: UInt64 = 1_000_000_000
        var samples: [LongPlaybackSample] = []
        samples.reserveCapacity(7_200)

        // Duplicate sequence 1: two samples with sequence: 1 and strictly increasing timestamps within [t_1, t_1 + 500ms]
        samples.append(LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: t0 + 1_000_000_000 + 100_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000
        ))
        samples.append(LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: t0 + 1_000_000_000 + 200_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000
        ))

        // Sequences 2...7200, but skipping sequence 1000 so total sample count is exactly 7200
        for n in 2...7_200 {
            if n == 1_000 { continue }
            samples.append(LongPlaybackSample(
                sequence: n,
                timestampNanoseconds: t0 + UInt64(n) * 1_000_000_000 + 100_000,
                physicalFootprintBytes: 500_000_000,
                availableMemoryBytes: 500_000_000
            ))
        }

        XCTAssertEqual(samples.count, 7_200)

        let measurement = try LongPlaybackMemoryMeasurement(samples: samples)
        XCTAssertEqual(measurement.missingSequenceNumber, 1_000)
        XCTAssertFalse(measurement.hasCompleteTwoHourCoverage)
        XCTAssertThrowsError(try measurement.validate()) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .missingRequiredSample(sequence: 1_000)
            )
        }
    }

    func testLongPlaybackDuplicateAndNonMonotonicTimestamps() throws {
        let t0: UInt64 = 1_000_000_000
        let s1 = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: t0 + 1_000_000_000,
            physicalFootprintBytes: 100_000_000,
            availableMemoryBytes: 500_000_000
        )
        // Duplicate timestamp
        let s2Duplicate = LongPlaybackSample(
            sequence: 2,
            timestampNanoseconds: t0 + 1_000_000_000,
            physicalFootprintBytes: 100_000_000,
            availableMemoryBytes: 500_000_000
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [s1, s2Duplicate])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .duplicateTimestamp(sequence: 2)
            )
        }

        // Regressing / non-monotonic timestamp
        let s2Regressing = LongPlaybackSample(
            sequence: 2,
            timestampNanoseconds: t0 + 999_999_999,
            physicalFootprintBytes: 100_000_000,
            availableMemoryBytes: 500_000_000
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [s1, s2Regressing])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .nonMonotonicTimestamp(sequence: 2)
            )
        }
    }

    func testLongPlaybackMedianFloorEvenCalculation() throws {
        // 60 items with even difference: 30th is 100, 31st is 102 -> 100 + (102-100)/2 = 101
        let itemsEven: [UInt64] = Array(repeating: 50, count: 29) + [100, 102] + Array(repeating: 200, count: 29)
        XCTAssertEqual(itemsEven.count, 60)
        XCTAssertEqual(LongPlaybackMemoryMeasurement.medianFloor60(itemsEven), 101)

        // 60 items with odd difference: 30th is 100, 31st is 103 -> 100 + (103-100)/2 = 101 (floor)
        let itemsOdd: [UInt64] = Array(repeating: 50, count: 29) + [100, 103] + Array(repeating: 200, count: 29)
        XCTAssertEqual(itemsOdd.count, 60)
        XCTAssertEqual(LongPlaybackMemoryMeasurement.medianFloor60(itemsOdd), 101)

        // 5 items odd median: items at indices 0,1,2,3,4 -> 3rd item (index 2)
        let items5: [UInt64] = [10, 20, 35, 50, 90]
        XCTAssertEqual(LongPlaybackMemoryMeasurement.median5(items5), 35)
    }

    func testLongPlaybackUnsignedUnderflowSaturation() throws {
        // Positive delta: R > B
        XCTAssertEqual(LongPlaybackMemoryMeasurement.positiveDelta(150, 100), 50)
        // Saturating underflow: R < B -> 0
        XCTAssertEqual(LongPlaybackMemoryMeasurement.positiveDelta(100, 150), 0)
        XCTAssertEqual(LongPlaybackMemoryMeasurement.positiveDelta(100, 100), 0)

        // Int64.max boundary
        let maxValid: UInt64 = UInt64(Int64.max)
        let validSample = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: maxValid,
            availableMemoryBytes: 500_000_000
        )
        XCTAssertNoThrow(try LongPlaybackMemoryMeasurement(samples: [validSample]))

        let overInt64Max: UInt64 = UInt64(Int64.max) + 1
        let invalidSample = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: overInt64Max,
            availableMemoryBytes: 500_000_000
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [invalidSample])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .footprintExceedsInt64Max(sequence: 1, bytes: overInt64Max)
            )
        }
    }

    func testLongPlaybackGrowthThreshold32MiBBoundaryAndViolation() throws {
        // Build 7200 samples where Window B median is 100_000_000
        // and Window R median is 100_000_000 + 33_554_432 (exact 32 MiB)
        var samplesExact: [LongPlaybackSample] = []
        samplesExact.reserveCapacity(7_200)
        for n in 1...7_200 {
            let fp: UInt64 = n <= 900 ? 100_000_000 : 100_000_000 + 33_554_432
            samplesExact.append(LongPlaybackSample(
                sequence: n,
                timestampNanoseconds: UInt64(n) * 1_000_000_000,
                physicalFootprintBytes: fp,
                availableMemoryBytes: 500_000_000
            ))
        }
        let exactMeasurement = try LongPlaybackMemoryMeasurement(samples: samplesExact)
        XCTAssertTrue(exactMeasurement.noUnboundedGrowth)
        XCTAssertNoThrow(try exactMeasurement.validate())

        // 32 MiB + 1 byte violation
        var samplesOver: [LongPlaybackSample] = []
        samplesOver.reserveCapacity(7_200)
        for n in 1...7_200 {
            let fp: UInt64 = n <= 900 ? 100_000_000 : 100_000_000 + 33_554_433
            samplesOver.append(LongPlaybackSample(
                sequence: n,
                timestampNanoseconds: UInt64(n) * 1_000_000_000,
                physicalFootprintBytes: fp,
                availableMemoryBytes: 500_000_000
            ))
        }
        let overMeasurement = try LongPlaybackMemoryMeasurement(samples: samplesOver)
        XCTAssertFalse(overMeasurement.noUnboundedGrowth)
        XCTAssertThrowsError(try overMeasurement.validate()) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .unboundedGrowthDetected(growthBytes: 33_554_433, allowedBytes: 33_554_432)
            )
        }
    }

    func testLongPlaybackMaxFootprint1Point5GiBBoundaryAndViolation() throws {
        let maxAllowed: UInt64 = 1_610_612_736 // 1.5 GiB
        let exactSample = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: maxAllowed,
            availableMemoryBytes: 500_000_000
        )
        let exactMeasurement = try LongPlaybackMemoryMeasurement(samples: [exactSample])
        XCTAssertLessThanOrEqual(exactMeasurement.maximumFootprintBytes, exactMeasurement.allowedFootprintBytes)

        let overBy1Sample = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: maxAllowed + 1,
            availableMemoryBytes: 500_000_000
        )
        let overMeasurement = try LongPlaybackMemoryMeasurement(samples: [overBy1Sample])
        XCTAssertGreaterThan(overMeasurement.maximumFootprintBytes, overMeasurement.allowedFootprintBytes)
        XCTAssertThrowsError(try overMeasurement.validate()) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .maximumFootprintExceeded(footprintBytes: maxAllowed + 1, allowedBytes: maxAllowed)
            )
        }
    }

    func testLongPlaybackMinAvailableMemory256MiBBoundaryAndViolation() throws {
        let minAllowed: UInt64 = 268_435_456 // 256 MiB
        let exactSample = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: minAllowed
        )
        let exactMeasurement = try LongPlaybackMemoryMeasurement(samples: [exactSample])
        XCTAssertTrue(exactMeasurement.hasAdequateAvailableMemory)

        let underBy1Sample = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: minAllowed - 1
        )
        let underMeasurement = try LongPlaybackMemoryMeasurement(samples: [underBy1Sample])
        XCTAssertFalse(underMeasurement.hasAdequateAvailableMemory)
        XCTAssertThrowsError(try underMeasurement.validate()) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .minimumAvailableMemoryRegressed(availableBytes: minAllowed - 1, requiredBytes: minAllowed)
            )
        }
    }

    func testLongPlaybackBacklogHardCapBoundaryAndViolation() throws {
        // Encoder hard cap 4
        let validEncoder = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            encoderBacklog: 4
        )
        XCTAssertNoThrow(try LongPlaybackMemoryMeasurement(samples: [validEncoder]))

        let overEncoder = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            encoderBacklog: 5
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [overEncoder])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .backlogHardCapExceeded(queue: "encoder", count: 5, limit: 4)
            )
        }

        // Writer hard cap 8
        let validWriter = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            writerBacklog: 8
        )
        XCTAssertNoThrow(try LongPlaybackMemoryMeasurement(samples: [validWriter]))

        let overWriter = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            writerBacklog: 9
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [overWriter])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .backlogHardCapExceeded(queue: "writer", count: 9, limit: 8)
            )
        }

        // Delivery hard cap 16 MiB (16,777,216 bytes)
        let validDelivery = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            deliveryBacklogBytes: 16_777_216
        )
        XCTAssertNoThrow(try LongPlaybackMemoryMeasurement(samples: [validDelivery]))

        let overDelivery = LongPlaybackSample(
            sequence: 1,
            timestampNanoseconds: 1_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            deliveryBacklogBytes: 16_777_217
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [overDelivery])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .backlogHardCapExceeded(queue: "delivery", count: 16_777_217, limit: 16_777_216)
            )
        }
    }

    func testLongPlaybackMidPlaybackRouteAndLifecycleDisruptions() throws {
        let routeDisrupted = LongPlaybackSample(
            sequence: 50,
            timestampNanoseconds: 50_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            route: "SampleBuffer"
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [routeDisrupted])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .routeDisrupted(sequence: 50, route: "SampleBuffer")
            )
        }

        let lifecycleDisrupted = LongPlaybackSample(
            sequence: 50,
            timestampNanoseconds: 50_000_000_000,
            physicalFootprintBytes: 500_000_000,
            availableMemoryBytes: 500_000_000,
            lifecycleState: "interrupted"
        )
        XCTAssertThrowsError(try LongPlaybackMemoryMeasurement(samples: [lifecycleDisrupted])) { error in
            XCTAssertEqual(
                error as? LongPlaybackMemoryMeasurementError,
                .lifecycleDisrupted(sequence: 50, state: "interrupted")
            )
        }
    }

    func testAACPrimingRSSWorstCaseFixtureFormatAndChecksum() throws {
        let fixtureData = AACPrimingRSSWorstCaseFixtureV1.generateSerializedData()
        XCTAssertEqual(fixtureData.count, 524_288)

        let digest = SHA256.hash(data: fixtureData)
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hashString, "a5172ccbd0cc73fbf901bec1c869255744fd2422fd0898f61a3c67135b616721")
        XCTAssertTrue(AACPrimingRSSWorstCaseFixtureV1.verifyDigest(data: fixtureData))

        let channels = AACPrimingRSSWorstCaseFixtureV1.generateChannelSamples()
        XCTAssertEqual(channels.count, 8)
        for channel in channels {
            XCTAssertEqual(channel.count, 16_384)
            // [0, 4096) must be +0.0f
            XCTAssertTrue(channel[0..<4_096].allSatisfy { $0 == 0.0 })
            // [12288, 16384) must be +0.0f
            XCTAssertTrue(channel[12_288..<16_384].allSatisfy { $0 == 0.0 })
            // Active zone [4096, 12288) has non-zero finite values
            XCTAssertTrue(channel[4_096..<12_288].allSatisfy { $0.isFinite && abs($0) <= 0.25 })
        }
    }

    func testAACPrimingRSSMeasurementSyntheticPassesAllCriteria() throws {
        var rounds: [AACPrimingRoundResult] = []
        rounds.reserveCapacity(20)

        for roundIndex in 1...20 {
            // 10 quiescence points with ~100ms interval, range <= 256 KiB, time < 5s
            var quiescencePoints: [AACQuiescencePoint] = []
            for i in 0..<10 {
                let time = 0.100 * Double(i)
                let footprint: UInt64 = 200_000_000 + UInt64(i * 1_000)
                quiescencePoints.append(AACQuiescencePoint(elapsedSeconds: time, footprintBytes: footprint))
            }

            // Peak window with 5ms intervals, peak within 32 MiB of baseline
            let baseline = 200_005_000 // approx
            let peakBytes: UInt64 = UInt64(baseline + 16 * 1_024 * 1_024)
            let peakSamples: [AACPeakSample] = [
                AACPeakSample(offsetSeconds: 0.001, footprintBytes: UInt64(baseline + 1_000_000)),
                AACPeakSample(offsetSeconds: 0.006, footprintBytes: peakBytes),
                AACPeakSample(offsetSeconds: 0.011, footprintBytes: UInt64(baseline + 2_000_000)),
            ]

            // 10 post-cleanup points, slight controlled drift < 128 KiB / round
            var postCleanupPoints: [AACQuiescencePoint] = []
            for i in 0..<10 {
                let time = 0.100 * Double(i)
                let footprint: UInt64 = 200_010_000 + UInt64(roundIndex * 2_000) + UInt64(i * 500)
                postCleanupPoints.append(AACQuiescencePoint(elapsedSeconds: time, footprintBytes: footprint))
            }

            rounds.append(AACPrimingRoundResult(
                roundIndex: roundIndex,
                quiescencePoints: quiescencePoints,
                peakSamples: peakSamples,
                postCleanupPoints: postCleanupPoints,
                transactionStartSeconds: 0.002,
                cleanupTerminalSeconds: 0.010
            ))
        }

        let measurement = try AACPrimingRSSMeasurement(rounds: rounds)
        XCTAssertNoThrow(try measurement.validate())
        XCTAssertLessThanOrEqual(measurement.maximumPeakDeltaBytes, 32 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(measurement.residueGrowthBytes, 2 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(measurement.residueSlopeBytesPerRound, 131_072)
    }

    func testAACPrimingRSSQuiescenceIntervalBoundariesAndViolations() throws {
        // Exact 90ms and 110ms intervals pass
        var validPoints: [AACQuiescencePoint] = []
        for i in 0..<10 {
            let interval = (i % 2 == 0) ? 0.090 : 0.110
            let time = (validPoints.last?.elapsedSeconds ?? 0) + interval
            validPoints.append(AACQuiescencePoint(elapsedSeconds: time, footprintBytes: 100_000_000))
        }
        XCTAssertNoThrow(try AACQuiescenceValidator.validate(points: validPoints))

        // Interval < 90ms (e.g. 89.999ms) fails
        var tooShortPoints = validPoints
        tooShortPoints[5] = AACQuiescencePoint(
            elapsedSeconds: tooShortPoints[4].elapsedSeconds + 0.089999999,
            footprintBytes: 100_000_000
        )
        XCTAssertThrowsError(try AACQuiescenceValidator.validate(points: tooShortPoints)) { error in
            XCTAssertEqual(error as? AACPrimingMeasurementError, .quiescenceIntervalViolation)
        }

        // Interval > 110ms (e.g. 110.000000001s) fails
        var tooLongPoints = validPoints
        tooLongPoints[5] = AACQuiescencePoint(
            elapsedSeconds: tooLongPoints[4].elapsedSeconds + 0.110000001,
            footprintBytes: 100_000_000
        )
        XCTAssertThrowsError(try AACQuiescenceValidator.validate(points: tooLongPoints)) { error in
            XCTAssertEqual(error as? AACPrimingMeasurementError, .quiescenceIntervalViolation)
        }

        // 10th sample at 4.999s passes
        var pointsValid4999: [AACQuiescencePoint] = []
        for i in 0..<10 {
            pointsValid4999.append(AACQuiescencePoint(elapsedSeconds: 4.099 + Double(i) * 0.100, footprintBytes: 100_000_000))
        }
        XCTAssertNoThrow(try AACQuiescenceValidator.validate(points: pointsValid4999))

        // 10th sample at 5.000s fails (must be strictly earlier than 5 seconds)
        var points5000: [AACQuiescencePoint] = []
        for i in 0..<10 {
            points5000.append(AACQuiescencePoint(elapsedSeconds: 4.100 + Double(i) * 0.100, footprintBytes: 100_000_000))
        }
        XCTAssertThrowsError(try AACQuiescenceValidator.validate(points: points5000)) { error in
            XCTAssertEqual(error as? AACPrimingMeasurementError, .quiescenceDeadlineExceeded)
        }

        // 10th sample at 5.001s fails
        var points5001: [AACQuiescencePoint] = []
        for i in 0..<10 {
            points5001.append(AACQuiescencePoint(elapsedSeconds: 4.101 + Double(i) * 0.100, footprintBytes: 100_000_000))
        }
        XCTAssertThrowsError(try AACQuiescenceValidator.validate(points: points5001)) { error in
            XCTAssertEqual(error as? AACPrimingMeasurementError, .quiescenceDeadlineExceeded)
        }
    }

    func testAACPrimingRSSQuiescenceRange256KiBBoundaryAndViolation() throws {
        // Max - min == 262_144 (256 KiB) passes
        var pointsExact: [AACQuiescencePoint] = []
        for i in 0..<10 {
            let fp: UInt64 = i == 9 ? 100_000_000 + 262_144 : 100_000_000
            pointsExact.append(AACQuiescencePoint(elapsedSeconds: Double(i) * 0.100, footprintBytes: fp))
        }
        XCTAssertNoThrow(try AACQuiescenceValidator.validate(points: pointsExact))

        // Max - min == 262_145 fails
        var pointsOver: [AACQuiescencePoint] = []
        for i in 0..<10 {
            let fp: UInt64 = i == 9 ? 100_000_000 + 262_145 : 100_000_000
            pointsOver.append(AACQuiescencePoint(elapsedSeconds: Double(i) * 0.100, footprintBytes: fp))
        }
        XCTAssertThrowsError(try AACQuiescenceValidator.validate(points: pointsOver)) { error in
            XCTAssertEqual(
                error as? AACPrimingMeasurementError,
                .quiescenceRangeExceeded(rangeBytes: 262_145, allowedBytes: 262_144)
            )
        }
    }

    func testAACPrimingRSSPeakWindowIntervalAndCoverageViolations() throws {
        // Adjacent interval == 7.5ms (0.0075s) passes
        let validPeak: [AACPeakSample] = [
            AACPeakSample(offsetSeconds: 0.000, footprintBytes: 100_000_000),
            AACPeakSample(offsetSeconds: 0.0075, footprintBytes: 105_000_000),
            AACPeakSample(offsetSeconds: 0.015, footprintBytes: 100_000_000),
        ]
        XCTAssertNoThrow(try AACPeakValidator.validate(
            samples: validPeak,
            transactionStartSeconds: 0.002,
            cleanupTerminalSeconds: 0.012
        ))

        // Adjacent interval == 7.5ms + 1ns fails
        let overPeak: [AACPeakSample] = [
            AACPeakSample(offsetSeconds: 0.000, footprintBytes: 100_000_000),
            AACPeakSample(offsetSeconds: 0.007500000001, footprintBytes: 105_000_000),
            AACPeakSample(offsetSeconds: 0.015, footprintBytes: 100_000_000),
        ]
        XCTAssertThrowsError(try AACPeakValidator.validate(
            samples: overPeak,
            transactionStartSeconds: 0.002,
            cleanupTerminalSeconds: 0.012
        )) { error in
            XCTAssertEqual(error as? AACPrimingMeasurementError, .peakSamplingIntervalExceeded)
        }

        // First sample starting after transaction creation fails
        XCTAssertThrowsError(try AACPeakValidator.validate(
            samples: validPeak,
            transactionStartSeconds: -0.001, // transaction started before first sample (0.000)
            cleanupTerminalSeconds: 0.012
        )) { error in
            XCTAssertEqual(error as? AACPrimingMeasurementError, .peakWindowMissingTransactionStart)
        }

        // Last sample ending before cleanup terminal fails
        XCTAssertThrowsError(try AACPeakValidator.validate(
            samples: validPeak,
            transactionStartSeconds: 0.002,
            cleanupTerminalSeconds: 0.020 // cleanup terminal after last sample (0.015)
        )) { error in
            XCTAssertEqual(error as? AACPrimingMeasurementError, .peakWindowMissingCleanupTerminal)
        }
    }

    func testAACPrimingRSSThresholds32MiB2MiB131072SlopeBoundariesAndViolations() throws {
        // Peak delta 32 MiB boundary: 33_554_432 passes, 33_554_433 fails
        XCTAssertNoThrow(try AACPrimingThresholdValidator.validatePeakDelta(33_554_432))
        XCTAssertThrowsError(try AACPrimingThresholdValidator.validatePeakDelta(33_554_433)) { error in
            XCTAssertEqual(
                error as? AACPrimingMeasurementError,
                .peakDeltaExceeded(deltaBytes: 33_554_433, allowedBytes: 33_554_432)
            )
        }

        // Residue median delta 2 MiB boundary: 2_097_152 passes, 2_097_153 fails
        XCTAssertNoThrow(try AACPrimingThresholdValidator.validateResidueMedianDelta(2_097_152))
        XCTAssertThrowsError(try AACPrimingThresholdValidator.validateResidueMedianDelta(2_097_153)) { error in
            XCTAssertEqual(
                error as? AACPrimingMeasurementError,
                .residueGrowthExceeded(growthBytes: 2_097_153, allowedBytes: 2_097_152)
            )
        }

        // OLS slope 131_072 passes, 131_073 fails
        XCTAssertNoThrow(try AACPrimingThresholdValidator.validateSlope(131_072.0))
        XCTAssertThrowsError(try AACPrimingThresholdValidator.validateSlope(131_073.0)) { error in
            XCTAssertEqual(
                error as? AACPrimingMeasurementError,
                .residueSlopeExceeded(slope: 131_073.0, allowedSlope: 131_072.0)
            )
        }

        // Negative slope saturated to 0.0 passes
        XCTAssertEqual(AACPrimingThresholdValidator.saturatedSlope(-500.0), 0.0)
        XCTAssertNoThrow(try AACPrimingThresholdValidator.validateSlope(AACPrimingThresholdValidator.saturatedSlope(-500.0)))
    }

    func testAACPrimingRSSRealDeviceExecutionSkipsGracefullyOnSimulator() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real Apple TV device acceptance requires verified hardware (AppleTV14,1)")
        #else
        // Feeds AACPrimingRSSWorstCaseFixtureV1 through the audio conversion pipeline
        // (48kHz Float32 8ch non-interleaved -> 48kHz AAC-LC stereo and 7.1-B)
        // Samples task_info(mach_task_self_, TASK_VM_INFO, ...).phys_footprint with 3 warmup + 20 formal rounds.
        let fixtureData = AACPrimingRSSWorstCaseFixtureV1.generateSerializedData()
        XCTAssertEqual(fixtureData.count, 524_288)
        XCTAssertTrue(AACPrimingRSSWorstCaseFixtureV1.verifyDigest(data: fixtureData))

        func currentPhysFootprint() -> UInt64? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
                infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
                }
            }
            guard kerr == KERN_SUCCESS else { return nil }
            return info.phys_footprint
        }

        func runConverterPumping(
            converter: AudioConverterRef,
            context: PrimingPCMInputContext,
            channels: UInt32
        ) {
            var outputBuffer = [UInt8](repeating: 0, count: 32_768)
            var packetDescriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: 16)
            while true {
                var ioOutputPackets: UInt32 = 16
                let status = outputBuffer.withUnsafeMutableBytes { outRaw in
                    var outBufferList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: channels,
                            mDataByteSize: UInt32(outRaw.count),
                            mData: outRaw.baseAddress
                        )
                    )
                    return AudioConverterFillComplexBuffer(
                        converter,
                        primingAudioConverterInputProc,
                        Unmanaged.passUnretained(context).toOpaque(),
                        &ioOutputPackets,
                        &outBufferList,
                        &packetDescriptions
                    )
                }
                if status != noErr || ioOutputPackets == 0 {
                    break
                }
            }
        }

        var formalRounds: [AACPrimingRoundResult] = []
        formalRounds.reserveCapacity(20)

        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)

        func nanosSince(_ start: UInt64) -> UInt64 {
            let now = mach_continuous_time()
            return (now - start) * UInt64(timebase.numer) / UInt64(timebase.denom)
        }

        fixtureData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                XCTFail("Failed to obtain fixture buffer pointer")
                return
            }

            for roundIndex in 0..<23 {
                autoreleasepool {
                    // 1. Quiescence sampling (10 points within [90ms, 110ms], strictly < 5.0s)
                    let quiescenceStart = mach_continuous_time()
                    var quiescencePoints: [AACQuiescencePoint] = []
                    for i in 0..<10 {
                        let targetElapsedNanos = UInt64(i) * 100_000_000
                        let currentNanos = nanosSince(quiescenceStart)
                        if currentNanos < targetElapsedNanos {
                            let sleepNanos = targetElapsedNanos - currentNanos
                            usleep(useconds_t(sleepNanos / 1_000))
                        }
                        let elapsedSec = Double(nanosSince(quiescenceStart)) / 1_000_000_000.0
                        let fp = currentPhysFootprint() ?? 0
                        quiescencePoints.append(AACQuiescencePoint(elapsedSeconds: elapsedSec, footprintBytes: fp))
                    }

                    // 2. Audio conversion pipeline: Stereo AudioConverter
                    var peakSamples: [AACPeakSample] = []
                    let roundTimeZero = mach_continuous_time()

                    func currentOffsetSec() -> Double {
                        Double(nanosSince(roundTimeZero)) / 1_000_000_000.0
                    }

                    // Pre-transaction peak sample
                    peakSamples.append(AACPeakSample(offsetSeconds: currentOffsetSec(), footprintBytes: currentPhysFootprint() ?? 0))
                    let transactionStartSec = currentOffsetSec()

                    var srcFormatStereo = AudioStreamBasicDescription(
                        mSampleRate: 48000.0,
                        mFormatID: kAudioFormatLinearPCM,
                        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                        mBytesPerPacket: 4,
                        mFramesPerPacket: 1,
                        mBytesPerFrame: 4,
                        mChannelsPerFrame: 2,
                        mBitsPerChannel: 32,
                        mReserved: 0
                    )
                    var dstFormatStereo = AudioStreamBasicDescription(
                        mSampleRate: 48000.0,
                        mFormatID: kAudioFormatMPEG4AAC,
                        mFormatFlags: 0,
                        mBytesPerPacket: 0,
                        mFramesPerPacket: 1024,
                        mBytesPerFrame: 0,
                        mChannelsPerFrame: 2,
                        mBitsPerChannel: 0,
                        mReserved: 0
                    )
                    var converterStereo: AudioConverterRef?
                    let statusStereo = AudioConverterNew(&srcFormatStereo, &dstFormatStereo, &converterStereo)
                    guard statusStereo == noErr, let convStereo = converterStereo else {
                        XCTFail("Failed to create stereo AudioConverter: \(statusStereo)")
                        return
                    }

                    var stereoLayout = AudioChannelLayout(
                        mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                        mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                        mNumberChannelDescriptions: 0,
                        mChannelDescriptions: (AudioChannelDescription(),)
                    )
                    AudioConverterSetProperty(convStereo, kAudioConverterInputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &stereoLayout)
                    AudioConverterSetProperty(convStereo, kAudioConverterOutputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &stereoLayout)
                    var bitrateStereo: UInt32 = 160_000
                    AudioConverterSetProperty(convStereo, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrateStereo)
                    var primeStereo: UInt32 = UInt32(kConverterPrimeMethod_Normal)
                    _ = AudioConverterSetProperty(convStereo, kAudioConverterPrimeMethod, UInt32(MemoryLayout<UInt32>.size), &primeStereo)

                    // Execute Stereo Conversion (channels 0 and 1)
                    let stereoContext = PrimingPCMInputContext(channelPointers: [base, base.advanced(by: 65536)])
                    runConverterPumping(converter: convStereo, context: stereoContext, channels: 2)

                    // Intermediate peak sample
                    peakSamples.append(AACPeakSample(offsetSeconds: currentOffsetSec(), footprintBytes: currentPhysFootprint() ?? 0))

                    // 3. Audio conversion pipeline: 7.1-B AudioConverter (while stereo converter is still retained)
                    var srcFormat71 = AudioStreamBasicDescription(
                        mSampleRate: 48000.0,
                        mFormatID: kAudioFormatLinearPCM,
                        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                        mBytesPerPacket: 4,
                        mFramesPerPacket: 1,
                        mBytesPerFrame: 4,
                        mChannelsPerFrame: 8,
                        mBitsPerChannel: 32,
                        mReserved: 0
                    )
                    var dstFormat71 = AudioStreamBasicDescription(
                        mSampleRate: 48000.0,
                        mFormatID: kAudioFormatMPEG4AAC,
                        mFormatFlags: 0,
                        mBytesPerPacket: 0,
                        mFramesPerPacket: 1024,
                        mBytesPerFrame: 0,
                        mChannelsPerFrame: 8,
                        mBitsPerChannel: 0,
                        mReserved: 0
                    )
                    var converter71: AudioConverterRef?
                    let status71 = AudioConverterNew(&srcFormat71, &dstFormat71, &converter71)
                    guard status71 == noErr, let conv71 = converter71 else {
                        AudioConverterDispose(convStereo)
                        XCTFail("Failed to create 7.1-B AudioConverter: \(status71)")
                        return
                    }

                    var layout71 = AudioChannelLayout(
                        mChannelLayoutTag: kAudioChannelLayoutTag_AAC_7_1_B,
                        mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                        mNumberChannelDescriptions: 0,
                        mChannelDescriptions: (AudioChannelDescription(),)
                    )
                    AudioConverterSetProperty(conv71, kAudioConverterInputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &layout71)
                    AudioConverterSetProperty(conv71, kAudioConverterOutputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &layout71)
                    var bitrate71: UInt32 = 512_000
                    AudioConverterSetProperty(conv71, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate71)
                    var prime71: UInt32 = UInt32(kConverterPrimeMethod_Normal)
                    _ = AudioConverterSetProperty(conv71, kAudioConverterPrimeMethod, UInt32(MemoryLayout<UInt32>.size), &prime71)

                    // Execute 7.1-B Conversion (channels 0...7)
                    let multichannelContext = PrimingPCMInputContext(channelPointers: (0..<8).map { base.advanced(by: $0 * 65536) })
                    runConverterPumping(converter: conv71, context: multichannelContext, channels: 8)

                    // Sample peak footprint during/right after conversion while both converters are still alive
                    peakSamples.append(AACPeakSample(offsetSeconds: currentOffsetSec(), footprintBytes: currentPhysFootprint() ?? 0))

                    let cleanupTerminalSec = currentOffsetSec()

                    // Dispose converters
                    AudioConverterDispose(conv71)
                    AudioConverterDispose(convStereo)

                    peakSamples.append(AACPeakSample(offsetSeconds: currentOffsetSec(), footprintBytes: currentPhysFootprint() ?? 0))

                    // 4. Post-cleanup sampling (10 points within [90ms, 110ms])
                    let cleanupStart = mach_continuous_time()
                    var postCleanupPoints: [AACQuiescencePoint] = []
                    for i in 0..<10 {
                        let targetElapsedNanos = UInt64(i) * 100_000_000
                        let currentNanos = nanosSince(cleanupStart)
                        if currentNanos < targetElapsedNanos {
                            let sleepNanos = targetElapsedNanos - currentNanos
                            usleep(useconds_t(sleepNanos / 1_000))
                        }
                        let elapsedSec = Double(nanosSince(cleanupStart)) / 1_000_000_000.0
                        let fp = currentPhysFootprint() ?? 0
                        postCleanupPoints.append(AACQuiescencePoint(elapsedSeconds: elapsedSec, footprintBytes: fp))
                    }

                    if roundIndex >= 3 {
                        formalRounds.append(AACPrimingRoundResult(
                            roundIndex: roundIndex - 2,
                            quiescencePoints: quiescencePoints,
                            peakSamples: peakSamples,
                            postCleanupPoints: postCleanupPoints,
                            transactionStartSeconds: transactionStartSec,
                            cleanupTerminalSeconds: cleanupTerminalSec
                        ))
                    }
                }
            }
        }

        XCTAssertEqual(formalRounds.count, 20)
        let measurement = try AACPrimingRSSMeasurement(rounds: formalRounds)
        XCTAssertNoThrow(try measurement.validate())

        for i in 0..<20 {
            let pDelta = LongPlaybackMemoryMeasurement.positiveDelta(measurement.peaks[i], measurement.baselines[i])
            XCTAssertLessThanOrEqual(pDelta, 33_554_432, "Round \(i) peak delta exceeded 32 MiB")
        }

        XCTAssertLessThanOrEqual(measurement.residueGrowthBytes, 2_097_152, "Residue delta exceeded 2 MiB")
        XCTAssertLessThanOrEqual(measurement.residueSlopeBytesPerRound, 131_072.0, "OLS trend slope exceeded 131,072 bytes/round")
        #endif
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
        let diagnosticsElement = app.otherElements["player-acceptance-diagnostics"]
        guard diagnosticsElement.waitForExistence(timeout: 30) else {
            throw AcceptanceNavigationFailure(
                target: .acceptanceMetrics,
                phase: .awaitExistence
            )
        }
        _ = try await awaitStableRoute(
            from: metricsElement,
            stateElement: stateElement,
            diagnosticsElement: diagnosticsElement,
            timeout: .seconds(90)
        )

        let runBaseline = try await activeHeartbeat(
            after: -Double.infinity,
            metricsElement: metricsElement,
            stateElement: stateElement,
            diagnosticsElement: diagnosticsElement,
            in: app
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let requestedDuration = Duration.milliseconds(Int64(configuration.duration * 1_000))
        let end = startedAt.advanced(by: requestedDuration)
        var nextMinute = startedAt.advanced(by: .seconds(60))
        var lastObservedElapsed = runBaseline.elapsedSeconds
        var previousSteadySnapshot = runBaseline
        var previousFunctionalSnapshot = runBaseline
        var snapshots: [AcceptanceMetricsSnapshot] = []

        while clock.now < end {
            let heartbeat = try await activeHeartbeat(
                after: lastObservedElapsed,
                metricsElement: metricsElement,
                stateElement: stateElement,
                progressingAfter: previousFunctionalSnapshot,
                diagnosticsElement: diagnosticsElement,
                in: app
            )
            lastObservedElapsed = heartbeat.elapsedSeconds
            try assertFunctionalProgress(
                from: previousFunctionalSnapshot,
                to: heartbeat
            )
            previousFunctionalSnapshot = heartbeat
            if clock.now >= nextMinute {
                if let prior = snapshots.last {
                    XCTAssertGreaterThan(heartbeat.elapsedSeconds, prior.elapsedSeconds)
                }
                if configuration.validatesSteadyStatePerformance {
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
            // app's accessibility tree on its main thread. During steady-state
            // performance validation, sample only at the same one-minute cadence
            // as the assertions; otherwise the observer itself disturbs the
            // playback workload it is trying to measure.
            let heartbeatInterval: Duration =
                configuration.validatesSteadyStatePerformance ? .seconds(60) : .seconds(10)
            try await clock.sleep(for: heartbeatInterval)
        }

        let final = try await activeHeartbeat(
            after: lastObservedElapsed,
            metricsElement: metricsElement,
            stateElement: stateElement,
            progressingAfter: previousFunctionalSnapshot,
            diagnosticsElement: diagnosticsElement,
            in: app
        )
        try assertFunctionalProgress(from: previousFunctionalSnapshot, to: final)
        if let prior = snapshots.last {
            XCTAssertGreaterThan(final.elapsedSeconds, prior.elapsedSeconds)
        }
        if configuration.validatesSteadyStatePerformance {
            assertSteadyStateCounterDelta(
                from: previousSteadySnapshot,
                to: final
            )
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
        diagnosticsElement: XCUIElement? = nil,
        timeout: Duration
    ) async throws -> AcceptanceMetricsSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastState: AcceptancePlaybackDiagnosticState?
        var didDecodeMetrics = false
        var lastSnapshot: AcceptanceMetricsSnapshot?
        while clock.now < deadline {
            let state = try playbackState(from: stateElement)
            do {
                try AcceptanceStableRouteFailureClassifier.validate(state: state)
            } catch {
                if let diagnosticsElement {
                    let diagnostic = diagnosticsElement.value as? String ?? "unavailable"
                    let attachment = XCTAttachment(string: diagnostic)
                    attachment.name = "playback-route-terminal-diagnostics.txt"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                throw error
            }
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
        stateElement: XCUIElement,
        progressingAfter previousSnapshot: AcceptanceMetricsSnapshot? = nil,
        diagnosticsElement: XCUIElement,
        in app: XCUIApplication
    ) async throws -> AcceptanceMetricsSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        var lastSnapshot: AcceptanceMetricsSnapshot?
        var replacementBaseline: (generation: String, clock: Double)?
        while clock.now < deadline {
            let state: AcceptancePlaybackDiagnosticState
            do {
                state = try playbackState(from: stateElement)
                try AcceptanceStableRouteFailureClassifier.validate(state: state)
                try assertActiveControls(in: app)
            } catch {
                let diagnostic = diagnosticsElement.value as? String ?? "unavailable"
                let attachment = XCTAttachment(string: diagnostic)
                attachment.name = "playback-terminal-diagnostics.txt"
                attachment.lifetime = .keepAlways
                add(attachment)
                throw error
            }
            guard state == .playing else {
                throw AcceptanceFailure.playbackNotPlaying
            }
            if let candidate = try? snapshot(from: metricsElement) {
                lastSnapshot = candidate
                let currentGeneration = avPlayerGeneration(
                    from: candidate.decoderSessionSummary
                )
                let mediaProgressed: Bool
                if let currentGeneration,
                   let previousSnapshot,
                   let currentTime = candidate.clockTimeSeconds,
                   let previousTime = previousSnapshot.clockTimeSeconds {
                    let previousGeneration = avPlayerGeneration(
                        from: previousSnapshot.decoderSessionSummary
                    )
                    if previousGeneration != currentGeneration {
                        if let baseline = replacementBaseline,
                           baseline.generation == currentGeneration {
                            mediaProgressed = currentTime > baseline.clock + 0.25
                        } else {
                            replacementBaseline = (currentGeneration, currentTime)
                            mediaProgressed = false
                        }
                    } else {
                        mediaProgressed = currentTime > previousTime + 0.25
                    }
                } else if let previousSnapshot {
                    mediaProgressed = candidate.videoAccessUnitCount
                        > previousSnapshot.videoAccessUnitCount
                        && candidate.videoDecodeSubmissionCount
                            > previousSnapshot.videoDecodeSubmissionCount
                        && candidate.videoRendererTotalFrameCount
                            > previousSnapshot.videoRendererTotalFrameCount
                } else {
                    mediaProgressed = true
                }
                let backendReady = currentGeneration != nil
                    ? candidate.audioReady
                        && candidate.readinessOpen
                        && candidate.clockTimeSeconds != nil
                    : candidate.decoderCallbacksPerSecond > 0
                        && candidate.videoRendererMetricsSampleCount > 0
                if candidate.elapsedSeconds > previousElapsed,
                   backendReady,
                   candidate.residentMemoryBytes > 0,
                   mediaProgressed {
                    return candidate
                }
            }
            try await clock.sleep(for: .milliseconds(500))
        }
        if let lastSnapshot {
            try attach(lastSnapshot, name: "playback-heartbeat-timeout.json")
        }
        let diagnostic = diagnosticsElement.value as? String ?? "unavailable"
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "playback-heartbeat-timeout-diagnostics.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        throw AcceptanceFailure.metricsDidNotAdvance
    }

    private func assertFunctionalProgress(
        from previous: AcceptanceMetricsSnapshot,
        to current: AcceptanceMetricsSnapshot
    ) throws {
        let previousAVPlayerGeneration = avPlayerGeneration(
            from: previous.decoderSessionSummary
        )
        let currentAVPlayerGeneration = avPlayerGeneration(
            from: current.decoderSessionSummary
        )
        if let currentAVPlayerGeneration {
            let previousClock = try XCTUnwrap(previous.clockTimeSeconds)
            let currentClock = try XCTUnwrap(current.clockTimeSeconds)
            if previousAVPlayerGeneration == currentAVPlayerGeneration {
                XCTAssertGreaterThan(currentClock, previousClock)
            } else {
                XCTAssertGreaterThan(currentClock, 0)
            }
        } else {
            XCTAssertGreaterThan(current.videoAccessUnitCount, previous.videoAccessUnitCount)
            XCTAssertGreaterThan(
                current.videoDecodeSubmissionCount,
                previous.videoDecodeSubmissionCount
            )
            XCTAssertGreaterThan(
                current.videoRendererTotalFrameCount,
                previous.videoRendererTotalFrameCount
            )
        }
        XCTAssertEqual(current.videoResyncCount, previous.videoResyncCount)
        XCTAssertEqual(current.audioContinuityDropCountsByReason.count, 5)
        XCTAssertEqual(previous.audioContinuityDropCountsByReason.count, 5)
        for index in 0..<5 {
            XCTAssertGreaterThanOrEqual(
                current.audioContinuityDropCountsByReason[index],
                previous.audioContinuityDropCountsByReason[index]
            )
        }
        XCTAssertGreaterThanOrEqual(current.audioShortGapCount, previous.audioShortGapCount)
        XCTAssertGreaterThanOrEqual(current.audioLargeGapCount, previous.audioLargeGapCount)
        XCTAssertGreaterThanOrEqual(
            current.audioContinuityIslandSwitchCount,
            previous.audioContinuityIslandSwitchCount
        )
        XCTAssertGreaterThanOrEqual(
            current.audioRendererBackpressureCount,
            previous.audioRendererBackpressureCount
        )
        XCTAssertGreaterThanOrEqual(
            current.audioRendererRequestRearmCount,
            previous.audioRendererRequestRearmCount
        )
        XCTAssertGreaterThanOrEqual(
            current.audioAutomaticFlushNoProgressCount,
            previous.audioAutomaticFlushNoProgressCount
        )

        let bufferingIndex = 1
        let previousBufferingCloses = previous.readinessCloseReasonCounts.indices.contains(
            bufferingIndex
        ) ? previous.readinessCloseReasonCounts[bufferingIndex] : 0
        let currentBufferingCloses = current.readinessCloseReasonCounts.indices.contains(
            bufferingIndex
        ) ? current.readinessCloseReasonCounts[bufferingIndex] : 0
        XCTAssertEqual(currentBufferingCloses, previousBufferingCloses)

        let discontinuityIndex = 3
        let previousDiscontinuities = previous.readinessCloseReasonCounts.indices.contains(
            discontinuityIndex
        ) ? previous.readinessCloseReasonCounts[discontinuityIndex] : 0
        let currentDiscontinuities = current.readinessCloseReasonCounts.indices.contains(
            discontinuityIndex
        ) ? current.readinessCloseReasonCounts[discontinuityIndex] : 0
        if currentDiscontinuities == previousDiscontinuities,
           avPlayerGeneration(from: previous.decoderSessionSummary)
            == avPlayerGeneration(from: current.decoderSessionSummary) {
            let previousClock = try XCTUnwrap(previous.clockTimeSeconds)
            let currentClock = try XCTUnwrap(current.clockTimeSeconds)
            XCTAssertGreaterThanOrEqual(currentClock, previousClock)
        }
    }

    private func avPlayerGeneration(from summary: String?) -> String? {
        summary?.split(separator: ",").lazy
            .first(where: { $0.hasPrefix("avplayer:gen=") })?
            .split(separator: "=", maxSplits: 1).last.map(String.init)
    }

    @MainActor
    private func assertActiveControls(in app: XCUIApplication) throws {
        let visibility = app.otherElements["player-controls-visibility"]
        guard app.otherElements["player-full-screen"].exists,
              visibility.exists,
              app.buttons.matching(identifier: "player-retry").count == 0 else {
            throw AcceptanceNavigationFailure(
                target: .activePlayerControls,
                phase: .awaitExistence
            )
        }
        // 播放中的控制条会在 3 秒后正常自动隐藏，opacity=0 时 tvOS
        // 不再向无障碍树暴露其按钮。长时验收不应因此把健康播放
        // 误判为导航丢失；只在控制条可见时验证按钮完整性。
        if visibility.value as? String == "visible" {
            guard app.buttons["player-play-pause"].exists,
                  app.buttons["player-settings"].exists else {
                throw AcceptanceNavigationFailure(
                    target: .activePlayerControls,
                    phase: .awaitExistence
                )
            }
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
        let avPlayerSummary = snapshot.decoderSessionSummary.flatMap { summary in
            summary.hasPrefix("avplayer:") ? summary : nil
        }

        XCTAssertGreaterThan(snapshot.residentMemoryBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInFlightCount, 3)
        // 验收启动会重置为 8 帧容量；参考窗口可在调度前短暂持有下一帧。
        XCTAssertLessThanOrEqual(snapshot.maximumYADIFInputDepth, 9)
        XCTAssertEqual(snapshot.audioContinuityDropCountsByReason.count, 5)
        XCTAssertGreaterThanOrEqual(snapshot.audioPendingSampleCount, 0)
        XCTAssertLessThanOrEqual(snapshot.audioPendingSampleCount, 1_120)
        if let avPlayerSummary {
            // HLS playback is rendered by AVPlayer, so the sample-buffer
            // decoder, renderer and Metal counters intentionally stay at zero.
            // Functional heartbeats separately prove that its media clock keeps
            // advancing; here validate the native player's steady state.
            XCTAssertNotNil(snapshot.clockTimeSeconds)
            XCTAssertTrue(avPlayerSummary.contains("tc=playing"))
            XCTAssertTrue(avPlayerSummary.contains("item=ready"))
            XCTAssertTrue(avPlayerSummary.contains("rate=1.000"))
        } else {
            XCTAssertGreaterThan(snapshot.decoderCallbacksPerSecond, 0)
            XCTAssertGreaterThan(snapshot.videoRendererMetricsSampleCount, 0)
            XCTAssertGreaterThan(snapshot.videoRendererTotalFrameCount, 0)
        }
        if let lastAcceptedPTSSeconds = snapshot.audioLastAcceptedPTSSeconds {
            XCTAssertTrue(lastAcceptedPTSSeconds.isFinite)
        }
        if let progressAgeSeconds = snapshot.audioLastRendererProgressAgeSeconds {
            XCTAssertTrue(progressAgeSeconds.isFinite)
            XCTAssertGreaterThanOrEqual(progressAgeSeconds, 0)
        }
        if snapshot.elapsedSeconds >= 60 {
            XCTAssertGreaterThanOrEqual(snapshot.windowDurationSeconds, 55)
            XCTAssertLessThanOrEqual(snapshot.windowDurationSeconds, 60.5)
        }

        XCTAssertGreaterThanOrEqual(
            snapshot.videoRendererTotalFrameCount,
            snapshot.videoRendererDroppedFrameCount
        )
        let validatesSteadyStatePerformance = configuration.validatesSteadyStatePerformance

        if configuration.channel == "东方卫视 4K" {
            XCTAssertEqual(snapshot.scanType, "progressive")
            XCTAssertEqual(snapshot.activeRoute, "bypass")
            XCTAssertEqual(snapshot.yadifKernelDispatchCount, 0)
            if validatesSteadyStatePerformance, avPlayerSummary == nil {
                XCTAssertTrue((48...52).contains(snapshot.decoderCallbacksPerSecond))
            }
            return
        }
        if configuration.channel == "中天新闻" {
            XCTAssertEqual(snapshot.scanType, "progressive")
            XCTAssertEqual(snapshot.activeRoute, "bypass")
            if validatesSteadyStatePerformance, avPlayerSummary == nil {
                XCTAssertTrue((28...32).contains(snapshot.decoderCallbacksPerSecond))
            }
            return
        }
        if ["东方卫视 HD", "五星体育 HD"].contains(configuration.channel) {
            XCTAssertEqual(snapshot.scanType, "interlaced")
        }
        guard snapshot.scanType == "interlaced" else { return }

        XCTAssertEqual(snapshot.activeRoute, "metalYADIF2x")
        guard avPlayerSummary == nil else { return }
        XCTAssertGreaterThan(snapshot.yadifKernelDispatchCount, 0)
        XCTAssertGreaterThan(snapshot.gpuDurationP95Milliseconds, 0)
        if validatesSteadyStatePerformance {
            XCTAssertTrue((22...28).contains(snapshot.decoderCallbacksPerSecond))
            guard snapshot.decoderCallbacksPerSecond > 0 else { return }
            // One YADIF command consumes one interlaced input frame and emits
            // both field-rate output frames. Its sustainable GPU budget is the
            // observed input-frame period, not an arbitrary display-frame
            // threshold such as 16 ms.
            XCTAssertLessThanOrEqual(
                snapshot.gpuDurationP95Milliseconds,
                1_000 / snapshot.decoderCallbacksPerSecond
            )
        }
    }

    private func assertSteadyStateCounterDelta(
        from previous: AcceptanceMetricsSnapshot,
        to current: AcceptanceMetricsSnapshot
    ) {
        // AVPlayer owns presentation for HLS playback. Its progress is checked
        // by assertFunctionalProgress using the native media clock, while these
        // counters belong only to the sample-buffer renderer.
        guard avPlayerGeneration(from: current.decoderSessionSummary) == nil else {
            return
        }
        XCTAssertGreaterThanOrEqual(
            previous.videoRendererTotalFrameCount,
            previous.videoRendererDroppedFrameCount
        )
        XCTAssertGreaterThanOrEqual(
            current.videoRendererTotalFrameCount,
            current.videoRendererDroppedFrameCount
        )
        XCTAssertNoThrow(try AcceptanceSnapshotValidator.validateCounterDelta(
            previousPresented: previous.videoRendererTotalFrameCount
                - previous.videoRendererDroppedFrameCount,
            previousDropped: previous.videoRendererDroppedFrameCount,
            currentPresented: current.videoRendererTotalFrameCount
                - current.videoRendererDroppedFrameCount,
            currentDropped: current.videoRendererDroppedFrameCount
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
    case playbackNotPlaying
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
        case .playbackNotPlaying:
            "acceptance playback is not playing"
        case let .playbackFailed(code):
            "acceptance playback failed code=\(code)"
        }
    }
}

private enum AcceptancePlaybackDiagnosticState: Equatable {
    case idle
    case preparing
    case buffering
    case recovering
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
        case "buffering":
            self = .buffering
        case "recovering":
            self = .recovering
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
        if lastState == .preparing || lastState == .buffering {
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

    var validatesSteadyStatePerformance: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        AcceptanceValidationPolicy.requiresSteadyStatePerformance(duration: duration)
        #endif
    }

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
    let yadifKernelDispatchCount: UInt64
    let staleGenerationDropCount: UInt64
    let droppedVideoFrames: UInt64
    let videoDropCountsBySource: [UInt64]
    let lastVideoDecodeFailure: String?
    let maximumYADIFInFlightCount: Int
    let maximumYADIFInputDepth: Int
    let gpuDurationP95Milliseconds: Double
    let yadifCPUEncodeP95Milliseconds: Double
    let residentMemoryBytes: UInt64
    let elapsedSeconds: Double
    let windowDurationSeconds: Double
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
    let videoRendererMetricsSampleCount: UInt64
    let videoRendererMetricsEpochCount: UInt64
    let videoRendererTotalFrameCount: UInt64
    let videoRendererDroppedFrameCount: UInt64
    let videoRendererCorruptedFrameCount: UInt64
    let videoRendererOptimizedFrameCount: UInt64
    let videoRendererAccumulatedFrameDelayMilliseconds: Double
    let clockTimeSeconds: Double?
    let videoResyncCount: UInt64
    let audioRecoveryCount: UInt64
    let audioPendingSampleCount: Int
    let audioRendererRequestArmed: Bool
    let audioRendererBackpressureCount: UInt64
    let audioRendererRequestRearmCount: UInt64
    let audioAutomaticFlushNoProgressCount: UInt64
    let audioLastAcceptedPTSSeconds: Double?
    let audioLastRendererProgressAgeSeconds: Double?
    let audioContinuityDropCountsByReason: [UInt64]
    let audioShortGapCount: UInt64
    let audioLargeGapCount: UInt64
    let audioContinuityIslandSwitchCount: UInt64
    let demuxQueueFullWaitSeconds: Double
    let demuxAdmitWaitSeconds: Double
    let playbackExecutorBusySeconds: Double
    let totalVideoDecodeSubmissionMilliseconds: Double
    let maximumOutstandingDecoderOutputs: Int
    let maximumDecodeSubmissionDepth: Int
    let maximumFramesBeingDecoded: Int
    let decoderSessionSummary: String?
    let decodeCallbackLatencyP95Milliseconds: Double
    let videoDecodeSubmissionP95Milliseconds: Double
    let demuxPacketCount: UInt64
    let videoAccessUnitCount: UInt64
    let audioSampleCount: UInt64
    let videoDecodeSubmissionCount: UInt64
    let maximumVideoDecodeSubmissionMilliseconds: Double
}

// MARK: - Task 27 Acceptance Test Support & Analyzers

public struct LongPlaybackSample: Sendable, Equatable {
    public var sequence: Int
    public var timestampNanoseconds: UInt64
    public var physicalFootprintBytes: UInt64
    public var availableMemoryBytes: UInt64
    public var encoderBacklog: Int
    public var writerBacklog: Int
    public var deliveryBacklogBytes: UInt64
    public var route: String
    public var lifecycleState: String

    public var deliveryBacklog: Int {
        Int(min(deliveryBacklogBytes, UInt64(Int.max)))
    }

    public init(
        sequence: Int,
        timestampNanoseconds: UInt64,
        physicalFootprintBytes: UInt64,
        availableMemoryBytes: UInt64 = 268_435_456,
        encoderBacklog: Int = 0,
        writerBacklog: Int = 0,
        deliveryBacklogBytes: UInt64 = 0,
        deliveryBacklog: Int? = nil,
        route: String = "airPlayHLS",
        lifecycleState: String = "active"
    ) {
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.physicalFootprintBytes = physicalFootprintBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.encoderBacklog = encoderBacklog
        self.writerBacklog = writerBacklog
        self.deliveryBacklogBytes = deliveryBacklog.map { UInt64($0) } ?? deliveryBacklogBytes
        self.route = route
        self.lifecycleState = lifecycleState
    }
}

public enum LongPlaybackMemoryMeasurementError: Error, Equatable, CustomStringConvertible {
    case emptySamples
    case duplicateTimestamp(sequence: Int)
    case nonMonotonicTimestamp(sequence: Int)
    case sampleTimingWindowExceeded(sequence: Int, offsetNanoseconds: Int64)
    case footprintExceedsInt64Max(sequence: Int, bytes: UInt64)
    case missingRequiredSample(sequence: Int)
    case incompleteCoverage(sampleCount: Int, requiredCount: Int)
    case maximumFootprintExceeded(footprintBytes: UInt64, allowedBytes: UInt64)
    case minimumAvailableMemoryRegressed(availableBytes: UInt64, requiredBytes: UInt64)
    case unboundedGrowthDetected(growthBytes: UInt64, allowedBytes: UInt64)
    case backlogHardCapExceeded(queue: String, count: Int, limit: Int)
    case routeDisrupted(sequence: Int, route: String)
    case lifecycleDisrupted(sequence: Int, state: String)

    public var description: String {
        switch self {
        case .emptySamples:
            return "long playback samples cannot be empty"
        case let .duplicateTimestamp(seq):
            return "duplicate timestamp detected at sequence \(seq)"
        case let .nonMonotonicTimestamp(seq):
            return "non-monotonic timestamp detected at sequence \(seq)"
        case let .sampleTimingWindowExceeded(seq, offset):
            return "sample timing window exceeded at sequence \(seq) offset=\(offset)ns"
        case let .footprintExceedsInt64Max(seq, bytes):
            return "physical footprint exceeds Int64.max at sequence \(seq) bytes=\(bytes)"
        case let .missingRequiredSample(seq):
            return "missing required sample sequence \(seq)"
        case let .incompleteCoverage(count, req):
            return "incomplete two-hour coverage: \(count)/\(req) samples"
        case let .maximumFootprintExceeded(bytes, allowed):
            return "maximum physical footprint exceeded: \(bytes) > \(allowed) bytes"
        case let .minimumAvailableMemoryRegressed(bytes, req):
            return "available memory regressed below requirement: \(bytes) < \(req) bytes"
        case let .unboundedGrowthDetected(bytes, allowed):
            return "unbounded memory growth detected: \(bytes) > \(allowed) bytes"
        case let .backlogHardCapExceeded(queue, count, limit):
            return "backlog hard cap exceeded for \(queue): \(count) > \(limit)"
        case let .routeDisrupted(seq, route):
            return "mid-playback route disrupted at sequence \(seq): \(route)"
        case let .lifecycleDisrupted(seq, state):
            return "mid-playback lifecycle disrupted at sequence \(seq): \(state)"
        }
    }
}

public struct LongPlaybackMemoryMeasurement: Sendable {
    public static let requiredTotalSampleCount = 7_200
    public static let allowedFootprintBytes: UInt64 = 1_610_612_736 // 1.5 GiB
    public static let requiredAvailableMemoryBytes: UInt64 = 268_435_456 // 256 MiB
    public static let allowedGrowthBytes: UInt64 = 33_554_432 // 32 MiB
    public static let maxEncoderBacklog = 4
    public static let maxWriterBacklog = 8
    public static let maxDeliveryBacklogBytes: UInt64 = 16_777_216 // 16 MiB

    public let samples: [LongPlaybackSample]
    public let maximumFootprintBytes: UInt64
    public let allowedFootprintBytes: UInt64
    public let minimumAvailableMemoryBytes: UInt64
    public let requiredAvailableMemoryBytes: UInt64
    public let baselineWindowBMedianFloor: UInt64?
    public let finalWindowRMedianFloor: UInt64?
    public let growthBytes: UInt64?
    public let hasCompleteTwoHourCoverage: Bool
    public let noUnboundedGrowth: Bool
    public let hasAdequateAvailableMemory: Bool
    public let missingSequenceNumber: Int?

    public static func positiveDelta(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let signedA = Int64(min(a, UInt64(Int64.max)))
        let signedB = Int64(min(b, UInt64(Int64.max)))
        return signedA <= signedB ? 0 : UInt64(signedA - signedB)
    }

    public static func medianFloor60(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        precondition(sorted.count == 60)
        let x30 = sorted[29]
        let x31 = sorted[30]
        return x30 + (x31 - x30) / 2
    }

    public static func median5(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        precondition(sorted.count == 5)
        return sorted[2]
    }

    public init(samples: [LongPlaybackSample], t0Nanoseconds: UInt64? = nil) throws {
        guard !samples.isEmpty else {
            throw LongPlaybackMemoryMeasurementError.emptySamples
        }
        self.samples = samples
        self.allowedFootprintBytes = Self.allowedFootprintBytes
        self.requiredAvailableMemoryBytes = Self.requiredAvailableMemoryBytes

        let effectiveT0: UInt64
        if let t0 = t0Nanoseconds {
            effectiveT0 = t0
        } else {
            // Infer sub-second t0 without truncating to whole seconds: t_n = t0 + n * 1s
            let first = samples[0]
            let expectedAdvance = UInt64(first.sequence) * 1_000_000_000
            if first.timestampNanoseconds >= expectedAdvance {
                effectiveT0 = first.timestampNanoseconds - expectedAdvance
            } else {
                effectiveT0 = 0
            }
        }

        var maxFp: UInt64 = 0
        var minAvail: UInt64 = UInt64.max
        var prevTimestamp: UInt64?

        var windowBSamples: [UInt64] = []
        windowBSamples.reserveCapacity(60)
        var windowRSamples: [UInt64] = []
        windowRSamples.reserveCapacity(60)

        var seenSequences = [Bool](repeating: false, count: Self.requiredTotalSampleCount + 1)
        var sampleCount = 0

        for sample in samples {
            // Int64.max check
            guard sample.physicalFootprintBytes <= UInt64(Int64.max) else {
                throw LongPlaybackMemoryMeasurementError.footprintExceedsInt64Max(
                    sequence: sample.sequence,
                    bytes: sample.physicalFootprintBytes
                )
            }

            // Monotonicity / duplicate check
            if let prev = prevTimestamp {
                if sample.timestampNanoseconds == prev {
                    throw LongPlaybackMemoryMeasurementError.duplicateTimestamp(sequence: sample.sequence)
                } else if sample.timestampNanoseconds < prev {
                    throw LongPlaybackMemoryMeasurementError.nonMonotonicTimestamp(sequence: sample.sequence)
                }
            }
            prevTimestamp = sample.timestampNanoseconds

            // Timing window check [t_n, t_n + 500ms]
            let tn = effectiveT0 + UInt64(sample.sequence) * 1_000_000_000
            if sample.timestampNanoseconds < tn {
                let offset = Int64(sample.timestampNanoseconds) - Int64(tn)
                throw LongPlaybackMemoryMeasurementError.sampleTimingWindowExceeded(
                    sequence: sample.sequence,
                    offsetNanoseconds: offset
                )
            }
            let diff = sample.timestampNanoseconds - tn
            if diff > 500_000_000 {
                throw LongPlaybackMemoryMeasurementError.sampleTimingWindowExceeded(
                    sequence: sample.sequence,
                    offsetNanoseconds: Int64(diff)
                )
            }

            // Route disruption check
            guard sample.route == "airPlayHLS" else {
                throw LongPlaybackMemoryMeasurementError.routeDisrupted(
                    sequence: sample.sequence,
                    route: sample.route
                )
            }

            // Lifecycle disruption check
            guard sample.lifecycleState == "active" else {
                throw LongPlaybackMemoryMeasurementError.lifecycleDisrupted(
                    sequence: sample.sequence,
                    state: sample.lifecycleState
                )
            }

            // Backlog hard caps
            guard sample.encoderBacklog <= Self.maxEncoderBacklog else {
                throw LongPlaybackMemoryMeasurementError.backlogHardCapExceeded(
                    queue: "encoder",
                    count: sample.encoderBacklog,
                    limit: Self.maxEncoderBacklog
                )
            }
            guard sample.writerBacklog <= Self.maxWriterBacklog else {
                throw LongPlaybackMemoryMeasurementError.backlogHardCapExceeded(
                    queue: "writer",
                    count: sample.writerBacklog,
                    limit: Self.maxWriterBacklog
                )
            }
            guard sample.deliveryBacklogBytes <= Self.maxDeliveryBacklogBytes else {
                throw LongPlaybackMemoryMeasurementError.backlogHardCapExceeded(
                    queue: "delivery",
                    count: Int(min(sample.deliveryBacklogBytes, UInt64(Int.max))),
                    limit: Int(Self.maxDeliveryBacklogBytes)
                )
            }

            maxFp = max(maxFp, sample.physicalFootprintBytes)
            minAvail = min(minAvail, sample.availableMemoryBytes)

            if sample.sequence >= 1 && sample.sequence <= Self.requiredTotalSampleCount {
                seenSequences[sample.sequence] = true
            }
            if sample.sequence >= 841 && sample.sequence <= 900 {
                windowBSamples.append(sample.physicalFootprintBytes)
            }
            if sample.sequence >= 7141 && sample.sequence <= 7200 {
                windowRSamples.append(sample.physicalFootprintBytes)
            }
            sampleCount += 1
        }

        self.maximumFootprintBytes = maxFp
        self.minimumAvailableMemoryBytes = minAvail
        self.hasAdequateAvailableMemory = minAvail >= Self.requiredAvailableMemoryBytes

        // Coverage check: check if 1...7200 are present
        var missingSeq: Int?
        for seq in 1...Self.requiredTotalSampleCount {
            if !seenSequences[seq] {
                missingSeq = seq
                break
            }
        }
        self.missingSequenceNumber = missingSeq

        let bMedian: UInt64? = windowBSamples.count == 60 ? Self.medianFloor60(windowBSamples) : nil
        self.baselineWindowBMedianFloor = bMedian

        let rMedian: UInt64? = windowRSamples.count == 60 ? Self.medianFloor60(windowRSamples) : nil
        self.finalWindowRMedianFloor = rMedian

        let isComplete = (missingSeq == nil && bMedian != nil && rMedian != nil && sampleCount >= Self.requiredTotalSampleCount)
        self.hasCompleteTwoHourCoverage = isComplete

        if let b = bMedian, let r = rMedian {
            let growth = Self.positiveDelta(r, b)
            self.growthBytes = growth
            self.noUnboundedGrowth = growth <= Self.allowedGrowthBytes
        } else {
            self.growthBytes = nil
            self.noUnboundedGrowth = false
        }
    }

    public func validate() throws {
        guard maximumFootprintBytes <= allowedFootprintBytes else {
            throw LongPlaybackMemoryMeasurementError.maximumFootprintExceeded(
                footprintBytes: maximumFootprintBytes,
                allowedBytes: allowedFootprintBytes
            )
        }
        guard minimumAvailableMemoryBytes >= requiredAvailableMemoryBytes else {
            throw LongPlaybackMemoryMeasurementError.minimumAvailableMemoryRegressed(
                availableBytes: minimumAvailableMemoryBytes,
                requiredBytes: requiredAvailableMemoryBytes
            )
        }
        if let growth = growthBytes {
            guard growth <= Self.allowedGrowthBytes else {
                throw LongPlaybackMemoryMeasurementError.unboundedGrowthDetected(
                    growthBytes: growth,
                    allowedBytes: Self.allowedGrowthBytes
                )
            }
        }
        if let missing = missingSequenceNumber {
            throw LongPlaybackMemoryMeasurementError.missingRequiredSample(sequence: missing)
        }
        guard hasCompleteTwoHourCoverage else {
            throw LongPlaybackMemoryMeasurementError.incompleteCoverage(
                sampleCount: samples.count,
                requiredCount: Self.requiredTotalSampleCount
            )
        }
    }
}

// MARK: - AAC Priming RSS Worst Case Fixture & Measurement

public enum AACPrimingRSSWorstCaseFixtureV1 {
    public static let sampleRate: Double = 48_000
    public static let channelCount: Int = 8
    public static let frameCount: Int = 16_384
    public static let byteCount: Int = 524_288
    public static let expectedSHA256: String = "a5172ccbd0cc73fbf901bec1c869255744fd2422fd0898f61a3c67135b616721"

    public static func generateChannelSamples() -> [[Float]] {
        var channels: [[Float]] = []
        channels.reserveCapacity(8)
        for c in 0..<8 {
            var channel = [Float](repeating: 0.0, count: 16_384)
            var x = (0x243F6A8885A308D3 &+ UInt64(c) &* 0x9E3779B97F4A7C15)
            for i in 4_096..<12_288 {
                x ^= x >> 12
                x ^= x << 25
                x ^= x >> 27
                let y = x &* 2685821657736338717
                let val = Int32(bitPattern: UInt32(truncatingIfNeeded: y >> 32))
                channel[i] = (Float(val) / 2147483648.0) * 0.25
            }
            channels.append(channel)
        }
        return channels
    }

    public static func generateSerializedData() -> Data {
        let channels = generateChannelSamples()
        var data = Data(capacity: byteCount)
        for channel in channels {
            for sample in channel {
                var leSample = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &leSample) { buffer in
                    data.append(contentsOf: buffer)
                }
            }
        }
        return data
    }

    public static func verifyDigest(data: Data) -> Bool {
        let digest = SHA256.hash(data: data)
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        return hashString == expectedSHA256
    }
}

public struct AACQuiescencePoint: Sendable, Equatable {
    public var elapsedSeconds: Double
    public var footprintBytes: UInt64

    public init(elapsedSeconds: Double, footprintBytes: UInt64) {
        self.elapsedSeconds = elapsedSeconds
        self.footprintBytes = footprintBytes
    }
}

public struct AACPeakSample: Sendable, Equatable {
    public var offsetSeconds: Double
    public var footprintBytes: UInt64

    public init(offsetSeconds: Double, footprintBytes: UInt64) {
        self.offsetSeconds = offsetSeconds
        self.footprintBytes = footprintBytes
    }
}

public struct AACPrimingRoundResult: Sendable, Equatable {
    public var roundIndex: Int
    public var quiescencePoints: [AACQuiescencePoint]
    public var peakSamples: [AACPeakSample]
    public var postCleanupPoints: [AACQuiescencePoint]
    public var transactionStartSeconds: Double
    public var cleanupTerminalSeconds: Double

    public init(
        roundIndex: Int,
        quiescencePoints: [AACQuiescencePoint],
        peakSamples: [AACPeakSample],
        postCleanupPoints: [AACQuiescencePoint],
        transactionStartSeconds: Double,
        cleanupTerminalSeconds: Double
    ) {
        self.roundIndex = roundIndex
        self.quiescencePoints = quiescencePoints
        self.peakSamples = peakSamples
        self.postCleanupPoints = postCleanupPoints
        self.transactionStartSeconds = transactionStartSeconds
        self.cleanupTerminalSeconds = cleanupTerminalSeconds
    }
}

public enum AACPrimingMeasurementError: Error, Equatable, CustomStringConvertible {
    case taskInfoFailed
    case quiescenceIntervalViolation
    case quiescenceDeadlineExceeded
    case quiescenceRangeExceeded(rangeBytes: UInt64, allowedBytes: UInt64)
    case quiescenceInsufficientPoints(count: Int, required: Int)
    case peakSamplingIntervalExceeded
    case peakWindowMissingTransactionStart
    case peakWindowMissingCleanupTerminal
    case peakDeltaExceeded(deltaBytes: UInt64, allowedBytes: UInt64)
    case residueGrowthExceeded(growthBytes: UInt64, allowedBytes: UInt64)
    case residueSlopeExceeded(slope: Double, allowedSlope: Double)
    case footprintExceedsInt64Max
    case insufficientRounds(count: Int, required: Int)

    public var description: String {
        switch self {
        case .taskInfoFailed:
            return "task_info(TASK_VM_INFO) call failed"
        case .quiescenceIntervalViolation:
            return "quiescence sampling interval was outside [90ms, 110ms]"
        case .quiescenceDeadlineExceeded:
            return "quiescence sampling did not complete strictly before 5.0 seconds"
        case let .quiescenceRangeExceeded(range, allowed):
            return "quiescence range exceeded: \(range) > \(allowed) bytes"
        case let .quiescenceInsufficientPoints(count, req):
            return "insufficient quiescence points: \(count)/\(req)"
        case .peakSamplingIntervalExceeded:
            return "peak sampling interval exceeded (0, 7.5ms]"
        case .peakWindowMissingTransactionStart:
            return "peak window first sample did not precede transaction creation"
        case .peakWindowMissingCleanupTerminal:
            return "peak window last sample did not follow cleanup terminal"
        case let .peakDeltaExceeded(delta, allowed):
            return "peak delta exceeded: \(delta) > \(allowed) bytes"
        case let .residueGrowthExceeded(growth, allowed):
            return "residue growth exceeded: \(growth) > \(allowed) bytes"
        case let .residueSlopeExceeded(slope, allowed):
            return "residue slope exceeded: \(slope) > \(allowed) bytes/round"
        case .footprintExceedsInt64Max:
            return "footprint reading exceeded Int64.max"
        case let .insufficientRounds(count, req):
            return "insufficient formal rounds: \(count)/\(req)"
        }
    }
}

public enum AACQuiescenceValidator {
    public static func validate(points: [AACQuiescencePoint]) throws -> UInt64 {
        guard points.count == 10 else {
            throw AACPrimingMeasurementError.quiescenceInsufficientPoints(count: points.count, required: 10)
        }
        for i in 1..<10 {
            let dt = points[i].elapsedSeconds - points[i - 1].elapsedSeconds
            // [90ms, 110ms] = [0.090, 0.110]
            guard dt >= 0.089999999999 && dt <= 0.110000000001 else {
                throw AACPrimingMeasurementError.quiescenceIntervalViolation
            }
        }
        guard points[9].elapsedSeconds < 5.0 else {
            throw AACPrimingMeasurementError.quiescenceDeadlineExceeded
        }
        let sorted = points.map(\.footprintBytes).sorted()
        let range = sorted.last! - sorted.first!
        guard range <= 262_144 else {
            throw AACPrimingMeasurementError.quiescenceRangeExceeded(rangeBytes: range, allowedBytes: 262_144)
        }
        let x5 = sorted[4]
        let x6 = sorted[5]
        return x5 + (x6 - x5) / 2
    }
}

public enum AACPeakValidator {
    public static func validate(
        samples: [AACPeakSample],
        transactionStartSeconds: Double,
        cleanupTerminalSeconds: Double
    ) throws -> UInt64 {
        guard !samples.isEmpty else {
            throw AACPrimingMeasurementError.peakWindowMissingTransactionStart
        }
        guard samples.first!.offsetSeconds <= transactionStartSeconds else {
            throw AACPrimingMeasurementError.peakWindowMissingTransactionStart
        }
        guard samples.last!.offsetSeconds >= cleanupTerminalSeconds else {
            throw AACPrimingMeasurementError.peakWindowMissingCleanupTerminal
        }
        for i in 1..<samples.count {
            let dt = samples[i].offsetSeconds - samples[i - 1].offsetSeconds
            guard dt > 0.0 && dt <= 0.0075000000001 else {
                throw AACPrimingMeasurementError.peakSamplingIntervalExceeded
            }
        }
        return samples.map(\.footprintBytes).max()!
    }
}

public enum AACPrimingThresholdValidator {
    public static let allowedPeakDelta: UInt64 = 33_554_432 // 32 MiB
    public static let allowedResidueDelta: UInt64 = 2_097_152 // 2 MiB
    public static let allowedSlope: Double = 131_072.0 // 128 KiB/round

    public static func validatePeakDelta(_ delta: UInt64) throws {
        guard delta <= allowedPeakDelta else {
            throw AACPrimingMeasurementError.peakDeltaExceeded(
                deltaBytes: delta,
                allowedBytes: allowedPeakDelta
            )
        }
    }

    public static func validateResidueMedianDelta(_ delta: UInt64) throws {
        guard delta <= allowedResidueDelta else {
            throw AACPrimingMeasurementError.residueGrowthExceeded(
                growthBytes: delta,
                allowedBytes: allowedResidueDelta
            )
        }
    }

    public static func validateSlope(_ slope: Double) throws {
        guard slope <= allowedSlope else {
            throw AACPrimingMeasurementError.residueSlopeExceeded(
                slope: slope,
                allowedSlope: allowedSlope
            )
        }
    }

    public static func saturatedSlope(_ rawSlope: Double) -> Double {
        max(0.0, rawSlope)
    }

    public static func calculateOLSSlope(y: [UInt64]) -> Double {
        precondition(y.count == 20)
        let n = 20.0
        let iMean = 10.5
        let yMean = y.reduce(0.0) { $0 + Double($1) } / n
        var numerator = 0.0
        var denominator = 0.0
        for i in 1...20 {
            let di = Double(i) - iMean
            let dy = Double(y[i - 1]) - yMean
            numerator += di * dy
            denominator += di * di
        }
        return numerator / denominator
    }
}

public struct AACPrimingRSSMeasurement: Sendable {
    public let rounds: [AACPrimingRoundResult]
    public let baselines: [UInt64]
    public let peaks: [UInt64]
    public let residues: [UInt64]
    public let maximumPeakDeltaBytes: UInt64
    public let residueGrowthBytes: UInt64
    public let residueSlopeBytesPerRound: Double

    public init(rounds: [AACPrimingRoundResult]) throws {
        guard rounds.count == 20 else {
            throw AACPrimingMeasurementError.insufficientRounds(count: rounds.count, required: 20)
        }
        self.rounds = rounds

        var bList: [UInt64] = []
        var pList: [UInt64] = []
        var rList: [UInt64] = []
        var maxPeakDelta: UInt64 = 0

        for r in rounds {
            let b = try AACQuiescenceValidator.validate(points: r.quiescencePoints)
            let p = try AACPeakValidator.validate(
                samples: r.peakSamples,
                transactionStartSeconds: r.transactionStartSeconds,
                cleanupTerminalSeconds: r.cleanupTerminalSeconds
            )
            let res = try AACQuiescenceValidator.validate(points: r.postCleanupPoints)

            bList.append(b)
            pList.append(p)
            rList.append(res)

            let peakDelta = LongPlaybackMemoryMeasurement.positiveDelta(p, b)
            maxPeakDelta = max(maxPeakDelta, peakDelta)
        }

        self.baselines = bList
        self.peaks = pList
        self.residues = rList
        self.maximumPeakDeltaBytes = maxPeakDelta

        // positiveDelta(medianFloor(R_16...R_20), B_1) <= 2 MiB
        let rLast5 = Array(rList[15..<20])
        let rMedian = LongPlaybackMemoryMeasurement.median5(rLast5)
        self.residueGrowthBytes = LongPlaybackMemoryMeasurement.positiveDelta(rMedian, bList[0])

        // OLS slope
        let rawSlope = AACPrimingThresholdValidator.calculateOLSSlope(y: rList)
        self.residueSlopeBytesPerRound = AACPrimingThresholdValidator.saturatedSlope(rawSlope)
    }

    public func validate() throws {
        for delta in peaks.indices.map({ LongPlaybackMemoryMeasurement.positiveDelta(peaks[$0], baselines[$0]) }) {
            try AACPrimingThresholdValidator.validatePeakDelta(delta)
        }
        try AACPrimingThresholdValidator.validateResidueMedianDelta(residueGrowthBytes)
        try AACPrimingThresholdValidator.validateSlope(residueSlopeBytesPerRound)
    }
}
