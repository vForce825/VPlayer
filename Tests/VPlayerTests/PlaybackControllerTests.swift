// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackControllerTests: XCTestCase {
    func testPipelinePhaseUsesMatchingCycleAndReadyAloneEntersPlaying() async throws {
        let pipeline = FakeControllerPipeline()
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline])
        )
        let request = makeRequest(channelID: "phase-cycle")
        await controller.play(request)

        pipeline.emit(.phase(.buffering, readinessCycle: 0))
        try await eventually {
            await controller.currentStateForTesting == .buffering(request)
        }
        pipeline.emit(.phase(.recovering, readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let staleInitialPhaseState = await controller.currentStateForTesting
        XCTAssertEqual(staleInitialPhaseState, .buffering(request))

        pipeline.emit(.phase(.recovering, readinessCycle: 0))
        try await eventually {
            await controller.currentStateForTesting == .recovering(request)
        }
        let recoveringState = await controller.currentStateForTesting
        XCTAssertNotEqual(recoveringState, .playing(request))
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually {
            await controller.currentStateForTesting == .playing(request)
        }

        await controller.setPaused(true)
        pipeline.emit(.phase(.buffering, readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let userPausedState = await controller.currentStateForTesting
        XCTAssertEqual(userPausedState, .paused(request))

        await controller.setPaused(false)
        pipeline.emit(.phase(.recovering, readinessCycle: 0))
        for _ in 0..<100 { await Task.yield() }
        let staleResumePhaseState = await controller.currentStateForTesting
        XCTAssertEqual(staleResumePhaseState, .preparing(request))
        pipeline.emit(.phase(.buffering, readinessCycle: 2))
        try await eventually {
            await controller.currentStateForTesting == .buffering(request)
        }
        let resumedBufferingState = await controller.currentStateForTesting
        XCTAssertNotEqual(resumedBufferingState, .playing(request))
        pipeline.emit(.ready(readinessCycle: 2))
        try await eventually {
            await controller.currentStateForTesting == .playing(request)
        }
    }

    func testPipelinePhaseCannotOverridePhysicalOrVetoSystemPause() async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "system-phase-fence")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually {
            await controller.currentStateForTesting == .playing(request)
        }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually {
            let cycle = await controller.readinessCycleForTesting
            let state = await controller.currentStateForTesting
            return cycle == 1 && state == .recovering(request)
        }
        pipeline.emit(.phase(.buffering, readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let physicallyPausedState = await controller.currentStateForTesting
        XCTAssertEqual(physicallyPausedState, .recovering(request))

        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually {
            await controller.currentStateForTesting == .paused(request)
        }
        pipeline.emit(.phase(.recovering, readinessCycle: 1))
        pipeline.emit(.ready(readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let vetoedState = await controller.currentStateForTesting
        XCTAssertEqual(vetoedState, .paused(request))
    }

    func testLifecycleEventStreamBoundsBacklogToEightLatestStates() async {
        let pipelines = (0..<10).map { _ in FakeControllerPipeline() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory(pipelines)
        )
        let stream = await controller.events()
        let requests = pipelines.indices.map {
            makeRequest(channelID: "session-\($0)")
        }

        for request in requests {
            await controller.play(request)
        }

        var iterator = stream.makeAsyncIterator()
        var bufferedStates: [PlaybackState] = []
        for _ in 0..<8 {
            if let state = await iterator.next() { bufferedStates.append(state) }
        }
        let expected = requests.suffix(8).map(PlaybackState.preparing)
        XCTAssertEqual(bufferedStates, expected)
    }

    func testSessionRelayDeliversOneSessionEventsInFIFOOrder() async throws {
        let identity = PlaybackRunIdentity(sessionID: 7, requestID: UUID())
        let recorder = PlaybackRunEventRecorder(currentIdentity: identity)
        let relay = PlaybackSessionEventRelay(identity: identity) { identity, event in
            await recorder.receive(identity: identity, event: event)
        }
        let expected: [PlaybackPipelineEvent] = [
            .mediaInformation(nil),
            .ready(readinessCycle: 3),
            .failed(.demuxRead(-70)),
        ]

        for event in expected { relay.send(event) }

        try await eventually { await recorder.events == expected }
    }

    func testDeactivatedRelayDropsQueuedAndFutureEvents() async throws {
        let identity = PlaybackRunIdentity(sessionID: 10, requestID: UUID())
        let gate = ManualControllerAsyncGate()
        let recorder = PlaybackRunEventRecorder(
            currentIdentity: identity,
            gate: gate
        )
        let relay = PlaybackSessionEventRelay(identity: identity) { identity, event in
            await recorder.receive(identity: identity, event: event)
        }

        relay.send(.ready(readinessCycle: 0))
        try await eventually { gate.waiterCount == 1 }
        relay.send(.ready(readinessCycle: 1))
        relay.deactivate()
        for cycle in 2..<100 {
            relay.send(.ready(readinessCycle: UInt64(cycle)))
        }
        gate.open()
        try await eventually { await recorder.completedReceiveCount == 1 }
        for _ in 0..<100 { await Task.yield() }

        let events = await recorder.events
        XCTAssertEqual(events, [.ready(readinessCycle: 0)])
        let completedReceiveCount = await recorder.completedReceiveCount
        XCTAssertEqual(completedReceiveCount, 1)
    }

    func testQueuedOldSessionRelayEventIsDiscardedAfterIdentityChanges() async throws {
        let oldIdentity = PlaybackRunIdentity(sessionID: 8, requestID: UUID())
        let newIdentity = PlaybackRunIdentity(sessionID: 9, requestID: UUID())
        let gate = ManualControllerAsyncGate()
        let recorder = PlaybackRunEventRecorder(
            currentIdentity: oldIdentity,
            gate: gate
        )
        let relay = PlaybackSessionEventRelay(identity: oldIdentity) { identity, event in
            await recorder.receive(identity: identity, event: event)
        }

        relay.send(.ready(readinessCycle: 0))
        try await eventually { gate.waiterCount == 1 }
        await recorder.setCurrentIdentity(newIdentity)
        gate.open()
        try await eventually { await recorder.completedReceiveCount == 1 }

        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)
    }

    func testAudioSessionRelayKeepsResumeThenNewInterruptionInSourceOrder() async throws {
        let identity = PlaybackRunIdentity(sessionID: 11, requestID: UUID())
        let lease = PlaybackAudioSessionLease(id: 1, generation: 1)
        let gate = ManualControllerAsyncGate()
        let recorder = AudioSessionRelayStateRecorder(gate: gate)
        let relay = PlaybackAudioSessionEventRelay(identity: identity) {
            identity, lease, event in
            await recorder.receive(identity: identity, lease: lease, event: event)
        }

        relay.send(lease: lease, event: .explicitResumeSucceeded)
        try await eventually { gate.waiterCount == 1 }
        relay.send(lease: lease, event: .interruptionBegan)
        for _ in 0..<100 { await Task.yield() }
        let blockedSnapshot = await recorder.snapshot
        XCTAssertEqual(blockedSnapshot.receiveCount, 1)

        gate.open()
        try await eventually {
            await recorder.snapshot.events == [
                .explicitResumeSucceeded,
                .interruptionBegan,
            ]
        }
        let finalSnapshot = await recorder.snapshot
        XCTAssertTrue(finalSnapshot.isSystemPaused)
    }

    func testAudioSessionRelayDeactivateDropsPendingAndFutureEvents() async throws {
        let identity = PlaybackRunIdentity(sessionID: 12, requestID: UUID())
        let lease = PlaybackAudioSessionLease(id: 2, generation: 2)
        let gate = ManualControllerAsyncGate()
        let recorder = AudioSessionRelayStateRecorder(gate: gate)
        let relay = PlaybackAudioSessionEventRelay(identity: identity) {
            identity, lease, event in
            await recorder.receive(identity: identity, lease: lease, event: event)
        }

        relay.send(lease: lease, event: .explicitResumeSucceeded)
        try await eventually { gate.waiterCount == 1 }
        relay.send(lease: lease, event: .interruptionBegan)
        relay.deactivate()
        relay.send(lease: lease, event: .mediaServicesWereReset)
        gate.open()
        try await eventually { await recorder.snapshot.events.count == 1 }
        for _ in 0..<100 { await Task.yield() }

        let snapshot = await recorder.snapshot
        XCTAssertEqual(snapshot.events, [.explicitResumeSucceeded])
        XCTAssertEqual(snapshot.receiveCount, 1)
    }

    func testLaterPlayWinsWhenEarlierFactorySuccessArrivesLast() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let firstPipeline = FakeControllerPipeline()
        let secondPipeline = FakeControllerPipeline()
        let controller = PlaybackController(factory: factory)
        let firstRequest = makeRequest(channelID: "first")
        let secondRequest = makeRequest(channelID: "second")

        let firstPlay = Task { await controller.play(firstRequest) }
        try await eventually { factory.isPending(callID: 1) }
        let secondPlay = Task { await controller.play(secondRequest) }
        try await eventually { factory.isPending(callID: 2) }

        factory.succeed(callID: 2, with: secondPipeline)
        await secondPlay.value
        factory.succeed(callID: 1, with: firstPipeline)
        await firstPlay.value

        XCTAssertEqual(secondPipeline.snapshot().starts, [secondRequest.streamURL])
        XCTAssertTrue(firstPipeline.snapshot().starts.isEmpty)
        XCTAssertEqual(firstPipeline.snapshot().stopCount, 1)
        secondPipeline.emit(.ready(readinessCycle: 0))
        try await eventually {
            await controller.currentStateForTesting == .playing(secondRequest)
        }
    }

    func testLaterPlayIgnoresEarlierFactoryFailureArrivingLast() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let secondPipeline = FakeControllerPipeline()
        let controller = PlaybackController(factory: factory)
        let firstRequest = makeRequest(channelID: "first")
        let firstPlay = Task { await controller.play(firstRequest) }
        try await eventually { factory.isPending(callID: 1) }
        let secondRequest = makeRequest(channelID: "second")
        let secondPlay = Task { await controller.play(secondRequest) }
        try await eventually { factory.isPending(callID: 2) }

        factory.succeed(callID: 2, with: secondPipeline)
        await secondPlay.value
        factory.fail(callID: 1, with: .demuxOpen(-71))
        await firstPlay.value
        secondPipeline.emit(.ready(readinessCycle: 0))

        try await eventually {
            await controller.currentStateForTesting == .playing(secondRequest)
        }
    }

    func testStopWinsWhenSuspendedFactorySuccessArrivesLast() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let controller = PlaybackController(factory: factory)
        let request = makeRequest(channelID: "first")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }

        await controller.stop()
        factory.succeed(callID: 1, with: pipeline)
        await play.value

        XCTAssertTrue(pipeline.snapshot().starts.isEmpty)
        XCTAssertEqual(pipeline.snapshot().stopCount, 1)
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .stopped)
    }

    func testRecoveryFailureTeardownBlocksReplacementFactoryAndStart() async throws {
        let first = FakeControllerPipeline()
        first.stopAutomaticallyCompletes = false
        let second = FakeControllerPipeline()
        let factory = FakeControllerPipelineFactory([first, second])
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(factory: factory, audioSessionOwner: owner)
        await controller.play(makeRequest(channelID: "first"))

        await MainActor.run {
            owner.emit(.recoveryFailed(stage: .mediaServicesResetActivation))
        }
        try await eventually { first.snapshot().isStopWaiting }
        let replacementRequest = makeRequest(channelID: "replacement")
        let replacement = Task {
            await controller.play(replacementRequest)
        }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(factory.makeCountSnapshot, 1)
        XCTAssertTrue(second.snapshot().starts.isEmpty)
        first.completeStop()
        await replacement.value

        XCTAssertEqual(factory.makeCountSnapshot, 2)
        XCTAssertEqual(second.snapshot().starts.count, 1)
        let state = await controller.currentStateForTesting
        guard case .preparing = state else {
            return XCTFail("旧恢复失败不得覆盖新播放状态")
        }
    }

    func testFactoryPendingInterruptionBeginsThenStartsInitiallyPaused() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "interrupted")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually {
            await controller.currentStateForTesting == .recovering(request)
        }
        factory.succeed(callID: 1, with: pipeline)
        await play.value

        XCTAssertEqual(pipeline.snapshot().pauses.map(\.0), [true])
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .recovering(request))
    }

    func testFactoryPendingInterruptionEndsThenStartsNormally() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run {
            RecordingPlaybackAudioSessionOwner(interruptedAtAcquisition: true)
        }
        let controller = PlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "reactivated")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        let interrupted = await controller.audioSessionInterruptedForTesting
        XCTAssertTrue(interrupted)

        await MainActor.run {
            owner.emit(.interruptionEnded(shouldResume: true))
        }
        try await eventually {
            !(await controller.audioSessionInterruptedForTesting)
        }
        factory.succeed(callID: 1, with: pipeline)
        await play.value

        XCTAssertTrue(pipeline.snapshot().pauses.isEmpty)
        XCTAssertEqual(pipeline.snapshot().startReadinessCycles, [1])
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .preparing(request))
        pipeline.emit(.ready(readinessCycle: 1))
        try await eventually {
            await controller.currentStateForTesting == .playing(request)
        }
    }

    func testFactoryPendingRecoveryFailureFailsAndStopsLatePipelineWithoutStart()
        async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "failure")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run {
            owner.emit(.recoveryFailed(stage: .mediaServicesResetConfiguration))
        }
        try await eventually {
            guard case let .failed(failure) = await controller.currentStateForTesting else {
                return false
            }
            return failure.code == "audio.session.activation"
        }
        factory.succeed(callID: 1, with: pipeline)
        await play.value

        XCTAssertTrue(pipeline.snapshot().starts.isEmpty)
        XCTAssertEqual(pipeline.snapshot().stopCount, 1)
        let ownerEvents = await MainActor.run { owner.events }
        XCTAssertEqual(ownerEvents.filter { $0 == .release(lease) }.count, 1)
    }

    func testFactoryPendingMediaResetUsesNewReadinessCycleAndCompletes() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "reset")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }

        await MainActor.run { owner.emit(.mediaServicesWereReset) }
        try await eventually {
            await controller.currentStateForTesting == .recovering(request)
        }
        factory.succeed(callID: 1, with: pipeline)
        await play.value

        XCTAssertEqual(pipeline.snapshot().audioSessionResetRecoveries, [1])
        pipeline.emit(.ready(readinessCycle: 0))
        for _ in 0..<100 { await Task.yield() }
        let staleState = await controller.currentStateForTesting
        XCTAssertEqual(staleState, .recovering(request))
        pipeline.emit(.ready(readinessCycle: 1))
        try await eventually {
            await controller.currentStateForTesting == .playing(request)
        }
    }

    func testFactoryPendingUserPauseStartsPausedAtCurrentReadinessCycle() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let controller = PlaybackController(factory: factory)
        let request = makeRequest(channelID: "factory-user-pause")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }

        await controller.setPaused(true)
        let pausedState = await controller.currentStateForTesting
        XCTAssertEqual(pausedState, .paused(request))
        factory.succeed(callID: 1, with: pipeline)
        await play.value

        XCTAssertEqual(pipeline.snapshot().startReadinessCycles, [1])
        XCTAssertEqual(pipeline.snapshot().pauses.map(\.0), [true])
        await controller.setPaused(false)
        XCTAssertEqual(pipeline.snapshot().pauses.map(\.0), [true, false])
        pipeline.emit(.ready(readinessCycle: 2))
        try await eventually {
            await controller.currentStateForTesting == .playing(request)
        }
    }

    func testFactoryPendingNonResumableInterruptionResetKeepsInitialSystemPause()
        async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "factory-resume-veto")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 1 }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually { !(await controller.audioSessionInterruptedForTesting) }
        await MainActor.run { owner.emit(.mediaServicesWereReset) }
        try await eventually { await controller.readinessCycleForTesting == 2 }
        factory.succeed(callID: 1, with: pipeline)
        await play.value

        XCTAssertEqual(pipeline.snapshot().startReadinessCycles, [2])
        XCTAssertEqual(pipeline.snapshot().pauses.map(\.0), [true])
        XCTAssertEqual(pipeline.snapshot().audioSessionResetRecoveries, [2])
        pipeline.emit(.ready(readinessCycle: 2))
        for _ in 0..<100 { await Task.yield() }
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .paused(request))
    }

    func testFailureRetainsMetricsUntilNextPlayBegins() async throws {
        let terminalMetrics = PlaybackMetrics(
            channelID: "terminal",
            now: { 10 },
            residentMemoryProvider: { 101 }
        )
        let firstPipeline = FakeControllerPipeline(metrics: terminalMetrics)
        let secondPipeline = FakeControllerPipeline()
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([firstPipeline, secondPipeline])
        )

        await controller.play(makeRequest(channelID: "first"))
        firstPipeline.emit(.failed(.demuxRead(-72)))
        try await eventually {
            if case .failed = await controller.currentStateForTesting { return true }
            return false
        }
        let failedSnapshot = await controller.playbackMetricsSnapshot(window: .seconds(60))
        XCTAssertEqual(failedSnapshot?.residentMemoryBytes, 101)

        await controller.play(makeRequest(channelID: "second"))
        let replacementSnapshot = await controller.playbackMetricsSnapshot(window: .seconds(60))
        XCTAssertNil(replacementSnapshot)
    }

    func testExplicitStopClearsMetricsRetainedAfterFailure() async throws {
        let terminalMetrics = PlaybackMetrics(
            channelID: "terminal",
            now: { 10 },
            residentMemoryProvider: { 202 }
        )
        let pipeline = FakeControllerPipeline(metrics: terminalMetrics)
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline])
        )

        await controller.play(makeRequest(channelID: "first"))
        pipeline.emit(.failed(.demuxRead(-73)))
        try await eventually {
            await controller.playbackMetricsSnapshot(window: .seconds(60)) != nil
        }
        await controller.stop()

        let stoppedSnapshot = await controller.playbackMetricsSnapshot(window: .seconds(60))
        XCTAssertNil(stoppedSnapshot)
    }

    func testChannelReplacementAcquiresNewAudioLeaseBeforeReleasingOldLease() async throws {
        let firstPipeline = FakeControllerPipeline()
        let replacementPipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([firstPipeline, replacementPipeline]),
            audioSessionOwner: owner
        )

        await controller.play(makeRequest(channelID: "first"))
        await controller.play(makeRequest(channelID: "replacement"))

        let beforeStop = await MainActor.run { owner.events }
        XCTAssertEqual(beforeStop, [
            .acquire(PlaybackAudioSessionLease(id: 1, generation: 1)),
            .acquire(PlaybackAudioSessionLease(id: 2, generation: 2)),
            .release(PlaybackAudioSessionLease(id: 1, generation: 1)),
        ])

        await controller.stop()

        let afterStop = await MainActor.run { owner.events }
        XCTAssertEqual(afterStop.last, .release(PlaybackAudioSessionLease(id: 2, generation: 2)))
    }

    func testOldAudioLeaseEventCannotMutateReplacementRun() async throws {
        let firstPipeline = FakeControllerPipeline()
        let replacementPipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([firstPipeline, replacementPipeline]),
            audioSessionOwner: owner
        )
        let firstRequest = makeRequest(channelID: "first")
        let replacementRequest = makeRequest(channelID: "replacement")
        await controller.play(firstRequest)
        let oldLease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.first) }
        await controller.play(replacementRequest)
        replacementPipeline.emit(.ready(readinessCycle: 0))
        try await eventually {
            await controller.currentStateForTesting == .playing(replacementRequest)
        }

        await MainActor.run {
            owner.emitEvenIfReleased(.interruptionBegan, for: oldLease)
        }
        for _ in 0..<100 { await Task.yield() }

        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .playing(replacementRequest))
    }

    func testOwnerResumeAndResetEventsDoNotResumeUserPausedPlayback() async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "paused")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        await controller.setPaused(true)

        await MainActor.run {
            owner.emit(.interruptionEnded(shouldResume: true))
            owner.emit(.mediaServicesWereReset)
        }
        for _ in 0..<100 { await Task.yield() }

        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .paused(request))
        XCTAssertEqual(pipeline.snapshot().audioSessionResetRecoveries, [2])
    }

    func testPlayingMediaServicesResetRunsRecoveryAndMatchingReadyReturnsToPlaying()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "reset-recovery")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }

        await MainActor.run { owner.emit(.mediaServicesWereReset) }
        try await eventually {
            let state = await controller.currentStateForTesting
            return pipeline.snapshot().audioSessionResetRecoveries == [1]
                && state == .recovering(request)
        }
        pipeline.emit(.ready(readinessCycle: 0))
        for _ in 0..<100 { await Task.yield() }
        let staleReadyState = await controller.currentStateForTesting
        XCTAssertEqual(staleReadyState, .recovering(request))

        pipeline.emit(.ready(readinessCycle: 1))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        XCTAssertTrue(pipeline.snapshot().pauses.isEmpty)
    }

    func testMediaResetAfterInterruptionRecoversThenReleasesSystemPauseOnSameCycle()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "interruption-reset")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations == [.pause(true, 1)]
        }
        await MainActor.run { owner.emit(.mediaServicesWereReset) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations == [
                .pause(true, 1),
                .reset(2),
                .pause(false, 2),
            ]
        }

        pipeline.emit(.ready(readinessCycle: 2))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
    }

    func testNonResumableInterruptionResetRebuildsWithoutReleasingSystemPause()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "installed-resume-veto")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations == [.pause(true, 1)]
        }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually { !(await controller.audioSessionInterruptedForTesting) }
        await MainActor.run { owner.emit(.mediaServicesWereReset) }
        try await eventually {
            pipeline.snapshot().audioSessionResetRecoveries == [2]
        }

        XCTAssertEqual(pipeline.snapshot().audioLifecycleOperations, [
            .pause(true, 1),
            .reset(2),
        ])
        pipeline.emit(.phase(.recovering, readinessCycle: 2))
        for _ in 0..<100 { await Task.yield() }
        pipeline.emit(.ready(readinessCycle: 2))
        for _ in 0..<100 { await Task.yield() }
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .paused(request))
    }

    func testExplicitResumeAfterVetoActivatesCurrentLeaseBeforeResuming() async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "explicit-resume")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 1 }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually {
            let interrupted = await controller.audioSessionInterruptedForTesting
            let state = await controller.currentStateForTesting
            return !interrupted && state == .paused(request)
        }
        await MainActor.run { owner.emit(.mediaServicesWereReset) }
        try await eventually {
            pipeline.snapshot().audioSessionResetRecoveries == [2]
        }
        await controller.setPaused(false)

        try await eventually {
            let events = await MainActor.run { owner.events }
            return events.contains(.requestResume(lease))
                && pipeline.snapshot().audioLifecycleOperations.last == .pause(false, 2)
        }
        pipeline.emit(.ready(readinessCycle: 2))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
    }

    func testExplicitResumeActivationFailureUsesTerminalRecoveryFailurePath()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run {
            RecordingPlaybackAudioSessionOwner(explicitResumeFails: true)
        }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "explicit-resume-failure")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 1 }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually {
            let interrupted = await controller.audioSessionInterruptedForTesting
            let state = await controller.currentStateForTesting
            return !interrupted && state == .paused(request)
        }
        await controller.setPaused(false)

        try await eventually {
            guard case let .failed(failure) = await controller.currentStateForTesting else {
                return false
            }
            return failure.code == "audio.session.activation"
                && pipeline.snapshot().completedStopCount == 1
        }
        let events = await MainActor.run { owner.events }
        XCTAssertEqual(events.filter { $0 == .requestResume(lease) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .release(lease) }.count, 1)
    }

    func testRepeatedExplicitResumeWhileFirstRequestIsPendingActivatesOnlyOnce()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run {
            RecordingPlaybackAudioSessionOwner(
                deferFirstExplicitResume: true,
                failAdditionalExplicitResume: true
            )
        }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "deduplicated-explicit-resume")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 1 }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually { await controller.currentStateForTesting == .paused(request) }

        await controller.setPaused(false)
        await controller.setPaused(false)
        let requestCount = await MainActor.run {
            owner.events.filter { $0 == .requestResume(lease) }.count
        }
        XCTAssertEqual(requestCount, 1)

        await MainActor.run { owner.completeDeferredExplicitResume() }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations.filter {
                $0 == .pause(false, 1)
            }.count == 1
        }
        pipeline.emit(.ready(readinessCycle: 1))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
    }

    func testExplicitResumeSuccessThenNewInterruptionEndsSystemPausedInSourceOrder()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run {
            RecordingPlaybackAudioSessionOwner(deferFirstExplicitResume: true)
        }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "resume-then-interrupt")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 1 }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually { await controller.currentStateForTesting == .paused(request) }
        await controller.setPaused(false)

        await MainActor.run {
            owner.completeDeferredExplicitResume()
            owner.emit(.interruptionBegan)
        }
        try await eventually {
            let operations = pipeline.snapshot().audioLifecycleOperations
            let state = await controller.currentStateForTesting
            return operations.suffix(2) == [
                .pause(false, 1),
                .pause(true, 2),
            ] && state == .recovering(request)
        }
        pipeline.emit(.ready(readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let finalState = await controller.currentStateForTesting
        XCTAssertEqual(finalState, .recovering(request))
    }

    func testExplicitResumeDuringNewPhysicalInterruptionDoesNotRequestOwner()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "resume-during-new-interruption")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 1 }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually { await controller.currentStateForTesting == .paused(request) }
        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 2 }

        await controller.setPaused(false)
        let activeRequestCount = await MainActor.run {
            owner.events.filter { $0 == .requestResume(lease) }.count
        }
        XCTAssertEqual(activeRequestCount, 0)

        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually { !(await controller.audioSessionInterruptedForTesting) }
        await controller.setPaused(false)
        try await eventually {
            let requestCount = await MainActor.run {
                owner.events.filter { $0 == .requestResume(lease) }.count
            }
            return requestCount == 1
                && pipeline.snapshot().audioLifecycleOperations.last == .pause(false, 2)
        }
        pipeline.emit(.ready(readinessCycle: 2))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
    }

    func testInterruptionEndedWithoutResumeAllowsNextInterruptionToCompleteRecovery()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "repeated-interruption")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations == [.pause(true, 1)]
        }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually { !(await controller.audioSessionInterruptedForTesting) }
        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations == [
                .pause(true, 1),
                .pause(true, 2),
            ]
        }
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: true)) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations.last == .pause(false, 2)
        }
        pipeline.emit(.ready(readinessCycle: 2))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
    }

    func testUserResumeDuringInterruptionKeepsSystemPauseUntilOwnerEndsIt() async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "user-resume-during-interruption")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }

        await MainActor.run { owner.emit(.interruptionBegan) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations == [.pause(true, 1)]
        }
        await controller.setPaused(true)
        await controller.setPaused(false)

        XCTAssertFalse(pipeline.snapshot().audioLifecycleOperations.contains(.pause(false, 3)))
        let interruptedState = await controller.currentStateForTesting
        XCTAssertEqual(interruptedState, .recovering(request))
        await MainActor.run { owner.emit(.interruptionEnded(shouldResume: true)) }
        try await eventually {
            pipeline.snapshot().audioLifecycleOperations.last == .pause(false, 3)
        }
        pipeline.emit(.ready(readinessCycle: 3))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
    }

    func testCurrentAudioSessionRecoveryFailureStopsOnceReleasesLeaseAndIsRetryable()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        await controller.play(makeRequest(channelID: "activation-failure"))
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run {
            owner.emit(.recoveryFailed(stage: .interruptionReactivation))
            owner.emitEvenIfReleased(
                .recoveryFailed(stage: .mediaServicesResetActivation),
                for: lease
            )
        }

        try await eventually {
            guard case let .failed(failure) = await controller.currentStateForTesting else {
                return false
            }
            return failure.code == "audio.session.activation"
                && pipeline.snapshot().completedStopCount == 1
        }
        let ownerEvents = await MainActor.run { owner.events }
        XCTAssertEqual(ownerEvents.filter { $0 == .release(lease) }.count, 1)
        XCTAssertEqual(pipeline.snapshot().stopCount, 1)
    }

    func testInterruptedLeaseClosesNewRunBeforePipelineStart() async {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run {
            RecordingPlaybackAudioSessionOwner(interruptedAtAcquisition: true)
        }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "interrupted-switch")

        await controller.play(request)

        XCTAssertEqual(pipeline.snapshot().pauses.map(\.0), [true])
        XCTAssertEqual(pipeline.snapshot().starts, [request.streamURL])
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .recovering(request))
    }

    func testPipelineFactoryFailureReleasesTheAcquiredAudioLease() async {
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = PlaybackController(
            factory: FakeControllerPipelineFactory([]),
            audioSessionOwner: owner
        )

        await controller.play(makeRequest(channelID: "factory-failure"))

        let result = await MainActor.run { (owner.acquiredLeases, owner.events) }
        guard let lease = result.0.first else {
            return XCTFail("创建 pipeline 前必须先取得音频会话 lease")
        }
        XCTAssertEqual(result.1, [.acquire(lease), .release(lease)])
    }

    private func makeRequest(channelID: String) -> PlaybackRequest {
        PlaybackRequest(
            sourceProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            channelID: channelID,
            streamURL: URL(string: "https://example.invalid/stream")!,
            title: channelID
        )
    }

    private func eventually(
        attempts: Int = 10_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("条件在限定调度轮次内未满足", file: file, line: line)
    }
}

@MainActor
private final class RecordingPlaybackAudioSessionOwner: PlaybackAudioSessionOwning {
    enum Event: Equatable {
        case acquire(PlaybackAudioSessionLease)
        case release(PlaybackAudioSessionLease)
        case requestResume(PlaybackAudioSessionLease)
    }

    private var nextID: UInt64 = 1
    private var handlers: [PlaybackAudioSessionLease:
        @MainActor @Sendable (PlaybackAudioSessionLease, PlaybackAudioSessionEvent) -> Void] = [:]
    private(set) var events: [Event] = []
    private(set) var acquiredLeases: [PlaybackAudioSessionLease] = []
    private let interruptedAtAcquisition: Bool
    private let explicitResumeFails: Bool
    private let deferFirstExplicitResume: Bool
    private let failAdditionalExplicitResume: Bool
    private var deferredExplicitResume: (
        PlaybackAudioSessionLease,
        @MainActor @Sendable (PlaybackAudioSessionLease, PlaybackAudioSessionEvent) -> Void
    )?

    init(
        interruptedAtAcquisition: Bool = false,
        explicitResumeFails: Bool = false,
        deferFirstExplicitResume: Bool = false,
        failAdditionalExplicitResume: Bool = false
    ) {
        self.interruptedAtAcquisition = interruptedAtAcquisition
        self.explicitResumeFails = explicitResumeFails
        self.deferFirstExplicitResume = deferFirstExplicitResume
        self.failAdditionalExplicitResume = failAdditionalExplicitResume
    }

    func acquire(
        eventHandler: @escaping @MainActor @Sendable (
            PlaybackAudioSessionLease,
            PlaybackAudioSessionEvent
        ) -> Void
    ) throws -> PlaybackAudioSessionLease {
        let lease = PlaybackAudioSessionLease(
            id: nextID,
            generation: nextID,
            isInterruptedAtAcquisition: interruptedAtAcquisition
        )
        nextID += 1
        handlers[lease] = eventHandler
        acquiredLeases.append(lease)
        events.append(.acquire(lease))
        return lease
    }

    func release(_ lease: PlaybackAudioSessionLease) {
        events.append(.release(lease))
    }

    @discardableResult
    func requestResume(for lease: PlaybackAudioSessionLease) -> Bool {
        guard acquiredLeases.last == lease,
              let handler = handlers[lease] else { return false }
        events.append(.requestResume(lease))
        if deferFirstExplicitResume, deferredExplicitResume == nil {
            deferredExplicitResume = (lease, handler)
            return true
        }
        if failAdditionalExplicitResume {
            handler(lease, .recoveryFailed(stage: .interruptionReactivation))
            return true
        }
        if explicitResumeFails {
            handler(lease, .recoveryFailed(stage: .interruptionReactivation))
        } else {
            handler(lease, .explicitResumeSucceeded)
        }
        return true
    }

    func completeDeferredExplicitResume() {
        guard let (lease, handler) = deferredExplicitResume else { return }
        deferredExplicitResume = nil
        handler(lease, .explicitResumeSucceeded)
    }

    func emit(_ event: PlaybackAudioSessionEvent) {
        guard let lease = acquiredLeases.last,
              let handler = handlers[lease] else { return }
        handler(lease, event)
    }

    func emitEvenIfReleased(
        _ event: PlaybackAudioSessionEvent,
        for lease: PlaybackAudioSessionLease
    ) {
        handlers[lease]?(lease, event)
    }
}

private actor PlaybackRunEventRecorder {
    private var currentIdentity: PlaybackRunIdentity
    private let gate: ManualControllerAsyncGate?
    private(set) var events: [PlaybackPipelineEvent] = []
    private(set) var completedReceiveCount = 0

    init(
        currentIdentity: PlaybackRunIdentity,
        gate: ManualControllerAsyncGate? = nil
    ) {
        self.currentIdentity = currentIdentity
        self.gate = gate
    }

    func setCurrentIdentity(_ identity: PlaybackRunIdentity) {
        currentIdentity = identity
    }

    func receive(identity: PlaybackRunIdentity, event: PlaybackPipelineEvent) async {
        await gate?.wait()
        if currentIdentity == identity { events.append(event) }
        completedReceiveCount += 1
    }
}

private actor AudioSessionRelayStateRecorder {
    private let gate: ManualControllerAsyncGate
    private(set) var events: [PlaybackAudioSessionEvent] = []
    private(set) var receiveCount = 0
    private(set) var isSystemPaused = true

    init(gate: ManualControllerAsyncGate) {
        self.gate = gate
    }

    var snapshot: (
        events: [PlaybackAudioSessionEvent],
        receiveCount: Int,
        isSystemPaused: Bool
    ) {
        (events, receiveCount, isSystemPaused)
    }

    func receive(
        identity _: PlaybackRunIdentity,
        lease _: PlaybackAudioSessionLease,
        event: PlaybackAudioSessionEvent
    ) async {
        receiveCount += 1
        if receiveCount == 1 { await gate.wait() }
        events.append(event)
        switch event {
        case .interruptionBegan:
            isSystemPaused = true
        case .interruptionEnded(shouldResume: true):
            isSystemPaused = false
        case .interruptionEnded(shouldResume: false),
             .mediaServicesWereReset,
             .recoveryFailed:
            break
        case .explicitResumeSucceeded:
            isSystemPaused = false
        }
    }
}

private final class ManualControllerAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { lock.withLock { continuations.count } }

    func wait() async {
        let shouldWait = lock.withLock { !isOpen }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard !isOpen else { return true }
                continuations.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { continuations.removeAll(keepingCapacity: false) }
            return continuations
        }
        for continuation in pending { continuation.resume() }
    }
}
