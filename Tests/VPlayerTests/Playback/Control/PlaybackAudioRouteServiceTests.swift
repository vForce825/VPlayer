// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class PlaybackAudioRouteServiceTests: XCTestCase {
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
