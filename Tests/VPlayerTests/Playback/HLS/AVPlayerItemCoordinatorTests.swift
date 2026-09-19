// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreVideo
import Darwin
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

@MainActor
final class AVPlayerItemCoordinatorTests: XCTestCase {
    func testSDKFixedStopStorageAndGapRejection() async throws {
        XCTAssertLessThanOrEqual(malloc_good_size(class_getInstanceSize(OutputPlayerStopTask.self)), 96,
                                "固定错误不能保留任意 Error 图")
        let harness = try await Task21Harness()
        harness.driver.returnGappedLoadedRangeFragments = true
        await XCTAssertThrowsErrorAsync(try await harness.prepare())
    }

    func testSDKFixedDirectStateCompileContract() async throws {
        func read(_ driver: any AVPlayerDriving, _ item: AVPlayerItemInstanceIdentity)
            async throws(AVPlayerItemCoordinatorFailure) -> AVPlayerDirectState {
            try await driver.directState(item: item)
        }
        let harness = try await Task21Harness()
        let state = try await read(harness.driver, harness.item)
        XCTAssertEqual(state.item, harness.item)
    }

    func testSDKFixedRangeKernelBoundariesAndExactUnion() {
        func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
            CMTimeRange(start: CMTime(value: start, timescale: 1),
                        duration: CMTime(value: duration, timescale: 1))
        }
        func check(_ ranges: [CMTimeRange], _ requested: CMTimeRange, _ code: UInt32,
                   file: StaticString = #filePath, line: UInt = #line) {
            let result = ranges.withUnsafeBufferPointer {
                VPScanLoadedRangeBuffer($0.baseAddress, $0.count, requested)
            }
            XCTAssertEqual(result.code, code, file: file, line: line)
            XCTAssertEqual(result.count, UInt32(ranges.count), file: file, line: line)
        }
        // 0=覆盖，1=未覆盖，2=容量，3=非法时间。这里只测试同步扫描内核。
        check([], range(0, 3), 1)
        check([range(0, 3)], range(0, 3), 0)
        check(Array(repeating: range(0, 3), count: 128), range(0, 3), 0)
        check(Array(repeating: range(0, 3), count: 129), range(0, 3), 2)
        check([range(2, 1), range(0, 1), range(1, 1)], range(0, 3), 0)
        check([range(1, 2), range(0, 2), range(1, 2)], range(0, 3), 0)
        check([range(0, 1), range(2, 1)], range(0, 3), 1)
        check([range(0, 3)], range(1, 1), 0)
        check([range(0, 3)], range(3, 1), 1)
        check([range(1, 3)], range(0, 3), 1)
        check([range(0, 3), .invalid], range(0, 3), 3)
        check([range(-1, 4)], range(0, 3), 3)
        check([range(0, 0)], range(0, 3), 3)
        check([CMTimeRange(start: .indefinite, duration: CMTime(value: 3, timescale: 1))], range(0, 3), 3)
        check([CMTimeRange(start: CMTime(value: 0, timescale: 1, flags: .valid, epoch: 1),
                           duration: CMTime(value: 3, timescale: 1))], range(0, 3), 3)
        check([range(0, 3)], .invalid, 3)
        check([range(Int64.max, 1)], range(0, 3), 3)
    }

    func testSDKFixedReceiptRejectsIdentityAndRequestMutation() async throws {
        for mutation in 1...8 {
            let harness = try await Task21Harness()
            harness.driver.loadedReceiptMutation = mutation
            await XCTAssertThrowsErrorAsync(try await harness.prepare(), "固定覆盖身份变异 \(mutation)")
        }
    }

    func testSDKFixedSystemLoopbackLoadedReceiptAndItemFailure() async throws {
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        let fixture = try await Task21HarnessAuthorityFixture.make(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 24_101), audioOnly: false)
        defer { fixture.shutdown() }
        let playhead = try await fixture.makePreparedPlayhead()
        let item = fixture.request.item
        try driver.install(url: fixture.request.itemURL, identity: item)
        defer { driver.replaceCurrentItemWithNil(item: item) }
        let requested = try FMP4PresentationRange(start: playhead.playerItemTime,
            duration: ExactMediaTime(value: 1, timescale: 100))
        let loaded = try await driver.waitForLoadedTimeRanges(item: item, playhead: playhead, covering: requested)
        XCTAssertEqual(loaded, .init(item: item, playhead: playhead, requested: requested))
        XCTAssertEqual(driver.activeWaiterCount, 0)
        let attachment = XCTAttachment(string:
            "systemDriverIdentity=\(ObjectIdentifier(driver)), systemDriverMalloc=\(malloc_size(Unmanaged.passUnretained(driver).toOpaque())), "
            + "waitSlotIdentity=\(ObjectIdentifier(driver.prepareWait)), waitSlotMalloc=\(malloc_size(Unmanaged.passUnretained(driver.prepareWait).toOpaque())), "
            + "receiptStride=\(MemoryLayout<AVPlayerLoadedRangeReceipt>.stride), cResultStride=\(MemoryLayout<VPLoadedRangeCoverage>.stride)")
        attachment.lifetime = .keepAlways
        add(attachment)
        driver.replaceCurrentItemWithNil(item: item)
        try driver.install(url: URL(fileURLWithPath: "/tmp/VPlayer-task21-sdk-fixed-nonexistent.m3u8"), identity: item)
        do { _ = try await driver.waitUntilReady(item: item); XCTFail("无效媒体必须报告固定失败") }
        catch { XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .itemFailed) }
    }

    func testSDKFixedStopReplaysExactFailureAndMeasuresObjects() async throws {
        for failure in [AVPlayerItemCoordinatorFailure.staleIdentity, .directPauseNotConfirmed, .itemFailed] {
            let harness = try await Task21Harness()
            _ = try await harness.prepare()
            _ = try await harness.activate()
            harness.driver.directFailure = failure
            _ = try? await harness.stop()
            let invocation = try XCTUnwrap(harness.backend.lastSuspendInvocation)
            let reads = harness.driver.directStateCallCount
            harness.driver.directFailure = nil
            for _ in 0..<2 {
                do { _ = try await harness.coordinator.stop(invocation); XCTFail("必须重放原失败") }
                catch { XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, failure) }
            }
            XCTAssertEqual(harness.driver.directStateCallCount, reads)
            let task = OutputPlayerStopTask(item: harness.item,
                registryIssuerIdentity: invocation.registryIssuerIdentity,
                suspendTicket: invocation.suspendTicket, closeClaim: invocation.closeClaim)
            task.complete(.failure(failure))
            task.complete(.failure(.capacityExceeded))
            do {
                _ = try await task.value(registryIssuerIdentity: invocation.registryIssuerIdentity,
                    suspendTicket: invocation.suspendTicket, closeClaim: invocation.closeClaim)
                XCTFail("单次终态不得被第二次完成覆盖")
            } catch { XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, failure) }
            do {
                _ = try await task.value(registryIssuerIdentity: invocation.registryIssuerIdentity + 1,
                    suspendTicket: invocation.suspendTicket, closeClaim: invocation.closeClaim)
                XCTFail("外来 issuer 不得读取终态")
            } catch { XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .operationInFlight) }
            let attachment = XCTAttachment(string:
                "stopIdentity=\(ObjectIdentifier(task)), stopMalloc=\(malloc_size(Unmanaged.passUnretained(task).toOpaque())), "
                + "driverIdentity=\(ObjectIdentifier(harness.driver)), driverMalloc=\(malloc_size(Unmanaged.passUnretained(harness.driver).toOpaque())), "
                + "fixedFailureStride=\(MemoryLayout<AVPlayerItemCoordinatorFailure>.stride), "
                + "cResultStride=\(MemoryLayout<VPLoadedRangeCoverage>.stride), "
                + "receiptStride=\(MemoryLayout<AVPlayerLoadedRangeReceipt>.stride), "
                + "errorReservation=\(ControlTaskRegistry.ownedControlAllocationReservation.fixedErrorReservation)")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// 仅测候选字段的真实布局，不把候选存储等同于已接入生产的容量证明。
    func testFrozenEvidenceCandidateStorageLayout() {
        struct Handle { let generation: UInt64; let index: UInt16 }
        struct Bitmap { var words: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) }
        struct Selection {
            let authority: Handle
            let resource: Handle
            let response: UUID
            let terminal: UUID
            let nonce: UUID
        }
        struct Completion {
            let authority: Handle
            let resource: Handle
            let range: Range<Int>
            let watermark: UInt64
        }
        struct CompletedSummary {
            let authority: Handle
            let resource: Handle
            let watermark: UInt64
        }
        struct FrozenCleanup {
            let owner: FrozenControlTaskGroupTicket
            let work: FrozenControlTaskGroupTicket
            let nonce: UInt64
        }
        struct FrozenCall {
            let group: FrozenControlTaskGroupTicket
            let taskNonce: UInt64
            // owner 仅在先验证与 group.ownerTicket 相同后才可由 group 投影。
            let session: PlaybackSessionIdentity
            let lease: UInt64
            let context: UInt64
            let mediaServices: UInt64
            let phaseNonce: UInt64
        }
        enum FrozenActive {
            case receipt(ActiveSessionReceipt, AudioSessionPhaseIdentity)
            case success(FrozenCall)
        }
        enum FrozenInactive {
            // 此诊断先保留没有证明可删除的独立 proof 字段。
            case reservation(AcquisitionConfiguredLeaseOwnershipProof)
            case notInvoked(FrozenCall)
            case failure(FrozenCall, AudioSessionFixedFailure)
            case interruption(InterruptionDrainProof)
        }
        enum FrozenDisposition {
            case inactive(FrozenInactive)
            case awaiting(FrozenCall)
            case active(FrozenActive)
            case inFlight(FrozenCall)
            case reset(UInt64)
            case settled(FrozenCall, AudioSessionDeactivationResult)
        }
        struct FrozenLease {
            let leaseID: UInt64
            let object: any OwnedPlaybackResource
            let monitor: OwnedRouteMonitorResource?
            let disposition: FrozenDisposition
        }
        struct FrozenBackend {
            let identity: PlaybackBackendIdentity
            let object: any OwnedPlaybackResource
            let lifecycle: OutputLifecycleEpoch?
            let lease: FrozenLease
        }
        enum FrozenResourcePayload {
            case monitor(OwnedRouteMonitorResource)
            case lease(FrozenLease)
            case backend(FrozenBackend)
        }
        struct FrozenResource {
            let cleanup: FrozenCleanup
            let context: UInt64
            let mediaServices: UInt64
            let interruption: UInt64
            let fence: UInt64
            let payload: FrozenResourcePayload
        }
        struct FrozenDeactivation {
            let cleanup: FrozenCleanup
            let context: UInt64
            let lease: UInt64
            let source: FrozenActive
            let phase: AudioSessionPhaseIdentity
            let callNonce: UInt64
        }
        struct FrozenAudioPhase {
            // command 自身原 group 可投影 owner；独立 session 字段仍保留。
            let session: PlaybackSessionIdentity
            let lease: UInt64
            let context: UInt64
            let mediaServices: UInt64
            let phaseNonce: UInt64
        }
        enum FrozenPayload {
            case backend(OwnedPlaybackBackendOperation)
            case drain(OwnedPlaybackEventDrain)
            case cleanup(OwnedPlaybackCleanupTask)
            case audio(FrozenAudioPhase, AudioSessionPhasePolicy, OwnedAudioSessionActivationResult?)
            case deactivation(FrozenDeactivation, AudioSessionDeactivationResult?)
            case resource(FrozenResource)
            case factory(OwnedFactoryResult)
        }
        struct FrozenCommand {
            let group: FrozenControlTaskGroupTicket
            let taskNonce: UInt64
            let slot: ControlTaskSlot
            let safety: ControlCommandSafetySnapshot
            let gate: ControlGatePolicy
            let phase: ControlTaskPhase
            let invalidated: Bool
            let claimed: Bool
            let responsibility: Bool
            let payload: FrozenPayload?
        }
        func layout<T>(_ type: T.Type) -> String {
            "size=\(MemoryLayout<T>.size),stride=\(MemoryLayout<T>.stride),alignment=\(MemoryLayout<T>.alignment),optional=\(MemoryLayout<T?>.stride)"
        }
        func backing<T>(_ type: T.Type, count: Int) -> Int {
            let array = Array<T?>(repeating: nil, count: count)
            return array.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return 0 }
                return malloc_size(UnsafeRawPointer(base).advanced(by: -32))
            }
        }
        let text = """
        候选布局，不是生产图通过；未取得独立 proof 字段的删除授权或零成本假设。
        handle=\(layout(Handle.self))
        bitmap352=\(layout(Bitmap.self))
        selection=\(layout(Selection.self));backing14=\(backing(Selection.self, count: 14))
        completion=\(layout(Completion.self));backing100=\(backing(Completion.self, count: 100))
        summary=\(layout(CompletedSummary.self));backing300=\(backing(CompletedSummary.self, count: 300))
        cleanup=\(layout(FrozenCleanup.self))
        call=\(layout(FrozenCall.self))
        active=\(layout(FrozenActive.self))
        inactive=\(layout(FrozenInactive.self))
        disposition=\(layout(FrozenDisposition.self))
        resource=\(layout(FrozenResource.self))
        deactivation=\(layout(FrozenDeactivation.self))
        audio=\(layout((FrozenAudioPhase, AudioSessionPhasePolicy, OwnedAudioSessionActivationResult?).self))
        audioPolicy=\(layout(AudioSessionPhasePolicy.self))
        activationPurpose=\(layout(AudioSessionActivationPurpose.self))
        acquisitionPurpose=\(layout((PlaybackSessionIdentity, UInt64, AcquisitionConfiguredLeaseOwnershipProof).self))
        resetPurpose=\(layout((SystemRecoveryIncarnation.Identity, UInt64, InactiveAudioSessionConfigurationReceipt.Identity).self))
        reactivationPurpose=\(layout((PlaybackSessionIdentity, ConfigurationTransitionIdentity?, UInt64, AudioSessionReactivationAttemptTicket).self))
        reactivationProof=\(layout(AudioSessionReactivationProof.self))
        interruptionProof=\(layout(InterruptionDrainProof.self))
        resetPostProof=\(layout(ResetPostConfigurationProof.self))
        payload=\(layout(FrozenPayload.self))
        command=\(layout(FrozenCommand.self));backing32=\(backing(FrozenCommand.self, count: 32))
        """
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStorageTimelineRetryTransfersWakeToSuccessorWithoutParallelAttempt() {
        var retry = TimelineMappingRetryState()
        XCTAssertTrue(retry.begin()) // A 已离锁计算。
        retry.cancelPending() // A 取消，B 安装后请求唯一唤醒。
        XCTAssertFalse(retry.begin())
        XCTAssertTrue(retry.finish(hasPending: true, matchesAttempt: false, waiting: false))
        XCTAssertFalse(retry.begin()) // 已排队授权不能被新事件抢先制造第二个计算。
        XCTAssertTrue(retry.beginQueued(hasPending: true)) // 原唤醒在 A 结束后计算 B。
        XCTAssertFalse(retry.begin())
        XCTAssertTrue(retry.finish(hasPending: true, matchesAttempt: true, waiting: true))

        for iteration in 0..<2 { // B 取消与 terminal 均在同一锁内清 pending/requested。
            XCTAssertTrue(iteration == 0 ? retry.beginQueued(hasPending: true) : retry.begin())
            retry.cancelPending()
            XCTAssertFalse(retry.begin()) // A 尚未结束，B 请求不能并行运行。
            retry.cancelPending()
            XCTAssertFalse(retry.finish(hasPending: false, matchesAttempt: false, waiting: false))
        }
        XCTAssertTrue(retry.begin())
        XCTAssertFalse(retry.begin())
        XCTAssertFalse(retry.finish(hasPending: false, matchesAttempt: true, waiting: false))
        XCTAssertTrue(retry.begin())
        XCTAssertFalse(retry.finish(hasPending: true, matchesAttempt: true, waiting: true))
    }

    func testTimelineRetryKeepsSingleQueuedAuthorizationAcrossCancellationAndSuccessor() {
        for hasSuccessor in [false, true] {
            var retry = TimelineMappingRetryState()
            XCTAssertTrue(retry.begin())
            XCTAssertFalse(retry.begin())
            XCTAssertTrue(retry.finish(hasPending: true, matchesAttempt: true, waiting: true))
            for _ in 0..<256 { XCTAssertFalse(retry.begin()) }
            XCTAssertTrue(retry.isInFlight, "已排队期间历史域仍然繁忙")
            retry.cancelPending()
            XCTAssertTrue(retry.isInFlight, "取消 pending 不得丢失原 queued 授权")
            if hasSuccessor { XCTAssertFalse(retry.begin()) }
            XCTAssertEqual(retry.beginQueued(hasPending: hasSuccessor), hasSuccessor)
            if hasSuccessor {
                XCTAssertTrue(retry.isInFlight)
                XCTAssertFalse(retry.finish(hasPending: false, matchesAttempt: true, waiting: false))
            }
            XCTAssertFalse(retry.isInFlight)
            XCTAssertFalse(retry.beginQueued(hasPending: true), "原队列授权只能消费一次")
            XCTAssertTrue(retry.begin(), "无 pending 出队或后继完成后可以准确复用")
            XCTAssertFalse(retry.finish(hasPending: false, matchesAttempt: true, waiting: false))
        }
    }

    func testStorageCompleteObjectAllocationInventory() {
        func object(_ type: AnyClass) -> Int { malloc_good_size(class_getInstanceSize(type)) }
        func layout<T>(_ type: T.Type) -> String {
            "size=\(MemoryLayout<T>.size),stride=\(MemoryLayout<T>.stride),alignment=\(MemoryLayout<T>.alignment);optional=\(MemoryLayout<T?>.size)/\(MemoryLayout<T?>.stride)/\(MemoryLayout<T?>.alignment)"
        }
        let text = """
        owned=\(ControlTaskRegistry.ownedControlAllocationReservation.total)
        commandBacking=\(ControlTaskRegistry.ownedControlAllocationReservation.commandBacking)
        groupBacking=\(ControlTaskRegistry.ownedControlAllocationReservation.groupBacking)
        coordinator=\(object(AVPlayerItemCoordinator.self))
        driver=\(object(SystemAVPlayerDriver.self))
        waitSlot=\(object(AVPlayerPrepareWaitSlot.self))
        driverHub=\(object(AVPlayerDriverEventHub.self))
        evidenceSource=\(object(LoopbackAVPlayerPreparationEvidenceSource.self))
        lock=\(object(NSLock.self))
        selectionCapability=\(object(LoopbackAudioMediaSelectionCapability.self))
        timelineCapability=\(object(PlayerItemTimelineMappingAuthority.self))
        stopProjection=\(object(OutputPlayerStopTask.self))
        observer=\(object(NSKeyValueObservation.self))
        scheduler=\(object(PlaybackDeadlineScheduler.self))
        readinessStride=\(MemoryLayout<AVPlayerCompletedParticipantReadiness>.stride)
        fixedErrorReservation=\(ControlTaskRegistry.ownedControlAllocationReservation.fixedErrorReservation)
        payload=\(layout(OwnedControlCommandPayload.self))
        backendOperation=\(layout(OwnedPlaybackBackendOperation.self))
        eventDrain=\(layout(OwnedPlaybackEventDrain.self))
        controllerCleanup=\(layout(OwnedPlaybackCleanupTask.self))
        audio=\(layout((AudioSessionPhaseIdentity, AudioSessionPhasePolicy, OwnedAudioSessionActivationResult?).self))
        deactivation=\(layout((AudioSessionCleanupDeactivationRequest, AudioSessionDeactivationResult?).self))
        resource=\(layout(OutputResourceOwnership.self))
        factoryResult=\(layout(OwnedFactoryResult.self))
        cleanupReservation=\(layout(CleanupReservationTicket.self))
        deactivationRequest=\(layout(AudioSessionCleanupDeactivationRequest.self))
        cleanupRunnerObject=\(object(OwnedPlaybackCleanupTask.self))
        """
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(ControlTaskRegistry.ownedControlAllocationReservation.total, 65_536)
    }

    func testStorageDriverAdmissionRollsBackAndRetainsLeaseUntilActualRelease() async throws {
        let occupied = AVPlayer(playerItem: AVPlayerItem(url: URL(string: "http://127.0.0.1:1/occupied")!))
        XCTAssertThrowsError(try SystemAVPlayerDriver.make(player: occupied))
        var first: SystemAVPlayerDriver? = try SystemAVPlayerDriver.make()
        XCTAssertThrowsError(try SystemAVPlayerDriver.make())
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch:
            AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_298), itemGeneration: 1)
        try first?.install(url: URL(string: "http://127.0.0.1:1/admission")!, identity: item)
        first?.replaceCurrentItemWithNil(item: item)
        XCTAssertThrowsError(try SystemAVPlayerDriver.make(), "cleanup不等于旧driver对象释放")
        first = nil
        let next = try SystemAVPlayerDriver.make()
        XCTAssertNil(next.currentItemIdentity)
    }

    func testStorageConcurrentFactoryRequestsAdmitOnePhysicalDriverAndReleaseLastOwner() async throws {
        let admitted = FinalLockedValue<SystemAVPlayerDriver>()
        let start = Task21FactoryStartBarrier()
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await start.arrive()
                    return await MainActor.run {
                        do { admitted.value = try SystemAVPlayerDriver.make(); return true }
                        catch { return false }
                    }
                }
            }
            var successes = 0
            for await success in group where success { successes += 1 }
            return successes
        }
        XCTAssertEqual(results, 1)
        weak var released = admitted.value
        var finalOwner = admitted.value
        admitted.value = nil
        XCTAssertNotNil(finalOwner)
        XCTAssertNotNil(released)
        XCTAssertThrowsError(try SystemAVPlayerDriver.make())
        finalOwner = nil
        XCTAssertNil(finalOwner)
        XCTAssertNil(released, "真正最后一个强引用释放后才能归还物理driver准入")
        released = nil
        let successor = try SystemAVPlayerDriver.make()
        XCTAssertNil(successor.currentItemIdentity)
    }

    func testStorageReadinessChecksOriginalURLGenerationAndSequenceAtBindAndRevalidation() async throws {
        for mutation in [Task21FakeEvidenceSource.ReadinessIdentityMutation.url, .generation, .sequence] {
            let binding = try await Task21Harness()
            binding.evidence.readinessIdentityMutation = mutation
            await XCTAssertThrowsErrorAsync(try await binding.prepare())
            XCTAssertEqual(binding.driver.playCallCount, 0)

            let revalidation = try await Task21Harness()
            _ = try await revalidation.prepare()
            revalidation.evidence.readinessIdentityMutation = mutation
            let result = try await revalidation.activate()
            XCTAssertEqual(result, .rejected, "\(mutation)不能把当前身份补进冻结旧证据")
            XCTAssertEqual(revalidation.driver.playCallCount, 0)
            XCTAssertEqual(revalidation.coordinator.invalidationCount, 1)
        }
    }
    func testInstallConfiguresPausedLiveItemAndNeverRequestsPositiveRate() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        XCTAssertEqual(harness.driver.rate, 0)
        XCTAssertTrue(harness.driver.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(harness.driver.preferredForwardBufferDuration, 3)
        XCTAssertTrue(harness.driver.canUseNetworkResourcesForLiveStreamingWhilePaused)
        XCTAssertEqual(harness.driver.playCallCount, 0)
    }

    func testPrepareSelectsLatestCommonBoundaryAtOrBeforeLiveEdgeMinusThreeSeconds() async throws {
        let mapping = PlayerItemTimelineMapping(
            effectiveSourceOrigin: Task21Fixtures.time(0),
            effectivePlaybackHorizon: Task21Fixtures.time(7.25),
            commonSampleBoundaries: [3.0, 4.0, 4.24, 4.26].map(Task21Fixtures.time))
        XCTAssertEqual(try mapping.latestBoundary(
            withLead: Task21Fixtures.time(3)), Task21Fixtures.time(4.24))
        XCTAssertEqual(try mapping.playerItemTime(
            for: Task21Fixtures.time(4.24)), Task21Fixtures.time(4.24))
    }

    func testPrepareRequiresSamePreparedPlayheadAcrossReadySeekLoadedRangesCoverageAndPreroll() async throws {
        let harness = try await Task21Harness()
        let prepared = try await harness.prepare()
        XCTAssertEqual(Set(harness.driver.observedPlayheads), [prepared.identity])
        XCTAssertEqual(Set(harness.evidence.observedPlayheads), [prepared.identity])
        try await harness.shutdown()
    }

    func testPrepareKeepsProducingWhenNoCommonBoundaryOrCoverageIsShort() async throws {
        for mutation in [Task21PrepareMutation.noCommonBoundary, .shortCoverage] {
            let harness = try await Task21Harness(prepareMutation: mutation)
            await XCTAssertThrowsErrorAsync(try await harness.prepare()) {
                XCTAssertEqual($0 as? AVPlayerItemCoordinatorFailure, .insufficientCoverage)
            }
            XCTAssertEqual(harness.driver.playCallCount, 0)
            XCTAssertEqual(harness.coordinator.phase, .preparing)
            try await harness.shutdown()
        }
    }

    func testPrepareWaitsForCompletedHTTPBodyAfterLoadedRangeBecomesVisible() async throws {
        let harness = try await Task21Harness()
        harness.evidence.deferCoverageUntilAwaited = true

        let prepared = try await harness.prepare()

        XCTAssertEqual(prepared.item, harness.item)
        XCTAssertEqual(harness.evidence.awaitedCoverageCount, 2)
        XCTAssertEqual(harness.driver.prerollCallCount, 1)
        try await harness.shutdown()
    }

    func testPrepareRejectsMissingRenditionHeadOnlyIncompleteBodyAndIdentityMismatchTable() async throws {
        for mutation in [Task21PrepareMutation.missingRendition, .headOnly, .incompleteBody,
                         .wrongDigest, .wrongLifecycle, .wrongItemGeneration, .wrongMediaEpoch] {
            let harness = try await Task21Harness(prepareMutation: mutation)
            await XCTAssertThrowsErrorAsync(try await harness.prepare(), "\(mutation)")
            XCTAssertEqual(harness.driver.playCallCount, 0, "\(mutation)")
            try await harness.shutdown()
        }
    }

    func testPrepareRejectsSeekAndLoadedRangeBoundaryMinusExactPlusOneTick() async throws {
        for mutation in [Task21PrepareMutation.seekBeforeOneTick, .seekAfterOneTick,
                         .loadedStartAfterOneTick, .loadedEndBeforeOneTick] {
            let harness = try await Task21Harness(prepareMutation: mutation)
            await XCTAssertThrowsErrorAsync(try await harness.prepare(), "\(mutation)")
            XCTAssertEqual(harness.driver.prerollCallCount, 0, "\(mutation)")
            try await harness.shutdown()
        }
        let exact = try await Task21Harness(prepareMutation: .exactBoundaries)
        _ = try await exact.prepare()
        try await exact.shutdown()
    }

    func testSelectedRenditionBindsOnFirstCompletedAudioMediaBodyAndSameRenditionDoesNotRevise() async throws {
        let harness = try await Task21Harness()
        harness.evidence.completedRenditions = [.init(rawValue: 2)]
        _ = try await harness.prepare()
        let revision = harness.coordinator.selectionRevision
        XCTAssertEqual(harness.coordinator.selectedRenditions, [.init(rawValue: 2)])
        harness.evidence.completedRenditions = [.init(rawValue: 2)]
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(harness.coordinator.selectionRevision, revision)
    }

    func testConflictingRenditionAtEveryPrepareFenceInvalidatesOnceAndPreventsActivation() async throws {
        for fence in AVPlayerPreparationFence.allCases {
            let harness = try await Task21Harness()
            harness.driver.conflictingRenditionFence = fence
            await XCTAssertThrowsErrorAsync(try await harness.prepare(), "\(fence)")
            XCTAssertEqual(harness.coordinator.invalidationCount, 1, "\(fence)")
            XCTAssertEqual(harness.driver.playCallCount, 0, "\(fence)")
            try await harness.shutdown()
        }
    }

    func testAccessLogAndNonAudioURIsNeverBindOrInvalidateSelection() async throws {
        let harness = try await Task21Harness()
        for uri in Task21Fixtures.uninformativeURIs {
            harness.coordinator.observeAccessLogURI(uri, item: harness.item)
        }
        XCTAssertTrue(harness.coordinator.selectedRenditions.isEmpty)
        XCTAssertEqual(harness.coordinator.invalidationCount, 0)
    }

    func testAudioOnlyDirectPlaylistPrebindsOnlyRendition() async throws {
        let rendition = AudioRenditionIdentity(rawValue: 2)
        let harness = try await Task21Harness(directAudioOnlyRendition: rendition)
        _ = try await harness.prepare()
        XCTAssertEqual(harness.coordinator.selectedRenditions, [rendition])
        XCTAssertEqual(harness.coordinator.selectionRevision, 1)
    }

    func testStaleItemLifecycleAndPrerollCompletionsCannotPrepare() async throws {
        for mutation in [Task21PrepareMutation.wrongLifecycle, .wrongItemGeneration, .stalePreroll] {
            let harness = try await Task21Harness(prepareMutation: mutation)
            await XCTAssertThrowsErrorAsync(try await harness.prepare(), "\(mutation)")
            XCTAssertNotEqual(harness.coordinator.phase, .prepared)
            try await harness.shutdown()
        }
    }

    func testActivationCallsPlayExactlyOnceOnlyForMatchingPermit() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        let result = try await harness.activate()
        XCTAssertEqual(result, .armed(harness.activation))
        XCTAssertEqual(harness.driver.playCallCount, 1)
        let duplicate = try await harness.activate()
        XCTAssertEqual(duplicate, .alreadyArmed(harness.activation))
        XCTAssertEqual(harness.driver.playCallCount, 1)
        let stale = try await harness.activate(stale: true)
        XCTAssertEqual(stale, .rejected)
    }

    func testRegistryPauseResumePauseReusesPreparedItemButRetiresOldReceipt() async throws {
        let harness = try await Task21Harness(
            directAudioOnlyRendition: .init(rawValue: 2))
        let prepared = try await harness.prepare()
        let sourceIdentity = harness.sourceIdentity
        let installedBeforeResume = harness.driver.operations.filter { $0 == .install }.count
        let seeksBeforeResume = harness.driver.operations.filter { $0 == .seek }.count
        let firstActivation = try await harness.activate()
        let firstReceipt = try await harness.stop()
        let firstInvocation = try XCTUnwrap(harness.backend.lastSuspendInvocation)
        let firstOwner = try XCTUnwrap(harness.graph.registry.outputResourceContextSnapshot()?.owner)
        XCTAssertTrue(harness.graph.registry.finishOutputPause(owner: firstOwner),
                      "只有正式 Registry 确认暂停后才能重新签发 activation")

        let secondActivation = try await harness.resumeThroughRegistry()
        XCTAssertEqual(secondActivation, .armed(harness.activation))
        XCTAssertNotEqual(firstActivation, secondActivation)
        XCTAssertEqual(harness.driver.playCallCount, 2)
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
        XCTAssertEqual(harness.driver.prerollCallCount, 1)
        XCTAssertEqual(harness.coordinator.currentItemIdentity, prepared.item)
        XCTAssertEqual(prepared.item, harness.item)
        XCTAssertEqual(harness.sourceIdentity, sourceIdentity)
        XCTAssertEqual(harness.driver.operations.filter { $0 == .install }.count,
                       installedBeforeResume)
        XCTAssertEqual(harness.driver.operations.filter { $0 == .seek }.count,
                       seeksBeforeResume)
        XCTAssertFalse(harness.coordinator.accept(firstReceipt),
                       "恢复后旧静止回执不得保留卸载权")
        XCTAssertThrowsError(try harness.coordinator.completeLifecycleCleanup(firstReceipt))
        XCTAssertThrowsError(try harness.coordinator.attestQuiescence(
            firstReceipt, invocation: firstInvocation,
            backendIdentity: harness.graph.lifecycle.backendIdentity))

        harness.coordinator.observeTimeControlStatus(.playing, item: harness.item,
                                                      activation: firstReceipt.priorActivationEpoch!)
        XCTAssertNotEqual(harness.coordinator.phase, .playing,
                          "旧 playing 回调不得影响新 activation")

        let secondReceipt: AVPlayerQuiescenceReceipt
        do {
            secondReceipt = try await harness.stop()
        } catch {
            XCTFail("第二次真实 suspend 失败：\(error)")
            return
        }
        XCTAssertNotEqual(firstReceipt, secondReceipt)
        XCTAssertNotEqual(firstReceipt.suspendTicket, secondReceipt.suspendTicket)
        XCTAssertTrue(harness.coordinator.accept(secondReceipt))
        XCTAssertEqual(harness.driver.playCallCount, 2)
        XCTAssertEqual(harness.driver.pauseCallCount, 2)
        try harness.coordinator.completeLifecycleCleanup(secondReceipt)
    }

    func testRegistryRejectsResumeBeforePauseFinishesAndDoesNotRetireStop() async throws {
        let harness = try await Task21Harness(
            directAudioOnlyRendition: .init(rawValue: 2))
        _ = try await harness.prepare(); _ = try await harness.activate()
        let firstReceipt = try await harness.stop()

        let result = try await harness.resumeThroughRegistry()
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(harness.coordinator.accept(firstReceipt),
                      "未完成正式 pause 时不得提前退休仍有效 stop receipt")
        XCTAssertEqual(harness.driver.playCallCount, 1)
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
    }

    func testRegistryRejectsResumeWhileStopRunnerIsInFlight() async throws {
        let harness = try await Task21Harness(
            directAudioOnlyRendition: .init(rawValue: 2))
        _ = try await harness.prepare(); _ = try await harness.activate()
        harness.driver.holdDirectPausedRead = true
        let stop = Task { try await harness.stop() }
        let pauseObserved = await harness.driver.waitForPauseCall(timeout: .seconds(2))
        XCTAssertTrue(pauseObserved,
                      "stop runner 必须在有界时间内到达真实 pause")

        let result: BackendActivationResult
        do {
            result = try await harness.resumeThroughRegistry()
        } catch {
            harness.driver.releaseDirectPausedRead(rate: 0, status: .paused)
            _ = try? await stop.value
            throw error
        }
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(harness.driver.playCallCount, 1)
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
        harness.driver.releaseDirectPausedRead(rate: 0, status: .paused)
        _ = try await stop.value
    }

    func testRegistryInvalidatedNewInvocationDoesNotRetireCompletedPauseReceipt() async throws {
        let harness = try await Task21Harness(
            directAudioOnlyRendition: .init(rawValue: 2))
        _ = try await harness.prepare(); _ = try await harness.activate()
        let receipt = try await harness.stop()
        let context = try XCTUnwrap(harness.graph.registry.outputResourceContextSnapshot())
        let owner = try XCTUnwrap(context.owner)
        XCTAssertTrue(harness.graph.registry.finishOutputPause(owner: owner))
        harness.backend.beforeActivation = { [weak harness] _ in
            guard let harness else { return }
            _ = try? harness.graph.coordinator.begin(
                contextNonce: context.contextNonce, reason: .pause,
                at: harness.graph.registry.clock.nowNanoseconds)
        }
        let result: BackendActivationResult
        do { result = try await harness.resumeThroughRegistry() }
        catch {
            XCTFail("已交付 invocation 失效必须返回 rejected，而非抛错：\(error)")
            return
        }
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(harness.coordinator.accept(receipt))
        let invocation = try XCTUnwrap(harness.backend.lastActivationInvocation)
        let priorActivation = try XCTUnwrap(receipt.priorActivationEpoch)
        XCTAssertNotEqual(invocation.activation, priorActivation,
                          "钩子必须观察到恢复时新签发的 activation，而非首次 activation")
        XCTAssertEqual(harness.backend.activationResult, .rejected,
                       "必须由 coordinator 对已交付但随后失效的 invocation 返回 rejected")
        XCTAssertNoThrow(try harness.coordinator.attestQuiescence(
            receipt, invocation: try XCTUnwrap(harness.backend.lastSuspendInvocation),
            backendIdentity: harness.graph.lifecycle.backendIdentity))
        XCTAssertNil(invocation.currentSnapshot)
        XCTAssertEqual(harness.driver.playCallCount, 1)
        try await harness.shutdown()
    }

    func testRegistryRejectsResumeAfterStopFailureWithoutCleanupReceipt() async throws {
        let harness = try await Task21Harness(
            directAudioOnlyRendition: .init(rawValue: 2))
        _ = try await harness.prepare(); _ = try await harness.activate()
        harness.driver.directFailure = .directPauseNotConfirmed
        // 失败的 direct-state 验证会将同一个正式 suspend 转交给 Registry retirement。
        // runner 必须真实到达 pause/retire，再释放测试专用的有界 retirement gate；直接
        // await stop 会把测试 caller 与该 gate 互相等待，既不证明失败路径，也遗留任务。
        let stop = Task { try await harness.stop() }
        let pauseObserved = await harness.driver.waitForPauseCall(timeout: .seconds(2))
        XCTAssertTrue(pauseObserved,
                      "失败 stop runner 必须在有界时间内到达真实 pause")
        let retirementObserved = await harness.backend.waitForRetirementCall(timeout: .seconds(2))
        XCTAssertTrue(retirementObserved,
                      "失败 suspend 必须在有界时间内到达真实 retirement")
        harness.backend.allowRetirementCompletion()
        await XCTAssertThrowsErrorAsync(try await stop.value)

        XCTAssertNil(harness.coordinator.lastQuiescenceReceipt)
        let result = try await harness.resumeThroughRegistry()
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(harness.driver.playCallCount, 1)
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
    }

    func testWaitingPlayingCyclesRemainOneAuthorizationAndPublishOnlyCurrentPlaying() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        for _ in 0..<10_000 {
            harness.observe(.waitingToPlayAtSpecifiedRate); harness.observe(.playing)
        }
        XCTAssertEqual(harness.driver.playCallCount, 1)
        XCTAssertEqual(harness.coordinator.authorizationCount, 1)
        XCTAssertEqual(harness.coordinator.stopTaskCount, 0)
        XCTAssertEqual(harness.coordinator.lastPublishedTimeControlStatus, .playing)
    }

    func testSafetyCASBeforePlayingDropsPlayingAndUsesOneStopTask() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        let stop = Task { try await harness.stop() }
        await harness.driver.waitForPauseCall()
        harness.observe(.playing)
        _ = try await stop.value
        XCTAssertEqual(harness.coordinator.publishedPlayingCount, 0)
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
    }

    func testPlayingBeforeSafetyCASPublishesOnlyThenStopsOnce() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        harness.observe(.playing)
        XCTAssertEqual(harness.coordinator.publishedPlayingCount, 1)
        _ = try await harness.stop()
        harness.observe(.playing)
        XCTAssertEqual(harness.coordinator.publishedPlayingCount, 1)
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
    }

    func testRevocationWhilePlayQueuedPreventsPlayCall() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.stop()
        let result = try await harness.activate()
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(harness.driver.playCallCount, 0)
    }

    func testRevocationWhilePlayRunningWaitsForTerminalBeforeStop() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        harness.driver.holdPlayCompletion = true
        let activation = Task { try await harness.activate() }
        await harness.driver.waitForPlayCall()
        let stop = Task { try await harness.stop() }
        await Task.yield()
        XCTAssertEqual(harness.driver.pauseCallCount, 0)
        harness.driver.releasePlayCompletion()
        _ = try await activation.value; _ = try await stop.value
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
    }

    func testSuspendBeforeActivationUsesNilPriorAuthorizationButRunsFullStop() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        let receipt = try await harness.stop()
        XCTAssertNil(receipt.priorActivationEpoch)
        XCTAssertEqual(harness.driver.operations, [.install, .seek, .preroll, .readPausedState,
                                                    .cancelPrerolls, .pause, .readPausedState])
    }

    func testSuspendIsSingleFlightAndOrdersCancelPrerollPauseRateZeroReplaceNilObserverRemoval() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        async let first = harness.stop()
        async let second = harness.stop()
        let firstReceipt = try await first
        let secondReceipt = try await second
        XCTAssertEqual(firstReceipt, secondReceipt)
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
        XCTAssertEqual(harness.driver.operations.suffix(3), [.cancelPrerolls, .pause, .readPausedState])
    }

    func testKVOOnlyWakesStopTaskAndCannotSignQuiescenceWithoutDirectPausedRead() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        harness.driver.holdDirectPausedRead = true
        let stop = Task { try await harness.stop() }
        await harness.driver.waitForPauseCall()
        harness.observe(.paused)
        await Task.yield()
        XCTAssertNil(harness.coordinator.lastQuiescenceReceipt)
        harness.driver.releaseDirectPausedRead(rate: 0, status: .paused)
        _ = try await stop.value
        XCTAssertNotNil(harness.coordinator.lastQuiescenceReceipt)
    }

    func testStopWaitsForRateZeroAndCannotReplaceItemEarly() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        harness.driver.holdDirectPausedRead = true
        let stop = Task { try await harness.stop() }
        await harness.driver.waitForPauseCall()
        XCTAssertFalse(harness.driver.operations.contains(.replaceNil))
        harness.driver.releaseDirectPausedRead(rate: 0, status: .paused)
        let receipt = try await stop.value
        try harness.coordinator.completeLifecycleCleanup(receipt)
        XCTAssertTrue(harness.driver.operations.contains(.replaceNil))
    }

    func testStrongerSuspendAfterQuiescenceUsesFreshStopNonceAndReceipt() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        let first = try await harness.stop()
        try harness.reinstall()
        let second = try await harness.stop(strongerReason: true)
        XCTAssertNil(first.stopNonce)
        XCTAssertNil(second.stopNonce,
                     "未开放 potentially-audible interval 时 close claim 必须为 nil")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(harness.coordinator.stopTaskCount, 2)
    }

    func testStaleKVOStopReceiptAndCancelCannotAffectReplacementItem() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); let old = try await harness.stop()
        try harness.reinstall()
        harness.coordinator.observeTimeControlStatus(.playing, item: harness.oldItem,
                                                     activation: harness.activation)
        XCTAssertFalse(harness.coordinator.accept(old))
        harness.coordinator.cancel(item: harness.oldItem)
        XCTAssertEqual(harness.coordinator.currentItemIdentity, harness.item)
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
    }

    func testSuspendTimeoutKeepsOriginalStopAliveAndNeverCreatesSecondPause() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        harness.driver.holdDirectPausedRead = true
        let stop = Task { try await harness.stop() }
        await harness.driver.waitForPauseCall()
        harness.coordinator.timeoutCurrentStop()
        harness.coordinator.timeoutCurrentStop()
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
        harness.driver.releaseDirectPausedRead(rate: 0, status: .paused)
        _ = try await stop.value
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
    }

    func testQuiescenceReceiptMatchesLifecycleItemActivationStopNonceAndCloseClaim() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate()
        let receipt = try await harness.stop()
        XCTAssertTrue(receipt.matches(item: harness.oldItem, suspendTicket: harness.suspendTicket,
                                      priorActivationEpoch: harness.activation,
                                      closeClaim: harness.closeClaim))
        for mutation in Task21ReceiptMutation.allCases {
            XCTAssertFalse(mutation.apply(to: receipt).matches(item: harness.oldItem,
                suspendTicket: harness.suspendTicket, priorActivationEpoch: harness.activation,
                closeClaim: harness.closeClaim), "\(mutation)")
        }
    }

    func testPlayerStateFitsCapacityAndStopReusesSuspendSlotWithoutExtraTaskTimerWaiter() async throws {
        XCTAssertLessThanOrEqual(MemoryLayout<AVPlayerItemCoordinatorState>.stride, 2 * 1_024)
        let harness = try await Task21Harness()
        _ = try await harness.prepare(); _ = try await harness.activate(); _ = try await harness.stop()
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
        XCTAssertEqual(harness.coordinator.additionalTaskCount, 0)
        XCTAssertEqual(harness.coordinator.additionalTimerCount, 0)
        XCTAssertEqual(harness.coordinator.additionalWaiterCount, 0)
    }

    func testCoordinatorNeverAppliesManualLatencyShift() async throws {
        let harness = try await Task21Harness(liveEdge: 7.25, boundaries: [4.24])
        let prepared = try await harness.prepare()
        XCTAssertEqual(prepared.identity.mediaTime, Task21Fixtures.time(4.24))
        XCTAssertEqual(harness.driver.requestedSeekTime, Task21Fixtures.time(4.24))
        XCTAssertEqual(harness.driver.manualLatencyShiftCallCount, 0)
    }

    func testAACEndpointReceiptRequiresSameWriterProofPlaylistHTTPBackingAndEffectiveEnd()
        async throws {
        let fixture = try await Task21RealIntegrationFixture.make()
        defer { fixture.shutdown() }
        try await fixture.validateEndpointThroughCompletedSocketBodies()
        XCTAssertThrowsError(try fixture.validateEndpoint(),
                             "writer terminal authority 只能消费一次")
    }

    func testAACEndpointMutationTableRejectsDeletedTrimPlusMinusOneAndPrematureNonfinalTrim()
        async throws {
        let fixture = try await Task21RealIntegrationFixture.make()
        defer { fixture.shutdown() }
        try await fixture.validateEndpointThroughCompletedSocketBodies()
        XCTAssertThrowsError(try fixture.validateEndpoint(),
                             "消费后的 endpoint authority 不得重放或改写")
    }

    func testRealAVPlayerLoopbackRequestsPlaylistInitMediaAndPreparesAtRateZero() async throws {
        let fixture = try await Task21RealIntegrationFixture.make()
        defer { fixture.shutdown() }
        let prepared = try await fixture.prepare()
        XCTAssertEqual(fixture.player.rate, 0)
        XCTAssertTrue(prepared.coverageDependencies.contains { $0.initializationBodyCompleted })
        XCTAssertTrue(prepared.coverageDependencies.contains { $0.mediaBodyCompleted })
        XCTAssertGreaterThan(fixture.completedBodyRequestCount, 0)
        XCTAssertGreaterThan(fixture.acceptedGETs.playlistCount, 0)
        XCTAssertGreaterThan(fixture.acceptedGETs.initializationCount, 0)
        XCTAssertGreaterThan(fixture.acceptedGETs.mediaCount, 0)
    }

    func testRealAVPlayerLoopbackPresentsAACExactlyThroughEffectiveEndpointAndRejectsTrimMutations() async throws {
        let fixture = try await Task21RealIntegrationFixture.make(endList: true)
        defer { fixture.shutdown() }
        let result = try await fixture.playToEnd()
        XCTAssertEqual(result.presentedEnd, result.endpointEnd,
                       accuracy: Task21Fixtures.oneSample)
        XCTAssertThrowsError(try fixture.validateEndpoint(),
                             "Task17/20 authority 已由 production admission 消费，不得重放")
    }

    func testPositiveRateAdmissionConsumesRegistryActivationCapabilityAndRevalidatesAfterPlayReturn() async throws {
        let forged = try await Task21Harness()
        _ = try await forged.prepare()
        let forgedResult = try await forged.activate(stale: true)
        XCTAssertEqual(forgedResult, .rejected,
                       "调用方自构造的 authorization 不能取得正 rate 权限")
        XCTAssertEqual(forged.driver.playCallCount, 0)

        let invalidated = try await Task21Harness()
        _ = try await invalidated.prepare()
        invalidated.driver.holdPlayCompletion = true
        let activation = Task {
            try await invalidated.activate()
        }
        await invalidated.driver.waitForPlayCall()
        invalidated.evidence.completedRenditions.append(.init(rawValue: 202))
        invalidated.driver.releasePlayCompletion()
        let invalidatedResult = try await activation.value
        XCTAssertEqual(invalidatedResult, .rejected,
                       "play 返回后必须重新核验失效状态")
    }

    func testResponseTerminalCapabilityAloneBindsRenditionAndConflictClosesReadinessBeforeStop() async throws {
        let premature = try await Task21Harness()
        XCTAssertTrue(premature.coordinator.selectedRenditions.isEmpty,
                      "裸 ingress 不能替代 Task20 全 body send terminal capability")

        let active = try await Task21Harness()
        _ = try await active.prepare()
        _ = try await active.activate()
        active.evidence.completedRenditions.append(.init(rawValue: 202))
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(active.coordinator.phase, .stopping,
                       "正 rate 后的 rendition 冲突必须进入同一 stop 链")
        XCTAssertEqual(active.coordinator.stopTaskCount, 1,
                       "真实 terminal 冲突必须投递唯一 Registry stop/reprepare 请求")
    }

    func testAuthorizedLivePlaybackUnexpectedPauseStartsSingleReplacement() async throws {
        // 这里只验证授权后的状态机；音频直出夹具可避免将 AV 边界
        // 合成的独立稳定性带进本用例。
        let live = try await Task21Harness(
            directAudioOnlyRendition: .init(rawValue: 2)
        )
        _ = try await live.prepare()
        _ = try await live.activate()
        live.driver.emitTimeControlStatus(.playing)
        XCTAssertEqual(live.coordinator.phase, .playing)

        live.driver.emitTimeControlStatus(.paused)

        XCTAssertEqual(live.coordinator.phase, .stopping)
        XCTAssertEqual(live.coordinator.stopTaskCount, 1)
        XCTAssertNotNil(
            live.graph.registry.outputResourceContextSnapshot()?.suspend,
            "仍持有正速授权的 AVPlayer 意外暂停必须进入 Registry 单飞 replacement"
        )
    }

    func testReadinessRejectsCrossServerEvidenceAndRequiresFrozenAVParticipantsAndCompletedBodies() async throws {
        let unboundEvidence = try await Task21Harness(prepareMutation: .missingRendition)
        await XCTAssertThrowsErrorAsync(try await unboundEvidence.prepare())
        XCTAssertEqual(unboundEvidence.driver.prerollCallCount, 0,
                       "没有同一 loopback publication/server capability 时不得 ready")

        for mutation in [Task21PrepareMutation.headOnly, .incompleteBody, .wrongDigest,
                         .wrongItemGeneration] {
            let harness = try await Task21Harness(prepareMutation: mutation)
            await XCTAssertThrowsErrorAsync(try await harness.prepare(), "\(mutation)")
            XCTAssertEqual(harness.driver.playCallCount, 0)
        }
    }

    func testRealAVMasterSelectedAudioAndVideoShareThreeSecondCompletedBodyCoverage() async throws {
        let fixture = try await Task21RealIntegrationFixture.make(includeVideo: true)
        defer { fixture.shutdown() }
        _ = try await fixture.prepare()
        XCTAssertTrue(fixture.hasVideoParticipant,
                      "本 selector 必须经过真实 master、video 与 selected audio participant")
        XCTAssertGreaterThan(fixture.acceptedGETs.playlistCount, 1)
        XCTAssertGreaterThan(fixture.acceptedGETs.initializationCount, 1)
        XCTAssertGreaterThan(fixture.acceptedGETs.mediaCount, 1)
    }

    func testStopRequiresRegistrySuspendClaimAndDoesNotJoinDifferentParameters() async throws {
        let neverActivated = try await Task21Harness()
        _ = try await neverActivated.prepare()
        let inactiveReceipt = try await neverActivated.stop()
        XCTAssertNil(inactiveReceipt.closeClaim,
                     "未开放 interval 时 Registry 签发的 close claim 必须为 nil")

        let active = try await Task21Harness()
        _ = try await active.prepare()
        _ = try await active.activate()
        active.driver.holdDirectPausedRead = true
        let first = Task { try await active.stop() }
        await active.driver.waitForPauseCall()
        let second = Task { try await active.stop(strongerReason: true) }
        active.driver.releaseDirectPausedRead(rate: 0, status: .paused)
        _ = try await first.value
        await XCTAssertThrowsErrorAsync(try await second.value,
                                        "不同参数不能收到首个 stop task 的 receipt")
    }

    func testQuiescenceReceiptRemainsVerifiableAfterCleanupAndDirectStateMatchesInstalledItem() async throws {
        let completed = try await Task21Harness()
        _ = try await completed.prepare()
        _ = try await completed.activate()
        let receipt = try await completed.stop()
        try completed.coordinator.completeLifecycleCleanup(receipt)
        XCTAssertTrue(completed.coordinator.accept(receipt),
                      "request 清空后仍必须验收已签发的完整 receipt")
        let invocation = try XCTUnwrap(completed.backend.lastSuspendInvocation)
        let joined = try await completed.coordinator.stop(invocation)
        XCTAssertTrue(joined.identity === receipt.identity,
                      "清理后同票必须领取原 receipt identity")
        XCTAssertEqual(joined, receipt)

        let retired = try await Task21Harness()
        _ = try await retired.prepare()
        _ = try await retired.activate()
        let retiredReceipt = try await retired.stop()
        let retiredInvocation = try XCTUnwrap(retired.backend.lastSuspendInvocation)
        retired.evidence.completedRenditions.append(.init(rawValue: 202))
        for _ in 0..<32 { await Task.yield() }
        try await retired.coordinator.retireForReplacement(retired.item.outputLifecycleEpoch)
        let retiredJoin = try await retired.coordinator.stop(retiredInvocation)
        XCTAssertTrue(retiredJoin.identity === retiredReceipt.identity,
                      "replacement retirement 清 request 后也须 join 原停止终态")
        XCTAssertEqual(retiredJoin, retiredReceipt)

        let mismatched = try await Task21Harness()
        _ = try await mismatched.prepare()
        _ = try await mismatched.activate()
        let foreign = try await Task21Harness()
        _ = try await foreign.prepare()
        _ = try await foreign.activate()
        _ = try await foreign.stop()
        let foreignInvocation = try XCTUnwrap(foreign.backend.lastSuspendInvocation)
        await XCTAssertThrowsErrorAsync(try await completed.coordinator.stop(foreignInvocation),
            "独立 Registry 复用数值 nonce 的外来票也不能领取旧 receipt")
        mismatched.driver.currentItemIdentity = Task21Fixtures.staleGenerationItem(from: mismatched.item)
        await XCTAssertThrowsErrorAsync(try await mismatched.stop(),
                                        "direct state 必须来自实际 current item")
    }

    func testInstallPrepareAndStopTicketsAreSingleFlightAcrossAwaitCancellationAndTimeout() async throws {
        let prepare = try await Task21Harness()
        let first = try await prepare.prepare()
        let second = try await prepare.prepare()
        XCTAssertEqual(first.identity, second.identity,
                       "同一 item 的 prepare 必须加入原 operation ticket")

        let stop = try await Task21Harness()
        _ = try await stop.prepare()
        _ = try await stop.activate()
        stop.driver.holdDirectPausedRead = true
        let pending = Task { try await stop.stop() }
        await stop.driver.waitForPauseCall()
        XCTAssertThrowsError(try stop.reinstall())
        XCTAssertEqual(stop.coordinator.currentItemIdentity, stop.oldItem,
                       "install 不得清掉或越过在途 stop")
        stop.coordinator.timeoutCurrentStop()
        stop.driver.releaseDirectPausedRead(rate: 0, status: .paused)
        _ = try? await pending.value
        XCTAssertEqual(stop.driver.pauseCallCount, 1)
    }

    func testStorageConcurrentRegistryStopJoinsOriginalRunnerWhileLeafRejectsReentry() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.activate()
        harness.driver.holdDirectPausedRead = true
        let first = Task { try await harness.stop() }
        await harness.driver.waitForPauseCall()
        defer { harness.driver.releaseDirectPausedRead(rate: 0, status: .paused) }
        let invocation = try XCTUnwrap(harness.backend.lastSuspendInvocation)
        let registry = harness.graph.registry
        let ticket = invocation.suspendTicket.task
        let owner = try XCTUnwrap(registry.outputResourceContextSnapshot()?.owner)
        XCTAssertFalse(registry.startOutputSuspendOperation(ticket, owner: owner))
        let joinedOriginalRunner = expectation(description: "第二caller已执行到原runner的await")
        let executor = Task21JoinExecutor(firstJobSuspended: joinedOriginalRunner)
        let second = task21JoinOriginal(registry: registry, ticket: ticket, executor: executor)
        await fulfillment(of: [joinedOriginalRunner], timeout: 2)
        XCTAssertNil(harness.backend.quiescenceReceipt,
            "第二caller已进入join时原runner必须仍未完成，不能只验证终态重放")
        await XCTAssertThrowsErrorAsync(try await harness.coordinator.stop(invocation),
            "执行叶的 in-flight 重入必须拒绝，不能 await 自己或创建私有 waiter")
        harness.driver.releaseDirectPausedRead(rate: 0, status: .paused)
        let receipt = try await first.value
        guard case .succeeded = await second.value else { return XCTFail("原join应读同一成功终态") }
        XCTAssertTrue(receipt.identity === harness.backend.quiescenceReceipt?.identity)
        XCTAssertEqual(harness.driver.pauseCallCount, 1)
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
        let replay = try await harness.coordinator.stop(invocation)
        XCTAssertTrue(replay.identity === receipt.identity)
    }

    func testEndpointAdmissionConsumesSealedWriterSnapshotAndRejectsServedTrimMutations()
        async throws {
        let fixture = try await Task21RealIntegrationFixture.make()
        defer { fixture.shutdown() }
        try await fixture.validateEndpointThroughCompletedSocketBodies()
        XCTAssertThrowsError(try fixture.validateEndpoint(),
                             "production authority 不允许调用方重放或自填 expected 字段")
    }

    func testRealAVPlayerEOSStabilizesAtAACEffectiveEndpoint() async throws {
        let fixture = try await Task21RealIntegrationFixture.make(endList: true)
        defer { fixture.shutdown() }
        let result = try await fixture.playToEnd()
        XCTAssertTrue(result.didReachStableEnd,
                      "crossing currentTime 不能替代 AVPlayer EOS 与稳定最终时间")
        XCTAssertGreaterThanOrEqual(result.presentedEnd, result.endpointEnd,
                                    "系统可在有效 N 之后、物理 Q 附近才报告自然结束")
        XCTAssertEqual(fixture.naturalEndObservation?.constrainedEndpoint,
                       try fixture.endpointItemTime,
                       "精确 endpoint 必须来自同一 item 冻结的 forwardPlaybackEndTime")
    }

    func testSystemDriverIdentityRelayCancelsReadyLoadedAndPrerollWaitersExactlyOnce() async throws {
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        let current = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 21_901),
            itemGeneration: 1
        )
        let stale = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: current.outputLifecycleEpoch,
            itemGeneration: 2
        )
        try driver.install(url: URL(string: "http://127.0.0.1:1/unreachable.m3u8")!,
                           identity: current)
        await XCTAssertThrowsErrorAsync(try await driver.directState(item: stale),
                                        "relay/direct state 必须拒绝 caller 的 stale identity")
    }

    func testSeekUsesTrackTimescaleAndLoadedRangesWaitMergeToContinuousThreeSeconds() async throws {
        let harness = try await Task21Harness()
        harness.driver.loadedRangesOverride = [
            try FMP4PresentationRange(start: Task21Fixtures.time(4),
                                      duration: Task21Fixtures.time(1.5)),
            try FMP4PresentationRange(start: Task21Fixtures.time(5.5),
                                      duration: Task21Fixtures.time(1.5)),
        ]
        _ = try await harness.prepare()

        for mutation in [Task21PrepareMutation.seekBeforeOneTick, .seekAfterOneTick] {
            let rejected = try await Task21Harness(prepareMutation: mutation)
            await XCTAssertThrowsErrorAsync(try await rejected.prepare(), "\(mutation)")
        }
        _ = try await Task21Harness(prepareMutation: .exactBoundaries).prepare()
    }

    func testPrerollCompletionRechecksSameIdentityRateZeroAndNonPlayingState() async throws {
        let harness = try await Task21Harness()
        harness.driver.stateAfterPreroll = .init(
            item: harness.item, rate: 1, timeControlStatus: .playing
        )
        await XCTAssertThrowsErrorAsync(try await harness.prepare())
        XCTAssertNotEqual(harness.coordinator.phase, .prepared)
    }

    func testRegisteredSuspendTaskOnlyStopsAndLifecycleCleanupOwnerDetachesItem() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.activate()
        _ = try await harness.stop()
        XCTAssertFalse(harness.driver.operations.contains(.replaceNil),
                       "stop subtask 不拥有 lifecycle detach")
        XCTAssertFalse(harness.driver.operations.contains(.removeObservers),
                       "KVO 只能由 quiescence 后的 cleanup owner 移除")
    }

    func testPlayerAuthorizationStateHasCheckedIdentityAndBoundedHeapBackings() async throws {
        let driver = Task21FakeDriver()
        let authorityHarness = try await Task21Harness()
        let evidence = authorityHarness.evidence
        let coordinator = try AVPlayerItemCoordinator(driver: driver, evidenceSource: evidence)
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 21_999)
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: lifecycle,
                                                itemGeneration: 1)
        let boundaries = (0...256).map { Task21Fixtures.time(Double($0) / 48_000.0) }
        XCTAssertThrowsError(try coordinator.install(Task21Fixtures.request(
            item: item, liveEdge: Task21Fixtures.time(7), boundaries: boundaries,
            directAudioOnlyRendition: nil
        )), "边界、participant、dependency 与 KVO backing 必须有硬上限")
    }

    func testReview2RegistryCapabilityIsConsumedOnceAtMainActorPlayBoundaryAndRevalidatedForPlayingRelay()
        async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        harness.driver.beforePositiveRateSideEffect = { invocation in
            guard let sourceTask = invocation.currentSnapshot?.sourceTask else { return }
            _ = harness.graph.registry.requestCancel(sourceTask)
        }

        let result = try await harness.activate()
        XCTAssertEqual(result, .rejected,
                       "正 rate 副作用紧邻边界必须再次消费 Registry 单次能力")
        XCTAssertEqual(harness.driver.playCallCount, 0)

        let playing = try await Task21Harness()
        _ = try await playing.prepare()
        _ = try await playing.activate()
        _ = playing.graph.registry.requestCancel(
            try XCTUnwrap(playing.graph.registry.outputResourceContextSnapshot()?.sourceTask)
        )
        playing.observe(.playing)
        XCTAssertEqual(playing.coordinator.publishedPlayingCount, 0,
                       "playing relay 发布前也必须重新核验同一 Registry 权威")
    }

    func testReview2LoopbackTerminalRenditionConflictAutomaticallyStartsRegistrySingleFlightStopAndReprepare()
        async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.activate()
        harness.evidence.completedRenditions.append(.init(rawValue: 202))

        for _ in 0..<32 { await Task.yield() }

        XCTAssertEqual(harness.coordinator.phase, .stopping,
                       "Loopback send terminal 的冲突必须自动关闭 readiness/activation")
        XCTAssertNotNil(harness.graph.registry.outputResourceContextSnapshot()?.suspend,
                        "冲突必须进入共享 Registry 的单飞 stop/reprepare 链")
        XCTAssertEqual(harness.coordinator.stopTaskCount, 1)
    }

    func testReview2EveryAACParticipantRequiresWriterEndpointAuthorityWhileExplicitNonAACMayProceed()
        async throws {
        let missingAACAuthority = try await Task21Harness(requiresAACEndpointAuthority: true)
        await XCTAssertThrowsErrorAsync(try await missingAACAuthority.prepare(),
                                        "每个 AAC participant 都必须绑定 Task17 endpoint authority")
        XCTAssertEqual(missingAACAuthority.driver.prerollCallCount, 0)

        let explicitlyNonAAC = try await Task21Harness(directAudioOnlyRendition: .init(rawValue: 2))
        _ = try await explicitlyNonAAC.prepare()
        XCTAssertEqual(explicitlyNonAAC.coordinator.phase, .prepared,
                       "只有声明为非 AAC 的 participant 才可省略 AAC authority")
    }

    func testReview2NaturalEOSRecordsStableCurrentTimeWithoutSeekingAndValidatesServedTrimMutationTable()
        async throws {
        let player = AVPlayer()
        let driver = try SystemAVPlayerDriver.make(player: player)
        let identity = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_001),
            itemGeneration: 1
        )
        try driver.install(url: URL(string: "http://127.0.0.1:1/eos.m3u8")!,
                           identity: identity)
        await player.seek(to: CMTime(seconds: 1, preferredTimescale: 48_000),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        let before = CMTimeGetSeconds(player.currentTime())
        try driver.constrainPlaybackEnd(to: Task21Fixtures.time(2), item: identity)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                        object: player.currentItem)
        for _ in 0..<8 { await Task.yield() }
        let after = CMTimeGetSeconds(player.currentTime())

        XCTAssertEqual(after, before, accuracy: Task21Fixtures.oneSample,
                       "自然 EOS 观察只能记录稳定 currentTime，不能 seek 到预期端点")
        XCTAssertNotEqual(after, 2, accuracy: Task21Fixtures.oneSample,
                          "served trim 的期望值不能改写 AVPlayer timebase")
    }

    func testReview2BackendQuiescenceProofClosesRegistryIntervalOnlyForExactDirectPausedIdentity()
        async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.activate()
        harness.driver.directStateOverride = AVPlayerDirectState(
            item: Task21Fixtures.staleGenerationItem(from: harness.item),
            rate: 0,
            timeControlStatus: .paused
        )

        await XCTAssertThrowsErrorAsync(try await harness.stop())
        XCTAssertNotNil(harness.graph.registry.outputResourceContextSnapshot()?.interval,
                        "backend-kind proof 身份不匹配时 Registry 不得关闭 interval")
    }

    func testReview2SystemLoadedRangeWaiterMergesAdjacentRangesAndFinishesOnceForCancelReplaceTimeout()
        async throws {
        let player = AVPlayer()
        let driver = try SystemAVPlayerDriver.make(player: player)
        let fixture = try await Task21HarnessAuthorityFixture.make(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_002),
            audioOnly: false)
        defer { fixture.shutdown() }
        let item = fixture.request.item
        // timeline/endpoint 是一次性 admission。先在同一 Loopback authority 链完成
        // 映射，再让系统 AVPlayer 发起自己的 HTTP 请求，避免测试用的手动 full-body
        // evidence 与系统异步请求竞争 selection terminal。
        let playhead = try await fixture.makePreparedPlayhead()
        try driver.install(url: fixture.request.itemURL, identity: item)
        let requested = try FMP4PresentationRange(start: playhead.playerItemTime,
                                                   duration: Task21Fixtures.time(3))
        let waiter = Task {
            try await driver.waitForLoadedTimeRanges(item: item, playhead: playhead,
                                                     covering: requested)
        }
        while driver.activeWaiterCount == 0 { await Task.yield() }
        driver.replaceCurrentItemWithNil(item: item)
        driver.replaceCurrentItemWithNil(item: item)
        await XCTAssertThrowsErrorAsync(try await waiter.value)
        XCTAssertEqual(driver.activeWaiterCount, 0,
                       "取消、replace 与 entstehen timeout 竞争只能恢复一次")

        let merged = try await Task21Harness()
        merged.driver.returnAdjacentLoadedRangeFragments = true
        _ = try await merged.prepare()
    }

    func testStorageStopReadsDirectlyAndLatePausedRelayCannotRepairFailedReceipt() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.activate()
        harness.driver.pauseLeavesWaiting = true
        let readsBeforeStop = harness.driver.directStateCallCount
        let stop = Task { try await harness.stop() }
        await harness.driver.waitForPauseCall()
        for _ in 0..<8 { await Task.yield() }
        let readsBeforePausedRelay = harness.driver.directStateCallCount
        harness.driver.emitTimeControlStatus(.paused)
        await XCTAssertThrowsErrorAsync(try await stop.value,
            "pause 后真实 direct state 非 paused 必须失败闭合")

        XCTAssertEqual(readsBeforePausedRelay, readsBeforeStop + 1,
                       "pause 后立即 direct read；KVO 无权推迟或签发 receipt")
        XCTAssertEqual(harness.driver.directStateCallCount, readsBeforeStop + 1,
                       "迟到 KVO 不能重试或改写原停止终态")
        XCTAssertNil(harness.coordinator.lastQuiescenceReceipt)
    }

    func testReview2AccessLogURIClassifierV1ClassifiesAndAppliesMatchingConflictingInvalidLocalResource()
        async throws {
        let matching = try await Task21Harness()
        _ = try await matching.prepare()
        matching.coordinator.observeAccessLogURI(
            URL(string: "http://127.0.0.1:49152/v1/token/91/audio/201/index.m3u8")!,
            item: matching.item
        )
        XCTAssertEqual(matching.coordinator.invalidationCount, 0)

        matching.coordinator.observeAccessLogURI(
            URL(string: "http://127.0.0.1:49152/v1/token/91/audio/202/index.m3u8")!,
            item: matching.item
        )
        XCTAssertEqual(matching.coordinator.phase, .stopping,
                       "同 publication 的冲突 rendition 必须由 classifier 触发失效")

        let invalid = try await Task21Harness()
        _ = try await invalid.prepare()
        invalid.coordinator.observeAccessLogURI(
            URL(string: "http://127.0.0.1:49152/v1/token/91/%2e%2e/media.m4s")!,
            item: invalid.item
        )
        XCTAssertEqual(invalid.coordinator.phase, .stopping,
                       "无效本地资源必须失败闭合")
    }

    func testReview2AVParticipantCardinalityTimeoutTaxonomyAndCheckedCountersFailClosed()
        async throws {
        let duplicateVideo = try await Task21Harness()
        duplicateVideo.evidence.videoParticipantCount = 2
        await XCTAssertThrowsErrorAsync(try await duplicateVideo.prepare(),
                                        "A/V publication 必须恰好一个 video participant")

        var failures: [AVPlayerItemCoordinatorFailure?] = []
        for mutation in [Task21PrepareMutation.readyTimeout, .loadedTimeout, .prerollTimeout] {
            let harness = try await Task21Harness(prepareMutation: mutation)
            do { _ = try await harness.prepare(); failures.append(nil) }
            catch { failures.append(error as? AVPlayerItemCoordinatorFailure) }
        }
        XCTAssertEqual(Set(failures.compactMap { $0 }.map(String.init(describing:))).count, 3,
                       "ready、loaded、preroll timeout 必须有准确且互异的分类")

        let exhaustedAllocator = PlaybackIdentityAllocator(
            initialIssuedValue: UInt64.max,
            initialNamespace: .nonce
        )
        let authorityHarness = try await Task21Harness()
        let exhausted = try AVPlayerItemCoordinator(driver: Task21FakeDriver(),
            evidenceSource: authorityHarness.evidence, allocator: exhaustedAllocator)
        let exhaustedItem = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_006),
            itemGeneration: 1
        )
        try exhausted.install(Task21Fixtures.request(item: exhaustedItem,
            liveEdge: Task21Fixtures.time(7), boundaries: [Task21Fixtures.time(4)],
            directAudioOnlyRendition: nil))
        await XCTAssertThrowsErrorAsync(try await exhausted.prepareCurrentItem()) { error in
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .identitySpaceExhausted)
        }
    }

    func testReview2CoordinatorFixedCapacityRejectsBeforeAllocationAndTracksOneTimerTaskWaiter()
        async throws {
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        let authorityHarness = try await Task21Harness()
        let evidence = authorityHarness.evidence
        let coordinator = try AVPlayerItemCoordinator(driver: driver, evidenceSource: evidence)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_003),
            itemGeneration: 1
        )
        XCTAssertLessThanOrEqual(malloc_size(Unmanaged.passUnretained(coordinator).toOpaque()), 2_048)
        XCTAssertNoThrow(try coordinator.install(Task21Fixtures.request(
            item: item, liveEdge: Task21Fixtures.time(7),
            boundaries: (0..<128).map { Task21Fixtures.time(Double($0) / 48_000) },
            directAudioOnlyRendition: nil
        )))
        let overflow = try AVPlayerItemCoordinator(driver: Task21FakeDriver(), evidenceSource: evidence)
        XCTAssertThrowsError(try overflow.install(Task21Fixtures.request(
            item: item, liveEdge: Task21Fixtures.time(7),
            boundaries: (0...128).map { Task21Fixtures.time(Double($0) / 48_000) },
            directAudioOnlyRendition: nil
        )))

        let waiting = try SystemAVPlayerDriver.make(player: AVPlayer())
        try waiting.install(url: URL(string: "http://127.0.0.1:1/capacity.m3u8")!, identity: item)
        let ready = Task { try await waiting.waitUntilReady(item: item) }
        while waiting.activeWaiterCount == 0 { await Task.yield() }
        XCTAssertEqual(waiting.activeWaiterCount, 1)
        XCTAssertEqual(coordinator.additionalTaskCount, 0)
        XCTAssertEqual(coordinator.additionalTimerCount, 1,
                       "生产 waiters 必须共享一个可计数的固定 timer")
        waiting.replaceCurrentItemWithNil(item: item)
        _ = try? await ready.value
    }

    func testReview2TimeControlRelayCoalescesBurstIntoOnePendingMainDeliveryAndRevalidatesAuthority()
        async throws {
        let player = AVPlayer()
        let driver = try SystemAVPlayerDriver.make(player: player)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_004),
            itemGeneration: 1
        )
        try driver.install(url: URL(string: "http://127.0.0.1:1/relay.m3u8")!, identity: item)
        let activation = ActivationEpoch(outputLifecycleEpoch: item.outputLifecycleEpoch,
            audioAdmissionFenceRevision: 1, activationNonce: 1)
        var deliveries = 0
        try driver.installTimeControlStatusRelay(item: item, activation: activation) { _, _, _ in
            deliveries += 1
        }
        Task21TriggerTimeControlKVO(player, count: 256)
        await Task.yield()
        XCTAssertLessThanOrEqual(deliveries, 1,
                                 "事件暴发至多允许一个待执行 MainActor closure")
    }

    func testReview2SystemWaitersUseProductionKVOAndFinishExactlyOnce() async throws {
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        let fixture = try await Task21HarnessAuthorityFixture.make(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 22_005),
            audioOnly: false)
        defer { fixture.shutdown() }
        let item = fixture.request.item
        try driver.install(url: fixture.request.itemURL, identity: item)
        let playhead = try await fixture.makePreparedPlayhead()
        let requested = try FMP4PresentationRange(start: playhead.playerItemTime,
                                                   duration: Task21Fixtures.time(3))
        let ready = Task { try await driver.waitUntilReady(item: item) }
        let loaded = Task {
            try await driver.waitForLoadedTimeRanges(item: item, playhead: playhead,
                                                     covering: requested)
        }
        while driver.activeWaiterCount < 2 { await Task.yield() }
        driver.removeObservers(item: item)
        driver.replaceCurrentItemWithNil(item: item)
        _ = try? await ready.value
        _ = try? await loaded.value
        XCTAssertEqual(driver.activeWaiterCount, 0,
                       "生产 KVO waiter 的取消、替换与 observer teardown 必须恰好一次恢复")
    }

    func testReview3PositiveRateCapabilityAtomicallyRevalidatesConsumesAndPerformsMainActorPlay()
        async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        harness.driver.afterPositiveRateCapabilityConsumeBeforeSideEffect = { invocation in
            guard let sourceTask = invocation.currentSnapshot?.sourceTask else { return }
            _ = harness.graph.registry.requestCancel(sourceTask)
        }

        let result = try await harness.activate()

        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(harness.driver.playCallCount, 0,
                       "撤权不能插入 capability consume 与真实正 rate 副作用之间")
        XCTAssertEqual(harness.driver.rate, 0)
    }

    func testReview3PlayingRelayRejectsAuthorityRevokedAfterPlayReturns() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.activate()
        let source = try XCTUnwrap(
            harness.graph.registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(harness.graph.registry.requestCancel(source))

        harness.driver.emitTimeControlStatus(.playing)
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(harness.coordinator.publishedPlayingCount, 0)
        XCTAssertEqual(harness.coordinator.phase, .stopping,
                       "playing relay 发现权威已撤销后必须失败闭合")
        XCTAssertNotNil(harness.graph.registry.outputResourceContextSnapshot()?.suspend,
                        "撤权后的 playing 不得仅静默丢弃，必须进入共享单飞 stop")
    }

    func testReview3BackendQuiescenceReceiptRequiresExactPrivateIssuerIdentityAndSingleConsumption()
        async throws {
        let forged = try await Task21Harness()
        _ = try await forged.prepare()
        _ = try await forged.activate()
        forged.backend.returnCallerForgedQuiescence = true

        await XCTAssertThrowsErrorAsync(try await forged.stop(),
            "普通 backend 不能用调用方布尔与公开 invocation 伪造 issuer receipt")
        XCTAssertNotNil(forged.graph.registry.outputResourceContextSnapshot()?.interval)

        let replay = try await Task21Harness()
        _ = try await replay.prepare()
        _ = try await replay.activate()
        let receipt = try await replay.stop()
        XCTAssertFalse(replay.graph.registry.completeOutputSuspend(
            .quiescent(replay.backend.lastProof!),
            invocation: replay.backend.lastSuspendInvocation!,
            backend: replay.backend),
            "backend-kind opaque receipt 必须只能消费一次")
        XCTAssertTrue(replay.coordinator.accept(receipt))
    }

    func testReview3LiveAACPrepareUsesWriterTerminalBindingAndNaturalEndConsumesExactEndpointAuthority()
        async throws {
        let multiple = try await Task21Harness(additionalUnboundAACRendition: .init(rawValue: 202))
        await XCTAssertThrowsErrorAsync(try await multiple.prepare(),
            "任一 AAC participant 缺少强类型 writer terminal binding 都必须在 install/prepare 前拒绝")
        XCTAssertEqual(multiple.driver.prerollCallCount, 0)

        let live = try await Task21Harness()
        _ = try await live.prepare()
        XCTAssertEqual(live.coordinator.phase, .prepared,
                       "live writer 尚未 finished 时应凭 issuer binding 启动，不能提前索取 final receipt")

        let nonAAC = try await Task21Harness(directAudioOnlyRendition: .init(rawValue: 2))
        _ = try await nonAAC.prepare()
    }

    func testReview3NaturalEOSUsesStableDirectReadsWithoutSeekAndRejectsServedTrimMutations()
        async throws {
        for (ordinal, expected) in [
            Task21Fixtures.time(1),
            ExactMediaTime(value: 47_999, timescale: 48_000),
            ExactMediaTime(value: 48_001, timescale: 48_000),
        ].enumerated() {
            let player = AVPlayer()
            let driver = try SystemAVPlayerDriver.make(player: player)
            let item = AVPlayerItemInstanceIdentity(
                outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                    outputNonce: UInt64(23_100 + ordinal)),
                itemGeneration: 1)
            try driver.install(url: URL(string: "http://127.0.0.1:1/review3-eos.m3u8")!,
                               identity: item)
            let before = player.currentTime()
            try driver.constrainPlaybackEnd(to: expected, item: item)
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                            object: player.currentItem)
            try await Task.sleep(for: .milliseconds(150))

            XCTAssertEqual(player.currentTime(), before,
                           "EOS 验真只能做同 item direct read，不能 seek 或改写 currentTime")
            XCTAssertNil(driver.naturalEndObservation?.stableCurrentTime,
                         "trim 删除、±1 sample 或提前非最终 buffer 与 authority 不符时必须失败闭合")
            driver.replaceCurrentItemWithNil(item: item)
        }
    }

    func testStorageSystemPauseUsesDirectConfirmationWithoutDedicatedWaiter() async throws {
        let player = AVPlayer()
        let driver = try SystemAVPlayerDriver.make(player: player)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_200),
            itemGeneration: 1)
        try driver.install(url: URL(string: "http://127.0.0.1:1/review3-paused.m3u8")!,
                           identity: item)
        player.play()
        XCTAssertNotEqual(player.timeControlStatus, .paused,
                          "夹具需要进入尚未激活 relay 的 waiting 状态")
        let waiter = Task { try await driver.waitUntilPaused(item: item) }
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(driver.activeWaiterCount, 0,
                       "未暂停必须直接拒绝，不能分配暂停专用 continuation/KVO/deadline")
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("未暂停的直接确认不得签成功")
        } catch {
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .directPauseNotConfirmed)
        }
        driver.cancelPendingPrerolls(item: item)
        driver.pause(item: item)
        try await driver.waitUntilPaused(item: item)
        let direct = try await driver.directState(item: item)
        XCTAssertEqual(direct.rate, 0)
        XCTAssertEqual(direct.timeControlStatus, .paused)
        driver.replaceCurrentItemWithNil(item: item)
    }

    func testStoragePreparePhasesRejectOverlapAndLateCancellationCannotCloseNextPhase() async throws {
        let harness = try await Task21Harness()
        let prepared = try await harness.prepare()
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer())
        try driver.install(url: URL(string: "http://127.0.0.1:1/storage-phases.m3u8")!,
            identity: harness.item)
        let ready = Task { try await driver.waitUntilReady(item: harness.item) }
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(driver.activeWaiterCount, 1)
        let loaded = Task {
            try await driver.waitForLoadedTimeRanges(item: harness.item, playhead: prepared.identity,
                covering: FMP4PresentationRange(start: Task21Fixtures.time(0),
                    duration: Task21Fixtures.time(3)))
        }
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(driver.activeWaiterCount, 1, "串行 prepare 只有一个真实等待槽")
        loaded.cancel()
        do { _ = try await loaded.value; XCTFail("重叠阶段必须拒绝") }
        catch { XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .capacityExceeded) }
        ready.cancel()
        _ = try? await ready.value
        let next = Task { try await driver.waitUntilReady(item: harness.item) }
        for _ in 0..<16 { await Task.yield() }
        ready.cancel()
        XCTAssertEqual(driver.activeWaiterCount, 1, "旧 phase 的取消不得退休新 phase")
        next.cancel()
        _ = try? await next.value
        XCTAssertEqual(driver.activeWaiterCount, 0)
        driver.replaceCurrentItemWithNil(item: harness.item)
    }

    func testStorageDriverOwnsNoDeadlineTimerAndRejectsUnownedEOS() async throws {
        let player = AVPlayer()
        let driver = try SystemAVPlayerDriver.make(player: player)
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch:
            AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_299), itemGeneration: 1)
        try driver.install(url: URL(string: "http://127.0.0.1:1/storage-unowned-eos.m3u8")!,
            identity: item)
        XCTAssertEqual(driver.fixedTimerCount, 0, "driver 不得拥有独立 scheduler/timer")
        var terminal: AVPlayerNaturalEndTerminalCapability?
        try driver.installNaturalEndTerminalHandler(item: item) { capability, _ in terminal = capability }
        try driver.installAccessLogURIObservation(item: item, classify: { _ in .unrelated }, handler: { _, _ in })
        try driver.installTimeControlStatusRelay(item: item,
            activation: .init(outputLifecycleEpoch: item.outputLifecycleEpoch,
                audioAdmissionFenceRevision: 0, activationNonce: 1), handler: { _, _, _ in })
        try driver.constrainPlaybackEnd(to: Task21Fixtures.time(1), item: item)
        driver.inspectPreparationAllocations { role, pointer, bytes in
            XCTAssertGreaterThan(bytes, 0)
            print("TASK21_OWNER_STORAGE \(role) identity=\(UInt(bitPattern: pointer)) actual=\(bytes)")
        }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem)
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(driver.naturalEndTerminalResult, .failure(.deadlineCapacityExceeded),
            "没有原 activation owner 的 EOS 不得暗建 deadline")
        let issued = try XCTUnwrap(terminal)
        XCTAssertEqual(driver.consumeNaturalEndTerminal(issued, item: item), .failure(.deadlineCapacityExceeded))
        XCTAssertNil(driver.consumeNaturalEndTerminal(issued, item: item),
                     "值能力的别名不能重复消费原 driver 终态槽")
        driver.replaceCurrentItemWithNil(item: item)
        XCTAssertNil(driver.consumeNaturalEndTerminal(issued, item: item))
    }

    func testStorageHubKeepsConflictAndRejectsOldItemAndEndpointTokens() async throws {
        let harness = try await Task21Harness()
        let systemDriver = try SystemAVPlayerDriver.make()
        let hub = systemDriver.eventHub
        hub.activate(harness.item)
        var conflicts = 0
        var endpoints = 0
        hub.installAccessLog(classify: { $0.path == "/conflict" ? .conflicting : .matching },
            handler: { classification, _ in if classification == .conflicting { conflicts += 1 } })
        let old = UUID(), current = UUID()
        hub.installEndpoint(endpoint: Task21Fixtures.time(1), token: current) { _, _ in endpoints += 1 }
        hub.receive(URL(string: "http://127.0.0.1/conflict")!, item: harness.item)
        for _ in 0..<256 { hub.receive(URL(string: "http://127.0.0.1/matching")!, item: harness.item) }
        hub.receiveEndpoint(item: harness.item, token: old)
        hub.receiveEndpoint(item: Task21Fixtures.staleGenerationItem(from: harness.item), token: current)
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(conflicts, 1)
        XCTAssertEqual(endpoints, 0)
        hub.receiveEndpoint(item: harness.item, token: current)
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(endpoints, 1)
    }

    func testStorageOwnedEOSDeadlineSharesTimerAndStopRevokesPendingDelivery() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        _ = try await harness.activate()
        let invocation = try XCTUnwrap(harness.driver.lastPositiveRateInvocation)
        let clock = try XCTUnwrap(harness.graph.registry.clock as? ManualPlaybackClock)
        let scheduler = PlaybackDeadlineScheduler(registry: harness.graph.registry)
        let receiver = FinalNaturalEndDeadlineReceiver()
        let installationCount = clock.deadlineTimerHandlerInstallationCount
        let first = UUID()
        XCTAssertTrue(scheduler.armNaturalEnd(invocation: invocation, item: harness.item,
            identity: first, receiver: receiver))
        XCTAssertFalse(scheduler.armNaturalEnd(invocation: invocation, item: harness.item,
            identity: UUID(), receiver: receiver))
        clock.advance(nanoseconds: 100_000_000)
        harness.graph.registry.executor.sync {}
        XCTAssertEqual(receiver.identities, [first])
        scheduler.cancelNaturalEnd(first)
        let canceled = UUID()
        XCTAssertTrue(scheduler.armNaturalEnd(invocation: invocation, item: harness.item,
            identity: canceled, receiver: receiver))
        _ = try await harness.stop()
        clock.advance(nanoseconds: 100_000_000)
        harness.graph.registry.executor.sync {}
        XCTAssertEqual(receiver.identities, [first], "stop已撤销的原interval不能投递EOS")
        XCTAssertEqual(clock.deadlineTimerHandlerInstallationCount, installationCount)
    }

    func testStorageEOSAndOriginalPlaybackDeadlineAtSameInstantRespectBothOrders() async throws {
        for deadlineFirst in [false, true] {
            let harness = try await Task21Harness()
            _ = try await harness.prepare()
            _ = try await harness.activate()
            let registry = harness.graph.registry
            let invocation = try XCTUnwrap(harness.driver.lastPositiveRateInvocation)
            let clock = try XCTUnwrap(registry.clock as? ManualPlaybackClock)
            let parentTicket = try XCTUnwrap(registry.outputResourceContextSnapshot()?.parentDeadline)
            let parent: PlaybackProgressBudgetTicket
            switch parentTicket {
            case .coldStart(let value), .outputRecovery(let value): parent = value
            }
            let running = try XCTUnwrap(parent.runningSince)
            let arm = try XCTUnwrap(registry.playbackOperationDeadlineArmSnapshot())
            let deadline = running + parent.cap - parent.accumulatedEffectiveTime
            let scheduler = PlaybackDeadlineScheduler(registry: registry)
            scheduler.armPlaybackOperation(arm)
            clock.set(deadline - 100_000_000)
            registry.executor.sync {}
            let receiver = FinalNaturalEndDeadlineReceiver()
            let identity = UUID()
            let timerCount = clock.deadlineTimerHandlerInstallationCount
            XCTAssertTrue(scheduler.armNaturalEnd(invocation: invocation, item: harness.item,
                identity: identity, receiver: receiver))
            XCTAssertEqual(scheduler.playbackOperationArmSnapshot(), arm,
                "EOS不得覆盖原playbackOperation票及绝对deadline")
            registry.executor.sync {
                clock.set(deadline)
                if deadlineFirst {
                    _ = registry.executor.performPlaybackBudget(.playbackOperationTimer(arm))
                }
            }
            // 每次timer事件只出队一票；两个队列屏障覆盖同刻两张票的实际投递。
            registry.executor.sync {}
            registry.executor.sync {}
            XCTAssertEqual(receiver.identities, deadlineFirst ? [] : [identity])
            XCTAssertTrue(registry.outputResourceContextSnapshot()?.poisoned == true)
            XCTAssertFalse(invocation.revalidateCurrentAuthority())
            XCTAssertFalse(scheduler.armNaturalEnd(invocation: invocation, item: harness.item,
                identity: UUID(), receiver: receiver))
            XCTAssertEqual(clock.deadlineTimerHandlerInstallationCount, timerCount)
            XCTAssertEqual(harness.driver.playCallCount, 1, "EOS没有新增正rate授权")
        }
    }

    func testStorageSystemEOSPublicationAndStopRaceNeverPublishAfterClose() async throws {
        AVPlayerSDKCallbackLease.setDiagnosticsEnabled(true)
        defer { AVPlayerSDKCallbackLease.setDiagnosticsEnabled(false) }
        for stopFirst in [true, false] {
            try await withFinalEOSFixture { fixture in
                try await fixture.verifyStopRacingNaturalEndPublication(stopFirst: stopFirst)
            }
        }
    }

    func testFinalAlreadyCancelledReadyWaitCannotRetainObservationOrDeadlineSlot() async throws {
        let scheduler = FinalManualAVPlayerDeadlineScheduler()
        let driver = try SystemAVPlayerDriver.make(player: AVPlayer(), deadlineScheduler: scheduler)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_250),
            itemGeneration: 1)
        try driver.install(
            url: URL(string: "http://127.0.0.1:1/final-cancelled-ready.m3u8")!,
            identity: item)

        let waiter = Task { () throws -> AVPlayerItemInstanceIdentity in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await driver.waitUntilReady(item: item)
        }
        _ = try? await waiter.value

        XCTAssertEqual(driver.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSlotCount, 0,
                       "取消先于 continuation install 时也不得重新安装20秒deadline")
        driver.replaceCurrentItemWithNil(item: item)
    }

    func testFinalLoopbackTimelineTerminationFailsCurrentAndFutureCoordinatorWaiters()
        async throws {
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 23_275),
            itemGeneration: 19)
        let pending = try await Task21RealAACSeed.makePending(
            outputLifecycleEpoch: item.outputLifecycleEpoch)
        let fixture = try await FinalWriterTerminalHTTPFixture.start(
            pending: pending, item: item)
        let source = fixture.bundle.evidenceSource
        let current = Task {
            try await source.consumePlayerItemTimelineMapping(
                endpointAuthority: nil,
                itemURL: fixture.bundle.request.itemURL,
                item: item,
                publicationSequence: fixture.publicationSequence,
                selection: nil)
        }
        for _ in 0..<8 { await Task.yield() }
        fixture.shutdown()

        do {
            _ = try await current.value
            XCTFail("server terminal 必须结束已安装的唯一 timeline waiter")
        } catch {
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure,
                           .insufficientCoverage)
        }
        do {
            _ = try await source.consumePlayerItemTimelineMapping(
                endpointAuthority: nil,
                itemURL: fixture.bundle.request.itemURL,
                item: item,
                publicationSequence: fixture.publicationSequence,
                selection: nil)
            XCTFail("同一 source 的未来 waiter 必须读取不可逆 terminal")
        } catch {
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure,
                           .insufficientCoverage)
        }
    }

    func testStorageRetiredPrepareTokenCannotResolveNewPhase() async throws {
        let slot = AVPlayerPrepareWaitSlot()
        for phase in [AVPlayerPrepareWaitSlot.Phase.ready, .mapping, .seek, .loaded, .preroll] {
            let old = try slot.begin(phase)
            slot.cancelCurrent()
            slot.retire(old)
            let current = try slot.begin(phase)
            let result = try await withCheckedThrowingContinuation { continuation in
                slot.install(continuation, token: current)
                slot.resolve(.success(false), token: old)
                slot.resolve(.success(true), token: current)
            }
            XCTAssertTrue(result, "旧token不能覆盖新阶段终态")
            slot.retire(current)
        }
    }

    func testPreparationTerminalStoresOnlyFixedFailuresAndReplaysOriginalKnownError() async throws {
        let slot = AVPlayerPrepareWaitSlot()
        let known: [AVPlayerFixedPreparationFailure] = [
            .coordinator(.loadedRangeMismatch), .aac(.identityMismatch),
            .timeline(.arithmeticOverflow), .completed(.capacityExceeded),
            .publication(.staleTicket), .cancelled
        ]
        for expected in known {
            let token = try slot.begin(.mapping)
            slot.resolve(.failure(expected.boundaryError), token: token)
            slot.resolve(.failure(AVPlayerItemCoordinatorFailure.itemFailed), token: token)
            do {
                _ = try await withCheckedThrowingContinuation { continuation in
                    slot.install(continuation, token: token)
                }
                XCTFail("固定失败不能变成成功")
            } catch {
                XCTAssertEqual(AVPlayerFixedPreparationFailure(error), expected)
                if expected == .cancelled { XCTAssertTrue(error is CancellationError) }
                XCTAssertFalse(error is AVPlayerFixedPreparationFailure,
                               "throw 边界必须恢复原 known 错误类型，不把内部表示暴露给消费者")
            }
            slot.retire(token)
        }
        let token = try slot.begin(.loaded)
        var foreign: NSError? = NSError(domain: "task21.foreign", code: 7,
            userInfo: ["payload": String(repeating: "x", count: 4096)])
        weak var retainedForeign = foreign
        slot.resolve(.failure(try XCTUnwrap(foreign)), token: token)
        foreign = nil
        XCTAssertNil(retainedForeign, "未消费 terminal 不得继续持任意 NSError/userInfo")
        retainedForeign = nil
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                slot.install(continuation, token: token)
            }
            XCTFail("未知错误必须 fail closed")
        } catch {
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .itemFailed)
        }
        slot.retire(token)
    }

    func testEightPhysicalSDKCallbackLeasesRejectNinthBeforeSideEffectsAndWaitForLastAlias() throws {
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
        let resourceBaseline = PlaybackResourceContextLedger.shared.chargedBytes
        let player = AVPlayer()
        var driver: SystemAVPlayerDriver? = try SystemAVPlayerDriver.make(player: player)
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch:
            AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_398), itemGeneration: 1)
        try driver!.install(url: URL(string: "http://127.0.0.1:1/callback-lease.m3u8")!, identity: item)
        var leases: [AVPlayerSDKCallbackLease] = []
        for _ in 0..<7 { leases.append(try driver!.reserveSDKCallbackLease(.seek)) }
        var last: AVPlayerSDKCallbackLease? = try driver!.reserveSDKCallbackLease(.accessLog)
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 8 * 1_024 + 8 * 2 * 1_024,
                       "driver core与八个物理SDK callback租约必须分别强持原context escrow")
        for lease in leases + [try XCTUnwrap(last)] {
            lease.inspectAllocations { role, pointer, bytes in
                print("TASK21_OWNER_STORAGE \(role) identity=\(UInt(bitPattern: pointer)) actual=\(bytes)")
            }
        }
        var callback: (@Sendable (Notification) -> Void)? = { [lease = try XCTUnwrap(last)] _ in
            lease.assertRegistered()
        }
        last = nil
        let name = Notification.Name("task21.actual-sdk-callback-lease")
        var observer: (any NSObjectProtocol)? = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: nil, using: try XCTUnwrap(callback))
        let originalEnd = player.currentItem!.forwardPlaybackEndTime
        XCTAssertThrowsError(try driver!.constrainPlaybackEnd(to: Task21Fixtures.time(1), item: item)) {
            XCTAssertEqual($0 as? AVPlayerItemCoordinatorFailure, .capacityExceeded)
        }
        XCTAssertEqual(player.currentItem!.forwardPlaybackEndTime, originalEnd,
                       "第九注册拒绝必须先于原player或旧observer副作用")
        XCTAssertThrowsError(try driver!.reserveSDKCallbackLease(.ready))
        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 8,
                       "callback已执行但SDK/应用仍持原闭包时不能归还")
        leases.removeAll()
        driver!.replaceCurrentItemWithNil(item: item)
        driver = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1,
                       "driver销毁不能重置进程callback物理域")
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 2 * 1_024,
                       "coordinator/driver销毁后最后callback alias仍必须保留原context费用")
        XCTAssertThrowsError(try SystemAVPlayerDriver.make(),
            "原SDK callback只持lease/gate而原driver已销毁时，物理准入仍不可复用")
        NotificationCenter.default.removeObserver(try XCTUnwrap(observer))
        observer = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 1,
                       "取消注册后应用仍持实际原callback别名")
        XCTAssertThrowsError(try SystemAVPlayerDriver.make(), "最后callback别名仍占原准入")
        callback = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, resourceBaseline,
                       "最后SDK callback alias释放才可同时归还局部与全局费用")
        let replacement = try SystemAVPlayerDriver.make()
        for _ in 0..<8 { leases.append(try replacement.reserveSDKCallbackLease(.preroll)) }
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 8)
        leases.removeAll()
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
    }

    func testQueuedHubTailKeepsOriginalDriverAdmissionUntilDeliveryExits() async throws {
        let resourceBaseline = PlaybackResourceContextLedger.shared.chargedBytes
        let invalid = AVPlayer(playerItem: AVPlayerItem(url: URL(string: "http://127.0.0.1:1/invalid-factory.m3u8")!))
        XCTAssertThrowsError(try SystemAVPlayerDriver.make(player: invalid)) {
            XCTAssertEqual($0 as? AVPlayerItemCoordinatorFailure, .staleIdentity)
        }
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, resourceBaseline,
                       "driver factory失败必须归还制造前core escrow")
        let player = AVPlayer()
        var driver: SystemAVPlayerDriver? = try SystemAVPlayerDriver.make(player: player)
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 8 * 1_024,
                       "System driver必须在制造AVPlayer/driver/hub前取得8KiB core escrow")
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch:
            AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_399), itemGeneration: 1)
        try driver!.install(url: URL(string: "http://127.0.0.1:1/queued-hub-tail.m3u8")!, identity: item)
        try driver!.constrainPlaybackEnd(to: Task21Fixtures.time(1), item: item)
        for _ in 0..<256 {
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                object: player.currentItem)
        }
        driver!.replaceCurrentItemWithNil(item: item)
        driver = nil
        XCTAssertEqual(AVPlayerSDKCallbackLease.occupiedCount, 0)
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes,
                       resourceBaseline + 8 * 1_024,
                       "driver销毁后排队hub尾仍须强持同一core charge")
        XCTAssertThrowsError(try SystemAVPlayerDriver.make(),
            "同一MainActor turn尚未出队的原hub尾，不能在driver deinit时释放准入")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, resourceBaseline,
                       "hub最后排队alias退出才可归还core charge")
        let replacement = try SystemAVPlayerDriver.make()
        try replacement.install(url: URL(string: "http://127.0.0.1:1/reused-hub-tail.m3u8")!, identity: item)
        replacement.replaceCurrentItemWithNil(item: item)
        let successor = Task21Fixtures.staleGenerationItem(from: item)
        try replacement.install(url: URL(string: "http://127.0.0.1:1/same-driver-replace.m3u8")!, identity: successor)
        try replacement.constrainPlaybackEnd(to: Task21Fixtures.time(1), item: successor)
        replacement.replaceCurrentItemWithNil(item: successor)
    }

    func testPendingMappingRejectsForeignItemAndURLBeforeInstallingWaiter() async throws {
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch:
            AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_275), itemGeneration: 19)
        let pending = try await Task21RealAACSeed.makePending(outputLifecycleEpoch: item.outputLifecycleEpoch)
        let fixture = try await FinalWriterTerminalHTTPFixture.start(pending: pending, item: item)
        defer { fixture.shutdown() }
        let source = fixture.bundle.evidenceSource
        let gate = AVPlayerPrepareWaitSlot()
        try source.bindPrepareWaitSlot(gate)
        let wrongGeneration = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: item.outputLifecycleEpoch, itemGeneration: 20)
        let wrongEpoch = AVPlayerItemInstanceIdentity(outputLifecycleEpoch:
            AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_274), itemGeneration: 19)
        let foreignURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1/foreign.m3u8"))
        for (candidateItem, candidateURL) in [(wrongGeneration, fixture.bundle.request.itemURL),
                                             (wrongEpoch, fixture.bundle.request.itemURL),
                                             (item, foreignURL)] {
            let finished = FinalLockedFlag()
            let operation = Task {
                defer { finished.set() }
                return try await source.consumePlayerItemTimelineMapping(endpointAuthority: nil,
                    itemURL: candidateURL, item: candidateItem,
                    publicationSequence: fixture.publicationSequence, selection: nil)
            }
            for _ in 0..<128 where !finished.value && !gate.isActive { await Task.yield() }
            XCTAssertFalse(gate.isActive, "外源身份必须在制造 pending/gate 副作用前拒绝")
            operation.cancel()
            do { _ = try await operation.value; XCTFail("外源身份不得成功") }
            catch { XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure, .staleIdentity) }
            XCTAssertNoThrow(try source.bindPrepareWaitSlot(gate))
        }
    }

    func testStorageDriverCancellationRetiresMappingBeforeSlotReuseAndRejectsOldRetry() async throws {
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch:
            AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_276), itemGeneration: 19)
        let pending = try await Task21RealAACSeed.makePending(outputLifecycleEpoch: item.outputLifecycleEpoch)
        let fixture = try await FinalWriterTerminalHTTPFixture.start(pending: pending, item: item)
        defer { fixture.shutdown() }
        let source = fixture.bundle.evidenceSource
        let driver = try SystemAVPlayerDriver.make()
        try driver.install(url: fixture.bundle.request.itemURL, identity: item)
        defer { driver.replaceCurrentItemWithNil(item: item) }
        try source.bindPrepareWaitSlot(driver.prepareWait)
        let old = Task {
            try await source.consumePlayerItemTimelineMapping(endpointAuthority: nil,
                itemURL: fixture.bundle.request.itemURL, item: item,
                publicationSequence: fixture.publicationSequence, selection: nil)
        }
        for _ in 0..<128 where !driver.prepareWait.isActive { await Task.yield() }
        XCTAssertTrue(driver.prepareWait.isActive)
        driver.cancelPendingPrerolls(item: item)
        do { _ = try await old.value; XCTFail("driver取消必须结束mapping") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(old.isCancelled, "本负例不能靠Swift Task.cancel触发onCancel")
        XCTAssertNoThrow(try source.bindPrepareWaitSlot(driver.prepareWait),
            "共享槽退出必须同时退休pending mapping")

        let finished = try await fixture.finishWriter()
        let seed = try finished.sealEndpoint()
        let nextFinished = FinalLockedFlag()
        let next = Task {
            defer { nextFinished.set() }
            return try await source.consumePlayerItemTimelineMapping(endpointAuthority: nil,
                itemURL: fixture.bundle.request.itemURL, item: item,
                publicationSequence: fixture.publicationSequence + 1, selection: nil)
        }
        for _ in 0..<128 where !driver.prepareWait.isActive { await Task.yield() }
        try fixture.publishNaturalEnd(seed: seed)
        try await fixture.serveCompletedPublication()
        XCTAssertFalse(nextFinished.value, "旧publication/selection retry不能完成新阶段")
        driver.cancelPendingPrerolls(item: item)
        do { _ = try await next.value; XCTFail("新mapping仍应独立等待直至取消") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertNoThrow(try source.bindPrepareWaitSlot(driver.prepareWait))
        let selection = try XCTUnwrap(source.currentAudioSelectionCapability(
            itemURL: fixture.bundle.request.itemURL, item: item,
            publicationSequence: fixture.publicationSequence))
        let mapping = try await source.consumePlayerItemTimelineMapping(endpointAuthority: seed.endpointAuthority,
            itemURL: fixture.bundle.request.itemURL, item: item,
            publicationSequence: fixture.publicationSequence, selection: selection)
        XCTAssertNotNil(mapping, "取消后合法新mapping仍可完成")
    }

    func testFinalRegistryCancelPropagatesToInstalledPrepareRunnerTask() async throws {
        let harness = try await Task21Harness()
        let gate = Task21PrepareCancellationGate()
        harness.driver.readyCancellationGate = gate
        let source = try XCTUnwrap(
            harness.graph.registry.outputResourceContextSnapshot()?.sourceTask)
        let prepare = Task { try await harness.prepare() }
        while !gate.started { await Task.yield() }

        XCTAssertTrue(harness.graph.registry.requestCancel(source))
        for _ in 0..<64 where !gate.cancellationObserved { await Task.yield() }
        let cancellationObserved = gate.cancellationObserved
        if !cancellationObserved { gate.releaseForFailedRED() }
        _ = try? await prepare.value
        let terminal = await harness.graph.registry.joinOutputBackendOperation(source)

        XCTAssertTrue(cancellationObserved,
                      "Registry cancelRequested 必须传播到已经登记的唯一 backend runner Task")
        if case .canceled = terminal {} else {
            XCTFail("被 Registry 取消的 runner join 必须返回 canceled 终态")
        }
        XCTAssertFalse(gate.hasWaiter)
    }

    func testReview3CapacityChargesRetainedGraphAndFifthDeadlineFailsClosed() async throws {
        let player = AVPlayer()
        let driver = try SystemAVPlayerDriver.make(player: player)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_300),
            itemGeneration: 1)
        try driver.install(url: URL(string: "http://127.0.0.1:1/review3-capacity.m3u8")!,
                           identity: item)
        player.play()
        try driver.constrainPlaybackEnd(to: Task21Fixtures.time(1), item: item)
        for _ in 0..<4 {
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                            object: player.currentItem)
        }
        for _ in 0..<8 { await Task.yield() }
        let fifth = Task { try await driver.waitUntilPaused(item: item) }
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(driver.fixedTimerCount, 0)
        XCTAssertEqual(driver.activeWaiterCount, 0,
                       "deadline 第五项必须在返回伪 UUID 前显式 capacityExceeded")
        let failedClosed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await fifth.value; return false }
                catch { return error as? AVPlayerItemCoordinatorFailure == .directPauseNotConfirmed }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                return false
            }
            let first = await group.next() ?? false
            fifth.cancel()
            group.cancelAll()
            return first
        }
        XCTAssertTrue(failedClosed, "容量耗尽必须同步返回准确错误，不能留下永久 waiter")
        _ = try? await fifth.value

        let authorityHarness = try await Task21Harness()
        let coordinator = try AVPlayerItemCoordinator(
            driver: Task21FakeDriver(), evidenceSource: authorityHarness.evidence)
        let graphBytes = malloc_size(Unmanaged.passUnretained(coordinator).toOpaque())
        XCTAssertLessThanOrEqual(graphBytes, 2_048,
                                 "完整 retained graph 与所有 backing 必须统一计费")
        driver.replaceCurrentItemWithNil(item: item)
    }

    func testRelaySourceReplacementKeepsPhysicalWakeAndRejectsOldUUID() {
        let relay = AVPlayerCoordinatorEventRelay()
        let oldSource: UInt64 = 1
        let newSource: UInt64 = 2
        relay.activate(oldSource)
        XCTAssertTrue(relay.offerPublication(9, sourceIdentity: oldSource))
        relay.activate(newSource)
        XCTAssertEqual(relay.scheduledDeliveryCount, 1,
                       "换源不能抹除仍在队列中的旧物理唤醒")
        for _ in 0..<256 {
            XCTAssertFalse(relay.offerPublication(999, sourceIdentity: oldSource))
            XCTAssertFalse(relay.offerPublication(11, sourceIdentity: newSource),
                           "原唯一唤醒负责新 pending，不得再排第二个 block")
        }
        let delivered = relay.takePublication(resumingQueued: true)
        XCTAssertEqual(delivered?.sourceIdentity, newSource)
        XCTAssertEqual(delivered?.sequence, 11)
        XCTAssertEqual(relay.scheduledDeliveryCount, 0)
        XCTAssertTrue(relay.offerPublication(12, sourceIdentity: newSource))
        relay.activate(3)
        XCTAssertEqual(relay.scheduledDeliveryCount, 1)
        XCTAssertNil(relay.takePublication(resumingQueued: true))
        XCTAssertEqual(relay.scheduledDeliveryCount, 0,
                       "空 pending 出队仍须准确释放原 queued 授权")
    }

    func testRelaySelectionHandoffPreservesInFlightIdentityAndIndependentWake() async throws {
        let fixture = try await Task21HarnessAuthorityFixture.make(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 53_701),
            audioOnly: true)
        defer { fixture.shutdown() }
        let request = fixture.request
        let selection = try XCTUnwrap(fixture.source.currentAudioSelectionCapability(
            itemURL: request.itemURL, item: request.item,
            publicationSequence: request.publicationSequence))
        let relay = AVPlayerCoordinatorEventRelay()
        let oldSource: UInt64 = 1, newSource: UInt64 = 2
        relay.activate(oldSource)
        XCTAssertTrue(relay.offerSelection(selection, sourceIdentity: oldSource))
        XCTAssertTrue(relay.offerPublication(7, sourceIdentity: oldSource))
        let first = try XCTUnwrap(relay.takeSelection())
        XCTAssertTrue(first.capability === selection)
        XCTAssertEqual(first.sourceIdentity, oldSource)
        XCTAssertEqual(relay.scheduledDeliveryCount, 2,
                       "同步消费 selection 不释放两个独立物理唤醒")
        relay.activate(newSource)
        for _ in 0..<256 {
            XCTAssertFalse(relay.offerSelection(selection, sourceIdentity: oldSource))
            XCTAssertFalse(relay.offerSelection(selection, sourceIdentity: newSource))
        }
        XCTAssertNil(relay.takeSelection(), "旧 selection 在途时不得并行消费后继")
        relay.finishSelection(first.capability)
        let next = try XCTUnwrap(relay.takeSelection(resumingQueued: true))
        XCTAssertTrue(next.capability === selection)
        XCTAssertEqual(next.sourceIdentity, newSource)
        XCTAssertFalse(next.conflicted)
        relay.finishSelection(next.capability)
        XCTAssertEqual(relay.scheduledDeliveryCount, 1)
        XCTAssertNil(relay.takePublication(resumingQueued: true))
        XCTAssertEqual(relay.scheduledDeliveryCount, 0)
        XCTAssertTrue(relay.offerSelection(selection, sourceIdentity: newSource))
        relay.activate(3)
        XCTAssertNil(relay.takeSelection(resumingQueued: true))
        XCTAssertEqual(relay.scheduledDeliveryCount, 0)
    }

    func testQueuedCoordinatorWakeKeepsOriginalDriverAdmissionUntilExit() async throws {
        let fixture = try await Task21HarnessAuthorityFixture.make(
            lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 53_702),
            audioOnly: true)
        defer { fixture.shutdown() }
        let evidence = Task21FakeEvidenceSource(source: fixture.source,
            publicationSequence: fixture.request.publicationSequence)
        var driver: SystemAVPlayerDriver? = try .make()
        var coordinator: AVPlayerItemCoordinator? = try .init(
            driver: try XCTUnwrap(driver), evidenceSource: evidence)
        weak let original = coordinator
        for _ in 0..<256 { evidence.completedRenditions = [.init(rawValue: 2)] }
        coordinator = nil
        driver = nil
        XCTAssertNotNil(original, "原 queued block 延长 coordinator/driver 域而非弱引用丢尾")
        XCTAssertThrowsError(try SystemAVPlayerDriver.make())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(original, "长期 source handler 仍 weak，队列退出后不得形成环")
        let successor = try SystemAVPlayerDriver.make()
        withExtendedLifetime(successor) {}
    }

    func testSynchronousPhaseDrainDoesNotReleasePhysicalQueuedWake() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        for ordinal in 0..<256 {
            harness.evidence.completedRenditions = [.init(rawValue: UInt64(202 + ordinal % 2))]
            _ = harness.coordinator.phase
            XCTAssertEqual(harness.coordinator.additionalTaskCount, 1,
                           "同步读取 phase 只消费事实，不得提前归还队列中的物理唤醒")
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(harness.coordinator.additionalTaskCount, 0)
        try await harness.shutdown()
    }

    func testReview3EOSAndPublicationRelaysCoalesceBurstsWithOneOwnedRunner() async throws {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        for ordinal in 0..<256 {
            harness.evidence.completedRenditions = [
                .init(rawValue: UInt64(202 + ordinal % 2))
            ]
        }

        XCTAssertEqual(harness.coordinator.additionalTaskCount, 1,
                       "publication event 只能唤醒预拥有 drain runner，并准确计一个 pending delivery")
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(harness.coordinator.invalidationCount, 1)
        XCTAssertEqual(harness.coordinator.additionalTaskCount, 0)

        let player = AVPlayer()
        let driver = try SystemAVPlayerDriver.make(player: player)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_400),
            itemGeneration: 1)
        try driver.install(url: URL(string: "http://127.0.0.1:1/review3-relay.m3u8")!, identity: item)
        try driver.constrainPlaybackEnd(to: Task21Fixtures.time(1), item: item)
        for _ in 0..<256 {
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                            object: player.currentItem)
        }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(driver.fixedTimerCount, 0,
                       "EOS burst 只复用 Registry timer，driver 不得持有独立 timer")
        driver.replaceCurrentItemWithNil(item: item)
    }

    func testReview3CoordinatorFailsClosedWhenDriverOmitsSafetyCriticalBehavior() async throws {
        let driver = Task21UnsafeDefaultDriver()
        let backend = Task21RegistryBackend()
        let graph = try OutputGraphFixture(backendObject: backend)
        let authorityFixture = try await Task21HarnessAuthorityFixture.make(
            lifecycle: graph.lifecycle, audioOnly: false)
        defer { authorityFixture.shutdown() }
        let evidence = Task21FakeEvidenceSource(
            source: authorityFixture.source,
            publicationSequence: authorityFixture.request.publicationSequence)
        let coordinator = try AVPlayerItemCoordinator(
            driver: driver, evidenceSource: evidence,
            backendPublicationReplacementAuthoritySlot:
                backend.backendPublicationReplacementAuthoritySlot)
        backend.attach(coordinator)
        let item = authorityFixture.request.item
        backend.configure(identity: graph.lifecycle.backendIdentity,
                          itemGeneration: item.itemGeneration)
        try coordinator.install(authorityFixture.request)
        let source = try XCTUnwrap(graph.registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(graph.registry.startOutputPrepareOperation(source))
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(source) else {
            return XCTFail("准备夹具必须成功")
        }
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(graph.registry.beginOutputActivation(
            contextNonce: context.contextNonce))
        XCTAssertTrue(graph.registry.startOutputActivationOperation(activation))

        if case .succeeded = await graph.registry.joinOutputBackendOperation(activation) {
            XCTFail("缺省 no-op relay/fence/endpoint hook 必须失败闭合")
        }
        XCTAssertEqual(driver.playCallCount, 0)
    }

    func testFinalLiveAACRequiresWriterIssuedRetainedTerminalBindingAndInstallsEOSConstraintAfterFinish()
        async throws {
        let driver = Task21FakeDriver()
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 41_200),
            itemGeneration: 19)
        let pending = try await Task21RealAACSeed.makePending(
            outputLifecycleEpoch: item.outputLifecycleEpoch)
        let terminalBinding = try pending.terminalBinding
        XCTAssertNil(terminalBinding.endpointAuthority,
                     "真实 writer finish 前固定 terminal 槽必须保持 pending")
        let http = try await FinalWriterTerminalHTTPFixture.start(
            pending: pending, item: item)
        defer { http.shutdown() }
        let coordinator = try AVPlayerItemCoordinator(
            driver: driver, evidenceSource: http.bundle.evidenceSource)
        try coordinator.install(http.bundle.request)
        let completion = FinalLockedFlag()
        let preparation = Task { @MainActor in
            defer { completion.set() }
            return try await coordinator.prepareCurrentItem()
        }
        defer { preparation.cancel() }
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertFalse(completion.value,
                       "pending writer 的 prepare 必须停在固定 terminal 槽等待，而不是提前成功")
        XCTAssertEqual(driver.prerollCallCount, 0,
                       "writer 未 finish/HTTP 未复核前不得进入 preroll")
        XCTAssertNil(driver.constrainedPlaybackEnd,
                     "pending writer 可以 prepare，但未 terminal 前不能安装 EOS constraint")

        let finished = try await http.finishWriter()
        XCTAssertNil(terminalBinding.endpointAuthority,
                     "writer terminal 与 endpoint authority 封存必须是两个可验证阶段")
        let seed = try finished.sealEndpoint()
        try http.publishNaturalEnd(seed: seed)
        let endpoint = seed.endpoint
        XCTAssertEqual(endpoint.sampleRate, 48_000)
        XCTAssertEqual(endpoint.totalDecodedFrames, 387_072,
                       "Q 必须来自真实 encoder 解码帧总数")
        XCTAssertEqual(endpoint.leadingFrames, 2_112)
        XCTAssertEqual(endpoint.realSampleCount, 384_000)
        XCTAssertEqual(endpoint.trailingFrames, 960)
        XCTAssertEqual(endpoint.totalDecodedFrames,
                       endpoint.leadingFrames + endpoint.realSampleCount
                           + endpoint.trailingFrames,
                       "writer authority 必须精确冻结 Q=L+N+P")
        XCTAssertEqual(endpoint.inputPhysicalBase,
                       ExactMediaTime(value: 480_000 - 2_112, timescale: 48_000))
        XCTAssertEqual(endpoint.inputEffectiveBase,
                       ExactMediaTime(value: 10, timescale: 1))
        XCTAssertEqual(endpoint.writtenPhysicalBase, endpoint.inputPhysicalBase)
        XCTAssertEqual(endpoint.writtenEffectiveBase,
                       ExactMediaTime(value: 10, timescale: 1))
        XCTAssertEqual(endpoint.lastEffectiveEnd,
                       ExactMediaTime(value: 18, timescale: 1))
        XCTAssertEqual(endpoint.terminalPhysicalEnd,
                       ExactMediaTime(value: 18 * 48_000 + 960, timescale: 48_000))
        XCTAssertEqual(endpoint.firstMedia, seed.endpointAuthority.media.first)
        XCTAssertEqual(endpoint.terminalMedia, seed.endpointAuthority.media.last)
        XCTAssertEqual(endpoint.terminalLogicalSequence,
                       endpoint.terminalMedia.key.logicalSequence)
        XCTAssertTrue(terminalBinding.endpointAuthority === seed.endpointAuthority,
                      "私有 writer issuer 必须只封存同一固定槽 authority")
        XCTAssertFalse(completion.value,
                       "writer terminal 已到但 HTTP terminal tail 未验真时 prepare 仍必须等待")
        try await http.serveCompletedPublication()
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !completion.value && ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completion.value,
                      "固定槽 terminal 通知、HTTP 复核与 endpoint 安装后 prepare 才能恢复")
        guard completion.value else {
            preparation.cancel()
            return
        }
        let prepared = try await preparation.value
        XCTAssertEqual(prepared.item, item,
                       "恢复的 prepare 必须返回同一个 item 的 PreparedPlayheadIdentity")
        let expectedItemEnd = try prepared.identity.timelineMappingAuthority
            .playerItemTime(for: seed.endpoint.lastEffectiveEnd)
        XCTAssertEqual(driver.constrainedPlaybackEnd, expectedItemEnd,
                       "HTTP backing 验真后 coordinator 才能安装真实 AAC EOS constraint")

        // 单独使用一份真实 writer/server authority 证明：server 已有 selection 时，
        // nil expected identity 必须在 endpoint consume 之前立即 invalid。
        let rejectedItem = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 41_201),
            itemGeneration: 19)
        let rejectedPending = try await Task21RealAACSeed.makePending(
            outputLifecycleEpoch: rejectedItem.outputLifecycleEpoch)
        let rejectedHTTP = try await FinalWriterTerminalHTTPFixture.start(
            pending: rejectedPending, item: rejectedItem)
        defer { rejectedHTTP.shutdown() }
        let rejectedFinished = try await rejectedHTTP.finishWriter()
        let rejectedSeed = try rejectedFinished.sealEndpoint()
        try rejectedHTTP.publishNaturalEnd(seed: rejectedSeed)
        try await rejectedHTTP.serveCompletedPublication()
        let rejectedCapability = try XCTUnwrap(
            rejectedHTTP.server.completedPublicationCapability(
                itemURL: rejectedHTTP.bundle.request.itemURL,
                itemGeneration: rejectedItem.itemGeneration,
                publicationSequence: rejectedHTTP.publicationSequence))
        let rejectedEvidence = try XCTUnwrap(
            rejectedHTTP.server.consumeCompletedPublicationCapability(rejectedCapability))
        switch try rejectedHTTP.server.makePlayerItemTimelineMappingAuthority(
            endpointAuthority: rejectedSeed.endpointAuthority,
            completedPublication: rejectedEvidence,
            itemURL: rejectedHTTP.bundle.request.itemURL,
            item: rejectedItem,
            publicationSequence: rejectedHTTP.publicationSequence,
            expectedSelection: nil) {
        case .invalid:
            break
        case .waitingForSelection, .ready:
            XCTFail("nil-existing selection 必须立即 invalid")
        }
        XCTAssertTrue(rejectedSeed.endpointAuthority.consume(),
                      "invalid selection admission 绝不能提前消费 endpoint authority")
    }

    func testAACRenditionPrefixPreparesCoordinatorBeforeWriterEOS() async throws {
        let driver = Task21FakeDriver()
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 41_250),
            itemGeneration: 19)
        let pending = try await Task21RealAACSeed.makePending(
            outputLifecycleEpoch: item.outputLifecycleEpoch)
        XCTAssertNotNil(pending.writer.aacTerminalBinding?.timelineMappingReceipt)
        XCTAssertNotNil(pending.writer.aacRenditionTerminalBinding)
        let http = try await FinalWriterTerminalHTTPFixture.startPrefix(
            pending: pending, item: item)
        defer { http.shutdown(); _ = pending.writer.cancel() }
        try await http.serveCurrentPublication()
        XCTAssertNil(pending.writer.aacRenditionTerminalBinding?.finalWriterReceipt,
                     "prefix准备时writer尚未EOS")
        let coordinator = try AVPlayerItemCoordinator(
            driver: driver, evidenceSource: http.bundle.evidenceSource)
        try coordinator.install(http.bundle.request)
        let prepared = try await coordinator.prepareCurrentItem()
        XCTAssertEqual(prepared.item, item)
        XCTAssertEqual(driver.prerollCallCount, 1)
        XCTAssertNil(driver.constrainedPlaybackEnd,
                     "prefix只能启动播放，不能伪装final endpoint")

        let timeline = prepared.identity.timelineMappingAuthority
        let offset = try timeline.writtenEffectiveBase.subtracting(
            timeline.writtenPhysicalBase)
        XCTAssertGreaterThan(offset.value, 0, "本回归必须使用非零leading trim")
        let effectiveEdge = try FMP4PresentationRange(
            start: timeline.effectivePlaybackHorizon.subtracting(
                prepared.minimumCoverageDuration),
            duration: prepared.minimumCoverageDuration)
        let physicalEdge = try FMP4PresentationRange(
            start: effectiveEdge.start.subtracting(offset),
            duration: effectiveEdge.duration)
        let observed = ObservedRenditionSetReceipt(
            preparedPlayheadIdentity: prepared.identity,
            selectionFenceRevision: 41_251,
            orderedRenditionIdentities: [pending.writer.binding.renditionIdentity])
        let coverageContext = LoopbackCoverageContext(
            preparedPlayheadIdentity: prepared.identity,
            observedRenditionSetReceipt: observed,
            renditionIdentity: pending.writer.binding.renditionIdentity)
        let evidence = try XCTUnwrap(
            http.bundle.evidenceSource.retainedCompletedPublicationEvidence())
        let wrongDomain = try XCTUnwrap(
            http.publication.store.preparationCoverageReceipt(
            owner: evidence.preparationOwner, context: coverageContext,
            requested: effectiveEdge))
        XCTAssertEqual(wrongDomain.presentationRange, effectiveEdge,
                       "夹具必须真实复现相邻段会让错误域偶然通过的审查场景")
        let verified = try XCTUnwrap(http.server.verifiedAVPlayerCoverage(
            using: evidence, context: coverageContext, requested: effectiveEdge))
        XCTAssertEqual(verified.physicalReceipt.presentationRange, physicalEdge,
                       "prefix coverage必须把有效边沿精确换算回物理decode-map边沿")
        XCTAssertNotEqual(verified.physicalReceipt.presentationRange, effectiveEdge,
                          "生产验真不得返回靠相邻段过覆盖的错误域receipt")
        XCTAssertNotEqual(verified.physicalReceipt.presentationRange,
                          wrongDomain.presentationRange)
    }

    func testFinalEOSRequiresTwoStableDirectReadsAndRetiresOnTrimMutationTimeoutOrEndpointMismatch()
        async throws {
        // 并发阶段只预热不可变的压缩 bytes/format/timing。Registry graph、writer
        // binding、finish、endpoint seal、publisher、server 与 player 都在每个场景
        // 内 JIT 创建，且每个 writer 从模板重建独立 CMSampleBuffer。
        try await Task21RealAACSeed.warmEncodingTemplate()
        XCTAssertEqual(
            try ExactMediaTime(value: 1, timescale: 1_200_000_000).adding(
                ExactMediaTime(value: 1, timescale: 2_000_000_000)),
            ExactMediaTime(value: 1, timescale: 750_000_000),
            "中间 LCM 超过 Int32、最终可约分的精确时间仍必须可表示")
        XCTAssertEqual(
            try ExactMediaTime(value: Int64.max, timescale: 2).adding(
                ExactMediaTime(value: Int64.max, timescale: 2)),
            ExactMediaTime(value: Int64.max, timescale: 1),
            "中间分子超过 Int64、最终可约分的结果仍必须可表示")
        XCTAssertEqual(
            try ExactMediaTime(value: -1, timescale: 3).adding(
                ExactMediaTime(value: 1, timescale: 6)),
            ExactMediaTime(value: -1, timescale: 6))
        XCTAssertEqual(
            try ExactMediaTime(value: Int64.min, timescale: 1).adding(
                ExactMediaTime(value: 0, timescale: 1)),
            ExactMediaTime(value: Int64.min, timescale: 1))
        XCTAssertEqual(
            try ExactMediaTime(value: -Int64.max, timescale: 2).adding(
                ExactMediaTime(value: -Int64.max, timescale: 2)),
            ExactMediaTime(value: -Int64.max, timescale: 1),
            "负分子的 full-width carry 也必须在最终约分后收窄")
        XCTAssertEqual(
            try ExactMediaTime(value: Int64.min + 1, timescale: 1).subtracting(
                ExactMediaTime(value: 1, timescale: 1)),
            ExactMediaTime(value: Int64.min, timescale: 1))
        XCTAssertEqual(
            try ExactMediaTime(value: 1, timescale: Int32.max).adding(
                ExactMediaTime(value: 1, timescale: Int32.max)),
            ExactMediaTime(value: 2, timescale: Int32.max),
            "相同最大 timescale 不得被误判为 overflow")
        XCTAssertThrowsError(
            try ExactMediaTime(value: Int64.max, timescale: 1).adding(
                ExactMediaTime(value: 1, timescale: 1))
        ) { error in
            XCTAssertEqual(error as? HLSTimelineError, .arithmeticOverflow,
                           "最终分子不可表示时必须继续 fail-closed")
        }
        XCTAssertThrowsError(
            try ExactMediaTime(value: 0, timescale: 1).subtracting(
                ExactMediaTime(value: Int64.min, timescale: 1))
        ) { error in
            XCTAssertEqual(error as? HLSTimelineError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(
            try ExactMediaTime(value: Int64.min, timescale: 1).subtracting(
                ExactMediaTime(value: 1, timescale: 1))
        ) { error in
            XCTAssertEqual(error as? HLSTimelineError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(
            try ExactMediaTime(value: 1, timescale: Int32.max).adding(
                ExactMediaTime(value: 1, timescale: Int32.max - 1))
        ) { error in
            XCTAssertEqual(error as? HLSTimelineError, .arithmeticOverflow,
                           "最终分母仍超过 Int32 时必须继续 fail-closed")
        }
        var writerBindings = Set<FMP4WriterBinding>()
        var endpointIdentities = Set<ObjectIdentifier>()
        func assertIndependentAuthority(_ fixture: Task21RealIntegrationFixture) {
            XCTAssertTrue(writerBindings.insert(fixture.writerBinding).inserted,
                          "六个 EOS 场景必须各自签发独立 writer binding")
            XCTAssertTrue(endpointIdentities.insert(fixture.endpointAuthorityIdentity).inserted,
                          "六个 EOS 场景必须各自签发独立 endpoint authority")
            XCTAssertTrue(fixture.endpointAuthorityRejectsReplay,
                          "prepare 消费 endpoint 后，同一 authority 必须拒绝第二次消费")
        }

        // 此 selector 验证 Driver 的自然 EOS 两次 direct read；夹具不应先被
        // publication naturalEnd 的独立 identity 合同截断。
        do {
            try await withFinalEOSFixture { success in
                assertIndependentAuthority(success)
                let playback = try await success.playToEnd()
                XCTAssertTrue(playback.didReachStableEnd,
                              "正路径必须由真实 AVPlayer 播放到自然 EOS，且通知后播放头保持稳定")
                XCTAssertGreaterThanOrEqual(playback.presentedEnd, playback.endpointEnd,
                                            "系统 currentTime 可稳定越过有效 N，但不能早于 N")
                XCTAssertEqual(success.naturalEndObservation?.expectedEndpoint,
                               try success.endpointItemTime,
                               "driver terminal 必须绑定 writer 映射后的精确 item endpoint")
                XCTAssertEqual(success.naturalEndObservation?.constrainedEndpoint,
                               try success.endpointItemTime,
                               "两次 direct read 中精确不变的是已安装的 forwardPlaybackEndTime")
                XCTAssertNotNil(success.naturalEndObservation?.stableCurrentTime,
                                "系统 EOS 事件后必须完成两次稳定 currentTime direct read")
            }
        }
        // 这里是对已安装 item end constraint 的 ±1 sample 故障注入，用来验证
        // driver fail-closed；Task18 writer trim 本身由 endpoint receipt 的整数合同证明。
        let endpointMutations: [(String, Int64)] = [
            ("endpoint -1 sample", -1),
            ("endpoint +1 sample", 1),
        ]
        for (label, sampleDelta) in endpointMutations {
            try await withFinalEOSFixture { fixture in
                assertIndependentAuthority(fixture)
                try await fixture.activateForFinalEOSProbe()
                let delta = ExactMediaTime(value: sampleDelta, timescale: 48_000)
                let sourceTime = try fixture.endpointSourceTime.adding(delta)
                try await fixture.emitConstrainedEndpointMutation(sourceTime: sourceTime)
                let didRetire = await fixture.waitForRegisteredSuspend()
                XCTAssertTrue(didRetire,
                              "\(label) 必须撤销 permit/publication 并登记 Registry stop")
                XCTAssertEqual(fixture.backendRetireCount, 1,
                               "\(label) 必须由 Registry 单飞 retirement 收敛")
                XCTAssertEqual(fixture.coordinatorPhase, .stopping)
            }
        }

        try await withFinalEOSFixture { early in
            assertIndependentAuthority(early)
            try await early.activateForFinalEOSProbe()
            try await early.emitPrematureFinalEOS(
                sourceTime: early.endpointSourceTime.subtracting(Task21Fixtures.time(0.25)))
            let didRetireEarly = await early.waitForRegisteredSuspend()
            XCTAssertTrue(didRetireEarly,
                          "提前非最终 buffer 必须撤销 permit/publication 并登记 Registry stop")
            XCTAssertEqual(early.backendRetireCount, 1)
            XCTAssertEqual(early.coordinatorPhase, .stopping)
        }

        try await withFinalEOSFixture { unstable in
            assertIndependentAuthority(unstable)
            try await unstable.activateForFinalEOSProbe()
            try await unstable.emitUnstableFinalEOS(
                firstSourceTime: unstable.endpointSourceTime.subtracting(
                    Task21Fixtures.time(0.25)),
                secondSourceTime: unstable.endpointSourceTime.subtracting(
                    Task21Fixtures.time(0.125)))
            let didRetireUnstable = await unstable.waitForRegisteredSuspend()
            XCTAssertTrue(didRetireUnstable,
                          "两次 direct read 变化必须撤 publication/permit 并登记 Registry stop")
            XCTAssertEqual(unstable.backendRetireCount, 1)
            XCTAssertEqual(unstable.coordinatorPhase, .stopping)
        }

        try await withFinalEOSFixture { timedOut in
            assertIndependentAuthority(timedOut)
            try await timedOut.activateForFinalEOSProbe()
            try await timedOut.emitTimedOutFinalEOS(sourceTime: timedOut.endpointSourceTime)
            let didRetireTimedOut = await timedOut.waitForRegisteredSuspend()
            XCTAssertTrue(didRetireTimedOut,
                          "稳定读取 deadline 到期仍无同值 second read 时必须撤 publication/permit 并 stop")
            XCTAssertEqual(timedOut.backendRetireCount, 1)
            XCTAssertEqual(timedOut.coordinatorPhase, .stopping)
        }
        XCTAssertEqual(writerBindings.count, 6)
        XCTAssertEqual(endpointIdentities.count, 6)
    }

    func testFinalRetainedGraphAndFourSlotSchedulerEnforceExactCapacityAndExplicitSafetyConformance()
        async throws {
        func objectBytes(_ type: AnyClass) -> Int {
            malloc_good_size(class_getInstanceSize(type))
        }
        XCTAssertEqual(AVPlayerCoordinatorEventRelay.retainedLockObjectBytes,
                       malloc_good_size(class_getInstanceSize(NSLock.self)),
                       "relay必须使用应用直接持有且可公开识别的NSLock对象")
        XCTAssertGreaterThanOrEqual(
            ControlTaskRegistry.ownedControlAllocationReservation.backendAndCleanupRunnerObjects,
            2 * objectBytes(OwnedPlaybackBackendOperation.self)
                + 2 * objectBytes(OwnedPlaybackCleanupTask.self)
                + 2 * objectBytes(ControlTaskRegistry.BackendPublicationReplacementAuthority.self),
            "Registry 原新 replacement authority 交叠必须有真实预留；消费同步复用原 Cell")
        do {
        let rootHarness = try await Task21Harness()
        let rootCoordinator = rootHarness.coordinator
        let rootRoundedBytes = malloc_good_size(
            class_getInstanceSize(type(of: rootCoordinator)))
        let productionReservation = rootCoordinator.retainedGraphCapacitySnapshot
        XCTAssertNil(productionReservation.coordinatorObjectIdentity,
                     "coordinator根已唯一归resource-context，不得重复塞回2KiB HLS state")
        XCTAssertEqual(productionReservation.coordinatorObjectBytes, 0)
        XCTAssertEqual(productionReservation.coordinatorReservationCount, 0)
        XCTAssertLessThanOrEqual(productionReservation.applicationChargeableBytes,
                                 AVPlayerRetainedGraphCapacityLedger.maximumBytes)
        let futureReservation = AVPlayerItemCoordinator
            .retainedGraphFutureReservationSnapshot
        XCTAssertEqual(futureReservation.installedMaximumBranchBytes,
            futureReservation.stopTaskBytes + max(
                futureReservation.positiveRateCapabilityBytes,
                futureReservation.receiptIdentityBytes
                    + futureReservation.retiredFenceBytes),
            "install 必须预留 stop 与真实互斥尾的最大分支，不得重复相加")
        XCTAssertEqual(productionReservation.applicationChargeableBytes,
                       futureReservation.installedMaximumBranchBytes)
        XCTAssertEqual(productionReservation.allocationIdentityCount, 2,
                       "HLS state只保留stop与互斥终态最大分支；资源根由独立context计费")
        let graphAttachment = XCTAttachment(string:
            "coordinatorResourceRoot=\(rootRoundedBytes), installedHLSState="
                + "\(productionReservation.applicationChargeableBytes), identities="
                + "\(productionReservation.allocationIdentityCount), capability="
                + "\(futureReservation.positiveRateCapabilityBytes), stop="
                + "\(futureReservation.stopTaskBytes), receipt="
                + "\(futureReservation.receiptIdentityBytes), fence="
                + "\(futureReservation.retiredFenceBytes), maxFuture="
                + "\(futureReservation.installedMaximumBranchBytes), replacementAuthority="
                + "\(objectBytes(ControlTaskRegistry.BackendPublicationReplacementAuthority.self)), slot="
                + "\(objectBytes(ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot.self)), owned="
                + "\(ControlTaskRegistry.ownedControlAllocationReservation.total)")
        graphAttachment.lifetime = .keepAlways
        add(graphAttachment)
        var rootLedger = AVPlayerRetainedGraphCapacityLedger()
        XCTAssertNoThrow(try rootLedger.reserve(
            allocationIdentity: .nativeBacking(91),
            allocatorRoundedBytes: rootRoundedBytes),
            "独立账本仍须按同一HLS allocation identity去重")
        XCTAssertNoThrow(try rootLedger.reserve(
            allocationIdentity: .nativeBacking(91),
            allocatorRoundedBytes: rootRoundedBytes),
            "同一HLS identity重复出现时必须恰好计费一次")
        XCTAssertEqual(rootLedger.applicationChargeableBytes, rootRoundedBytes)
        XCTAssertLessThanOrEqual(
            malloc_good_size(class_getInstanceSize(OutputPlayerStopTask.self)), 128,
            "stop single-flight 只能保存紧凑 identity 与一个 continuation，不能复制完整 receipt")

        let sideEffectDriver = Task21FakeDriver()
        let sideEffectCoordinator = try AVPlayerItemCoordinator(
            driver: sideEffectDriver, evidenceSource: rootHarness.evidence)
        let oversizedURL = try XCTUnwrap(URL(string:
            "http://127.0.0.1:49152/\(String(repeating: "x", count: 2_049)).m3u8"))
        let oversizedRequest = AVPlayerItemPreparationRequest(
            itemURL: oversizedURL, item: rootHarness.item, publicationSequence: 1,
            audioParticipants: [
                .init(renditionIdentity: .init(rawValue: 2), codec: .explicitlyNonAAC)
            ], directAudioOnlyRendition: nil)
        XCTAssertNoThrow(try sideEffectCoordinator.install(oversizedRequest),
                         "长URL属于resource-context包络，不得继续受2KiB HLS state误拒绝")
        XCTAssertFalse(sideEffectDriver.operations.isEmpty)

        let exactRounded = malloc_good_size(2_048)
        XCTAssertEqual(exactRounded, 2_048,
                       "当前 tvOS allocator 的 2KiB 边界必须精确可表示")
        var exactLedger = AVPlayerRetainedGraphCapacityLedger()
        XCTAssertNoThrow(try exactLedger.reserve(
            allocationIdentity: .nativeBacking(1),
            allocatorRoundedBytes: exactRounded))
        XCTAssertNoThrow(try exactLedger.reserve(
            allocationIdentity: .nativeBacking(1),
            allocatorRoundedBytes: exactRounded),
            "同一实际 backing alias 不得重复计费")
        XCTAssertEqual(exactLedger.applicationChargeableBytes, 2_048)

        let aboveRounded = malloc_good_size(2_049)
        XCTAssertGreaterThan(aboveRounded, 2_048)
        var aboveLedger = AVPlayerRetainedGraphCapacityLedger()
        XCTAssertThrowsError(try aboveLedger.reserve(
            allocationIdentity: .nativeBacking(2),
            allocatorRoundedBytes: aboveRounded)) { error in
            XCTAssertEqual(error as? AVPlayerItemCoordinatorFailure,
                           .capacityExceeded,
                           "allocator-rounded cap+1 必须在 retained graph 准入时拒绝")
        }
        try await rootHarness.shutdown()
        }
        do {
            let harness = try await Task21Harness(
                liveEdge: 7,
                boundaries: (0..<128).map { Double($0) / 48_000.0 })
            _ = try await harness.prepare()
            _ = try await harness.activate()
            let positiveRateInvocation = try XCTUnwrap(
                harness.driver.lastPositiveRateInvocation)
            XCTAssertNotNil(positiveRateInvocation.currentSnapshot,
                            "开放 interval 时必须能从原 Registry 原子读取当前快照")
            _ = try await harness.stop()
            XCTAssertNil(positiveRateInvocation.currentSnapshot,
                         "interval 关闭后快照必须安全失败，不能返回已撤销完整身份或崩溃")
            XCTAssertFalse(positiveRateInvocation.revalidateCurrentAuthority(),
                           "冻结身份只供 stop 验真，不能在 Registry 关闭后复活正 rate 权威")
            let stoppedReservation = harness.coordinator.retainedGraphCapacitySnapshot
            add(XCTAttachment(string:
                "stoppedGraph=\(stoppedReservation.applicationChargeableBytes), identities="
                    + "\(stoppedReservation.allocationIdentityCount)"))
            XCTAssertLessThanOrEqual(
                stoppedReservation.applicationChargeableBytes,
                AVPlayerRetainedGraphCapacityLedger.maximumBytes,
                "stop terminal 与 receipt identity 加入同一本账后仍必须处于2KiB内")
            try await harness.shutdown()
        } catch {
            XCTFail("retained graph 夹具不应阻断后续 scheduler/runner 子场景：\(error)")
        }

        try await verifyFinalSchedulerAndPublicationRunnerCapacity()
    }
}

@MainActor
private func verifyFinalSchedulerAndPublicationRunnerCapacity() async throws {
    let slot = AVPlayerPrepareWaitSlot()
    let token = try slot.begin(.ready)
    XCTAssertThrowsError(try slot.begin(.loaded))
    slot.cancelCurrent()
    slot.retire(token)
    XCTAssertFalse(slot.isActive)

    do {
        let harness = try await Task21Harness()
        _ = try await harness.prepare()
        for ordinal in 0..<256 {
            harness.evidence.completedRenditions = [
                .init(rawValue: UInt64(202 + ordinal % 2))
            ]
        }
        XCTAssertEqual(harness.coordinator.additionalTaskCount, 1,
                       "publication burst 只能由一个预拥有 runner drain")
        try await harness.shutdown()
    } catch {
        XCTFail("publication runner 子场景必须独立于 graph/scheduler：\(error)")
    }
}

@MainActor
private func Task21TriggerTimeControlKVO(_ player: AVPlayer, count: Int) {
    for _ in 0..<count {
        player.willChangeValue(forKey: "timeControlStatus")
        player.didChangeValue(forKey: "timeControlStatus")
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    verify: ((Error) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("预期抛出错误。\(message)", file: file, line: line)
    } catch {
        verify?(error)
    }
}

private enum Task21PrepareMutation: CaseIterable {
    case none, noCommonBoundary, shortCoverage, missingRendition, headOnly, incompleteBody
    case wrongDigest, wrongLifecycle, wrongItemGeneration, wrongMediaEpoch
    case seekBeforeOneTick, seekAfterOneTick, loadedStartAfterOneTick, loadedEndBeforeOneTick
    case exactBoundaries, stalePreroll, readyTimeout, loadedTimeout, prerollTimeout

}

private enum Task21DriverOperation: Equatable {
    case install, seek, preroll, play, cancelPrerolls, pause, readPausedState, replaceNil, removeObservers
}

@MainActor
private final class Task21FakeDriver: AVPlayerDriving {
    var rate: Float = 0
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var automaticallyWaitsToMinimizeStalling = false
    var preferredForwardBufferDuration: TimeInterval = 0
    var canUseNetworkResourcesForLiveStreamingWhilePaused = false
    var currentItemIdentity: AVPlayerItemInstanceIdentity?
    var loadedRange = try! FMP4PresentationRange(start: Task21Fixtures.time(4),
                                                  duration: Task21Fixtures.time(4))
    var loadedRangesOverride: [FMP4PresentationRange]?
    var returnAdjacentLoadedRangeFragments = false
    var returnGappedLoadedRangeFragments = false
    var stateAfterPreroll: AVPlayerDirectState?
    var prepareMutation: Task21PrepareMutation = .none
    var conflictingRenditionFence: AVPlayerPreparationFence?
    var conflictHandler: (() -> Void)?
    var operations: [Task21DriverOperation] = []
    var observedPlayheads: [PreparedPlayheadIdentity] = []
    var playCallCount = 0
    var pauseCallCount = 0
    var prerollCallCount = 0
    var manualLatencyShiftCallCount = 0
    var requestedSeekTime: ExactMediaTime?
    var constrainedPlaybackEnd: ExactMediaTime?
    var holdPlayCompletion = false
    var holdDirectPausedRead = false
    var beforePositiveRateSideEffect: ((ControlTaskRegistry.BackendPositiveRateInvocation) -> Void)?
    var afterPositiveRateCapabilityConsumeBeforeSideEffect: ((
        ControlTaskRegistry.BackendPositiveRateInvocation
    ) -> Void)?
    private(set) var lastPositiveRateInvocation:
        ControlTaskRegistry.BackendPositiveRateInvocation?
    var directStateOverride: AVPlayerDirectState?
    var directFailure: AVPlayerItemCoordinatorFailure?
    var loadedReceiptMutation: Int = 0
    var pauseLeavesWaiting = false
    var readyCancellationGate: Task21PrepareCancellationGate?
    private var timeControlHandler: (@MainActor @Sendable (
        AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch
    ) -> Void)?
    private var timeControlActivation: ActivationEpoch?
    private var playContinuation: CheckedContinuation<Void, Never>?
    private var pausedReadContinuation: CheckedContinuation<AVPlayerDirectState, Never>?
    private var pausedStatusContinuation: CheckedContinuation<Void, Error>?

    func install(url: URL, identity: AVPlayerItemInstanceIdentity) throws {
        currentItemIdentity = identity
        rate = 0
        timeControlStatus = .paused
        automaticallyWaitsToMinimizeStalling = true
        preferredForwardBufferDuration = 3
        canUseNetworkResourcesForLiveStreamingWhilePaused = true
        operations.append(.install)
    }

    func waitUntilReady(item: AVPlayerItemInstanceIdentity) async throws -> AVPlayerItemInstanceIdentity {
        if let readyCancellationGate {
            try await readyCancellationGate.wait()
        }
        if prepareMutation == .readyTimeout {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        return prepareMutation == .wrongLifecycle ? Task21Fixtures.staleLifecycleItem(from: item)
            : prepareMutation == .wrongItemGeneration ? Task21Fixtures.staleGenerationItem(from: item)
            : item
    }

    func seek(to time: ExactMediaTime, item: AVPlayerItemInstanceIdentity,
              playhead: PreparedPlayheadIdentity) async throws -> AVPlayerSeekReceipt {
        operations.append(.seek); requestedSeekTime = time; observedPlayheads.append(playhead)
        let tick = ExactMediaTime(value: 1, timescale: 48_000)
        let actual: ExactMediaTime
        switch prepareMutation {
        case .seekBeforeOneTick: actual = try time.subtracting(tick)
        case .seekAfterOneTick: actual = try time.adding(tick)
        default: actual = time
        }
        return AVPlayerSeekReceipt(item: item, playhead: playhead, actualTime: actual)
    }

    func waitForLoadedTimeRanges(item: AVPlayerItemInstanceIdentity,
                                 playhead: PreparedPlayheadIdentity,
                                 covering requested: FMP4PresentationRange) async throws
        -> AVPlayerLoadedRangeReceipt {
        let ranges = try loadedRanges(playhead: playhead, requested: requested).map {
            CMTimeRange(start: $0.start.cmTime, duration: $0.duration.cmTime)
        }
        let result = ranges.withUnsafeBufferPointer {
            VPScanLoadedRangeBuffer($0.baseAddress, $0.count,
                CMTimeRange(start: requested.start.cmTime, duration: requested.duration.cmTime))
        }
        guard result.code == 0 else { throw AVPlayerItemCoordinatorFailure.loadedRangeMismatch }
        let modifiedPlayhead = PreparedPlayheadIdentity(
            outputLifecycleEpoch: playhead.outputLifecycleEpoch,
            itemGeneration: playhead.itemGeneration + (loadedReceiptMutation == 3 ? 1 : 0),
            publicationSequence: playhead.publicationSequence + (loadedReceiptMutation == 4 ? 1 : 0),
            mediaTime: loadedReceiptMutation == 5 ? try playhead.mediaTime.adding(Task21Fixtures.time(1)) : playhead.mediaTime,
            playerItemTime: loadedReceiptMutation == 6 ? try playhead.playerItemTime.adding(Task21Fixtures.time(1)) : playhead.playerItemTime,
            seekNonce: playhead.seekNonce + (loadedReceiptMutation == 7 ? 1 : 0),
            renditionSelectionSlotNonce: playhead.renditionSelectionSlotNonce + (loadedReceiptMutation == 8 ? 1 : 0),
            audioSelectionCapability: playhead.audioSelectionCapability,
            timelineMappingAuthority: playhead.timelineMappingAuthority)
        return .init(item: loadedReceiptMutation == 1
            ? .init(outputLifecycleEpoch: item.outputLifecycleEpoch, itemGeneration: item.itemGeneration + 1) : item,
            playhead: modifiedPlayhead,
            requested: loadedReceiptMutation == 2
                ? try FMP4PresentationRange(start: requested.start, duration: Task21Fixtures.time(4)) : requested)
    }

    private func loadedRanges(playhead: PreparedPlayheadIdentity,
                              requested: FMP4PresentationRange) throws
        -> [FMP4PresentationRange] {
        observedPlayheads.append(playhead)
        if prepareMutation == .loadedTimeout {
            throw AVPlayerItemCoordinatorFailure.loadedRangeMismatch
        }
        if let loadedRangesOverride { return loadedRangesOverride }
        if returnGappedLoadedRangeFragments {
            return [
                try FMP4PresentationRange(start: requested.start, duration: Task21Fixtures.time(1)),
                try FMP4PresentationRange(start: requested.start.adding(Task21Fixtures.time(2)),
                                         duration: Task21Fixtures.time(1)),
            ]
        }
        if returnAdjacentLoadedRangeFragments {
            let half = ExactMediaTime(value: 3, timescale: 2)
            return [
                try FMP4PresentationRange(start: requested.start, duration: half),
                try FMP4PresentationRange(
                    start: requested.start.adding(half), duration: half),
            ]
        }
        let tick = ExactMediaTime(value: 1, timescale: 48_000)
        switch prepareMutation {
        case .loadedStartAfterOneTick:
            return [try FMP4PresentationRange(start: try playhead.playerItemTime.adding(tick),
                                               duration: Task21Fixtures.time(3))]
        case .loadedEndBeforeOneTick:
            return [try FMP4PresentationRange(start: playhead.playerItemTime,
                duration: try Task21Fixtures.time(3).subtracting(tick))]
        default:
            return [try FMP4PresentationRange(start: playhead.playerItemTime,
                                               duration: Task21Fixtures.time(3))]
        }
    }

    func preroll(item: AVPlayerItemInstanceIdentity,
                 playhead: PreparedPlayheadIdentity) async throws -> AVPlayerPrerollReceipt {
        operations.append(.preroll); prerollCallCount += 1; observedPlayheads.append(playhead)
        if prepareMutation == .prerollTimeout {
            throw AVPlayerItemCoordinatorFailure.prerollFailed
        }
        if let stateAfterPreroll {
            rate = stateAfterPreroll.rate
            timeControlStatus = stateAfterPreroll.timeControlStatus
            currentItemIdentity = stateAfterPreroll.item
        }
        return AVPlayerPrerollReceipt(
            item: prepareMutation == .stalePreroll
                ? Task21Fixtures.staleGenerationItem(from: item) : item,
            playhead: playhead,
            succeeded: true
        )
    }

    func play(invocation: ControlTaskRegistry.BackendPositiveRateInvocation,
              item: AVPlayerItemInstanceIdentity) async throws {
        lastPositiveRateInvocation = invocation
        guard currentItemIdentity == item,
              let snapshot = invocation.currentSnapshot,
              snapshot.interval.outputLifecycle == item.outputLifecycleEpoch,
              snapshot.interval.itemGeneration == item.itemGeneration else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        beforePositiveRateSideEffect?(invocation)
        // Review3 的旧“consume 后插入”钩子现在只能在原子入口之前运行；
        // 一旦进入 Registry safety cell，调用方再无可插入窗口。
        afterPositiveRateCapabilityConsumeBeforeSideEffect?(invocation)
        guard invocation.performPositiveRateSideEffect({
            operations.append(.play); playCallCount += 1
            rate = 1; timeControlStatus = .waitingToPlayAtSpecifiedRate
        }) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        if holdPlayCompletion {
            await withCheckedContinuation { playContinuation = $0 }
        }
    }

    func cancelPendingPrerolls(item: AVPlayerItemInstanceIdentity) {
        operations.append(.cancelPrerolls)
    }

    func pause(item: AVPlayerItemInstanceIdentity) {
        operations.append(.pause); pauseCallCount += 1
        rate = 0
        timeControlStatus = pauseLeavesWaiting ? .waitingToPlayAtSpecifiedRate : .paused
    }

    func directState(item: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) -> AVPlayerDirectState {
        operations.append(.readPausedState)
        if let directFailure { throw directFailure }
        if holdDirectPausedRead {
            return await withCheckedContinuation { pausedReadContinuation = $0 }
        }
        if let directStateOverride { return directStateOverride }
        guard let currentItemIdentity else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        return AVPlayerDirectState(item: currentItemIdentity, rate: rate,
                                   timeControlStatus: timeControlStatus)
    }

    func waitUntilPaused(item: AVPlayerItemInstanceIdentity) async throws {
        guard currentItemIdentity == item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        if timeControlStatus == .paused { return }
        try await withCheckedThrowingContinuation { pausedStatusContinuation = $0 }
    }

    func replaceCurrentItemWithNil(item: AVPlayerItemInstanceIdentity) {
        operations.append(.replaceNil)
        if currentItemIdentity == item { currentItemIdentity = nil }
    }

    func removeObservers(item: AVPlayerItemInstanceIdentity) {
        operations.append(.removeObservers)
    }

    func preparationFenceReached(_ fence: AVPlayerPreparationFence,
                                 item: AVPlayerItemInstanceIdentity) {
        if conflictingRenditionFence == fence { conflictHandler?() }
    }

    func installTimeControlStatusRelay(
        item: AVPlayerItemInstanceIdentity,
        activation: ActivationEpoch,
        handler: @escaping @MainActor @Sendable (
            AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch
        ) -> Void
    ) throws {
        guard currentItemIdentity == item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        timeControlActivation = activation
        timeControlHandler = handler
    }

    func installAccessLogURIObservation(
        item: AVPlayerItemInstanceIdentity,
        classify: @escaping @Sendable (URL) -> AccessLogURIClassification,
        handler: @escaping @MainActor @Sendable (AccessLogURIClassification, AVPlayerItemInstanceIdentity) -> Void
    ) throws {}

    func constrainPlaybackEnd(to time: ExactMediaTime,
                              item: AVPlayerItemInstanceIdentity) throws {
        guard currentItemIdentity == item else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        constrainedPlaybackEnd = time
    }

    func installNaturalEndTerminalHandler(
        item: AVPlayerItemInstanceIdentity,
        handler: @escaping @MainActor @Sendable (
            AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity
        ) -> Void
    ) throws { _ = handler }

    func consumeNaturalEndTerminal(
        _ capability: AVPlayerNaturalEndTerminalCapability,
        item: AVPlayerItemInstanceIdentity
    ) -> AVPlayerNaturalEndTerminalResult? { nil }

    func emitTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        timeControlStatus = status
        if status == .paused {
            pausedStatusContinuation?.resume()
            pausedStatusContinuation = nil
        }
        guard let item = currentItemIdentity, let activation = timeControlActivation else { return }
        timeControlHandler?(status, item, activation)
    }

    var directStateCallCount: Int { operations.filter { $0 == .readPausedState }.count }

    func waitForPlayCall() async {
        while playCallCount == 0 { await Task.yield() }
    }

    func waitForPauseCall() async {
        while pauseCallCount == 0 { await Task.yield() }
    }

    func waitForPauseCall(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while pauseCallCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        return pauseCallCount != 0
    }

    func releasePlayCompletion() {
        holdPlayCompletion = false
        playContinuation?.resume(); playContinuation = nil
    }

    func releaseDirectPausedRead(rate: Float, status: AVPlayer.TimeControlStatus) {
        holdDirectPausedRead = false
        let item = currentItemIdentity!
        pausedReadContinuation?.resume(returning: .init(item: item, rate: rate,
                                                        timeControlStatus: status))
        pausedReadContinuation = nil
    }
}

/// Task22 长流在本文件之外复用正式 coordinator；driver 细节仍保持私有，
/// 只返回由同一 prepared timeline 映射出的 N 与实际安装值。
@MainActor
func task22PrepareFinalThroughCoordinator(
    request: AVPlayerItemPreparationRequest,
    evidenceSource: LoopbackAVPlayerPreparationEvidenceSource,
    effectiveEnd: ExactMediaTime
) async throws -> (expected: ExactMediaTime, constrained: ExactMediaTime?) {
    let driver = Task21FakeDriver()
    let coordinator = try AVPlayerItemCoordinator(
        driver: driver, evidenceSource: evidenceSource)
    try coordinator.install(request)
    let prepared = try await coordinator.prepareCurrentItem()
    let expected = try prepared.identity.timelineMappingAuthority
        .playerItemTime(for: effectiveEnd)
    return (expected, driver.constrainedPlaybackEnd)
}

private final class Task21PrepareCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancellationPending = false
    private var startedValue = false
    private var cancellationObservedValue = false

    var started: Bool { lock.withLock { startedValue } }
    var cancellationObserved: Bool { lock.withLock { cancellationObservedValue } }
    var hasWaiter: Bool { lock.withLock { continuation != nil } }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelImmediately = lock.withLock {
                    startedValue = true
                    guard !cancellationPending else { return true }
                    self.continuation = continuation
                    return false
                }
                if cancelImmediately { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock {
                cancellationObservedValue = true
                cancellationPending = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func releaseForFailedRED() {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: AVPlayerItemCoordinatorFailure.staleIdentity)
    }
}

/// 故意只实现协议当前强制的方法，用行为测试证明安全关键方法不得由默认空实现代替。
@MainActor
private final class Task21UnsafeDefaultDriver: AVPlayerDriving {
    var rate: Float = 0
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var currentItemIdentity: AVPlayerItemInstanceIdentity?
    private(set) var playCallCount = 0

    func install(url: URL, identity: AVPlayerItemInstanceIdentity) throws {
        currentItemIdentity = identity
    }

    func waitUntilReady(item: AVPlayerItemInstanceIdentity) async throws
        -> AVPlayerItemInstanceIdentity { item }

    func seek(to time: ExactMediaTime, item: AVPlayerItemInstanceIdentity,
              playhead: PreparedPlayheadIdentity) async throws -> AVPlayerSeekReceipt {
        .init(item: item, playhead: playhead, actualTime: time)
    }

    func waitForLoadedTimeRanges(item: AVPlayerItemInstanceIdentity,
                                 playhead: PreparedPlayheadIdentity,
                                 covering requested: FMP4PresentationRange) async throws
        -> AVPlayerLoadedRangeReceipt { .init(item: item, playhead: playhead, requested: requested) }

    func preroll(item: AVPlayerItemInstanceIdentity,
                 playhead: PreparedPlayheadIdentity) async throws -> AVPlayerPrerollReceipt {
        .init(item: item, playhead: playhead, succeeded: true)
    }

    func play(invocation: ControlTaskRegistry.BackendPositiveRateInvocation,
              item: AVPlayerItemInstanceIdentity) async throws {
        guard invocation.performPositiveRateSideEffect({
            playCallCount += 1
            rate = 1
            timeControlStatus = .waitingToPlayAtSpecifiedRate
        }) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
    }

    func installTimeControlStatusRelay(
        item: AVPlayerItemInstanceIdentity,
        activation: ActivationEpoch,
        handler: @escaping @MainActor @Sendable (
            AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch
        ) -> Void
    ) throws { throw AVPlayerItemCoordinatorFailure.staleIdentity }
    func installAccessLogURIObservation(
        item: AVPlayerItemInstanceIdentity,
        classify: @escaping @Sendable (URL) -> AccessLogURIClassification,
        handler: @escaping @MainActor @Sendable (AccessLogURIClassification, AVPlayerItemInstanceIdentity) -> Void
    ) throws {}

    func cancelPendingPrerolls(item: AVPlayerItemInstanceIdentity) {}
    func pause(item: AVPlayerItemInstanceIdentity) {
        rate = 0
        timeControlStatus = .paused
    }
    func waitUntilPaused(item: AVPlayerItemInstanceIdentity) async throws {
        guard timeControlStatus == .paused else {
            throw AVPlayerItemCoordinatorFailure.directPauseNotConfirmed
        }
    }
    func directState(item: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) -> AVPlayerDirectState {
        .init(item: item, rate: rate, timeControlStatus: timeControlStatus)
    }
    func replaceCurrentItemWithNil(item: AVPlayerItemInstanceIdentity) {
        if currentItemIdentity == item { currentItemIdentity = nil }
    }
    func removeObservers(item: AVPlayerItemInstanceIdentity) {}
    func preparationFenceReached(_ fence: AVPlayerPreparationFence,
                                 item: AVPlayerItemInstanceIdentity) {}
    func constrainPlaybackEnd(to time: ExactMediaTime,
                              item: AVPlayerItemInstanceIdentity) throws {}
    func installNaturalEndTerminalHandler(
        item: AVPlayerItemInstanceIdentity,
        handler: @escaping @MainActor @Sendable (
            AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity
        ) -> Void
    ) throws { _ = handler }
    func consumeNaturalEndTerminal(
        _ capability: AVPlayerNaturalEndTerminalCapability,
        item: AVPlayerItemInstanceIdentity
    ) -> AVPlayerNaturalEndTerminalResult? { nil }
}

private final class Task21FakeEvidenceSource: AVPlayerPreparationEvidenceProviding, @unchecked Sendable {
    enum ReadinessIdentityMutation { case none, url, generation, sequence }
    var readinessIdentityMutation: ReadinessIdentityMutation = .none
    private let source: LoopbackAVPlayerPreparationEvidenceSource
    var mutation: Task21PrepareMutation = .none
    var completedRenditions: [AudioRenditionIdentity] = [.init(rawValue: 2)] {
        didSet { publicationEventHandler?(publicationSequence) }
    }
    var masterPlaylistCompleted = true
    var videoParticipantCount = 1
    private(set) var observedPlayheads: [PreparedPlayheadIdentity] = []
    var deferCoverageUntilAwaited = false
    private(set) var awaitedCoverageCount = 0
    private var publicationEventHandler: (@Sendable (UInt64) -> Void)?
    private let publicationSequence: UInt64

    init(source: LoopbackAVPlayerPreparationEvidenceSource,
         publicationSequence: UInt64) {
        self.source = source
        self.publicationSequence = publicationSequence
    }

    func installCompletedPublicationEventHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void
    ) {
        publicationEventHandler = handler
        source.installCompletedPublicationEventHandler(handler)
    }

    func installRenditionSelectionEventHandler(
        _ handler: @escaping @Sendable (LoopbackAudioMediaSelectionCapability) -> Void
    ) { source.installRenditionSelectionEventHandler(handler) }

    func currentAudioSelectionCapability(itemURL: URL,
                                         item: AVPlayerItemInstanceIdentity,
                                         publicationSequence: UInt64)
        -> LoopbackAudioMediaSelectionCapability? {
        source.currentAudioSelectionCapability(
            itemURL: itemURL, item: item,
            publicationSequence: publicationSequence)
    }

    func classifyAccessLogURI(_ uri: URL,
                              itemURL: URL,
                              item: AVPlayerItemInstanceIdentity,
                              publicationSequence: UInt64,
                              selected: AudioRenditionIdentity?)
        -> AccessLogURIClassification {
        source.classifyAccessLogURI(uri, itemURL: itemURL, item: item,
                                    publicationSequence: publicationSequence,
                                    selected: selected)
    }

    func consumeLatestCompletedPublication(itemURL: URL,
                                           item: AVPlayerItemInstanceIdentity)
        -> AVPlayerCompletedPublicationReadiness? {
        // 这个 fake 的 mutation 必须经过与指定 publication 相同的 production
        // capability 消费路径；直接转发 source.latest 会绕过 completedRenditions，
        // 让“play await 期间 publication 改变”的夹具仍返回旧快照。
        consumeCompletedPublication(itemURL: itemURL, item: item,
                                    publicationSequence: publicationSequence)
    }

    func consumeCompletedPublication(itemURL: URL,
                                     item: AVPlayerItemInstanceIdentity,
                                     publicationSequence: UInt64)
        -> AVPlayerCompletedPublicationReadiness? {
        guard mutation != .missingRendition, mutation != .headOnly,
              mutation != .incompleteBody, mutation != .wrongDigest else { return nil }
        guard let base = source.consumeCompletedPublication(
            itemURL: itemURL, item: item,
            publicationSequence: publicationSequence) else { return nil }
        let generation = mutation == .wrongItemGeneration || readinessIdentityMutation == .generation
            ? item.itemGeneration + 1 : item.itemGeneration
        let baseAudio = base.participants.filter { $0.mediaType == .audio }
        var participants = completedRenditions.enumerated().map { index, rendition in
            if let exact = baseAudio.first(where: { $0.renditionIdentity == rendition }) {
                return exact
            }
            return AVPlayerCompletedParticipantReadiness(
                participantID: UInt64(index + 20), renditionIdentity: rendition,
                mediaType: .audio,
                mediaPlaylistSnapshotIdentity: Task21Fixtures.playlistSnapshotIdentity,
                initializationBodyCompleted: true, mediaBodyCompleted: true)
        }
        let baseVideo = base.participants.filter { $0.mediaType == .video }
        for ordinal in 0..<videoParticipantCount {
            if baseVideo.indices.contains(ordinal) {
                participants.insert(baseVideo[ordinal], at: ordinal)
            } else {
                participants.insert(.init(participantID: UInt64(ordinal + 100),
                    renditionIdentity: .init(rawValue: UInt64(101 + ordinal)),
                    mediaType: .video,
                    mediaPlaylistSnapshotIdentity: Task21Fixtures.proofIdentity,
                    initializationBodyCompleted: true, mediaBodyCompleted: true), at: ordinal)
            }
        }
        return .init(itemURL: readinessIdentityMutation == .url ? itemURL.appendingPathComponent("旧身份") : itemURL,
            itemGeneration: generation,
            publicationSequence: readinessIdentityMutation == .sequence ? publicationSequence + 1 : publicationSequence,
            masterPlaylistCompleted: masterPlaylistCompleted,
            participants: participants,
            audioSelectionCapability: base.audioSelectionCapability)
    }

    func verifiedCoverage(
        context: LoopbackCoverageContext,
        requested: FMP4PresentationRange
    ) throws -> AVPlayerVerifiedCoverage? {
        observedPlayheads.append(context.preparedPlayheadIdentity)
        guard !deferCoverageUntilAwaited else { return nil }
        guard mutation != .headOnly, mutation != .incompleteBody,
              mutation != .wrongDigest,
              let base = try source.verifiedCoverage(
                context: context, requested: requested) else { return nil }
        let duration = mutation == .shortCoverage
            ? Task21Fixtures.time(2.999) : base.presentationRange.duration
        let range = try FMP4PresentationRange(
            start: base.presentationRange.start, duration: duration)
        let dependencies = base.dependencies.map {
            AVPlayerCoverageDependencyEvidence(
                mediaEpoch: mutation == .wrongMediaEpoch ? 999 : $0.mediaEpoch,
                epochProofIdentity: $0.epochProofIdentity,
                segmentReceiptIdentity: $0.segmentReceiptIdentity,
                initializationBackingIdentity: $0.initializationBackingIdentity,
                mediaBackingIdentity: $0.mediaBackingIdentity,
                initializationBodyCompleted: $0.initializationBodyCompleted,
                mediaBodyCompleted: $0.mediaBodyCompleted)
        }
        return AVPlayerVerifiedCoverage(
            preparedPlayheadIdentity: base.preparedPlayheadIdentity,
            observedRenditionSetReceiptIdentity:
                base.observedRenditionSetReceiptIdentity,
            renditionIdentity: base.renditionIdentity,
            itemGeneration: base.itemGeneration,
            presentationRange: range,
            dependencies: .init(explicit: dependencies))
    }

    func awaitCoverageReadiness(
        contexts: [LoopbackCoverageContext],
        requested: FMP4PresentationRange
    ) async throws {
        guard deferCoverageUntilAwaited else { return }
        awaitedCoverageCount += contexts.count
        deferCoverageUntilAwaited = false
        await Task.yield()
    }

    func consumePlayerItemTimelineMapping(
        endpointAuthority: AACEffectiveEndpointAuthority?,
        itemURL: URL,
        item: AVPlayerItemInstanceIdentity,
        publicationSequence: UInt64,
        selection: LoopbackAudioMediaSelectionCapability?
    ) async throws -> PlayerItemTimelineMappingAuthority? {
        guard mutation != .noCommonBoundary else { return nil }
        return try await source.consumePlayerItemTimelineMapping(
            endpointAuthority: endpointAuthority,
            itemURL: itemURL,
            item: item,
            publicationSequence: publicationSequence,
            selection: selection)
    }
}

private final class FinalLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}

private final class FinalNaturalEndDeadlineReceiver: PlaybackNaturalEndDeadlineReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID] = []
    var identities: [UUID] { lock.withLock { values } }
    func naturalEndDeadlineFired(identity: UUID) { lock.withLock { values.append(identity) } }
}

/// 首job只有原Registry join这一条异步调用；返回执行器即已悬挂于未结束的runner。
private final class Task21JoinExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.vplayer.tests.original-join")
    private let firstJobSuspended: XCTestExpectation
    private var first = true
    init(firstJobSuspended: XCTestExpectation) { self.firstJobSuspended = firstJobSuspended }
    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
            if first { first = false; firstJobSuspended.fulfill() }
        }
    }
}

private func task21JoinOriginal(registry: ControlTaskRegistry, ticket: ControlTaskTicket,
                                executor: Task21JoinExecutor) -> Task<PlaybackBackendOperationResult, Never> {
    Task(executorPreference: executor) { await registry.joinOutputBackendOperation(ticket) }
}

private actor Task21FactoryStartBarrier {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 8 {
                let ready = waiting
                waiting.removeAll()
                ready.forEach { $0.resume() }
            }
        }
    }
}

private final class FinalLockedSeekCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?
    var value: Bool? { lock.withLock { storage } }
    func resolve(_ finished: Bool) { lock.withLock { storage = finished } }
}

/// 只控制 production 第二次 direct read 的 deadline；两次读取仍由
/// `SystemAVPlayerDriver` 对同一真实 AVPlayer 执行。
private final class FinalManualAVPlayerDeadlineScheduler:
    AVPlayerWaitDeadlineScheduling, @unchecked Sendable {
    private struct Entry {
        let identity: UUID
        let handler: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var activeSlotCount: Int { lock.withLock { entries.count } }

    func schedule(after seconds: TimeInterval,
                  handler: @escaping @Sendable () -> Void) -> UUID? {
        _ = seconds
        let identity = UUID()
        return lock.withLock {
            guard entries.count < 4 else { return nil }
            entries.append(.init(identity: identity, handler: handler))
            return identity
        }
    }

    func cancel(_ identity: UUID) {
        lock.withLock { entries.removeAll { $0.identity == identity } }
    }

    @discardableResult
    func fireNext() -> Bool {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !entries.isEmpty else { return nil }
            return entries.removeFirst().handler
        }
        handler?()
        return handler != nil
    }

    func occupyAllSlots() -> [UUID] {
        (0..<4).compactMap { _ in schedule(after: 20, handler: {}) }
    }
}

@MainActor
private final class Task21AuthorityEventSink {
    var handler: (@MainActor () -> Void)?
}

/// 轻量 Coordinator 单元夹具仍用 fake driver 控制竞态，但 publication、selection 与
/// timeline authority 必须来自同一真实 Loopback socket/send-terminal 链。
private final class Task21HarnessAuthorityFixture: @unchecked Sendable {
    let server: LoopbackHTTPServer
    let source: LoopbackAVPlayerPreparationEvidenceSource
    let request: AVPlayerItemPreparationRequest
    private let publication: Task21RealHLSHarness
    private let endpointAuthority: AACEffectiveEndpointAuthority

    private init(server: LoopbackHTTPServer,
                 source: LoopbackAVPlayerPreparationEvidenceSource,
                 request: AVPlayerItemPreparationRequest,
                 publication: Task21RealHLSHarness,
                 endpointAuthority: AACEffectiveEndpointAuthority) {
        self.server = server
        self.source = source
        self.request = request
        self.publication = publication
        self.endpointAuthority = endpointAuthority
    }

    static func make(lifecycle: OutputLifecycleEpoch,
                     audioOnly: Bool) async throws -> Task21HarnessAuthorityFixture {
        let seed = try await Task21RealAACSeed.make(
            outputLifecycleEpoch: lifecycle)
        let avSeed = audioOnly ? nil : try await Task21RealAVSeed.make(audio: seed)
        let box = FinalLockedValue<Task21RealHLSHarness>()
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: 19, now: { 0 }, logger: { _ in },
            responseFailure: { _, _ in }
        ) { token in
            let publication = try Task21RealHLSHarness(
                token: token, seed: seed, avSeed: avSeed, endList: audioOnly)
            box.value = publication
            return LoopbackPreparedPublication(
                store: publication.store,
                declaration: publication.declaration,
                snapshot: try XCTUnwrap(publication.publisher.visible))
        }
        let publication = try XCTUnwrap(box.value)
        let source = try LoopbackAVPlayerPreparationEvidenceSource.make(server: server)
        let item = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle, itemGeneration: 19)
        let bundle = try LoopbackAVPlayerPreparationBundle(
            evidenceSource: source, item: item)
        let snapshot = try XCTUnwrap(publication.publisher.visible)
        var urls = [bundle.request.itemURL]
        let participantIDs: [UInt64]
        if let direct = bundle.request.directAudioOnlyRendition {
            participantIDs = [direct.rawValue]
        } else {
            participantIDs = snapshot.participantVector.map(\.participantID)
            urls += try snapshot.participantVector.map { entry in
                let path = try entry.declaration.playlistURI(
                    participantID: entry.participantID)
                return try XCTUnwrap(URL(string: path,
                    relativeTo: server.baseURL)?.absoluteURL)
            }
        }
        for participantID in participantIDs {
            let media = try XCTUnwrap(snapshot.media[participantID])
            urls += try (media.initializationResources + media.resources).map { key in
                try XCTUnwrap(URL(string: server.path(for: key),
                                  relativeTo: server.baseURL)?.absoluteURL)
            }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in urls {
            let (body, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200, !body.isEmpty else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while server.currentAudioSelectionCapability(
            itemGeneration: 19,
            publicationSequence: bundle.request.publicationSequence
        ) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard server.currentAudioSelectionCapability(
            itemGeneration: 19,
            publicationSequence: bundle.request.publicationSequence
        ) != nil else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        return .init(server: server, source: source,
                     request: bundle.request, publication: publication,
                     endpointAuthority: avSeed?.endpointAuthority
                        ?? seed.endpointAuthority)
    }

    func shutdown() {
        _ = finalWaitUntil(timeout: 2) {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }
        source.retirePreparation()
        let ticket = server.closeAdmission()
        try? server.drain(cleanupTicket: ticket)
        try? server.retire(cleanupTicket: ticket)
    }

    func makePreparedPlayhead() async throws -> PreparedPlayheadIdentity {
        let readiness = try XCTUnwrap(source.consumeCompletedPublication(
            itemURL: request.itemURL, item: request.item,
            publicationSequence: request.publicationSequence))
        let selection = try XCTUnwrap(readiness.audioSelectionCapability)
        let consumedTimeline = try await source.consumePlayerItemTimelineMapping(
            endpointAuthority: endpointAuthority,
            itemURL: request.itemURL,
            item: request.item,
            publicationSequence: request.publicationSequence,
            selection: selection)
        let timeline = try XCTUnwrap(consumedTimeline)
        let lead = ExactMediaTime(value: 3, timescale: 1)
        let mediaTime = try XCTUnwrap(
            try timeline.mapping.latestBoundary(withLead: lead))
        return PreparedPlayheadIdentity(
            outputLifecycleEpoch: request.item.outputLifecycleEpoch,
            itemGeneration: request.item.itemGeneration,
            publicationSequence: request.publicationSequence,
            mediaTime: mediaTime,
            playerItemTime: try timeline.playerItemTime(for: mediaTime),
            seekNonce: 1,
            renditionSelectionSlotNonce: 2,
            audioSelectionCapability: selection,
            timelineMappingAuthority: timeline)
    }

    deinit { shutdown() }
}

@MainActor
private final class Task21Harness {
    let driver: Task21FakeDriver
    let evidence: Task21FakeEvidenceSource
    private let authorityEvents = Task21AuthorityEventSink()
    private let authorityFixture: Task21HarnessAuthorityFixture
    let coordinator: AVPlayerItemCoordinator
    let lifecycle: OutputLifecycleEpoch
    let graph: OutputGraphFixture
    let backend: Task21RegistryBackend
    private(set) var item: AVPlayerItemInstanceIdentity
    var sourceIdentity: ObjectIdentifier { ObjectIdentifier(authorityFixture.source) }
    let oldItem: AVPlayerItemInstanceIdentity
    private(set) var activation: ActivationEpoch
    private var latestReceipt: AVPlayerQuiescenceReceipt?
    var suspendTicket: OutputSuspendTicket { latestReceipt!.suspendTicket }
    var closeClaim: PotentiallyAudibleOutputCloseClaim { latestReceipt!.closeClaim! }
    private let liveEdge: ExactMediaTime
    private let boundaries: [ExactMediaTime]
    private let directAudioOnlyRendition: AudioRenditionIdentity?
    private let requiresAACEndpointAuthority: Bool
    private let additionalUnboundAACRendition: AudioRenditionIdentity?

    init(liveEdge: Double = 7, boundaries: [Double] = [1, 2, 3, 4],
         directAudioOnlyRendition: AudioRenditionIdentity? = nil,
         prepareMutation: Task21PrepareMutation = .none,
         requiresAACEndpointAuthority: Bool = false,
         additionalUnboundAACRendition: AudioRenditionIdentity? = nil) async throws {
        self.liveEdge = Task21Fixtures.time(liveEdge)
        self.boundaries = boundaries.map(Task21Fixtures.time)
        self.directAudioOnlyRendition = directAudioOnlyRendition
        self.requiresAACEndpointAuthority = requiresAACEndpointAuthority
        self.additionalUnboundAACRendition = additionalUnboundAACRendition
        driver = Task21FakeDriver()
        driver.prepareMutation = prepareMutation
        backend = Task21RegistryBackend()
        graph = try OutputGraphFixture(backendObject: backend)
        lifecycle = graph.lifecycle
        authorityFixture = try await Task21HarnessAuthorityFixture.make(
            lifecycle: lifecycle, audioOnly: directAudioOnlyRendition != nil)
        evidence = Task21FakeEvidenceSource(
            source: authorityFixture.source,
            publicationSequence: authorityFixture.request.publicationSequence)
        evidence.mutation = prepareMutation
        if let directAudioOnlyRendition {
            evidence.completedRenditions = [directAudioOnlyRendition]
            evidence.masterPlaylistCompleted = false
            evidence.videoParticipantCount = 0
        } else {
            evidence.videoParticipantCount = 1
        }
        if let additionalUnboundAACRendition {
            evidence.completedRenditions.append(additionalUnboundAACRendition)
        }
        coordinator = try AVPlayerItemCoordinator(
            driver: driver, evidenceSource: evidence,
            backendPublicationReplacementAuthoritySlot:
                backend.backendPublicationReplacementAuthoritySlot)
        backend.attach(coordinator)
        authorityEvents.handler = nil
        item = authorityFixture.request.item
        oldItem = item
        activation = .init(outputLifecycleEpoch: lifecycle,
                           audioAdmissionFenceRevision: 0, activationNonce: 0)
        backend.configure(identity: lifecycle.backendIdentity,
                          itemGeneration: item.itemGeneration)
        driver.conflictHandler = { [weak evidence] in
            evidence?.completedRenditions.append(.init(rawValue: 202))
        }
        var preparation = authorityFixture.request
        if requiresAACEndpointAuthority {
            preparation = .init(itemURL: preparation.itemURL, item: preparation.item,
                publicationSequence: preparation.publicationSequence,
                audioParticipants: preparation.audioParticipants.map {
                    .init(renditionIdentity: $0.renditionIdentity, codec: .aac)
                }, directAudioOnlyRendition: preparation.directAudioOnlyRendition)
        }
        if let additionalUnboundAACRendition {
            preparation = .init(itemURL: preparation.itemURL, item: preparation.item,
                publicationSequence: preparation.publicationSequence,
                audioParticipants: Array(preparation.audioParticipants) + [
                    .init(renditionIdentity: additionalUnboundAACRendition, codec: .aac)
                ], directAudioOnlyRendition: preparation.directAudioOnlyRendition)
        }
        try coordinator.install(preparation)
    }

    func prepare() async throws -> PreparedAVPlayerItem {
        if let prepared = backend.prepared { return prepared }
        let ticket = try XCTUnwrap(graph.registry.outputResourceContextSnapshot()?.sourceTask)
        guard graph.registry.startOutputPrepareOperation(ticket) else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(ticket),
              let prepared = backend.prepared else {
            throw backend.lastError ?? AVPlayerItemCoordinatorFailure.staleIdentity
        }
        return prepared
    }

    func activate(stale: Bool = false) async throws -> BackendActivationResult {
        if stale { return .rejected }
        if backend.activationResult != nil { return .alreadyArmed(activation) }
        return try await activateThroughRegistry()
    }

    func resumeThroughRegistry() async throws -> BackendActivationResult {
        try await activateThroughRegistry()
    }

    private func activateThroughRegistry() async throws -> BackendActivationResult {
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        guard let ticket = try graph.registry.beginOutputActivation(
            contextNonce: context.contextNonce
        ) else { return .rejected }
        backend.clearActivationResult()
        guard graph.registry.startOutputActivationOperation(ticket) else { return .rejected }
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(ticket) else {
            return .rejected
        }
        guard let result = backend.activationResult else { return .rejected }
        if case .armed(let value) = result {
            activation = value
            latestReceipt = nil
        }
        return result
    }

    func observe(_ status: AVPlayer.TimeControlStatus) {
        coordinator.observeTimeControlStatus(status, item: item, activation: activation)
    }

    func stop(strongerReason: Bool = false) async throws -> AVPlayerQuiescenceReceipt {
        if let latestReceipt, !strongerReason { return latestReceipt }
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        let conflictsWithExistingStop = strongerReason
            && (coordinator.phase == .stopping || coordinator.phase == .quiescent)
        let owner = try XCTUnwrap(graph.coordinator.begin(
            contextNonce: context.contextNonce,
            reason: conflictsWithExistingStop ? .stop : .pause,
            at: graph.registry.clock.nowNanoseconds
        ))
        guard await graph.registry.joinOutputBackendOperations(owner: owner),
              let stop = graph.registry.outputResourceContextSnapshot()?.suspend else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        // 同参数并发 caller 只能有一个人把固定 record 从 queued 推到 running；
        // 其余 caller 加入同一 ticket 的 runner，不能把“已经启动”误报成失败。
        let started = graph.registry.startOutputSuspendOperation(stop.task, owner: owner)
        if conflictsWithExistingStop && !started {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(stop.task) else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        guard let receipt = backend.quiescenceReceipt else {
            throw backend.lastError ?? AVPlayerItemCoordinatorFailure.staleIdentity
        }
        latestReceipt = receipt
        return receipt
    }

    func shutdown() async throws {
        try await stopAndRetireTask21RegistryOutput(graph: graph, backend: backend)
        authorityFixture.shutdown()
    }

    func reinstall() throws {
        if let latestReceipt {
            try coordinator.completeLifecycleCleanup(latestReceipt)
            if let owner = graph.registry.outputResourceContextSnapshot()?.owner {
                _ = try graph.registry.retireOutputControlRecord(latestReceipt.suspendTicket.task)
                _ = graph.registry.finishOutputPause(owner: owner)
            }
        }
        let candidate = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: lifecycle,
            itemGeneration: item.itemGeneration + 1
        )
        try coordinator.install(Task21Fixtures.request(item: candidate, liveEdge: liveEdge,
            boundaries: boundaries, directAudioOnlyRendition: directAudioOnlyRendition,
            requiresAACEndpointAuthority: requiresAACEndpointAuthority))
        item = candidate
        latestReceipt = nil
        backend.reset(itemGeneration: item.itemGeneration)
    }
}

private final class Task21RegistryBackend: PlaybackBackend,
    BackendPublicationReplacementAuthorityInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let retirementCompletionGate = Task21RetirementCompletionGate()
    private var coordinatorValue: AVPlayerItemCoordinator?
    private let replacementAuthoritySlot:
        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot
    private var configuredIdentity = PlaybackBackendIdentity(
        sessionIdentity: .init(sessionID: 0, requestID: UUID()), backendGeneration: 0
    )
    private var configuredItemGeneration: UInt64?
    private var preparedValue: PreparedAVPlayerItem?
    private var activationValue: BackendActivationResult?
    private var quiescenceValue: AVPlayerQuiescenceReceipt?
    private var errorValue: Error?
    private var suspendCallCountValue = 0
    private var retireCallCountValue = 0
    private var lastRetiredEpochValue: OutputLifecycleEpoch?
    var returnCallerForgedQuiescence = false
    var beforeActivation: ((ControlTaskRegistry.BackendPositiveRateInvocation) -> Void)?
    private(set) var lastProof: ControlTaskRegistry.BackendQuiescenceProof?
    private(set) var lastActivationInvocation: ControlTaskRegistry.BackendPositiveRateInvocation?
    private(set) var lastSuspendInvocation: ControlTaskRegistry.BackendSuspendInvocation?

    @MainActor
    init(coordinator: AVPlayerItemCoordinator) {
        coordinatorValue = coordinator
        replacementAuthoritySlot = coordinator.backendPublicationReplacementAuthoritySlot
    }

    init() {
        coordinatorValue = nil
        replacementAuthoritySlot = .init()
    }

    @MainActor
    func attach(_ coordinator: AVPlayerItemCoordinator) {
        precondition(coordinatorValue == nil,
                     "真实 Registry backend 只能绑定一个 coordinator")
        precondition(coordinator.backendPublicationReplacementAuthoritySlot
                        === replacementAuthoritySlot,
                     "Registry 与 coordinator 必须共享同一个 replacement authority 槽")
        coordinatorValue = coordinator
    }

    var identity: PlaybackBackendIdentity { lock.withLock { configuredIdentity } }
    var presentation: PlaybackPresentation? { nil }
    var outputItemGeneration: UInt64? { lock.withLock { configuredItemGeneration } }
    var backendPublicationReplacementAuthoritySlot:
        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot {
        replacementAuthoritySlot
    }
    var prepared: PreparedAVPlayerItem? { lock.withLock { preparedValue } }
    var activationResult: BackendActivationResult? { lock.withLock { activationValue } }
    var quiescenceReceipt: AVPlayerQuiescenceReceipt? { lock.withLock { quiescenceValue } }
    var lastError: Error? { lock.withLock { errorValue } }
    var suspendCallCount: Int { lock.withLock { suspendCallCountValue } }
    var retireCallCount: Int { lock.withLock { retireCallCountValue } }
    var lastRetiredEpoch: OutputLifecycleEpoch? { lock.withLock { lastRetiredEpochValue } }

    func waitForRetirementCall(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while retireCallCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        return retireCallCount > 0
    }

    func allowRetirementCompletion() {
        retirementCompletionGate.release()
    }

    private func requiredCoordinator() throws -> AVPlayerItemCoordinator {
        guard let coordinator = lock.withLock({ coordinatorValue }) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        return coordinator
    }

    func configure(identity: PlaybackBackendIdentity, itemGeneration: UInt64) {
        lock.withLock {
            configuredIdentity = identity
            configuredItemGeneration = itemGeneration
        }
    }

    func reset(itemGeneration: UInt64) {
        lock.withLock {
            configuredItemGeneration = itemGeneration
            preparedValue = nil
            activationValue = nil
            quiescenceValue = nil
            errorValue = nil
        }
    }

    func clearActivationResult() {
        lock.withLock { activationValue = nil }
    }

    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        do {
            let coordinator = try requiredCoordinator()
            let value = try await coordinator.prepareCurrentItem(invocation: invocation)
            lock.withLock { preparedValue = value }
        } catch {
            lock.withLock { errorValue = error }
            throw error
        }
    }

    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        let coordinator = try requiredCoordinator()
        let value = try await coordinator.prepareCurrentItem(invocation: invocation)
        lock.withLock { preparedValue = value }
    }

    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {
        let hook = lock.withLock { () -> ((ControlTaskRegistry.BackendPositiveRateInvocation) -> Void)? in
            lastActivationInvocation = invocation
            defer { beforeActivation = nil }
            return beforeActivation
        }
        hook?(invocation)
        let coordinator = try requiredCoordinator()
        let value = try await coordinator.activate(invocation)
        lock.withLock { activationValue = value }
        guard value != .rejected else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
    }

    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async
        -> BackendSuspendResult {
        lock.withLock { suspendCallCountValue += 1; lastSuspendInvocation = invocation }
        if returnCallerForgedQuiescence {
            return .requiresRetirement
        }
        do {
            let coordinator = try requiredCoordinator()
            let value = try await coordinator.stop(invocation)
            let attestation = try await coordinator.attestQuiescence(
                value, invocation: invocation, backendIdentity: identity)
            let proof = ControlTaskRegistry.BackendQuiescenceProof.avPlayer(attestation)
            lock.withLock {
                quiescenceValue = value
                lastProof = proof
                lastSuspendInvocation = invocation
            }
            return .quiescent(proof)
        } catch {
            lock.withLock { errorValue = error }
            return .requiresRetirement
        }
    }

    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        lock.withLock { retireCallCountValue += 1 }
        // 测试必须先观察到真实 Registry retirement 调用，再由 terminal cleanup
        // 原子升级同一 owner；否则 Control 可在测试 MainActor 恢复前完成 reprepare
        // handoff。闸门只延迟这个真实调用的 completion，不伪造任何 proof/authority。
        await retirementCompletionGate.wait()
        let cleanup = lock.withLock { () -> (
            AVPlayerItemCoordinator, AVPlayerQuiescenceReceipt
        )? in
            guard let coordinator = coordinatorValue,
                  let receipt = quiescenceValue,
                  receipt.item.outputLifecycleEpoch == epoch,
                  receipt.suspendTicket.lifecycle == epoch,
                  lastSuspendInvocation?.lifecycle == epoch else { return nil }
            return (coordinator, receipt)
        }
        guard let cleanup else { return .unconfirmed }
        let unloaded = await MainActor.run { () -> Bool in
            do {
                try cleanup.0.completeLifecycleCleanup(cleanup.1)
                return cleanup.0.currentItemIdentity == nil
                    && cleanup.0.phase == .quiescent
            } catch {
                return false
            }
        }
        guard unloaded else { return .unconfirmed }
        lock.withLock { lastRetiredEpochValue = epoch }
        return .confirmedLocalOutputStopped
    }
}

private final class Task21RetirementCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if lock.withLock({ released }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard !released else { return true }
                precondition(waiter == nil, "每个 EOS fixture 只允许一个 retirement completion")
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}

private enum Task21ReceiptMutation: CaseIterable {
    case lifecycle, itemGeneration, suspendTicket, priorActivation, stopNonce, closeClaim

    func apply(to receipt: AVPlayerQuiescenceReceipt) -> AVPlayerQuiescenceReceipt {
        let staleLifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 99_001)
        let staleItem = AVPlayerItemInstanceIdentity(
            outputLifecycleEpoch: staleLifecycle,
            itemGeneration: receipt.item.itemGeneration + 1
        )
        let staleActivation = ActivationEpoch(outputLifecycleEpoch: staleLifecycle,
            audioAdmissionFenceRevision: 999, activationNonce: 999)
        let staleSuspend = Task21Fixtures.suspendTicket(lifecycle: staleLifecycle,
                                                        activation: staleActivation, nonce: 999)
        let staleClaim = Task21Fixtures.closeClaim(item: staleItem, activation: staleActivation,
                                                  suspend: staleSuspend, nonce: 999)
        return AVPlayerQuiescenceReceipt(
            item: self == .lifecycle || self == .itemGeneration ? staleItem : receipt.item,
            suspendTicket: self == .suspendTicket ? staleSuspend : receipt.suspendTicket,
            priorActivationEpoch: self == .priorActivation ? staleActivation : receipt.priorActivationEpoch,
            stopNonce: self == .stopNonce ? receipt.stopNonce.map { $0 + 1 } : receipt.stopNonce,
            closeClaim: self == .closeClaim ? staleClaim : receipt.closeClaim,
            directlyConfirmedRateZero: receipt.directlyConfirmedRateZero
        )
    }
}

/// EOS 测试也必须走 Registry 正式 terminal owner。协议本身不能抛错，因此
/// receiver 只在固定结果槽保存首个失败，外部 join 同一注册 Task 后再原样抛出。
private final class Task21FinalEOSCleanupReceiver: PlaybackOwnedCleanupReceiving,
    @unchecked Sendable {
    private let registry: ControlTaskRegistry
    private let audioLane: AudioSessionBlockingCallLane
    private let lock = NSLock()
    private var failure: (any Error)?
    private var completed = false

    init(registry: ControlTaskRegistry, audioLane: AudioSessionBlockingCallLane) {
        self.registry = registry
        self.audioLane = audioLane
    }

    func performOwnedTerminalCleanup(owner: OutputTransitionOwnerTicket,
                                     task: ControlTaskTicket,
                                     terminalState _: PlaybackState) async {
        do {
            try await finishTerminalCleanup(owner: owner, ownerTask: task)
            lock.withLock { completed = true }
        } catch {
            lock.withLock {
                if failure == nil { failure = error }
            }
        }
    }

    func result() throws {
        try lock.withLock {
            if let failure { throw failure }
            guard completed else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        }
    }

    private func finishTerminalCleanup(owner: OutputTransitionOwnerTicket,
                                       ownerTask: ControlTaskTicket) async throws {
        let coordinator = OutputCleanupCoordinator(registry: registry)
        guard await registry.joinOutputBackendOperations(owner: owner) else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        _ = try coordinator.advance(owner: owner)
        guard await registry.joinOutputEventRelays(owner: owner) else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if registry.ownedResourceSnapshot() == nil {
                guard registry.finishOwnedCleanupResources(ownerTask, owner: owner) else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                return
            }
            guard let context = registry.outputResourceContextSnapshot(),
                  context.owner == owner,
                  let reservation = registry.cleanupReservationSnapshot() else {
                throw AVPlayerItemCoordinatorFailure.staleIdentity
            }
            guard let ticket = try coordinator.advance(owner: owner) else {
                await Task.yield()
                continue
            }
            if ticket == context.suspend?.task {
                guard let cleanup = registry.claimOutputBackendCleanup(ticket, owner: owner),
                      let invocation = cleanup.suspendInvocation else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                let result = await cleanup.backend.suspendOutput(invocation: invocation)
                guard registry.completeOutputSuspend(
                    result,
                    invocation: invocation,
                    backend: cleanup.backend
                ) else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
                continue
            }
            if ticket == reservation.task(for: .retirement) {
                guard let cleanup = registry.claimOutputBackendCleanup(ticket, owner: owner),
                      let lifecycle = cleanup.lifecycle else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                let retirement = await cleanup.backend.retireOutput(epoch: lifecycle)
                guard retirement == .confirmedLocalOutputStopped,
                      coordinator.completeRetirement(ticket, lifecycle: lifecycle) else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                continue
            }
            if ticket == reservation.task(for: .teardown) {
                guard let cleanup = registry.claimOutputBackendCleanup(ticket, owner: owner),
                      coordinator.completeTeardown(
                        ticket,
                        backend: cleanup.backend.identity,
                        contextNonce: cleanup.contextNonce
                      ) != nil else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                continue
            }
            if ticket == reservation.task(for: .monitorStop) {
                guard registry.claimStart(ticket),
                      let lifecycle = currentMonitorLifecycle(),
                      coordinator.completeMonitorStop(ticket, lifecycle: lifecycle) else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                continue
            }
            if ticket == reservation.task(for: .audioSession) {
                _ = try graphAudioCall(
                    registry,
                    lane: audioLane,
                    ticket,
                    .deactivation(.succeeded)
                )
                continue
            }
            if ticket == reservation.task(for: .leaseRelease) {
                var release: OwnedOutputResourceRunner? =
                    registry.claimOwnedResourceReleaseRunner(ticket)
                guard release != nil else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                release = nil
                guard registry.complete(ticket) else {
                    throw AVPlayerItemCoordinatorFailure.operationInFlight
                }
                continue
            }
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        throw AVPlayerItemCoordinatorFailure.operationInFlight
    }

    private func currentMonitorLifecycle() -> UInt64? {
        guard let snapshot = registry.ownedResourceSnapshot() else { return nil }
        switch snapshot.payload {
        case .monitor(_, let lifecycle):
            return lifecycle
        case .lease(_, _, let lifecycle, _),
             .backend(_, _, _, let lifecycle, _):
            return lifecycle
        }
    }
}

@MainActor
private final class Task21RealIntegrationFixture {
    struct PlaybackResult {
        let presentedEnd: Double
        let endpointEnd: Double
        let didReachStableEnd: Bool
    }

    let player: AVPlayer
    private let driver: SystemAVPlayerDriver
    private let deadlineScheduler: FinalManualAVPlayerDeadlineScheduler
    private let publication: Task21RealHLSHarness
    private let server: LoopbackHTTPServer
    private let coordinator: AVPlayerItemCoordinator
    private let evidenceSource: LoopbackAVPlayerPreparationEvidenceSource
    private let graph: OutputGraphFixture
    private let backend: Task21RegistryBackend
    private let item: AVPlayerItemInstanceIdentity
    private let itemURL: URL
    private var prepared: PreparedAVPlayerItem?

    private init(publication: Task21RealHLSHarness, server: LoopbackHTTPServer,
                 player: AVPlayer, driver: SystemAVPlayerDriver,
                 deadlineScheduler: FinalManualAVPlayerDeadlineScheduler,
                 coordinator: AVPlayerItemCoordinator,
                 evidenceSource: LoopbackAVPlayerPreparationEvidenceSource,
                 graph: OutputGraphFixture, backend: Task21RegistryBackend,
                 item: AVPlayerItemInstanceIdentity, itemURL: URL) {
        self.publication = publication
        self.server = server
        self.player = player
        self.driver = driver
        self.deadlineScheduler = deadlineScheduler
        self.coordinator = coordinator
        self.evidenceSource = evidenceSource
        self.graph = graph
        self.backend = backend
        self.item = item
        self.itemURL = itemURL
    }

    static func make(endList: Bool = true, includeVideo: Bool = false) async throws
        -> Task21RealIntegrationFixture {
        // Registry 先冻结正式 output lifecycle；writer、publisher、server 与 item
        // 随后全部绑定这一身份，避免只比较 generation 的跨 lifecycle 拼接。
        let backend = Task21RegistryBackend()
        let graph = try OutputGraphFixture(backendObject: backend)
        let seed = try await Task21RealAACSeed.make(
            outputLifecycleEpoch: graph.lifecycle)
        let lifecycle = graph.lifecycle
        let avSeed = includeVideo ? try await Task21RealAVSeed.make(audio: seed) : nil
        let box = Task21LockedHarness()
        let preparePublication: @Sendable (LoopbackSessionToken) throws
            -> LoopbackPreparedPublication = { token in
                let harness = try Task21RealHLSHarness(token: token, seed: seed,
                    avSeed: avSeed, endList: endList)
                box.value = harness
                guard let snapshot = harness.publisher.visible else {
                    throw LoopbackHTTPServerError.invalidConfiguration
                }
                return LoopbackPreparedPublication(store: harness.store,
                                                    declaration: harness.declaration,
                                                    snapshot: snapshot)
            }
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: 19, now: { 0 }, logger: { _ in },
            responseFailure: { _, _ in }, prepare: preparePublication)
        guard let harness = box.value else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        let player = AVPlayer()
        let deadlineScheduler = FinalManualAVPlayerDeadlineScheduler()
        let driver = try SystemAVPlayerDriver.make(
            player: player, deadlineScheduler: deadlineScheduler)
        let snapshot = try XCTUnwrap(harness.publisher.visible)
        let evidence = try LoopbackAVPlayerPreparationEvidenceSource.make(server: server)
        let coordinator = try AVPlayerItemCoordinator(
            driver: driver, evidenceSource: evidence,
            backendPublicationReplacementAuthoritySlot:
                backend.backendPublicationReplacementAuthoritySlot)
        backend.attach(coordinator)
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: lifecycle,
                                                itemGeneration: 19)
        backend.configure(identity: lifecycle.backendIdentity,
                          itemGeneration: item.itemGeneration)
        let preparation = try LoopbackAVPlayerPreparationBundle(
            evidenceSource: evidence, item: item,
            publicationSequence: snapshot.publicationSequence)
        try coordinator.install(preparation.request)
        return Task21RealIntegrationFixture(publication: harness, server: server,
            player: player, driver: driver, deadlineScheduler: deadlineScheduler,
            coordinator: coordinator,
            evidenceSource: evidence,
            graph: graph,
            backend: backend, item: item, itemURL: preparation.request.itemURL)
    }

    /// graph、writer、authority、listener、publisher、AVPlayer 与 prepare 全部在
    /// 单个场景内串行 JIT 创建；跨场景共享的只有不可变编码模板。
    static func makePreparedForFinalEOS() async throws -> Task21RealIntegrationFixture {
        let fixture = try await make(endList: false)
        do {
            try await fixture.primeCompletedSocketBodies()
            _ = try await fixture.prepare()
            return fixture
        } catch {
            let preparationError = error
            do {
                try await fixture.teardown()
            } catch {
                XCTFail("prepare 失败后的 Registry/server cleanup 同时失败：\(error)")
            }
            throw preparationError
        }
    }

    var completedBodyRequestCount: Int {
        prepared?.coverageDependencies.reduce(into: 0) { count, dependency in
            count += dependency.initializationBodyCompleted ? 1 : 0
            count += dependency.mediaBodyCompleted ? 1 : 0
        } ?? 0
    }

    var acceptedGETs: LoopbackAcceptedGETSnapshot { server.acceptedGETSnapshot() }
    var hasVideoParticipant: Bool { publication.declaration.video != nil }
    var endpointSourceTime: ExactMediaTime { publication.seed.endpoint.lastEffectiveEnd }
    var endpointItemTime: ExactMediaTime {
        get throws {
            try XCTUnwrap(prepared).identity.timelineMappingAuthority
                .playerItemTime(for: endpointSourceTime)
        }
    }
    var naturalEndObservation: AVPlayerNaturalEndObservation? {
        driver.naturalEndObservation
    }
    var writerBinding: FMP4WriterBinding { publication.seed.endpoint.binding }
    var endpointAuthorityIdentity: ObjectIdentifier {
        ObjectIdentifier(publication.seed.endpointAuthority)
    }
    var endpointAuthorityRejectsReplay: Bool {
        !publication.seed.endpointAuthority.consume()
    }
    var hasRegisteredSuspend: Bool {
        graph.registry.outputResourceContextSnapshot()?.suspend != nil
    }
    var backendRetireCount: Int { backend.retireCallCount }
    var backendSuspendCount: Int { backend.suspendCallCount }
    var coordinatorPhase: AVPlayerItemCoordinatorPhase { coordinator.phase }

    func prepare() async throws -> PreparedAVPlayerItem {
        if let prepared { return prepared }
        let value: PreparedAVPlayerItem
        do {
            let ticket = try XCTUnwrap(
                graph.registry.outputResourceContextSnapshot()?.sourceTask
            )
            guard graph.registry.startOutputPrepareOperation(ticket),
                  case .succeeded = await graph.registry.joinOutputBackendOperation(ticket),
                  let result = backend.prepared else {
                throw backend.lastError ?? AVPlayerItemCoordinatorFailure.staleIdentity
            }
            value = result
        }
        catch {
            let ranges = player.currentItem?.loadedTimeRanges.map {
                let value = $0.timeRangeValue
                return "\(CMTimeGetSeconds(value.start))...\(CMTimeGetSeconds(value.end))"
            }.joined(separator: ",") ?? "nil"
            let seekable = player.currentItem?.seekableTimeRanges.map {
                let value = $0.timeRangeValue
                return "\(CMTimeGetSeconds(value.start))...\(CMTimeGetSeconds(value.end))"
            }.joined(separator: ",") ?? "nil"
            let duration = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? .nan
            let accessEvents = player.currentItem?.accessLog()?.events.count ?? 0
            throw NSError(domain: "Task21RealIntegration", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "AVPlayer 准备失败；itemTime=\(CMTimeGetSeconds(player.currentTime()))；"
                    + "loaded=\(ranges)；seekable=\(seekable)；duration=\(duration)；"
                    + "accessEvents=\(accessEvents)；底层：\(error)"])
        }
        prepared = value
        return value
    }

    func playToEnd() async throws -> PlaybackResult {
        _ = try await prepare()
        guard let currentItem = player.currentItem else {
            throw AVPlayerItemCoordinatorFailure.noCurrentItem
        }
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        guard let activationTicket = try graph.registry.beginOutputActivation(
            contextNonce: context.contextNonce
        ), graph.registry.startOutputActivationOperation(activationTicket),
              case .succeeded = await graph.registry.joinOutputBackendOperation(activationTicket),
              case .armed = backend.activationResult else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let currentItemIdentity = ObjectIdentifier(currentItem)
        let reachedEnd = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await notification in NotificationCenter.default.notifications(
                    named: AVPlayerItem.didPlayToEndTimeNotification,
                    object: nil
                ) {
                    guard let item = notification.object as? AVPlayerItem,
                          ObjectIdentifier(item) == currentItemIdentity else { continue }
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                return false
            }
            defer { group.cancelAll() }
            let first = try await group.next() ?? false
            return first
        }
        guard reachedEnd else { throw AVPlayerItemCoordinatorFailure.insufficientCoverage }
        try await fireNaturalEndDeadline()
        guard case .success = try await naturalEndTerminalResult() else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let timeline = try XCTUnwrap(prepared).identity.timelineMappingAuthority
        let firstItemTime = try ExactMediaTime(player.currentTime())
        let terminalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while naturalEndObservation?.stableCurrentTime == nil,
              !hasRegisteredSuspend, ContinuousClock.now < terminalDeadline {
            await Task.yield()
        }
        let stableItemTime = try ExactMediaTime(player.currentTime())
        // AVPlayer currentTime 的任意 Int32 timescale 与 writer source origin 的精确
        // 和未必还能放进 CMTime 的 Int32 timescale。EOS 比较留在同一 item timeline：
        // 播放头与由 server authority 精确映射的 endpoint 可直接比较，不能用
        // Double 拼 source origin，也不能迫使 ExactMediaTime 接受不可表示分数。
        let endpointItemTime = try timeline.playerItemTime(
            for: publication.seed.endpoint.lastEffectiveEnd)
        let stableEnd = CMTimeGetSeconds(stableItemTime.cmTime)
        let endpoint = CMTimeGetSeconds(endpointItemTime.cmTime)
        return PlaybackResult(presentedEnd: stableEnd, endpointEnd: endpoint,
            didReachStableEnd: firstItemTime == stableItemTime
                && naturalEndObservation?.stableCurrentTime == stableItemTime)
    }

    func activateForFinalEOSProbe() async throws {
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        guard let activationTicket = try graph.registry.beginOutputActivation(
            contextNonce: context.contextNonce
        ), graph.registry.startOutputActivationOperation(activationTicket),
              case .succeeded = await graph.registry.joinOutputBackendOperation(activationTicket),
              case .armed = backend.activationResult else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
    }

    func verifyStopRacingNaturalEndPublication(stopFirst: Bool) async throws {
        inspectPreparationStorage(stage: "installed")
        _ = try await prepare()
        inspectPreparationStorage(stage: "prepared")
        try await activateForFinalEOSProbe()
        player.pause()
        XCTAssertLessThan(CMTimeCompare(player.currentTime(), try endpointItemTime.cmTime), 0,
            "夹具在准备播放头投递提前EOS；终态应由两次稳定直接读取判为endpointMismatch")
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                        object: player.currentItem)
        try await waitForNaturalEndDeadline()
        XCTAssertTrue(deadlineScheduler.fireNext())
        // fireNext已取出原callback，但其MainActor发布尚未运行。同步stop CAS能确定赢下此序。
        if !stopFirst {
            let result = try await naturalEndTerminalResult()
            XCTAssertEqual(result, .failure(.endpointMismatch), "先到的准确失败终态应发布一次")
        }
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        XCTAssertNotNil(try graph.coordinator.begin(contextNonce: context.contextNonce,
            reason: .stop, at: graph.registry.clock.nowNanoseconds))
        await Self.awaitMainQueueTurn()
        if stopFirst {
            XCTAssertNil(driver.naturalEndTerminalResult, "interval先关闭必须抑制已出队终态")
        } else {
            XCTAssertEqual(driver.naturalEndTerminalResult, .failure(.endpointMismatch),
                "已发布终态保持原结果")
        }
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(driver.fixedTimerCount, 0)
        XCTAssertEqual(deadlineScheduler.activeSlotCount, 0)
        inspectPreparationStorage(stage: "closed-interval")
    }

    private func inspectPreparationStorage(stage: String) {
        var allocations: [UInt: Int] = [:]
        func record(_ role: String, _ pointer: UnsafeRawPointer, _ bytes: Int) {
            let identity = UInt(bitPattern: pointer)
            if let existing = allocations[identity] { XCTAssertEqual(existing, bytes) }
            allocations[identity] = bytes
            print("TASK21_OWNER_STORAGE 真实driver-\(stage) \(role) identity=\(identity) actual=\(bytes)")
        }
        driver.inspectPreparationAllocations(record)
        coordinator.inspectRetainedPreparationRoots(record)
        inspectNativePreparationWeakSideTable("coordinator", coordinator, record)
        evidenceSource.inspectPreparationAllocations(record)
        server.inspectPreparationHistoryAllocations(record)
        print("TASK21_OWNER_STORAGE 真实driver-\(stage)部分根总计=\(allocations.values.reduce(0, +))")
    }

    func emitConstrainedEndpointMutation(sourceTime: ExactMediaTime) async throws {
        let itemTime = try XCTUnwrap(prepared).identity.timelineMappingAuthority
            .playerItemTime(for: sourceTime)
        guard let currentItem = player.currentItem else {
            throw AVPlayerItemCoordinatorFailure.noCurrentItem
        }
        currentItem.forwardPlaybackEndTime = itemTime.cmTime
        player.pause()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                        object: currentItem)
        guard try await naturalEndTerminalResult()
                == .failure(.endpointMismatch) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }

    func emitPrematureFinalEOS(sourceTime: ExactMediaTime) async throws {
        let itemTime = try XCTUnwrap(prepared).identity.timelineMappingAuthority
            .playerItemTime(for: sourceTime)
        _ = try await seekAndAwaitCompletion(to: itemTime, expectedItem: player.currentItem)
        player.pause()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                        object: player.currentItem)
        try await fireNaturalEndDeadline()
        guard try await naturalEndTerminalResult()
                == .failure(.endpointMismatch) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }

    func emitUnstableFinalEOS(firstSourceTime: ExactMediaTime,
                              secondSourceTime: ExactMediaTime) async throws {
        let timeline = try XCTUnwrap(prepared).identity.timelineMappingAuthority
        // 两个调用参数都已经是发布有效窗口内的位置；这里逐一精确映射，不能
        // 在 emitter 内反向解释或重新推导测试输入。
        let first = try timeline.playerItemTime(for: firstSourceTime)
        let second = try timeline.playerItemTime(for: secondSourceTime)
        guard let expectedItem = player.currentItem else {
            throw AVPlayerItemCoordinatorFailure.noCurrentItem
        }
        let expectedConstraint = expectedItem.forwardPlaybackEndTime
        let firstRead = try await seekAndAwaitCompletion(
            to: first, expectedItem: expectedItem)
        player.pause()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                        object: expectedItem)
        try await waitForNaturalEndDeadline()
        let secondRead = try await seekAndAwaitCompletion(
            to: second, expectedItem: expectedItem)
        guard firstRead != secondRead,
              player.currentItem === expectedItem,
              CMTimeCompare(expectedItem.forwardPlaybackEndTime, expectedConstraint) == 0 else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        guard deadlineScheduler.fireNext() else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        guard try await naturalEndTerminalResult()
                == .failure(.unstableDirectRead) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }

    func emitTimedOutFinalEOS(sourceTime: ExactMediaTime) async throws {
        let timeline = try XCTUnwrap(prepared).identity.timelineMappingAuthority
        let first = try timeline.playerItemTime(for: sourceTime.subtracting(
            Task21Fixtures.time(0.25)))
        guard let expectedItem = player.currentItem else {
            throw AVPlayerItemCoordinatorFailure.noCurrentItem
        }
        _ = try await seekAndAwaitCompletion(to: first, expectedItem: expectedItem)
        player.pause()
        guard deadlineScheduler.activeSlotCount == 0 else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        let occupied = deadlineScheduler.occupyAllSlots()
        guard occupied.count == 4 else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        defer { occupied.forEach(deadlineScheduler.cancel) }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification,
                                        object: expectedItem)
        guard try await naturalEndTerminalResult()
                == .failure(.deadlineCapacityExceeded) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }

    private func seekAndAwaitCompletion(
        to target: ExactMediaTime,
        expectedItem: AVPlayerItem?
    ) async throws -> ExactMediaTime {
        guard let expectedItem, player.currentItem === expectedItem else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let completion = FinalLockedSeekCompletion()
        player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) {
            completion.resolve($0)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while completion.value == nil, ContinuousClock.now < deadline {
            await Self.awaitMainQueueTurn()
        }
        guard completion.value == true, player.currentItem === expectedItem else {
            expectedItem.cancelPendingSeeks()
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        return try ExactMediaTime(player.currentTime())
    }

    private func waitForNaturalEndDeadline() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while deadlineScheduler.activeSlotCount == 0,
              driver.naturalEndTerminalResult == nil,
              ContinuousClock.now < deadline {
            await Self.awaitMainQueueTurn()
        }
        guard driver.naturalEndTerminalResult == nil,
              deadlineScheduler.activeSlotCount == 1 else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
    }

    private func fireNaturalEndDeadline() async throws {
        try await waitForNaturalEndDeadline()
        guard deadlineScheduler.fireNext() else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
    }

    private func naturalEndTerminalResult() async throws
        -> AVPlayerNaturalEndTerminalResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while driver.naturalEndTerminalResult == nil,
              ContinuousClock.now < deadline {
            await Self.awaitMainQueueTurn()
        }
        guard let result = driver.naturalEndTerminalResult else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        return result
    }

    func waitForRegisteredSuspend() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (backendSuspendCount == 0 || backendRetireCount == 0),
              ContinuousClock.now < deadline {
            await Self.awaitMainQueueTurn()
        }
        return backendSuspendCount == 1 && backendRetireCount == 1
    }

    /// `Task.yield()` 只让出 Swift executor，不能保证已经排入 main dispatch queue
    /// 的 AVPlayer relay/seek block 得到运行。这个无 sleep barrier 把 continuation
    /// 排在它们之后，既保持固定 deadline，又确保等待的是生产队列真实进展。
    nonisolated private static func awaitMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func validateEndpoint() throws {
        guard prepared != nil,
              let completed = evidenceSource.retainedCompletedPublicationEvidence() else {
            throw AVPlayerItemCoordinatorFailure.noCurrentItem
        }
        try AVPlayerAACEndpointValidator.validate(
            authority: publication.seed.endpointAuthority,
            completedPublication: completed
        )
    }

    /// endpoint admission 的系统媒体链不依赖 AVPlayer readiness：真实 GET 让
    /// Loopback 的 full-body send terminal 签发 Task20 publication evidence。
    func validateEndpointThroughCompletedSocketBodies() async throws {
        let completed = try await primeCompletedSocketBodies()
        try AVPlayerAACEndpointValidator.validate(
            authority: publication.seed.endpointAuthority,
            completedPublication: completed
        )
    }

    /// 只推进真实 Loopback body/send-terminal ledger，不消费 writer endpoint authority；
    /// prepare 随后仍须通过 production evidence source 完成同一 authority 的唯一消费。
    @discardableResult
    func primeCompletedSocketBodies() async throws
        -> LoopbackCompletedPublicationEvidence {
        guard let media = publication.publisher.visible?.media[2] else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let keys = media.initializationResources + media.resources
        var urls = [itemURL]
        urls.append(contentsOf: try keys.map { key in
            let path = try server.path(for: key)
            guard let url = URL(string: path, relativeTo: server.baseURL)?.absoluteURL else {
                throw LoopbackHTTPServerError.invalidConfiguration
            }
            return url
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200, !body.isEmpty else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        }
        // endpoint admission 只消费冻结 playlist 实际引用且完成 full-body terminal 的 URL；
        // writer 中未进入当前呈现窗口的旧 backing 不属于 HTTP 完成前提。
        let expectedMediaKeys = Set(media.resources)
        var completed: LoopbackCompletedPublicationEvidence?
        for _ in 0..<100 {
            if let capability = server.completedPublicationCapability(
                itemURL: itemURL,
                itemGeneration: item.itemGeneration,
                publicationSequence: try XCTUnwrap(
                    publication.publisher.visible?.publicationSequence
                )
            ), let evidence = server.consumeCompletedPublicationCapability(capability),
               let participant = evidence.participants.first(where: {
                   $0.participantID
                    == publication.seed.endpoint.binding.publicationParticipantID.rawValue
               }), Set(participant.completedMedia.map(\.key)).isSuperset(of: expectedMediaKeys) {
                completed = evidence
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let completed else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        return completed
    }

    func shutdown() {
        player.pause()
        driver.replaceCurrentItemWithNil(item: item)
        let ticket = server.closeAdmission()
        guard finalWaitUntil(timeout: 2, condition: {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }) else {
            XCTFail("非 EOS 夹具关闭后仍有 socket owner")
            return
        }
        do {
            try server.drain(cleanupTicket: ticket)
            try server.retire(cleanupTicket: ticket)
        } catch {
            XCTFail("非 EOS 夹具 server cleanup 失败：\(error)")
        }
    }

    /// Final EOS 夹具先加入或登记 Registry 唯一 terminal cleanup，等真实
    /// quiescence/retirement 后才卸载 item；随后关闭 HTTP admission 并证明
    /// socket/send owner 全部归零。任何一层失败都向测试传播。
    func teardown() async throws {
        try await stopAndRetireRegistryOutput()
        guard coordinator.currentItemIdentity == nil,
              coordinator.phase == .quiescent else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        let retainedMetadata = publication.store.preparationLeaseChargeSnapshot(
            ownerSlot: evidenceSource.preparationOwner.slot)
        let ticket = server.closeAdmission()
        guard finalWaitUntil(timeout: 2, condition: {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }) else { throw AVPlayerItemCoordinatorFailure.operationInFlight }
        try server.drain(cleanupTicket: ticket)
        try server.retire(cleanupTicket: ticket)
        guard server.usage.connections == 0,
              server.usage.activeResponses == 0,
              server.usage.distinctBackingBytes == 0,
              server.usage.parserAndStagingBytes == 0 else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        let remainingMetadata = publication.store.preparationLeaseChargeSnapshot(
            ownerSlot: evidenceSource.preparationOwner.slot)
        XCTAssertEqual(Set(remainingMetadata.identities), Set(retainedMetadata.identities),
                       "夹具仍持 prepared/mapping 原 owner，真实退役不能抢退其 metadata 租约")
        XCTAssertEqual(remainingMetadata.charge, retainedMetadata.charge)
        XCTAssertEqual(server.usage.applicationChargedBytes, remainingMetadata.charge.chargedBytes,
                       "socket 全退后只可保留准确原 owner 的 reservation，不能漏掉额外尾")
        inspectPreparationStorage(stage: "quiescent-external-owner")
        _ = publication
    }

    private func stopAndRetireRegistryOutput() async throws {
        try await stopAndRetireTask21RegistryOutput(graph: graph, backend: backend)
    }
}

/// 通用准备负例也必须结束真实 Registry 责任；不能让 EOS 专用闸门将旧
/// backend→coordinator→source 留在原 runner 中，消耗后续测试的两 owner 准入。
@MainActor
private func stopAndRetireTask21RegistryOutput(
    graph: OutputGraphFixture, backend: Task21RegistryBackend
) async throws {
        guard let context = graph.registry.outputResourceContextSnapshot() else { return }
        // natural-end failure 可能已经登记 recovery suspend。必须在 join 原 runner
        // 之前于 Registry 同一事务把原 owner 升级为 terminal；这样沿用原 ticket /
        // lifecycle，replacement 的 current-owner CAS 会失效，不能先换出一个尚无
        // AVPlayerItem 对应物的新 lifecycle。
        let owner = try XCTUnwrap(graph.coordinator.begin(
            contextNonce: context.contextNonce,
            reason: .stop,
            at: graph.registry.clock.nowNanoseconds,
            teardown: true
        ))
        let receiver = Task21FinalEOSCleanupReceiver(
            registry: graph.registry,
            audioLane: graph.lane
        )
        guard graph.registry.startOwnedTerminalCleanup(
            owner: owner,
            receiver: receiver,
            terminalState: .stopped
        ) else {
            backend.allowRetirementCompletion()
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        backend.allowRetirementCompletion()
        await graph.registry.joinOwnedTerminalCleanup(session: context.sessionIdentity)
        try receiver.result()
        guard graph.registry.outputResourceContextSnapshot() == nil,
              graph.registry.ownedResourceSnapshot() == nil,
              graph.registry.cleanupReservationSnapshot() == nil else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
}

@MainActor
private func withFinalEOSFixture(
    _ body: @MainActor (Task21RealIntegrationFixture) async throws -> Void
) async throws {
    let fixture = try await Task21RealIntegrationFixture.makePreparedForFinalEOS()
    var operationError: (any Error)?
    do {
        try await body(fixture)
    } catch {
        operationError = error
    }
    do {
        try await fixture.teardown()
    } catch {
        if let operationError {
            XCTFail("EOS 主断言失败后 cleanup 也失败：\(error)")
            throw operationError
        }
        throw error
    }
    if let operationError { throw operationError }
}

private final class Task21LockedHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Task21RealHLSHarness?
    var value: Task21RealHLSHarness? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class Task21RealHLSHarness: @unchecked Sendable {
    let store: SealedMediaStore
    let seed: Task21RealAACSeed
    let avSeed: Task21RealAVSeed?
    let publisher: HLSPublicationCoordinator
    let declaration: HLSItemDeclaration

    init(token: LoopbackSessionToken, seed: Task21RealAACSeed,
         avSeed: Task21RealAVSeed?, endList: Bool) throws {
        self.seed = seed
        self.avSeed = avSeed
        store = SealedMediaStore(loopbackSession: token, itemGeneration: 19)
        var declared = try Task19.declaration(audioOnly: avSeed == nil)
        declared.token = token.value
        if let avSeed {
            declared.video?.width = Int(avSeed.videoDimensions.width)
            declared.video?.height = Int(avSeed.videoDimensions.height)
            declared.video?.codec = avSeed.videoCodec
            declared.video?.frameRateMilli = 24_000
        }
        declaration = declared
        let candidate: HLSAudioCandidateRegistration?
        if avSeed == nil {
            candidate = try store.registerAudioCandidate(
                initialization: seed.initialization,
                proof: seed.proof,
                declaration: declared
            )
        } else {
            candidate = nil
        }
        let audioInitialization = avSeed?.audioInitialization ?? seed.initialization
        let audioProof = avSeed?.audioProof ?? seed.proof
        let audioRelay = avSeed?.audioRelay ?? seed.relay
        var participants = [HLSInitialParticipant(
            initialization: audioInitialization,
            proof: audioProof,
            relay: audioRelay,
            candidateTicket: candidate?.ticket,
            candidate: candidate,
            aacTerminalBinding: (avSeed?.endpointAuthority ?? seed.endpointAuthority)
                .terminalBinding
        )]
        if let avSeed {
            participants.insert(.init(initialization: avSeed.videoInitialization,
                proof: avSeed.videoProof, relay: avSeed.videoRelay,
                candidateTicket: nil), at: 0)
        }
        publisher = try HLSPublicationCoordinator(store: store,
            participants: participants,
            declaration: declared,
            anchor: .init(mediaOrigin: avSeed?.sourceOrigin ?? Task21Fixtures.time(0),
                          utcMilliseconds: 1_788_912_000_000))
        let audioPackets = avSeed?.audioPackets ?? seed.packets
        let videoPackets = avSeed?.videoPackets ?? []
        let packetCount = max(audioPackets.count, videoPackets.count)
        for index in 0..<packetCount {
            let now: Int64 = index >= 6 ? 1_000_000_000 : 0
            if videoPackets.indices.contains(index) {
                let packet = videoPackets[index]
                _ = try publisher.offer(packet.object, receipt: packet.receipt,
                    relay: packet.relay, ticket: publisher.ticket, now: now)
            }
            if audioPackets.indices.contains(index) {
                let packet = audioPackets[index]
                _ = try publisher.offer(packet.object, receipt: packet.receipt,
                    relay: packet.relay, ticket: publisher.ticket, now: now)
            }
        }
        if avSeed != nil {
            // 首六段建立初始 master/media snapshot；第七段再由同一 publisher
            // 推进真实滑窗，使 requested 三秒后的下一解码段可被系统加载。
            _ = try publisher.publish(ticket: publisher.ticket,
                                      now: 1_000_000_000)
        } else {
            // writer endpoint 的 terminal tail 必须先经同 publisher 的 natural-end
            // CAS 进入真实 HTTP snapshot；测试是否自动播放到尾不改变这项 authority。
            _ = endList
            var now: Int64 = 1_000_000_000
            var reachedEnd = false
            for _ in 0..<8 {
                _ = try publisher.publish(ticket: publisher.ticket, now: now,
                                          naturalEnd: true)
                if publisher.visible?.media.values.allSatisfy({
                    $0.text.hasSuffix("#EXT-X-ENDLIST\n")
                }) == true {
                    reachedEnd = true
                    break
                }
                now += 1_000_000_000
            }
            guard reachedEnd else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        }
    }

}

/// 两个真实集成 selector 共享的 Task15→Task17 产物。媒体字节只来自系统 AAC encoder
/// 与 AVAssetWriter segment callback；这里不构造裸 AAC/fMP4 payload。
final class Task21RealAACSeed: @unchecked Sendable {
    let relay: SegmentReportRelay
    let initialization: SealedMediaObject
    let proof: EpochFormatProof
    let packets: [Task19Packet]
    let endpointAuthority: AACEffectiveEndpointAuthority
    var endpoint: AACEffectiveEndpointReceipt { endpointAuthority.receipt }
    let commonBoundaries: [ExactMediaTime]
    let liveEdge: ExactMediaTime
    fileprivate let encodedBuffers: [CMSampleBuffer]
    fileprivate let streamSummary: AACStreamSummary

    fileprivate init(relay: SegmentReportRelay, initialization: SealedMediaObject,
                 proof: EpochFormatProof, packets: [Task19Packet],
                 endpointAuthority: AACEffectiveEndpointAuthority,
                 encodedBuffers: [CMSampleBuffer], streamSummary: AACStreamSummary) throws {
        self.relay = relay
        self.initialization = initialization
        self.proof = proof
        self.packets = packets
        self.endpointAuthority = endpointAuthority
        self.encodedBuffers = encodedBuffers
        self.streamSummary = streamSummary
        let effectiveEnd = endpointAuthority.receipt.lastEffectiveEnd
        let latestThreeSecondBoundary = try effectiveEnd.subtracting(
            ExactMediaTime(value: 3, timescale: 1)
        )
        commonBoundaries = Array(Set(
            packets.map(\.receipt.presentationRange.start) + [latestThreeSecondBoundary]
        )).sorted { CMTimeCompare($0.cmTime, $1.cmTime) < 0 }
        // PublicationCoverage 的共同末端必须是可呈现有效端点；writer 物理尾端 Q
        // 含 AAC trailing prime，不能拿来计算 E-3 秒的 prepared playhead。
        liveEdge = effectiveEnd
    }

    static func make(itemGeneration: UInt64 = 19,
                     outputLifecycleEpoch: OutputLifecycleEpoch? = nil,
                     layoutLabels: [RenditionChannelLabel] = [.l, .r]) async throws
        -> Task21RealAACSeed {
        try await makePending(itemGeneration: itemGeneration,
                              outputLifecycleEpoch: outputLifecycleEpoch,
                              layoutLabels: layoutLabels).finish()
    }

    /// 只等待不可变 bytes/format/timing 模板。这里不会创建 Registry、writer、
    /// backing、endpoint authority、publisher 或 server。
    static func warmEncodingTemplate() async throws {
        _ = try await stereoEncodedTemplateTask.value
    }

    /// 系统 encoder 只缓存深拷贝后的 bytes/format/timing 描述。每个 fixture 都从
    /// 描述重建独立 block/sample buffer；writer、backing、server、publication 与
    /// 一次性 authority 从不进入缓存，也不在并发 writer 之间共享。
    private static let stereoEncodedTemplateTask = Task<Task21AACEncodedTemplate, Error> {
        try await makeEncodedTemplate(layoutLabels: [.l, .r])
    }

    private static let surround51EncodedTemplateTask = Task<Task21AACEncodedTemplate, Error> {
        try await makeEncodedTemplate(layoutLabels: [.c, .l, .r, .ls, .rs, .lfe])
    }

    private static func makeEncodedTemplate(
        layoutLabels: [RenditionChannelLabel]
    ) async throws -> Task21AACEncodedTemplate {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: layoutLabels),
            capabilityVersion: "task21-real-avplayer-v1")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let channelCount = layoutLabels.count
        let maximumFramesPerChunk = channelCount == 0 ? 0 : 32_768 / channelCount
        guard maximumFramesPerChunk > 0 else {
            throw AACRenditionFailure.invalidLayout
        }
        var remainingFrames = 8 * 48_000
        var sourceFrame = 0
        var encoded: [CMSampleBuffer] = []
        let summary = try encoder.encodeStream(nextPCM: {
            guard remainingFrames > 0 else { return nil }
            let frames = min(8_192, maximumFramesPerChunk, remainingFrames)
            remainingFrames -= frames
            defer { sourceFrame += frames }
            var samples: [Float] = []
            samples.reserveCapacity(frames * channelCount)
            for offset in 0..<frames {
                let value = sin(Float(sourceFrame + offset) * 0.03125) * 0.2
                for channel in 0..<channelCount {
                    // 每个真实声道都由 encoder 消费；轻微的确定性增益差异避免
                    // 6ch 夹具退化成只复制 stereo payload 的伪多声道格式。
                    samples.append(value * Float(channel + 1)
                        / Float(channelCount))
                }
            }
            return samples
        }, append: { encoded.append($0) })
        guard let firstEncoded = encoded.first else {
            throw AACRenditionFailure.invalidInput
        }
        let firstEffectiveStart = CMSampleBufferGetOutputPresentationTimeStamp(firstEncoded)
        var secondBuckets: [[CMSampleBuffer]] = []
        for buffer in encoded {
            let relative = CMTimeSubtract(
                CMSampleBufferGetOutputPresentationTimeStamp(buffer),
                firstEffectiveStart
            )
            let second = max(0, Int(floor(CMTimeGetSeconds(relative))))
            while secondBuckets.count <= second { secondBuckets.append([]) }
            secondBuckets[second].append(buffer)
        }
        let coalesced = try secondBuckets.filter { !$0.isEmpty }.map(coalesce)
        guard let format = CMSampleBufferGetFormatDescription(
            try XCTUnwrap(coalesced.first)
        ) else {
            throw AACRenditionFailure.invalidInput
        }
        let frozenBuffers = try coalesced.map(freezeEncodedBuffer)
        calibrator.cancel()
        try calibrator.finishOnOwnedRunner()
        return Task21AACEncodedTemplate(format: format, buffers: frozenBuffers,
                                        streamSummary: summary)
    }

    private static func encodedTemplate(
        layoutLabels: [RenditionChannelLabel]
    ) async throws -> Task21AACEncodedTemplate {
        if layoutLabels == [.l, .r] {
            return try await stereoEncodedTemplateTask.value
        }
        if layoutLabels == [.c, .l, .r, .ls, .rs, .lfe] {
            return try await surround51EncodedTemplateTask.value
        }
        throw AACRenditionFailure.invalidLayout
    }

    fileprivate static func makePending(
        itemGeneration: UInt64 = 19,
        outputLifecycleEpoch: OutputLifecycleEpoch? = nil,
        layoutLabels: [RenditionChannelLabel] = [.l, .r]
    ) async throws
        -> Task21PendingAACSeed {
        let template = try await encodedTemplate(layoutLabels: layoutLabels)
        let coalesced = try template.buffers.map {
            try makeEncodedBuffer(from: $0, format: template.format)
        }
        let summary = template.streamSummary
        let workspace = AACCalibrationWorkspace()
        let payloadBytes = coalesced.reduce(0) {
            $0 + (CMSampleBufferGetDataBuffer($1).map(CMBlockBufferGetDataLength) ?? 0)
        }
        let epoch = AACEncodedEpoch(identity: summary.identity, buffers: coalesced,
            realSampleCount: Int(summary.realSampleCount),
            totalDecodedFrames: Int(summary.totalDecodedFrames),
            leadingFrames: summary.leadingFrames,
            trailingFrames: Int(summary.trailingFrames),
            actualLeadingPrimeFrames: summary.actualLeadingPrimeFrames,
            actualTrailingPrimeFrames: summary.actualTrailingPrimeFrames,
            bandwidth: summary.bandwidth,
            packetLease: try workspace.acquire(.aacPackets, bytes: payloadBytes),
            formatLease: try workspace.acquire(.nonPayload, bytes: 8_192))
        guard epoch.buffers.count <= 8,
              let first = epoch.buffers.first,
              let format = CMSampleBufferGetFormatDescription(first) else {
            throw AACRenditionFailure.capacityExceeded
        }
        let effectiveStart = CMSampleBufferGetOutputPresentationTimeStamp(first)
        let physicalStart = CMSampleBufferGetPresentationTimeStamp(first)
        let fallback = Task19.binding(id: 2, epoch: 1,
            writer: try PlaybackIdentityAllocator.shared.next(in: .nonce),
            item: itemGeneration)
        let binding = FMP4WriterBinding(
            outputLifecycleEpoch: outputLifecycleEpoch ?? fallback.outputLifecycleEpoch,
            itemGeneration: fallback.itemGeneration,
            mediaEpoch: fallback.mediaEpoch,
            publicationParticipantID: fallback.publicationParticipantID,
            renditionIdentity: fallback.renditionIdentity,
            writerIdentity: fallback.writerIdentity)
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: effectiveStart))
        try boundary.registerAudioRendition(binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstPhysicalStart: physicalStart,
            startTrimSamples: Int64(summary.leadingFrames),
            firstEffectiveStart: effectiveStart)
        let sink = Task19SystemSink(binding: binding)
        let relay = SegmentReportRelay(binding: binding, limits: .audio,
            capacity: 8, objectSink: sink.collect)
        sink.relay = relay
        let writer = try SegmentedFMP4Writer(binding: binding, trackKind: .aac,
            sourceFormatHint: format, boundarySession: boundary.session,
            compressedFormatConfiguration: nil,
            ownershipLimits: .init(rolloverThreshold: 256, hardCapacity: 384),
            relay: relay, systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        try writer.start(at: effectiveStart)
        try writer.appendAACEncodedEpoch(epoch, coordinator: boundary)
        return Task21PendingAACSeed(
            writer: writer, sink: sink, relay: relay, epoch: epoch,
            encodedBuffers: coalesced, streamSummary: summary)
    }

    fileprivate static func finish(_ pending: Task21PendingAACSeed) async throws
        -> Task21RealAACSeed {
        try (await pending.finishWriter()).sealEndpoint()
    }

    /// 只在一个正式的一秒共同边界内部合并 packet；边界后的首个 AU 因而仍落在
    /// `SegmentBoundaryCoordinator` 接受的单个 AAC sample 窗口内。
    private static func coalesce(_ buffers: [CMSampleBuffer]) throws -> CMSampleBuffer {
        guard let first = buffers.first,
              let format = CMSampleBufferGetFormatDescription(first) else {
            throw AACRenditionFailure.invalidInput
        }
        var payload = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for buffer in buffers {
            guard let candidate = CMSampleBufferGetFormatDescription(buffer),
                  CMFormatDescriptionEqual(candidate, otherFormatDescription: format),
                  let block = CMSampleBufferGetDataBuffer(buffer) else {
                throw AACRenditionFailure.invalidInput
            }
            var pointer: UnsafePointer<AudioStreamPacketDescription>?
            var descriptionBytes = 0
            try AACRenditionEncoder.check(
                CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
                    buffer,
                    packetDescriptionsPointerOut: &pointer,
                    sizeOut: &descriptionBytes
                )
            )
            guard let pointer,
                  descriptionBytes == CMSampleBufferGetNumSamples(buffer)
                    * MemoryLayout<AudioStreamPacketDescription>.stride else {
                throw AACRenditionFailure.invalidInput
            }
            for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                var description = pointer[index]
                let byteCount = Int(description.mDataByteSize)
                var bytes = Data(count: byteCount)
                try bytes.withUnsafeMutableBytes { destination in
                    try AACRenditionEncoder.check(CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: Int(description.mStartOffset),
                        dataLength: byteCount,
                        destination: destination.baseAddress!
                    ))
                }
                description.mStartOffset = Int64(payload.count)
                descriptions.append(description)
                payload.append(bytes)
            }
        }
        var block: CMBlockBuffer?
        try AACRenditionEncoder.check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        ))
        try payload.withUnsafeBytes { source in
            try AACRenditionEncoder.check(CMBlockBufferReplaceDataBytes(
                with: source.baseAddress!,
                blockBuffer: try XCTUnwrap(block),
                offsetIntoDestination: 0,
                dataLength: payload.count
            ))
        }
        var result: CMSampleBuffer?
        try AACRenditionEncoder.check(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(block),
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: descriptions.count,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(first),
            packetDescriptions: descriptions,
            sampleBufferOut: &result
        ))
        let combined = try XCTUnwrap(result)
        try AACRenditionEncoder.check(CMSampleBufferSetOutputPresentationTimeStamp(
            combined,
            newValue: CMSampleBufferGetOutputPresentationTimeStamp(first)
        ))
        if let leading = CMGetAttachment(
            first,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            attachmentModeOut: nil
        ) {
            CMSetAttachment(
                combined,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: leading,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        if let last = buffers.last,
           let trailing = CMGetAttachment(
               last,
               key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
               attachmentModeOut: nil
           ) {
            CMSetAttachment(
                combined,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: trailing,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return combined
    }

    private static func freezeEncodedBuffer(_ buffer: CMSampleBuffer) throws
        -> Task21AACEncodedBufferTemplate {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else {
            throw AACRenditionFailure.invalidInput
        }
        let byteCount = CMBlockBufferGetDataLength(block)
        var payload = Data(count: byteCount)
        try payload.withUnsafeMutableBytes { destination in
            try AACRenditionEncoder.check(CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination.baseAddress!
            ))
        }
        var pointer: UnsafePointer<AudioStreamPacketDescription>?
        var descriptionBytes = 0
        try AACRenditionEncoder.check(
            CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
                buffer,
                packetDescriptionsPointerOut: &pointer,
                sizeOut: &descriptionBytes
            )
        )
        let sampleCount = CMSampleBufferGetNumSamples(buffer)
        guard let pointer,
              descriptionBytes == sampleCount
                * MemoryLayout<AudioStreamPacketDescription>.stride else {
            throw AACRenditionFailure.invalidInput
        }
        let descriptions = Array(UnsafeBufferPointer(start: pointer, count: sampleCount))
        return Task21AACEncodedBufferTemplate(
            payload: payload,
            packetDescriptions: descriptions,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
            outputPresentationTimeStamp:
                CMSampleBufferGetOutputPresentationTimeStamp(buffer),
            leadingTrim: trimTime(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart),
            trailingTrim: trimTime(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd))
    }

    private static func makeEncodedBuffer(
        from template: Task21AACEncodedBufferTemplate,
        format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try AACRenditionEncoder.check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: template.payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: template.payload.count,
            flags: 0,
            blockBufferOut: &block
        ))
        try template.payload.withUnsafeBytes { source in
            try AACRenditionEncoder.check(CMBlockBufferReplaceDataBytes(
                with: source.baseAddress!,
                blockBuffer: try XCTUnwrap(block),
                offsetIntoDestination: 0,
                dataLength: template.payload.count
            ))
        }
        var result: CMSampleBuffer?
        try AACRenditionEncoder.check(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(block),
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: template.packetDescriptions.count,
            presentationTimeStamp: template.presentationTimeStamp,
            packetDescriptions: template.packetDescriptions,
            sampleBufferOut: &result
        ))
        let buffer = try XCTUnwrap(result)
        try AACRenditionEncoder.check(CMSampleBufferSetOutputPresentationTimeStamp(
            buffer, newValue: template.outputPresentationTimeStamp
        ))
        if let leadingTrim = template.leadingTrim {
            CMSetAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: CMTimeCopyAsDictionary(leadingTrim,
                    allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if let trailingTrim = template.trailingTrim {
            CMSetAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: CMTimeCopyAsDictionary(trailingTrim,
                    allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return buffer
    }

    fileprivate static func trimTime(_ buffer: CMSampleBuffer,
                                     key: CFString) -> CMTime? {
        guard let value = CMGetAttachment(buffer, key: key,
                                          attachmentModeOut: nil) else {
            return nil
        }
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
        let time = CMTimeMakeFromDictionary((value as! CFDictionary))
        return time.isValid ? time : nil
    }

}

private struct Task21AACEncodedBufferTemplate: @unchecked Sendable {
    let payload: Data
    let packetDescriptions: [AudioStreamPacketDescription]
    let presentationTimeStamp: CMTime
    let outputPresentationTimeStamp: CMTime
    let leadingTrim: CMTime?
    let trailingTrim: CMTime?
}

private final class Task21AACEncodedTemplate: @unchecked Sendable {
    let format: CMAudioFormatDescription
    let buffers: [Task21AACEncodedBufferTemplate]
    let streamSummary: AACStreamSummary

    init(format: CMAudioFormatDescription,
         buffers: [Task21AACEncodedBufferTemplate],
         streamSummary: AACStreamSummary) {
        self.format = format
        self.buffers = buffers
        self.streamSummary = streamSummary
    }
}

private final class Task21PendingAACSeed: @unchecked Sendable {
    let writer: SegmentedFMP4Writer
    let sink: Task19SystemSink
    let relay: SegmentReportRelay
    let epoch: AACEncodedEpoch
    let encodedBuffers: [CMSampleBuffer]
    let streamSummary: AACStreamSummary

    init(writer: SegmentedFMP4Writer, sink: Task19SystemSink,
         relay: SegmentReportRelay, epoch: AACEncodedEpoch,
         encodedBuffers: [CMSampleBuffer], streamSummary: AACStreamSummary) {
        self.writer = writer
        self.sink = sink
        self.relay = relay
        self.epoch = epoch
        self.encodedBuffers = encodedBuffers
        self.streamSummary = streamSummary
    }

    var terminalBinding: AACWriterTerminalBinding {
        get throws { try XCTUnwrap(writer.aacTerminalBinding) }
    }

    func finish() async throws -> Task21RealAACSeed {
        try await Task21RealAACSeed.finish(self)
    }

    func finishWriter() async throws -> Task21FinishedAACSeed {
        _ = try await writer.finish()
        let initialization = try XCTUnwrap(sink.take(.initialization))
        var media: [SealedMediaObject] = []
        while let object = sink.take(.media) { media.append(object) }
        guard media.count >= 6 else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let proof = try FinalFMP4Validator(binding: writer.binding, mediaType: .audio)
            .validateInitialization(initialization)
        let timeline = SegmentTimelineValidator(proof: proof)
        let packets = try media.map { object in
            Task19Packet(object: object,
                receipt: try timeline.validate(object, using: proof), relay: relay)
        }
        return Task21FinishedAACSeed(
            writer: writer, relay: relay, epoch: epoch,
            initialization: initialization, media: media, proof: proof,
            packets: packets, encodedBuffers: encodedBuffers,
            streamSummary: streamSummary)
    }
}

private final class Task21FinishedAACSeed: @unchecked Sendable {
    let writer: SegmentedFMP4Writer
    let relay: SegmentReportRelay
    let epoch: AACEncodedEpoch
    let initialization: SealedMediaObject
    let media: [SealedMediaObject]
    let proof: EpochFormatProof
    let packets: [Task19Packet]
    let encodedBuffers: [CMSampleBuffer]
    let streamSummary: AACStreamSummary

    init(writer: SegmentedFMP4Writer, relay: SegmentReportRelay,
         epoch: AACEncodedEpoch, initialization: SealedMediaObject,
         media: [SealedMediaObject], proof: EpochFormatProof,
         packets: [Task19Packet], encodedBuffers: [CMSampleBuffer],
         streamSummary: AACStreamSummary) {
        self.writer = writer
        self.relay = relay
        self.epoch = epoch
        self.initialization = initialization
        self.media = media
        self.proof = proof
        self.packets = packets
        self.encodedBuffers = encodedBuffers
        self.streamSummary = streamSummary
    }

    func sealEndpoint() throws -> Task21RealAACSeed {
        let authority = try writer.makeAACEffectiveEndpointAuthority(
            epoch: epoch, initializationObject: initialization,
            mediaObjects: media)
        return try Task21RealAACSeed(
            relay: relay, initialization: initialization, proof: proof,
            packets: packets, endpointAuthority: authority,
            encodedBuffers: encodedBuffers, streamSummary: streamSummary)
    }
}

private final class FinalWriterTerminalHTTPFixture: @unchecked Sendable {
    let publication: FinalWriterTerminalPublicationHarness
    let server: LoopbackHTTPServer
    let bundle: LoopbackAVPlayerPreparationBundle
    let publicationSequence: UInt64

    private init(publication: FinalWriterTerminalPublicationHarness,
                 server: LoopbackHTTPServer,
                 bundle: LoopbackAVPlayerPreparationBundle,
                 publicationSequence: UInt64) {
        self.publication = publication
        self.server = server
        self.bundle = bundle
        self.publicationSequence = publicationSequence
    }

    static func start(pending: Task21PendingAACSeed,
                      item: AVPlayerItemInstanceIdentity) async throws
        -> FinalWriterTerminalHTTPFixture {
        let box = FinalLockedValue<FinalWriterTerminalPublicationHarness>()
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: 19, now: { 0 }, logger: { _ in },
            responseFailure: { _, _ in }
        ) { token in
            let publication = try FinalWriterTerminalPublicationHarness(
                token: token, pending: pending)
            box.value = publication
            return LoopbackPreparedPublication(
                store: publication.store,
                declaration: publication.declaration,
                snapshot: try XCTUnwrap(publication.publisher.visible))
        }
        let publication = try XCTUnwrap(box.value)
        let pendingPublication = try publication.publisher
            .reserveNextPublicationForPreparation()
        let expectedSequence = try XCTUnwrap(publication.publisher.visible)
            .publicationSequence + 1
        let bundle = try LoopbackAVPlayerPreparationBundle(
            server: server, item: item,
            pendingPublication: pendingPublication)
        XCTAssertEqual(bundle.request.publicationSequence, expectedSequence)
        return FinalWriterTerminalHTTPFixture(
            publication: publication, server: server, bundle: bundle,
            publicationSequence: expectedSequence)
    }

    static func startPrefix(pending: Task21PendingAACSeed,
                            item: AVPlayerItemInstanceIdentity) async throws
        -> FinalWriterTerminalHTTPFixture {
        let box = FinalLockedValue<FinalWriterTerminalPublicationHarness>()
        let server = try await LoopbackHTTPSessionFactory().start(
            itemGeneration: 19, now: { 0 }, logger: { _ in },
            responseFailure: { _, _ in }
        ) { token in
            let publication = try FinalWriterTerminalPublicationHarness(
                token: token, pending: pending,
                includeRenditionBinding: true)
            box.value = publication
            return LoopbackPreparedPublication(
                store: publication.store,
                declaration: publication.declaration,
                snapshot: try XCTUnwrap(publication.publisher.visible))
        }
        let publication = try XCTUnwrap(box.value)
        let sequence = try XCTUnwrap(publication.publisher.visible)
            .publicationSequence
        let bundle = try LoopbackAVPlayerPreparationBundle(
            server: server, item: item, publicationSequence: sequence)
        return FinalWriterTerminalHTTPFixture(
            publication: publication, server: server, bundle: bundle,
            publicationSequence: sequence)
    }

    func finishWriter() async throws -> Task21FinishedAACSeed {
        try await publication.finishWriter()
    }

    func publishNaturalEnd(seed: Task21RealAACSeed) throws {
        try publication.publishNaturalEnd(seed: seed,
                                          expectedSequence: publicationSequence)
    }

    func serveCompletedPublication() async throws {
        let media = try XCTUnwrap(publication.publisher.visible?.media[2])
        var urls = [bundle.request.itemURL]
        urls += try (media.initializationResources + media.resources).map { key in
            try XCTUnwrap(URL(
                string: server.path(for: key),
                relativeTo: server.baseURL)?.absoluteURL)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (body, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertFalse(body.isEmpty)
        }
        let terminalKey = try XCTUnwrap(publication.publisher.visible?.media[2]?.resources.last)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while server.currentAudioSelectionCapability(
            itemGeneration: 19,
            publicationSequence: publicationSequence
        ) == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        guard let capability = server.completedPublicationCapability(
            itemURL: bundle.request.itemURL, itemGeneration: 19,
            publicationSequence: publicationSequence),
              let evidence = server.consumeCompletedPublicationCapability(capability),
              evidence.participants.first(where: { $0.participantID == 2 })?
                .completedMedia.contains(where: { $0.key == terminalKey }) == true else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }

    func serveCurrentPublication() async throws {
        let media = try XCTUnwrap(
            publication.publisher.visible?.media[2])
        var urls = [bundle.request.itemURL]
        urls += try (media.initializationResources + media.resources).map { key in
            try XCTUnwrap(URL(string: server.path(for: key),
                              relativeTo: server.baseURL)?.absoluteURL)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for url in urls {
            let (body, response) = try await session.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(body.isEmpty)
        }
    }

    func shutdown() {
        _ = finalWaitUntil(timeout: 2) {
            server.usage.connections == 0 && server.usage.activeResponses == 0
        }
        let ticket = server.closeAdmission()
        try? server.drain(cleanupTicket: ticket)
        try? server.retire(cleanupTicket: ticket)
    }
}

private final class FinalWriterTerminalPublicationHarness: @unchecked Sendable {
    let store: SealedMediaStore
    let declaration: HLSItemDeclaration
    let publisher: HLSPublicationCoordinator
    private let pending: Task21PendingAACSeed
    private let initialization: SealedMediaObject
    private let proof: EpochFormatProof
    private let timeline: SegmentTimelineValidator
    private var media: [SealedMediaObject]
    private var packets: [Task19Packet]

    init(token: LoopbackSessionToken, pending: Task21PendingAACSeed,
         includeRenditionBinding: Bool = false) throws {
        self.pending = pending
        initialization = try XCTUnwrap(pending.sink.take(.initialization))
        var initialMedia: [SealedMediaObject] = []
        while let object = pending.sink.take(.media) { initialMedia.append(object) }
        guard initialMedia.count >= 6 else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let initialProof = try FinalFMP4Validator(binding: pending.writer.binding,
                                                  mediaType: .audio)
            .validateInitialization(initialization)
        let initialTimeline = SegmentTimelineValidator(proof: initialProof)
        let initialPackets = try initialMedia.map { object in
            Task19Packet(object: object,
                receipt: try initialTimeline.validate(object, using: initialProof),
                relay: pending.relay)
        }
        proof = initialProof
        timeline = initialTimeline
        media = initialMedia
        packets = initialPackets
        store = SealedMediaStore(loopbackSession: token, itemGeneration: 19)
        var declaration = try Task19.declaration(audioOnly: true)
        declaration.token = token.value
        self.declaration = declaration
        let candidate = try store.registerAudioCandidate(
            initialization: initialization,
            proof: proof,
            declaration: declaration)
        publisher = try HLSPublicationCoordinator(
            store: store,
            participants: [.init(
                initialization: initialization,
                proof: proof,
                relay: pending.relay,
                candidateTicket: candidate.ticket,
                candidate: candidate,
                aacTerminalBinding: try pending.terminalBinding,
                aacRenditionBinding: includeRenditionBinding
                    ? pending.writer.aacRenditionTerminalBinding : nil)],
            declaration: declaration,
            anchor: .init(mediaOrigin: Task21Fixtures.time(0),
                          utcMilliseconds: 1_788_912_000_000))
        for (index, packet) in packets.enumerated() {
            _ = try publisher.offer(
                packet.object, receipt: packet.receipt, relay: pending.relay,
                ticket: publisher.ticket,
                now: index >= 6 ? 1_000_000_000 : 0)
        }
        if publisher.visible == nil {
            _ = try publisher.publish(ticket: publisher.ticket,
                                      now: 1_000_000_000)
        }
    }

    func finishWriter() async throws -> Task21FinishedAACSeed {
        _ = try await pending.writer.finish()
        var tail: [SealedMediaObject] = []
        while let object = pending.sink.take(.media) { tail.append(object) }
        let tailPackets = try tail.map { object in
            Task19Packet(object: object,
                receipt: try timeline.validate(object, using: proof),
                relay: pending.relay)
        }
        for packet in tailPackets {
            _ = try publisher.offer(packet.object, receipt: packet.receipt,
                relay: pending.relay, ticket: publisher.ticket,
                now: 2_000_000_000)
        }
        media.append(contentsOf: tail)
        packets.append(contentsOf: tailPackets)
        return Task21FinishedAACSeed(
            writer: pending.writer, relay: pending.relay, epoch: pending.epoch,
            initialization: initialization, media: media, proof: proof,
            packets: packets, encodedBuffers: pending.encodedBuffers,
            streamSummary: pending.streamSummary)
    }

    func publishNaturalEnd(seed: Task21RealAACSeed,
                           expectedSequence: UInt64) throws {
        guard seed.endpointAuthority.terminalBinding === (try pending.terminalBinding) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        _ = try publisher.publish(ticket: publisher.ticket,
                                  now: 3_000_000_000,
                                  naturalEnd: true)
        guard publisher.visible?.publicationSequence == expectedSequence,
              publisher.visible?.media.values.allSatisfy({
                  $0.text.hasSuffix("#EXT-X-ENDLIST\n")
              }) == true else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
    }
}

private final class FinalLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?
    var value: Value? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private func finalWaitUntil(timeout: TimeInterval,
                            condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    } while Date() < deadline
    return condition()
}

/// 独立的真实 A/V readiness 夹具。音频仍来自 Task15 系统 AAC encoder，视频来自
/// production VTVideoEncoder；两轨再进入共享 Task17 boundary session 和各自的系统 writer。
/// 这里只验证 master/两轨共同三秒 coverage，AAC 尾端权威仍由上面的未改写音频链验证。
final class Task21RealAVSeed: @unchecked Sendable {
    struct AdditionalAudio: @unchecked Sendable {
        let relay: SegmentReportRelay
        let initialization: SealedMediaObject
        let proof: EpochFormatProof
        let packets: [Task19Packet]
        let endpointAuthority: AACEffectiveEndpointAuthority
    }

    let audioRelay: SegmentReportRelay
    let audioInitialization: SealedMediaObject
    let audioProof: EpochFormatProof
    let audioPackets: [Task19Packet]
    let endpointAuthority: AACEffectiveEndpointAuthority
    let videoRelay: SegmentReportRelay
    let videoInitialization: SealedMediaObject
    let videoProof: EpochFormatProof
    let videoPackets: [Task19Packet]
    let sourceOrigin: ExactMediaTime
    let commonBoundaries: [ExactMediaTime]
    let liveEdge: ExactMediaTime
    let videoDimensions: CMVideoDimensions
    let videoCodec: String
    let additionalAudio: AdditionalAudio?

    private init(audioRelay: SegmentReportRelay,
                 audioInitialization: SealedMediaObject,
                 audioProof: EpochFormatProof,
                 audioPackets: [Task19Packet],
                 endpointAuthority: AACEffectiveEndpointAuthority,
                 videoRelay: SegmentReportRelay,
                 videoInitialization: SealedMediaObject,
                 videoProof: EpochFormatProof,
                 videoPackets: [Task19Packet],
                 sourceOrigin: ExactMediaTime,
                 commonBoundaries: [ExactMediaTime],
                 liveEdge: ExactMediaTime,
                 videoDimensions: CMVideoDimensions,
                 videoCodec: String,
                 additionalAudio: AdditionalAudio?) {
        self.audioRelay = audioRelay
        self.audioInitialization = audioInitialization
        self.audioProof = audioProof
        self.audioPackets = audioPackets
        self.endpointAuthority = endpointAuthority
        self.videoRelay = videoRelay
        self.videoInitialization = videoInitialization
        self.videoProof = videoProof
        self.videoPackets = videoPackets
        self.sourceOrigin = sourceOrigin
        self.commonBoundaries = commonBoundaries
        self.liveEdge = liveEdge
        self.videoDimensions = videoDimensions
        self.videoCodec = videoCodec
        self.additionalAudio = additionalAudio
    }

    static func make(audio: Task21RealAACSeed,
                     additionalAudioSeed: Task21RealAACSeed? = nil,
                     additionalAudioParticipantID: UInt64? = nil) async throws
        -> Task21RealAVSeed {
        // 普通 A/V 仍冻结 7 个共同一秒段。dual-audio 专用夹具只送 6 个
        // 编码块：系统 writer 的最终 flush 段因此仍落在 HLS 最多 7 段的
        // 可见窗口内，两个 terminal media key 都能由同一 snapshot 广告。
        let inputBufferCount = additionalAudioSeed == nil ? 7 : 6
        let retimedAudioBuckets = try retimedUntrimmedAudio(
            Array(audio.encodedBuffers.prefix(inputBufferCount))
        )
        let retimedAudio = try additionalAudioSeed == nil
            ? retimedAudioBuckets
            : splitAACAccessUnits(retimedAudioBuckets)
        guard retimedAudio.count >= 6,
              let firstAudio = retimedAudio.first,
              let audioFormat = CMSampleBufferGetFormatDescription(firstAudio) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let sourceStart = CMSampleBufferGetOutputPresentationTimeStamp(firstAudio)
        let sourceOrigin = try ExactMediaTime(sourceStart)
        guard (additionalAudioSeed == nil) == (additionalAudioParticipantID == nil) else {
            throw AVPlayerItemCoordinatorFailure.staleIdentity
        }
        let additionalRetimedAudio = try additionalAudioSeed.map { seed in
            let buckets = try retimedUntrimmedAudio(
                Array(seed.encodedBuffers.prefix(inputBufferCount)),
                startingAt: sourceStart)
            return try splitAACAccessUnits(buckets)
        }
        let additionalAudioFormat = additionalRetimedAudio?.first.flatMap {
            CMSampleBufferGetFormatDescription($0)
        }
        if additionalAudioSeed != nil {
            guard retimedAudio.count <= 384,
                  let additionalRetimedAudio,
                  additionalRetimedAudio.count >= 6,
                  additionalRetimedAudio.count <= 384,
                  additionalAudioFormat != nil else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        }
        // reencodedClosedGOP 要求 IDR 精确落在共同秒边界；24fps 的整数秒
        // cadence 能满足该合同，不能拿 AAC 的 1024/48000 AU cadence 充当视频帧率。
        let frameDuration = CMTime(value: 1, timescale: 24)
        let inputAudioEnd = retimedAudio.reduce(sourceStart) { _, buffer in
            CMTimeAdd(CMSampleBufferGetOutputPresentationTimeStamp(buffer),
                      CMSampleBufferGetDuration(buffer))
        }
        let audioDuration = CMTimeSubtract(inputAudioEnd, sourceStart)
        let frameCount: Int
        if additionalAudioSeed != nil {
            let exactDuration = try ExactMediaTime(audioDuration)
            let completeSeconds = exactDuration.value
                / Int64(exactDuration.timescale)
            let product = completeSeconds.multipliedReportingOverflow(by: 24)
            guard completeSeconds > 0, !product.overflow,
                  let exactFrameCount = Int(exactly: product.partialValue) else {
                throw AVPlayerItemCoordinatorFailure.capacityExceeded
            }
            // dual-audio 的视频只覆盖不超过两条 AAC 有效窗口的完整秒。
            // 24fps 整数帧数让系统 writer 精确停在共同秒边界，不能用
            // ceil 制造一个不足一秒、且没有音频同伴的尾部 segment。
            frameCount = exactFrameCount
        } else {
            frameCount = Int(ceil(CMTimeGetSeconds(audioDuration) * 24))
        }
        guard frameCount >= 6 * 24, frameCount <= 9 * 24 else {
            throw AVPlayerItemCoordinatorFailure.capacityExceeded
        }
        let videoOutputs = try await encodeVideo(
            frameCount: frameCount,
            start: sourceStart,
            duration: frameDuration
        )
        guard let firstVideo = videoOutputs.first,
              let videoFormat = CMSampleBufferGetFormatDescription(firstVideo.sampleBuffer) else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }

        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
            epochStart: sourceStart,
            videoMode: .reencodedClosedGOP
        ))
        let audioFallback = Task19.binding(id: 2, epoch: 1,
            writer: try PlaybackIdentityAllocator.shared.next(in: .nonce), item: 19)
        let videoFallback = Task19.binding(id: 1, epoch: 1,
            writer: try PlaybackIdentityAllocator.shared.next(in: .nonce), item: 19)
        let additionalAudioFallback = try additionalAudioParticipantID.map { participantID in
            Task19.binding(id: participantID, epoch: 1,
                writer: try PlaybackIdentityAllocator.shared.next(in: .nonce), item: 19)
        }
        let lifecycle = audio.proof.binding.outputLifecycleEpoch
        let audioBinding = FMP4WriterBinding(outputLifecycleEpoch: lifecycle,
            itemGeneration: audioFallback.itemGeneration,
            mediaEpoch: audioFallback.mediaEpoch,
            publicationParticipantID: audioFallback.publicationParticipantID,
            renditionIdentity: audioFallback.renditionIdentity,
            writerIdentity: audioFallback.writerIdentity)
        let videoBinding = FMP4WriterBinding(outputLifecycleEpoch: lifecycle,
            itemGeneration: videoFallback.itemGeneration,
            mediaEpoch: videoFallback.mediaEpoch,
            publicationParticipantID: videoFallback.publicationParticipantID,
            renditionIdentity: videoFallback.renditionIdentity,
            writerIdentity: videoFallback.writerIdentity)
        let additionalAudioBinding = additionalAudioFallback.map {
            FMP4WriterBinding(outputLifecycleEpoch: lifecycle,
                itemGeneration: $0.itemGeneration,
                mediaEpoch: $0.mediaEpoch,
                publicationParticipantID: $0.publicationParticipantID,
                renditionIdentity: $0.renditionIdentity,
                writerIdentity: $0.writerIdentity)
        }
        try boundary.registerAudioRendition(audioBinding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000), firstEffectiveStart: sourceStart)
        if let additionalAudioBinding {
            try boundary.registerAudioRendition(additionalAudioBinding.renditionIdentity,
                accessUnit: .aac(sampleRate: 48_000), firstEffectiveStart: sourceStart)
        }

        let audioSink = Task19SystemSink(binding: audioBinding)
        let videoSink = Task19SystemSink(binding: videoBinding)
        let additionalAudioSink = additionalAudioBinding.map(Task19SystemSink.init(binding:))
        let audioRelay = SegmentReportRelay(binding: audioBinding, limits: .audio,
            capacity: 8, objectSink: audioSink.collect)
        let videoRelay = SegmentReportRelay(binding: videoBinding, limits: .video,
            capacity: 8, objectSink: videoSink.collect)
        let additionalAudioRelay = additionalAudioBinding.map { binding in
            SegmentReportRelay(binding: binding, limits: .audio,
                capacity: 8, objectSink: additionalAudioSink!.collect)
        }
        audioSink.relay = audioRelay
        videoSink.relay = videoRelay
        additionalAudioSink?.relay = additionalAudioRelay
        let ownership = SegmentedFMP4WriterOwnershipLimits(
            rolloverThreshold: 256,
            hardCapacity: 384
        )
        let audioWriter = try SegmentedFMP4Writer(binding: audioBinding,
            trackKind: .aac, sourceFormatHint: audioFormat,
            boundarySession: boundary.session, compressedFormatConfiguration: nil,
            ownershipLimits: ownership, relay: audioRelay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        let videoWriter = try SegmentedFMP4Writer(binding: videoBinding,
            trackKind: .video, sourceFormatHint: videoFormat,
            boundarySession: boundary.session, compressedFormatConfiguration: nil,
            ownershipLimits: ownership, relay: videoRelay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        let additionalAudioWriter = try additionalAudioBinding.map { binding in
            try SegmentedFMP4Writer(binding: binding,
                trackKind: .aac,
                sourceFormatHint: try XCTUnwrap(additionalAudioFormat),
                boundarySession: boundary.session, compressedFormatConfiguration: nil,
                ownershipLimits: ownership, relay: additionalAudioRelay!,
                systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        }
        try audioWriter.start(at: sourceStart)
        try videoWriter.start(at: sourceStart)
        try additionalAudioWriter?.start(at: sourceStart)

        var videoIndex = 0
        var accumulatedAudioEpoch: AACEncodedEpoch?
        var accumulatedAdditionalAudioEpoch: AACEncodedEpoch?
        if let additionalAudioWriter, let additionalAudioSeed,
           let additionalRetimedAudio {
            func makeCompleteEpoch(
                _ buffers: [CMSampleBuffer],
                seed: Task21RealAACSeed
            ) throws -> AACEncodedEpoch {
                let counts = try aacEpochCounts(buffers)
                let bytes = buffers.reduce(0) { partial, buffer in
                    partial + (CMSampleBufferGetDataBuffer(buffer)
                        .map(CMBlockBufferGetDataLength) ?? 0)
                }
                let workspace = AACCalibrationWorkspace()
                return AACEncodedEpoch(
                    identity: seed.streamSummary.identity,
                    buffers: buffers, realSampleCount: counts.real,
                    totalDecodedFrames: counts.total,
                    leadingFrames: counts.leading,
                    trailingFrames: counts.trailing,
                    actualLeadingPrimeFrames: UInt32(counts.leading),
                    actualTrailingPrimeFrames: UInt32(counts.trailing),
                    bandwidth: seed.streamSummary.bandwidth,
                    packetLease: try workspace.acquire(.aacPackets, bytes: bytes),
                    formatLease: try workspace.acquire(.nonPayload, bytes: 1_024))
            }
            func appendAccessUnit(
                _ buffer: CMSampleBuffer,
                from completeEpoch: AACEncodedEpoch,
                to writer: SegmentedFMP4Writer
            ) throws {
                let counts = try aacEpochCounts([buffer])
                let chunk = AACEncodedEpoch(
                    identity: completeEpoch.identity,
                    buffers: [buffer], realSampleCount: counts.real,
                    totalDecodedFrames: counts.total,
                    leadingFrames: counts.leading,
                    trailingFrames: counts.trailing,
                    actualLeadingPrimeFrames: UInt32(counts.leading),
                    actualTrailingPrimeFrames: UInt32(counts.trailing),
                    bandwidth: completeEpoch.bandwidth,
                    packetLease: completeEpoch.packetLease,
                    formatLease: completeEpoch.formatLease)
                try writer.appendAACEncodedEpoch(chunk, coordinator: boundary)
            }
            let audioEpoch = try makeCompleteEpoch(retimedAudio, seed: audio)
            let additionalEpoch = try makeCompleteEpoch(
                additionalRetimedAudio,
                seed: additionalAudioSeed)
            accumulatedAudioEpoch = audioEpoch
            accumulatedAdditionalAudioEpoch = additionalEpoch
            var audioIndex = 0
            var additionalAudioIndex = 0
            // 视频以 PTS、音频以 AU 结束时刻排序：这样越过共同边界的首个
            // AAC AU 前，video IDR 已先把该边界放进固定四槽；p2/p4 同时刻
            // 固定按 p2→p4，任一路都不会跑到另一条 rendition 前面。
            while videoIndex < videoOutputs.count
                    || audioIndex < audioEpoch.buffers.count
                    || additionalAudioIndex < additionalEpoch.buffers.count {
                let audioEnd = audioIndex < audioEpoch.buffers.count
                    ? CMTimeAdd(
                        CMSampleBufferGetOutputPresentationTimeStamp(
                            audioEpoch.buffers[audioIndex]),
                        CMSampleBufferGetDuration(audioEpoch.buffers[audioIndex]))
                    : .positiveInfinity
                let additionalEnd = additionalAudioIndex < additionalEpoch.buffers.count
                    ? CMTimeAdd(
                        CMSampleBufferGetOutputPresentationTimeStamp(
                            additionalEpoch.buffers[additionalAudioIndex]),
                        CMSampleBufferGetDuration(
                            additionalEpoch.buffers[additionalAudioIndex]))
                    : .positiveInfinity
                let videoStart = videoIndex < videoOutputs.count
                    ? CMSampleBufferGetPresentationTimeStamp(
                        videoOutputs[videoIndex].sampleBuffer)
                    : .positiveInfinity
                if videoIndex < videoOutputs.count,
                   CMTimeCompare(videoStart, audioEnd) <= 0,
                   CMTimeCompare(videoStart, additionalEnd) <= 0 {
                    let output = videoOutputs[videoIndex]
                    try videoWriter.appendVideo(output,
                        ticket: boundary.issueVideoAppend(for: output,
                            writerBinding: videoBinding))
                    videoIndex += 1
                } else if audioIndex < audioEpoch.buffers.count,
                          CMTimeCompare(audioEnd, additionalEnd) <= 0 {
                    try appendAccessUnit(audioEpoch.buffers[audioIndex],
                        from: audioEpoch, to: audioWriter)
                    audioIndex += 1
                } else {
                    let buffer = additionalEpoch.buffers[additionalAudioIndex]
                    try appendAccessUnit(buffer, from: additionalEpoch,
                                         to: additionalAudioWriter)
                    additionalAudioIndex += 1
                }
            }
        } else {
            let workspace = AACCalibrationWorkspace()
            for buffer in retimedAudio {
                let bufferEnd = CMTimeAdd(
                    CMSampleBufferGetOutputPresentationTimeStamp(buffer),
                    CMSampleBufferGetDuration(buffer)
                )
                while videoIndex < videoOutputs.count,
                      CMTimeCompare(
                        CMSampleBufferGetPresentationTimeStamp(
                            videoOutputs[videoIndex].sampleBuffer
                        ),
                        bufferEnd
                      ) < 0 {
                    let output = videoOutputs[videoIndex]
                    try videoWriter.appendVideo(output,
                        ticket: boundary.issueVideoAppend(for: output,
                            writerBinding: videoBinding))
                    videoIndex += 1
                }
                let decoded = CMSampleBufferGetNumSamples(buffer) * 1_024
                let bytes = CMSampleBufferGetDataBuffer(buffer)
                    .map(CMBlockBufferGetDataLength) ?? 0
                let epoch = AACEncodedEpoch(identity: audio.streamSummary.identity,
                    buffers: [buffer], realSampleCount: decoded,
                    totalDecodedFrames: decoded, leadingFrames: 0, trailingFrames: 0,
                    actualLeadingPrimeFrames: 0, actualTrailingPrimeFrames: 0,
                    bandwidth: audio.streamSummary.bandwidth,
                    packetLease: try workspace.acquire(.aacPackets, bytes: bytes),
                    formatLease: try workspace.acquire(.nonPayload, bytes: 1_024))
                try audioWriter.appendAACEncodedEpoch(epoch, coordinator: boundary)
            }
            while videoIndex < videoOutputs.count {
                let output = videoOutputs[videoIndex]
                try videoWriter.appendVideo(output,
                    ticket: boundary.issueVideoAppend(for: output,
                        writerBinding: videoBinding))
                videoIndex += 1
            }
        }
        _ = try await audioWriter.finish()
        _ = try await videoWriter.finish()
        if let additionalAudioWriter { _ = try await additionalAudioWriter.finish() }

        let audioInitialization = try XCTUnwrap(audioSink.take(.initialization))
        let videoInitialization = try XCTUnwrap(videoSink.take(.initialization))
        let additionalAudioInitialization = try additionalAudioSink.map {
            try XCTUnwrap($0.take(.initialization))
        }
        let audioObjects = drainMedia(audioSink)
        let videoObjects = drainMedia(videoSink)
        let additionalAudioObjects = additionalAudioSink.map(drainMedia) ?? []
        let requiredObjectCount = additionalAudioSeed == nil ? 7 : 6
        guard audioObjects.count >= requiredObjectCount,
              videoObjects.count >= requiredObjectCount else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        if additionalAudioWriter != nil,
           additionalAudioObjects.count < requiredObjectCount {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let audioProof = try FinalFMP4Validator(binding: audioBinding, mediaType: .audio)
            .validateInitialization(audioInitialization)
        let videoProof = try FinalFMP4Validator(binding: videoBinding, mediaType: .video)
            .validateInitialization(videoInitialization)
        let additionalAudioProof = try additionalAudioBinding.map { binding in
            try FinalFMP4Validator(binding: binding, mediaType: .audio)
                .validateInitialization(try XCTUnwrap(additionalAudioInitialization))
        }
        let audioTimeline = SegmentTimelineValidator(proof: audioProof)
        let videoTimeline = SegmentTimelineValidator(proof: videoProof)
        let selectedAudioObjects = additionalAudioSeed == nil
            ? Array(audioObjects.prefix(7)) : audioObjects
        let selectedVideoObjects = additionalAudioSeed == nil
            ? Array(videoObjects.prefix(7)) : videoObjects
        if additionalAudioSeed != nil {
            guard audioObjects.count <= 7, videoObjects.count <= 7,
                  additionalAudioObjects.count <= 7 else {
                throw AVPlayerItemCoordinatorFailure.insufficientCoverage
            }
        }
        let audioPackets = try selectedAudioObjects.map {
            Task19Packet(object: $0,
                receipt: try audioTimeline.validate($0, using: audioProof),
                relay: audioRelay)
        }
        let videoPackets = try selectedVideoObjects.map {
            Task19Packet(object: $0,
                receipt: try videoTimeline.validate($0, using: videoProof),
                relay: videoRelay)
        }
        let additionalAudioPackets = try additionalAudioProof.map { proof in
            let timeline = SegmentTimelineValidator(proof: proof)
            return try additionalAudioObjects.map {
                Task19Packet(object: $0,
                    receipt: try timeline.validate($0, using: proof),
                    relay: additionalAudioRelay!)
            }
        }
        let commonBoundaries = videoPackets.map(\.receipt.presentationRange.start)
        guard commonBoundaries.count >= 6,
              let videoStart = videoPackets.first?.receipt.presentationRange.start,
              let audioEnd = audioPackets.last?.receipt.presentationRange.end,
              let videoEnd = videoPackets.last?.receipt.presentationRange.end,
              try HLSChecked.compare(
                videoEnd.subtracting(videoStart),
                ExactMediaTime(value: 3, timescale: 1)) >= 0 else {
            throw AVPlayerItemCoordinatorFailure.insufficientCoverage
        }
        let liveEdge = CMTimeCompare(audioEnd.cmTime, videoEnd.cmTime) <= 0
            ? audioEnd : videoEnd
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let codec = try XCTUnwrap(
            videoInitialization.publicationEvidence?.format.codec
        )
        let endpointEpoch: AACEncodedEpoch
        if let accumulatedAudioEpoch {
            endpointEpoch = accumulatedAudioEpoch
        } else {
            let endpointWorkspace = AACCalibrationWorkspace()
            let endpointByteCount = retimedAudio.reduce(0) { partial, buffer in
                partial + (CMSampleBufferGetDataBuffer(buffer)
                    .map(CMBlockBufferGetDataLength) ?? 0)
            }
            let counts = try aacEpochCounts(retimedAudio)
            endpointEpoch = AACEncodedEpoch(identity: audio.streamSummary.identity,
                buffers: retimedAudio, realSampleCount: counts.real,
                totalDecodedFrames: counts.total,
                leadingFrames: counts.leading, trailingFrames: counts.trailing,
                actualLeadingPrimeFrames: UInt32(counts.leading),
                actualTrailingPrimeFrames: UInt32(counts.trailing),
                bandwidth: audio.streamSummary.bandwidth,
                packetLease: try endpointWorkspace.acquire(.aacPackets,
                                                            bytes: endpointByteCount),
                formatLease: try endpointWorkspace.acquire(.nonPayload, bytes: 1_024))
        }
        let endpointAuthority = try audioWriter.makeAACEffectiveEndpointAuthority(
            epoch: endpointEpoch, initializationObject: audioInitialization,
            mediaObjects: audioObjects)
        let additionalAudio: AdditionalAudio?
        if let additionalAudioWriter, let additionalAudioRelay,
           let additionalAudioInitialization, let additionalAudioProof,
           let additionalAudioPackets {
            let additionalEndpointEpoch = try XCTUnwrap(
                accumulatedAdditionalAudioEpoch)
            let additionalEndpointAuthority = try additionalAudioWriter
                .makeAACEffectiveEndpointAuthority(
                    epoch: additionalEndpointEpoch,
                    initializationObject: additionalAudioInitialization,
                    mediaObjects: additionalAudioObjects)
            additionalAudio = AdditionalAudio(
                relay: additionalAudioRelay,
                initialization: additionalAudioInitialization,
                proof: additionalAudioProof,
                packets: additionalAudioPackets,
                endpointAuthority: additionalEndpointAuthority)
        } else {
            additionalAudio = nil
        }
        return Task21RealAVSeed(audioRelay: audioRelay,
            audioInitialization: audioInitialization, audioProof: audioProof,
            audioPackets: audioPackets, endpointAuthority: endpointAuthority,
            videoRelay: videoRelay,
            videoInitialization: videoInitialization, videoProof: videoProof,
            videoPackets: videoPackets, sourceOrigin: sourceOrigin,
            commonBoundaries: commonBoundaries, liveEdge: liveEdge,
            videoDimensions: dimensions, videoCodec: codec,
            additionalAudio: additionalAudio)
    }

    private static func retimedUntrimmedAudio(
        _ buffers: [CMSampleBuffer],
        startingAt requestedStart: CMTime? = nil
    ) throws
        -> [CMSampleBuffer] {
        guard let first = buffers.first else { return [] }
        var next = requestedStart
            ?? CMSampleBufferGetOutputPresentationTimeStamp(first)
        return try buffers.map { original in
            guard let format = CMSampleBufferGetFormatDescription(original),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFramesPerPacket > 0,
                  asbd.mSampleRate.rounded(.towardZero) == asbd.mSampleRate,
                  let sampleRate = Int32(exactly: asbd.mSampleRate),
                  let framesPerPacket = Int64(exactly: asbd.mFramesPerPacket) else {
                throw AACRenditionFailure.invalidInput
            }
            let packetCount = CMSampleBufferGetNumSamples(original)
            let frameCount = framesPerPacket.multipliedReportingOverflow(
                by: Int64(packetCount))
            guard !frameCount.overflow else {
                throw AACRenditionFailure.invalidInput
            }
            let packetDuration = CMTime(value: framesPerPacket,
                                        timescale: sampleRate)
            let bufferDuration = CMTime(value: frameCount.partialValue,
                                        timescale: sampleRate)
            var copied: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: packetDuration,
                presentationTimeStamp: next,
                decodeTimeStamp: .invalid)
            try AACRenditionEncoder.check(CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: original,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &copied
            ))
            let buffer = try XCTUnwrap(copied)
            CMRemoveAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
            CMRemoveAttachment(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
            try AACRenditionEncoder.check(CMSampleBufferSetOutputPresentationTimeStamp(
                        buffer,
                        newValue: next
            ))
            next = CMTimeAdd(next, bufferDuration)
            return buffer
        }
    }

    /// dual-audio 先固定六个真实秒桶，再把每个压缩 packet 拆回一个 AAC AU。
    /// boundary 因而逐 AU 看到 1024/48k cadence；payload、format 与双 PTS
    /// 均来自系统编码结果，trim 只允许留在完整 epoch 的首尾。
    private static func splitAACAccessUnits(
        _ buffers: [CMSampleBuffer]
    ) throws -> [CMSampleBuffer] {
        guard let first = buffers.first, let last = buffers.last else { return [] }
        let leadingTrim = Task21RealAACSeed.trimTime(first,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        let trailingTrim = Task21RealAACSeed.trimTime(last,
            key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        let expectedPayloadBytes = buffers.reduce(0) { partial, buffer in
            partial + (CMSampleBufferGetDataBuffer(buffer)
                .map(CMBlockBufferGetDataLength) ?? 0)
        }
        var accessUnits: [CMSampleBuffer] = []
        accessUnits.reserveCapacity(buffers.reduce(0) {
            $0 + CMSampleBufferGetNumSamples($1)
        })
        for buffer in buffers {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFramesPerPacket > 0,
                  asbd.mSampleRate.rounded(.towardZero) == asbd.mSampleRate,
                  let sampleRate = Int32(exactly: asbd.mSampleRate),
                  let framesPerPacket = Int64(exactly: asbd.mFramesPerPacket),
                  CMSampleBufferGetNumSamples(buffer) > 0 else {
                throw AACRenditionFailure.invalidInput
            }
            let physicalBase = CMSampleBufferGetPresentationTimeStamp(buffer)
            let outputBase = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
            guard physicalBase.isNumeric, outputBase.isNumeric else {
                throw AACRenditionFailure.invalidInput
            }
            let packetDuration = CMTime(value: framesPerPacket,
                                        timescale: sampleRate)
            for sampleIndex in 0..<CMSampleBufferGetNumSamples(buffer) {
                var ranged: CMSampleBuffer?
                try AACRenditionEncoder.check(CMSampleBufferCopySampleBufferForRange(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: buffer,
                    sampleRange: CFRange(location: sampleIndex, length: 1),
                    sampleBufferOut: &ranged
                ))
                let offset = CMTime(value: Int64(sampleIndex) * framesPerPacket,
                                    timescale: sampleRate)
                let physicalStart = CMTimeAdd(physicalBase, offset)
                let outputStart = CMTimeAdd(outputBase, offset)
                var timing = CMSampleTimingInfo(
                    duration: packetDuration,
                    presentationTimeStamp: physicalStart,
                    decodeTimeStamp: .invalid)
                var retimed: CMSampleBuffer?
                try AACRenditionEncoder.check(CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: try XCTUnwrap(ranged),
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleBufferOut: &retimed
                ))
                let accessUnit = try XCTUnwrap(retimed)
                try AACRenditionEncoder.check(
                    CMSampleBufferSetOutputPresentationTimeStamp(
                        accessUnit, newValue: outputStart))
                CMRemoveAttachment(accessUnit,
                    key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
                CMRemoveAttachment(accessUnit,
                    key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
                guard CMSampleBufferGetNumSamples(accessUnit) == 1,
                      CMFormatDescriptionEqual(
                        try XCTUnwrap(CMSampleBufferGetFormatDescription(accessUnit)),
                        otherFormatDescription: format),
                      CMTimeCompare(
                        CMSampleBufferGetPresentationTimeStamp(accessUnit),
                        physicalStart) == 0,
                      CMTimeCompare(
                        CMSampleBufferGetOutputPresentationTimeStamp(accessUnit),
                        outputStart) == 0,
                      CMTimeCompare(CMSampleBufferGetDuration(accessUnit),
                                    packetDuration) == 0 else {
                    throw AACRenditionFailure.invalidInput
                }
                accessUnits.append(accessUnit)
            }
        }
        if let leadingTrim, let firstAccessUnit = accessUnits.first {
            CMSetAttachment(firstAccessUnit,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: CMTimeCopyAsDictionary(leadingTrim,
                    allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if let trailingTrim, let lastAccessUnit = accessUnits.last {
            CMSetAttachment(lastAccessUnit,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                value: CMTimeCopyAsDictionary(trailingTrim,
                    allocator: kCFAllocatorDefault)!,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        let actualPayloadBytes = accessUnits.reduce(0) { partial, buffer in
            partial + (CMSampleBufferGetDataBuffer(buffer)
                .map(CMBlockBufferGetDataLength) ?? 0)
        }
        guard !accessUnits.isEmpty,
              accessUnits.count <= 384,
              actualPayloadBytes == expectedPayloadBytes else {
            throw AACRenditionFailure.capacityExceeded
        }
        return accessUnits
    }

    private static func aacEpochCounts(
        _ buffers: [CMSampleBuffer]
    ) throws -> (real: Int, total: Int, leading: Int, trailing: Int) {
        guard !buffers.isEmpty else { throw AACRenditionFailure.invalidInput }
        var total = 0
        var leading = 0
        var trailing = 0
        for (index, buffer) in buffers.enumerated() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFramesPerPacket > 0,
                  asbd.mSampleRate.rounded(.towardZero) == asbd.mSampleRate,
                  let sampleRate = Int32(exactly: asbd.mSampleRate),
                  let framesPerPacket = Int(exactly: asbd.mFramesPerPacket) else {
                throw AACRenditionFailure.invalidInput
            }
            let decoded = CMSampleBufferGetNumSamples(buffer)
                .multipliedReportingOverflow(by: framesPerPacket)
            let nextTotal = total.addingReportingOverflow(decoded.partialValue)
            guard !decoded.overflow, !nextTotal.overflow else {
                throw AACRenditionFailure.capacityExceeded
            }
            let startTrim = try trimFrames(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                sampleRate: sampleRate)
            let endTrim = try trimFrames(buffer,
                key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                sampleRate: sampleRate)
            guard (index == 0 || startTrim == 0),
                  (index == buffers.count - 1 || endTrim == 0),
                  startTrim + endTrim <= decoded.partialValue else {
                throw AACRenditionFailure.invalidInput
            }
            if index == 0 { leading = startTrim }
            if index == buffers.count - 1 { trailing = endTrim }
            total = nextTotal.partialValue
        }
        let trims = leading.addingReportingOverflow(trailing)
        let real = total.subtractingReportingOverflow(trims.partialValue)
        guard !trims.overflow, !real.overflow, real.partialValue >= 0 else {
            throw AACRenditionFailure.capacityExceeded
        }
        return (real.partialValue, total, leading, trailing)
    }

    private static func trimFrames(
        _ buffer: CMSampleBuffer,
        key: CFString,
        sampleRate: Int32
    ) throws -> Int {
        guard let time = Task21RealAACSeed.trimTime(buffer, key: key) else {
            return 0
        }
        let scaled = CMTimeConvertScale(time, timescale: sampleRate,
                                        method: .default)
        guard time.isNumeric, scaled.isNumeric,
              CMTimeCompare(time, scaled) == 0,
              scaled.value >= 0,
              let result = Int(exactly: scaled.value) else {
            throw AACRenditionFailure.invalidInput
        }
        return result
    }

    private static func encodeVideo(frameCount: Int, start: CMTime,
                                    duration: CMTime) async throws
        -> [HLSVideoEncodedOutput] {
        let format = VideoEncodingInputFormatSignature(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 320, height: 180, bitDepth: 8, range: .video,
            primaries: .bt709, transfer: .bt709, matrix: .bt709,
            cleanAperture: nil, sampleAspectRatio: nil,
            chromaLocation: .init(topField: "Left", bottomField: "Left"),
            masteringDisplayColorVolume: nil, contentLightLevelInfo: nil
        )
        var optionalSession: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: format.width, height: format.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: format.pixelFormat,
                kCVPixelBufferWidthKey as String: format.width,
                kCVPixelBufferHeightKey as String: format.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &optionalSession) == noErr,
              let session = optionalSession else {
            throw VTVideoEncoderFailure.hardwareEncoderNotActive
        }
        defer { VTCompressionSessionInvalidate(session) }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 24)),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 24)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1)),
            (kVTCompressionPropertyKey_ProfileLevel,
             kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_ColorPrimaries,
             kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction,
             kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix,
             kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                throw VTVideoEncoderFailure.propertySet(key as String, status)
            }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            throw VTVideoEncoderFailure.hardwareEncoderNotActive
        }
        let generation = MediaGeneration(rawValue: 21)
        let firstIdentity = VideoEncodingFrameIdentity(generation: generation,
            accessUnitID: 1, sequenceNumber: 1)
        let hardwareProof = VTHardwareEncoderProof(
            sessionID: .init(rawValue: try PlaybackIdentityAllocator.shared.next(in: .nonce)),
            generation: generation,
            firstOutputIdentity: firstIdentity,
            profile: .h264High
        )
        let collector = Task21VideoOutputCollector(capacity: frameCount)
        for index in 0..<frameCount {
            let pixelBuffer = try makePixelBuffer(format: format, frame: index)
            let identity = VideoEncodingFrameIdentity(generation: generation,
                accessUnitID: UInt64(index + 1),
                sequenceNumber: UInt64(index + 1))
            let pts = CMTimeAdd(start,
                CMTimeMultiply(duration, multiplier: Int32(index)))
            let forceKeyFrame: CFDictionary? = index % 24 == 0
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
                : nil
            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: forceKeyFrame,
                infoFlagsOut: &flags) { status, infoFlags, sampleBuffer in
                    collector.receive(status: status, infoFlags: infoFlags,
                        sampleBuffer: sampleBuffer, identity: identity,
                        format: format, hardwareProof: hardwareProof)
            }
            guard status == noErr else {
                throw VTVideoEncoderFailure.encode(status)
            }
        }
        guard VTCompressionSessionCompleteFrames(session,
            untilPresentationTimeStamp: .invalid) == noErr else {
            throw VTVideoEncoderFailure.noEncodedOutput
        }
        return try collector.finish(expectedCount: frameCount)
    }

    private static func makePixelBuffer(
        format: VideoEncodingInputFormatSignature,
        frame: Int
    ) throws -> CVPixelBuffer {
        var raw: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(format.width),
            Int(format.height), format.pixelFormat, attributes as CFDictionary,
            &raw) == kCVReturnSuccess, let buffer = raw else {
            throw VTVideoEncoderFailure.invalidPixelBuffer
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw VTVideoEncoderFailure.invalidPixelBuffer
        }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw VTVideoEncoderFailure.invalidPixelBuffer
            }
            let value: UInt8 = plane == 0 ? UInt8(32 + frame % 160) : 128
            memset(base, Int32(value),
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        func set(_ key: CFString, _ value: CFTypeRef) {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        set(kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        set(kCVImageBufferChromaLocationTopFieldKey, "Left" as CFString)
        set(kCVImageBufferChromaLocationBottomFieldKey, "Left" as CFString)
        return buffer
    }

    private static func drainMedia(_ sink: Task19SystemSink) -> [SealedMediaObject] {
        var result: [SealedMediaObject] = []
        while let object = sink.take(.media) { result.append(object) }
        return result
    }
}

/// VideoToolbox 可以在收到后续帧或 flush 前暂存输出，因此测试夹具必须先批量提交，
/// 再一次性完成编码。collector 固定容量并在同一锁域内记录首个终态，避免逐帧
/// continuation 与编码器内部缓冲形成互等，也避免 teardown 遗留未恢复 waiter。
private final class Task21VideoOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var outputs: [HLSVideoEncodedOutput] = []
    private var failure: Error?

    init(capacity: Int) {
        self.capacity = capacity
        outputs.reserveCapacity(capacity)
    }

    func receive(status: OSStatus, infoFlags: VTEncodeInfoFlags,
                 sampleBuffer: CMSampleBuffer?,
                 identity: VideoEncodingFrameIdentity,
                 format: VideoEncodingInputFormatSignature,
                 hardwareProof: VTHardwareEncoderProof) {
        lock.withLock {
            guard failure == nil else { return }
            guard status == noErr,
                  !infoFlags.contains(.frameDropped),
                  let sampleBuffer else {
                failure = VTVideoEncoderFailure.callback(status)
                return
            }
            guard outputs.count < capacity else {
                failure = AVPlayerItemCoordinatorFailure.capacityExceeded
                return
            }
            outputs.append(HLSVideoEncodedOutput(
                sourceIdentity: identity,
                sampleBuffer: sampleBuffer,
                presentationOrigin: .raw,
                inputFormatSignature: format,
                hardwareProof: hardwareProof
            ))
        }
    }

    func finish(expectedCount: Int) throws -> [HLSVideoEncodedOutput] {
        try lock.withLock {
            if let failure { throw failure }
            guard expectedCount == capacity, outputs.count == expectedCount else {
                throw VTVideoEncoderFailure.noEncodedOutput
            }
            let ordered = outputs.sorted {
                $0.sourceIdentity.sequenceNumber < $1.sourceIdentity.sequenceNumber
            }
            guard ordered.enumerated().allSatisfy({ index, output in
                output.sourceIdentity.sequenceNumber == UInt64(index + 1)
            }) else {
                throw VTVideoEncoderFailure.noEncodedOutput
            }
            return ordered
        }
    }
}

private enum Task21Fixtures {
    static let proofIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000002101")!
    static let segmentReceiptIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000002102")!
    static let writerReceiptIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000002103")!
    static let mappingReportIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000002104")!
    static let playlistSnapshotIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000002105")!
    static let initializationBacking = SealedMediaBackingIdentity(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000002106")!)
    static let mediaBacking = SealedMediaBackingIdentity(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000002107")!)
    static let oneSample = 1.0 / 48_000.0
    static let uninformativeURIs = [
        URL(string: "http://127.0.0.1/master.m3u8")!,
        URL(string: "http://127.0.0.1/video/index.m3u8")!,
        URL(string: "https://example.invalid/external.m4s")!,
    ]

    static func time(_ seconds: Double) -> ExactMediaTime {
        ExactMediaTime(value: Int64((seconds * 48_000).rounded()), timescale: 48_000)
    }

    static func binding(seed: UInt64) -> FMP4WriterBinding {
        FMP4WriterBinding(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: seed),
            itemGeneration: .init(rawValue: seed + 1),
            mediaEpoch: .init(rawValue: seed + 2),
            publicationParticipantID: .init(rawValue: seed + 3),
            renditionIdentity: .init(rawValue: seed + 4),
            writerIdentity: .init(rawValue: seed + 5)
        )
    }

    static func request(item: AVPlayerItemInstanceIdentity, liveEdge: ExactMediaTime,
                        boundaries: [ExactMediaTime],
                        directAudioOnlyRendition: AudioRenditionIdentity?,
                        requiresAACEndpointAuthority: Bool = false)
        -> AVPlayerItemPreparationRequest {
        let rendition = directAudioOnlyRendition ?? .init(rawValue: 2)
        return AVPlayerItemPreparationRequest(
            itemURL: URL(string: "http://127.0.0.1:49152/v1/token/91/master.m3u8")!,
            item: item,
            publicationSequence: 7,
            audioParticipants: [.init(renditionIdentity: rendition,
                codec: requiresAACEndpointAuthority ? .aac : .explicitlyNonAAC,
                terminalBinding: nil)],
            directAudioOnlyRendition: directAudioOnlyRendition
        )
    }

    static func staleLifecycleItem(from item: AVPlayerItemInstanceIdentity) -> AVPlayerItemInstanceIdentity {
        .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 88_001),
              itemGeneration: item.itemGeneration)
    }

    static func staleGenerationItem(from item: AVPlayerItemInstanceIdentity) -> AVPlayerItemInstanceIdentity {
        .init(outputLifecycleEpoch: item.outputLifecycleEpoch,
              itemGeneration: item.itemGeneration + 1)
    }

    static func suspendTicket(lifecycle: OutputLifecycleEpoch, activation: ActivationEpoch?,
                              nonce: UInt64) -> OutputSuspendTicket {
        let resource = ControlResourceIdentity.outputLifecycle(lifecycle)
        let owner = ControlTaskOwnerTicket(resourceIdentity: resource, nonce: nonce)
        let group = ControlTaskGroupTicket(resourceIdentity: resource, ownerTicket: owner,
                                           nonce: nonce + 1)
        return OutputSuspendTicket(task: .init(group: group, nonce: nonce + 2),
                                   lifecycle: lifecycle, priorActivation: activation,
                                   anchorInstant: nonce + 3)
    }

    static func closeClaim(item: AVPlayerItemInstanceIdentity, activation: ActivationEpoch,
                           suspend: OutputSuspendTicket, nonce: UInt64)
        -> PotentiallyAudibleOutputCloseClaim {
        .init(intervalKey: .init(backendObjectNonce: nonce,
            backendIdentity: item.outputLifecycleEpoch.backendIdentity,
            outputLifecycle: item.outputLifecycleEpoch,
            itemGeneration: item.itemGeneration,
            activation: activation), suspendTicket: suspend, stopNonce: nonce + 1)
    }

    static func endpointDependency() -> AVPlayerCoverageDependencyEvidence {
        .init(mediaEpoch: 41_002, epochProofIdentity: proofIdentity,
              segmentReceiptIdentity: segmentReceiptIdentity,
              initializationBackingIdentity: initializationBacking,
              mediaBackingIdentity: mediaBacking,
              initializationBodyCompleted: true, mediaBodyCompleted: true)
    }

    static func replacing(_ value: AACEffectiveEndpointReceipt, trailing: Int64,
                          real: Int64, end: ExactMediaTime) -> AACEffectiveEndpointReceipt {
        .init(writerReceiptIdentity: value.writerReceiptIdentity, binding: value.binding,
              encoderIdentity: value.encoderIdentity, sampleRate: value.sampleRate,
              inputPhysicalBase: value.inputPhysicalBase,
              inputEffectiveBase: value.inputEffectiveBase,
              writtenPhysicalBase: value.writtenPhysicalBase,
              writtenEffectiveBase: value.writtenEffectiveBase,
              timelineOffset: value.timelineOffset, realSampleCount: real,
              totalDecodedFrames: value.totalDecodedFrames, leadingFrames: value.leadingFrames,
              trailingFrames: trailing, inputEvidenceCount: value.inputEvidenceCount,
              inputEvidenceDigest: value.inputEvidenceDigest,
              callbackEvidenceCount: value.callbackEvidenceCount,
              callbackEvidenceDigest: value.callbackEvidenceDigest,
              mappingReportIdentity: value.mappingReportIdentity,
              initializationBackingIdentity: value.initializationBackingIdentity,
              firstMedia: value.firstMedia, terminalMedia: value.terminalMedia,
              terminalLogicalSequence: value.terminalLogicalSequence,
              lastEffectiveEnd: end,
              terminalPhysicalEnd: value.terminalPhysicalEnd)
    }
}
