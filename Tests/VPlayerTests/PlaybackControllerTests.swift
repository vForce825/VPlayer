// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
import VPlayerCore
@testable import VPlayerPlayback

private struct ErrorReportingPipelineFactory: PlaybackPipelineFactory {
    let error: any Error
    func makePipeline(tuning: PlaybackTuning, channelID: String,
                      eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void)
        async throws -> any PlaybackPipelineProtocol {
        throw error
    }
}

final class PlaybackControllerTests: XCTestCase {
    func testCancelledScopedPauseAndPlayCannotAdoptSameRequestRetryRun() async throws {
        for paused in [true, false] {
            let first = FakeControllerPipeline()
            let replacement = FakeControllerPipeline()
            let controller = makeRoutedPlaybackController(
                factory: FakeControllerPipelineFactory([first, replacement]))
            let request = makeRequest(channelID: "same-request-retry")
            await controller.play(request)
            let firstCycle = await controller.readinessCycleForTesting
            first.emit(.ready(readinessCycle: firstCycle))
            try await eventually { await controller.currentStateForTesting == .playing(request) }
            if !paused { await controller.setPaused(true) }
            let gate = ManualControllerAsyncGate()
            defer { gate.open() }
            await controller.setRequestScopedControlCheckpointForTesting { checkpoint in
                if checkpoint == .pauseIngress { await gate.wait() }
            }
            let oldCommand = Task { await controller.setPaused(paused, requestID: request.id) }
            try await eventually { gate.waiterCount == 1 }
            // FullScreen's failure/retry path cancels the originating command,
            // then intentionally reuses this exact request UUID for its new run.
            oldCommand.cancel()
            await controller.play(request)
            let replacementCycle = await controller.readinessCycleForTesting
            replacement.emit(.ready(readinessCycle: replacementCycle))
            try await eventually { await controller.currentStateForTesting == .playing(request) }
            if !paused { await controller.setPaused(true) }
            let expected: PlaybackState = paused ? .playing(request) : .paused(request)
            let before = await controller.currentStateForTesting
            XCTAssertEqual(before, expected)
            let pauseCount = replacement.snapshot().pauses.count
            gate.open()
            await oldCommand.value
            let after = await controller.currentStateForTesting
            XCTAssertEqual(after, expected)
            XCTAssertEqual(replacement.snapshot().pauses.count, pauseCount)
            await controller.stop()
        }
    }

    func testReplacementPreparationRejectsDelayedPreviousWatchdogArm() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let first = FakeControllerPipeline()
        let replacement = FakeControllerPipeline()
        let firstRequest = makeRequest(channelID: "watchdog-old")
        let replacementRequest = makeRequest(channelID: "watchdog-new")
        let firstPlay = Task { await controller.play(firstRequest) }
        try await eventually { factory.isPending(callID: 1) }
        factory.succeed(callID: 1, with: first)
        await firstPlay.value
        let oldSession = try XCTUnwrap(owner.registry.outputResourceContextSnapshot()?.sessionIdentity)
        let oldEpochValue = await controller.watchdog.currentActivationEpoch
        let oldEpoch = try XCTUnwrap(oldEpochValue)
        let nextPlay = Task { await controller.play(replacementRequest) }
        try await eventually { factory.isPending(callID: 2) }
        // B has crossed its exact new-play disarm but is still held in prepare.
        // Deliver A's previously authorized arm after that transition.
        await controller.watchdog.arm(activationEpoch: oldEpoch, hasObservedProgress: true,
            session: oldSession, controlRevision: 0)
        let armedDuringPrepare = await controller.watchdog.isArmed
        let epochDuringPrepare = await controller.watchdog.currentActivationEpoch
        XCTAssertFalse(armedDuringPrepare)
        XCTAssertNil(epochDuringPrepare)
        factory.succeed(callID: 2, with: replacement)
        await nextPlay.value
        let armedForReplacement = await controller.watchdog.isArmed
        XCTAssertTrue(armedForReplacement)
        await controller.stop()
    }

    func testScopedStopSuspendedAtWatchdogBoundaryCannotCancelReplacement() async throws {
        let first = FakeControllerPipeline()
        let replacement = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([first, replacement]), audioSessionOwner: owner)
        let firstRequest = makeRequest(channelID: "scoped-stop-first")
        let replacementRequest = makeRequest(channelID: "scoped-stop-replacement")
        await controller.play(firstRequest)
        let gate = ManualControllerAsyncGate()
        defer { gate.open() }
        await controller.setRequestScopedControlCheckpointForTesting { checkpoint in
            if checkpoint == .stopAfterWatchdog { await gate.wait() }
        }
        let obsoleteStop = Task { await controller.stop(requestID: firstRequest.id) }
        try await eventually { gate.waiterCount == 1 }
        await controller.play(replacementRequest)
        let cycle = await controller.readinessCycleForTesting
        replacement.emit(.ready(readinessCycle: cycle))
        try await eventually { await controller.currentStateForTesting == .playing(replacementRequest) }
        gate.open()
        await obsoleteStop.value
        XCTAssertEqual(owner.registry.outputResourceContextSnapshot()?.sessionIdentity.requestID, replacementRequest.id)
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .playing(replacementRequest))
        XCTAssertEqual(replacement.snapshot().stopCount, 0)
        await controller.stop()
    }

    func testScopedPauseAndResumeQueuedBeforeActorValidationCannotControlReplacement() async throws {
        for paused in [true, false] {
            let first = FakeControllerPipeline()
            let replacement = FakeControllerPipeline()
            let controller = makeRoutedPlaybackController(
                factory: FakeControllerPipelineFactory([first, replacement]))
            let firstRequest = makeRequest(channelID: "scoped-pause-first")
            let replacementRequest = makeRequest(channelID: "scoped-pause-replacement")
            await controller.play(firstRequest)
            let gate = ManualControllerAsyncGate()
            defer { gate.open() }
            await controller.setRequestScopedControlCheckpointForTesting { checkpoint in
                if checkpoint == .pauseIngress { await gate.wait() }
            }
            let obsoletePause = Task { await controller.setPaused(paused, requestID: firstRequest.id) }
            try await eventually { gate.waiterCount == 1 }
            await controller.play(replacementRequest)
            let cycle = await controller.readinessCycleForTesting
            replacement.emit(.ready(readinessCycle: cycle))
            try await eventually { await controller.currentStateForTesting == .playing(replacementRequest) }
            let pauseCountBeforeRelease = replacement.snapshot().pauses.count
            gate.open()
            await obsoletePause.value
            let state = await controller.currentStateForTesting
            XCTAssertEqual(state, .playing(replacementRequest))
            XCTAssertEqual(replacement.snapshot().pauses.count, pauseCountBeforeRelease)
            await controller.stop()
        }
    }

    func testCurrentRelayRejectsFrozenOldPrepareScopeAndAcceptsCurrentFailure() async throws {
        let first = FakeControllerPipeline()
        let current = FakeControllerPipeline()
        current.stopAutomaticallyCompletes = false
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([first, current]), audioSessionOwner: owner)
        let firstRequest = makeRequest(channelID: "scope-first-issued-ticket")
        let currentRequest = makeRequest(channelID: "scope-current-issued-ticket")
        defer {
            first.releaseStopForFailureCleanup()
            current.releaseStopForFailureCleanup()
        }

        func waitForScopeState(_ stage: String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !(await condition()) {
                guard ContinuousClock.now < deadline else {
                    throw NSError(domain: "HLSPrepareScopeRegressionTimeout", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "有域首错回归等待超时：\(stage)"])
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        do {
            await controller.play(firstRequest)
            let oldTicket = try XCTUnwrap(owner.registry.outputResourceContextSnapshot()?.prepareTicket)
            let oldScope = PlaybackBackendPrepareFailureScope(ticket: oldTicket)
            let firstCycle = await controller.readinessCycleForTesting
            first.emit(.ready(readinessCycle: firstCycle))
            try await waitForScopeState("首个真实签发播放已 ready") {
                await controller.currentStateForTesting == .playing(firstRequest)
            }

            // 两次播放使用同一个 owner.registry；新票由正常控制流程签发，不手造 nonce。
            await controller.play(currentRequest)
            let currentTicket = try XCTUnwrap(owner.registry.outputResourceContextSnapshot()?.prepareTicket)
            XCTAssertNotEqual(currentTicket.prepareNonce, oldTicket.prepareNonce)
            XCTAssertNotEqual(currentTicket.backendIdentity, oldTicket.backendIdentity,
                "此 controller 子测试明确使用新播放，不宣称同 backend replacement 的端到端验收")
            XCTAssertFalse(oldScope.matches(currentTicket))
            let currentCycle = await controller.readinessCycleForTesting
            current.emit(.ready(readinessCycle: currentCycle))
            try await waitForScopeState("当前真实签发播放已 ready") {
                await controller.currentStateForTesting == .playing(currentRequest)
            }
            XCTAssertEqual(first.snapshot().completedStopCount, 1)
            XCTAssertEqual(current.snapshot().stopCount, 0)

            // 故意通过当前 relay 投递旧票的冻结 scope，使 envelope 的 run/backend 检查通过；
            // 被测拒绝点必须是当前 PrepareTicket 与旧 prepareNonce 的不匹配。
            let oldMetadata = try HLSRuntimeFailureMetadataOwner.reserve(in: .shared)
            let oldDiagnostic = ErrorDiagnosticSnapshot(typeName: "HLS.OldGraph", message: "旧图排队错误")
            current.emit(.backendFailed(oldDiagnostic, prepareScope: oldScope,
                metadataOwner: oldMetadata))
            // 同一 relay 的 FIFO sentinel 证明旧 failure 已被消费，不靠任意 sleep 断言未停止。
            current.emit(.phase(.buffering, readinessCycle: currentCycle))
            try await waitForScopeState("当前 relay 已消费旧错误后的 FIFO sentinel") {
                await controller.currentStateForTesting == .buffering(currentRequest)
            }
            XCTAssertEqual(owner.registry.outputResourceContextSnapshot()?.prepareTicket, currentTicket)
            XCTAssertEqual(current.snapshot().stopCount, 0)
            XCTAssertEqual(first.snapshot().completedStopCount, 1)

            let currentMetadata = try HLSRuntimeFailureMetadataOwner.reserve(in: .shared)
            let currentDiagnostic = ErrorDiagnosticSnapshot(typeName: "HLS.CurrentGraph", message: "当前图真实错误")
            current.emit(.backendFailed(currentDiagnostic, prepareScope: .init(ticket: currentTicket),
                metadataOwner: currentMetadata))
            try await waitForScopeState("当前 scope 首错已开始唯一 owned stop") {
                current.snapshot().isStopWaiting
            }
            guard case let .failed(failure) = await controller.currentStateForTesting else {
                current.releaseStopForFailureCleanup()
                await controller.stop()
                await owner.registry.joinOwnedTerminalCleanup()
                return XCTFail("当前票首错必须在 cleanup 等待前公开")
            }
            XCTAssertTrue(failure.userMessage.contains("当前图真实错误"), failure.userMessage)
            XCTAssertFalse(failure.userMessage.contains("旧图排队错误"), failure.userMessage)
            XCTAssertEqual(current.snapshot().stopCount, 1)
            current.completeStop()
            await owner.registry.joinOwnedTerminalCleanup()
            let finalState = await controller.currentStateForTesting
            XCTAssertEqual(finalState, .failed(failure))
            XCTAssertEqual(current.snapshot().stopCount, 1)
            XCTAssertEqual(current.snapshot().completedStopCount, 1)
            XCTAssertNil(owner.registry.ownedResourceSnapshot())
        } catch {
            first.releaseStopForFailureCleanup()
            current.releaseStopForFailureCleanup()
            await controller.stop()
            await owner.registry.joinOwnedTerminalCleanup()
            throw error
        }
    }

    func testCurrentScopedBackendFailureStopsOnceAndPreservesOriginalDiagnostic() async throws {
        let pipeline = FakeControllerPipeline()
        pipeline.stopAutomaticallyCompletes = false
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]), audioSessionOwner: owner)
        defer { pipeline.releaseStopForFailureCleanup() }
        do {
            await controller.play(makeRequest(channelID: "hls-first-runtime-error"))
            let ticket = try XCTUnwrap(owner.registry.outputResourceContextSnapshot()?.prepareTicket)
            let original = ErrorDiagnosticSnapshot(NSError(domain: "HLS.Publication.Native", code: -72,
                userInfo: [NSLocalizedDescriptionKey: "后继分段发布关闭"]))
            pipeline.emit(.backendFailed(original,
                prepareScope: .init(ticket: ticket),
                metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: .shared)))
            try await eventually { pipeline.snapshot().isStopWaiting }
            guard case let .failed(failure) = await controller.currentStateForTesting else {
                pipeline.releaseStopForFailureCleanup()
                await controller.stop()
                await owner.registry.joinOwnedTerminalCleanup()
                return XCTFail("有域首错必须在 owned cleanup 等待前可见")
            }
            XCTAssertTrue(failure.userMessage.contains("HLS 媒体生成"), failure.userMessage)
            XCTAssertTrue(failure.userMessage.contains("HLS.Publication.Native"), failure.userMessage)
            XCTAssertTrue(failure.userMessage.contains("-72"), failure.userMessage)
            pipeline.emit(.backendFailed(ErrorDiagnosticSnapshot(
                typeName: "HLS.Secondary", message: "第二错误"), prepareScope: .init(ticket: ticket),
                metadataOwner: try HLSRuntimeFailureMetadataOwner.reserve(in: .shared)))
            await controller.failPresentationControl()
            XCTAssertEqual(pipeline.snapshot().stopCount, 1)
            pipeline.completeStop()
            await owner.registry.joinOwnedTerminalCleanup()
            let finalState = await controller.currentStateForTesting
            XCTAssertEqual(finalState, .failed(failure))
            XCTAssertNil(owner.registry.ownedResourceSnapshot())
            XCTAssertEqual(pipeline.snapshot().completedStopCount, 1)
        } catch {
            pipeline.releaseStopForFailureCleanup()
            await controller.stop()
            await owner.registry.joinOwnedTerminalCleanup()
            throw error
        }
    }

    func testBackendFirstFailureIsVisibleWhileCleanupWaitsAndSurvivesSafetyTerminal() async throws {
        let pipeline = FakeControllerPipeline()
        pipeline.stopAutomaticallyCompletes = false
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]), audioSessionOwner: owner
        )
        await controller.play(makeRequest(channelID: "first-error-cleanup"))
        pipeline.emit(.failed(.audioRendererFailed("NativeAudioFailure:-702")))
        try await eventually { pipeline.snapshot().isStopWaiting }
        guard case let .failed(original) = await controller.currentStateForTesting else {
            pipeline.completeStop()
            return XCTFail("真实首错必须在清理等待前保留")
        }
        XCTAssertTrue(original.userMessage.contains("NativeAudioFailure:-702"))
        await controller.failPresentationControl()
        for _ in 0..<100 { await Task.yield() }
        let duringCleanup = await controller.currentStateForTesting
        XCTAssertEqual(duringCleanup, .failed(original), "控制终态不可覆盖真实首错")
        pipeline.completeStop()
        await owner.registry.joinOwnedTerminalCleanup()
        let afterCleanup = await controller.currentStateForTesting
        XCTAssertEqual(afterCleanup, .failed(original))
    }

    func testForeignPipelineConstructionErrorsKeepTheirTypeAndReasonAfterCleanup() async throws {
        let errors: [any Error] = [
            AVPlayerItemCoordinatorFailure.prerollFailed,
            AVPlayerItemCoordinatorFailure.staleIdentity,
            NSError(domain: "PlayerSetupFailure", code: -701,
                    userInfo: [NSLocalizedDescriptionKey: "输出设备准备失败"]),
        ]
        var messages: [String] = []
        for error in errors {
            let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
            let controller = makeRoutedPlaybackController(
                factory: ErrorReportingPipelineFactory(error: error), audioSessionOwner: owner
            )
            await controller.play(makeRequest(channelID: "foreign-factory-error"))
            guard case let .failed(failure) = await controller.currentStateForTesting else {
                return XCTFail("创建失败必须呈现具体错误")
            }
            XCTAssertEqual(failure.code, "playback.backend.prepare")
            XCTAssertFalse(failure.userMessage.contains("检查地址和网络"))
            messages.append(failure.userMessage)
            await owner.registry.joinOwnedTerminalCleanup()
            XCTAssertNil(owner.registry.ownedResourceSnapshot())
            XCTAssertEqual(owner.sdk.deactivateCallCount, 1)
        }
        XCTAssertTrue(messages[0].contains("AVPlayerItemCoordinatorFailure"))
        XCTAssertTrue(messages[0].contains("prerollFailed"))
        XCTAssertTrue(messages[1].contains("staleIdentity"))
        XCTAssertTrue(messages[2].contains("PlayerSetupFailure"))
        XCTAssertTrue(messages[2].contains("-701"))
        XCTAssertTrue(messages[2].contains("输出设备准备失败"))
        XCTAssertEqual(Set(messages).count, 3)
    }

    func testColdStartReportsBothCategoryFailuresWithSystemCode() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = AudioSessionSDKSpy(
            categoryResults: [.failure, .failure], multichannelFails: false,
            executor: registry.executor,
            categoryFailure: NSError(domain: NSOSStatusErrorDomain, code: -42)
        )
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([]), audioSessionOwner: owner
        )

        await controller.play(makeRequest(channelID: "category-failure"))
        try await eventually {
            if case .failed = await controller.currentStateForTesting { return true }
            return false
        }
        guard case let .failed(failure) = await controller.currentStateForTesting else {
            return XCTFail("配置失败必须产生终态")
        }
        XCTAssertEqual(failure.code, "audio.session.category")
        XCTAssertTrue(failure.userMessage.contains("音频会话配置"))
        XCTAssertTrue(failure.userMessage.contains("系统返回码 -42"))
        XCTAssertEqual(failure.diagnosticCode, "audio.session.category.osStatus.-42")
        XCTAssertEqual(sdk.events, [.category(.longFormAudio), .category(.default)])
        await registry.joinOwnedTerminalCleanup()
    }

    func testColdStartReportsActivationFailureSeparatelyFromCategory() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: [.airPlay])
        sdk.activateError = NSError(domain: NSOSStatusErrorDomain, code: -50)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([]), audioSessionOwner: owner
        )

        await controller.play(makeRequest(channelID: "activation-failure"))
        try await eventually {
            if case .failed = await controller.currentStateForTesting { return true }
            return false
        }
        guard case let .failed(failure) = await controller.currentStateForTesting else {
            return XCTFail("激活失败必须产生终态")
        }
        XCTAssertEqual(failure.code, "audio.session.activate")
        XCTAssertTrue(failure.userMessage.contains("激活"))
        XCTAssertTrue(failure.userMessage.contains("系统返回码 -50"))
        XCTAssertEqual(failure.diagnosticCode, "audio.session.activate.osStatus.-50")
        XCTAssertEqual(sdk.lock.withLock { sdk.calls }, [
            .category(.longFormAudio), .multichannel, .activate
        ])
        await registry.joinOwnedTerminalCleanup()
    }

    func testPipelinePhaseUsesMatchingCycleAndReadyAloneEntersPlaying() async throws {
        let pipeline = FakeControllerPipeline()
        let controller = makeRoutedPlaybackController(
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
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "system-phase-fence")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually {
            await controller.currentStateForTesting == .playing(request)
        }

        await MainActor.run { _ = owner.monitor.emit(.interruptionBegan) }
        try await eventually {
            let cycle = await controller.readinessCycleForTesting
            let state = await controller.currentStateForTesting
            return cycle == 1 && state == .recovering(request)
        }
        pipeline.emit(.phase(.buffering, readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let physicallyPausedState = await controller.currentStateForTesting
        XCTAssertEqual(physicallyPausedState, .recovering(request))

        await MainActor.run { _ = owner.monitor.emit(.interruptionEnded(shouldResume: false)) }
        try await eventually {
            await controller.currentStateForTesting == .paused(request)
        }
        pipeline.emit(.phase(.recovering, readinessCycle: 1))
        pipeline.emit(.ready(readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let vetoedState = await controller.currentStateForTesting
        XCTAssertEqual(vetoedState, .paused(request))
    }

    func testLifecycleEventStreamBoundsBacklogToTheNewestState() async {
        let pipelines = (0..<10).map { _ in FakeControllerPipeline() }
        let controller = makeRoutedPlaybackController(
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
        let latest = await iterator.next()
        XCTAssertEqual(latest, .preparing(requests[9]), "慢订阅只保存最后一个状态，不积压旧session")
        await controller.stop()
    }

    func testSessionRelayDeliversOneSessionEventsInFIFOOrder() async throws {
        let identity = PlaybackRunIdentity(sessionID: 7, requestID: UUID())
        let recorder = PlaybackRunEventRecorder(currentIdentity: identity)
        let relay = PlaybackSessionEventRelay(identity: identity) { identity, event in
            await recorder.receive(identity: identity, event: event)
        }

        try bindOwnedRelayForTesting(.pipeline(relay), identity: identity)
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

        try bindOwnedRelayForTesting(.pipeline(relay), identity: identity)
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

        try bindOwnedRelayForTesting(.pipeline(relay), identity: oldIdentity)
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
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let relay = PlaybackAudioSessionEventRelay(identity: identity, lease: lease) {
            identity, lease, event, _ in
            await recorder.receive(identity: identity, lease: lease, event: event.event)
        }

        try bindOwnedRelayForTesting(.audio(relay), identity: identity)
        relay.send(lease: lease, event: try XCTUnwrap(monitor.emit(.explicitResumeSucceeded)))
        try await eventually { gate.waiterCount == 1 }
        relay.send(lease: lease, event: try XCTUnwrap(monitor.emit(.interruptionBegan)))
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
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let relay = PlaybackAudioSessionEventRelay(identity: identity, lease: lease) {
            identity, lease, event, _ in
            await recorder.receive(identity: identity, lease: lease, event: event.event)
        }

        try bindOwnedRelayForTesting(.audio(relay), identity: identity)
        relay.send(lease: lease, event: try XCTUnwrap(monitor.emit(.explicitResumeSucceeded)))
        try await eventually { gate.waiterCount == 1 }
        relay.send(lease: lease, event: try XCTUnwrap(monitor.emit(.interruptionBegan)))
        relay.deactivate()
        relay.send(lease: lease, event: try XCTUnwrap(monitor.emit(.mediaServicesWereReset)))
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
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let firstRequest = makeRequest(channelID: "first")
        let secondRequest = makeRequest(channelID: "second")
        let firstPlay = Task { await controller.play(firstRequest) }
        try await eventually { factory.isPending(callID: 1) }
        let secondPlay = Task { await controller.play(secondRequest) }
        try await eventually { await controller.currentStateForTesting == .preparing(secondRequest) }
        XCTAssertFalse(factory.isPending(callID: 2), "原prepare尚未收敛不得创建新输出")
        factory.succeed(callID: 1, with: firstPipeline)
        await firstPlay.value
        try await eventually { factory.isPending(callID: 2) }
        factory.succeed(callID: 2, with: secondPipeline)
        await secondPlay.value
        XCTAssertEqual(secondPipeline.snapshot().starts, [secondRequest.streamURL])
        XCTAssertTrue(firstPipeline.snapshot().starts.isEmpty)
        XCTAssertEqual(firstPipeline.snapshot().completedStopCount, 1)
        secondPipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(secondRequest) }
        await controller.stop()
    }

    func testLaterPlayIgnoresEarlierFactoryFailureArrivingLast() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let secondPipeline = FakeControllerPipeline()
        let controller = makeRoutedPlaybackController(factory: factory)
        let firstRequest = makeRequest(channelID: "first")
        let firstPlay = Task { await controller.play(firstRequest) }
        try await eventually { factory.isPending(callID: 1) }
        let secondRequest = makeRequest(channelID: "second")
        let secondPlay = Task { await controller.play(secondRequest) }
        try await eventually { await controller.currentStateForTesting == .preparing(secondRequest) }
        XCTAssertFalse(factory.isPending(callID: 2))
        factory.fail(callID: 1, with: .demuxOpen(-71))
        await firstPlay.value
        try await eventually { factory.isPending(callID: 2) }
        factory.succeed(callID: 2, with: secondPipeline)
        await secondPlay.value
        secondPipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(secondRequest) }
        await controller.stop()
    }

    func testStopWinsWhenSuspendedFactorySuccessArrivesLast() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "first")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        let stop = Task { await controller.stop() }
        try await eventually { owner.registry.outputResourceContextSnapshot()?.disposition == .releaseAfterTeardown }
        factory.succeed(callID: 1, with: pipeline)
        await play.value
        await stop.value
        XCTAssertTrue(pipeline.snapshot().starts.isEmpty)
        XCTAssertEqual(pipeline.snapshot().completedStopCount, 1)
        XCTAssertNil(owner.registry.outputResourceContextSnapshot())
        XCTAssertNil(owner.registry.cleanupReservationSnapshot())
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .stopped)
    }

    func testRecoveryFailureTeardownBlocksReplacementFactoryAndStart() async throws {
        let first = FakeControllerPipeline()
        first.stopAutomaticallyCompletes = false
        let second = FakeControllerPipeline()
        let factory = FakeControllerPipelineFactory([first, second])
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        await controller.play(makeRequest(channelID: "first"))

        await MainActor.run {
            _ = owner.monitor.emit(.recoveryFailed(stage: .mediaServicesResetActivation))
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

    func testPendingPrepareInterruptionRetiresOriginalBeforeResumingSuccessor() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let first = FakeControllerPipeline()
        let successor = FakeControllerPipeline()
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "pending-prepare")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        _ = owner.monitor.emit(.interruptionBegan)
        try await eventually { await controller.currentStateForTesting == .recovering(request) }
        factory.succeed(callID: 1, with: first)
        await play.value
        try await eventually { first.snapshot().completedStopCount == 1 }
        XCTAssertTrue(first.snapshot().starts.isEmpty)
        XCTAssertFalse(factory.isPending(callID: 2))
        XCTAssertEqual(owner.sdk.activateCallCount, 1)
        _ = owner.monitor.emit(.interruptionEnded(shouldResume: true))
        try await eventually { factory.isPending(callID: 2) }
        factory.succeed(callID: 2, with: successor)
        try await eventually { successor.snapshot().starts.count == 1 }
        XCTAssertEqual(successor.snapshot().startReadinessCycles, [1])
        await controller.stop()
    }

    func testPendingPrepareBeganEndedWaitsForOriginalDrainBeforeSuccessor() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let first = FakeControllerPipeline()
        let successor = FakeControllerPipeline()
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "pending-prepare")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        _ = owner.monitor.emit(.interruptionBegan)
        _ = owner.monitor.emit(.interruptionEnded(shouldResume: true))
        factory.succeed(callID: 1, with: first)
        await play.value
        try await eventually { first.snapshot().completedStopCount == 1 }
        try await eventually { factory.isPending(callID: 2) }
        factory.succeed(callID: 2, with: successor)
        try await eventually { successor.snapshot().starts.count == 1 }
        XCTAssertTrue(first.snapshot().starts.isEmpty)
        XCTAssertEqual(successor.snapshot().startReadinessCycles, [1])
        successor.emit(.ready(readinessCycle: 1))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        await controller.stop()
    }

    func testPendingPrepareTerminalFailureWaitsForLatePipelineCleanup() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let first = FakeControllerPipeline()
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "pending-prepare")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        _ = owner.monitor.emit(.recoveryFailed(stage: .mediaServicesResetConfiguration))
        try await eventually { owner.registry.outputResourceContextSnapshot()?.disposition == .releaseAfterTeardown }
        factory.succeed(callID: 1, with: first)
        await play.value
        try await eventually {
            guard case let .failed(failure) = await controller.currentStateForTesting else { return false }
            return failure.code == "audio.session.recovery.configuration" && first.snapshot().completedStopCount == 1
        }
        // 首错先于清理完成发布；资源释放须独立等待准确原 cleanup runner。
        try await eventually { owner.registry.outputResourceContextSnapshot() == nil }
        XCTAssertTrue(first.snapshot().starts.isEmpty)
        XCTAssertFalse(factory.isPending(callID: 2))
        XCTAssertNil(owner.registry.outputResourceContextSnapshot())
        await controller.stop()
        XCTAssertNil(owner.registry.cleanupReservationSnapshot(), "原terminal runner必须由外部stop准确join后退休")
    }

    func testPendingPrepareResetRebuildsOnlyAfterOriginalPipelineRetires() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let first = FakeControllerPipeline()
        let successor = FakeControllerPipeline()
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "pending-prepare")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        _ = owner.monitor.emit(.mediaServicesWereReset)
        try await eventually { await controller.currentStateForTesting == .paused(request) }
        XCTAssertEqual(owner.sdk.categoryCallCount, 1)
        factory.succeed(callID: 1, with: first)
        await play.value
        try await eventually { first.snapshot().completedStopCount == 1 }
        try await resumeResetAfterReconfiguration(controller, owner: owner)
        try await eventually { factory.isPending(callID: 2) }
        factory.succeed(callID: 2, with: successor)
        try await eventually { successor.snapshot().starts.count == 1 }
        XCTAssertTrue(first.snapshot().starts.isEmpty)
        XCTAssertEqual(owner.sdk.categoryCallCount, 2)
        XCTAssertEqual(owner.sdk.activateCallCount, 2)
        XCTAssertEqual(successor.snapshot().startReadinessCycles, [1])
        first.emit(.ready(readinessCycle: 0))
        successor.emit(.ready(readinessCycle: 1))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        await controller.stop()
    }

    func testFactoryPendingUserPauseStartsPausedAtCurrentReadinessCycle() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let pipeline = FakeControllerPipeline()
        let controller = makeRoutedPlaybackController(factory: factory)
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

    func testPendingPrepareVetoResetRetiresOriginalAndKeepsSystemPause() async throws {
        let factory = SuspendedControllerPipelineFactory()
        let first = FakeControllerPipeline()
        let successor = FakeControllerPipeline()
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "pending-prepare")
        let play = Task { await controller.play(request) }
        try await eventually { factory.isPending(callID: 1) }
        _ = owner.monitor.emit(.interruptionBegan)
        _ = owner.monitor.emit(.interruptionEnded(shouldResume: false))
        _ = owner.monitor.emit(.mediaServicesWereReset)
        factory.succeed(callID: 1, with: first)
        await play.value
        try await eventually { first.snapshot().completedStopCount == 1 }
        try await eventually { owner.sdk.categoryCallCount == 2 }
        XCTAssertTrue(first.snapshot().starts.isEmpty)
        XCTAssertTrue(successor.snapshot().starts.isEmpty)
        XCTAssertFalse(factory.isPending(callID: 2))
        XCTAssertEqual(owner.sdk.activateCallCount, 1)
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .paused(request))
        await controller.stop()
    }

    func testFailureRetainsMetricsUntilNextPlayBegins() async throws {
        let terminalMetrics = PlaybackMetrics(
            channelID: "terminal",
            now: { 10 },
            residentMemoryProvider: { 101 }
        )
        let firstPipeline = FakeControllerPipeline(metrics: terminalMetrics)
        let secondPipeline = FakeControllerPipeline()
        let controller = makeRoutedPlaybackController(
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
        let controller = makeRoutedPlaybackController(
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

    func testSuspendedStopClearsOnlyItsOriginalTerminalMetrics() async throws {
        for replaceSession in [false, true] {
            let firstMetrics = PlaybackMetrics(channelID: "first", now: { 10 },
                residentMemoryProvider: { 211 })
            let replacementMetrics = PlaybackMetrics(channelID: "replacement", now: { 10 },
                residentMemoryProvider: { 422 })
            let first = FakeControllerPipeline(metrics: firstMetrics)
            let replacement = FakeControllerPipeline(metrics: replacementMetrics)
            let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
            let controller = makeRoutedPlaybackController(
                factory: FakeControllerPipelineFactory([first, replacement]), audioSessionOwner: owner)
            let firstRequest = makeRequest(channelID: "metrics-original")
            await controller.play(firstRequest)
            let gate = ManualControllerAsyncGate()
            defer { gate.open() }
            await controller.setRequestScopedControlCheckpointForTesting { checkpoint in
                if checkpoint == .stopAfterWatchdog { await gate.wait() }
            }
            let stop = Task { await controller.stop(requestID: firstRequest.id) }
            try await eventually { gate.waiterCount == 1 }
            if replaceSession { await controller.play(makeRequest(channelID: "metrics-replacement")) }
            (replaceSession ? replacement : first).emit(.failed(.demuxRead(-74)))
            try await eventually {
                if case .failed = await controller.currentStateForTesting {
                    return owner.registry.cleanupReservationSnapshot() == nil
                }
                return false
            }
            let retained = await controller.playbackMetricsSnapshot(window: .seconds(60))
            XCTAssertEqual(retained?.residentMemoryBytes, replaceSession ? 422 : 211)
            gate.open()
            await stop.value
            let afterStop = await controller.playbackMetricsSnapshot(window: .seconds(60))
            if replaceSession {
                XCTAssertEqual(afterStop?.residentMemoryBytes, 422,
                    "An obsolete Stop cannot clear a replacement's terminal collector")
            } else {
                XCTAssertNil(afterStop, "Stop must clear the original collector after failure wins its suspension")
            }
            await controller.stop()
            let finalMetrics = await controller.playbackMetricsSnapshot(window: .seconds(60))
            XCTAssertNil(finalMetrics)
        }
    }

    func testChannelReplacementReleasesRetiredAudioLeaseBeforeSuccessorAcquisition() async throws {
        let f = ControllerRecoveryFixture(channelID: "first", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        let lease = try XCTUnwrap(f.owner.acquiredLeases.first)
        let reservation = try XCTUnwrap(f.owner.registry.cleanupReservationSnapshot())
        f.first.stopAutomaticallyCompletes = false
        let deactivateEntered = expectation(description: "原lease真实deactivate")
        let deactivateGate = DispatchSemaphore(value: 0)
        f.owner.sdk.lock.withLock {
            f.owner.sdk.onDeactivate = { deactivateEntered.fulfill(); deactivateGate.wait() }
        }
        let replacementRequest = makeRequest(channelID: "replacement")
        let replacement = Task { await f.controller.play(replacementRequest) }
        try await eventually { f.first.snapshot().isStopWaiting }
        XCTAssertEqual(f.factory.makeCountSnapshot, 1)
        XCTAssertEqual(f.owner.sdk.deactivateCallCount, 0)
        XCTAssertEqual(f.owner.events, [.acquire(lease)])
        f.first.completeStop()
        await fulfillment(of: [deactivateEntered], timeout: 1)
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 1)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 1)
        deactivateGate.signal()
        await replacement.value
        let successorLease = try XCTUnwrap(f.owner.acquiredLeases.last)
        XCTAssertNotEqual(successorLease, lease)
        XCTAssertEqual(f.owner.events, [.acquire(lease), .acquire(successorLease)])
        XCTAssertEqual(f.owner.predecessorRegistrationReleasedAtAcquisition, [true, true],
            "后继acquisition入口之前原lease登记必须已被Authority释放")
        XCTAssertEqual(f.owner.sdk.lock.withLock {
            f.owner.sdk.calls.filter { $0 == .activate || $0 == .deactivate }
        }, [.activate, .deactivate, .activate])
        XCTAssertNil(f.owner.registry.phase(of: reservation.task(for: .owner)))
        XCTAssertEqual(f.successor.snapshot().starts.count, 1)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        f.owner.sdk.lock.withLock { f.owner.sdk.onDeactivate = nil }
        await f.controller.stop()
    }

    func testOldAudioLeaseEventCannotMutateReplacementRun() async throws {
        let first = FakeControllerPipeline()
        let successor = FakeControllerPipeline()
        let owner = RecordingPlaybackAudioSessionOwner()
        let controller = makeRoutedPlaybackController(factory: FakeControllerPipelineFactory([first, successor]), audioSessionOwner: owner)
        await controller.play(makeRequest(channelID: "first"))
        let oldRelay = try XCTUnwrap(owner.registry.executor.safetyIngress.currentOwnedAudioEventRelay())
        let oldLease = try XCTUnwrap(owner.acquiredLeases.first)
        let replacement = makeRequest(channelID: "replacement")
        await controller.play(replacement)
        successor.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(replacement) }
        oldRelay.send(lease: oldLease, event: .init(
            event: .recoveryFailed(stage: .interruptionReactivation), systemReceipt: nil))
        for _ in 0..<100 { await Task.yield() }
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .playing(replacement))
        XCTAssertEqual(successor.snapshot().stopCount, 0)
        await controller.stop()
    }

    func testOwnerResumeAndResetEventsDoNotResumeUserPausedPlayback() async throws {
        let f = ControllerRecoveryFixture(channelID: "paused", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        await f.controller.setPaused(true)
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: true))
        _ = f.owner.monitor.emit(.mediaServicesWereReset)
        try await eventually { f.owner.sdk.categoryCallCount == 2 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertTrue(f.successor.snapshot().starts.isEmpty)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 1)
        XCTAssertEqual(f.successor.playbackRate, 0)
        f.successor.emit(.ready(readinessCycle: 2))
        for _ in 0..<100 { await Task.yield() }
        let state = await f.controller.currentStateForTesting
        XCTAssertEqual(state, .paused(f.request))
        await f.controller.setPaused(false)
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        let cycle = await f.controller.readinessCycleForTesting
        f.successor.emit(.ready(readinessCycle: cycle))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testPlayingMediaServicesResetWaitsForUserResumeAndMatchingReadyReturnsToPlaying() async throws {
        let f = ControllerRecoveryFixture(channelID: "reset-recovery", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        _ = f.owner.monitor.emit(.mediaServicesWereReset)
        try await resumeResetAfterReconfiguration(f.controller, owner: f.owner)
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 2)
        XCTAssertEqual(f.owner.sdk.categoryCallCount, 2)
        f.first.emit(.ready(readinessCycle: 0))
        f.successor.emit(.ready(readinessCycle: 0))
        for _ in 0..<100 { await Task.yield() }
        let waiting = await f.controller.currentStateForTesting
        XCTAssertEqual(waiting, .preparing(f.request))
        f.successor.emit(.ready(readinessCycle: 1))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testMediaResetAfterInterruptionRecoversThenReleasesSystemPauseOnSameCycle() async throws {
        let f = ControllerRecoveryFixture(channelID: "interruption-reset", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.mediaServicesWereReset)
        try await eventually { f.owner.sdk.categoryCallCount == 2 }
        XCTAssertEqual(f.owner.sdk.activateCallCount, 1, "reset不能越过真实began")
        XCTAssertTrue(f.successor.snapshot().starts.isEmpty)
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: true))
        try await resumeResetAfterReconfiguration(f.controller, owner: f.owner)
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        XCTAssertEqual(f.successor.snapshot().startReadinessCycles, [2])
        f.successor.emit(.ready(readinessCycle: 2))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testNonResumableInterruptionResetConfiguresWithoutReleasingSystemPause() async throws {
        let f = ControllerRecoveryFixture(channelID: "installed-resume-veto", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        _ = f.owner.monitor.emit(.mediaServicesWereReset)
        try await eventually { f.owner.sdk.categoryCallCount == 2 }
        XCTAssertEqual(f.owner.sdk.activateCallCount, 1)
        XCTAssertTrue(f.successor.snapshot().starts.isEmpty)
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        let state = await f.controller.currentStateForTesting
        XCTAssertEqual(state, .paused(f.request))
        await f.controller.stop()
    }

    func testExplicitResumeAfterVetoActivatesCurrentLeaseBeforeResuming() async throws {
        let f = ControllerRecoveryFixture(channelID: "explicit-resume", owner: RecordingPlaybackAudioSessionOwner(deferFirstExplicitResume: true))
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        XCTAssertNotNil(f.owner.registry.registeredOutputDrainProof())
        await f.controller.setPaused(false)
        try await eventually { f.owner.sdk.activateCallCount == 2 }
        XCTAssertEqual(f.factory.makeCountSnapshot, 1, "真实SDK返回前不得创建后继")
        XCTAssertNil(f.owner.registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        f.owner.completeDeferredExplicitResume()
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        let lease = try XCTUnwrap(f.owner.acquiredLeases.first)
        XCTAssertEqual(f.owner.events.filter { $0 == .requestResume(lease) }.count, 1)
        f.successor.emit(.ready(readinessCycle: 1))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testExplicitResumeActivationFailureUsesTerminalRecoveryFailurePath()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run {
            RecordingPlaybackAudioSessionOwner(explicitResumeFails: true)
        }
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        let request = makeRequest(channelID: "explicit-resume-failure")
        await controller.play(request)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run { _ = owner.monitor.emit(.interruptionBegan) }
        try await eventually { await controller.readinessCycleForTesting == 1 }
        await MainActor.run { _ = owner.monitor.emit(.interruptionEnded(shouldResume: false)) }
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
            return failure.code == "audio.session.recovery.reactivation"
                && pipeline.snapshot().completedStopCount == 1
        }
        guard case let .failed(failure) = await controller.currentStateForTesting else {
            return XCTFail("中断后激活失败必须产生终态")
        }
        XCTAssertTrue(failure.userMessage.contains("音频中断结束后"))
        XCTAssertTrue(failure.userMessage.contains("系统返回码 -1"))
        let events = await MainActor.run { owner.events }
        XCTAssertEqual(events.filter { $0 == .requestResume(lease) }.count, 1)
        await owner.registry.joinOwnedTerminalCleanup()
        XCTAssertNil(owner.registry.ownedResourceSnapshot())
        XCTAssertNil(owner.registry.cleanupReservationSnapshot())
        XCTAssertNil(owner.registration(for: try XCTUnwrap(owner.acquisitions.first)))
        XCTAssertEqual(owner.sdk.deactivateCallCount, 0,
            "interruption drain与真实activation失败均证明inactive，不能伪造额外deactivate责任")
        XCTAssertEqual(owner.sdk.activateCallCount, 2)
    }

    func testRepeatedExplicitResumeWhileFirstRequestIsPendingActivatesOnlyOnce() async throws {
        let f = ControllerRecoveryFixture(channelID: "deduplicated-explicit-resume", owner: RecordingPlaybackAudioSessionOwner(deferFirstExplicitResume: true, failAdditionalExplicitResume: true))
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        await f.controller.setPaused(false)
        try await eventually { f.owner.sdk.activateCallCount == 2 }
        await f.controller.setPaused(false)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 2)
        XCTAssertEqual(f.factory.makeCountSnapshot, 1)
        let lease = try XCTUnwrap(f.owner.acquiredLeases.first)
        XCTAssertEqual(f.owner.events.filter { $0 == .requestResume(lease) }.count, 1)
        f.owner.completeDeferredExplicitResume()
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 2)
        f.successor.emit(.ready(readinessCycle: 1))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testExplicitResumeSuccessThenNewInterruptionEndsSystemPausedInSourceOrder() async throws {
        let f = ControllerRecoveryFixture(channelID: "resume-then-interrupt", owner: RecordingPlaybackAudioSessionOwner(deferFirstExplicitResume: true))
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        await f.controller.setPaused(false)
        try await eventually { f.owner.sdk.activateCallCount == 2 }
        f.owner.completeDeferredExplicitResume()
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        // 先观察真实completion已消费并建立后继，再注入新的物理began。
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.successor.snapshot().completedStopCount == 1 }
        f.successor.emit(.ready(readinessCycle: 1))
        for _ in 0..<100 { await Task.yield() }
        let state = await f.controller.currentStateForTesting
        XCTAssertEqual(state, .recovering(f.request))
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        await f.controller.stop()
    }

    func testExplicitResumeDuringNewPhysicalInterruptionDoesNotRequestOwner() async throws {
        let f = ControllerRecoveryFixture(channelID: "resume-during-new-interruption", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { await f.controller.readinessCycleForTesting == 2 }
        await f.controller.setPaused(false)
        let lease = try XCTUnwrap(f.owner.acquiredLeases.first)
        XCTAssertEqual(f.owner.events.filter { $0 == .requestResume(lease) }.count, 0)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 1)
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        await f.controller.setPaused(false)
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        XCTAssertEqual(f.owner.events.filter { $0 == .requestResume(lease) }.count, 1)
        f.successor.emit(.ready(readinessCycle: 2))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testInterruptionEndedWithoutResumeAllowsNextInterruptionToCompleteRecovery() async throws {
        let f = ControllerRecoveryFixture(channelID: "repeated-interruption", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { await f.controller.readinessCycleForTesting == 2 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: true))
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 2)
        f.successor.emit(.ready(readinessCycle: 2))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testUserResumeDuringInterruptionKeepsSystemPauseUntilOwnerEndsIt() async throws {
        let f = ControllerRecoveryFixture(channelID: "user-resume-during-interruption", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        await f.controller.setPaused(true)
        await f.controller.setPaused(false)
        XCTAssertEqual(f.owner.sdk.activateCallCount, 1)
        XCTAssertTrue(f.successor.snapshot().starts.isEmpty)
        let interrupted = await f.controller.currentStateForTesting
        XCTAssertEqual(interrupted, .recovering(f.request))
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: true))
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.first.snapshot().completedStopCount, 1)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        XCTAssertEqual(f.outputConcurrency.maximum, 1)
        XCTAssertEqual(f.successor.snapshot().startReadinessCycles, [3])
        f.successor.emit(.ready(readinessCycle: 3))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    func testCurrentAudioSessionRecoveryFailureStopsOnceReleasesLeaseAndIsRetryable()
        async throws {
        let pipeline = FakeControllerPipeline()
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([pipeline]),
            audioSessionOwner: owner
        )
        await controller.play(makeRequest(channelID: "activation-failure"))
        let lease = try await MainActor.run { try XCTUnwrap(owner.acquiredLeases.last) }

        await MainActor.run {
            _ = owner.monitor.emit(.recoveryFailed(stage: .interruptionReactivation))
            owner.emitEvenIfReleased(
                .recoveryFailed(stage: .mediaServicesResetActivation),
                for: lease
            )
        }

        try await eventually {
            guard case let .failed(failure) = await controller.currentStateForTesting else {
                return false
            }
            return failure.code == "audio.session.recovery.reactivation"
                && pipeline.snapshot().completedStopCount == 1
        }
        await owner.registry.joinOwnedTerminalCleanup()
        XCTAssertNil(owner.registry.ownedResourceSnapshot())
        XCTAssertNil(owner.registry.cleanupReservationSnapshot())
        XCTAssertNil(owner.registration(for: try XCTUnwrap(owner.acquisitions.first)))
        XCTAssertEqual(owner.sdk.deactivateCallCount, 1)
        XCTAssertEqual(pipeline.snapshot().stopCount, 1)
    }

    func testInterruptedAcquisitionWaitsForPhysicalEndBeforeFactoryAndOutput() async throws {
        let pipeline = FakeControllerPipeline()
        let factory = FakeControllerPipelineFactory([pipeline])
        let owner = RecordingPlaybackAudioSessionOwner()
        _ = owner.monitor.emit(.interruptionBegan)
        let controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        let request = makeRequest(channelID: "interrupted-acquisition")
        let play = Task { await controller.play(request) }
        try await eventually { owner.registry.outputResourceContextSnapshot() != nil }
        XCTAssertEqual(owner.sdk.activateCallCount, 0)
        XCTAssertEqual(factory.makeCountSnapshot, 0)
        _ = owner.monitor.emit(.interruptionEnded(shouldResume: true))
        await play.value
        try await eventually { pipeline.snapshot().starts.count == 1 }
        XCTAssertEqual(owner.sdk.activateCallCount, 1)
        pipeline.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        await controller.stop()
    }

    func testPipelineFactoryFailureReleasesTheAcquiredAudioLease() async {
        let owner = await MainActor.run { RecordingPlaybackAudioSessionOwner() }
        let controller = makeRoutedPlaybackController(
            factory: FakeControllerPipelineFactory([]),
            audioSessionOwner: owner
        )

        await controller.play(makeRequest(channelID: "factory-failure"))

        let result = await MainActor.run { (owner.acquiredLeases, owner.events) }
        guard let lease = result.0.first else {
            return XCTFail("创建 pipeline 前必须先取得音频会话 lease")
        }
        XCTAssertEqual(result.1, [.acquire(lease)])
        await owner.registry.joinOwnedTerminalCleanup()
        XCTAssertNil(owner.registry.ownedResourceSnapshot())
        XCTAssertNil(owner.registry.cleanupReservationSnapshot())
        XCTAssertEqual(owner.sdk.deactivateCallCount, 1)
        XCTAssertTrue(owner.acquisitions.allSatisfy { owner.registration(for: $0) == nil })
    }

    func testExplicitResumeAfterVetoAndResetRequiresOriginalResetProof() async throws {
        let f = ControllerRecoveryFixture(channelID: "veto-reset-resume", owner: RecordingPlaybackAudioSessionOwner())
        try await start(f)
        _ = f.owner.monitor.emit(.interruptionBegan)
        try await eventually { f.first.snapshot().completedStopCount == 1 }
        _ = f.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        try await eventually {
            let interrupted = await f.controller.audioSessionInterruptedForTesting
            let state = await f.controller.currentStateForTesting
            return !interrupted && state == .paused(f.request)
        }
        _ = f.owner.monitor.emit(.mediaServicesWereReset)
        try await eventually { f.owner.sdk.categoryCallCount == 2 }
        XCTAssertEqual(f.owner.sdk.activateCallCount, 1)
        await f.controller.setPaused(false)
        try await eventually { f.successor.snapshot().starts.count == 1 }
        XCTAssertEqual(f.owner.sdk.activateCallCount, 2)
        XCTAssertEqual(f.factory.makeCountSnapshot, 2)
        f.successor.emit(.ready(readinessCycle: 2))
        try await eventually { await f.controller.currentStateForTesting == .playing(f.request) }
        await f.controller.stop()
    }

    private func resumeResetAfterReconfiguration(_ controller: PlaybackController,
        owner: RecordingPlaybackAudioSessionOwner) async throws {
        try await eventually {
            owner.registry.outputResourceContextSnapshot()?.systemRecoveryBinding?.inactiveConfigurationReceipt != nil
        }
        XCTAssertTrue(owner.registry.executor.safetyIngress.snapshot.mediaServicesResumeRequired)
        XCTAssertNil(owner.registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        await controller.setPaused(false)
    }

    private func start(_ fixture: ControllerRecoveryFixture) async throws {
        await fixture.controller.play(fixture.request)
        fixture.first.emit(.ready(readinessCycle: 0))
        try await eventually { await fixture.controller.currentStateForTesting == .playing(fixture.request) }
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
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("条件在限定调度轮次内未满足", file: file, line: line)
    }
}

private final class ControllerRecoveryFixture: @unchecked Sendable {
    let owner: RecordingPlaybackAudioSessionOwner
    let outputConcurrency = PipelineOutputConcurrency()
    let first: FakeControllerPipeline
    let successor: FakeControllerPipeline
    let factory: FakeControllerPipelineFactory
    let controller: PlaybackController
    let request: PlaybackRequest
    init(channelID: String, owner: RecordingPlaybackAudioSessionOwner) {
        self.owner = owner
        first = FakeControllerPipeline(outputConcurrency: outputConcurrency)
        successor = FakeControllerPipeline(outputConcurrency: outputConcurrency)
        factory = FakeControllerPipelineFactory([first, successor])
        controller = makeRoutedPlaybackController(factory: factory, audioSessionOwner: owner)
        request = PlaybackRequest(sourceProfileID: UUID(), channelID: channelID,
            streamURL: URL(string: "https://example.invalid/stream")!, title: channelID)
    }
}

private final class RecordingPlaybackAudioSessionOwner: PlaybackAudioSessionOwner, @unchecked Sendable {
    enum Event: Equatable {
        case acquire(PlaybackAudioSessionLease)
        case requestResume(PlaybackAudioSessionLease)
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var _acquiredLeases: [PlaybackAudioSessionLease] = []
    private var _acquisitions: [ControlTaskTicket] = []
    private var _predecessorRegistrationReleasedAtAcquisition: [Bool] = []
    let sdk: FakeAudioSessionSDK
    private let explicitResumeFails: Bool
    private let deferFirstExplicitResume: Bool
    private let failAdditionalExplicitResume: Bool
    private let resumeGate = DispatchSemaphore(value: 0)
    private var resumeRequests = 0

    var events: [Event] { lock.withLock { _events } }
    var acquiredLeases: [PlaybackAudioSessionLease] { lock.withLock { _acquiredLeases } }
    var acquisitions: [ControlTaskTicket] { lock.withLock { _acquisitions } }
    var predecessorRegistrationReleasedAtAcquisition: [Bool] {
        lock.withLock { _predecessorRegistrationReleasedAtAcquisition }
    }

    init(
        interruptedAtAcquisition: Bool = false,
        explicitResumeFails: Bool = false,
        deferFirstExplicitResume: Bool = false,
        failAdditionalExplicitResume: Bool = false
    ) {
        self.explicitResumeFails = explicitResumeFails
        self.deferFirstExplicitResume = deferFirstExplicitResume
        self.failAdditionalExplicitResume = failAdditionalExplicitResume
        let reg = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        sdk = FakeAudioSessionSDK(initialPorts: [.hdmi])
        try! super.init(registry: reg, sdk: sdk, monitor: nil)
        if interruptedAtAcquisition { monitor.emit(.interruptionBegan) }
    }

    override func startAcquisition(_ ticket: ControlTaskTicket, receiver: any PlaybackAudioSessionCompletionReceiving) throws -> Bool {
        let previous = lock.withLock { _acquisitions.last }
        let previousReleased = previous.map { registration(for: $0) == nil } ?? true
        let started = try super.startAcquisition(ticket, receiver: receiver)
        // 只记录真实登记结果，不能预测lease序号或伪造acquisition成功。
        if let registration = registration(for: ticket) {
            let id = registration.identity.leaseID
            let lease = PlaybackAudioSessionLease(id: id, generation: id,
                isInterruptedAtAcquisition: registry.executor.safetyIngress.snapshot.interruptionState == .began)
            lock.withLock {
                _acquiredLeases.append(lease)
                _acquisitions.append(ticket)
                _predecessorRegistrationReleasedAtAcquisition.append(previousReleased)
                _events.append(.acquire(lease))
            }
        }
        return started
    }

    @discardableResult
    override func requestResume(for lease: PlaybackAudioSessionLease,
        expectedEpoch: AudioSessionLifecycleEpoch? = nil) -> Bool {
        let count = lock.withLock { () -> Int in
            resumeRequests += 1
            _events.append(.requestResume(lease))
            return resumeRequests
        }
        let gate = resumeGate
        sdk.lock.withLock {
            sdk.shouldFailActivate = explicitResumeFails || (failAdditionalExplicitResume && count > 1)
            if deferFirstExplicitResume && count == 1 { sdk.onActivate = { gate.wait() } }
            else { sdk.onActivate = nil }
        }
        // 准入、原proof与真实SDK completion全部由基类/Registry完成。
        return super.requestResume(for: lease, expectedEpoch: expectedEpoch)
    }

    func completeDeferredExplicitResume() { resumeGate.signal() }

    func emitEvenIfReleased(_ event: PlaybackAudioSessionEvent, for lease: PlaybackAudioSessionLease) {
        // 此接缝只用于当前lease重复终态；跨lease尾部测试直接保留原relay。
        guard acquiredLeases.last == lease else { return }
        monitor.emit(event)
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
        case .explicitResumeSucceeded, .resetConfigurationSucceeded:
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
