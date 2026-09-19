// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import AVFoundation
import AVKit
import Foundation
import XCTest
@testable import VPlayer
@testable import VPlayerPlayback

@MainActor
final class FullScreenPlayerViewModelTests: XCTestCase {
    func testPlayerOverlayUsesOneThreeSecondSteadyPlaybackTimeout() {
        let request = makeRequest()

        XCTAssertEqual(PlayerControlsVisibilityPolicy.idleTimeout, .seconds(3))
        XCTAssertFalse(PlayerControlsVisibilityPolicy.staysVisible(for: .playing(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .preparing(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .buffering(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .recovering(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .paused(request)))
    }

    func testTransportControlsAutoHideOnlyDuringSteadyPlayback() {
        let request = makeRequest()
        let failure = PlaybackFailure(code: "demux.open", userMessage: "failed")

        // Steady playback is timed; preparing and paused are pinned. Terminal
        // states must remove the transport and channel overlays entirely.
        XCTAssertFalse(PlayerControlsVisibilityPolicy.staysVisible(for: .playing(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .idle))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .preparing(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .buffering(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .recovering(request)))
        XCTAssertTrue(PlayerControlsVisibilityPolicy.staysVisible(for: .paused(request)))
        XCTAssertFalse(PlayerControlsVisibilityPolicy.staysVisible(for: .stopped))
        XCTAssertFalse(PlayerControlsVisibilityPolicy.staysVisible(for: .failed(failure)))
        XCTAssertGreaterThan(PlayerControlsVisibilityPolicy.idleTimeout, .zero)
    }

    func testOverlayVisibilityModeSeparatesHiddenPinnedAndTimedStates() {
        let request = makeRequest()
        let failure = PlaybackFailure(code: "demux.open", userMessage: "failed")

        XCTAssertEqual(
            PlayerControlsVisibilityPolicy.mode(for: .failed(failure)),
            .hidden
        )
        XCTAssertEqual(
            PlayerControlsVisibilityPolicy.mode(for: .stopped),
            .hidden
        )
        XCTAssertEqual(
            PlayerControlsVisibilityPolicy.mode(for: .preparing(request)),
            .pinned
        )
        XCTAssertEqual(
            PlayerControlsVisibilityPolicy.mode(for: .buffering(request)),
            .pinned
        )
        XCTAssertEqual(
            PlayerControlsVisibilityPolicy.mode(for: .recovering(request)),
            .pinned
        )
        XCTAssertEqual(
            PlayerControlsVisibilityPolicy.mode(for: .paused(request)),
            .pinned
        )
        XCTAssertEqual(
            PlayerControlsVisibilityPolicy.mode(for: .playing(request)),
            .timed
        )
        XCTAssertFalse(
            PlayerControlsVisibilityPolicy.mountsOverlays(for: .failed(failure))
        )
        XCTAssertFalse(
            PlayerControlsVisibilityPolicy.mountsOverlays(for: .stopped)
        )
        XCTAssertTrue(
            PlayerControlsVisibilityPolicy.mountsOverlays(for: .preparing(request))
        )
        XCTAssertTrue(
            PlayerControlsVisibilityPolicy.mountsOverlays(for: .buffering(request))
        )
        XCTAssertTrue(
            PlayerControlsVisibilityPolicy.mountsOverlays(for: .recovering(request))
        )
        XCTAssertTrue(
            PlayerControlsVisibilityPolicy.mountsOverlays(for: .paused(request))
        )
        XCTAssertTrue(
            PlayerControlsVisibilityPolicy.mountsOverlays(for: .playing(request))
        )
    }

    func testAutoHideStateChangesKeyForTerminalStateWakeAndMediaEvents() {
        var state = PlayerControlsVisibilityState(mode: .timed, wakeRevision: 7)
        let playingKey = state.key

        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(PlayerControlsAutoHidePolicy.shouldSleep(for: playingKey))
        XCTAssertTrue(
            PlayerControlsAutoHidePolicy.shouldHide(after: playingKey, current: playingKey)
        )

        state.apply(.stateChanged(.pinned))
        let pausedKey = state.key
        XCTAssertNotEqual(pausedKey, playingKey)
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(PlayerControlsAutoHidePolicy.shouldSleep(for: pausedKey))
        XCTAssertFalse(
            PlayerControlsAutoHidePolicy.shouldHide(after: playingKey, current: pausedKey)
        )
        state.apply(.stateChanged(.pinned))
        XCTAssertEqual(state.key, pausedKey)
        state.apply(.mediaInformationBecameAvailable)
        XCTAssertEqual(state.key, pausedKey)

        state.apply(.stateChanged(.hidden))
        let stoppedKey = state.key
        XCTAssertNotEqual(stoppedKey, pausedKey)
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(PlayerControlsAutoHidePolicy.shouldSleep(for: stoppedKey))

        state.apply(.stateChanged(.timed))
        let resumedKey = state.key
        XCTAssertTrue(state.isVisible)
        state.apply(.mediaInformationBecameAvailable)
        let mediaReadyKey = state.key
        XCTAssertNotEqual(mediaReadyKey, resumedKey)
        state.apply(.userInteraction)
        XCTAssertNotEqual(state.key, mediaReadyKey)
        XCTAssertTrue(state.isVisible)
    }

    func testVisibilityReducerKeepsPinnedInteractionVisibleWithoutStartingATimer() {
        var state = PlayerControlsVisibilityState(mode: .pinned, wakeRevision: 11)
        let pinnedKey = state.key

        state.apply(.userInteraction)

        XCTAssertEqual(state.key, pinnedKey)
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(PlayerControlsAutoHidePolicy.shouldSleep(for: state.key))
    }

    func testTimeoutCompletionOnlyHidesTheCurrentTimedKey() {
        var state = PlayerControlsVisibilityState(mode: .timed, wakeRevision: 3)
        let originalKey = state.key

        state.apply(.userInteraction)
        let currentKey = state.key
        XCTAssertNotEqual(currentKey, originalKey)

        state.apply(.timeoutCompleted(originalKey))
        XCTAssertTrue(state.isVisible)

        state.apply(.timeoutCompleted(currentKey))
        XCTAssertFalse(state.isVisible)

        state.apply(.stateChanged(.pinned))
        state.apply(.timeoutCompleted(currentKey))
        XCTAssertTrue(state.isVisible)

        state.apply(.stateChanged(.hidden))
        state.apply(.timeoutCompleted(currentKey))
        XCTAssertFalse(state.isVisible)
    }

    func testPlayPauseCommandWakesBeforeTogglingPlayback() {
        var wakeRevision = 0
        var events: [String] = []

        PlayerControlsCommandPolicy.handlePlayPause(
            wake: {
                wakeRevision += 1
                events.append("wake:\(wakeRevision)")
            },
            toggle: {
                events.append("toggle:\(wakeRevision)")
            }
        )

        XCTAssertEqual(events, ["wake:1", "toggle:1"])
    }

    func testIdleTimerIsDisabledOnlyWhilePreparingOrPlaying() {
        let request = makeRequest()
        let failure = PlaybackFailure(code: "demux.open", userMessage: "failed")

        XCTAssertFalse(PlaybackIdleTimerPolicy.isDisabled(for: .idle))
        XCTAssertTrue(PlaybackIdleTimerPolicy.isDisabled(for: .preparing(request)))
        XCTAssertTrue(PlaybackIdleTimerPolicy.isDisabled(for: .buffering(request)))
        XCTAssertTrue(PlaybackIdleTimerPolicy.isDisabled(for: .recovering(request)))
        XCTAssertTrue(PlaybackIdleTimerPolicy.isDisabled(for: .playing(request)))
        XCTAssertFalse(PlaybackIdleTimerPolicy.isDisabled(for: .paused(request)))
        XCTAssertFalse(PlaybackIdleTimerPolicy.isDisabled(for: .stopped))
        XCTAssertFalse(PlaybackIdleTimerPolicy.isDisabled(for: .failed(failure)))
    }

    func testFailureActionPolicyShowsRetryOnlyForTheSameRequestDisposition() {
        for (disposition, expected) in [
            (PlaybackRetryDisposition.retrySameRequest, true),
            (.chooseAnotherChannel, false),
            (.doNotRetry, false),
        ] {
            XCTAssertEqual(
                PlayerFailureActionPolicy.showsRetry(for: PlaybackFailure(
                    code: "fixture.failure",
                    userMessage: "播放失败。",
                    retryDisposition: disposition
                )),
                expected
            )
        }
    }

    func testPlayerLifecycleStopsOnlyWhenDisappearanceIsNotCausedBySettingsSheet() {
        XCTAssertFalse(
            FullScreenPlayerLifecyclePolicy.shouldStopOnDisappear(
                isPresentingSettings: true
            )
        )
        XCTAssertTrue(
            FullScreenPlayerLifecyclePolicy.shouldStopOnDisappear(
                isPresentingSettings: false
            )
        )
    }

    func testStartSubscribesBeforePlayAndPresentationLookup() async throws {
        let log = ViewModelOperationLog()
        let engine = ViewModelPlaybackEngine(log: log)
        let settings = makeSettings()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: {
                log.append("presentation")
                return Self.finishedPresentationStream()
            },
            settings: settings
        )

        model.start()
        try await eventually { log.values.count >= 3 }

        XCTAssertEqual(Array(log.values.prefix(3)), [
            "events", "play", "presentation",
        ])
    }

    func testMediaInformationSubscriptionClearsOnRetryAndStop() async throws {
        let media = ViewModelMediaInformationFeed()
        let engine = ViewModelPlaybackEngine(log: .init())
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            mediaInformationProvider: { await media.stream() },
            settings: makeSettings()
        )
        model.start()
        await media.emit(PlaybackMediaInformation(
            width: 1_920,
            height: 1_080,
            scanMode: .interlaced,
            sourceFrameRate: MediaRational(num: 25, den: 1),
            outputFrameRate: 50,
            isSmoothMotionEnhanced: true
        ))
        try await eventually { model.mediaInformation?.width == 1_920 }

        let failure = retryableFailure()
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }
        model.retry()
        try await eventually { model.mediaInformation == nil }

        await model.stop()
        XCTAssertNil(model.mediaInformation)
    }

    func testMediaInformationWaitsForCurrentPlayClearBoundaryBeforeAcceptingSnapshot() async throws {
        let media = ViewModelMediaGenerationFeed(previous: mediaInformation(width: 1_280))
        let playGate = ViewModelAsyncGate()
        let retryGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedPlayCall: 1,
            playGate: playGate,
            playGates: [2: retryGate],
            playCompletion: { await media.markPlayCompleted() }
        )
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            mediaInformationProvider: { await media.stream() },
            settings: makeSettings()
        )

        model.start()
        try await eventually { await playGate.hasWaiter }

        XCTAssertNil(model.mediaInformation)

        await playGate.open()
        try await eventually { await media.hasSubscriber }
        await media.emit(mediaInformation(width: 1_920))
        try await eventually { model.mediaInformation?.width == 1_920 }

        await media.prepareNextPlay()
        let failure = retryableFailure()
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }
        model.retry()
        try await eventually { await retryGate.hasWaiter }
        XCTAssertNil(model.mediaInformation)

        await retryGate.open()
        try await eventually { await media.hasSubscriber }
        await media.emit(mediaInformation(width: 3_840))
        try await eventually { model.mediaInformation?.width == 3_840 }
    }

    func testStopMarksViewModelStoppedAndHidesMediaImmediately() async throws {
        let media = ViewModelMediaInformationFeed()
        let engine = ViewModelPlaybackEngine(log: .init())
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            mediaInformationProvider: { await media.stream() },
            settings: makeSettings()
        )

        model.start()
        try await eventually { await engine.playCount == 1 }
        await media.emit(mediaInformation(width: 1_920))
        try await eventually { model.mediaInformation != nil }

        await model.stop()

        XCTAssertEqual(model.state, .stopped)
        XCTAssertNil(model.mediaInformation)
    }

    func testStopDoesNotWaitForNonCooperativeMediaInformationProvider() async throws {
        let provider = ViewModelNonCooperativeMediaInformationProvider()
        let engine = ViewModelPlaybackEngine(log: .init())
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            mediaInformationProvider: { await provider.stream() },
            settings: makeSettings()
        )
        let stopFinished = ViewModelFlag()

        model.start()
        try await eventually { await provider.hasWaiter }
        let stop = Task {
            await model.stop()
            stopFinished.set()
        }

        let finishedWithoutProvider = await waitUntil { stopFinished.value }
        XCTAssertTrue(finishedWithoutProvider)

        await provider.release()
        await stop.value
        XCTAssertNil(model.mediaInformation)
    }

    func testPauseRetryAndStopExactlyOnce() async throws {
        let log = ViewModelOperationLog()
        let engine = ViewModelPlaybackEngine(log: log)
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.playCount == 1 }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually { await engine.pauses == [true] }
        let failure = retryableFailure()
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }
        model.retry()
        try await eventually { await engine.playCount == 2 }
        await model.stop()
        await model.stop()

        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testRetryActionReplaysOnlyRetrySameRequestFailures() async {
        let cases: [(PlaybackRetryDisposition, Int)] = [
            (.retrySameRequest, 2),
            (.chooseAnotherChannel, 1),
            (.doNotRetry, 1),
        ]

        for (disposition, expectedPlayCount) in cases {
            let engine = ViewModelPlaybackEngine(log: .init())
            let model = FullScreenPlayerViewModel(
                request: makeRequest(),
                engine: engine,
                presentationStreamProvider: { Self.finishedPresentationStream() },
                settings: makeSettings()
            )
            model.start()
            let didStart = await waitUntil { await engine.playCount == 1 }
            XCTAssertTrue(didStart)

            let failure = PlaybackFailure(
                code: "fixture.failure",
                userMessage: "播放失败。",
                retryDisposition: disposition
            )
            await engine.emit(state: .failed(failure))
            let didApplyFailure = await waitUntil { model.state == .failed(failure) }
            XCTAssertTrue(didApplyFailure)

            model.retry()
            for _ in 0..<100 { await Task.yield() }

            let playCount = await engine.playCount
            XCTAssertEqual(
                playCount,
                expectedPlayCount,
                "retry disposition \(disposition) must own the action contract"
            )
            await model.stop()
        }
    }

    func testRapidPauseTogglesRetireExactCommandsAndReconcileAcknowledgements() async throws {
        let firstPauseGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(pauseGates: [1: firstPauseGate])
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.subscriberCount == 1 }
        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        model.togglePause()

        try await eventually { await firstPauseGate.hasWaiter }
        await firstPauseGate.open()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 4
        }

        let pauseOperations = await engine.operations.filter { $0.hasPrefix("pause:") }
        XCTAssertEqual(pauseOperations, [
            "pause:true:start",
            "pause:true:end",
            "pause:false:start",
            "pause:false:end",
        ])

        await engine.emit(state: .paused(request))
        try await eventually { model.state == .paused(request) }
        model.togglePause()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 6
        }
        var completedPauseOperations = await engine.operations.filter {
            $0.hasPrefix("pause:")
        }
        XCTAssertEqual(Array(completedPauseOperations.suffix(2)), [
            "pause:true:start",
            "pause:true:end",
        ])

        model.togglePause()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 8
        }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }
        await engine.emit(state: .paused(request))
        try await eventually { model.state == .paused(request) }
        model.togglePause()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 10
        }
        completedPauseOperations = await engine.operations.filter {
            $0.hasPrefix("pause:")
        }
        XCTAssertEqual(Array(completedPauseOperations.suffix(2)), [
            "pause:false:start",
            "pause:false:end",
        ])
    }

    func testDuplicatePlayingDoesNotOverwriteExpectedPauseIntent() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.subscriberCount == 1 }
        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually {
            await engine.operations.contains("pause:true:end")
        }
        await engine.emit(state: .playing(request))
        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 4
        }

        let pauseOperations = await engine.operations.filter { $0.hasPrefix("pause:") }
        XCTAssertEqual(pauseOperations, [
            "pause:true:start",
            "pause:true:end",
            "pause:false:start",
            "pause:false:end",
        ])
    }

    func testPausedEventWhileResumePendingDoesNotOverwriteFinalResumeIntent() async throws {
        let resumeGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(pauseGates: [2: resumeGate])
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.subscriberCount == 1 }
        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually {
            await engine.operations.contains("pause:true:end")
        }
        model.togglePause()
        try await eventually { await resumeGate.hasWaiter }
        await engine.emit(state: .paused(request))
        try await eventually { model.state == .paused(request) }

        await resumeGate.open()
        try await eventually {
            await engine.operations.contains("pause:false:end")
        }
        model.togglePause()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 6
        }

        let pauseOperations = await engine.operations.filter { $0.hasPrefix("pause:") }
        XCTAssertEqual(pauseOperations, [
            "pause:true:start",
            "pause:true:end",
            "pause:false:start",
            "pause:false:end",
            "pause:true:start",
            "pause:true:end",
        ])
    }

    func testRetryResetsPauseIntentAndNewPreparingEnablesStateSynchronization() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.subscriberCount == 1 }
        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }
        model.togglePause()
        try await eventually {
            await engine.operations.contains("pause:true:end")
        }

        let failure = retryableFailure()
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }
        model.retry()
        try await eventually { await engine.playCount == 2 }
        await engine.emit(state: .paused(request))
        try await eventually { model.state == .paused(request) }
        model.togglePause()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 4
        }

        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .paused(request))
        try await eventually { model.state == .paused(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }
        model.togglePause()
        try await eventually {
            await engine.operations.filter { $0.hasPrefix("pause:") }.count == 6
        }

        let pauseOperations = await engine.operations.filter { $0.hasPrefix("pause:") }
        XCTAssertEqual(pauseOperations, [
            "pause:true:start",
            "pause:true:end",
            "pause:true:start",
            "pause:true:end",
            "pause:true:start",
            "pause:true:end",
        ])
    }

    func testRetryPreventsCancelledQueuedPauseFromCrossingPlaybackGeneration() async throws {
        let firstPauseGate = ViewModelAsyncGate()
        let stalePauseGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(pauseGates: [
            1: firstPauseGate,
            2: stalePauseGate,
        ])
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.subscriberCount == 1 }
        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        model.togglePause()
        try await eventually { await firstPauseGate.hasWaiter }

        let failure = retryableFailure()
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }
        model.retry()
        try await eventually { await engine.playCount == 2 }
        await firstPauseGate.open()
        try await eventually {
            await engine.operations.contains("pause:true:end")
        }

        var stalePauseStarted = false
        for _ in 0..<200 {
            if await stalePauseGate.hasWaiter {
                stalePauseStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(stalePauseStarted)

        await stalePauseGate.open()
        if stalePauseStarted {
            try await eventually {
                await engine.operations.contains("pause:false:end")
            }
        }
        await model.stop()
    }

    func testConcurrentStopsWaitForSuspendedStartupAndTheSameEngineStop() async throws {
        let eventsGate = ViewModelBlockingGate()
        let stopGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            eventsGate: eventsGate,
            stopGate: stopGate
        )
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        let firstFinished = ViewModelFlag()
        let secondFinished = ViewModelFlag()

        model.start()
        try await eventually { eventsGate.hasEntered }
        let firstStop = Task {
            await model.stop()
            firstFinished.set()
        }
        let secondStop = Task {
            await model.stop()
            secondFinished.set()
        }
        await Task.yield()

        XCTAssertFalse(firstFinished.value)
        XCTAssertFalse(secondFinished.value)
        eventsGate.open()
        try await eventually { await stopGate.hasWaiter }
        XCTAssertFalse(firstFinished.value)
        XCTAssertFalse(secondFinished.value)

        await stopGate.open()
        await firstStop.value
        await secondStop.value
        let stopCount = await engine.stopCount
        let subscriberCount = await engine.subscriberCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(subscriberCount, 0)
    }

    func testStopDoesNotWaitForNonCooperativeProviderOrWriteBackItsLateContext() async throws {
        let providerGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine()
        let lateContext = PlaybackPresentationContext()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: {
                await providerGate.wait()
                return Self.presentationStream(context: lateContext, nonce: 701)
            },
            settings: makeSettings()
        )
        let stopFinished = ViewModelFlag()

        model.start()
        try await eventually { await providerGate.hasWaiter }
        let stop = Task {
            await model.stop()
            stopFinished.set()
        }
        try await eventually { stopFinished.value }

        XCTAssertTrue(stopFinished.value)
        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(model.presentation)

        await providerGate.open()
        await stop.value
        await Task { @MainActor in }.value
        XCTAssertNil(model.presentation)
        lateContext.teardown()
    }

    func testStaleProviderCompletionCannotTeardownCurrentRetryContext() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let sharedContext = PlaybackPresentationContext()
        let provider = ViewModelPresentationProviderSequence(context: sharedContext)
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { await provider.next() },
            settings: makeSettings()
        )

        model.start()
        try await eventually { provider.firstCallHasWaiter }
        let failure = retryableFailure()
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }
        model.retry()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(provider.callCount, 1, "旧provider未退出前不得启动第二条consumer Task")
        XCTAssertNil(model.presentation)

        provider.releaseFirstCall()
        try await eventually {
            guard provider.callCount == 2,
                  case let .sampleBuffer(context)? = model.presentation?.presentation else {
                return false
            }
            return context === sharedContext
        }
        let videoView = sharedContext.makeVideoView()
        XCTAssertNotNil(videoView.windowDidChange)

        await Task { @MainActor in }.value

        guard case let .sampleBuffer(currentContext)? = model.presentation?.presentation else {
            return XCTFail("当前挂载不是 sample buffer presentation")
        }
        XCTAssertTrue(currentContext === sharedContext)
        XCTAssertNotNil(videoView.windowDidChange)
        sharedContext.teardown()
    }

    func testStopWaitsForSuspendedRetryBeforeStoppingEngine() async throws {
        let retryGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedPlayCall: 2,
            playGate: retryGate
        )
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.playCount == 1 }

        let failure = retryableFailure()
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }
        model.retry()
        try await eventually { await retryGate.hasWaiter }
        let stopFinished = ViewModelFlag()
        let stop = Task {
            await model.stop()
            stopFinished.set()
        }
        await Task.yield()

        XCTAssertFalse(stopFinished.value)
        await retryGate.open()
        await stop.value
        let operations = await engine.operations
        let playEnd = try XCTUnwrap(operations.firstIndex(of: "play:2:end"))
        let stopStart = try XCTUnwrap(operations.firstIndex(of: "stop:start"))
        XCTAssertLessThan(playEnd, stopStart)
        XCTAssertEqual(operations.last, "stop:end")
    }

    func testStopWaitsForSuspendedPauseBeforeStoppingEngine() async throws {
        let pauseGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(pauseGate: pauseGate)
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.subscriberCount == 1 }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually { await pauseGate.hasWaiter }
        let stopFinished = ViewModelFlag()
        let stop = Task {
            await model.stop()
            stopFinished.set()
        }
        await Task.yield()

        XCTAssertFalse(stopFinished.value)
        await pauseGate.open()
        await stop.value
        let operations = await engine.operations
        let pauseEnd = try XCTUnwrap(operations.firstIndex(of: "pause:true:end"))
        let stopStart = try XCTUnwrap(operations.firstIndex(of: "stop:start"))
        XCTAssertLessThan(pauseEnd, stopStart)
    }

    func testFailureReleasesSuspendedPauseOwnershipBeforeStop() async throws {
        let pauseGate = ViewModelAsyncGate()
        let stopGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            stopGate: stopGate,
            pauseGates: [1: pauseGate]
        )
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { Self.finishedPresentationStream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.subscriberCount == 1 }
        await engine.emit(state: .preparing(request))
        try await eventually { model.state == .preparing(request) }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually { await pauseGate.hasWaiter }
        let failure = PlaybackFailure(
            code: "playback.failed",
            userMessage: "Playback failed"
        )
        await engine.emit(state: .failed(failure))
        try await eventually { model.state == .failed(failure) }

        let stop = Task { await model.stop() }
        var stopReachedEngineWhilePauseWasSuspended = false
        for _ in 0..<200 {
            if await stopGate.hasWaiter {
                stopReachedEngineWhilePauseWasSuspended = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(stopReachedEngineWhilePauseWasSuspended)

        await pauseGate.open()
        if !stopReachedEngineWhilePauseWasSuspended {
            try await eventually { await stopGate.hasWaiter }
        }
        await stopGate.open()
        await stop.value
        try await eventually {
            await engine.operations.contains("pause:true:end")
        }

        let operations = await engine.operations
        let stopStart = try XCTUnwrap(operations.firstIndex(of: "stop:start"))
        let pauseEnd = try XCTUnwrap(operations.firstIndex(of: "pause:true:end"))
        XCTAssertLessThan(stopStart, pauseEnd)
    }

    func testSettingsTuningSelectionControllerSerializesRapidChanges() async throws {
        let firstTuningGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedTuningCall: 1,
            tuningGate: firstTuningGate
        )
        let controller = PlaybackTuningSelectionController(engine: engine)
        let first = PlaybackTuning(videoBufferSeconds: 1)
        let second = PlaybackTuning(videoBufferSeconds: 4)

        controller.apply(first)
        try await eventually { await firstTuningGate.hasWaiter }
        controller.apply(second)
        await Task.yield()
        let tuningsBeforeRelease = await engine.completedTunings
        XCTAssertTrue(tuningsBeforeRelease.isEmpty)

        await firstTuningGate.open()
        try await eventually { await engine.completedTunings.count == 2 }
        let tunings = await engine.completedTunings
        XCTAssertEqual(tunings, [first, second])
    }

    func testPresentationNewestReplacementDetachesMountedAThenAttachesB() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let mount = ViewModelPresentationMountSpy()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { try relay.presentations() },
            presentationMount: mount,
            settings: makeSettings()
        )
        let a = identifiedPresentation(nonce: 101, kind: .sampleBuffer)
        let b = identifiedPresentation(nonce: 102, kind: .avPlayer)

        model.start()
        try await eventually { relay.activeSubscriptionGeneration != nil }
        try relay.replace(with: a)
        try await eventually { model.presentation?.identity == a.identity }

        try relay.replace(with: nil)
        try relay.replace(with: b)
        try await eventually { model.presentation?.identity == b.identity }

        XCTAssertEqual(mount.events, [
            .attach(a.identity),
            .detach(a.identity),
            .attach(b.identity),
        ])
        await model.stop()
    }

    func testNewSubscriptionTakesOwnershipOfSameIdentityAndOldDeferCannotDetachIt() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let allocator = PlaybackIdentityAllocator()
        let firstRelay = PlaybackPresentationRelay(allocator: allocator)
        let secondRelay = PlaybackPresentationRelay(allocator: allocator)
        let provider = ViewModelPresentationStreamSequence(relays: [firstRelay, secondRelay])
        let mount = ViewModelPresentationMountSpy()
        let a = identifiedPresentation(nonce: 201, kind: .sampleBuffer)
        try firstRelay.replace(with: a)
        try secondRelay.replace(with: a)
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { try provider.next() },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { model.presentation?.identity == a.identity }
        let firstOwner = try XCTUnwrap(model.presentationMountOwnership)
        await engine.emit(state: .failed(retryableFailure()))
        try await eventually {
            if case .failed = model.state { return true }
            return false
        }
        model.retry()
        firstRelay.finish()
        try await eventually {
            model.presentationMountOwnership?.subscriptionGeneration !=
                firstOwner.subscriptionGeneration
        }
        let secondOwner = try XCTUnwrap(model.presentationMountOwnership)

        model.detachPresentationIfOwned(firstOwner)

        XCTAssertEqual(model.presentation?.identity, a.identity)
        XCTAssertEqual(model.presentationMountOwnership, secondOwner)
        XCTAssertEqual(
            mount.events,
            [.attach(a.identity)],
            "相同context/identity的G2接管只更新owner CAS，不得制造detach→attach黑帧"
        )
        await model.stop()
    }

    func testPendingG2KeepsSamePresentationMountedWhileProviderIgnoresCancellation() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let presentation = identifiedPresentation(nonce: 211, kind: .sampleBuffer)
        let provider = ViewModelDelayedSamePresentationProvider(presentation: presentation)
        let mount = ViewModelPresentationMountSpy()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { await provider.next() },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { model.presentation?.identity == presentation.identity }
        await engine.emit(state: .failed(retryableFailure()))
        try await eventually {
            if case .failed = model.state { return true }
            return false
        }
        model.retry()
        await provider.finishFirstStream()
        try await eventually { await provider.secondCallIsBlocked }

        XCTAssertEqual(model.presentation?.identity, presentation.identity)
        XCTAssertEqual(
            mount.events,
            [.attach(presentation.identity)],
            "pending G2尚未取得同一presentation时，G1 defer不得先拆宿主"
        )

        await provider.releaseSecondCall()
        try await eventually { await provider.callCount == 2 }
        XCTAssertEqual(model.presentation?.identity, presentation.identity)
        XCTAssertEqual(mount.events, [.attach(presentation.identity)])
        await model.stop()
    }

    func testRetryRejectsLateG1ClaimBeforeSameContextG2TransfersOnlyOwnership() async throws {
        let claimGate = ViewModelBlockingGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedClaimCall: 2,
            claimGate: claimGate
        )
        let allocator = PlaybackIdentityAllocator()
        let firstRelay = PlaybackPresentationRelay(allocator: allocator)
        let secondRelay = PlaybackPresentationRelay(allocator: allocator)
        let provider = ViewModelPresentationStreamSequence(relays: [firstRelay, secondRelay])
        let mount = ViewModelPresentationMountSpy()
        let current = identifiedPresentation(nonce: 221, kind: .sampleBuffer)
        let stale = identifiedPresentation(nonce: 222, kind: .avPlayer)
        try firstRelay.replace(with: current)
        try secondRelay.replace(with: current)
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { try provider.next() },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { model.presentation?.identity == current.identity }
        let firstOwner = try XCTUnwrap(model.presentationMountOwnership)
        await engine.emit(state: .failed(retryableFailure()))
        try await eventually { if case .failed = model.state { return true }; return false }
        DispatchQueue.global().async { try? firstRelay.replace(with: stale) }
        try await eventually { claimGate.hasEntered }
        model.retry()
        firstRelay.finish()
        claimGate.open()

        try await eventually {
            model.presentationMountOwnership?.subscriptionGeneration !=
                firstOwner.subscriptionGeneration
        }
        XCTAssertEqual(model.presentation?.identity, current.identity)
        XCTAssertEqual(
            mount.events,
            [.attach(current.identity)],
            "retry后的G1迟到claim不得写入host；同context G2只能转移owner"
        )
        await model.stop()
    }

    func testRetryRejectsLateG1ClaimBeforeDifferentContextG2ReplacesOnce() async throws {
        let claimGate = ViewModelBlockingGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedClaimCall: 2,
            claimGate: claimGate
        )
        let allocator = PlaybackIdentityAllocator()
        let firstRelay = PlaybackPresentationRelay(allocator: allocator)
        let secondRelay = PlaybackPresentationRelay(allocator: allocator)
        let provider = ViewModelPresentationStreamSequence(relays: [firstRelay, secondRelay])
        let mount = ViewModelPresentationMountSpy()
        let current = identifiedPresentation(nonce: 231, kind: .sampleBuffer)
        let stale = identifiedPresentation(nonce: 232, kind: .avPlayer)
        let successor = identifiedPresentation(nonce: 233, kind: .avPlayer)
        try firstRelay.replace(with: current)
        try secondRelay.replace(with: successor)
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { try provider.next() },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { model.presentation?.identity == current.identity }
        await engine.emit(state: .failed(retryableFailure()))
        try await eventually { if case .failed = model.state { return true }; return false }
        DispatchQueue.global().async { try? firstRelay.replace(with: stale) }
        try await eventually { claimGate.hasEntered }
        model.retry()
        firstRelay.finish()
        claimGate.open()

        try await eventually { model.presentation?.identity == successor.identity }
        XCTAssertEqual(mount.events, [
            .attach(current.identity),
            .detach(current.identity),
            .attach(successor.identity),
        ], "retry后的G1迟到claim不得制造额外detach/attach")
        await model.stop()
    }

    func testStaleRevisionAndABAIdentityCannotOverwriteLatestMount() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let source = ViewModelManualPresentationStream()
        let mount = ViewModelPresentationMountSpy()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { source.stream },
            presentationMount: mount,
            settings: makeSettings()
        )
        let a1 = identifiedPresentation(nonce: 301, kind: .sampleBuffer)
        let b = identifiedPresentation(nonce: 302, kind: .avPlayer)
        let a2 = identifiedPresentation(nonce: 303, kind: .sampleBuffer)

        model.start()
        try await eventually { await engine.playCount == 1 }
        source.yield(generation: 7, revision: 1, desired: a1)
        source.yield(generation: 7, revision: 2, desired: b)
        source.yield(generation: 7, revision: 3, desired: a2)
        source.yield(generation: 7, revision: 2, desired: a1)
        try await eventually { model.presentation?.identity == a2.identity }

        XCTAssertEqual(mount.events.suffix(5), [
            .attach(a1.identity),
            .detach(a1.identity),
            .attach(b.identity),
            .detach(b.identity),
            .attach(a2.identity),
        ])
        await model.stop()
    }

    func testStreamRejectsGenerationChangeAfterFirstEnvelope() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let source = ViewModelManualPresentationStream()
        let mount = ViewModelPresentationMountSpy()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { source.stream },
            presentationMount: mount,
            settings: makeSettings()
        )
        let a = identifiedPresentation(nonce: 351, kind: .sampleBuffer)
        let staleB = identifiedPresentation(nonce: 352, kind: .avPlayer)
        let currentB = identifiedPresentation(nonce: 353, kind: .avPlayer)

        model.start()
        try await eventually { await engine.playCount == 1 }
        source.yield(generation: 7, revision: 1, desired: a)
        try await eventually { model.presentation?.identity == a.identity }
        source.yield(generation: 8, revision: 2, desired: staleB)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.presentation?.identity, a.identity)

        source.yield(generation: 7, revision: 2, desired: currentB)
        try await eventually { model.presentation?.identity == currentB.identity }
        XCTAssertEqual(mount.events, [
            .attach(a.identity),
            .detach(a.identity),
            .attach(currentB.identity),
        ])
        await model.stop()
    }

    func testMountNonceOverflowIsDecidedBeforeReplacementUISideEffects() async throws {
        let engine = ControlledViewModelPlaybackEngine(initialPresentationMountNonce: UInt64.max - 1)
        let source = ViewModelManualPresentationStream()
        let mount = ViewModelPresentationMountSpy()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { source.stream },
            presentationMount: mount,
            settings: makeSettings()
        )
        let a = identifiedPresentation(nonce: 371, kind: .sampleBuffer)
        let rejectedB = identifiedPresentation(nonce: 372, kind: .avPlayer)

        model.start()
        try await eventually { await engine.playCount == 1 }
        source.yield(generation: 9, revision: 1, desired: a)
        try await eventually { model.presentation?.identity == a.identity }

        source.yield(generation: 9, revision: 2, desired: rejectedB)
        try await eventually { model.presentation == nil }

        XCTAssertEqual(mount.events, [
            .attach(a.identity),
            .detach(a.identity),
        ])
        XCTAssertNil(model.presentationMountOwnership)
        let failureCount = await engine.presentationControlFailureCount
        XCTAssertEqual(failureCount, 1)
        await model.stop()
    }

    func testNonCooperativePresentationProviderFoldsRepeatedRetriesToOnePendingIntent() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let provider = ViewModelNonCooperativePresentationProvider()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { await provider.stream() },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await provider.callCount == 1 }

        for expectedPlayCount in 2...17 {
            await engine.emit(state: .failed(retryableFailure()))
            try await eventually {
                if case .failed = model.state { return true }
                return false
            }
            model.retry()
            try await eventually { await engine.playCount == expectedPlayCount }
        }

        let blockedCallCount = await provider.callCount
        let blockedPeakConcurrentCalls = await provider.peakConcurrentCalls
        XCTAssertEqual(blockedCallCount, 1)
        XCTAssertEqual(blockedPeakConcurrentCalls, 1)
        await provider.releaseFirstCall()
        try await eventually { await provider.callCount == 2 }
        try await eventually { model.presentation?.identity.presentationNonce == 2 }
        let completedPeakConcurrentCalls = await provider.peakConcurrentCalls
        XCTAssertEqual(completedPeakConcurrentCalls, 1)
        await model.stop()
    }

    func testPresentationConsumerGenerationOverflowFailsClosedBeforeStartingProvider() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let provider = ViewModelNonCooperativePresentationProvider()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { await provider.stream() },
            settings: makeSettings(),
            initialPresentationConsumerGeneration: UInt64.max
        )

        model.start()
        try await eventually { await engine.playCount == 1 }
        try await eventually { await engine.presentationControlFailureCount == 1 }

        let providerCallCount = await provider.callCount
        XCTAssertEqual(providerCallCount, 0)
        XCTAssertNil(model.presentation)
        XCTAssertNil(model.presentationMountOwnership)
        await model.stop()
    }

    func testRealHostRemovesCoalescedSampleBufferBeforeAttachingAVPlayer() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let relay = PlaybackPresentationRelay(allocator: PlaybackIdentityAllocator())
        let mount = PlaybackPresentationHostMount()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { try relay.presentations() },
            presentationMount: mount,
            settings: makeSettings()
        )
        let host = PlaybackPresentationHostController()
        XCTAssertTrue(model.presentationHostMount === mount, "生产View与ViewModel必须共用同一host mount")
        model.presentationHostMount.connect(to: host)
        let a = identifiedPresentation(nonce: 381, kind: .sampleBuffer)
        let b = identifiedPresentation(nonce: 382, kind: .avPlayer)
        guard case let .sampleBuffer(aContext) = a.presentation else {
            return XCTFail("fixture不是SampleBuffer presentation")
        }
        let aView = aContext.makeVideoView()

        model.start()
        try await eventually { relay.activeSubscriptionGeneration != nil }
        try relay.replace(with: a)
        try await eventually { aView.isDescendant(of: host.view) }
        try relay.replace(with: nil)
        try relay.replace(with: b)
        try await eventually { host.mountedIdentity == b.identity }

        XCTAssertFalse(aView.isDescendant(of: host.view))
        XCTAssertEqual(host.children.count, 1)
        await model.stop()
    }

    func testRealViewModelHostReplacesDifferentContextEvenWhenIdentityIsEqual() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let source = ViewModelManualPresentationStream()
        let mount = PlaybackPresentationHostMount()
        let identity = identifiedPresentation(nonce: 391, kind: .sampleBuffer).identity
        let firstContext = PlaybackPresentationContext()
        let firstView = firstContext.makeVideoView()
        let firstController = AVPlayerViewController()
        var factoryCalls = 0
        let host = PlaybackPresentationHostController(avPlayerControllerFactory: {
            XCTAssertNil(firstView.superview, "构造B wrapper前必须先移除A view")
            defer { factoryCalls += 1 }
            return firstController
        })
        host.loadViewIfNeeded()
        mount.connect(to: host)
        let first = IdentifiedPlaybackPresentation(
            identity: identity,
            presentation: .sampleBuffer(firstContext)
        )
        let secondContext = AVPlayerPresentationContext(player: AVPlayer())
        let second = IdentifiedPlaybackPresentation(
            identity: identity,
            presentation: .avPlayer(secondContext)
        )
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { source.stream },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { await engine.playCount == 1 }
        source.yield(generation: 17, revision: 1, desired: first)
        try await eventually { firstView.isDescendant(of: host.view) }
        source.yield(generation: 17, revision: 2, desired: second)
        try await eventually { host.children.first === firstController }

        XCTAssertFalse(firstView.isDescendant(of: host.view), "B attach前必须先detach A context")
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(firstController.player === secondContext.player)
        XCTAssertEqual(host.mountedIdentity, identity)
        await model.stop()
    }

    func testResetWinningBeforeRealMountClaimRejectsOldControllerEnvelope() async throws {
        let fixture = try Task10ControllerFixture()
        let gate = ViewModelBlockingGate()
        await fixture.controller.setBeforePresentationMountClaimForTesting { gate.wait() }
        let mount = ViewModelPresentationMountSpy()
        let model = FullScreenPlayerViewModel(
            request: fixture.request,
            engine: fixture.controller,
            presentationStreamProvider: { try await fixture.controller.presentations() },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { gate.hasEntered }
        fixture.registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
        gate.open()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(model.presentation, "reset已赢最终mount fence时，旧envelope不得写入VM")
        XCTAssertNil(model.presentationMountOwnership)
        XCTAssertTrue(mount.events.isEmpty)
        await fixture.controller.setBeforePresentationMountClaimForTesting(nil)
        await model.stop()
        await fixture.controller.stop()
    }

    func testRealControllerG2ClaimsSameContextWithoutReplacingProductionHost() async throws {
        let fixture = try Task10ControllerFixture()
        await fixture.start()
        let retryGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedPlayCall: 2,
            playGate: retryGate
        )
        let mount = PlaybackPresentationHostMount()
        let host = PlaybackPresentationHostController()
        host.loadViewIfNeeded()
        mount.connect(to: host)
        let model = FullScreenPlayerViewModel(
            request: fixture.request,
            engine: engine,
            presentationController: fixture.controller,
            presentationStreamProvider: { try await fixture.controller.presentations() },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { host.children.count == 1 }
        let originalChild = try XCTUnwrap(host.children.first)
        let originalPresentation = try XCTUnwrap(model.presentation)
        let originalOwner = try XCTUnwrap(model.presentationMountOwnership)
        await engine.emit(state: .failed(retryableFailure()))
        try await eventually {
            if case .failed = model.state { return true }
            return false
        }
        model.retry()
        try await eventually { await retryGate.hasWaiter }

        // 取消真实G1 stream会进入Relay的onTermination，但pending G2不得先拆host。
        model.cancelPresentationConsumerForTesting()
        try await eventually { !model.presentationConsumerIsActiveForTesting }
        XCTAssertTrue(host.children.first === originalChild)
        XCTAssertEqual(model.presentation?.identity, originalPresentation.identity)

        await retryGate.open()
        try await eventually {
            model.presentationMountOwnership?.subscriptionGeneration !=
                originalOwner.subscriptionGeneration
        }
        XCTAssertTrue(host.children.first === originalChild)
        XCTAssertEqual(model.presentation?.identity, originalPresentation.identity)

        await model.stop()
        await fixture.controller.stop()
    }

    func testRealControllerG1ToDifferentContextDetachesBeforeG2AttachesProductionHost() async throws {
        let fixture = try Task10ControllerFixture()
        let mount = PlaybackPresentationHostMount()
        let host = PlaybackPresentationHostController()
        host.loadViewIfNeeded()
        mount.connect(to: host)
        let model = FullScreenPlayerViewModel(
            request: fixture.request,
            engine: fixture.controller,
            presentationController: fixture.controller,
            presentationStreamProvider: { try await fixture.controller.presentations() },
            presentationMount: mount,
            settings: makeSettings()
        )

        model.start()
        try await eventually { host.children.count == 1 }
        let originalChild = try XCTUnwrap(host.children.first)
        let originalIdentity = try XCTUnwrap(model.presentation?.identity)
        let originalBackend = try XCTUnwrap(fixture.factory.createdBackends.first)
        originalBackend.setHoldStop(true)
        fixture.registry.publishState(.failed(retryableFailure()))
        try await eventually {
            if case .failed = model.state { return true }
            return false
        }
        model.retry()
        await originalBackend.waitForRetireEntered()
        XCTAssertTrue(
            host.children.first === originalChild,
            "G2目标尚未到达时不能预先拆掉可能复用的G1 host"
        )

        originalBackend.confirmStop()
        try await eventually {
            host.children.count == 1 && model.presentation?.identity != originalIdentity
        }
        XCTAssertFalse(host.children.first === originalChild)
        XCTAssertNil(originalChild.parent)
        XCTAssertTrue(host.children.first?.parent === host)

        await model.stop()
        await fixture.controller.stop()
    }

    func testConsumerIdentityExhaustionUsesSharedRegistryFailClosedBeforeReturning() async throws {
        let fixture = try Task10ControllerFixture()
        await fixture.start()
        let backend = try XCTUnwrap(fixture.factory.createdBackends.first)
        backend.setHoldStop(true)
        let original = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let engine = RegistryMountClaimViewModelEngine(registry: fixture.registry)
        let model = FullScreenPlayerViewModel(
            request: fixture.request,
            engine: engine,
            presentationStreamProvider: {
                XCTFail("consumer generation耗尽不得调用provider")
                return AsyncStream { $0.finish() }
            },
            settings: makeSettings(),
            initialPresentationConsumerGeneration: .max
        )

        model.start()
        try await eventually { await engine.failReturnCount == 1 }

        let safety = fixture.registry.executor.safetyIngress.snapshot
        XCTAssertEqual(safety.failure, .identitySpaceExhausted)
        XCTAssertFalse(safety.outputPermitPresent)
        XCTAssertFalse(safety.readinessOpen)
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        XCTAssertTrue(context.poisoned)
        XCTAssertEqual(context.disposition, .releaseAfterTeardown)
        XCTAssertEqual(context.owner?.identity, original.terminalOwner)
        XCTAssertEqual(fixture.registry.cleanupReservationSnapshot()?.ticket, original.ticket)
        try await eventually { backend.retirementSnapshot.count == 1 }
        XCTAssertEqual(backend.retirementSnapshot.count, 1)

        backend.confirmStop()
        await model.stop()
    }

    func testLateSubscriptionAfterFirstPlayAudioFailureRetiresPresentationConsumerAtEOF() async throws {
        let fixture = try Task10ControllerFixture()
        fixture.sdk.activateError = NSError(
            domain: "FullScreenPlayerViewModelTests.AudioSession",
            code: -10
        )
        let providerGate = ViewModelAsyncGate()
        let model = FullScreenPlayerViewModel(
            request: fixture.request,
            engine: fixture.controller,
            presentationController: fixture.controller,
            presentationStreamProvider: {
                await providerGate.wait()
                return try await fixture.controller.presentations()
            },
            settings: makeSettings()
        )

        model.start()
        try await eventually {
            if case .failed = model.state { return true }
            return false
        }
        try await eventually { await providerGate.hasWaiter }
        // 让 producer 的失败终态确定先于首次 presentation subscription。
        for _ in 0..<50 { await Task.yield() }
        await providerGate.open()

        try await eventually {
            !model.presentationConsumerIsActiveForTesting
        }
        XCTAssertNil(model.presentation)
        XCTAssertNil(model.presentationMountOwnership)
        await model.stop()
    }

    func testStopReleasesViewModelAndMountWhenPresentationProviderNeverReturns() async throws {
        let provider = ViewModelNonCooperativePresentationProvider()
        let engine = ControlledViewModelPlaybackEngine()
        var mount: PlaybackPresentationHostMount? = PlaybackPresentationHostMount()
        var model: FullScreenPlayerViewModel? = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { await provider.stream() },
            presentationMount: mount,
            settings: makeSettings()
        )
        weak let weakModel = model
        weak let weakMount = mount

        model?.start()
        try await eventually { await provider.callCount == 1 }
        await model?.stop()
        let callCountAtStop = await provider.callCount
        let activeCallsAtStop = await provider.activeCalls
        let peakCallsAtStop = await provider.peakConcurrentCalls
        XCTAssertEqual(callCountAtStop, 1, "stop 不得为非合作 provider 再建第二条尾部")
        XCTAssertEqual(activeCallsAtStop, 1, "最多只允许原 provider 调用尾仍在等待")
        XCTAssertEqual(peakCallsAtStop, 1)

        model = nil
        mount = nil
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(weakModel, "被取消的 provider 尾不得继续强持有 ViewModel")
        XCTAssertNil(weakMount, "ViewModel 释放后不得由 consumer 尾继续强持有 mount")

        // 失败断言之后也要释放测试 continuation，避免污染同进程后续用例。
        await provider.releaseFirstCall()
    }

    func testStopStartsEngineCleanupWithoutWaitingForPresentationStreamToFinish() async throws {
        let stopGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(stopGate: stopGate)
        let source = ViewModelManualPresentationStream()
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationStreamProvider: { source.stream },
            settings: makeSettings()
        )
        model.start()
        try await eventually { await engine.playCount == 1 }

        let stop = Task { await model.stop() }
        try await eventually { await stopGate.hasWaiter }

        XCTAssertFalse(source.isFinished)
        await stopGate.open()
        await stop.value
    }

    func testAVPlayerControllerDisablesSystemControls() {
        let context = AVPlayerPresentationContext(player: AVPlayer())

        let controller = AVPlayerPlayerView.makeController(context: context)

        XCTAssertFalse(controller.showsPlaybackControls)
        XCTAssertTrue(controller.player === context.player)

        let identified = identifiedPresentation(nonce: 401, kind: .avPlayer)
        guard case let .avPlayer(mountedContext) = identified.presentation else {
            return XCTFail("fixture不是AVPlayer presentation")
        }
        let mountedController = AVPlayerPlayerView.makeController(context: mountedContext)
        DefaultPlaybackPresentationMount().detach(identified)
        XCTAssertNil(mountedController.player)
    }

    private enum PresentationFixtureKind {
        case sampleBuffer
        case avPlayer
    }

    private func identifiedPresentation(
        nonce: UInt64,
        kind: PresentationFixtureKind
    ) -> IdentifiedPlaybackPresentation {
        let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
        let backend = PlaybackBackendIdentity(
            sessionIdentity: session,
            backendGeneration: nonce
        )
        let presentation: PlaybackPresentation = switch kind {
        case .sampleBuffer:
            .sampleBuffer(PlaybackPresentationContext())
        case .avPlayer:
            .avPlayer(AVPlayerPresentationContext(player: AVPlayer()))
        }
        return IdentifiedPlaybackPresentation(
            identity: PresentationIdentity(
                sessionIdentity: session,
                backendIdentity: backend,
                outputLifecycleEpoch: OutputLifecycleEpoch(
                    backendIdentity: backend,
                    outputNonce: nonce
                ),
                itemGeneration: nil,
                presentationNonce: nonce
            ),
            presentation: presentation
        )
    }

    private func makeSettings() -> PlaybackSettingsStore {
        let suite = "FullScreenPlayerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return PlaybackSettingsStore(defaults: defaults)
    }

    nonisolated private static func finishedPresentationStream() -> AsyncStream<PlaybackPresentationReplacement> {
        AsyncStream { continuation in continuation.finish() }
    }

    nonisolated private static func presentationStream(
        context: PlaybackPresentationContext,
        nonce: UInt64
    ) -> AsyncStream<PlaybackPresentationReplacement> {
        let session = PlaybackSessionIdentity(sessionID: nonce, requestID: UUID())
        let backend = PlaybackBackendIdentity(
            sessionIdentity: session,
            backendGeneration: nonce
        )
        return AsyncStream { continuation in
            continuation.yield(.init(
                subscriptionGeneration: nonce,
                revision: 1,
                desired: .init(
                    identity: .init(
                        sessionIdentity: session,
                        backendIdentity: backend,
                        outputLifecycleEpoch: .init(
                            backendIdentity: backend,
                            outputNonce: nonce
                        ),
                        itemGeneration: nil,
                        presentationNonce: nonce
                    ),
                    presentation: .sampleBuffer(context)
                )
            ))
            continuation.finish()
        }
    }

    private func makeRequest() -> PlaybackRequest {
        PlaybackRequest(
            sourceProfileID: UUID(),
            channelID: "fixture",
            streamURL: URL(string: "https://fixture.invalid/live")
                ?? URL(fileURLWithPath: "/fixture.invalid/live"),
            title: "Fixture"
        )
    }

    private func retryableFailure() -> PlaybackFailure {
        PlaybackFailure(
            code: "fixture.retryable",
            userMessage: "播放失败。",
            retryDisposition: .retrySameRequest
        )
    }

    private func mediaInformation(width: Int32) -> PlaybackMediaInformation {
        PlaybackMediaInformation(
            width: width,
            height: 1_080,
            scanMode: .progressive,
            sourceFrameRate: MediaRational(num: 25, den: 1),
            outputFrameRate: 25,
            isSmoothMotionEnhanced: false
        )
    }

    private func eventually(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not reached")
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class ViewModelPresentationMountSpy: PlaybackPresentationMounting {
    enum Event: Equatable {
        case attach(PresentationIdentity)
        case detach(PresentationIdentity)
    }

    private(set) var events: [Event] = []

    func attach(_ presentation: IdentifiedPlaybackPresentation) {
        events.append(.attach(presentation.identity))
    }

    func detach(_ presentation: IdentifiedPlaybackPresentation) {
        events.append(.detach(presentation.identity))
    }
}

private final class ViewModelPresentationStreamSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [PlaybackPresentationRelay]

    init(relays: [PlaybackPresentationRelay]) {
        self.relays = relays
    }

    func next() throws -> AsyncStream<PlaybackPresentationReplacement> {
        let relay = try lock.withLock { () throws -> PlaybackPresentationRelay in
            guard !relays.isEmpty else { throw PlaybackPresentationRelayError.terminal }
            return relays.removeFirst()
        }
        return try relay.presentations()
    }
}

private final class ViewModelManualPresentationStream: @unchecked Sendable {
    private let lock = NSLock()
    private let pair = AsyncStream.makeStream(
        of: PlaybackPresentationReplacement.self,
        bufferingPolicy: .unbounded
    )
    private var finished = false

    var stream: AsyncStream<PlaybackPresentationReplacement> { pair.stream }
    var isFinished: Bool { lock.withLock { finished } }

    func yield(
        generation: UInt64,
        revision: UInt64,
        desired: IdentifiedPlaybackPresentation?
    ) {
        _ = pair.continuation.yield(.init(
            subscriptionGeneration: generation,
            revision: revision,
            desired: desired
        ))
    }

    func finish() {
        lock.withLock { finished = true }
        pair.continuation.finish()
    }
}

private final class ViewModelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false
    var value: Bool { lock.withLock { storedValue } }
    func set() { lock.withLock { storedValue = true } }
}

private final class ViewModelPresentationProviderSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let context: PlaybackPresentationContext
    private var storedCallCount = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var streamContinuations: [
        AsyncStream<PlaybackPresentationReplacement>.Continuation
    ] = []

    init(context: PlaybackPresentationContext) {
        self.context = context
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    var firstCallHasWaiter: Bool {
        lock.withLock { firstCallContinuation != nil }
    }

    func next() async -> AsyncStream<PlaybackPresentationReplacement> {
        let call = lock.withLock {
            storedCallCount += 1
            return storedCallCount
        }
        if call == 1 {
            await withCheckedContinuation { continuation in
                lock.withLock { firstCallContinuation = continuation }
            }
        }
        let nonce = UInt64(call)
        let session = PlaybackSessionIdentity(sessionID: nonce, requestID: UUID())
        let backend = PlaybackBackendIdentity(
            sessionIdentity: session,
            backendGeneration: nonce
        )
        let pair = AsyncStream.makeStream(of: PlaybackPresentationReplacement.self)
        lock.withLock { streamContinuations.append(pair.continuation) }
        pair.continuation.yield(.init(
                subscriptionGeneration: nonce,
                revision: 1,
                desired: .init(
                    identity: .init(
                        sessionIdentity: session,
                        backendIdentity: backend,
                        outputLifecycleEpoch: .init(
                            backendIdentity: backend,
                            outputNonce: nonce
                        ),
                        itemGeneration: nil,
                        presentationNonce: nonce
                    ),
                    presentation: .sampleBuffer(context)
                )
            ))
        return pair.stream
    }

    func releaseFirstCall() {
        let continuation = lock.withLock {
            let continuation = firstCallContinuation
            firstCallContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class ViewModelBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var isOpen = false

    var hasEntered: Bool {
        condition.withLock { entered }
    }

    func wait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }
}

private actor ViewModelAsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var waiterCount = 0
    var hasWaiter: Bool { waiterCount > 0 }

    func wait() async {
        waiterCount += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor ControlledViewModelPlaybackEngine: PlaybackEngine, PlaybackPresentationControlling {
    private let eventsGate: ViewModelBlockingGate?
    private let stopGate: ViewModelAsyncGate?
    private let suspendedPlayCall: Int?
    private let playGate: ViewModelAsyncGate?
    private let playGates: [Int: ViewModelAsyncGate]
    private let playCompletion: (@Sendable () async -> Void)?
    private let suspendedTuningCall: Int?
    private let tuningGate: ViewModelAsyncGate?
    private let pauseGate: ViewModelAsyncGate?
    private let pauseGates: [Int: ViewModelAsyncGate]
    private let suspendedClaimCall: Int?
    private let claimGate: ViewModelBlockingGate?
    private var eventContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var completedTunings: [PlaybackTuning] = []
    private(set) var operations: [String] = []
    private var tuningCallCount = 0
    private var pauseCallCount = 0
    private var presentationMountNonce: UInt64
    private var claimCallCount = 0
    private(set) var presentationControlFailureCount = 0

    var subscriberCount: Int { eventContinuations.count }

    init(
        eventsGate: ViewModelBlockingGate? = nil,
        stopGate: ViewModelAsyncGate? = nil,
        suspendedPlayCall: Int? = nil,
        playGate: ViewModelAsyncGate? = nil,
        playGates: [Int: ViewModelAsyncGate] = [:],
        playCompletion: (@Sendable () async -> Void)? = nil,
        suspendedTuningCall: Int? = nil,
        tuningGate: ViewModelAsyncGate? = nil,
        pauseGate: ViewModelAsyncGate? = nil,
        pauseGates: [Int: ViewModelAsyncGate] = [:],
        suspendedClaimCall: Int? = nil,
        claimGate: ViewModelBlockingGate? = nil,
        initialPresentationMountNonce: UInt64 = 0
    ) {
        self.eventsGate = eventsGate
        self.stopGate = stopGate
        self.suspendedPlayCall = suspendedPlayCall
        self.playGate = playGate
        self.playGates = playGates
        self.playCompletion = playCompletion
        self.suspendedTuningCall = suspendedTuningCall
        self.tuningGate = tuningGate
        self.pauseGate = pauseGate
        self.pauseGates = pauseGates
        self.suspendedClaimCall = suspendedClaimCall
        self.claimGate = claimGate
        presentationMountNonce = initialPresentationMountNonce
    }

    func events() -> AsyncStream<PlaybackState> {
        eventsGate?.wait()
        let id = UUID()
        let pair = AsyncStream.makeStream(of: PlaybackState.self)
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    func play(_ request: PlaybackRequest) async {
        _ = request
        playCount += 1
        let call = playCount
        operations.append("play:\(call):start")
        let gate = playGates[call] ?? (suspendedPlayCall == call ? playGate : nil)
        if let gate { await gate.wait() }
        if let playCompletion { await playCompletion() }
        operations.append("play:\(call):end")
    }

    func setPaused(_ paused: Bool) async {
        pauseCallCount += 1
        let call = pauseCallCount
        operations.append("pause:\(paused):start")
        if let gate = pauseGates[call] ?? pauseGate { await gate.wait() }
        operations.append("pause:\(paused):end")
    }

    func emit(state: PlaybackState) {
        for continuation in eventContinuations.values { continuation.yield(state) }
    }

    func stop() async {
        stopCount += 1
        operations.append("stop:start")
        if let stopGate { await stopGate.wait() }
        operations.append("stop:end")
    }

    func setTuning(_ tuning: PlaybackTuning) async {
        tuningCallCount += 1
        let call = tuningCallCount
        if suspendedTuningCall == call, let tuningGate { await tuningGate.wait() }
        completedTunings.append(tuning)
    }

    func presentations() throws -> AsyncStream<PlaybackPresentationReplacement> {
        AsyncStream { continuation in continuation.finish() }
    }

    func claimPresentationMountOwnership(
        for replacement: PlaybackPresentationReplacement
    ) -> PlaybackPresentationMountClaimResult {
        claimCallCount += 1
        if suspendedClaimCall == claimCallCount { claimGate?.wait() }
        let (next, overflow) = presentationMountNonce.addingReportingOverflow(1)
        guard !overflow else { return .exhausted }
        presentationMountNonce = next
        return .claimed(.init(
            subscriptionGeneration: replacement.subscriptionGeneration,
            presentationIdentity: replacement.desired?.identity,
            mountNonce: next
        ))
    }

    func failPresentationControl() {
        presentationControlFailureCount += 1
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

}

private actor ViewModelNonCooperativePresentationProvider {
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var streamContinuations: [AsyncStream<PlaybackPresentationReplacement>.Continuation] = []
    private(set) var callCount = 0
    private(set) var activeCalls = 0
    private(set) var peakConcurrentCalls = 0

    func stream() async -> AsyncStream<PlaybackPresentationReplacement> {
        callCount += 1
        activeCalls += 1
        peakConcurrentCalls = max(peakConcurrentCalls, activeCalls)
        let call = callCount
        if call == 1 {
            await withCheckedContinuation { firstCallContinuation = $0 }
        }
        activeCalls -= 1
        let session = PlaybackSessionIdentity(sessionID: UInt64(call), requestID: UUID())
        let backend = PlaybackBackendIdentity(
            sessionIdentity: session,
            backendGeneration: UInt64(call)
        )
        let pair = AsyncStream.makeStream(of: PlaybackPresentationReplacement.self)
        streamContinuations.append(pair.continuation)
        pair.continuation.yield(.init(
            subscriptionGeneration: UInt64(call),
            revision: 1,
            desired: .init(
                identity: .init(
                    sessionIdentity: session,
                    backendIdentity: backend,
                    outputLifecycleEpoch: .init(
                        backendIdentity: backend,
                        outputNonce: UInt64(call)
                    ),
                    itemGeneration: nil,
                    presentationNonce: UInt64(call)
                ),
                presentation: .sampleBuffer(PlaybackPresentationContext())
            )
        ))
        return pair.stream
    }

    func releaseFirstCall() {
        let continuation = firstCallContinuation
        firstCallContinuation = nil
        continuation?.resume()
    }
}

private actor ViewModelDelayedSamePresentationProvider {
    private let presentation: IdentifiedPlaybackPresentation
    private var secondCallContinuation: CheckedContinuation<Void, Never>?
    private var streamContinuations: [AsyncStream<PlaybackPresentationReplacement>.Continuation] = []
    private(set) var callCount = 0
    private(set) var secondCallIsBlocked = false

    init(presentation: IdentifiedPlaybackPresentation) {
        self.presentation = presentation
    }

    func next() async -> AsyncStream<PlaybackPresentationReplacement> {
        callCount += 1
        let call = callCount
        if call == 2 {
            secondCallIsBlocked = true
            await withCheckedContinuation { secondCallContinuation = $0 }
            secondCallIsBlocked = false
        }
        let pair = AsyncStream.makeStream(
            of: PlaybackPresentationReplacement.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        streamContinuations.append(pair.continuation)
        pair.continuation.yield(.init(
            subscriptionGeneration: UInt64(call),
            revision: 1,
            desired: presentation
        ))
        return pair.stream
    }

    func releaseSecondCall() {
        let continuation = secondCallContinuation
        secondCallContinuation = nil
        continuation?.resume()
    }

    func finishFirstStream() {
        streamContinuations.first?.finish()
    }
}

private actor RegistryMountClaimViewModelEngine: PlaybackEngine, PlaybackPresentationControlling {
    private let registry: ControlTaskRegistry
    private let claimGate: ViewModelBlockingGate?
    private(set) var claimReturnCount = 0
    private(set) var failReturnCount = 0

    init(registry: ControlTaskRegistry, claimGate: ViewModelBlockingGate? = nil) {
        self.registry = registry
        self.claimGate = claimGate
    }

    func events() -> AsyncStream<PlaybackState> {
        AsyncStream { $0.finish() }
    }

    func play(_: PlaybackRequest) async {}
    func setPaused(_: Bool) async {}
    func stop() async {}
    func setTuning(_: PlaybackTuning) async {}

    func presentations() throws -> AsyncStream<PlaybackPresentationReplacement> {
        AsyncStream { continuation in continuation.finish() }
    }

    func claimPresentationMountOwnership(
        for replacement: PlaybackPresentationReplacement
    ) -> PlaybackPresentationMountClaimResult {
        claimGate?.wait()
        // 该兼容夹具不再用于跨capability生产接线；保留给旧测试的显式stale结果。
        claimReturnCount += 1
        _ = replacement
        return .stale
    }

    func failPresentationControl() {
        registry.failPresentationControl()
        failReturnCount += 1
    }
}

private final class ViewModelOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

private actor ViewModelMediaInformationFeed {
    private let pair = AsyncStream.makeStream(of: PlaybackMediaInformation?.self)

    func stream() -> AsyncStream<PlaybackMediaInformation?> {
        pair.stream
    }

    func emit(_ information: PlaybackMediaInformation?) {
        pair.continuation.yield(information)
    }
}

private actor ViewModelMediaGenerationFeed {
    private let previous: PlaybackMediaInformation
    private var pair: (stream: AsyncStream<PlaybackMediaInformation?>,
                       continuation: AsyncStream<PlaybackMediaInformation?>.Continuation)?
    private var playCompleted = false

    init(previous: PlaybackMediaInformation) {
        self.previous = previous
    }

    var hasSubscriber: Bool { pair != nil }

    func stream() -> AsyncStream<PlaybackMediaInformation?> {
        let next = AsyncStream.makeStream(of: PlaybackMediaInformation?.self)
        pair = next
        if playCompleted {
            next.continuation.yield(nil)
        } else {
            next.continuation.yield(previous)
        }
        return next.stream
    }

    func markPlayCompleted() {
        playCompleted = true
        pair?.continuation.yield(nil)
    }

    func prepareNextPlay() {
        playCompleted = false
        pair = nil
    }

    func emit(_ information: PlaybackMediaInformation?) {
        pair?.continuation.yield(information)
    }
}

private actor ViewModelNonCooperativeMediaInformationProvider {
    private var continuation: CheckedContinuation<AsyncStream<PlaybackMediaInformation?>, Never>?

    var hasWaiter: Bool { continuation != nil }

    func stream() async -> AsyncStream<PlaybackMediaInformation?> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        let pair = AsyncStream.makeStream(of: PlaybackMediaInformation?.self)
        continuation?.resume(returning: pair.stream)
        continuation = nil
    }
}

private actor ViewModelPlaybackEngine: PlaybackEngine, PlaybackPresentationControlling {
    private let log: ViewModelOperationLog
    private var stateContinuation: AsyncStream<PlaybackState>.Continuation?
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var pauses: [Bool] = []
    private var presentationMountNonce: UInt64 = 0

    init(log: ViewModelOperationLog) {
        self.log = log
    }

    func events() -> AsyncStream<PlaybackState> {
        let pair = AsyncStream.makeStream(of: PlaybackState.self)
        stateContinuation = pair.continuation
        log.append("events")
        return pair.stream
    }

    func play(_ request: PlaybackRequest) async {
        playCount += 1
        log.append("play")
    }

    func setPaused(_ paused: Bool) async {
        pauses.append(paused)
    }

    func stop() async {
        stopCount += 1
        log.append("stop")
    }

    func setTuning(_ tuning: PlaybackTuning) async {
        log.append("tuning:\(tuning.videoBufferSeconds)")
    }

    func presentations() throws -> AsyncStream<PlaybackPresentationReplacement> {
        AsyncStream { continuation in continuation.finish() }
    }

    func claimPresentationMountOwnership(
        for replacement: PlaybackPresentationReplacement
    ) -> PlaybackPresentationMountClaimResult {
        let (next, overflow) = presentationMountNonce.addingReportingOverflow(1)
        guard !overflow else { return .exhausted }
        presentationMountNonce = next
        return .claimed(.init(
            subscriptionGeneration: replacement.subscriptionGeneration,
            presentationIdentity: replacement.desired?.identity,
            mountNonce: next
        ))
    }

    func failPresentationControl() {
        stateContinuation?.yield(.failed(.init(
            code: "presentation.identity.exhausted",
            userMessage: "播放器呈现身份已耗尽。",
            retryDisposition: .doNotRetry
        )))
    }

    func emit(state: PlaybackState) {
        stateContinuation?.yield(state)
    }

}
