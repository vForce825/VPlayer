// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Darwin
import ObjectiveC
import XCTest
@testable import VPlayerPlayback

extension XCTestCase {
    /// 组件测试也使用生产owned record，测试退出明确join，不保留裸Task旁路。
    func bindOwnedRelayForTesting(_ relay: OwnedPlaybackEventDrain.Relay, identity: PlaybackRunIdentity) throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let session = PlaybackSessionIdentity(sessionID: identity.sessionID, requestID: identity.requestID)
        let parent = try registry.createGroup(resource: .context(session: session, nonce: 1))
        let group = try registry.createGroup(resource: .session(session), parent: parent)
        let ticket = try registry.enqueue(group: group, slot: .accounting, policy: .routeNeutral)
        let cleanup = try registry.enqueue(group: parent, slot: .cancel, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(cleanup))
        switch relay {
        case .pipeline(let value): XCTAssertTrue(registry.bindEventRelay(value, to: ticket))
        case .audio(let value): XCTAssertTrue(registry.bindEventRelay(value, to: ticket))
        }
        addTeardownBlock {
            XCTAssertTrue(registry.seal(group))
            let joined = await registry.joinEventRelay(ticket, from: cleanup)
            XCTAssertTrue(joined)
            XCTAssertTrue(registry.retire(ticket))
            XCTAssertTrue(registry.complete(cleanup))
            XCTAssertTrue(registry.retire(cleanup))
            XCTAssertTrue(registry.releaseGroup(group))
            XCTAssertTrue(registry.seal(parent))
            XCTAssertTrue(registry.releaseGroup(parent))
        }
    }
}

private protocol Task9NativeArrayObservation {
    var countForAllocation: Int { get }
    var capacityForAllocation: Int { get }
    var elementStrideForAllocation: Int { get }
    var storageIdentityForAllocation: UInt { get }
    var frozenTailAllocationBytes: Int { get }
}

extension Array: Task9NativeArrayObservation {
    fileprivate var countForAllocation: Int { count }
    fileprivate var capacityForAllocation: Int { capacity }
    fileprivate var elementStrideForAllocation: Int { MemoryLayout<Element>.stride }
    fileprivate var storageIdentityForAllocation: UInt {
        withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }
    fileprivate var frozenTailAllocationBytes: Int {
        malloc_good_size(32 + capacity * MemoryLayout<Element>.stride)
    }
}

/// 只按同一tvOS运行时的真实对象base或公开Array容量计量；绝不对element base调用malloc_size。
private struct Task9AllocationCharge {
    enum Ledger: String, CaseIterable {
        case ownedControl, audioRelay, systemAndPipelineRelay, route, presentation
    }
    let ledger: Ledger
    let name: String
    let allocationIdentity: UInt
    let bytes: Int
}

private func task9ObjectCharge(_ object: AnyObject, ledger: Task9AllocationCharge.Ledger,
    name: String) -> Task9AllocationCharge {
    let base = Unmanaged.passUnretained(object).toOpaque()
    return .init(ledger: ledger, name: name, allocationIdentity: UInt(bitPattern: base),
        bytes: malloc_size(base))
}

private func task9Wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}

private func task9ArrayCharge(_ array: any Task9NativeArrayObservation,
    ledger: Task9AllocationCharge.Ledger, name: String) -> Task9AllocationCharge {
    .init(ledger: ledger, name: name, allocationIdentity: array.storageIdentityForAllocation,
        bytes: array.frozenTailAllocationBytes)
}

private func task9Unwrapped(_ value: Any) -> Any? {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return value }
    return mirror.children.first?.value
}

private func task9Field(_ name: String, of value: Any) -> Any? {
    Mirror(reflecting: value).children.first { $0.label == name }.flatMap { task9Unwrapped($0.value) }
}

private func task9ObjectField<T: AnyObject>(_ name: String, of value: Any,
    as type: T.Type = T.self) -> T? {
    task9Field(name, of: value) as? T
}

private func task9AnyObjectField(_ name: String, of value: Any) -> AnyObject? {
    guard let field = task9Field(name, of: value), Mirror(reflecting: field).displayStyle == .class else { return nil }
    return field as AnyObject
}

private func task9ArrayField(_ name: String, of value: Any) -> (any Task9NativeArrayObservation)? {
    task9Field(name, of: value) as? any Task9NativeArrayObservation
}

private struct Task9ArrayAllocationSnapshot {
    let count: Int
    let capacity: Int
    let stride: Int
    let identity: UInt
    let bytes: Int
}

/// Mirror得到的Array副本只在本函数短借；生产mutation前销毁，避免测试自身制造COW。
private func task9ArraySnapshot(_ name: String, of value: Any) -> Task9ArrayAllocationSnapshot? {
    guard let array = task9ArrayField(name, of: value) else { return nil }
    return .init(count: array.countForAllocation, capacity: array.capacityForAllocation,
        stride: array.elementStrideForAllocation, identity: array.storageIdentityForAllocation,
        bytes: array.frozenTailAllocationBytes)
}

private final class Task9RuntimeWeakTargets {
    weak var executor: PlaybackControlExecutor?
    weak var scheduler: PlaybackDeadlineScheduler?
    weak var registry: ControlTaskRegistry?
    weak var controller: PlaybackController?
    weak var cleanupRunner: OwnedPlaybackCleanupTask?
    weak var monitor: SystemAudioEventMonitor?
    weak var routeService: PlaybackAudioRouteService?

    var allReleased: Bool {
        executor == nil && scheduler == nil && registry == nil && controller == nil &&
            cleanupRunner == nil && monitor == nil && routeService == nil
    }
}

/// 只控制被替代backend的异步返回；所有准入、路由与所有权决策仍由真实controller执行。
/// owner恢复测试使用既有Authority图排空合同；仅初次配置/后端排空沿用Task4测试驱动。
/// 被测reactivation必须经过真实owner与SDK lane，不能注入合成成功回执。
private struct Task9ExplicitResumeFixture {
    let registry: ControlTaskRegistry
    let sdk: FakeAudioSessionSDK
    let owner: PlaybackAudioSessionOwner
    let lease: PlaybackAudioSessionLease

    init() throws {
        let clock = OutputTestClock(100)
        registry = ControlTaskRegistry(allocator: .init(), clock: clock)
        sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let lane = try XCTUnwrap(Mirror(reflecting: owner).children.first { $0.label == "lane" }?.value
            as? AudioSessionBlockingCallLane)
        let fixture = try OutputGraphFixture(registry: registry, clock: clock, audioLane: lane)
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let leaseID = try XCTUnwrap(context.sessionReceipts?.active?.leaseID)
        lease = .init(id: leaseID, generation: leaseID)
        owner.monitor.emit(.interruptionBegan)
        _ = registry.outputResourceContextSnapshot()
        if let source = context.sourceTask {
            XCTAssertEqual(try registry.retireOutputControlRecord(source), .retired(followUp: nil))
        }
        let transition = try XCTUnwrap(fixture.coordinator.begin(contextNonce: context.contextNonce,
            reason: .recovery, at: clock.read(), teardown: false))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertTrue(registry.claimStart(stop.task))
        XCTAssertTrue(fixture.coordinator.completeSuspend(.init(suspendTicket: stop, closeClaim: nil,
            directlyConfirmedRateZero: true, preparedPreserved: false)))
        let retirement = try XCTUnwrap(fixture.coordinator.advance(owner: transition))
        XCTAssertTrue(registry.claimStart(retirement))
        XCTAssertTrue(fixture.coordinator.completeRetirement(retirement, lifecycle: fixture.lifecycle))
        guard case .settled(_, nil) = registry.settleOutputInterruptionDrain(owner: transition) else {
            throw ControlTaskRegistry.Failure.invalidGroup
        }
        XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        let cleanup = try XCTUnwrap(registry.outputCleanupOwnerTask(transition))
        XCTAssertTrue(registry.complete(cleanup))
        XCTAssertEqual(try registry.retireOutputControlRecord(cleanup), .retired(followUp: nil))
        owner.monitor.emit(.interruptionEnded(shouldResume: false))
        XCTAssertNotNil(registry.registeredOutputDrainProof())
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
    }
}

private actor Task9OperationGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var completionWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { completionWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    var hasEntered: Bool { entered }

    func release() {
        released = true
        completionWaiter?.resume()
        completionWaiter = nil
    }
}

private final class Task9OutputConcurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var audible: [PlaybackBackendIdentity] = []
    private var peak = 0
    var maximum: Int { lock.withLock { peak } }
    var current: Int { lock.withLock { audible.count } }
    func activate(_ identity: PlaybackBackendIdentity) {
        lock.withLock {
            if !audible.contains(identity) { audible.append(identity) }
            peak = max(peak, audible.count)
        }
    }
    func suspend(_ identity: PlaybackBackendIdentity) { lock.withLock { audible.removeAll { $0 == identity } } }
}

private final class Task9PreparedBackend: PlaybackBackend,
    SampleBufferQuiescenceIssuerInstalling, @unchecked Sendable {
    let identity: PlaybackBackendIdentity
    let presentation: PlaybackPresentation? = .sampleBuffer(PlaybackPresentationContext())
    private let prepareGate: Task9OperationGate?
    private let retirementGate: Task9OperationGate?
    private let activationGate: Task9OperationGate?
    private let suspensionGate: Task9OperationGate?
    private let prepareFailure: PlaybackCoreError?
    private let sink: @Sendable (PlaybackPipelineEvent) -> Void
    private let outputConcurrency: Task9OutputConcurrency
    private let lock = NSLock()
    private var activations = 0
    private var lastActivation: ActivationEpoch?
    private var suspensions: [OutputLifecycleEpoch] = []
    private var retirements: [OutputLifecycleEpoch] = []
    private var quiescenceIssuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer?
    private var physicalRate: Float = 0

    init(identity: PlaybackBackendIdentity, prepareGate: Task9OperationGate?, retirementGate: Task9OperationGate?,
         sink: @escaping @Sendable (PlaybackPipelineEvent) -> Void, outputConcurrency: Task9OutputConcurrency,
         activationGate: Task9OperationGate? = nil, suspensionGate: Task9OperationGate? = nil,
         prepareFailure: PlaybackCoreError? = nil) {
        self.identity = identity
        self.prepareGate = prepareGate
        self.retirementGate = retirementGate
        self.sink = sink
        self.outputConcurrency = outputConcurrency
        self.activationGate = activationGate
        self.suspensionGate = suspensionGate
        self.prepareFailure = prepareFailure
    }

    var activationCount: Int { lock.withLock { activations } }
    var activationEpoch: ActivationEpoch? { lock.withLock { lastActivation } }
    var suspensionEpochs: [OutputLifecycleEpoch] { lock.withLock { suspensions } }
    var retirementEpochs: [OutputLifecycleEpoch] { lock.withLock { retirements } }
    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
        await prepareGate?.enter()
        if let prepareFailure { throw prepareFailure }
    }
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
        await prepareGate?.enter()
    }
    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {
        await activationGate?.enter()
        _ = invocation.performPositiveRateSideEffect {
            outputConcurrency.activate(identity)
            lock.withLock {
                activations += 1
                lastActivation = invocation.activation
                physicalRate = 1
            }
        }
    }
    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async -> BackendSuspendResult {
        await suspensionGate?.enter()
        outputConcurrency.suspend(identity)
        lock.withLock {
            suspensions.append(invocation.lifecycle)
            physicalRate = 0
        }
        guard let proof = lock.withLock({
            quiescenceIssuer?.issue(
                backendIdentity: identity, invocation: invocation,
                observedRate: physicalRate, preparedPreserved: true)
        }) else { return .requiresRetirement }
        return .quiescent(proof)
    }
    func installSampleBufferQuiescenceIssuer(
        _ issuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer
    ) {
        lock.withLock { quiescenceIssuer = issuer }
    }
    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        lock.withLock { retirements.append(epoch) }
        await retirementGate?.enter()
        return .confirmedLocalOutputStopped
    }
    func emit(_ event: PlaybackPipelineEvent) { sink(event) }
}

private final class Task9PreparedFactory: PlaybackBackendFactory, @unchecked Sendable {
    private let factoryGate: Task9OperationGate?
    private let activationGate: Task9OperationGate?
    private let suspensionGate: Task9OperationGate?
    private let firstPrepareFailure: PlaybackCoreError?
    private let prepareGate: Task9OperationGate?
    private let retirementGate: Task9OperationGate?
    private let lock = NSLock()
    private var created: [Task9PreparedBackend] = []
    let outputConcurrency = Task9OutputConcurrency()

    init(prepareGate: Task9OperationGate? = nil, retirementGate: Task9OperationGate? = nil,
         factoryGate: Task9OperationGate? = nil, activationGate: Task9OperationGate? = nil,
         suspensionGate: Task9OperationGate? = nil, firstPrepareFailure: PlaybackCoreError? = nil) {
        self.prepareGate = prepareGate
        self.retirementGate = retirementGate
        self.factoryGate = factoryGate
        self.activationGate = activationGate
        self.suspensionGate = suspensionGate
        self.firstPrepareFailure = firstPrepareFailure
    }
    var backends: [Task9PreparedBackend] { lock.withLock { created } }

    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity,
        tuning: PlaybackTuning, channelID: String, url: URL,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        await factoryGate?.enter()
        let backend = Task9PreparedBackend(identity: identity, prepareGate: prepareGate,
            retirementGate: retirementGate, sink: eventSink, outputConcurrency: outputConcurrency,
            activationGate: activationGate, suspensionGate: suspensionGate,
            prepareFailure: lock.withLock { created.isEmpty ? firstPrepareFailure : nil })
        lock.withLock { created.append(backend) }
        return backend
    }
}

/// 仅阻塞真实SDK返回；不替代Registry配置、completion或proof。
private final class Task9SDKGate: PlaybackAudioSessionSDK, @unchecked Sendable {
    let base = FakeAudioSessionSDK(initialPorts: .hdmi)
    let categoryOrdinal: Int
    let entered: @Sendable () -> Void
    let gate = DispatchSemaphore(value: 0)
    init(categoryOrdinal: Int, entered: @escaping @Sendable () -> Void) {
        self.categoryOrdinal = categoryOrdinal
        self.entered = entered
    }
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {
        try base.setPlaybackCategory(policy: policy)
        if base.lock.withLock({ base.categoryCallCount == categoryOrdinal }) { entered(); gate.wait() }
    }
    func setSupportsMultichannelContent() throws { try base.setSupportsMultichannelContent() }
    func activate() throws { try base.activate() }
    func deactivate() throws { try base.deactivate() }
    func currentRoute() -> any AudioSessionRouteSnapshot { base.currentRoute() }
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool { base.fillRandomBytes(bytes) }
}

private final class Task9BeforeBindingOwner: PlaybackAudioSessionOwner, @unchecked Sendable {
    let history = PlaybackStreamRecorder<PlaybackAudioSessionEventEnvelope>()
    override func startAcquisition(_ ticket: ControlTaskTicket,
        receiver: any PlaybackAudioSessionCompletionReceiving) -> Bool {
        let started = super.startAcquisition(ticket, receiver: receiver)
        if started, let envelope = monitor.emit(.interruptionEnded(shouldResume: true)) { history.append(envelope) }
        return started
    }
}

/// 只阻塞首个真实route getter，让通知精确落在SDK返回之前。
private final class Task9RouteGetterGateSDK: PlaybackAudioSessionSDK, @unchecked Sendable {
    private let base = FakeAudioSessionSDK(initialPorts: .hdmi)
    private let lock = NSLock()
    private let firstRouteEntered: @Sendable () -> Void
    private let gate = DispatchSemaphore(value: 0)
    private var routeCalls = 0

    init(firstRouteEntered: @escaping @Sendable () -> Void) {
        self.firstRouteEntered = firstRouteEntered
    }

    var routeCallCount: Int { lock.withLock { routeCalls } }
    func releaseFirstRoute() { gate.signal() }
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {
        try base.setPlaybackCategory(policy: policy)
    }
    func setSupportsMultichannelContent() throws { try base.setSupportsMultichannelContent() }
    func activate() throws { try base.activate() }
    func deactivate() throws { try base.deactivate() }
    func currentRoute() -> any AudioSessionRouteSnapshot {
        let ordinal = lock.withLock { routeCalls += 1; return routeCalls }
        if ordinal == 1 {
            firstRouteEntered()
            gate.wait()
        }
        return base.currentRoute()
    }
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool { base.fillRandomBytes(bytes) }
}

final class Task9ReconstructedRegressionTests: XCTestCase {
    func testConcurrentSystemFoldCannotDeliverEndedBeforeEarlierBeganToProduction() async throws {
        let retirement = Task9OperationGate()
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry,
            sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory(retirementGate: retirement))
        await controller.play(request())

        let beganFolded = expectation(description: "began已经完成同步fold")
        let beganReturned = expectation(description: "began已经投递")
        let endedAttempted = expectation(description: "ended已从并发线程进入emit")
        let endedReturned = expectation(description: "ended已经投递")
        let releaseBegan = DispatchSemaphore(value: 0)
        let endedReachedDeliverySeam = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            owner.monitor.emit(.interruptionBegan, beforeProductionDelivery: {
                beganFolded.fulfill()
                releaseBegan.wait()
            })
            beganReturned.fulfill()
        }
        await fulfillment(of: [beganFolded], timeout: 1)
        DispatchQueue.global().async {
            endedAttempted.fulfill()
            owner.monitor.emit(.interruptionEnded(shouldResume: false), beforeProductionDelivery: {
                endedReachedDeliverySeam.signal()
            })
            endedReturned.fulfill()
        }
        await fulfillment(of: [endedAttempted], timeout: 1)
        _ = task9Wait(endedReachedDeliverySeam, timeout: .now() + 0.2)
        releaseBegan.signal()
        await fulfillment(of: [beganReturned, endedReturned], timeout: 1)

        for _ in 0..<500 {
            if await retirement.hasEntered { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let retirementEntered = await retirement.hasEntered
        XCTAssertTrue(retirementEntered,
            "更晚fold的ended不能先进入production relay并使原began被revision游标丢弃")
        await retirement.release()
        await controller.stop()
    }

    func testCurrentRouteCompletionAutomaticallyStartsReplacementSampler() async throws {
        let firstRouteEntered = expectation(description: "首个真实route getter在途")
        let sdk = Task9RouteGetterGateSDK(firstRouteEntered: { firstRouteEntered.fulfill() })
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        let playbackRequest = request()
        let play = Task { await controller.play(playbackRequest) }
        await fulfillment(of: [firstRouteEntered], timeout: 2)
        service.resample(reason: .unknown)
        sdk.releaseFirstRoute()

        for _ in 0..<500 {
            if sdk.routeCallCount >= 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(sdk.routeCallCount, 2,
            "旧getter完成后安装的replacement sampler必须由同一receiver自动领取")
        await controller.stop()
        await play.value
    }

    func testPreboundAudioRingKeepsThirtyTwoExactKeysUntilBinding() async throws {
        try await assertPreboundAudioTransport(count: 32, competingWakes: false)
    }

    func testPreboundAudioThirtyThirdKeySynchronouslyRevokesOriginalAuthority() async throws {
        try await assertPreboundAudioTransport(count: 33, competingWakes: false)
    }

    func testPreboundAudioDrainRequestRacingBindingLaunchesExactlyOnce() async throws {
        try await assertPreboundAudioTransport(count: 2, competingWakes: true)
    }

    private func assertPreboundAudioTransport(count: Int, competingWakes: Bool) async throws {
        let category = expectation(description: "原lease真实SDK配置在途")
        let sdk = Task9SDKGate(categoryOrdinal: 1, entered: { category.fulfill() })
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        // 仅用于测试退出调用生产cleanup；资源仍由下方真实acquisition登记。
        let cleanupController = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        let admission = try registry.admitPlaybackRequest(requestID: UUID())
        let acquisition = try XCTUnwrap(registry.beginOutputAcquisition(admission: admission,
            resetRecoveryMandatorySuffix: 3_000_000_000))
        XCTAssertTrue(owner.startAcquisition(acquisition, receiver: service))
        await fulfillment(of: [category], timeout: 2)
        let registration = try XCTUnwrap(owner.registration(for: acquisition))
        let original = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let run = PlaybackRunIdentity(sessionID: original.sessionIdentity.sessionID,
            requestID: original.sessionIdentity.requestID)
        let lease = PlaybackAudioSessionLease(id: registration.identity.leaseID,
            generation: registration.identity.leaseID)
        let group = try registry.createGroup(resource: .monitor(session: original.sessionIdentity,
            lifecycle: registration.identity.monitorLifecycle), parent: original.reservation.ownerGroup)
        let drain = try registry.enqueue(group: group, slot: .systemEventRelay, policy: .safetyBypass)
        let delivered = PlaybackStreamRecorder<PlaybackAudioSessionEventKey>()
        let consumed = PlaybackStreamRecorder<PlaybackAudioSessionEvent>()
        let received = expectation(description: "原owned receiver完整交付且无重放")
        received.expectedFulfillmentCount = count == 33 ? 1 : count
        received.assertForOverFulfill = true
        let receiverExitGate = count == 33 ? Task9OperationGate() : nil
        let relay = PlaybackAudioSessionEventRelay(identity: run, lease: lease) { identity, lease, key, ticket in
            XCTAssertEqual(ticket, drain)
            delivered.append(key)
            if let envelope = registry.consumeAudioSessionEvent(key, run: identity, lease: lease, drain: ticket) {
                consumed.append(envelope.event)
            }
            if count != 33 {
                XCTAssertNil(registry.consumeAudioSessionEvent(key, run: identity, lease: lease, drain: ticket),
                    "系统key必须由原cursor严格一次消费")
            }
            received.fulfill()
            if let receiverExitGate { await receiverExitGate.enter() }
        }
        XCTAssertTrue(registry.prepareAudioEventRelayBinding(relay, to: drain))
        let owned = try eventDrainRunner(registry, ticket: drain)
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let expected = PlaybackStreamRecorder<PlaybackAudioSessionEventKey>()
        registry.executor.sync {
            for index in 0..<count {
                let event: PlaybackAudioSessionEvent = index % 2 == 0 ? .interruptionBegan :
                    .interruptionEnded(shouldResume: false)
                guard let envelope = monitor.emit(event), let key = PlaybackAudioSessionEventKey(envelope: envelope)
                else { return XCTFail("必须由真实Cell签发原历史key") }
                expected.append(key)
                relay.send(lease: lease, event: envelope)
                if competingWakes { registry.executor.signalOwnedEventDrain(); registry.drainOwnedEventRelays() }
            }
            registry.drainOwnedEventRelays()
            XCTAssertNil(owned.task, "登记owner不能提前分配排空Task；receiver在最终bind前不可运行")
            XCTAssertEqual(registry.phase(of: drain), .queued)
            XCTAssertTrue(delivered.snapshot.isEmpty)
            let slots = Mirror(reflecting: relay).children.first { $0.label == "pending" }?.value
                as? [PlaybackAudioSessionEventKey?]
            XCTAssertEqual(slots?.count, 32, "预绑定仍使用原固定32槽，无第二backing")
            if count == 33 {
                let snapshot = registry.outputResourceContextSnapshot()
                XCTAssertEqual(snapshot?.contextNonce, original.contextNonce)
                XCTAssertTrue(snapshot?.poisoned == true, "第33条返回前必须同步撤权原准确Authority")
                XCTAssertEqual(snapshot?.disposition, .releaseAfterTeardown)
                XCTAssertEqual(slots?.compactMap { $0 }.count, 1, "溢出只能保留原槽中的唯一terminal")
            } else {
                XCTAssertEqual(slots?.compactMap { $0 }, expected.snapshot)
            }
            XCTAssertTrue(registry.bindEventRelay(relay, to: drain))
            registry.drainOwnedEventRelays()
            let firstTask = owned.task
            XCTAssertNotNil(firstTask)
            for _ in 0..<3 {
                registry.executor.signalOwnedEventDrain()
                registry.drainOwnedEventRelays()
                XCTAssertEqual(owned.task, firstTask, "bind前后的重复source唤醒不能重复领取原请求")
            }
        }
        await fulfillment(of: [received], timeout: 2)
        if count == 33 {
            XCTAssertEqual(delivered.snapshot.map(\.event), [.recoveryFailed(stage: .eventRelayCapacity)])
        } else {
            XCTAssertEqual(delivered.snapshot, expected.snapshot)
            XCTAssertEqual(consumed.snapshot, expected.snapshot.map(\.event))
        }
        if let receiverExitGate {
            await receiverExitGate.waitUntilEntered()
            registry.executor.sync {
                XCTAssertTrue(eventDrainRunnerIsolated(registry, ticket: drain) === owned,
                    "receiver返回前原record必须仍强持同一runner")
                XCTAssertEqual(registry.phase(of: drain), .cancelRequested,
                    "终态cleanup可先请求取消，但receiver返回前不得冒充已退休")
            }
            await receiverExitGate.release()
        } else {
            // 非终态路径没有自动cleanup，原Task退出尾仍由同一record强持。
            XCTAssertTrue(try eventDrainRunner(registry, ticket: drain) === owned)
        }
        sdk.gate.signal()
        for _ in 0..<500 {
            var sdkInFlight = false
            registry.executor.sync {
                let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
                let permit = Mirror(reflecting: authority).children.first { $0.label == "audioSessionPermit" }!.value
                sdkInFlight = !Mirror(reflecting: permit).children.isEmpty
            }
            if !sdkInFlight { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await cleanupController.stop()
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.phase(of: drain), "生产cleanup完成后必须退休原drain record")
    }

    private func eventDrainRunner(_ registry: ControlTaskRegistry, ticket: ControlTaskTicket) throws
        -> OwnedPlaybackEventDrain {
        var result: OwnedPlaybackEventDrain?
        registry.executor.sync { result = eventDrainRunnerIsolated(registry, ticket: ticket) }
        return try XCTUnwrap(result)
    }

    private func eventDrainRunnerIsolated(_ registry: ControlTaskRegistry, ticket: ControlTaskTicket)
        -> OwnedPlaybackEventDrain? {
        precondition(registry.executor.isIsolated)
        let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
        let records = Mirror(reflecting: authority).children.first { $0.label == "commands" }!.value
            as! [OwnedPostIngressControlCommand?]
        guard let record = records.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
              case .eventDrain(let runner) = record.payload else { return nil }
        return runner
    }

    func testAudioRelayPreservesCellKeysAcrossOwnedBindingWithoutASecondMailbox() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let session = PlaybackSessionIdentity(sessionID: 21, requestID: UUID())
        let run = PlaybackRunIdentity(sessionID: session.sessionID, requestID: session.requestID)
        let lease = PlaybackAudioSessionLease(id: 1, generation: 1)
        let parent = try registry.createGroup(resource: .session(session))
        let group = try registry.createGroup(resource: .monitor(session: session, lifecycle: 1), parent: parent)
        let drain = try registry.enqueue(group: group, slot: .systemEventRelay, policy: .safetyBypass)
        let cleanup = try registry.enqueue(group: parent, slot: .cancel, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(cleanup))
        let delivered = PlaybackStreamRecorder<PlaybackAudioSessionEventKey>()
        let relay = PlaybackAudioSessionEventRelay(identity: run, lease: lease) { _, _, key, _ in delivered.append(key) }
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let before = try XCTUnwrap(monitor.emit(.interruptionBegan))
        relay.send(lease: lease, event: before)
        XCTAssertTrue(delivered.snapshot.isEmpty, "未绑定前不能启动无主Task")
        XCTAssertTrue(registry.bindEventRelay(relay, to: drain))
        let after = try XCTUnwrap(monitor.emit(.interruptionEnded(shouldResume: false)))
        relay.send(lease: lease, event: after)
        for _ in 0..<500 {
            if delivered.snapshot.count == 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(delivered.snapshot, try [before, after].map { try XCTUnwrap(PlaybackAudioSessionEventKey(envelope: $0)) },
            "Cell原key必须跨过bind保存FIFO；不能因无executor丢掉或用latest替代")
        XCTAssertTrue(registry.seal(group))
        let joined = await registry.joinEventRelay(drain, from: cleanup)
        XCTAssertTrue(joined)
        XCTAssertTrue(registry.retire(drain))
        XCTAssertTrue(registry.complete(cleanup))
        XCTAssertTrue(registry.retire(cleanup))
        XCTAssertTrue(registry.releaseGroup(group))
        XCTAssertTrue(registry.seal(parent))
        XCTAssertTrue(registry.releaseGroup(parent))
    }

    func testPendingAcquisitionAudioKeysKeepAdmissionBoundaryAndHistoricalOrder() async throws {
        let category = expectation(description: "原acquisition真实category在途")
        let sdk = Task9SDKGate(categoryOrdinal: 1, entered: { category.fulfill() })
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try Task9BeforeBindingOwner(registry: registry, sdk: sdk, monitor: nil)
        _ = owner.monitor.emit(.interruptionEnded(shouldResume: true))
        let observed = PlaybackStreamRecorder<PlaybackAudioSessionEvent>()
        owner.monitor.setEventHandler { observed.append($0.event) }
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let factory = Task9PreparedFactory()
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        let request = request()
        let play = Task { await controller.play(request) }
        await fulfillment(of: [category], timeout: 2)
        _ = await controller.audioSessionInterruptedForTesting
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertEqual(context.phase, .pendingLeaseAcquisition)
        let drain = try actualAudioDrain(registry)
        _ = owner.monitor.emit(.interruptionBegan)
        _ = owner.monitor.emit(.interruptionEnded(shouldResume: false))
        for _ in 0..<500 {
            if observed.snapshot.count == 3, registry.phase(of: drain.ticket) == .running { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(observed.snapshot, [
            .interruptionEnded(shouldResume: true), .interruptionBegan,
            .interruptionEnded(shouldResume: false)
        ], "observer只观察生产事件，不能替代relay transport或再次消费原key")
        XCTAssertEqual(sdk.base.lock.withLock { sdk.base.activateCallCount }, 0)
        XCTAssertTrue(factory.backends.isEmpty)
        let stop = Task { await controller.stop() }
        sdk.gate.signal()
        await play.value
        await stop.value
        XCTAssertNil(registry.cleanupReservationSnapshot())
    }

    func testBeganDuringResetConfigurationKeepsSafeConfigurationAndResumesOnce() async throws {
        try await assertBeganDuringResetSDK(activationInFlight: false)
    }

    func testBeganDuringResetActivationRejectsOldCompletionAndResumesOnce() async throws {
        try await assertBeganDuringResetSDK(activationInFlight: true)
    }

    private func assertBeganDuringResetSDK(activationInFlight: Bool) async throws {
        let entered = expectation(description: "真实reset SDK步骤在途")
        let sdk = Task9SDKGate(categoryOrdinal: activationInFlight ? -1 : 2, entered: { entered.fulfill() })
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let factory = Task9PreparedFactory()
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        let original = try XCTUnwrap(factory.backends.first)
        let successes = PlaybackStreamRecorder<PlaybackAudioSessionEventEnvelope>()
        owner.monitor.setEventHandler { envelope in
            if envelope.event == .resetConfigurationSucceeded { successes.append(envelope) }
        }
        if activationInFlight {
            sdk.base.lock.withLock {
                sdk.base.onActivate = {
                    if sdk.base.lock.withLock({ sdk.base.activateCallCount == 2 }) { entered.fulfill(); sdk.gate.wait() }
                }
            }
        }
        owner.monitor.emit(.mediaServicesWereReset)
        await fulfillment(of: [entered], timeout: 2)
        let originalPhase = try XCTUnwrap(registry.registeredAudioSessionPhase())
        let originalEpoch = registry.executor.safetyIngress.snapshot.interruptionEpoch
        let proof = try XCTUnwrap(registry.registeredOutputDrainProof())
        owner.monitor.emit(.interruptionBegan)
        for _ in 0..<500 {
            if await controller.audioSessionInterruptedForTesting { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        XCTAssertEqual(factory.backends.count, 1)
        sdk.gate.signal()
        for _ in 0..<500 {
            if registry.outputResourceContextSnapshot()?.systemRecoveryBinding?.inactiveConfigurationReceipt != nil,
               registry.outputResourceContextSnapshot()?.pendingActivationCall == nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNotNil(registry.outputResourceContextSnapshot()?.systemRecoveryBinding?.inactiveConfigurationReceipt,
            "began不能误封口安全配置而遗失原reset后继责任")
        XCTAssertTrue(successes.snapshot.isEmpty, "旧SDK返回不能越过新began发布reset success")
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        XCTAssertEqual(registry.registeredOutputDrainProof(), proof)
        owner.monitor.emit(.interruptionEnded(shouldResume: true))
        for _ in 0..<1000 {
            if factory.backends.count == 2, factory.backends.last?.activationCount == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(factory.backends.count, 2, "准确新epoch必须继续同reset root，且后继唯一")
        XCTAssertEqual(factory.backends.last?.activationCount, 1)
        XCTAssertEqual(original.retirementEpochs.count, 1)
        XCTAssertEqual(factory.outputConcurrency.maximum, 1)
        XCTAssertEqual(sdk.base.lock.withLock { sdk.base.categoryCallCount }, 2)
        XCTAssertEqual(sdk.base.lock.withLock { sdk.base.activateCallCount }, activationInFlight ? 3 : 2)
        XCTAssertEqual(successes.snapshot.count, 1)
        if let receipt = successes.snapshot.first?.reactivationReceipt {
            XCTAssertGreaterThan(receipt.interruptionEpoch, originalEpoch)
            XCTAssertNotEqual(registry.registeredAudioSessionPhase()?.policy, originalPhase.policy)
        }
        sdk.base.lock.withLock { sdk.base.onActivate = nil }
        await controller.stop()
        XCTAssertNil(registry.cleanupReservationSnapshot())
    }
    func testStoppedAudioRelayTailCannotPoisonNewPlayAndIsReleasedAfterJoin() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let factory = Task9PreparedFactory()
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        weak var oldRelay: PlaybackAudioSessionEventRelay?
        do {
            await controller.play(request())
            let oldDrain = try actualAudioDrain(registry)
            oldRelay = oldDrain.relay
            await controller.stop()
            XCTAssertNil(registry.phase(of: oldDrain.ticket))
            await controller.play(request())
            let next = try XCTUnwrap(registry.outputResourceContextSnapshot())
            for _ in 0..<33 {
                oldDrain.relay.send(lease: oldDrain.relay.lease,
                    event: .init(event: .recoveryFailed(stage: .eventRelayCapacity), systemReceipt: nil))
            }
            registry.executor.safetyIngress.receiveAudioRelayOverflow(recordNonce: oldDrain.ticket.nonce)
            let afterTail = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertEqual(afterTail.contextNonce, next.contextNonce)
            XCTAssertEqual(afterTail.sessionIdentity, next.sessionIdentity)
            XCTAssertFalse(afterTail.poisoned)
            XCTAssertEqual(factory.backends.count, 2)
            XCTAssertEqual(factory.outputConcurrency.maximum, 1)
        }
        XCTAssertNil(oldRelay, "原record join后不得被新session或最后Task尾部继续强持有")
        await controller.stop()
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testAudioSystemKeyRejectsZeroAndFutureEpochWithoutConsumingOriginalCursor() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        await controller.play(request())
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let run = PlaybackRunIdentity(sessionID: context.sessionIdentity.sessionID, requestID: context.sessionIdentity.requestID)
        let drain = try actualAudioDrain(registry)
        // 精确key测试使用未绑定monitor；production monitor不被替换为测试transport。
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let envelope = try XCTUnwrap(monitor.emit(.interruptionBegan))
        let receipt = try XCTUnwrap(envelope.systemReceipt)
        drain.relay.send(lease: drain.relay.lease, event: .init(event: .explicitResumeSucceeded, systemReceipt: nil))
        for _ in 0..<500 {
            if registry.phase(of: drain.ticket) == .running { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(registry.phase(of: drain.ticket), .running)
        for epoch in [UInt64(0), UInt64.max] {
            let invalid = PlaybackSystemSafetyReceipt(event: receipt.event, revision: receipt.revision,
                mediaServicesEpoch: receipt.mediaServicesEpoch, interruptionEpoch: epoch,
                audioAdmissionFenceRevision: receipt.audioAdmissionFenceRevision)
            let key = try XCTUnwrap(PlaybackAudioSessionEventKey(envelope: .init(
                event: .interruptionBegan, systemReceipt: invalid)))
            XCTAssertNil(registry.consumeAudioSessionEvent(key, run: run, lease: drain.relay.lease, drain: drain.ticket))
        }
        let original = try XCTUnwrap(PlaybackAudioSessionEventKey(envelope: envelope))
        XCTAssertEqual(registry.consumeAudioSessionEvent(original, run: run, lease: drain.relay.lease,
            drain: drain.ticket)?.event, .interruptionBegan)
        XCTAssertNil(registry.consumeAudioSessionEvent(original, run: run, lease: drain.relay.lease, drain: drain.ticket))
        await controller.stop()
        XCTAssertNil(registry.cleanupReservationSnapshot())
    }

    func testSystemIdentityExhaustionRetainsOriginalCleanupAndRejectsRecovery() async throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max, initialNamespace: .systemEvent)
        let registry = ControlTaskRegistry(allocator: allocator)
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        await controller.play(request())
        let original = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertNil(owner.monitor.emit(.interruptionBegan))
        let failed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(allocator.isExhausted)
        XCTAssertTrue(failed.poisoned)
        XCTAssertEqual(failed.disposition, .releaseAfterTeardown)
        XCTAssertEqual(failed.reservation, original.reservation)
        XCTAssertEqual(registry.executor.safetyIngress.snapshot.failure, .identitySpaceExhausted)
        XCTAssertNil(registry.registeredOutputDrainProof())
        XCTAssertNil(owner.monitor.emit(.interruptionEnded(shouldResume: true)))
        XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 1)
        await controller.stop()
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testProductionResetCompletionKeyConsumesOriginalProofOnce() async throws {
        try await assertProductionResetCompletionConsumption(newBeganWins: false)
    }

    func testNewBeganRejectsOriginalProductionResetCompletionKey() async throws {
        try await assertProductionResetCompletionConsumption(newBeganWins: true)
    }

    private func assertProductionResetCompletionConsumption(newBeganWins: Bool) async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let factory = Task9PreparedFactory()
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        let activationCountBeforeReset = sdk.lock.withLock { sdk.activateCallCount }
        let completed = expectation(description: "原reset SDK completion携原proof到达")
        completed.assertForOverFulfill = true
        let receiptLock = NSLock()
        nonisolated(unsafe) var returned: PlaybackAudioSessionEventEnvelope?
        nonisolated(unsafe) var completionCount = 0
        owner.monitor.setEventHandler { envelope in
            if envelope.event == .resetConfigurationSucceeded {
                receiptLock.withLock {
                    returned = envelope
                    completionCount += 1
                }
                if newBeganWins { owner.monitor.emit(.interruptionBegan) }
                completed.fulfill()
            }
        }
        owner.monitor.emit(.mediaServicesWereReset)
        await fulfillment(of: [completed], timeout: 2)
        let envelope = try XCTUnwrap(receiptLock.withLock { returned })
        let receipt = try XCTUnwrap(envelope.reactivationReceipt)
        for _ in 0..<1_000 {
            let proofConsumed = !registry.acceptsReactivationCompletion(receipt)
            let resetSettled = newBeganWins || registry.outputResourceContextSnapshot()?.pendingReset == nil
            let backendGenerationSettled = factory.backends.count == (newBeganWins ? 1 : 2)
            let activatedOnce = sdk.lock.withLock { sdk.activateCallCount } == activationCountBeforeReset + 1
            if proofConsumed, resetSettled, backendGenerationSettled, activatedOnce { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(registry.acceptsReactivationCompletion(receipt),
            "production owned drain必须消费或由更新物理epoch撤销原reset proof")
        XCTAssertEqual(receiptLock.withLock { completionCount }, 1,
            "production direct transport必须只交付一次reset completion")
        if newBeganWins {
            XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active,
                "observer中先折叠的新began必须胜过已排队的旧activation completion")
            XCTAssertEqual(factory.backends.count, 1)
        } else {
            XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, activationCountBeforeReset + 1,
                "reset recovery必须只追加一次SDK activation")
            XCTAssertNil(registry.outputResourceContextSnapshot()?.pendingReset)
            XCTAssertEqual(factory.backends.count, 2)
        }
        await controller.stop()
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.cleanupReservationSnapshot())
    }

    func testProductionBeganEndedResetDrainsOnceAndCreatesOneResetSuccessor() async throws {
        try await assertProductionMixedResetRecovery(resetBeforeBegan: false)
    }

    func testProductionResetBeganDefersActivationUntilEndedAndCreatesOneSuccessor() async throws {
        try await assertProductionMixedResetRecovery(resetBeforeBegan: true)
    }

    private func assertProductionMixedResetRecovery(resetBeforeBegan: Bool) async throws {
        let retirement = Task9OperationGate()
        let factory = Task9PreparedFactory(retirementGate: retirement)
        let registry = ControlTaskRegistry(allocator: .init())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        let original = try XCTUnwrap(factory.backends.first)
        let activationGate = DispatchSemaphore(value: 0)
        sdk.lock.withLock { sdk.onActivate = { activationGate.wait() } }
        registry.executor.sync {
            if resetBeforeBegan {
                owner.monitor.emit(.mediaServicesWereReset)
                owner.monitor.emit(.interruptionBegan)
            } else {
                owner.monitor.emit(.interruptionBegan)
                owner.monitor.emit(.interruptionEnded(shouldResume: true))
                owner.monitor.emit(.mediaServicesWereReset)
            }
        }
        for _ in 0..<500 {
            if await retirement.hasEntered { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let entered = await retirement.hasEntered
        XCTAssertTrue(entered, "真实历史事件必须使原backend进入owned retirement")
        XCTAssertNil(registry.registeredOutputDrainProof())
        XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 1,
            "原backend尚未退休时不能配置后恢复激活")
        await retirement.release()
        if resetBeforeBegan {
            for _ in 0..<500 {
                if case .reset = registry.registeredOutputDrainProof() { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard case .reset = registry.registeredOutputDrainProof() else {
                activationGate.signal()
                await controller.stop()
                return XCTFail("reset→began必须先建立原reset drain proof，不能退回interruption proof")
            }
            XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 1)
            XCTAssertEqual(factory.backends.count, 1)
            owner.monitor.emit(.interruptionEnded(shouldResume: true))
        }
        for _ in 0..<750 {
            if sdk.lock.withLock({ sdk.activateCallCount == 2 }) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(sdk.lock.withLock { sdk.categoryCallCount }, 2,
            "reset必须沿原SDK lane重新配置，不能把旧configured generation当作新证明")
        XCTAssertEqual(factory.backends.count, 1, "真实SDK activation仍被阻塞，不得发布成功或创建后继")
        XCTAssertEqual(factory.outputConcurrency.maximum, 1)
        activationGate.signal()
        for _ in 0..<750 {
            if factory.backends.count == 2 && factory.backends.last?.activationCount == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(original.retirementEpochs.count, 1)
        XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 2,
            "必须消费真实reset activation completion，而非仅调用pipeline恢复")
        XCTAssertEqual(factory.backends.count, 2, "同一reset root只允许一个后继")
        XCTAssertEqual(factory.backends.last?.activationCount, 1)
        XCTAssertEqual(factory.outputConcurrency.maximum, 1)
        XCTAssertNil(registry.outputResourceContextSnapshot()?.pendingReset)
        await controller.stop()
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.cleanupReservationSnapshot())
    }

    func testAudioOverflowRevokesAuthorityBeforeBlockedReceiverReturns() async throws {
        let retirement = Task9OperationGate()
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory(retirementGate: retirement))
        await controller.play(request())
        owner.monitor.emit(.interruptionBegan)
        for _ in 0..<500 {
            if await retirement.hasEntered { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let retirementEntered = await retirement.hasEntered
        XCTAssertTrue(retirementEntered)
        owner.monitor.emit(.interruptionEnded(shouldResume: false))
        for _ in 0..<500 {
            if case .paused = await controller.currentStateForTesting { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let drain = try actualAudioDrain(registry)
        let originalOwner = try XCTUnwrap(registry.outputResourceContextSnapshot()?.owner)
        // ended receiver正在join原retirement；31 pending加1 in-flight后下一条溢出。
        for _ in 0..<32 {
            drain.relay.send(lease: drain.relay.lease,
                event: .init(event: .explicitResumeSucceeded, systemReceipt: nil))
        }
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertTrue(context.poisoned, "send返回前必须同锁撤销原Authority，不能等被阻塞receiver取到failure")
        XCTAssertEqual(context.disposition, .releaseAfterTeardown)
        XCTAssertEqual(context.owner, originalOwner, "溢出撤权不能夺走仍在retirement内的原owner")
        XCTAssertNil(registry.registeredOutputDrainProof())
        await retirement.release()
        for _ in 0..<500 {
            if case .failed = await controller.currentStateForTesting { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard case .failed = await controller.currentStateForTesting else {
            return XCTFail("原retirement尾部之后，唯一overflow终态必须完成owned cleanup")
        }
        // failed只证明软件撤权；不再输入stop，等待原owner自行完成真实lease清理。
        for _ in 0..<500 {
            if registry.ownedResourceSnapshot() == nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNil(registry.ownedResourceSnapshot())
        await controller.stop()
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testAudioFailureReceiverUsesOwnedTerminalCleanupWithoutJoiningItself() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        await controller.play(request())
        owner.monitor.emit(.recoveryFailed(stage: .eventRelayCapacity))
        for _ in 0..<500 {
            if case .failed = await controller.currentStateForTesting { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard case .failed = await controller.currentStateForTesting else {
            // 旧实现receiver→裸teardown→原receiver形成环；RED不再次await同一个死锁。
            return XCTFail("audio failure必须从receiver返回，由原owned cleanup完成后发布终态")
        }
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertEqual(sdk.lock.withLock { sdk.deactivateCallCount }, 1)
        await controller.stop()
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testProductionOwnedDrainConsumesReactivationKeyExactlyOnce() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        await controller.play(request())
        owner.monitor.emit(.interruptionBegan)
        for _ in 0..<500 {
            if registry.registeredOutputDrainProof() != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNotNil(registry.registeredOutputDrainProof())
        owner.monitor.emit(.interruptionEnded(shouldResume: false))
        for _ in 0..<500 {
            if case .paused = await controller.currentStateForTesting { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let completed = expectation(description: "真实SDK回执到达原monitor")
        let receiptLock = NSLock()
        nonisolated(unsafe) var completedEnvelope: PlaybackAudioSessionEventEnvelope?
        owner.monitor.setEventHandler { envelope in
            guard envelope.reactivationReceipt != nil else { return }
            receiptLock.withLock { completedEnvelope = envelope }
            completed.fulfill()
        }
        await controller.setPaused(false)
        await fulfillment(of: [completed], timeout: 1)
        let envelope = try XCTUnwrap(receiptLock.withLock { completedEnvelope })
        let receipt = try XCTUnwrap(envelope.reactivationReceipt)
        for _ in 0..<500 {
            if !registry.acceptsReactivationCompletion(receipt) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(registry.acceptsReactivationCompletion(receipt),
            "准确completion只能由生产owned drain消费一次，observer不能成为第二transport")
        await controller.stop()
    }

    private func actualAudioDrain(_ registry: ControlTaskRegistry) throws
        -> (ticket: ControlTaskTicket, relay: PlaybackAudioSessionEventRelay) {
        var result: (ControlTaskTicket, PlaybackAudioSessionEventRelay)?
        registry.executor.sync {
            let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
            let records = Mirror(reflecting: authority).children.first { $0.label == "commands" }!.value
                as! [OwnedPostIngressControlCommand?]
            for case let record? in records {
                guard record.slot == .systemEventRelay, case .eventDrain(let runner) = record.payload,
                      case .audio(let relay) = runner.relay else { continue }
                result = (record.controlTaskTicket, relay)
            }
        }
        return try XCTUnwrap(result)
    }

    func testAudioKeyObservedBeforeAdmissionCannotBeReboundToTheNewSession() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let oldEvent = try XCTUnwrap(monitor.emit(.interruptionBegan))
        monitor.emit(.interruptionEnded(shouldResume: true))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        await controller.play(request())
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let drain = try actualAudioDrain(registry)
        drain.relay.send(lease: drain.relay.lease, event: .init(event: .explicitResumeSucceeded, systemReceipt: nil))
        for _ in 0..<500 {
            if registry.phase(of: drain.ticket) == .running { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(registry.phase(of: drain.ticket), .running)
        let run = PlaybackRunIdentity(sessionID: context.sessionIdentity.sessionID,
            requestID: context.sessionIdentity.requestID)
        let key = try XCTUnwrap(PlaybackAudioSessionEventKey(envelope: oldEvent))
        XCTAssertNil(registry.consumeAudioSessionEvent(key, run: run, lease: drain.relay.lease, drain: drain.ticket),
            "即使误投到新relay，admission已吸收的旧物理key也不能获得新session动作权")
        await controller.stop()
    }

    func testOwnedAudioDrainAcceptsThirtyTwoSystemKeysBeforeReceiverStarts() async throws {
        try await assertOwnedAudioBurst(count: 32)
    }

    func testOwnedAudioDrainThirtyThirdKeyProducesExactlyOneTerminal() async throws {
        try await assertOwnedAudioBurst(count: 33)
    }

    private func assertOwnedAudioBurst(count: Int) async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let identity = PlaybackRunIdentity(sessionID: 41, requestID: UUID())
        let session = PlaybackSessionIdentity(sessionID: identity.sessionID, requestID: identity.requestID)
        let parent = try registry.createGroup(resource: .context(session: session, nonce: 1))
        let group = try registry.createGroup(resource: .session(session), parent: parent)
        let drain = try registry.enqueue(group: group, slot: .systemEventRelay, policy: .safetyBypass)
        let cleanup = try registry.enqueue(group: parent, slot: .cancel, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(cleanup))
        let received = expectation(description: "原owned receiver按序接收全部32条")
        received.expectedFulfillmentCount = count == 32 ? 32 : 1
        let resultLock = NSLock()
        nonisolated(unsafe) var delivered: [PlaybackAudioSessionEvent] = []
        let lease = PlaybackAudioSessionLease(id: 41, generation: 41)
        let relay = PlaybackAudioSessionEventRelay(identity: identity, lease: lease) { _, _, key, ticket in
            XCTAssertEqual(ticket, drain)
            resultLock.withLock { delivered.append(key.event) }
            received.fulfill()
        }
        XCTAssertTrue(registry.bindEventRelay(relay, to: drain))
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let pattern: [PlaybackAudioSessionEvent] = [
            .interruptionBegan, .interruptionEnded(shouldResume: false), .mediaServicesWereReset,
            .mediaServicesWereReset, .interruptionBegan, .interruptionEnded(shouldResume: true),
            .interruptionBegan, .interruptionEnded(shouldResume: false)
        ]
        let events = (0..<count).map { pattern[$0 % pattern.count] }
        let expected: [PlaybackAudioSessionEvent] = count == 32 ? events : [.recoveryFailed(stage: .eventRelayCapacity)]
        registry.executor.sync {
            for event in events {
                guard let envelope = monitor.emit(event) else { XCTFail("原Cell应签发事件key"); continue }
                relay.send(lease: lease, event: envelope)
            }
        }
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(resultLock.withLock { delivered }, expected,
            "只排队尚未进入receiver不能虚占一个in-flight槽；两种reset/interruption次序都须保留")
        relay.deactivate()
        XCTAssertTrue(registry.seal(group))
        let joined = await registry.joinEventRelay(drain, from: cleanup)
        XCTAssertTrue(joined)
        XCTAssertTrue(registry.retire(drain))
        XCTAssertTrue(registry.releaseGroup(group))
        XCTAssertTrue(registry.complete(cleanup))
        XCTAssertTrue(registry.retire(cleanup))
        XCTAssertTrue(registry.seal(parent))
        XCTAssertTrue(registry.releaseGroup(parent))
    }

    func testBlockedExecutorBeganThenEndedCannotSkipOriginalInterruptionCleanup() async throws {
        for shouldResume in [false, true] {
            let retirement = Task9OperationGate()
            let factory = Task9PreparedFactory(retirementGate: retirement)
            let registry = ControlTaskRegistry(allocator: .init())
            let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
            let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
            let service = PlaybackAudioRouteService(registry: registry, owner: owner)
            let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
                routeService: service, backendFactory: factory)
            await controller.play(request())
            registry.executor.sync {
                owner.monitor.emit(.interruptionBegan)
                owner.monitor.emit(.interruptionEnded(shouldResume: shouldResume))
            }
            for _ in 0..<500 {
                if await retirement.hasEntered { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard await retirement.hasEntered else {
                await retirement.release()
                await controller.stop()
                XCTFail("更晚ended不能把原began丢弃；原owner必须进入真实retirement")
                continue
            }
            XCTAssertNil(registry.registeredOutputDrainProof())
            XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 1,
                "即使ended(true)已入队，真实排空前也不准激活")
            await retirement.release()
            for _ in 0..<750 {
                if shouldResume {
                    if factory.backends.count == 2 && factory.backends.last?.activationCount == 1 { break }
                } else if registry.registeredOutputDrainProof() != nil { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, shouldResume ? 2 : 1)
            XCTAssertEqual(factory.backends.count, shouldResume ? 2 : 1)
            await controller.stop()
        }
    }

    func testReactivationReceiptRejectsAnUnregisteredSourceRecordNonce() throws {
        let fixture = try Task9ExplicitResumeFixture()
        let success = expectation(description: "真实SDK完成后取得原receipt")
        let receiptLock = NSLock()
        nonisolated(unsafe) var saved: AudioSessionReactivationCompletionReceipt?
        fixture.owner.monitor.setEventHandler { envelope in
            guard let receipt = envelope.reactivationReceipt else { return }
            receiptLock.withLock { saved = receipt }
            success.fulfill()
        }
        XCTAssertTrue(fixture.owner.requestResume(for: fixture.lease))
        wait(for: [success], timeout: 1)
        let original = try XCTUnwrap(receiptLock.withLock { saved })
        let foreign = AudioSessionReactivationCompletionReceipt(sourceRecordNonce: .max,
            contextNonce: original.contextNonce, proofNonce: original.proofNonce,
            leaseID: original.leaseID, activationNonce: original.activationNonce,
            interruptionEpoch: original.interruptionEpoch, mediaServicesEpoch: original.mediaServicesEpoch,
            audioAdmissionFenceRevision: original.audioAdmissionFenceRevision)
        XCTAssertTrue(fixture.registry.acceptsReactivationCompletion(original))
        XCTAssertFalse(fixture.registry.acceptsReactivationCompletion(foreign),
            "当前active/proof匹配也不能补造从未登记过的source record")
    }

    func testActualAudioRelayPendingUsesAtMostTwentyFourBytesPerKey() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let controller = try routedController(registry: registry, factory: Task9PreparedFactory())
        await controller.play(request())
        let relay = try XCTUnwrap(registry.executor.safetyIngress.currentOwnedAudioEventRelay())
        let pending = try XCTUnwrap(Mirror(reflecting: relay).children.first {
            $0.label == "pending"
        }?.value as? any Task9NativeArrayObservation)
        XCTAssertEqual(pending.countForAllocation, 32)
        XCTAssertLessThanOrEqual(pending.elementStrideForAllocation, 24,
            "实际relay backing只保存key，不能把lease和两种完整receipt每槽复制")
        await controller.stop()
    }

    func testAcquisitionCancellationCannotDiscardARegisteredLeaseOrItsSDKRecord() throws {
        let fixture = try AcquiringOutputFixture()
        let activation = try fixture.prepareActivation()
        let before = fixture.registry.ownedResourceSnapshot()
        XCTAssertNotNil(before)
        XCTAssertFalse(fixture.registry.cancelAcquisitionSession(),
            "旧acquisition便捷清理不得抹掉真实lease和原SDK命令责任")
        XCTAssertNotNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertEqual(fixture.registry.phase(of: activation), .queued)
        XCTAssertNotNil(fixture.registry.cleanupReservationSnapshot())
    }

    func testUserPauseClosesTheExactRegistryIntervalAndResumeUsesItsLifecycle() async throws {
        let registry = ControlTaskRegistry(allocator: .init())
        let factory = Task9PreparedFactory()
        let controller = try routedController(registry: registry, factory: factory)
        await controller.play(request())
        let backend = try XCTUnwrap(factory.backends.first)
        let original = try XCTUnwrap(registry.outputResourceContextSnapshot()?.activation)
        XCTAssertNotNil(registry.outputResourceContextSnapshot()?.interval)
        await controller.setPaused(true)
        XCTAssertEqual(backend.suspensionEpochs, [original.outputLifecycleEpoch])
        XCTAssertNil(registry.outputResourceContextSnapshot()?.interval,
            "真实suspend回执必须关闭原潜在可出声区间")
        XCTAssertNil(registry.outputResourceContextSnapshot()?.activation)
        await controller.setPaused(false)
        XCTAssertEqual(backend.activationCount, 2)
        XCTAssertEqual(backend.activationEpoch?.outputLifecycleEpoch, original.outputLifecycleEpoch,
            "pause保留prepared时不能伪造新lifecycle")
        XCTAssertEqual(backend.activationEpoch, registry.outputResourceContextSnapshot()?.activation)
        XCTAssertNotNil(registry.outputResourceContextSnapshot()?.interval)
        await controller.stop()
    }

    func testProductionEndedTrueUsesRealActivationBeforeSuccessor() async throws {
        let factory = Task9PreparedFactory()
        let registry = ControlTaskRegistry(allocator: .init())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        owner.monitor.emit(.interruptionBegan)
        for _ in 0..<500 {
            if registry.registeredOutputDrainProof() != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNotNil(registry.registeredOutputDrainProof())
        owner.monitor.emit(.interruptionEnded(shouldResume: true))
        for _ in 0..<750 {
            if factory.backends.count == 2 && factory.backends.last?.activationCount == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 2)
        XCTAssertEqual(factory.backends.count, 2)
        XCTAssertEqual(factory.backends.last?.activationCount, 1)
        await controller.stop()
    }

    func testStopJoinsProductionInterruptionRetirementWithoutReactivation() async throws {
        let retirement = Task9OperationGate()
        let factory = Task9PreparedFactory(retirementGate: retirement)
        let registry = ControlTaskRegistry(allocator: .init())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        owner.monitor.emit(.interruptionBegan)
        for _ in 0..<500 {
            if await retirement.hasEntered { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard await retirement.hasEntered else {
            await retirement.release()
            await controller.stop()
            return XCTFail("必须实际进入原retirement")
        }
        let stop = Task { await controller.stop() }
        await Task.yield()
        XCTAssertNotNil(registry.ownedResourceSnapshot())
        await retirement.release()
        await stop.value
        XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 1)
        XCTAssertEqual(sdk.lock.withLock { sdk.deactivateCallCount }, 1)
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testProductionInterruptionDrainWaitsForOwnedTailBeforeExplicitResume() async throws {
        let retirement = Task9OperationGate()
        let factory = Task9PreparedFactory(retirementGate: retirement)
        let registry = ControlTaskRegistry(allocator: .init())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        owner.monitor.emit(.interruptionBegan)
        for _ in 0..<500 {
            if await retirement.hasEntered { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard await retirement.hasEntered else {
            await retirement.release()
            await controller.stop()
            return XCTFail("生产began必须进入原owned cleanup的真实retirement")
        }
        XCTAssertNil(registry.registeredOutputDrainProof(), "真实retirement未返回不得发行proof")
        owner.monitor.emit(.interruptionEnded(shouldResume: false))
        await retirement.release()
        for _ in 0..<500 {
            if registry.registeredOutputDrainProof() != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNotNil(registry.registeredOutputDrainProof())
        XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 1, "ended(false)本身不能恢复")
        let activationEntered = expectation(description: "生产显式恢复进入真实SDK")
        let activationGate = DispatchSemaphore(value: 0)
        sdk.lock.withLock { sdk.onActivate = { activationEntered.fulfill(); activationGate.wait() } }
        await controller.setPaused(false)
        await fulfillment(of: [activationEntered], timeout: 1)
        XCTAssertEqual(factory.backends.count, 1, "SDK返回前不能创建后继出声对象")
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        activationGate.signal()
        for _ in 0..<750 {
            if factory.backends.count == 2 && factory.backends.last?.activationCount == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(factory.backends.count, 2)
        XCTAssertEqual(factory.backends.last?.activationCount, 1)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.activation, factory.backends.last?.activationEpoch)
        XCTAssertEqual(factory.backends.first?.retirementEpochs.count, 1)
        await controller.stop()
    }

    func testExplicitResumeWaitsForRealActivationCompletion() throws {
        let fixture = try Task9ExplicitResumeFixture()
        let entered = expectation(description: "真实恢复activation已进入")
        let success = expectation(description: "准确completion后才恢复")
        let completionGate = DispatchSemaphore(value: 0)
        let successLock = NSLock()
        nonisolated(unsafe) var successes = 0
        fixture.sdk.onActivate = { entered.fulfill(); completionGate.wait() }
        fixture.owner.monitor.setEventHandler { event in
            if event.event == .explicitResumeSucceeded {
                XCTAssertNotNil(event.reactivationReceipt)
                successLock.withLock { successes += 1 }
                success.fulfill()
            }
        }
        XCTAssertTrue(fixture.owner.requestResume(for: fixture.lease))
        wait(for: [entered], timeout: 1)
        XCTAssertFalse(fixture.owner.requestResume(for: fixture.lease), "原activation运行期间不得重复签发")
        XCTAssertEqual(successLock.withLock { successes }, 0, "SDK尚未返回不能伪造成功")
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        completionGate.signal()
        wait(for: [success], timeout: 1)
        XCTAssertEqual(fixture.sdk.lock.withLock { fixture.sdk.activateCallCount }, 1)
        XCTAssertNotNil(fixture.registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
    }

    func testNewInterruptionWinsAgainstExplicitResumeActivationCompletion() throws {
        try assertPhysicalEventWinsAgainstExplicitResume(.interruptionBegan)
    }

    func testMediaResetWinsAgainstExplicitResumeActivationCompletion() throws {
        try assertPhysicalEventWinsAgainstExplicitResume(.mediaServicesWereReset)
    }

    private func assertPhysicalEventWinsAgainstExplicitResume(_ physicalEvent: PlaybackAudioSessionEvent) throws {
        let fixture = try Task9ExplicitResumeFixture()
        let entered = expectation(description: "真实恢复activation已进入")
        let returned = expectation(description: "真实SDK调用允许返回")
        let staleSuccess = expectation(description: "新began之后旧completion不能成功")
        staleSuccess.isInverted = true
        let completionGate = DispatchSemaphore(value: 0)
        fixture.sdk.onActivate = { entered.fulfill(); completionGate.wait(); returned.fulfill() }
        fixture.owner.monitor.setEventHandler { event in
            if event.event == .explicitResumeSucceeded { staleSuccess.fulfill() }
        }
        XCTAssertTrue(fixture.owner.requestResume(for: fixture.lease))
        wait(for: [entered], timeout: 1)
        fixture.owner.monitor.emit(physicalEvent)
        completionGate.signal()
        wait(for: [returned, staleSuccess], timeout: 0.1)
        XCTAssertEqual(fixture.sdk.lock.withLock { fixture.sdk.activateCallCount }, 1)
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot()?.sessionReceipts?.active)
        XCTAssertFalse(fixture.owner.requestResume(for: fixture.lease), "新物理事件撤销旧proof的恢复调用权")
    }

    func testSupersededRequestAdmissionCannotAcquireOrCancelItsReplacement() throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let first = try registry.admitPlaybackRequest(requestID: UUID())
        let replacement = try registry.admitPlaybackRequest(requestID: UUID())
        guard case .coldStart(let firstBudget) = first else { return XCTFail("必须为cold-start准入") }
        XCTAssertFalse(registry.cancelPlaybackRequest(firstBudget.identity.sessionIdentity))
        XCTAssertEqual(registry.playbackRequestAdmissionSnapshot(), replacement)
        XCTAssertNil(try registry.beginOutputAcquisition(admission: first,
            resetRecoveryMandatorySuffix: 3_000_000_000))
        XCTAssertNotNil(try registry.beginOutputAcquisition(admission: replacement,
            resetRecoveryMandatorySuffix: 3_000_000_000))
    }

    func testColdStartWaitingForPredecessorCannotRefillItsBudget() throws {
        let clock = ManualPlaybackClock(8_000_000_000)
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator(), clock: clock)
        let admission = try registry.admitPlaybackRequest(requestID: UUID())
        clock.advance(nanoseconds: 60_000_000_000)
        XCTAssertNil(try registry.beginOutputAcquisition(admission: admission,
            resetRecoveryMandatorySuffix: 3_000_000_000), "原60秒已到，不能从acquire重新计时")
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testExhaustedRequestIdentityFailsClosedWithoutAnAcquisition() throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator(
            initialIssuedValue: .max, initialNamespace: .session))
        XCTAssertThrowsError(try registry.admitPlaybackRequest(requestID: UUID()))
        XCTAssertNil(registry.playbackRequestAdmissionSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testUnboundRelaysCannotStartReceiverTasks() async {
        let identity = PlaybackRunIdentity(sessionID: 37, requestID: UUID())
        let unexpected = expectation(description: "没有owned record的relay不能启动receiver")
        unexpected.isInverted = true
        let pipeline = PlaybackSessionEventRelay(identity: identity) { _, _ in unexpected.fulfill() }
        let audio = PlaybackAudioSessionEventRelay(identity: identity, lease: .init(id: 37, generation: 37)) {
            _, _, _, _ in unexpected.fulfill()
        }
        pipeline.send(.ready(readinessCycle: 0))
        audio.send(lease: .init(id: 37, generation: 37),
            event: .init(event: .explicitResumeSucceeded, systemReceipt: nil))
        await fulfillment(of: [unexpected], timeout: 0.05)
        pipeline.deactivate()
        audio.deactivate()
    }

    func testProductionControllerOwnsBothRelayRecordsDuringBackendPrepare() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let gate = Task9OperationGate()
        let factory = Task9PreparedFactory(prepareGate: gate)
        let controller = try routedController(registry: registry, factory: factory)
        let requested = request()
        let play = Task { await controller.play(requested) }
        await gate.waitUntilEntered()
        registry.executor.sync {
            let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
            let records = Mirror(reflecting: authority).children.first { $0.label == "commands" }!.value
                as! [OwnedPostIngressControlCommand?]
            let count = records.reduce(0) { count, record in
                guard case .eventDrain = record?.payload else { return count }
                return count + 1
            }
            XCTAssertEqual(count, 2, "实际controller的pipeline/audio relay都必须由原Registry记录持有")
        }
        await gate.release()
        await play.value
        await controller.stop()
    }

    func testPendingResetRejectsRelayTaskAllocationAtTheHandleHandoffBarrier() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let identity = PlaybackRunIdentity(sessionID: 36, requestID: UUID())
        let (group, ticket, cleanup) = try drainTickets(registry: registry, identity: identity)
        let unexpected = expectation(description: "旧epoch的receiver不能运行")
        unexpected.isInverted = true
        let relay = PlaybackSessionEventRelay(identity: identity) { _, _ in unexpected.fulfill() }
        XCTAssertTrue(registry.bindEventRelay(relay, to: ticket))
        registry.executor.sync {
            relay.send(.ready(readinessCycle: 0))
            registry.executor.safetyIngress.performSyncIngress(.mediaServicesReset)
            // 真实source的具名消费入口；固定执行顺序保证安全事件先赢，无sleep竞争。
            registry.drainOwnedEventRelays()
            let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
            let records = Mirror(reflecting: authority).children.first { $0.label == "commands" }!.value
                as! [OwnedPostIngressControlCommand?]
            if let record = records.first(where: { $0?.controlTaskTicket == ticket }) ?? nil,
               case .eventDrain(let runner) = record.payload {
                XCTAssertNil(runner.task, "先线性化的reset必须在分配/换手Task以前取消旧record")
            } else { XCTFail("原record必须继续保有待清理relay") }
        }
        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertTrue(registry.seal(group))
        let joined = await registry.joinEventRelay(ticket, from: cleanup)
        XCTAssertTrue(joined)
        XCTAssertTrue(registry.retire(ticket))
        XCTAssertTrue(registry.releaseGroup(group))
    }

    private func drainTickets(registry: ControlTaskRegistry, identity: PlaybackRunIdentity) throws
        -> (group: ControlTaskGroupTicket, ticket: ControlTaskTicket, cleanup: ControlTaskTicket) {
        let session = PlaybackSessionIdentity(sessionID: identity.sessionID, requestID: identity.requestID)
        let parent = try registry.createGroup(resource: .context(session: session, nonce: 1))
        let group = try registry.createGroup(resource: .session(session), parent: parent)
        let ticket = try registry.enqueue(group: group, slot: .accounting, policy: .routeNeutral)
        let cleanup = try registry.enqueue(group: parent, slot: .cancel, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(cleanup))
        return (group, ticket, cleanup)
    }

    func testForeignCleanupOwnerCannotJoinTheRelayRecord() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let identity = PlaybackRunIdentity(sessionID: 34, requestID: UUID())
        let (group, ticket, cleanup) = try drainTickets(registry: registry, identity: identity)
        let foreignGroup = try registry.createGroup(resource: .session(.init(sessionID: 35, requestID: UUID())))
        let foreign = try registry.enqueue(group: foreignGroup, slot: .cancel, policy: .safetyBypass)
        XCTAssertTrue(registry.claimStart(foreign))
        let relay = PlaybackSessionEventRelay(identity: identity) { _, _ in }
        XCTAssertTrue(registry.bindEventRelay(relay, to: ticket))
        XCTAssertTrue(registry.seal(group))
        let rejected = await registry.joinEventRelay(ticket, from: foreign)
        XCTAssertFalse(rejected, "其他session的cleanup不得处置原relay")
        let accepted = await registry.joinEventRelay(ticket, from: cleanup)
        XCTAssertTrue(accepted)
        XCTAssertTrue(registry.retire(ticket))
        XCTAssertTrue(registry.releaseGroup(group))
    }

    func testAudioRelayUsesTheSameOwnedDrainAndCannotCompleteBeforeJoin() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let identity = PlaybackRunIdentity(sessionID: 32, requestID: UUID())
        let (group, ticket, cleanup) = try drainTickets(registry: registry, identity: identity)
        let gate = Task9OperationGate()
        let entered = expectation(description: "audio receiver已进入")
        let relay = PlaybackAudioSessionEventRelay(identity: identity, lease: .init(id: 32, generation: 32)) { _, _, _, _ in
            entered.fulfill()
            await gate.enter()
        }
        XCTAssertTrue(registry.bindEventRelay(relay, to: ticket))
        relay.send(lease: .init(id: 32, generation: 32),
            event: .init(event: .explicitResumeSucceeded, systemReceipt: nil))
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(registry.phase(of: ticket), .running)
        XCTAssertFalse(registry.complete(ticket), "通用completion不能绕过原Task的join")
        relay.deactivate()
        XCTAssertTrue(registry.seal(group))
        XCTAssertFalse(registry.isTerminal(group))
        await gate.release()
        let joined = await registry.joinEventRelay(ticket, from: cleanup)
        XCTAssertTrue(joined)
        XCTAssertTrue(registry.retire(ticket))
        XCTAssertTrue(registry.releaseGroup(group))
    }

    func testSealedOwnedDrainRejectsTheNextQueuedDelivery() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let identity = PlaybackRunIdentity(sessionID: 33, requestID: UUID())
        let (group, ticket, cleanup) = try drainTickets(registry: registry, identity: identity)
        let gate = Task9OperationGate()
        let entered = expectation(description: "第一个receiver已进入")
        let rejected = expectation(description: "seal后的第二个事件不能交付")
        rejected.isInverted = true
        let firstReturned = expectation(description: "第一个receiver已返回")
        let relay = PlaybackSessionEventRelay(identity: identity) { _, event in
            if event == .ready(readinessCycle: 0) {
                entered.fulfill()
                await gate.enter()
                firstReturned.fulfill()
            } else { rejected.fulfill() }
        }
        XCTAssertTrue(registry.bindEventRelay(relay, to: ticket))
        relay.send(.ready(readinessCycle: 0))
        await fulfillment(of: [entered], timeout: 3)
        relay.send(.ready(readinessCycle: 1))
        XCTAssertTrue(registry.seal(group))
        await gate.release()
        await fulfillment(of: [firstReturned], timeout: 3)
        await fulfillment(of: [rejected], timeout: 0.05)
        let joined = await registry.joinEventRelay(ticket, from: cleanup)
        XCTAssertTrue(joined)
        XCTAssertTrue(registry.retire(ticket))
        XCTAssertTrue(registry.releaseGroup(group))
    }

    func testRegistryOwnsTheRelayDrainUntilActualReceiverExit() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let identity = PlaybackRunIdentity(sessionID: 31, requestID: UUID())
        let (group, ticket, cleanup) = try drainTickets(registry: registry, identity: identity)
        let gate = Task9OperationGate()
        let entered = expectation(description: "原record的receiver已进入")
        let relay = PlaybackSessionEventRelay(identity: identity) { _, _ in
            entered.fulfill()
            await gate.enter()
        }
        XCTAssertTrue(registry.bindEventRelay(relay, to: ticket))
        relay.send(.ready(readinessCycle: 0))
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(registry.phase(of: ticket), .running,
            "receiver必须由同一Registry已claim的原record持有")
        relay.deactivate()
        XCTAssertTrue(registry.seal(group))
        XCTAssertFalse(registry.isTerminal(group), "deactivate不能把尚未返回的receiver冒充terminal")
        await gate.release()
        let joined = await registry.joinEventRelay(ticket, from: cleanup)
        XCTAssertTrue(joined, "必须等待原Task真实退出才可确认join")
        XCTAssertEqual(registry.phase(of: ticket), .terminal(.canceled))
        XCTAssertTrue(registry.retire(ticket))
        XCTAssertTrue(registry.releaseGroup(group))
    }

    private func request(_ channel: String = "local") -> PlaybackRequest {
        PlaybackRequest(sourceProfileID: UUID(), channelID: channel,
            streamURL: URL(string: "http://localhost/fixture.m3u8")!, title: "本地测试")
    }

    private func routedController(registry: ControlTaskRegistry,
        factory: Task9PreparedFactory) throws -> PlaybackController {
        let owner = try PlaybackAudioSessionOwner(registry: registry,
            sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        return PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
    }

    @MainActor
    func testPublicInitializerUsesTheAudioOwnersExactMonitor() throws {
        let controller = PlaybackController()
        let fields = Mirror(reflecting: controller).children
        let owner = try XCTUnwrap(fields.first { $0.label == "audioSessionOwner" }?.value as? PlaybackAudioSessionOwner)
        let monitor = try XCTUnwrap(fields.first { $0.label == "audioEventMonitor" }?.value as? SystemAudioEventMonitor)
        XCTAssertTrue(owner.monitor === monitor,
            "公开构造必须把owner自身的同一monitor接入controller，才能交付恢复completion")
    }

    func testUnregisteredExplicitResumeCannotFabricateActivationSuccess() throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let success = expectation(description: "错误的恢复成功不能发布")
        success.isInverted = true
        owner.monitor.setEventHandler { event in
            if event.event == .explicitResumeSucceeded { success.fulfill() }
        }
        let accepted = owner.requestResume(for: .init(id: 999, generation: 999))
        XCTAssertFalse(accepted, "未经登记的lease没有任何恢复调用权")
        XCTAssertEqual(sdk.lock.withLock { sdk.activateCallCount }, 0)
        wait(for: [success], timeout: 0.01)
    }

    func testInstalledBackendIsOwnedByTheRegistryContext() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let factory = Task9PreparedFactory()
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .installed,
            "完成prepare的实际backend必须安装在唯一Registry资源形态内")
        guard case .backend(let identity, let lifecycle, _, _, _) = registry.ownedResourceSnapshot()?.payload else {
            XCTFail("Registry仅持有lease，controller旁路持有了实际backend")
            await controller.stop()
            return
        }
        XCTAssertEqual(identity, factory.backends.first?.identity)
        XCTAssertEqual(lifecycle, factory.backends.first?.activationEpoch?.outputLifecycleEpoch)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.activation, factory.backends.first?.activationEpoch)
        XCTAssertTrue(registry.outputResourceContextSnapshot()?.prepared == true)
        XCTAssertNotNil(registry.outputResourceContextSnapshot()?.interval,
            "真实正速率调用之前必须取得唯一潜在出声interval")
        await controller.stop()
        let output = try XCTUnwrap(lifecycle)
        XCTAssertEqual(factory.backends.first?.suspensionEpochs, [output], "只可由原owner静止原lifecycle一次")
        XCTAssertEqual(factory.backends.first?.retirementEpochs, [output], "只可由原owner退休原lifecycle一次")
        XCTAssertNil(registry.ownedResourceSnapshot(), "stop必须释放原backend和lease")
        XCTAssertNil(registry.cleanupReservationSnapshot(), "实际退出后才能释放原cleanup预留")
        XCTAssertEqual(sdk.lock.withLock { sdk.deactivateCallCount }, 1)
    }

    func testColdStartBudgetUsesTheRequestAdmissionClockInstant() async throws {
        let clock = ManualPlaybackClock(8_000_000_000)
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator(), clock: clock)
        let gate = Task9OperationGate()
        let factory = Task9PreparedFactory(prepareGate: gate)
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        let request = request()
        let play = Task { await controller.play(request) }
        // 只推进真实sampler之后的单调时钟；不直接写stable commit或伪造路由。
        for _ in 0..<500 {
            if sdk.lock.withLock({ sdk.routeCallCount > 0 }) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        clock.advance(nanoseconds: 125_000_000)
        for _ in 0..<2_000 {
            if await gate.hasEntered { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let entered = await gate.hasEntered
        let state = await controller.currentStateForTesting
        XCTAssertTrue(entered, "实际factory/prepare未进入；状态：\(state)")
        let deadline = registry.outputResourceContextSnapshot()?.parentDeadline
        if case .coldStart(let budget) = deadline {
            XCTAssertEqual(budget.originInstant, 8_000_000_000,
                "不能把真实单调时钟的请求准入时刻改写为0")
            registry.executor.sync {
                let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
                let admission = Mirror(reflecting: authority).children.first {
                    $0.label == "playbackRequestAdmission"
                }?.value as? CurrentPlaybackOperationDeadlineTicket
                guard case .coldStart(let admitted) = admission else {
                    return XCTFail("请求身份和原始预算必须在唯一Authority登记，不能仅保存在controller局部")
                }
                XCTAssertEqual(admitted.identity, budget.identity)
                XCTAssertEqual(admitted.originInstant, budget.originInstant)
            }
        } else {
            XCTFail("首次准备必须沿用准入时安装的cold-start预算")
        }
        await gate.release()
        await play.value
        await controller.stop()
    }

    func testRepeatedHandoffJoinsTheExistingRetirement() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        harness.holdOldStopConfirmation()
        await harness.requestAirPlay()
        await harness.controller.requestRouteHandoff(to: .hlsAVPlayer)
        XCTAssertEqual(harness.backendCreationCount, 1, "重复请求不能越过旧retirement")
        harness.confirmOldStopAndRetirement()
        await harness.drain()
        XCTAssertEqual(harness.backendCreationCount, 2)
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
        XCTAssertEqual(harness.currentAudibleOutputs, 1,
            "交接终值：\(String(describing: harness.registry.outputResourceContextSnapshot()))；路由：\(String(describing: harness.registry.outputRouteObservationSnapshot()))")
        await harness.controller.stop()
    }

    func testRouteReversalRecomputesTheSuccessorAfterRetirement() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        harness.holdOldStopConfirmation()
        await harness.requestAirPlay()
        harness.setRoute(.sampleBuffer)
        await harness.controller.requestRouteHandoff(to: .sampleBuffer)
        harness.confirmOldStopAndRetirement()
        await harness.drain()
        XCTAssertEqual(harness.factory.createdBackends.last?.kind, .sampleBuffer,
            "旧stop期间的A→B→A必须由最新目标决定successor")
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
        XCTAssertEqual(harness.currentAudibleOutputs, 1)
        await harness.controller.stop()
    }

    func testOldStopCannotPublishStoppedOverANewlyAdmittedPlay() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        harness.holdOldStopConfirmation()
        let first = try XCTUnwrap(harness.factory.createdBackends.first)
        let stop = Task { await harness.controller.stop() }
        await first.waitForRetireEntered()
        let replacement = request("replacement")
        let states = await harness.controller.events()
        let admitted = expectation(description: "新play在旧stop等待期间已准入")
        let observation = Task {
            for await state in states {
                if state == .preparing(replacement) { admitted.fulfill(); return }
            }
        }
        let play = Task { await harness.controller.play(replacement) }
        await fulfillment(of: [admitted], timeout: 3)
        harness.confirmOldStopAndRetirement()
        await stop.value
        await play.value
        let state = await harness.controller.currentStateForTesting
        XCTAssertNotEqual(state, .stopped, "旧stop尾部不能覆盖新play的状态")
        XCTAssertEqual(harness.backendCreationCount, 2)
        observation.cancel()
        await harness.controller.stop()
    }

    func testPauseThenResumeDuringPrepareWaitsAndActivatesExactlyOnce() async throws {
        let gate = Task9OperationGate()
        let factory = Task9PreparedFactory(prepareGate: gate)
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        let request = request()
        let play = Task { await controller.play(request) }
        await gate.waitUntilEntered()
        let backend = try XCTUnwrap(factory.backends.first)
        await controller.setPaused(true)
        await controller.setPaused(false)
        XCTAssertEqual(backend.activationCount, 0, "prepare尚未返回，resume只能更新intent")
        XCTAssertTrue(backend.suspensionEpochs.isEmpty, "prepare期间pause不能调用未完成backend的输出API")
        await gate.release()
        await play.value
        XCTAssertEqual(backend.activationCount, 1, "prepared后只可消费一次最新许可")
        XCTAssertEqual(backend.activationEpoch, registry.outputResourceContextSnapshot()?.activation)
        await controller.stop()
    }

    func testOneSystemEventAdvancesItsRevisionAndEpochOnlyOnce() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let owner = try PlaybackAudioSessionOwner(registry: registry,
            sdk: FakeAudioSessionSDK(initialPorts: .hdmi))
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: Task9PreparedFactory())
        await controller.play(request())
        let stream = await controller.events()
        let delivered = expectation(description: "真实monitor事件已由controller消费")
        let observation = Task {
            for await state in stream {
                if case .recovering = state { delivered.fulfill(); return }
            }
        }
        let before = registry.executor.safetyIngress.snapshot
        owner.monitor.emit(.interruptionBegan)
        await fulfillment(of: [delivered], timeout: 3)
        let after = registry.executor.safetyIngress.snapshot
        XCTAssertEqual(after.throughRevision, before.throughRevision + 1)
        XCTAssertEqual(after.interruptionEpoch, before.interruptionEpoch + 1)
        XCTAssertEqual(after.audioAdmissionFenceRevision, before.audioAdmissionFenceRevision + 1)
        observation.cancel()
        await controller.stop()
    }

    func testBackendStoppedReleasesTheOriginalRegistryLease() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let factory = Task9PreparedFactory()
        let controller = try routedController(registry: registry, factory: factory)
        await controller.play(request())
        let stream = await controller.events()
        let delivered = expectation(description: "backend终态已消费")
        let observation = Task {
            for await state in stream {
                if state == .stopped { delivered.fulfill(); return }
            }
        }
        try XCTUnwrap(factory.backends.first).emit(.stopped)
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertNil(registry.ownedResourceSnapshot(), "终态不能只清空controller旁路backend")
        XCTAssertNil(registry.outputResourceContextSnapshot())
        observation.cancel()
        await controller.stop()
    }

    func testBackendTerminalRetirementIsOwnedAndStopJoinsItsExactTail() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let gate = Task9OperationGate()
        let factory = Task9PreparedFactory(retirementGate: gate)
        let controller = try routedController(registry: registry, factory: factory)
        await controller.play(request())
        let backend = try XCTUnwrap(factory.backends.first)
        backend.emit(.stopped)
        for _ in 0..<500 {
            if await gate.hasEntered { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard await gate.hasEntered else {
            await gate.release()
            await controller.stop()
            return XCTFail("backend终态必须由原owned cleanup runner进入真实retirement")
        }
        registry.executor.sync {
            let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
            let records = Mirror(reflecting: authority).children.first { $0.label == "commands" }!.value
                as! [OwnedPostIngressControlCommand?]
            let owned = records.first { $0?.slot == .committedCleanup } ?? nil
            XCTAssertNotNil(owned?.payload, "SDK等待期间原cleanup record必须强持真实Task runner")
        }
        let stop = Task { await controller.stop() }
        await Task.yield()
        XCTAssertNotNil(registry.ownedResourceSnapshot())
        await gate.release()
        await stop.value
        XCTAssertEqual(backend.retirementEpochs.count, 1)
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0, "stop须join真实尾部后释放原记录与group")
    }

    func testSameSessionRetiredBackendTerminalCannotClearItsSuccessor() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let factory = Task9PreparedFactory()
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        await controller.play(request())
        let predecessor = try XCTUnwrap(factory.backends.first)
        sdk.lock.withLock { sdk.initialPorts = .airPlay }
        await controller.requestRouteHandoff(to: .hlsAVPlayer)
        let successor = try XCTUnwrap(factory.backends.last)
        XCTAssertNotEqual(predecessor.identity, successor.identity)
        let stream = await controller.events()
        let unexpected = expectation(description: "原后端迟到terminal不得结束同session后继")
        unexpected.isInverted = true
        let observation = Task {
            for await state in stream {
                if state == .stopped { unexpected.fulfill(); return }
            }
        }
        predecessor.emit(.stopped)
        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.candidateBackendIdentity, successor.identity)
        XCTAssertTrue(successor.retirementEpochs.isEmpty)
        observation.cancel()
        await controller.stop()
    }

    func testBlockedRelayNeverRetainsBackingBeyondItsFixedCapacity() async throws {
        let gate = Task9OperationGate()
        let identity = PlaybackRunIdentity(sessionID: 1, requestID: UUID())
        let relay = PlaybackSessionEventRelay(identity: identity) { _, _ in
            await gate.enter()
        }
        try bindOwnedRelayForTesting(.pipeline(relay), identity: identity)
        relay.send(.stopped)
        await gate.waitUntilEntered()
        for _ in 0..<4_096 { relay.send(.stopped) }
        // drain被准确阻塞，所有send已返回；只借用真实数组统计本体，不保存背板跨mutation。
        let storage = Mirror(reflecting: relay).children.compactMap { $0.value as? [PlaybackPipelineEvent] }.first
        let bytes = storage.map { 32 + $0.capacity * MemoryLayout<PlaybackPipelineEvent>.stride }
        XCTAssertLessThanOrEqual(try XCTUnwrap(bytes), 16 * 1_024,
            "逻辑pendingIndex上限不能掩盖Array backing持续扩张")
        relay.deactivate()
        await gate.release()
    }

    func testPipelineRelayOverflowProducesOneTerminalInsteadOfSilentlyDroppingEvents() async throws {
        let gate = Task9OperationGate()
        let failed = expectation(description: "容量溢出必须交付明确终态")
        failed.assertForOverFulfill = true
        let identity = PlaybackRunIdentity(sessionID: 1, requestID: UUID())
        let relay = PlaybackSessionEventRelay(identity: identity) { _, event in
            await gate.enter()
            if event == .failed(.controlEventCapacityExceeded) { failed.fulfill() }
        }
        try bindOwnedRelayForTesting(.pipeline(relay), identity: identity)
        relay.send(.ready(readinessCycle: 0))
        await gate.waitUntilEntered()
        for value in 1...64 { relay.send(.ready(readinessCycle: UInt64(value))) }
        await gate.release()
        await fulfillment(of: [failed], timeout: 2)
        relay.deactivate()
    }

    func testAudioRelayOverflowProducesOneTerminalInsteadOfSilentlyDroppingEvents() async throws {
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
        let gate = Task9OperationGate()
        let failed = expectation(description: "音频事件容量溢出必须交付明确终态")
        failed.assertForOverFulfill = true
        let identity = PlaybackRunIdentity(sessionID: 1, requestID: UUID())
        let relay = PlaybackAudioSessionEventRelay(identity: identity, lease: .init(id: 1, generation: 1)) { _, _, envelope, _ in
            await gate.enter()
            if envelope.event == .recoveryFailed(stage: .eventRelayCapacity) { failed.fulfill() }
        }
        try bindOwnedRelayForTesting(.audio(relay), identity: identity)
        let lease = PlaybackAudioSessionLease(id: 1, generation: 1)
        relay.send(lease: lease, event: try XCTUnwrap(monitor.emit(.interruptionBegan)))
        await gate.waitUntilEntered()
        for _ in 0..<64 {
            relay.send(lease: lease, event: try XCTUnwrap(monitor.emit(.interruptionEnded(shouldResume: false))))
        }
        await gate.release()
        await fulfillment(of: [failed], timeout: 2)
        relay.deactivate()
    }
}

private struct Task9RuntimeFixture {
    let registry: ControlTaskRegistry
    let owner: PlaybackAudioSessionOwner
    let controller: PlaybackController
    let factory: Task9PreparedFactory
    let sdk: FakeAudioSessionSDK
    init(factory: Task9PreparedFactory = .init(), allocator: PlaybackIdentityAllocator = .init(),
         clock: any PlaybackMonotonicClock = DispatchPlaybackMonotonicClock()) throws {
        registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        self.factory = factory
    }
    func request() -> PlaybackRequest {
        .init(sourceProfileID: UUID(), channelID: "runtime", streamURL: URL(string: "http://localhost/runtime.m3u8")!,
            title: "唯一所有权测试")
    }
}

/// 只观察真实对象的保留责任；不通过生产测试API注入runner、receipt或授权。
private func task9OwnedRecords(_ registry: ControlTaskRegistry) -> [OwnedPostIngressControlCommand] {
    var records: [OwnedPostIngressControlCommand] = []
    registry.executor.sync {
        let authority = Mirror(reflecting: registry).children.first { $0.label == "authority" }!.value
        records = (Mirror(reflecting: authority).children.first { $0.label == "commands" }!.value
            as! [OwnedPostIngressControlCommand?]).compactMap { $0 }
    }
    return records
}

private func task9ContainsTask(_ value: Any, depth: Int = 0) -> Bool {
    if value is Task<Void, Never> { return true }
    guard depth < 4 else { return false }
    return Mirror(reflecting: value).children.contains { task9ContainsTask($0.value, depth: depth + 1) }
}

private func task9BorrowedResourceCount(_ value: Any, depth: Int = 0) -> Int {
    if value is any PlaybackBackend || value is PlaybackAudioSessionLease ||
       value is PlaybackSessionEventRelay || value is PlaybackAudioSessionEventRelay { return 1 }
    let mirror = Mirror(reflecting: value)
    guard depth < 4, depth == 0 || mirror.displayStyle != .class else { return 0 }
    return mirror.children.reduce(0) { $0 + task9BorrowedResourceCount($1.value, depth: depth + 1) }
}

/// Batch5只通过真实runtime、SDK和原record观察终态；手动时钟不模拟receipt。
private final class Task9CompletionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.withLock { completed } }
    func complete() { lock.withLock { completed = true } }
}

private final class Task9WeakRuntime {
    weak var controller: PlaybackController?
    weak var registry: ControlTaskRegistry?
    weak var runner: OwnedPlaybackCleanupTask?
}

/// 真实controller完成资源CAS后，测试只阻塞原receiver返回，以观察未join的孤儿Task尾。
private final class Task9OrphanCleanupReceiver: PlaybackOwnedCleanupReceiving, Sendable {
    let controller: PlaybackController
    let gate: Task9OperationGate
    init(controller: PlaybackController, gate: Task9OperationGate) {
        self.controller = controller
        self.gate = gate
    }
    func performOwnedTerminalCleanup(owner: OutputTransitionOwnerTicket,
        task: ControlTaskTicket, terminalState: PlaybackState) async {
        await controller.performOwnedTerminalCleanup(owner: owner, task: task, terminalState: terminalState)
        await gate.enter()
    }
}

final class Task9ProductionDeadlineTests: XCTestCase {
    func testStateSubscriptionInstallationCannotReplaySnapshotOlderThanAutomaticFailure() async throws {
        let fixture = try Task9RuntimeFixture()
        XCTAssertEqual(fixture.registry.playbackStateSnapshot(), .idle)
        let terminal = PlaybackState.failed(.init(code: "test.terminal", userMessage: "测试终态"))
        fixture.registry.publishState(terminal)
        // 旧snapshot之后、安装之前发生终态；新API不再接收窗口外的initial。
        let stream = await fixture.controller.events()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, terminal, "安装必须读取同一Authority当前值，不能接受窗口外的旧snapshot")
    }

    func testReadOnlyRuntimeProjectionsDoNotConsumePendingSafetyIngress() throws {
        let fixture = try Task9RuntimeFixture()
        let session = PlaybackSessionIdentity(sessionID: 701, requestID: UUID())
        let group = try fixture.registry.createGroup(resource: .session(session))
        let ticket = try fixture.registry.enqueue(group: group, slot: .accounting, policy: .routeNeutral)
        let owner = OutputTransitionOwnerTicket(identity: group.ownerTicket, reason: .stop)
        let observations: [(String, () -> Void)] = [
            ("state", { _ = fixture.registry.playbackStateSnapshot() }),
            ("deadline", { _ = fixture.registry.playbackDeadlineScheduleSnapshot() }),
            ("context", { _ = fixture.registry.outputResourceContextSnapshot() }),
            ("resource", { _ = fixture.registry.ownedResourceSnapshot() }),
            ("reservation", { _ = fixture.registry.cleanupReservationSnapshot() }),
            ("occupancy", { _ = fixture.registry.occupancy }),
            ("deactivation", { _ = fixture.registry.ownedDeactivationDisposition() }),
            ("lease", { _ = fixture.registry.audioSessionLease(session: session) }),
            ("metrics", { _ = fixture.registry.metricsProjection(window: .seconds(1)) }),
            ("terminalMetrics", { _ = fixture.registry.terminalMetricsProjection(backendIdentity: nil) }),
            ("taskPhase", { _ = fixture.registry.phase(of: ticket) }),
            ("groupTerminal", { _ = fixture.registry.isTerminal(group) }),
            ("audioPhase", { _ = fixture.registry.registeredAudioSessionPhase() }),
            ("activationOutcome", { _ = fixture.registry.activationOutcome(of: ticket) }),
            ("activationDisposition", { _ = fixture.registry.activationDeactivationDisposition(of: ticket) }),
            ("registration", { _ = fixture.registry.audioSessionRegistration(for: ticket) }),
            ("cleanupTask", { _ = fixture.registry.outputCleanupOwnerTask(owner) }),
            ("drainProof", { _ = fixture.registry.registeredOutputDrainProof() })
        ]
        var before: PlaybackSafetySnapshot?
        var after: PlaybackSafetySnapshot?
        fixture.registry.executor.sync {
            let authority = Mirror(reflecting: fixture.registry).children.first { $0.label == "authority" }!.value
            for (index, observation) in observations.enumerated() {
                let (name, observe) = observation
                before = Mirror(reflecting: authority).children.first { $0.label == "snapshot" }!.value as? PlaybackSafetySnapshot
                let event: PlaybackSystemSafetyEvent = index.isMultiple(of: 2)
                    ? .interruptionBegan : .interruptionEnded(shouldResume: false)
                _ = fixture.registry.executor.safetyIngress.performSyncIngress(event)
                let pending = fixture.registry.executor.safetyIngress.snapshot
                XCTAssertGreaterThan(pending.throughRevision, before?.throughRevision ?? 0,
                    "\(name)之前必须有尚未被Authority消费的准确新事件")
                XCTAssertTrue(pending.safetyIngressPending)
                observe()
                after = Mirror(reflecting: authority).children.first { $0.label == "snapshot" }!.value as? PlaybackSafetySnapshot
                XCTAssertEqual(after?.throughRevision, before?.throughRevision,
                    "\(name)只读投影不能抢先消费pending ingress并替原source驱动自动终态")
            }
        }
        // parked-acquisition需要实际registration的其他运行时门禁已覆盖；这里补结构检查防止回落barrier。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/VPlayerPlayback/Control/ControlTaskRegistry.swift"), encoding: .utf8)
        let body = try XCTUnwrap(source.components(separatedBy: "func acquisitionIsParkedForPhysicalResume").last?
            .components(separatedBy: "\n    func ").first)
        XCTAssertFalse(body.contains("transaction"), "纯等待状态查询不得偷偷执行barrier")
        XCTAssertTrue(body.contains("projection"))
    }

    func testRejectedSecondProgressWaitEndsReentrantPlayInsteadOfBusyRetrying() async throws {
        let clock = ManualPlaybackClock(100)
        let fixture = try Task9RuntimeFixture(clock: clock)
        let sdkGate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "真实SDK进入，play等待其准确acquisition")
        fixture.sdk.lock.withLock { fixture.sdk.onActivate = { entered.fulfill(); sdkGate.wait() } }
        let returned = Task9CompletionObservation()
        let play = Task { await fixture.controller.play(fixture.request()); returned.complete() }
        await fulfillment(of: [entered], timeout: 2)
        await settle {
            var parked = false
            fixture.registry.executor.sync {
                parked = Mirror(reflecting: fixture.registry.progressSignal).children.contains {
                    $0.label == "waiter" && !Mirror(reflecting: $0.value).children.isEmpty
                }
            }
            return parked
        }
        let acquisition = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.sourceTask)
        let parked = expectation(description: "相同准确ticket的竞争caller占有唯一固定槽")
        let competing = Task {
            await withCheckedContinuation { continuation in
                fixture.registry.executor.sync {
                    // 唤醒原play但仍占住executor，确定性地让第二caller先登记同一个固定槽。
                    fixture.registry.progressSignal.signal()
                    let result = fixture.registry.progressSignal.register(continuation,
                        key: .init(phase: 0, nonce: acquisition.nonce))
                    if case .parked = result { parked.fulfill() }
                    else { XCTFail("测试gate必须占有唯一槽"); continuation.resume(returning: false) }
                }
            }
        }
        await fulfillment(of: [parked], timeout: 2)
        let rejected = await fixture.registry.waitForPlaybackProgress(.acquisition(acquisition))
        XCTAssertFalse(rejected, "同Authority的第二等待不能替换原continuation")
        await settle { returned.value }
        XCTAssertTrue(returned.value, "controller丢失等待权后必须退出，不能即时重试忙循环")
        fixture.registry.progressSignal.signal()
        _ = await competing.value
        sdkGate.signal()
        fixture.sdk.lock.withLock { fixture.sdk.onActivate = nil }
        await fixture.controller.stop()
        await play.value
    }

    func testParkedRecoveryTailDoesNotRetainControllerOrRegistryAfterRuntimeRelease() async throws {
        let references = try await makeParkedRecoveryWeakReferences()
        await settle { references.controller == nil && references.registry == nil && references.runner == nil }
        XCTAssertNil(references.controller, "disposition等待期间不得强持receiver/controller")
        XCTAssertNil(references.registry, "原Task不能跨无限等待强持Registry形成环")
        XCTAssertNil(references.runner, "runtime释放必须唤醒原单waiter，释放runner↔Task尾")
        if let runner = references.runner {
            let attachment = XCTAttachment(string: "弱尾诊断：task=\(String(describing: runner.task))；waiter=\(String(describing: runner.dispositionWaiter))；join=\(runner.joinRequested)；terminal=\(runner.terminalRequested)")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // RED失败也不遗留测试runtime；这不是正式成功路径的一部分。
        await references.controller?.stop()
    }

    private func makeParkedRecoveryWeakReferences() async throws -> Task9WeakRuntime {
        let clock = ManualPlaybackClock(100)
        let fixture = try Task9RuntimeFixture(clock: clock)
        let play = Task { await fixture.controller.play(fixture.request()) }
        await establishStableRoute(fixture, clock: clock)
        await play.value
        fixture.owner.monitor.emit(.interruptionBegan)
        await settle {
            task9OwnedRecords(fixture.registry).contains {
                if case .controllerCleanup(let runner) = $0.payload { return runner.dispositionWaiter != nil }
                return false
            }
        }
        let record = try XCTUnwrap(task9OwnedRecords(fixture.registry).first {
            if case .controllerCleanup(let runner) = $0.payload { return runner.dispositionWaiter != nil }
            return false
        })
        guard case .controllerCleanup(let runner) = record.payload else { throw ControlTaskRegistry.Failure.invalidGroup }
        let references = Task9WeakRuntime()
        references.controller = fixture.controller
        references.registry = fixture.registry
        references.runner = runner
        return references
    }

    func testProductionReadyConsumesExactParentAndLaterBufferingReadySurvivesFortySeconds() async throws {
        let clock = ManualPlaybackClock(100)
        let fixture = try Task9RuntimeFixture(clock: clock)
        let request = fixture.request()
        let play = Task { await fixture.controller.play(request) }
        await establishStableRoute(fixture, clock: clock)
        await play.value
        let backend = try XCTUnwrap(fixture.factory.backends.first)
        XCTAssertNotNil(fixture.registry.playbackDeadlineScheduleSnapshot().playbackOperation)
        backend.emit(.ready(readinessCycle: 0))
        await settle { await fixture.controller.currentStateForTesting == .playing(request) }
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot()?.parentDeadline,
            "SampleBuffer实际readiness观察由Authority消费当前准确interval，不能留下40秒parent")
        XCTAssertNil(fixture.registry.playbackDeadlineScheduleSnapshot().playbackOperation)
        clock.advance(nanoseconds: 40_000_000_000)
        fixture.registry.executor.sync {}
        await assertFailed(fixture.controller, expected: false)
        backend.emit(.phase(.buffering, readinessCycle: 0))
        await settle { await fixture.controller.currentStateForTesting == .buffering(request) }
        backend.emit(.ready(readinessCycle: 0))
        await settle { await fixture.controller.currentStateForTesting == .playing(request) }
        let state = await fixture.controller.currentStateForTesting
        XCTAssertEqual(state, .playing(request), "parent已消费不应吞掉同interval的后续合法ready")
        if state != .playing(request) {
            let attachment = XCTAttachment(string: "ready后继诊断：context=\(String(describing: fixture.registry.outputResourceContextSnapshot()))；safety=\(fixture.registry.executor.safetyIngress.snapshot)；route=\(String(describing: fixture.registry.stableRouteCommitSnapshot()))；records=\(task9OwnedRecords(fixture.registry))")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(fixture.factory.outputConcurrency.maximum, 1)
        await fixture.controller.stop()
    }

    func testPlayingPublicationCannotOverwriteSafetyFailureConsumedByItsOwnBarrier() async throws {
        let clock = ManualPlaybackClock(100)
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max, initialNamespace: .systemEvent)
        let fixture = try Task9RuntimeFixture(allocator: allocator, clock: clock)
        let request = fixture.request()
        let play = Task { await fixture.controller.play(request) }
        await establishStableRoute(fixture, clock: clock)
        await play.value
        var state: PlaybackState = .idle
        fixture.registry.executor.sync {
            fixture.owner.monitor.emit(.interruptionBegan)
            // source尚不能进入；publication自身的barrier先看到sticky failure。
            fixture.registry.publishState(.playing(request))
            state = fixture.registry.playbackStateSnapshot()
        }
        XCTAssertNotEqual(state, .playing(request), "安全失败不能被同transaction尾部无条件playing覆盖")
        await settle { fixture.registry.cleanupReservationSnapshot() == nil }
        await fixture.controller.stop()
    }

    func testRuntimeOwnsExactlyEightBudgetSlotsAndOneIndependentStabilitySource() async throws {
        let clock = ManualPlaybackClock(100)
        let fixture = try Task9RuntimeFixture(clock: clock)
        let scheduler = Mirror(reflecting: fixture.controller).children.compactMap { $0.value as? PlaybackDeadlineScheduler }
        XCTAssertEqual(scheduler.count, 1, "生产controller必须长期持有一个8槽scheduler")
        XCTAssertEqual(clock.deadlineTimerHandlerInstallationCount, 2, "预算和120ms稳定源各一个，不能有第三个")
        if let scheduler = scheduler.first {
            let slots = Mirror(reflecting: scheduler).children.filter {
                ["acquisition", "cleanup", "ordinaryRoute", "resetPreRoute", "postConfiguration",
                 "reactivation", "playbackOperation", "suspend"].contains($0.label ?? "")
            }
            XCTAssertEqual(slots.count, 8)
        }
        let play = Task { await fixture.controller.play(fixture.request()) }
        await waitForStabilityArm(fixture)
        let original = try XCTUnwrap(fixture.registry.playbackDeadlineScheduleSnapshot().ordinaryRoute)
        clock.fireDeadlineTimerEarly()
        fixture.registry.executor.sync {}
        fixture.registry.executor.sync {}
        let rearmed = try XCTUnwrap(fixture.registry.playbackDeadlineScheduleSnapshot().ordinaryRoute)
        XCTAssertEqual(rearmed.armNonce, original.armNonce + 1,
            "生产早醒只能执行一次budget CAS；deliver在途不得递归reconcile并再次签票")
        await establishStableRoute(fixture, clock: clock)
        await play.value
        await fixture.controller.stop()
    }

    func testControllerHasOneFixedProgressSignalAndNoSleepPolling() throws {
        let fixture = try Task9RuntimeFixture()
        let signals = Mirror(reflecting: fixture.registry).children.filter {
            String(describing: type(of: $0.value)) == "PlaybackControlProgressSignal"
        }
        XCTAssertEqual(signals.count, 1, "单个pendingWake+单waiter信号必须归Registry runtime")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/VPlayerPlayback/Pipeline/PlaybackController.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Task.sleep"), "acquisition/route/SDK cleanup只能等待固定进展信号")
    }

    func testBlockedFactoryAutomaticallyFailsAtExactParentBoundaryAndRetainsOriginalRunner() async throws {
        try await checkBlockedStage(.factory)
    }
    func testBlockedPrepareAutomaticallyFailsAtExactParentBoundaryAndRetainsOriginalRunner() async throws {
        try await checkBlockedStage(.prepare)
    }
    func testBlockedBackendActivationAutomaticallyFailsWithoutAuthorizingSuccessor() async throws {
        try await checkBlockedStage(.activation)
    }
    func testBlockedSuspendAutomaticallyFailsAtExactOneSecondBoundaryWithoutSecondCleanup() async throws {
        try await checkBlockedStage(.suspend)
    }
    func testBlockedRetirementAutomaticallyFailsAtOriginalFiveSecondCleanupBoundary() async throws {
        try await checkBlockedStage(.retirement)
    }

    func testBlockedSDKActivationAutomaticallyFailsAtExactAcquisitionBoundaryAndKeepsPermit() async throws {
        let clock = ManualPlaybackClock(100)
        let fixture = try Task9RuntimeFixture(clock: clock)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "真实SDK activation已进入")
        fixture.sdk.lock.withLock { fixture.sdk.onActivate = { entered.fulfill(); gate.wait() } }
        let play = Task { await fixture.controller.play(fixture.request()) }
        await fulfillment(of: [entered], timeout: 2)
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let deadline = try XCTUnwrap(context.acquisitionDeadline)
        clock.set(deadline.anchorInstant + 5_000_000_000 - 1)
        fixture.registry.executor.sync {}
        await assertFailed(fixture.controller, expected: false)
        clock.advance(nanoseconds: 1)
        fixture.registry.executor.sync {}
        await settle { await self.failed(fixture.controller) }
        await assertFailed(fixture.controller, expected: true)
        XCTAssertNotNil(fixture.registry.cleanupReservationSnapshot())
        XCTAssertNotNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertEqual(fixture.factory.backends.count, 0)
        gate.signal()
        fixture.sdk.lock.withLock { fixture.sdk.onActivate = nil }
        await play.value
        await settle { fixture.registry.cleanupReservationSnapshot() == nil }
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot(), "迟到SDK completion必须自动接回原terminal owner")
        await fixture.controller.stop()
    }

    func testSystemIdentityExhaustionAutomaticallyStartsReservedTerminalOwner() async throws {
        try await checkExhaustion(callback: true)
        // 非callback的applyUserControl fail-closed必须使用同一原owner入口，而非play catch补丁。
        try await checkExhaustion(callback: true, userControl: true)
    }
    func testNonCallbackIdentityExhaustionUsesSameStickyWakeWithoutAnotherInput() async throws {
        try await checkExhaustion(callback: false)
    }

    func testRecoveryRunnerFailClosedUpgradesWithinOriginalTaskAndReleasesLease() async throws {
        let clock = ManualPlaybackClock(100)
        let gate = Task9OperationGate()
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1, initialNamespace: .systemEvent)
        let fixture = try Task9RuntimeFixture(factory: .init(retirementGate: gate), allocator: allocator, clock: clock)
        let play = Task { await fixture.controller.play(fixture.request()) }
        await establishStableRoute(fixture, clock: clock)
        await play.value
        fixture.owner.monitor.emit(.interruptionBegan)
        await settle { await gate.hasEntered }
        let entered = await gate.hasEntered
        XCTAssertTrue(entered)
        let original = try XCTUnwrap(task9OwnedRecords(fixture.registry).first {
            if case .controllerCleanup = $0.payload { return true }; return false
        })
        guard case .controllerCleanup(let runner) = original.payload else { return XCTFail("缺原runner") }
        let originalTask = runner.task
        fixture.owner.monitor.emit(.mediaServicesWereReset)
        await settle { await self.failed(fixture.controller) }
        await assertFailed(fixture.controller, expected: true)
        XCTAssertEqual(runner.task, originalTask, "fail-closed不能替换已运行的recovery Task")
        XCTAssertEqual(task9OwnedRecords(fixture.registry).filter {
            if case .controllerCleanup = $0.payload { return true }; return false
        }.count, 1)
        await gate.release()
        await settle { fixture.registry.cleanupReservationSnapshot() == nil }
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot(), "原recovery body须在同Task内继续terminal release")
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertEqual(fixture.factory.backends.first?.retirementEpochs.count, 1)
        XCTAssertLessThanOrEqual(fixture.factory.outputConcurrency.maximum, 1)
        await fixture.controller.stop()
    }

    func testAdmissionCASRejectsTailInstalledAfterJoinWithoutAllocatingAnotherIdentity() async throws {
        let clock = ManualPlaybackClock(100)
        let gate = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(clock: clock)
        let play = Task { await fixture.controller.play(fixture.request()) }
        await establishStableRoute(fixture, clock: clock)
        await play.value
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let oldSession = context.sessionIdentity
        await fixture.registry.joinAutomaticCleanupTailBeforeAdmission()
        let receiver = Task9OrphanCleanupReceiver(controller: fixture.controller, gate: gate)
        XCTAssertTrue(fixture.registry.cancelPlaybackRequest(oldSession))
        let owner = try XCTUnwrap(fixture.registry.beginOutputTransition(contextNonce: context.contextNonce,
            reason: .stop, anchorInstant: clock.nowNanoseconds, teardown: true))
        XCTAssertTrue(fixture.registry.startOwnedTerminalCleanup(owner: owner, receiver: receiver, terminalState: .stopped))
        await gate.waitUntilEntered()
        let entered = await gate.hasEntered
        XCTAssertTrue(entered)
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot(), "必须是真实资源CAS已清空的孤儿尾")
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot())
        XCTAssertEqual(fixture.registry.occupancy.groups, 0)
        let orphan = try XCTUnwrap(task9OwnedRecords(fixture.registry).first {
            if case .controllerCleanup = $0.payload { return true }; return false
        })
        XCTAssertTrue(task9ContainsTask(orphan.payload as Any), "receiver尚未返回，原Task仍由固定record持有")
        XCTAssertThrowsError(try fixture.registry.admitPlaybackRequest(requestID: UUID()),
            "孤儿tail必须在同Cell、分配新身份前拒绝admission")
        XCTAssertNil(fixture.registry.playbackRequestAdmissionSnapshot())
        await gate.release()
        await fixture.registry.joinAutomaticCleanupTailBeforeAdmission()
        XCTAssertFalse(task9OwnedRecords(fixture.registry).contains { $0.controlTaskTicket == orphan.controlTaskTicket })
        let admitted = try fixture.registry.admitPlaybackRequest(requestID: UUID())
        guard case .coldStart(let value) = admitted else { return XCTFail("缺准确admission") }
        XCTAssertEqual(value.identity.sessionIdentity.sessionID, oldSession.sessionID + 1,
            "被tail拒绝的尝试不能分配session/deadline身份")
        _ = fixture.registry.cancelPlaybackRequest(value.identity.sessionIdentity)
    }

    func testOwnerGroupRelayIsJoinedBeforeStopReleasesTheOriginalLease() async throws {
        let fixture = try Task9RuntimeFixture()
        await fixture.controller.play(fixture.request())
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let gate = Task9OperationGate()
        let ticket = try fixture.registry.enqueue(group: context.reservation.ownerGroup,
            slot: .systemEventRelay, policy: .safetyBypass)
        let relay = PlaybackSessionEventRelay(identity: .init(sessionID: context.sessionIdentity.sessionID,
            requestID: context.sessionIdentity.requestID)) { _, _ in await gate.enter() }
        XCTAssertTrue(fixture.registry.bindEventRelay(relay, to: ticket))
        relay.send(.ready(readinessCycle: 0))
        await gate.waitUntilEntered()
        let finished = Task9CompletionObservation()
        let stop = Task { await fixture.controller.stop(); finished.complete() }
        await settle {
            task9OwnedRecords(fixture.registry).contains {
                guard $0.controlTaskTicket == ticket, case .eventDrain(let runner) = $0.payload else { return false }
                return runner.joining
            }
        }
        XCTAssertFalse(finished.value, "同组relay的真实receiver未退出，stop不能归还lease")
        XCTAssertNotNil(fixture.registry.ownedResourceSnapshot())
        await gate.release()
        await stop.value
        XCTAssertFalse(task9OwnedRecords(fixture.registry).contains { $0.controlTaskTicket == ticket })
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot())
        XCTAssertEqual(fixture.registry.occupancy.groups, 0)
    }

    func testCleanupRejectsLateRelayBindingAcrossOwnerSiblingAndDescendantSlots() async throws {
        let suspension = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(suspensionGate: suspension))
        await fixture.controller.play(fixture.request())
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let registry = fixture.registry
        let sibling = try registry.createGroup(resource: .context(session: context.sessionIdentity, nonce: 901),
            parent: context.reservation.ownerGroup)
        let descendant = try registry.createGroup(resource: .context(session: context.sessionIdentity, nonce: 902), parent: sibling)
        let spare = try registry.createGroup(resource: .context(session: context.sessionIdentity, nonce: 903),
            parent: context.reservation.ownerGroup)
        let groups = [context.reservation.ownerGroup, sibling, descendant]
        let tickets = try groups.map { try registry.enqueue(group: $0, slot: .systemEventRelay, policy: .safetyBypass) }
        let gate = Task9OperationGate()
        let blocking = PlaybackSessionEventRelay(identity: .init(sessionID: context.sessionIdentity.sessionID,
            requestID: context.sessionIdentity.requestID)) { _, _ in await gate.enter() }
        // 最后一个槽的receiver阻塞，确保前两个未绑定槽已经被清理游标越过。
        XCTAssertTrue(registry.bindEventRelay(blocking, to: tickets[2]))
        blocking.send(.ready(readinessCycle: 0))
        await gate.waitUntilEntered()
        let pause = Task { await fixture.controller.setPaused(true) }
        await suspension.waitUntilEntered()
        let stop = Task { await fixture.controller.stop() }
        await settle { registry.outputResourceContextSnapshot()?.owner?.reason == .stop }
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.owner?.reason, .stop)
        // pause原调用尚未退出，cleanup已取得owner但relay游标尚未启动，组仍未被扫描封口。
        for ticket in tickets.prefix(2) {
            let late = PlaybackSessionEventRelay(identity: .init(sessionID: context.sessionIdentity.sessionID,
                requestID: context.sessionIdentity.requestID)) { _, _ in XCTFail("游标开始前也不能补绑") }
            XCTAssertFalse(registry.bindEventRelay(late, to: ticket))
        }
        XCTAssertThrowsError(try registry.enqueue(group: spare, slot: .accounting, policy: .routeNeutral),
            "空的兄弟组不能在cleanup owner产生之后新分配relay record")
        await suspension.release()
        await pause.value
        let joined = expectation(description: "cleanup游标进入原后代relay的真实join")
        let observation = Task {
            while !Task.isCancelled {
                if task9OwnedRecords(registry).contains(where: {
                    guard $0.controlTaskTicket == tickets[2], case .eventDrain(let runner) = $0.payload else { return false }
                    return runner.joining
                }) { joined.fulfill(); return }
                await Task.yield()
            }
        }
        await fulfillment(of: [joined], timeout: 2)
        observation.cancel()
        await observation.value
        XCTAssertTrue(task9OwnedRecords(registry).contains {
            guard $0.controlTaskTicket == tickets[2], case .eventDrain(let runner) = $0.payload else { return false }
            return runner.joining
        }, "真实游标必须已越过前面的未bind槽，并阻塞在后代receiver")
        XCTAssertEqual(registry.phase(of: tickets[0]), .terminal(.canceled),
            "未绑定的准确旧票必须被游标取消，仍属当前输出图时由原cleanup统一释放")
        for (group, ticket) in zip(groups, tickets) {
            let late = PlaybackSessionEventRelay(identity: .init(sessionID: context.sessionIdentity.sessionID,
                requestID: context.sessionIdentity.requestID)) { _, _ in XCTFail("已撤权的late relay不得运行") }
            XCTAssertFalse(registry.bindEventRelay(late, to: ticket), "准确旧票不得在游标后补绑/替换")
            XCTAssertThrowsError(try registry.enqueue(group: group, slot: .systemEventRelay, policy: .safetyBypass))
        }
        await gate.release()
        await stop.value
        XCTAssertNil(registry.ownedResourceSnapshot())
        XCTAssertNil(registry.cleanupReservationSnapshot())
        XCTAssertEqual(registry.occupancy.groups, 0)
    }

    func testSecondAdmissionExhaustionAutomaticallyCleansAlreadyAudibleOriginalOutput() async throws {
        let clock = ManualPlaybackClock(100)
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: .max - 1, initialNamespace: .session)
        let fixture = try Task9RuntimeFixture(allocator: allocator, clock: clock)
        let first = Task { await fixture.controller.play(fixture.request()) }
        await establishStableRoute(fixture, clock: clock)
        await first.value
        XCTAssertEqual(fixture.factory.outputConcurrency.current, 1)
        let backend = try XCTUnwrap(fixture.factory.backends.first)
        await fixture.controller.play(fixture.request())
        await assertFailed(fixture.controller, expected: true)
        await settle { fixture.registry.cleanupReservationSnapshot() == nil }
        XCTAssertEqual(backend.suspensionEpochs.count, 1, "admission分配失败不能仅发布failed而留下旧正rate输出")
        XCTAssertEqual(backend.retirementEpochs.count, 1)
        XCTAssertEqual(fixture.sdk.lock.withLock { fixture.sdk.deactivateCallCount }, 1)
        XCTAssertEqual(fixture.factory.outputConcurrency.current, 0)
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot())
        await fixture.controller.stop()
    }

    func testNewSessionInheritsPhysicalResumeVetoAndExplicitResumeUsesItsRealLease() async throws {
        let clock = ManualPlaybackClock(100)
        let fixture = try Task9RuntimeFixture(clock: clock)
        let first = Task { await fixture.controller.play(fixture.request()) }
        await establishStableRoute(fixture, clock: clock)
        await first.value
        fixture.owner.monitor.emit(.interruptionBegan)
        fixture.owner.monitor.emit(.interruptionEnded(shouldResume: false))
        await settle {
            if case .paused = await fixture.controller.currentStateForTesting { return true }; return false
        }
        let request = fixture.request()
        let next = Task { await fixture.controller.play(request) }
        await settle {
            guard let context = fixture.registry.outputResourceContextSnapshot(), context.sessionIdentity.requestID == request.id,
                  let source = context.sourceTask, let registration = fixture.registry.audioSessionRegistration(for: source)
            else { return false }
            return fixture.registry.acquisitionIsParkedForPhysicalResume(registration)
        }
        XCTAssertTrue(fixture.registry.executor.safetyIngress.snapshot.interruptionVeto)
        XCTAssertEqual(fixture.sdk.lock.withLock { fixture.sdk.activateCallCount }, 1,
            "新admission不得清除ended(false)的物理veto")
        let current = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        if current.sessionIdentity.requestID != request.id {
            let state = await fixture.controller.currentStateForTesting
            let records = task9OwnedRecords(fixture.registry).map {
                "\($0.slot):\($0.phase):task=\($0.controlTaskTicket.nonce):group=\($0.groupTicket.nonce):payload=\(String(describing: $0.payload))"
            }
            let diagnostic = XCTAttachment(string: "新lease尚未建立：state=\(state)；admission=\(String(describing: fixture.registry.playbackRequestAdmissionSnapshot()))；context=\(current)；records=\(records)")
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        XCTAssertEqual(current.sessionIdentity.requestID, request.id)
        XCTAssertNil(current.interruptionProof, "fresh acquisition不伪造已有输出的drain proof")
        let phase = try XCTUnwrap(fixture.registry.registeredAudioSessionPhase())
        XCTAssertEqual(phase.acquisitionOwnershipProof?.sessionIdentity, current.sessionIdentity)
        XCTAssertEqual(phase.acquisitionOwnershipProof?.contextNonce, current.contextNonce)
        XCTAssertNotNil(phase.configuredReceipt)
        let safety = fixture.registry.executor.safetyIngress.snapshot
        let callsBeforeWaitingResume = fixture.sdk.lock.withLock { fixture.sdk.calls }
        XCTAssertEqual(fixture.registry.performOutputUserControl(.init(kind: .resume,
            sessionIdentity: current.sessionIdentity, expectedOwner: current.owner, contextNonce: current.contextNonce,
            interruptionEpoch: safety.interruptionEpoch, mediaServicesEpoch: safety.mediaServicesEpoch,
            resetPreRouteBinding: current.resetPreRouteBinding)), .acceptedWaiting,
            "无lease/proof的普通resume只能登记等待，不能清除物理veto")
        XCTAssertTrue(fixture.registry.executor.safetyIngress.snapshot.interruptionVeto)
        XCTAssertTrue(try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()).userResumeRequested)
        XCTAssertEqual(fixture.sdk.lock.withLock { fixture.sdk.calls }, callsBeforeWaitingResume,
            "等待中的resume不能产生任何SDK副作用")
        await fixture.controller.setPaused(false)
        await settle { fixture.sdk.lock.withLock { fixture.sdk.activateCallCount == 2 } }
        XCTAssertEqual(fixture.sdk.lock.withLock { fixture.sdk.activateCallCount }, 2,
            "用户resume必须验证新lease的proof并进入真实SDK，不能只改门面标志")
        XCTAssertFalse(try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()).userResumeRequested,
            "真实lease/proof开始消费恢复后必须清除已登记意图")
        if fixture.sdk.lock.withLock({ fixture.sdk.activateCallCount == 2 }) {
            await establishStableRoute(fixture, clock: clock)
            // play会join原factory/prepare/activation runner；backend被追加本身不是activation完成证明。
            await next.value
        }
        XCTAssertEqual(fixture.factory.backends.count, 2)
        XCTAssertEqual(fixture.factory.backends.last?.activationCount, 1)
        XCTAssertEqual(fixture.factory.outputConcurrency.maximum, 1)
        // RED也准确取消当前admission，让测试本身不留下阻塞任务。
        await fixture.controller.stop()
        await next.value
    }

    private enum Stage { case factory, prepare, activation, suspend, retirement }

    private func checkBlockedStage(_ stage: Stage) async throws {
        let clock = ManualPlaybackClock(100)
        let gate = Task9OperationGate()
        let factory = Task9PreparedFactory(prepareGate: stage == .prepare ? gate : nil,
            retirementGate: stage == .retirement ? gate : nil,
            factoryGate: stage == .factory ? gate : nil,
            activationGate: stage == .activation ? gate : nil,
            suspensionGate: stage == .suspend ? gate : nil)
        let fixture = try Task9RuntimeFixture(factory: factory, clock: clock)
        let play = Task { await fixture.controller.play(fixture.request()) }
        await establishStableRoute(fixture, clock: clock)
        var cleanup: Task<Void, Never>?
        if stage == .suspend || stage == .retirement {
            await play.value
            cleanup = Task {
                if stage == .suspend { await fixture.controller.setPaused(true) }
                else { await fixture.controller.stop() }
            }
        }
        await settle { await gate.hasEntered }
        let entered = await gate.hasEntered
        XCTAssertTrue(entered, "先证明真实目标调用进入，再移动时钟")
        let context = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
        let reservation = context.reservation
        let boundary: UInt64
        switch stage {
        case .suspend: boundary = try XCTUnwrap(context.suspend).anchorInstant + 1_000_000_000
        case .retirement: boundary = try XCTUnwrap(context.budget).deadlineInstant
        default:
            let parent = try XCTUnwrap(context.parentDeadline)
            let value: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let p), .outputRecovery(let p): value = p }
            boundary = try XCTUnwrap(value.runningSince) + value.cap - value.accumulatedEffectiveTime
        }
        clock.set(boundary - 1)
        fixture.registry.executor.sync {}
        await assertFailed(fixture.controller, expected: false)
        clock.advance(nanoseconds: 1)
        fixture.registry.executor.sync {}
        await settle { await self.failed(fixture.controller) }
        await assertFailed(fixture.controller, expected: true)
        XCTAssertEqual(fixture.registry.cleanupReservationSnapshot()?.ticket, reservation)
        XCTAssertTrue(task9OwnedRecords(fixture.registry).contains { task9ContainsTask($0) }, "原Task尾不能到界时丢弃")
        XCTAssertLessThanOrEqual(task9OwnedRecords(fixture.registry).filter {
            if case .controllerCleanup = $0.payload { return true }; return false
        }.count, 1)
        await gate.release()
        await play.value
        await cleanup?.value
        await settle { fixture.registry.cleanupReservationSnapshot() == nil }
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot(), "原late completion须自动排空，无需stop补救")
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        let tails = task9OwnedRecords(fixture.registry).filter {
            if case .controllerCleanup = $0.payload { return true }; return false
        }
        XCTAssertLessThanOrEqual(tails.count, 1, "资源终态后仍诚实保留至多一个未join原Task尾")
        var groupCount = -1
        fixture.registry.executor.sync {
            let authority = Mirror(reflecting: fixture.registry).children.first { $0.label == "authority" }!.value
            let groups = Mirror(reflecting: authority).children.first { $0.label == "groups" }!.value
            groupCount = Mirror(reflecting: groups).children.filter { Mirror(reflecting: $0.value).children.count > 0 }.count
        }
        XCTAssertEqual(groupCount, 0, "释放业务group不等于伪造Task尾已退出")
        XCTAssertLessThanOrEqual(factory.outputConcurrency.maximum, 1)
        XCTAssertLessThanOrEqual(factory.backends.first?.retirementEpochs.count ?? 0, 1)
        if stage == .factory {
            let oldTickets = tails.map(\.controlTaskTicket)
            let next = Task { await fixture.controller.play(fixture.request()) }
            await establishStableRoute(fixture, clock: clock)
            await next.value
            XCTAssertFalse(task9OwnedRecords(fixture.registry).contains { oldTickets.contains($0.controlTaskTicket) },
                "后继准入之前必须join并移除无reservation的原tail，不能永久占槽")
        }
        await fixture.controller.stop()
    }

    private func checkExhaustion(callback: Bool, userControl: Bool = false) async throws {
        let clock = ManualPlaybackClock(100)
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: callback ? .max : .max - 1,
            initialNamespace: callback ? .systemEvent : .subscription)
        let gate = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(prepareGate: gate), allocator: allocator, clock: clock)
        let play = Task { await fixture.controller.play(fixture.request()) }
        await establishStableRoute(fixture, clock: clock)
        await settle { await gate.hasEntered }
        let entered = await gate.hasEntered
        XCTAssertTrue(entered)
        let original = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot())
        let stream = await fixture.controller.events()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertNotNil(initial)
        let observedFailure = Task9CompletionObservation()
        let observer = Task {
            while let event = await iterator.next() {
                if case .failed = event { observedFailure.complete(); return }
            }
        }
        if userControl {
            clock.set(0)
            await fixture.controller.setPaused(true)
        } else if callback { fixture.owner.monitor.emit(.interruptionBegan) }
        else {
            // 真实Registry非callback入口发生checked分配失败；不直接测试allocator私用路径。
            let rejected = fixture.registry.makeStateStream()
            withExtendedLifetime(rejected) {}
        }
        // 此后不发stop/resume，也不通过snapshot主动触发耗尽检查；只等原source与actor。
        await settle { observedFailure.value }
        XCTAssertTrue(observedFailure.value, "只能由真实公开stream观察failed，不能用getter替原source推进耗尽")
        observer.cancel()
        await observer.value
        if userControl { XCTAssertEqual(fixture.registry.executor.safetyIngress.snapshot.failure, .clockOverflow) }
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.owner?.identity, original.terminalOwner)
        XCTAssertEqual(fixture.registry.cleanupReservationSnapshot()?.ticket, original.ticket)
        await gate.release()
        await play.value
        await settle { fixture.registry.cleanupReservationSnapshot() == nil }
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot())
        XCTAssertNil(fixture.registry.ownedResourceSnapshot())
        XCTAssertEqual(fixture.factory.backends.first?.activationCount, 0)
        await fixture.controller.stop()
    }

    private func establishStableRoute(_ fixture: Task9RuntimeFixture, clock: ManualPlaybackClock) async {
        await waitForStabilityArm(fixture)
        fixture.registry.executor.sync {}
        clock.advance(nanoseconds: 120_000_000)
        fixture.registry.executor.sync {}
        await settle { fixture.registry.stableRouteCommitSnapshot() != nil }
        XCTAssertNotNil(fixture.registry.stableRouteCommitSnapshot())
    }

    private func waitForStabilityArm(_ fixture: Task9RuntimeFixture) async {
        // 等真实getter完成、原stability槽已arm；不重建latest、不注入任何receipt。
        await settle {
            var armed = false
            fixture.registry.executor.sync {
                let authority = Mirror(reflecting: fixture.registry).children.first { $0.label == "authority" }!.value
                let candidate = Mirror(reflecting: authority).children.first { $0.label == "routeStabilityCandidate" }!.value
                armed = self.containsStabilityTicket(candidate)
            }
            return armed
        }
    }

    private func containsStabilityTicket(_ value: Any) -> Bool {
        if value is RouteStabilityTicket { return true }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return false }
        return mirror.children.contains { containsStabilityTicket($0.value) }
    }
    private func failed(_ controller: PlaybackController) async -> Bool {
        if case .failed = await controller.currentStateForTesting { return true }; return false
    }
    private func assertFailed(_ controller: PlaybackController, expected: Bool,
        file: StaticString = #filePath, line: UInt = #line) async {
        let value = await failed(controller)
        XCTAssertEqual(value, expected, "公开failed必须在准确边界自动发布", file: file, line: line)
    }
    private func settle(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 { if await condition() { return }; await Task.yield() }
    }
}

final class Task9RuntimeOwnershipTests: XCTestCase {
    func testOldPrepareFailureCleanupCannotPublishIntoNewAdmittedContext() async throws {
        let retirement = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(retirementGate: retirement,
            firstPrepareFailure: .demuxOpen(-717)))
        let first = Task { await fixture.controller.play(fixture.request()) }
        await retirement.waitUntilEntered()
        let original = try XCTUnwrap(fixture.registry.cleanupReservationSnapshot()?.ticket)
        let activationEntered = expectation(description: "新session已建立真实acquisition并进入SDK")
        let activationGate = DispatchSemaphore(value: 0)
        fixture.sdk.lock.withLock {
            fixture.sdk.onActivate = { activationEntered.fulfill(); activationGate.wait() }
        }
        let request = fixture.request()
        let replacement = Task { await fixture.controller.play(request) }
        for _ in 0..<500 {
            if case .coldStart(let value) = fixture.registry.playbackRequestAdmissionSnapshot(),
               value.identity.sessionIdentity.requestID == request.id { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(fixture.registry.cleanupReservationSnapshot()?.ticket, original,
            "旧owned cleanup退出前新admission只能等，不能重建第二资源图")
        await retirement.release()
        await fulfillment(of: [activationEntered], timeout: 2)
        await first.value
        let state = await fixture.controller.currentStateForTesting
        XCTAssertEqual(state, .preparing(request), "旧prepare失败不能在await之后覆盖新请求的preparing")
        XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.sessionIdentity.requestID, request.id)
        XCTAssertNotEqual(fixture.registry.cleanupReservationSnapshot()?.ticket.ownerGroup, original.ownerGroup)
        XCTAssertEqual(fixture.factory.backends.count, 1, "新SDK返回前不允许factory后继")
        fixture.sdk.lock.withLock { fixture.sdk.onActivate = nil }
        activationGate.signal()
        await replacement.value
        XCTAssertEqual(fixture.factory.backends.count, 2)
        XCTAssertEqual(fixture.factory.backends.first?.retirementEpochs.count, 1)
        XCTAssertEqual(fixture.factory.backends.last?.activationCount, 1)
        XCTAssertEqual(fixture.factory.outputConcurrency.maximum, 1)
        await fixture.controller.stop()
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot())
    }

    func testInstalledPauseSuspensionIsHeldByOriginalRecordUntilExternalJoin() async throws {
        let gate = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(suspensionGate: gate))
        let request = fixture.request()
        await fixture.controller.play(request)
        let finished = PlaybackStreamRecorder<Bool>()
        let pause = Task { await fixture.controller.setPaused(true); finished.append(true) }
        await gate.waitUntilEntered()
        let stop = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.suspend)
        let record = try XCTUnwrap(task9OwnedRecords(fixture.registry).first { $0.controlTaskTicket == stop.task })
        XCTAssertTrue(task9ContainsTask(record.payload as Any), "暂停真实suspend必须在原record内持有Task")
        XCTAssertTrue(finished.snapshot.isEmpty)
        await gate.release()
        await pause.value
        let state = await fixture.controller.currentStateForTesting
        XCTAssertEqual(state, .paused(request))
        XCTAssertNil(fixture.registry.phase(of: stop.task), "外部join确认原Task退出后才能退休暂停record")
        XCTAssertEqual(fixture.factory.outputConcurrency.current, 0)
        await fixture.controller.stop()
    }

    func testPauseCancelsAndJoinsInflightActivationBeforeOneSuspension() async throws {
        let gate = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(activationGate: gate))
        let request = fixture.request()
        let play = Task { await fixture.controller.play(request) }
        await gate.waitUntilEntered()
        let activation = try XCTUnwrap(task9OwnedRecords(fixture.registry).first { $0.slot == .activation })
        let backend = try XCTUnwrap(fixture.factory.backends.first)
        let finished = PlaybackStreamRecorder<Bool>()
        let pause = Task { await fixture.controller.setPaused(true); finished.append(true) }
        for _ in 0..<500 {
            if fixture.registry.outputResourceContextSnapshot()?.owner?.reason == .pause { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(fixture.registry.phase(of: activation.controlTaskTicket), .cancelRequested,
            "pause先撤销原activation，但不得在真实调用返回前伪造terminal")
        XCTAssertTrue(backend.suspensionEpochs.isEmpty, "原activation返回前不能先suspend再被迟到activate反转")
        XCTAssertTrue(finished.snapshot.isEmpty)
        await gate.release()
        await play.value
        await pause.value
        XCTAssertEqual(backend.activationCount, 1)
        XCTAssertEqual(backend.suspensionEpochs.count, 1)
        XCTAssertEqual(fixture.factory.outputConcurrency.current, 0)
        XCTAssertEqual(fixture.factory.outputConcurrency.maximum, 1)
        let state = await fixture.controller.currentStateForTesting
        XCTAssertEqual(state, .paused(request))
        await fixture.controller.stop()
    }

    func testStopAndReplacementJoinTheOriginalPauseSuspensionTail() async throws {
        let gate = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(suspensionGate: gate))
        await fixture.controller.play(fixture.request())
        let pause = Task { await fixture.controller.setPaused(true) }
        await gate.waitUntilEntered()
        let original = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.suspend)
        let finished = PlaybackStreamRecorder<Bool>()
        let stop = Task { await fixture.controller.stop(); finished.append(true) }
        for _ in 0..<500 {
            if fixture.registry.outputResourceContextSnapshot()?.owner?.reason == .stop { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let request = fixture.request()
        let replacement = Task { await fixture.controller.play(request) }
        for _ in 0..<500 {
            if case .coldStart(let value) = fixture.registry.playbackRequestAdmissionSnapshot(),
               value.identity.sessionIdentity.requestID == request.id { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(finished.snapshot.isEmpty, "stop必须等待原pause实际退出")
        XCTAssertEqual(fixture.factory.backends.count, 1)
        XCTAssertTrue(task9OwnedRecords(fixture.registry).contains {
            $0.controlTaskTicket == original.task && task9ContainsTask($0.payload as Any)
        }, "换owner不可丢掉已经开始的原suspend尾部")
        await gate.release()
        await pause.value
        await stop.value
        await replacement.value
        if fixture.factory.backends.count != 2 {
            let state = await fixture.controller.currentStateForTesting
            let attachment = XCTAttachment(string: "暂停尾部后继诊断：state=\(state)；admission=\(String(describing: fixture.registry.playbackRequestAdmissionSnapshot()))；context=\(String(describing: fixture.registry.outputResourceContextSnapshot()))；reservation=\(String(describing: fixture.registry.cleanupReservationSnapshot()))；safety=\(fixture.registry.executor.safetyIngress.snapshot)")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(fixture.factory.backends.count, 2)
        XCTAssertEqual(fixture.factory.backends.first?.retirementEpochs.count, 1)
        XCTAssertEqual(fixture.factory.backends.last?.activationCount, 1)
        XCTAssertEqual(fixture.factory.outputConcurrency.maximum, 1)
        await fixture.controller.stop()
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot())
    }

    func testFactoryCanceledAfterRunnerInstallationBeforeClaimSettlesOriginalNoObject() async throws {
        let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "preclaim",
            streamURL: URL(string: "http://localhost/preclaim.m3u8")!, title: "调用前取消")
        let fixture = try StableOutputFixture(requestID: request.id)
        let registry = fixture.registry
        let context = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: context.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let ticket = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        let creation = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let identity = try XCTUnwrap(creation.candidateBackendIdentity)
        let kind = try XCTUnwrap(creation.desiredBackendKind)
        let factory = Task9PreparedFactory()
        let relay = PlaybackSessionEventRelay(identity: .init(sessionID: context.sessionIdentity.sessionID,
            requestID: request.id)) { _, _ in }
        let group = try registry.createGroup(resource: .backend(identity), parent: creation.reservation.workGroup)
        let drain = try registry.enqueue(group: group, slot: .accounting, policy: .routeNeutral)
        XCTAssertTrue(registry.bindEventRelay(relay, to: drain))
        // 原executor串行屏障保证Task已换手，但body尚不能claim；不加生产gate。
        registry.executor.sync {
            XCTAssertTrue(registry.startOutputFactoryOperation(ticket, input: .init(factory: factory,
                kind: kind, identity: identity, request: request, tuning: .default, relay: relay)))
            XCTAssertEqual(registry.phase(of: ticket), .queued)
            XCTAssertTrue(task9OwnedRecords(registry).contains {
                $0.controlTaskTicket == ticket && task9ContainsTask($0.payload as Any)
            })
            XCTAssertTrue(registry.requestCancel(ticket))
            XCTAssertNotNil(try? registry.beginOutputTransition(contextNonce: creation.contextNonce,
                reason: .stop, anchorInstant: registry.clock.nowNanoseconds, teardown: true))
        }
        let result = await registry.joinOutputBackendOperation(ticket)
        guard case .canceled = result else { return XCTFail("未调用的原操作只能结束为取消") }
        XCTAssertTrue(factory.backends.isEmpty, "取消先赢时不能调用factory或制造后端")
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.phase, .leaseOnlyCleanup,
            "原Task退出必须结清准确no-object，不得把lease卡在pendingCreation")
        XCTAssertNil(registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertEqual(try registry.retireOutputControlRecord(ticket), .retired(followUp: nil),
            "只有真实join之后才能归还原factory record")
    }

    func testInstalledControllerDoesNotRetainASecondResourceGraph() async throws {
        let fixture = try Task9RuntimeFixture()
        await fixture.controller.play(fixture.request())
        XCTAssertEqual(fixture.factory.backends.first?.activationCount, 1)
        XCTAssertEqual(task9BorrowedResourceCount(fixture.controller), 0,
            "后端、lease与relay只能由原Registry图持续强持；controller不得复制资源图")
        XCTAssertNotNil(fixture.registry.ownedResourceSnapshot())
        await fixture.controller.stop()
    }

    func testMonitorDispatchesThroughOnlyTheRegistryOwnedSystemRelay() async throws {
        let fixture = try Task9RuntimeFixture()
        await fixture.controller.play(fixture.request())
        let system = task9OwnedRecords(fixture.registry).filter { $0.slot == .systemEventRelay }
        XCTAssertEqual(system.count, 1)
        fixture.owner.monitor.emit(.interruptionBegan)
        for _ in 0..<500 {
            if await fixture.controller.audioSessionInterruptedForTesting { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let interrupted = await fixture.controller.audioSessionInterruptedForTesting
        XCTAssertTrue(interrupted)
        XCTAssertEqual(task9BorrowedResourceCount(fixture.controller), 0,
            "monitor callback不可借controller的relay/lease镜像选择接收者")
        await fixture.controller.stop()
    }

    func testFactoryRunnerRemainsOnItsRecordUntilLateResultAndStopJoin() async throws {
        try await assertOperationRunner(slot: .factory)
    }

    func testPrepareRunnerRemainsOnItsRecordUntilLateResultAndStopJoin() async throws {
        try await assertOperationRunner(slot: .prepare)
    }

    func testActivationRunnerRemainsOnItsRecordUntilLateResultAndStopJoin() async throws {
        try await assertOperationRunner(slot: .activation)
    }

    private func assertOperationRunner(slot: ControlTaskSlot) async throws {
        let gate = Task9OperationGate()
        let factory = Task9PreparedFactory(prepareGate: slot == .prepare ? gate : nil,
            factoryGate: slot == .factory ? gate : nil, activationGate: slot == .activation ? gate : nil)
        let fixture = try Task9RuntimeFixture(factory: factory)
        let first = Task { await fixture.controller.play(fixture.request()) }
        await gate.waitUntilEntered()
        let record = try XCTUnwrap(task9OwnedRecords(fixture.registry).first { $0.slot == slot && $0.phase == .running })
        XCTAssertTrue(task9ContainsTask(record.payload as Any), "真实异步操作的Task必须由准确原record持有")
        let stopped = PlaybackStreamRecorder<Bool>()
        let stop = Task { await fixture.controller.stop(); stopped.append(true) }
        for _ in 0..<500 {
            if fixture.registry.outputResourceContextSnapshot()?.owner?.reason == .stop { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let next = fixture.request()
        let replacement = Task { await fixture.controller.play(next) }
        for _ in 0..<500 {
            if case .coldStart(let admitted) = fixture.registry.playbackRequestAdmissionSnapshot(),
               admitted.identity.sessionIdentity.requestID == next.id { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(stopped.snapshot.isEmpty, "stop必须join原调用真实退出，不能提前归还前驱责任")
        let retained = try XCTUnwrap(task9OwnedRecords(fixture.registry).first { $0.controlTaskTicket == record.controlTaskTicket })
        XCTAssertTrue(task9ContainsTask(retained.payload as Any), "stop/new-play不能丢掉旧Task尾部")
        XCTAssertTrue(task9OwnedRecords(fixture.registry).contains {
            $0.slot == .committedCleanup && task9ContainsTask($0.payload as Any)
        }, "前驱cleanup也必须在既有committedCleanup槽")
        await gate.release()
        await first.value
        await stop.value
        await replacement.value
        XCTAssertEqual(factory.backends.count, 2)
        XCTAssertEqual(factory.backends.first?.retirementEpochs.count, 1)
        XCTAssertEqual(factory.backends.last?.activationCount, 1)
        XCTAssertEqual(factory.outputConcurrency.maximum, 1)
        await fixture.controller.stop()
        XCTAssertNil(fixture.registry.cleanupReservationSnapshot())
    }

    func testHandoffRetirementUsesTheOriginalCommittedCleanupRunner() async throws {
        let gate = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(retirementGate: gate))
        await fixture.controller.play(fixture.request())
        let handoff = Task { await fixture.controller.requestRouteHandoff(to: .hlsAVPlayer) }
        await gate.waitUntilEntered()
        XCTAssertTrue(task9OwnedRecords(fixture.registry).contains {
            $0.slot == .committedCleanup && task9ContainsTask($0.payload as Any)
        }, "handoff只能借原cleanup record，不能另存pendingTeardown")
        XCTAssertFalse(Mirror(reflecting: fixture.controller).children.contains { task9ContainsTask($0.value) },
            "controller不能私存cleanup/handoff Task handle")
        await gate.release()
        await handoff.value
        XCTAssertEqual(fixture.factory.outputConcurrency.maximum, 1)
        await fixture.controller.stop()
    }

    func testInvalidationDoesNotSpendOrFallbackTheLastSessionIdentity() async throws {
        let allocator = PlaybackIdentityAllocator(initialIssuedValue: UInt64.max - 1, initialNamespace: .session)
        let fixture = try Task9RuntimeFixture(allocator: allocator)
        await fixture.controller.play(fixture.request())
        XCTAssertFalse(allocator.isExhausted, "只有admission分配session，invalidate不得耗尽全局allocator")
        XCTAssertEqual(fixture.factory.backends.first?.activationCount, 1)
        await fixture.controller.stop()
        XCTAssertFalse(allocator.isExhausted, "stop只取消准确旧admission，不分配或fallback身份")
        XCTAssertNil(fixture.registry.playbackRequestAdmissionSnapshot())
    }
}

final class Task9PublicStreamOwnershipTests: XCTestCase {
    func testNewStateSubscriberFinishesThePreviousSubscriber() async throws {
        let fixture = try Task9RuntimeFixture()
        let first = await fixture.controller.events()
        let ended = expectation(description: "新state订阅同步结束旧订阅")
        let reader = Task { for await _ in first {}; ended.fulfill() }
        let current = await fixture.controller.events()
        await fulfillment(of: [ended], timeout: 1)
        reader.cancel()
        await reader.value
        var iterator = current.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .idle, "旧termination不能清掉新订阅")
    }

    func testNewMediaSubscriberFinishesThePreviousSubscriber() async throws {
        let fixture = try Task9RuntimeFixture()
        let first = await fixture.controller.playbackMediaInformation()
        let ended = expectation(description: "新media订阅同步结束旧订阅")
        let reader = Task { for await _ in first {}; ended.fulfill() }
        let current = await fixture.controller.playbackMediaInformation()
        await fulfillment(of: [ended], timeout: 1)
        reader.cancel()
        await reader.value
        var iterator = current.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertNotNil(initial as Any?, "旧termination不能结束新订阅")
    }

    func testStateStreamKeepsOnlyTheNewestValue() async throws {
        let fixture = try Task9RuntimeFixture()
        let request = fixture.request()
        await fixture.controller.play(request)
        let stream = await fixture.controller.events()
        await fixture.controller.setPaused(true)
        await fixture.controller.setPaused(false)
        await fixture.controller.setPaused(true)
        var iterator = stream.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest, .paused(request), "慢消费者只保留最新1项，不积压8项")
        await fixture.controller.stop()
    }

    func testMediaStreamKeepsOnlyTheNewestValue() async throws {
        let fixture = try Task9RuntimeFixture()
        let request = fixture.request()
        await fixture.controller.play(request)
        let stream = await fixture.controller.playbackMediaInformation()
        let backend = try XCTUnwrap(fixture.factory.backends.first)
        for width: Int32 in [640, 1280, 1920] {
            backend.emit(.mediaInformation(.init(width: width, height: 1080, scanMode: .progressive,
                sourceFrameRate: nil, outputFrameRate: nil, isSmoothMotionEnhanced: false)))
        }
        backend.emit(.ready(readinessCycle: 0))
        for _ in 0..<500 {
            if await fixture.controller.currentStateForTesting == .playing(request) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        var iterator = stream.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest??.width, 1920, "最新media覆盖旧nil及旧分辨率，容量严格为1")
        await fixture.controller.stop()
    }

    func testSubscriptionStormKeepsOnlyTwoRegistrySlotsAndRejectsStaleTermination() async throws {
        let fixture = try Task9RuntimeFixture()
        var oldState: AsyncStream<PlaybackState>?
        var oldMedia: AsyncStream<PlaybackMediaInformation?>?
        for _ in 0..<64 {
            oldState = await fixture.controller.events()
            oldMedia = await fixture.controller.playbackMediaInformation()
        }
        let currentState = await fixture.controller.events()
        let currentMedia = await fixture.controller.playbackMediaInformation()
        let staleState = try XCTUnwrap(oldState)
        let staleMedia = try XCTUnwrap(oldMedia)
        let cancelState = Task { for await _ in staleState {} }
        let cancelMedia = Task { for await _ in staleMedia {} }
        cancelState.cancel()
        cancelMedia.cancel()
        await cancelState.value
        await cancelMedia.value
        oldState = nil
        oldMedia = nil
        var stateSlots = 0
        var mediaSlots = 0
        fixture.registry.executor.sync {
            let authority = Mirror(reflecting: fixture.registry).children.first { $0.label == "authority" }!.value
            func count(_ value: Any, depth: Int = 0) {
                if value is AsyncStream<PlaybackState>.Continuation { stateSlots += 1; return }
                if value is AsyncStream<PlaybackMediaInformation?>.Continuation { mediaSlots += 1; return }
                let mirror = Mirror(reflecting: value)
                guard depth < 3, depth == 0 || mirror.displayStyle != .class,
                      mirror.displayStyle != .collection, mirror.displayStyle != .dictionary else { return }
                for child in mirror.children { count(child.value, depth: depth + 1) }
            }
            count(authority)
        }
        XCTAssertEqual(stateSlots, 1, "state只有Registry一个固定continuation槽，旧token不得清新槽")
        XCTAssertEqual(mediaSlots, 1, "media只有Registry一个固定continuation槽")
        XCTAssertFalse(Mirror(reflecting: fixture.controller).children.contains {
            Mirror(reflecting: $0.value).displayStyle == .dictionary
        }, "取消风暴不能留controller订阅字典")
        var state = currentState.makeAsyncIterator()
        var media = currentMedia.makeAsyncIterator()
        let initial = await state.next()
        XCTAssertEqual(initial, .idle)
        let information = await media.next()
        XCTAssertNotNil(information as Any?)
    }
}

/// Task9最终运行时容量门禁：五个局部ledger互斥计费，并在全局96KiB只按allocation identity求和一次。
/// Task/Block无法稳定取得公开allocation identity，使用具名保守slab；不把编译器瞬时栈或框架opaque内存伪装进账。
final class Task9RuntimeCapacityTests: XCTestCase {
    private let ownedCap = 64 * 1_024
    private let audioRelayCap = 16 * 1_024
    private let systemAndPipelineCap = 4 * 1_024
    private let routeCap = 4 * 1_024
    private let presentationCap = 2 * 1_024
    private let globalCap = 96 * 1_024

    func testProductionRuntimeUsesFiveDisjointAllocationLedgersAndFitsGlobalCap() throws {
        let fixture = try Task9RuntimeFixture()
        let run = PlaybackRunIdentity(sessionID: 1, requestID: UUID())
        let pipeline = PlaybackSessionEventRelay(identity: run) { _, _ in }
        let audio = PlaybackAudioSessionEventRelay(identity: run,
            lease: .init(id: 1, generation: 1)) { _, _, _, _ in }
        let service = try XCTUnwrap(task9ObjectField("routeService", of: fixture.controller,
            as: PlaybackAudioRouteService.self))
        let presentationRelay = try XCTUnwrap(task9ObjectField("presentationRelay", of: fixture.controller,
            as: PlaybackPresentationRelay.self))
        let presentationLock = try XCTUnwrap(task9ObjectField("lock", of: presentationRelay,
            as: NSLock.self))
        let presentationStream = try presentationRelay.presentations()
        defer {
            presentationRelay.finish()
            withExtendedLifetime(presentationStream) {}
        }
        let charges = try [
            task9ObjectCharge(fixture.registry, ledger: .ownedControl, name: "Registry"),
            task9ObjectCharge(fixture.controller, ledger: .ownedControl, name: "Controller"),
            task9ObjectCharge(fixture.registry.progressSignal, ledger: .ownedControl, name: "ProgressSignal"),
            task9ObjectCharge(audio, ledger: .audioRelay, name: "AudioRelay"),
            task9ArrayCharge(XCTUnwrap(task9ArrayField("pending", of: audio)),
                ledger: .audioRelay, name: "AudioRelay.pending"),
            task9ObjectCharge(fixture.owner.monitor, ledger: .systemAndPipelineRelay, name: "SystemMonitor"),
            task9ObjectCharge(pipeline, ledger: .systemAndPipelineRelay, name: "PipelineRelay"),
            task9ArrayCharge(XCTUnwrap(task9ArrayField("pending", of: pipeline)),
                ledger: .systemAndPipelineRelay, name: "PipelineRelay.pending"),
            task9ObjectCharge(service, ledger: .route, name: "RouteService"),
            task9ObjectCharge(presentationRelay, ledger: .presentation, name: "PresentationRelay"),
            task9ObjectCharge(presentationLock, ledger: .presentation, name: "PresentationRelay.lock")
        ]
        let grouped = Dictionary(grouping: charges, by: \.ledger).mapValues { rows in
            Dictionary(grouping: rows, by: \.allocationIdentity).values.reduce(0) { total, aliases in
                total + (aliases.map(\.bytes).max() ?? 0)
            }
        }
        XCTAssertEqual(Set(grouped.keys), Set(Task9AllocationCharge.Ledger.allCases))
        XCTAssertEqual(ControlTaskRegistry.controlAllocationReservation.total,
            ControlTaskRegistry.ownedControlAllocationReservation.total, "兼容API必须alias同一本owned账")
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.ownedControl.total, ownedCap)
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.audioRelay.total, audioRelayCap)
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.total,
            systemAndPipelineCap)
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.route.total, routeCap)
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.presentation.total,
            presentationCap)
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.globalReachablePeak, globalCap)
        let ledgerAttachment = XCTAttachment(string: """
            owned=\(PlaybackRuntimeAllocationReservations.ownedControl.total)
            audio=\(PlaybackRuntimeAllocationReservations.audioRelay.total)
            system+pipeline=\(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.total)
            route=\(PlaybackRuntimeAllocationReservations.route.total)
            presentation=\(PlaybackRuntimeAllocationReservations.presentation.total)
            global=\(PlaybackRuntimeAllocationReservations.globalReachablePeak)
            """)
        ledgerAttachment.lifetime = .keepAlways
        add(ledgerAttachment)
        XCTAssertLessThanOrEqual(grouped[.audioRelay] ?? .max,
            PlaybackRuntimeAllocationReservations.audioRelay.total)
        XCTAssertLessThanOrEqual(grouped[.systemAndPipelineRelay] ?? .max,
            PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.total)
        XCTAssertLessThanOrEqual(grouped[.route] ?? .max,
            PlaybackRuntimeAllocationReservations.route.total)
        XCTAssertLessThanOrEqual(grouped[.presentation] ?? .max,
            PlaybackRuntimeAllocationReservations.presentation.total)
        let crossLedgerAliases = Dictionary(grouping: charges, by: \.allocationIdentity).values.filter {
            Set($0.map(\.ledger)).count > 1
        }
        XCTAssertTrue(crossLedgerAliases.isEmpty, "同一allocation identity不得跨ledger重复计费")
    }

    func testProductionObjectsAndFixedBackingsMatchSameTargetAllocationClasses() throws {
        let fixture = try Task9RuntimeFixture()
        let scheduler = try XCTUnwrap(task9ObjectField("deadlineScheduler", of: fixture.controller,
            as: PlaybackDeadlineScheduler.self))
        let authority = try XCTUnwrap(task9AnyObjectField("authority", of: fixture.registry))
        let lane = try XCTUnwrap(task9AnyObjectField("lane", of: fixture.owner))
        let run = PlaybackRunIdentity(sessionID: 2, requestID: UUID())
        let pipeline = PlaybackSessionEventRelay(identity: run) { _, _ in }
        let audio = PlaybackAudioSessionEventRelay(identity: run,
            lease: .init(id: 2, generation: 2)) { _, _, _, _ in }
        let objects: [(String, AnyObject)] = [
            ("registry", fixture.registry), ("authority", authority), ("executor", fixture.registry.executor),
            ("cell", fixture.registry.executor.safetyIngress), ("controller", fixture.controller),
            ("owner", fixture.owner), ("lane", lane), ("scheduler", scheduler),
            ("progressSignal", fixture.registry.progressSignal), ("pipelineRelay", pipeline), ("audioRelay", audio),
            ("monitor", fixture.owner.monitor)
        ]
        var rows: [String] = []
        for (name, object) in objects {
            let instance = class_getInstanceSize(type(of: object))
            let actual = malloc_size(Unmanaged.passUnretained(object).toOpaque())
            rows.append("\(name): instance=\(instance), good=\(malloc_good_size(instance)), actual=\(actual)")
            XCTAssertEqual(actual, malloc_good_size(instance), "\(name)必须使用本目标实测allocation class")
        }
        let arrays = try [
            ("commands", XCTUnwrap(task9ArraySnapshot("commands", of: authority)), 32),
            ("groups", XCTUnwrap(task9ArraySnapshot("groups", of: authority)), 32),
            ("pipeline.pending", XCTUnwrap(task9ArraySnapshot("pending", of: pipeline)), 32),
            ("audio.pending", XCTUnwrap(task9ArraySnapshot("pending", of: audio)), 32)
        ]
        for (name, array, expectedCount) in arrays {
            rows.append("\(name): count=\(array.count), capacity=\(array.capacity), stride=\(array.stride), tailClass=\(array.bytes)")
            XCTAssertEqual(array.count, expectedCount)
            XCTAssertGreaterThanOrEqual(array.capacity, expectedCount,
                "公开capacity是本目标allocator事实，不能用count替代")
            XCTAssertEqual(array.bytes, malloc_good_size(32 + array.capacity * array.stride))
            if name == "commands" {
                XCTAssertEqual(ControlTaskRegistry.commandBackingCapacity, array.count)
                XCTAssertEqual(ControlTaskRegistry.controlAllocationReservation.commandBacking, array.bytes,
                    "command逻辑请求须落入本目标真实allocation class")
            } else if name == "groups" {
                XCTAssertEqual(ControlTaskRegistry.groupBackingCapacity, array.count)
                XCTAssertEqual(ControlTaskRegistry.controlAllocationReservation.groupBacking, array.bytes,
                    "group逻辑请求须落入本目标真实allocation class")
            } else if name == "pipeline.pending" {
                XCTAssertEqual(PlaybackSessionEventRelay.fixedBackingCapacity, array.count)
                XCTAssertEqual(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.pipelineBacking,
                    array.bytes)
            } else if name == "audio.pending" {
                XCTAssertEqual(PlaybackAudioSessionEventRelay.fixedBackingCapacity, array.count)
                XCTAssertEqual(PlaybackRuntimeAllocationReservations.audioRelay.fixedBacking, array.bytes)
            }
        }
        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        add(attachment)
        let ownedObjects = objects.prefix(9).reduce(0) {
            $0 + malloc_size(Unmanaged.passUnretained($1.1).toOpaque())
        }
        XCTAssertGreaterThanOrEqual(PlaybackRuntimeAllocationReservations.ownedControl.fixedObjectAllocationCharges,
            ownedObjects)
        XCTAssertGreaterThanOrEqual(PlaybackRuntimeAllocationReservations.audioRelay.fixedObjectAllocationCharges,
            task9ObjectCharge(audio, ledger: .audioRelay, name: "audio").bytes)
        XCTAssertGreaterThanOrEqual(
            PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.fixedObjectAllocationCharges,
            task9ObjectCharge(pipeline, ledger: .systemAndPipelineRelay, name: "pipeline").bytes +
                task9ObjectCharge(fixture.owner.monitor, ledger: .systemAndPipelineRelay, name: "monitor").bytes)
    }

    func testTaskFramesCapturesContinuationsAndOldTailsFitReachablePeak() async throws {
        let gate = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(retirementGate: gate))
        await fixture.controller.play(fixture.request())
        let stopped = Task { await fixture.controller.stop() }
        await gate.waitUntilEntered()
        var cleanup = task9OwnedRecords(fixture.registry).first { record in
            if case .controllerCleanup = record.payload { return true }
            return false
        }
        var runner: OwnedPlaybackCleanupTask?
        if case .controllerCleanup(let value) = cleanup?.payload { runner = value }
        let cleanupTicket = cleanup?.controlTaskTicket
        weak let releasedRunner = runner
        let taskWasRetained = runner?.task != nil
        cleanup = nil
        await gate.release()
        await stopped.value
        XCTAssertTrue(taskWasRetained, "原cleanup Task frame须留在准确record直到外部join")
        XCTAssertFalse(task9OwnedRecords(fixture.registry).contains { $0.controlTaskTicket == cleanupTicket },
            "外部join后Registry必须释放原runner record")
        runner = nil
        await settle { releasedRunner == nil }
        XCTAssertNil(releasedRunner, "测试不再借用后，原runner与已完成Task尾必须一起释放")

        let conservativeReservations: [(String, Int)] = [
            ("controller-operation-task-slab", 512),
            ("cleanup-task-slab-and-old-tail-overlap", 2 * 512),
            ("pipeline-relay-previous-next-task-slabs", 2 * 512),
            ("audio-relay-previous-next-task-slabs", 2 * 512),
            ("escaping-Task-captures-and-Blocks", 12 * 80),
            ("four-simultaneous-checked-continuations", 4 * 256)
        ]
        let attachment = XCTAttachment(string: conservativeReservations.map { "\($0.0)=\($0.1)" }.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        add(attachment)
        let allocation = PlaybackRuntimeAllocationReservations.ownedControl
        XCTAssertGreaterThanOrEqual(allocation.taskSlabs, conservativeReservations[0...1].reduce(0) { $0 + $1.1 })
        XCTAssertGreaterThanOrEqual(allocation.escapingCaptures, conservativeReservations[4].1 / 2)
        XCTAssertGreaterThanOrEqual(allocation.continuations, conservativeReservations[5].1)
        XCTAssertGreaterThan(allocation.overlappingOldTails, 0)
    }

    func testThirtyFourProducerReservationCoversEveryExternalExecutorEntrant() throws {
        let mapping = PlaybackRuntimeAllocationReservations.ownedControl.externalProducerAssignments
        let owned = (0..<32).compactMap { mapping.assignment(for: .ownedRunner($0))?.slot }
        let lane = try XCTUnwrap(mapping.assignment(for: .audioSessionLaneCompletion))
        let user = try XCTUnwrap(mapping.assignment(for: .serializedUserControl))
        let reserved = owned + [lane.slot, user.slot]
        XCTAssertEqual(reserved.count, PlaybackExternalSyncProducerReservation.slotCount)
        XCTAssertEqual(Set(reserved).count, PlaybackExternalSyncProducerReservation.slotCount)
        XCTAssertEqual(reserved.map(\.index).sorted(), Array(0..<34))
        XCTAssertEqual(ControlTaskRegistry.controlAllocationReservation.externalSyncReservation,
            PlaybackExternalSyncProducerReservation.slotCount *
                (PlaybackExternalSyncProducerReservation.environmentBytes + PlaybackExternalSyncProducerReservation.blockBytes))
        let deinitialization = try XCTUnwrap(mapping.assignment(for: .registryDeinitialization))
        XCTAssertNil(mapping.assignment(for: .stateTermination))
        XCTAssertNil(mapping.assignment(for: .mediaTermination))
        XCTAssertNil(mapping.assignment(for: .audioPipelineRouteResample))
        XCTAssertEqual(mapping.coverage(for: .stateTermination),
            .fixedLedgerCharge(.ownedStateTerminationSyncBridge))
        XCTAssertEqual(mapping.coverage(for: .mediaTermination),
            .fixedLedgerCharge(.ownedMediaTerminationSyncBridge))
        XCTAssertEqual(mapping.coverage(for: .audioPipelineRouteResample),
            .fixedLedgerCharge(.routeResampleSyncBridge))
        XCTAssertEqual(deinitialization, .init(slot: user.slot, proof: .requiresRuntimeUnreachable))
        XCTAssertNil(mapping.assignment(for: .ownedRunner(32)), "不得生成第35个或越界owned producer")
        let attachment = XCTAttachment(string: reserved.map { "producer-slot=\($0.index)" }.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSevenWeakTargetsReleaseAtTheirExactJoinOrTimerBoundary() async throws {
        let weakTargets = try await makeReleasedWeakTargets()
        await settle { weakTargets.allReleased }
        XCTAssertNil(weakTargets.cleanupRunner, "cleanup runner只可活到准确外部join")
        XCTAssertNil(weakTargets.controller)
        XCTAssertNil(weakTargets.registry)
        XCTAssertNil(weakTargets.executor)
        XCTAssertNil(weakTargets.scheduler)
        XCTAssertNil(weakTargets.monitor, "observer退订后system monitor不得有callback尾")
        XCTAssertNil(weakTargets.routeService, "timer清handler并cancel后route service不得有尾")
        XCTAssertEqual(ControlTaskRegistry.controlAllocationReservation.weakSideTables, 5 * 32,
            "owned栏须计executor/scheduler/Registry/controller/cleanup runner五个唯一target")
        XCTAssertEqual(SystemAudioEventMonitor.weakTargetAllocationCharges, 32)
        XCTAssertEqual(PlaybackAudioRouteService.routeAllocationReservation.weakTargetAllocationCharges, 32)
    }

    func testParkedProgressWaiterDoesNotRetainRuntimePastItsOriginalDeadline() async throws {
        let weakTargets = try await makeTimedOutAcquisitionWeakTargets()
        await settle { weakTargets.controller == nil && weakTargets.registry == nil && weakTargets.executor == nil }
        XCTAssertNil(weakTargets.controller, "原acquisition deadline结算后parked play continuation不得持有controller")
        XCTAssertNil(weakTargets.registry, "signal移走continuation后Task尾不得形成Registry环")
        XCTAssertNil(weakTargets.executor)
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.ownedControl.progressWaiterTaskSlab, 0)
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.ownedControl.progressWaiterCapture, 0)
    }

    func testRelayGenerationOverlapKeepsFixedBackingsAndReleasesOldRunners() async throws {
        let retirement = Task9OperationGate()
        let fixture = try Task9RuntimeFixture(factory: .init(retirementGate: retirement))
        await fixture.controller.play(fixture.request())
        var oldPipeline = pipelineRelay(in: fixture.registry)
        var oldRunner = pipelineDrain(in: fixture.registry)
        let oldIdentity = try XCTUnwrap(oldPipeline.flatMap { task9ArraySnapshot("pending", of: $0) }).identity
        weak let releasedRunner = oldRunner
        let handoff = Task { await fixture.controller.requestRouteHandoff(to: .hlsAVPlayer) }
        await retirement.waitUntilEntered()
        XCTAssertEqual(task9ArraySnapshot("pending", of: try XCTUnwrap(oldPipeline))?.identity,
            oldIdentity, "handoff期间原32槽ring不得COW/扩容")
        await retirement.release()
        await handoff.value
        let nextPipeline = try XCTUnwrap(pipelineRelay(in: fixture.registry))
        let nextBacking = try XCTUnwrap(task9ArraySnapshot("pending", of: nextPipeline))
        XCTAssertEqual(nextBacking.count, 32)
        XCTAssertGreaterThanOrEqual(nextBacking.capacity, 32)
        XCTAssertNotEqual(nextBacking.identity, oldIdentity,
            "新generation拥有自己的固定ring，不能别名已退休旧背板")
        oldPipeline = nil
        oldRunner = nil
        await settle { releasedRunner == nil }
        XCTAssertNil(releasedRunner, "原relay runner外部join后必须释放原Task尾；测试factory可继续留backend/sink")
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.relayTaskSlabs, 0)
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.relayOldTailOverlap, 0)
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.audioRelay.relayTaskSlabs, 0)
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.audioRelay.relayOldTailOverlap, 0)
        await fixture.controller.stop()
    }

    func testOneSchedulerAndOneRouteTimerRemainFixedAcrossPlayStopHandoffAndRebind() async throws {
        let fixture = try Task9RuntimeFixture()
        let scheduler = try XCTUnwrap(task9ObjectField("deadlineScheduler", of: fixture.controller,
            as: PlaybackDeadlineScheduler.self))
        let service = try XCTUnwrap(task9ObjectField("routeService", of: fixture.controller,
            as: PlaybackAudioRouteService.self))
        let schedulerTimer = try XCTUnwrap(task9AnyObjectField("timer", of: scheduler))
        let routeTimer = try XCTUnwrap(task9AnyObjectField("timer", of: service))
        let identities = [ObjectIdentifier(scheduler), ObjectIdentifier(schedulerTimer),
            ObjectIdentifier(service), ObjectIdentifier(routeTimer)]
        await fixture.controller.play(fixture.request())
        await fixture.controller.requestRouteHandoff(to: .hlsAVPlayer)
        await fixture.controller.stop()
        await fixture.controller.play(fixture.request())
        let currentScheduler = try XCTUnwrap(task9ObjectField("deadlineScheduler", of: fixture.controller,
            as: PlaybackDeadlineScheduler.self))
        let currentService = try XCTUnwrap(task9ObjectField("routeService", of: fixture.controller,
            as: PlaybackAudioRouteService.self))
        let current = [ObjectIdentifier(currentScheduler),
            ObjectIdentifier(try XCTUnwrap(task9AnyObjectField("timer", of: currentScheduler))),
            ObjectIdentifier(currentService),
            ObjectIdentifier(try XCTUnwrap(task9AnyObjectField("timer", of: currentService)))]
        XCTAssertEqual(current, identities, "play/stop/handoff/rebind不得新建scheduler或route timer/source/handler")
        XCTAssertGreaterThan(
            PlaybackRuntimeAllocationReservations.route.timerSourceAndPermanentHandlerAllocationCharges, 0)
        await fixture.controller.stop()
    }

    func testStateAndMediaReplacementKeepOnlyCurrentRegistryOwnedStorage() async throws {
        let fixture = try Task9RuntimeFixture()
        var stateStreams: [AsyncStream<PlaybackState>] = []
        var mediaStreams: [AsyncStream<PlaybackMediaInformation?>] = []
        for _ in 0..<32 {
            stateStreams.append(await fixture.controller.events())
            mediaStreams.append(await fixture.controller.playbackMediaInformation())
        }
        var stateSlots = 0
        var mediaSlots = 0
        fixture.registry.executor.sync {
            guard let authority = task9Field("authority", of: fixture.registry) else { return }
            func count(_ value: Any, depth: Int = 0) {
                if value is AsyncStream<PlaybackState>.Continuation { stateSlots += 1; return }
                if value is AsyncStream<PlaybackMediaInformation?>.Continuation { mediaSlots += 1; return }
                let mirror = Mirror(reflecting: value)
                guard depth < 4, depth == 0 || mirror.displayStyle != .class,
                      mirror.displayStyle != .collection, mirror.displayStyle != .dictionary else { return }
                for child in mirror.children { count(child.value, depth: depth + 1) }
            }
            count(authority)
        }
        XCTAssertEqual(stateSlots, 1, "替换后Registry只持当前state continuation")
        XCTAssertEqual(mediaSlots, 1, "替换后Registry只持当前media continuation")
        XCTAssertEqual(stateStreams.count, 32)
        XCTAssertEqual(mediaStreams.count, 32)
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.ownedControl.stateSubscriptionStorage, 0)
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.ownedControl.mediaSubscriptionStorage, 0)
    }

    func testReviewExternalSyncBridgesAreIndependentFromTheThirtyFourBaseSlots() throws {
        let owned = PlaybackRuntimeAllocationReservations.ownedControl
        let route = PlaybackRuntimeAllocationReservations.route
        let mapping = owned.externalProducerAssignments
        let baseBytes = PlaybackExternalSyncProducerReservation.slotCount *
            (PlaybackExternalSyncProducerReservation.environmentBytes +
                PlaybackExternalSyncProducerReservation.blockBytes)

        XCTAssertNil(mapping.assignment(for: .stateTermination),
            "state onTermination可与base34同时等待executor，不能伪装复用用户槽")
        XCTAssertNil(mapping.assignment(for: .mediaTermination),
            "media onTermination可与base34同时等待executor，不能伪装复用用户槽")
        XCTAssertNil(mapping.assignment(for: .audioPipelineRouteResample),
            "route resample可与全部owned runner同时等待executor，不能伪装复用runner31")
        XCTAssertEqual(owned.externalProducerAssignments.total, baseBytes,
            "类型化base表必须仍然只有32 runner、lane和user共34槽")
        XCTAssertEqual(owned.externalSyncReservation, baseBytes,
            "base34不得吸收三个可同时存在的额外bridge")
        XCTAssertEqual(owned.stateContinuationStorage, 256)
        XCTAssertEqual(owned.mediaContinuationStorage, 256)
        XCTAssertEqual(owned.stateTerminationSyncBridge, 80)
        XCTAssertEqual(owned.mediaTerminationSyncBridge, 80)
        XCTAssertEqual(owned.stateSubscriptionStorage, 336,
            "state完整continuation与termination bridge须同时保守计费")
        XCTAssertEqual(owned.mediaSubscriptionStorage, 336,
            "media完整continuation与termination bridge须同时保守计费")
        XCTAssertEqual(route.resampleSyncBridge, 80)
        XCTAssertEqual(route.subscriberAdapterCapture, 80,
            "route subscriber与resample bridge必须为两份独立charge")
    }

    func testReviewMonitorForwardsDirectlyAfterReplacingTestObserverAndAccountsRealTokens() async throws {
        let fixture = try Task9RuntimeFixture()
        await fixture.controller.play(fixture.request())
        let relay = try XCTUnwrap(audioRelay(in: fixture.registry), "真实play必须安装audio event relay")
        let observed = PlaybackStreamRecorder<PlaybackAudioSessionEventEnvelope>()
        fixture.owner.monitor.setEventHandler { observed.append($0) }

        var queuedKeys = -1
        fixture.registry.executor.sync {
            _ = fixture.owner.monitor.emit(.interruptionBegan)
            let slots = task9Field("pending", of: relay) as? [PlaybackAudioSessionEventKey?]
            queuedKeys = slots?.compactMap { $0 }.count ?? -1
        }
        XCTAssertEqual(observed.snapshot.count, 1, "测试observer仍须收到一次真实事件")
        XCTAssertEqual(queuedKeys, 1,
            "替换测试observer不能切断monitor到Registry的生产转发；生产不能依赖该长期closure")

        let interruptionToken = try XCTUnwrap(task9AnyObjectField("interruptionObserver",
            of: fixture.owner.monitor), "start后须持有真实interruption token")
        let resetToken = try XCTUnwrap(task9AnyObjectField("resetObserver",
            of: fixture.owner.monitor), "start后须持有真实reset token")
        let tokenBytes = malloc_size(Unmanaged.passUnretained(interruptionToken).toOpaque()) +
            malloc_size(Unmanaged.passUnretained(resetToken).toOpaque())
        XCTAssertGreaterThanOrEqual(PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.observerTokens,
            tokenBytes, "framework私有token须覆盖当前真实class，并保留跨tvOS runtime保守上界")
        await fixture.controller.stop()
    }

    func testReviewFixedRingsReserveLogicalRequestClassWithoutStrictRuntimeCapacity() throws {
        let fixture = try Task9RuntimeFixture()
        let authority = try XCTUnwrap(task9AnyObjectField("authority", of: fixture.registry))
        let identity = PlaybackRunIdentity(sessionID: 91, requestID: UUID())
        let pipeline = PlaybackSessionEventRelay(identity: identity) { _, _ in }
        let audio = PlaybackAudioSessionEventRelay(identity: identity,
            lease: .init(id: 91, generation: 91)) { _, _, _, _ in }
        let observations = try [
            ("commands", XCTUnwrap(task9ArraySnapshot("commands", of: authority)),
                ControlTaskRegistry.controlAllocationReservation.commandBacking,
                ControlTaskRegistry.commandBackingCapacity),
            ("groups", XCTUnwrap(task9ArraySnapshot("groups", of: authority)),
                ControlTaskRegistry.controlAllocationReservation.groupBacking,
                ControlTaskRegistry.groupBackingCapacity),
            ("pipeline", XCTUnwrap(task9ArraySnapshot("pending", of: pipeline)),
                PlaybackRuntimeAllocationReservations.systemAndPipelineRelay.pipelineBacking,
                PlaybackSessionEventRelay.fixedBackingCapacity),
            ("audio", XCTUnwrap(task9ArraySnapshot("pending", of: audio)),
                PlaybackRuntimeAllocationReservations.audioRelay.fixedBacking,
                PlaybackAudioSessionEventRelay.fixedBackingCapacity)
        ]
        for (name, actual, reservedBytes, policyCount) in observations {
            XCTAssertEqual(actual.count, 32)
            XCTAssertEqual(policyCount, actual.count,
                "\(name)的类型化reservation策略只能冻结逻辑32请求，不能冻结某台模拟器公开capacity")
            XCTAssertEqual(reservedBytes, malloc_good_size(32 + 32 * actual.stride),
                "\(name)须按当前runtime对逻辑32请求得到的allocation class自适应计费")
            XCTAssertEqual(actual.bytes, reservedBytes,
                "\(name)真实Array背板必须落在同一runtime allocation class")
        }
    }

    @MainActor
    func testReviewDefaultProductionGraphAndFourSimultaneousContinuationsAreReserved() throws {
        let controller = PlaybackController()
        let registry = try XCTUnwrap(task9ObjectField("registry", of: controller,
            as: ControlTaskRegistry.self))
        let progress = registry.progressSignal
        let backendFactory = try XCTUnwrap(task9Field("backendFactory", of: controller))
        let pipelineFactory = try XCTUnwrap(task9Field("pipelineFactory", of: backendFactory))
        let defaultReceiver = try XCTUnwrap(task9AnyObjectField("defaultReceiver", of: controller))
        let routeAdapter = try XCTUnwrap(task9ObjectField("routeMonitor", of: pipelineFactory,
            as: AudioOutputRouteMonitor.self))

        XCTAssertEqual(Mirror(reflecting: backendFactory).displayStyle, .class,
            "SystemPlaybackBackendFactory须有可按真实class计费的稳定对象身份")
        XCTAssertEqual(Mirror(reflecting: pipelineFactory).displayStyle, .class,
            "SystemPlaybackPipelineFactory须有可按真实class计费的稳定对象身份")
        let backendObjectBytes = task9AnyObjectField("backendFactory", of: controller).map {
            malloc_size(Unmanaged.passUnretained($0).toOpaque())
        } ?? 0
        let pipelineObjectBytes = task9AnyObjectField("pipelineFactory", of: backendFactory).map {
            malloc_size(Unmanaged.passUnretained($0).toOpaque())
        } ?? 0
        let ownedMinimum = malloc_size(Unmanaged.passUnretained(controller).toOpaque()) +
            malloc_size(Unmanaged.passUnretained(progress).toOpaque()) + malloc_good_size(class_getInstanceSize(NSLock.self)) +
            malloc_size(Unmanaged.passUnretained(defaultReceiver).toOpaque()) + backendObjectBytes + pipelineObjectBytes
        XCTAssertGreaterThanOrEqual(
            PlaybackRuntimeAllocationReservations.ownedControl.controllerAndProgressObjects,
            ownedMinimum, "owned默认图必须含controller、progress、两层factory与default receiver")
        XCTAssertGreaterThanOrEqual(PlaybackRuntimeAllocationReservations.ownedControl.continuations,
            4 * 256, "progress/state/media/recovery cleanup disposition四份continuation可同时存活")
        XCTAssertGreaterThanOrEqual(
            PlaybackRuntimeAllocationReservations.route.fixedObjectAllocationCharges,
            PlaybackRuntimeAllocationReservations.route.serviceObject +
                PlaybackRuntimeAllocationReservations.route.serviceLock +
                PlaybackRuntimeAllocationReservations.route.timerWrapper +
                PlaybackRuntimeAllocationReservations.route.timerSource +
                malloc_size(Unmanaged.passUnretained(routeAdapter).toOpaque()),
            "route ledger必须包含默认AudioOutputRouteMonitor真实class allocation")
    }

    private func pipelineRelay(in registry: ControlTaskRegistry) -> PlaybackSessionEventRelay? {
        for record in task9OwnedRecords(registry) {
            guard case .eventDrain(let runner) = record.payload else { continue }
            if case .pipeline(let relay) = runner.relay { return relay }
        }
        return nil
    }

    private func pipelineDrain(in registry: ControlTaskRegistry) -> OwnedPlaybackEventDrain? {
        for record in task9OwnedRecords(registry) {
            guard case .eventDrain(let runner) = record.payload else { continue }
            if case .pipeline = runner.relay { return runner }
        }
        return nil
    }

    private func audioRelay(in registry: ControlTaskRegistry) -> PlaybackAudioSessionEventRelay? {
        for record in task9OwnedRecords(registry) {
            guard case .eventDrain(let runner) = record.payload else { continue }
            if case .audio(let relay) = runner.relay { return relay }
        }
        return nil
    }

    private func makeReleasedWeakTargets() async throws -> Task9RuntimeWeakTargets {
        let targets = Task9RuntimeWeakTargets()
        let retirement = Task9OperationGate()
        do {
            let fixture = try Task9RuntimeFixture(factory: .init(retirementGate: retirement))
            targets.executor = fixture.registry.executor
            targets.registry = fixture.registry
            targets.controller = fixture.controller
            targets.monitor = fixture.owner.monitor
            targets.scheduler = task9ObjectField("deadlineScheduler", of: fixture.controller,
                as: PlaybackDeadlineScheduler.self)
            targets.routeService = task9ObjectField("routeService", of: fixture.controller,
                as: PlaybackAudioRouteService.self)
            await fixture.controller.play(fixture.request())
            let stop = Task { await fixture.controller.stop() }
            await retirement.waitUntilEntered()
            if let record = task9OwnedRecords(fixture.registry).first(where: {
                if case .controllerCleanup = $0.payload { return true }; return false
            }), case .controllerCleanup(let runner) = record.payload {
                targets.cleanupRunner = runner
            }
            XCTAssertNotNil(targets.cleanupRunner, "释放边界前须观察真实原cleanup runner")
            await retirement.release()
            await stop.value
        }
        return targets
    }

    private func makeTimedOutAcquisitionWeakTargets() async throws -> Task9RuntimeWeakTargets {
        let targets = Task9RuntimeWeakTargets()
        let clock = ManualPlaybackClock(100)
        let sdkGate = DispatchSemaphore(value: 0)
        do {
            let fixture = try Task9RuntimeFixture(clock: clock)
            targets.executor = fixture.registry.executor
            targets.registry = fixture.registry
            targets.controller = fixture.controller
            targets.scheduler = task9ObjectField("deadlineScheduler", of: fixture.controller,
                as: PlaybackDeadlineScheduler.self)
            targets.monitor = fixture.owner.monitor
            targets.routeService = task9ObjectField("routeService", of: fixture.controller,
                as: PlaybackAudioRouteService.self)
            let entered = expectation(description: "SDK activation进入后play停在唯一progress waiter")
            fixture.sdk.lock.withLock { fixture.sdk.onActivate = { entered.fulfill(); sdkGate.wait() } }
            let play = Task { await fixture.controller.play(fixture.request()) }
            await fulfillment(of: [entered], timeout: 2)
            let deadline = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.acquisitionDeadline)
            clock.set(deadline.anchorInstant + 5_000_000_000)
            fixture.registry.executor.sync {}
            await settle {
                if case .failed = await fixture.controller.currentStateForTesting { return true }
                return false
            }
            fixture.sdk.lock.withLock { fixture.sdk.onActivate = nil }
            sdkGate.signal()
            await play.value
            await settle { fixture.registry.cleanupReservationSnapshot() == nil }
            await fixture.controller.stop()
        }
        return targets
    }

    private func settle(_ condition: () async -> Bool) async {
        for _ in 0..<5_000 {
            if await condition() { return }
            await Task.yield()
        }
    }
}
