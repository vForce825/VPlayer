// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class PlaybackAudioRouteServiceTests: XCTestCase {
    func testAuthoritativeHDMISamplePublishesSystemOutputTiming() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .hdmi)
        harness.sdk.setOutputTiming(outputLatency: 0.080, ioBufferDuration: 0.020)
        try await harness.acquireWithoutNotification()
        let received = RouteSnapshotRecorder()
        harness.service.addSubscriber { snapshot in received.append(snapshot) }
        XCTAssertNil(received.last, "最新 SDK 样本必须通过既有稳定提交后才能发布")

        await harness.advanceThroughStabilityWindow()

        let snapshot = try XCTUnwrap(received.last)
        XCTAssertEqual(snapshot.category, .hdmi)
        XCTAssertEqual(snapshot.outputLatency, 0.080, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.ioBufferDuration, 0.020, accuracy: 0.000_001)
        XCTAssertEqual(harness.routeGetterCallCount, 1)
    }

    func testLateSubscriberReplaysCommittedOutputTimingWithoutReadingNewSDKState() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .hdmi)
        harness.sdk.setOutputTiming(outputLatency: 0.080, ioBufferDuration: 0.020)
        try await harness.acquireWithoutNotification()
        await harness.advanceThroughStabilityWindow()

        // 尚未通过新 sampler 的 SDK 状态不能覆盖已经提交的时序证据。
        harness.sdk.setOutputTiming(outputLatency: 0.500, ioBufferDuration: 0.050)
        let received = RouteSnapshotRecorder()
        harness.service.addSubscriber { snapshot in received.append(snapshot) }

        let snapshot = try XCTUnwrap(received.last)
        XCTAssertEqual(snapshot.outputLatency, 0.080, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.ioBufferDuration, 0.020, accuracy: 0.000_001)
        XCTAssertEqual(harness.routeGetterCallCount, 1,
            "迟到订阅只能重放原 commit，不得在订阅回调旁路读取 SDK")
    }

    func testOutputTimingRefreshKeepsRouteSemanticAndOriginalStabilityDeadline() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .hdmi)
        harness.sdk.setOutputTiming(outputLatency: 0.080, ioBufferDuration: 0.020)
        try await harness.acquireWithoutNotification()
        guard case .pending(let firstPending) = harness.registry.outputRouteObservationSnapshot() else {
            return XCTFail("首次真实样本必须等待稳定提交")
        }
        let firstObservation = try XCTUnwrap(firstPending.ticket)
        let firstTicket = try XCTUnwrap(try harness.registry.armOutputRouteStability(observation: firstObservation))
        let received = RouteSnapshotRecorder()
        harness.service.addSubscriber { snapshot in received.append(snapshot) }

        harness.clock.advance(nanoseconds: 60_000_000)
        harness.sdk.setOutputTiming(outputLatency: 0.120, ioBufferDuration: 0.030)
        harness.service.resample(reason: .unknown)
        try await harness.flushRouteSampler()
        guard case .pending(let refreshedPending) = harness.registry.outputRouteObservationSnapshot() else {
            return XCTFail("重采样完成后必须等待原稳定窗口")
        }
        let refreshedObservation = try XCTUnwrap(refreshedPending.ticket)
        let refreshedTicket = try XCTUnwrap(try harness.registry.armOutputRouteStability(observation: refreshedObservation))
        XCTAssertEqual(refreshedTicket.authority.semanticIdentity, firstTicket.authority.semanticIdentity,
            "输出延迟是样本时序，不能创建另一种端点或配置身份")
        XCTAssertEqual(refreshedTicket.anchorInstant, firstTicket.anchorInstant)
        XCTAssertEqual(refreshedTicket.deadlineInstant, firstTicket.deadlineInstant,
            "相同语义的新延迟不能重新延长 120ms 稳定窗口")
        XCTAssertNil(received.last)

        harness.clock.advance(nanoseconds: 65_000_000)
        harness.clock.fireDeadlineTimerEarly()
        harness.registry.executor.sync {}

        let snapshot = try XCTUnwrap(received.last)
        XCTAssertEqual(snapshot.outputLatency, 0.120, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.ioBufferDuration, 0.030, accuracy: 0.000_001)
        XCTAssertEqual(harness.routeGetterCallCount, 2,
            "每组时序数据必须来自各自的一次授权 route getter")
        XCTAssertEqual(harness.registry.stableRouteCommitSnapshot()?.authority.semanticIdentity,
            firstTicket.authority.semanticIdentity)
    }

    func testInvalidSDKOutputTimingClearsOnlyInvalidFieldAndKeepsUsableRoute() async throws {
        let cases: [(TimeInterval, TimeInterval, TimeInterval, TimeInterval)] = [
            (-0.080, 0.020, 0, 0.020),
            (0.080, -0.020, 0.080, 0),
            (.nan, 0.020, 0, 0.020),
            (0.080, .nan, 0.080, 0),
            (.infinity, 0.020, 0, 0.020),
            (0.080, .infinity, 0.080, 0),
        ]
        for (index, values) in cases.enumerated() {
            let harness = RouteServiceTestHarness(initialPorts: .hdmi)
            harness.sdk.setOutputTiming(outputLatency: values.0, ioBufferDuration: values.1)
            try await harness.acquireWithoutNotification()
            await harness.advanceThroughStabilityWindow()
            let received = RouteSnapshotRecorder()
            harness.service.addSubscriber { snapshot in received.append(snapshot) }

            let snapshot = try XCTUnwrap(received.last, "第 \(index) 组异常时序不能使有效 HDMI 端点消失")
            XCTAssertEqual(snapshot.category, .hdmi)
            XCTAssertTrue(snapshot.outputLatency.isFinite)
            XCTAssertTrue(snapshot.ioBufferDuration.isFinite)
            XCTAssertGreaterThanOrEqual(snapshot.outputLatency, 0)
            XCTAssertGreaterThanOrEqual(snapshot.ioBufferDuration, 0)
            XCTAssertEqual(snapshot.outputLatency, values.2, accuracy: 0.000_001)
            XCTAssertEqual(snapshot.ioBufferDuration, values.3, accuracy: 0.000_001)
            XCTAssertEqual(harness.routeGetterCallCount, 1)
        }
    }

    func testLateSubscriberReceivesCommittedBluetoothRoute() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .bluetooth)
        try await harness.acquireWithoutNotification()
        await harness.advanceThroughStabilityWindow()
        XCTAssertEqual(harness.committedBackend, .sampleBuffer)

        let received = RouteSnapshotRecorder()
        harness.service.addSubscriber { snapshot in received.append(snapshot) }

        let snapshot = try XCTUnwrap(received.last)
        XCTAssertEqual(snapshot.category, .bluetooth)
        XCTAssertEqual(snapshot.ports, [.bluetooth])
        XCTAssertGreaterThan(snapshot.revision, 0)
    }

    func testLateSubscriberReplayIsSerializedWithRouteCommits() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .bluetooth)
        try await harness.acquireWithoutNotification()
        await harness.advanceThroughStabilityWindow()

        let received = RouteSnapshotRecorder()
        let executor = harness.registry.executor
        harness.service.addSubscriber { snapshot in
            received.append(snapshot, onControlExecutor: executor.isIsolated)
        }

        XCTAssertEqual(received.last?.category, .bluetooth)
        XCTAssertEqual(received.lastDeliveryOnControlExecutor, true)
    }

    func testRebindingDoesNotReplayPreviousSessionRoute() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .bluetooth)
        try await harness.acquireWithoutNotification()
        await harness.advanceThroughStabilityWindow()
        harness.service.unbindSession()

        let received = RouteSnapshotRecorder()
        harness.service.addSubscriber { snapshot in received.append(snapshot) }

        XCTAssertNil(received.last)
    }

    func testStabilityArmsAndSessionRebindingReuseOneFixedHandler() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .airPlay)
        XCTAssertEqual(harness.clock.deadlineTimerHandlerInstallationCount, 1,
            "长期source在构造时安装一个固定handler，不让每张票产生新的逃逸捕获")
        try await harness.acquireWithoutNotification()
        harness.registry.executor.sync {}
        XCTAssertEqual(harness.clock.deadlineTimerHandlerInstallationCount, 1)
        let registration = try XCTUnwrap(harness.registration)
        harness.service.unbindSession()
        harness.service.bindSession(registration: registration)
        harness.service.resample(reason: .unknown)
        try await harness.flushRouteSampler()
        XCTAssertEqual(harness.clock.deadlineTimerHandlerInstallationCount, 1,
            "换票和解绑只操作固定槽，不能替换handler")
        await harness.advanceThroughStabilityWindow()
        XCTAssertEqual(harness.committedBackend, .hlsAVPlayer)
    }

    func testAlreadyQueuedStabilityWakeCannotCommitAfterUnbind() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .airPlay)
        try await harness.acquireWithoutNotification()
        harness.registry.executor.sync {
            // 回调已排到同executor，但解绑在其执行前完成。
            harness.clock.advance(nanoseconds: 125_000_000)
            harness.service.unbindSession()
        }
        harness.registry.executor.sync {}
        XCTAssertNil(harness.committedBackend,
            "取消排期不撤销已排队回调；旧wake必须看到原稳定票已经撤销")
        XCTAssertNil(harness.registry.stableRouteCommitSnapshot())
    }

    func testDestroyedSystemMonitorUnregistersItsOriginalObservers() {
        let center = Task9ObserverLifetimeNotificationCenter()
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        weak var releasedMonitor: SystemAudioEventMonitor?
        autoreleasepool {
            let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress,
                notificationCenter: center)
            releasedMonitor = monitor
            monitor.start()
        }
        XCTAssertNil(releasedMonitor)
        XCTAssertEqual(center.installedCount, 2)
        XCTAssertEqual(center.removedCount, 2,
            "runtime析构后NotificationCenter不能永久保留旧monitor的弱引用holder")
    }

    func testUnusedProductionRouteServiceCanBeReleasedBeforeAnySessionIsBound() throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let owner = try PlaybackAudioSessionOwner(registry: registry)
        weak var releasedService: PlaybackAudioRouteService?
        autoreleasepool {
            let service = PlaybackAudioRouteService(registry: registry, owner: owner)
            releasedService = service
            withExtendedLifetime(service) {}
        }
        XCTAssertNil(releasedService)
        XCTAssertNil(registry.outputResourceContextSnapshot())
    }

    func testAcquireWithoutNotificationAdvancesThroughStabilityWindowAndCommitsAirPlay() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.airPlay])
        try await harness.acquireWithoutNotification()
        await harness.advanceThroughStabilityWindow()
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.hlsAVPlayer)
        XCTAssertEqual(harness.routeGetterCallCount, 1)
        XCTAssertEqual(harness.categoryCallCount, 1)
    }

    func testAcquireWithHDMIPortsCommitsSampleBuffer() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.hdmi])
        try await harness.acquireWithoutNotification()
        await harness.advanceThroughStabilityWindow()
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.sampleBuffer)
    }

    func testUnbindThenRebindReusesTheSameLiveStabilityTimer() async throws {
        let harness = RouteServiceTestHarness(initialPorts: .airPlay)
        try await harness.acquireWithoutNotification()
        let registration = try XCTUnwrap(harness.registration)
        harness.service.unbindSession()
        harness.service.bindSession(registration: registration)
        harness.service.resample(reason: .unknown)
        try await harness.flushRouteSampler()
        await harness.advanceThroughStabilityWindow()
        XCTAssertEqual(harness.committedBackend, .hlsAVPlayer,
            "解绑只撤销本次session排期，不能永久cancel进程runtime复用的timer")
    }

    func testTimerFiresEarlyDoesNotCommit() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.airPlay])
        try await harness.acquireWithoutNotification()
        harness.clock.advance(nanoseconds: 119_000_000)
        harness.clock.fireDeadlineTimerEarly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertNil(harness.committedBackend)
        
        harness.clock.advance(nanoseconds: 1_000_000)
        harness.clock.fireDeadlineTimerEarly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.hlsAVPlayer)
    }

    func testSystemInterruptionBeginsAndEnds() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.airPlay])
        let ingress = harness.registry.executor.safetyIngress
        _ = SystemAudioEventMonitor(safetyIngress: ingress, notificationCenter: .default)
        
        ingress.performSyncIngress(PlaybackSystemSafetyEvent.interruptionBegan)
        try await harness.acquireWithoutNotification()
        await harness.advanceThroughStabilityWindow()
        XCTAssertNil(harness.committedBackend)
        // 保留同一acquisition/lease。配置可在中断中完成，但不能靠便捷取消再申请来恢复。
        for _ in 0..<500 {
            if case .complete = harness.registry.registeredAudioSessionPhase()?.configurationProgress { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard case .complete = harness.registry.registeredAudioSessionPhase()?.configurationProgress else {
            return XCTFail("原acquisition配置必须完成，等待真实ended后才能激活")
        }
        XCTAssertEqual(harness.sdk.activateCallCount, 0)
        let context = try XCTUnwrap(harness.registry.outputResourceContextSnapshot())
        ingress.performSyncIngress(PlaybackSystemSafetyEvent.interruptionEnded(shouldResume: true))
        let activation = try XCTUnwrap(harness.registry.beginOutputAcquisitionActivation(contextNonce: context.contextNonce))
        XCTAssertEqual(harness.owner.invoke(activation, receiver: harness.service), .started)
        try await harness.flushCommits()
        await harness.advanceThroughStabilityWindow()
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.hlsAVPlayer)
        XCTAssertEqual(harness.registry.outputResourceContextSnapshot()?.sessionIdentity, context.sessionIdentity)
        XCTAssertEqual(harness.sdk.activateCallCount, 1)
    }

    func testSameSemanticDoesNotRenewStabilityWindow() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.hdmi])
        try await harness.acquireWithoutNotification()
        harness.clock.advance(nanoseconds: 60_000_000)
        
        harness.initialPorts = [PlaybackRoutePorts.hdmi]
        harness.service.resample(reason: AudioRouteChangeReason.unknown)
        try await harness.flushRouteSampler()
        
        harness.clock.advance(nanoseconds: 65_000_000)
        harness.clock.fireDeadlineTimerEarly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.sampleBuffer)
    }

    func testStaleWakeDoesNotClearNewTicket() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.airPlay])
        try await harness.acquireWithoutNotification()
        
        harness.clock.advance(nanoseconds: 125_000_000)
        harness.clock.fireDeadlineTimerEarly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.hlsAVPlayer)
        
        harness.initialPorts = [PlaybackRoutePorts.hdmi]
        harness.service.resample(reason: AudioRouteChangeReason.unknown)
        try await harness.flushRouteSampler()
        harness.clock.advance(nanoseconds: 10_000_000)
        harness.clock.fireDeadlineTimerEarly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.hlsAVPlayer)
        
        harness.clock.advance(nanoseconds: 115_000_000)
        harness.clock.fireDeadlineTimerEarly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertEqual(harness.committedBackend, PlaybackBackendKind.sampleBuffer)
    }

    func testStrictOuterDeadlineEnforcement() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.airPlay])
        try await harness.acquireWithoutNotification()
        harness.clock.advance(nanoseconds: 3_000_000_000) // Over outer deadline
        harness.clock.fireDeadlineTimerEarly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertNil(harness.committedBackend) // Assuming outer deadline was respected and not committed
    }

    func testDoubleSourceExpirationAndStopCleanupWithoutDeadlock() async throws {
        let harness = RouteServiceTestHarness(initialPorts: [PlaybackRoutePorts.airPlay])
        try await harness.acquireWithoutNotification()
        harness.clock.advance(nanoseconds: 50_000_000)
        
        // This simulates a concurrent stop and timer fire
        harness.service.unbindSession()
        harness.clock.fireDeadlineTimerEarly()
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            harness.registry.executor.submit { continuation.resume() }
        }
        XCTAssertNil(harness.committedBackend) // Because session was unbound
    }
}

private final class RouteSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AudioOutputRouteSnapshot] = []
    private var deliveryContexts: [Bool] = []

    func append(_ snapshot: AudioOutputRouteSnapshot, onControlExecutor: Bool = false) {
        lock.withLock {
            snapshots.append(snapshot)
            deliveryContexts.append(onControlExecutor)
        }
    }

    var last: AudioOutputRouteSnapshot? {
        lock.withLock { snapshots.last }
    }

    var lastDeliveryOnControlExecutor: Bool? {
        lock.withLock { deliveryContexts.last }
    }
}

private final class Task9ObserverLifetimeNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let observationLock = NSLock()
    private var installed = 0
    private var removed = 0
    var installedCount: Int { observationLock.withLock { installed } }
    var removedCount: Int { observationLock.withLock { removed } }

    override func addObserver(forName name: Notification.Name?, object: Any?, queue: OperationQueue?,
        using block: @Sendable @escaping (Notification) -> Void) -> any NSObjectProtocol {
        observationLock.withLock { installed += 1 }
        return super.addObserver(forName: name, object: object, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        observationLock.withLock { removed += 1 }
        super.removeObserver(observer)
    }
}
