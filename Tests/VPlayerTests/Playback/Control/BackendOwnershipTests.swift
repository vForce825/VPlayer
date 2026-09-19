// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class TrackingPlaybackBackend: PlaybackBackend,
    SampleBufferQuiescenceIssuerInstalling, @unchecked Sendable {
    let identity: PlaybackBackendIdentity
    let kind: PlaybackBackendKind
    let presentation: PlaybackPresentation? = .sampleBuffer(PlaybackPresentationContext())
    private weak var harness: BackendOwnershipTestHarness?
    
    private let lock = NSLock()
    private var isAudible = false
    private var isRetiredValue = false
    private var retiredEpoch: OutputLifecycleEpoch?
    private var retireCalls = 0
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var retireEnteredContinuation: CheckedContinuation<Void, Never>?
    private var holdStop = false
    private var stopConfirmed = false
    private var retireEntryObserver: (@Sendable () -> Void)?
    private var quiescenceIssuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer?
    private var requiresRetirement = false
    private var teardownResult: BackendTeardownResult = .confirmedLocalOutputStopped
    private var prepareCalls = 0
    private var activationCalls = 0

    func configureRetirement(required: Bool, result: BackendTeardownResult) {
        lock.withLock { requiresRetirement = required; teardownResult = result }
    }

    var positiveWorkSnapshot: (prepared: Int, activated: Int) {
        lock.withLock { (prepareCalls, activationCalls) }
    }
    
    init(
        identity: PlaybackBackendIdentity,
        kind: PlaybackBackendKind,
        harness: BackendOwnershipTestHarness?
    ) {
        self.identity = identity
        self.kind = kind
        self.harness = harness
    }
    
    var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRetiredValue
    }

    var retirementSnapshot: (count: Int, epoch: OutputLifecycleEpoch?) {
        lock.withLock { (retireCalls, retiredEpoch) }
    }
    
    func setHoldStop(_ hold: Bool) {
        lock.lock()
        holdStop = hold
        lock.unlock()
    }

    func setRetireEntryObserver(_ observer: (@Sendable () -> Void)?) {
        let retired = lock.withLock {
            let retired = retireEntryObserver
            retireEntryObserver = observer
            return retired
        }
        withExtendedLifetime(retired) {}
    }
    
    func waitForRetireEntered() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if stopContinuation != nil || stopConfirmed || !holdStop {
                lock.unlock()
                cont.resume()
                return
            }
            retireEnteredContinuation = cont
            lock.unlock()
        }
    }
    
    func confirmStop() {
        lock.lock()
        stopConfirmed = true
        let cont = stopContinuation
        stopContinuation = nil
        lock.unlock()
        cont?.resume()
    }
    
    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
        lock.withLock { prepareCalls += 1 }
    }
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
    }
    
    private func markAudible() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !isAudible {
            isAudible = true
            return true
        }
        return false
    }
    
    private func markInaudible() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isAudible {
            isAudible = false
            return true
        }
        return false
    }
    
    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {
        lock.withLock { activationCalls += 1 }
        _ = invocation.performPositiveRateSideEffect {
            if markAudible() { harness?.incrementAudibleCount() }
        }
    }
    
    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async -> BackendSuspendResult {
        if lock.withLock({ requiresRetirement }) { return .requiresRetirement }
        if markInaudible() {
            harness?.decrementAudibleCount()
        }
        guard let proof = lock.withLock({
            quiescenceIssuer?.issue(
                backendIdentity: identity, invocation: invocation,
                observedRate: isAudible ? 1 : 0, preparedPreserved: true)
        }) else { return .requiresRetirement }
        return .quiescent(proof)
    }

    func installSampleBufferQuiescenceIssuer(
        _ issuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer
    ) {
        lock.withLock { quiescenceIssuer = issuer }
    }
    
    private func markRetireBegun() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        isRetiredValue = true
        return holdStop && !stopConfirmed
    }

    private func popRetireEnteredContinuation() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let entered = retireEnteredContinuation
        retireEnteredContinuation = nil
        return entered
    }

    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        let entryObserver = lock.withLock {
            retireCalls += 1
            retiredEpoch = epoch
            return retireEntryObserver
        }
        entryObserver?()
        if markInaudible() {
            harness?.decrementAudibleCount()
        }
        
        let shouldHold = markRetireBegun()
        
        if shouldHold {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if stopConfirmed {
                    lock.unlock()
                    cont.resume()
                    return
                }
                stopContinuation = cont
                let entered = retireEnteredContinuation
                retireEnteredContinuation = nil
                lock.unlock()
                entered?.resume()
            }
        } else {
            let entered = popRetireEnteredContinuation()
            entered?.resume()
        }
        
        return lock.withLock { teardownResult }
    }
}

final class HarnessBackendFactory: PlaybackBackendFactory, @unchecked Sendable {
    weak var harness: BackendOwnershipTestHarness?
    var delayNanoseconds: UInt64 = 0
    var onMakeBackendStarted: (@Sendable () -> Void)?
    var configureBackend: (@Sendable (TrackingPlaybackBackend) -> Void)?
    private let lock = NSLock()
    private var _createdBackends: [TrackingPlaybackBackend] = []
    var holdCreation = false
    private var creationContinuation: CheckedContinuation<Void, Never>?

    func releaseCreation() {
        let continuation = lock.withLock {
            let value = creationContinuation
            creationContinuation = nil
            return value
        }
        continuation?.resume()
    }
    
    var createdBackends: [TrackingPlaybackBackend] {
        lock.lock()
        defer { lock.unlock() }
        return _createdBackends
    }
    
    private func recordCreatedBackend(_ backend: TrackingPlaybackBackend) {
        lock.lock()
        _createdBackends.append(backend)
        lock.unlock()
    }
    
    func makeBackend(
        kind: PlaybackBackendKind,
        identity: PlaybackBackendIdentity,
        tuning: PlaybackTuning,
        channelID: String,
        url: URL,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackBackend {
        if holdCreation {
            await withCheckedContinuation { continuation in
                lock.withLock { creationContinuation = continuation }
                onMakeBackendStarted?()
            }
        } else {
            onMakeBackendStarted?()
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let backend = TrackingPlaybackBackend(identity: identity, kind: kind, harness: harness)
        configureBackend?(backend)
        recordCreatedBackend(backend)
        harness?.recordBackendCreation(backend)
        return backend
    }
}

final class BackendOwnershipTestHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _backendCreationCount: Int = 0
    private var _currentAudibleOutputs: Int = 0
    private var _maximumPotentiallyAudibleOutputs: Int = 0
    private var backends: [TrackingPlaybackBackend] = []
    private var handoffTask: Task<Void, Never>?
    
    let factory: HarnessBackendFactory
    let controller: PlaybackController
    let registry: ControlTaskRegistry
    private let sdk: FakeAudioSessionSDK
    
    init() {
        let factory = HarnessBackendFactory()
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        let owner = try! PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let service = PlaybackAudioRouteService(registry: registry, owner: owner)
        let controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: service, backendFactory: factory)
        self.factory = factory
        self.controller = controller
        self.registry = registry
        self.sdk = sdk
        factory.harness = self
    }
    
    var backendCreationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _backendCreationCount
    }
    
    var maximumPotentiallyAudibleOutputs: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maximumPotentiallyAudibleOutputs
    }

    var currentAudibleOutputs: Int { lock.withLock { _currentAudibleOutputs } }

    func setRoute(_ kind: PlaybackBackendKind) {
        sdk.lock.withLock { sdk.initialPorts = kind == .hlsAVPlayer ? .airPlay : .hdmi }
    }
    
    fileprivate func incrementAudibleCount() {
        lock.lock()
        _currentAudibleOutputs += 1
        if _currentAudibleOutputs > _maximumPotentiallyAudibleOutputs {
            _maximumPotentiallyAudibleOutputs = _currentAudibleOutputs
        }
        lock.unlock()
    }
    
    fileprivate func decrementAudibleCount() {
        lock.lock()
        _currentAudibleOutputs = max(0, _currentAudibleOutputs - 1)
        lock.unlock()
    }
    
    fileprivate func recordBackendCreation(_ backend: TrackingPlaybackBackend) {
        lock.lock()
        _backendCreationCount += 1
        backends.append(backend)
        lock.unlock()
    }
    
    private func firstBackend() -> TrackingPlaybackBackend? {
        lock.lock()
        defer { lock.unlock() }
        return backends.first
    }
    
    func playLocal(url: URL = URL(string: "http://localhost/local.m3u8")!) async {
        let request = PlaybackRequest(
            sourceProfileID: UUID(),
            channelID: "ch-local",
            streamURL: url,
            title: "Local Channel"
        )
        await controller.play(request)
    }
    
    func holdOldStopConfirmation() {
        firstBackend()?.setHoldStop(true)
    }
    
    func requestAirPlay() async {
        let first = firstBackend()
        setRoute(.hlsAVPlayer)
        
        handoffTask = Task {
            await controller.requestRouteHandoff(to: .hlsAVPlayer)
        }
        if let first {
            await first.waitForRetireEntered()
        }
    }
    
    func confirmOldStopAndRetirement() {
        firstBackend()?.confirmStop()
    }
    
    func drain() async {
        if let task = handoffTask {
            _ = await task.result
            handoffTask = nil
        }
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

final class BackendOwnershipTests: XCTestCase {
    func testOldBackendStopMustConfirmBeforeSuccessorCreation() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        harness.holdOldStopConfirmation()
        await harness.requestAirPlay()
        XCTAssertEqual(harness.backendCreationCount, 1)
        harness.confirmOldStopAndRetirement()
        await harness.drain()
        XCTAssertEqual(harness.backendCreationCount, 2)
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
    }
    
    func testRapidNewPlayCancelsPredecessorBackendAndTeardownOrder() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal(url: URL(string: "http://localhost/first.m3u8")!)
        XCTAssertEqual(harness.backendCreationCount, 1)
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
        
        await harness.playLocal(url: URL(string: "http://localhost/second.m3u8")!)
        await harness.drain()
        XCTAssertEqual(harness.backendCreationCount, 2)
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
    }
    
    func testPauseDuringRouteHandoffPreservesPausedStateForSuccessor() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        harness.holdOldStopConfirmation()
        await harness.requestAirPlay()
        XCTAssertEqual(harness.backendCreationCount, 1)
        
        await harness.controller.setPaused(true)
        harness.confirmOldStopAndRetirement()
        await harness.drain()
        
        XCTAssertEqual(harness.backendCreationCount, 2)
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
        let state = await harness.controller.currentStateForTesting
        guard case .paused = state else {
            XCTFail("Expected state to be paused, got \(state)")
            return
        }
    }
    
    func testStopDuringRouteHandoffAbortsSuccessorActivation() async throws {
        let harness = BackendOwnershipTestHarness()
        await harness.playLocal()
        harness.holdOldStopConfirmation()
        await harness.requestAirPlay()
        XCTAssertEqual(harness.backendCreationCount, 1)
        
        let stopTask = Task {
            await harness.controller.stop()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.confirmOldStopAndRetirement()
        _ = await stopTask.result
        await harness.drain()
        
        let state = await harness.controller.currentStateForTesting
        XCTAssertEqual(state, .stopped)
    }
    
    func testLateFactoryResultAfterSessionInvalidatedIsCleanedUp() async throws {
        try await checkLateFactoryCleanup(controlled: true)
    }

    func testLateFactoryOriginalTimingStillRetires() async throws {
        try await checkLateFactoryCleanup(controlled: false)
    }

    func testLateFactoryUnconfirmedRetirementKeepsLeaseAndSuccessorBarrier() async throws {
        try await checkLateFactoryCleanup(controlled: true, retirementResult: .unconfirmed)
    }

    private func checkLateFactoryCleanup(controlled: Bool,
        retirementResult: BackendTeardownResult = .confirmedLocalOutputStopped) async throws {
        let factory = HarnessBackendFactory()
        let registry = ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let sdk = FakeAudioSessionSDK(initialPorts: [.hdmi])
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let controller = makeRoutedPlaybackController(backendFactory: factory, audioSessionOwner: owner)
        let request1 = PlaybackRequest(
            sourceProfileID: UUID(),
            channelID: "ch1",
            streamURL: URL(string: "http://localhost/1.m3u8")!,
            title: "Test 1"
        )
        
        factory.holdCreation = controlled
        factory.delayNanoseconds = controlled ? 0 : 100_000_000
        factory.configureBackend = { backend in
            backend.configureRetirement(required: true, result: retirementResult)
        }
        let backendStarted = expectation(description: "backend creation started")
        factory.onMakeBackendStarted = {
            backendStarted.fulfill()
        }
        let playTask = Task {
            await controller.play(request1)
        }
        
        await fulfillment(of: [backendStarted], timeout: 5.0)
        if controlled {
            let stopTask = Task { await controller.stop() }
            let stopInstalled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                registry.outputResourceContextSnapshot()?.owner?.reason == .stop
            }, object: nil)
            await fulfillment(of: [stopInstalled], timeout: 5)
            factory.releaseCreation()
            await stopTask.value
        } else {
            await controller.stop()
        }
        
        _ = await playTask.result
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .stopped)
        
        let created = factory.createdBackends
        let finalContext = registry.outputResourceContextSnapshot()
        let finalReservation = registry.cleanupReservationSnapshot()
        let finalDeactivations = sdk.deactivateCallCount
        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(created.first?.isRetired == true)
        let backend = try XCTUnwrap(created.first)
        XCTAssertEqual(backend.retirementSnapshot.count, 1)
        XCTAssertEqual(backend.retirementSnapshot.epoch?.backendIdentity, backend.identity)
        XCTAssertEqual(backend.positiveWorkSnapshot.prepared, 0)
        XCTAssertEqual(backend.positiveWorkSnapshot.activated, 0)
        if retirementResult == .confirmedLocalOutputStopped {
            XCTAssertNil(finalContext)
            XCTAssertNil(finalReservation)
            XCTAssertEqual(finalDeactivations, 1)
        } else {
            let retained = try XCTUnwrap(finalContext)
            XCTAssertFalse(retained.retirementConfirmed)
            XCTAssertNotNil(finalReservation)
            XCTAssertEqual(finalDeactivations, 0)
            XCTAssertNil(try registry.beginOutputActivation(contextNonce: retained.contextNonce))
            XCTAssertNil(try registry.renewOutputCycle(contextNonce: retained.contextNonce))
        }
    }

    func testRevokedRealFactoryWithoutOwnerRetainsLifecycleAndRejectsSecondResult() throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        let pending = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let identity = try XCTUnwrap(pending.candidateBackendIdentity)
        let candidate = TrackingPlaybackBackend(identity: identity, kind: .sampleBuffer, harness: nil)
        XCTAssertTrue(registry.requestCancel(factory))
        XCTAssertNil(registry.outputResourceContextSnapshot()?.owner)
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: candidate))
        let cleanup = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertNotNil(cleanup.owner)
        XCTAssertEqual(cleanup.suspend?.lifecycle,
            OutputLifecycleEpoch(backendIdentity: identity, outputNonce: pending.candidateLifecycleNonce))
        XCTAssertNil(cleanup.teardown)
        XCTAssertFalse(try registry.completeOutputFactory(factory, candidate: nil))
        XCTAssertFalse(try registry.settleOutputFactory(factory))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.suspend, cleanup.suspend)
    }

    func testOwnedSuspendRetirementRequiredConfirmedAndUnconfirmed() async throws {
        for outcome in [BackendTeardownResult.confirmedLocalOutputStopped, .unconfirmed] {
            let factory = HarnessBackendFactory()
            factory.configureBackend = { $0.configureRetirement(required: true, result: outcome) }
            let registry = ControlTaskRegistry(allocator: .init())
            let sdk = FakeAudioSessionSDK(initialPorts: [.hdmi])
            let audio = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
            let controller = makeRoutedPlaybackController(backendFactory: factory, audioSessionOwner: audio)
            await controller.play(.init(sourceProfileID: UUID(), channelID: "退休测试",
                streamURL: URL(string: "http://localhost/retirement.m3u8")!, title: "退休测试"))
            let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let owner = try XCTUnwrap(registry.beginOutputTransition(contextNonce: installed.contextNonce,
                reason: .pause, anchorInstant: registry.clock.nowNanoseconds, teardown: false))
            let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
            XCTAssertTrue(registry.startOutputSuspendOperation(stop.task, owner: owner))
            _ = await registry.joinOutputBackendOperation(stop.task)
            let candidate = try XCTUnwrap(factory.createdBackends.first)
            XCTAssertEqual(candidate.retirementSnapshot.count, 1)
            XCTAssertEqual(candidate.retirementSnapshot.epoch, stop.lifecycle)
            let current = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertEqual(current.retirementConfirmed, outcome == .confirmedLocalOutputStopped)
            XCTAssertNil(registry.playbackDeadlineScheduleSnapshot().suspend,
                "停止责任转交退休后不再运行原 suspend 计时器")
            XCTAssertNil(try registry.beginOutputActivation(contextNonce: current.contextNonce))
            XCTAssertEqual(sdk.deactivateCallCount, 0)
            withExtendedLifetime(controller) {}
        }
    }

    func testRetirementRequirementRejectsForeignBackendWrongTicketAndReplay() async throws {
        let factory = HarnessBackendFactory()
        let registry = ControlTaskRegistry(allocator: .init())
        let sdk = FakeAudioSessionSDK(initialPorts: [.hdmi])
        let audio = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let controller = makeRoutedPlaybackController(backendFactory: factory, audioSessionOwner: audio)
        await controller.play(.init(sourceProfileID: UUID(), channelID: "准确退休",
            streamURL: URL(string: "http://localhost/exact-retirement.m3u8")!, title: "准确退休"))
        let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let interval = try XCTUnwrap(installed.interval)
        let owner = try XCTUnwrap(registry.beginOutputTransition(contextNonce: installed.contextNonce,
            reason: .stop, anchorInstant: registry.clock.nowNanoseconds, teardown: true))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        let cleanup = try XCTUnwrap(registry.claimOutputBackendCleanup(stop.task, owner: owner))
        let invocation = try XCTUnwrap(cleanup.suspendInvocation)
        let foreign = TrackingPlaybackBackend(identity: cleanup.backend.identity, kind: .sampleBuffer, harness: nil)
        XCTAssertFalse(registry.completeOutputSuspend(.requiresRetirement, invocation: invocation, backend: foreign))
        XCTAssertFalse(try XCTUnwrap(registry.outputResourceContextSnapshot()).suspendRequiresRetirement)
        XCTAssertTrue(registry.completeOutputSuspend(.requiresRetirement, invocation: invocation, backend: cleanup.backend))
        XCTAssertFalse(registry.completeOutputSuspend(.requiresRetirement, invocation: invocation, backend: cleanup.backend))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.interval, interval)
        let retirement = try XCTUnwrap(registry.advanceOutputCleanup(owner: owner))
        let retiring = try XCTUnwrap(registry.claimOutputBackendCleanup(retirement, owner: owner))
        XCTAssertFalse(registry.completeOutputRetirement(stop.task, lifecycle: invocation.lifecycle))
        let foreignLifecycle = OutputLifecycleEpoch(backendIdentity: invocation.lifecycle.backendIdentity,
            outputNonce: invocation.lifecycle.outputNonce + 1)
        XCTAssertFalse(registry.completeOutputRetirement(retirement, lifecycle: foreignLifecycle))
        XCTAssertEqual(registry.outputResourceContextSnapshot()?.interval, interval)
        XCTAssertEqual(sdk.deactivateCallCount, 0)
        let result = await retiring.backend.retireOutput(epoch: invocation.lifecycle)
        XCTAssertEqual(result, .confirmedLocalOutputStopped)
        XCTAssertTrue(registry.completeOutputRetirement(retirement, lifecycle: invocation.lifecycle))
        XCTAssertFalse(registry.completeOutputRetirement(retirement, lifecycle: invocation.lifecycle))
        XCTAssertNil(registry.outputResourceContextSnapshot()?.interval)
        withExtendedLifetime(controller) {}
    }

    func testLateSuspendTimeoutAfterRetirementTransferPreservesRetainedOwnerAndBudgets() throws {
        for reason in [OutputTransitionReason.pause, .recovery] {
            let fixture = try StableOutputFixture()
            let registry = fixture.registry
            let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
                stableCommit: fixture.stable, owner: nil))
            let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
            XCTAssertTrue(registry.claimStart(factory))
            let identity = try XCTUnwrap(registry.outputResourceContextSnapshot()?.candidateBackendIdentity)
            let backend = TrackingPlaybackBackend(identity: identity, kind: .sampleBuffer, harness: nil)
            XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: backend))
            XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
            let prepare = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sourceTask)
            XCTAssertTrue(registry.claimStart(prepare))
            XCTAssertTrue(registry.completeOutputPrepare(prepare))
            let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let owner = try XCTUnwrap(registry.beginOutputTransition(contextNonce: installed.contextNonce,
                reason: reason, anchorInstant: registry.clock.nowNanoseconds, teardown: false))
            let oldTimer = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
            let cleanup = try XCTUnwrap(registry.claimOutputBackendCleanup(oldTimer.task, owner: owner))
            let invocation = try XCTUnwrap(cleanup.suspendInvocation)
            XCTAssertTrue(registry.completeOutputSuspend(.requiresRetirement, invocation: invocation, backend: backend))
            let before = try XCTUnwrap(registry.outputResourceContextSnapshot())
            let budget = try XCTUnwrap(before.budget)
            XCTAssertNotNil(before.parentDeadline)
            XCTAssertNil(registry.playbackDeadlineScheduleSnapshot().suspend)
            let lateInstant = oldTimer.anchorInstant + 1_000_000_001
            XCTAssertLessThan(lateInstant, budget.deadlineInstant)
            fixture.acquisition.clock.set(lateInstant)
            XCTAssertFalse(registry.timeoutOutputSuspend(oldTimer),
                "\(reason)：已在途旧票也必须拒绝，取消排期不能代替 Authority 验票")
            let after = try XCTUnwrap(registry.outputResourceContextSnapshot())
            XCTAssertEqual(after.owner, before.owner)
            XCTAssertEqual(after.poisoned, before.poisoned)
            XCTAssertEqual(after.disposition, before.disposition)
            XCTAssertEqual(after.budget, before.budget)
            XCTAssertEqual(after.parentDeadline, before.parentDeadline)
            XCTAssertEqual(after.teardownRequested, before.teardownRequested)
            XCTAssertFalse(after.suspendTimedOut)
            XCTAssertTrue(after.suspendRequiresRetirement)
            XCTAssertFalse(after.retirementConfirmed)
            XCTAssertFalse(try XCTUnwrap(registry.cleanupReservationSnapshot()).terminal)
        }
    }

    func testRetirementRequirementDoesNotSkipSuspendOnNewLifecycle() async throws {
        let fixture = try StableOutputFixture()
        let registry = fixture.registry
        let retained = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let rebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: retained.contextNonce,
            stableCommit: fixture.stable, owner: nil))
        let factory = try XCTUnwrap(registry.claimOutputSuccessor(try XCTUnwrap(rebase.successorClaim)))
        XCTAssertTrue(registry.claimStart(factory))
        let identity = try XCTUnwrap(registry.outputResourceContextSnapshot()?.candidateBackendIdentity)
        let backend = TrackingPlaybackBackend(identity: identity, kind: .sampleBuffer, harness: nil)
        XCTAssertTrue(try registry.completeOutputFactory(factory, candidate: backend))
        XCTAssertEqual(try registry.retireOutputControlRecord(factory), .retired(followUp: nil))
        let prepare = try XCTUnwrap(registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(registry.claimStart(prepare))
        XCTAssertTrue(registry.completeOutputPrepare(prepare))
        let installed = try XCTUnwrap(registry.outputResourceContextSnapshot())
        let owner = try XCTUnwrap(registry.beginOutputTransition(contextNonce: installed.contextNonce,
            reason: .pause, anchorInstant: registry.clock.nowNanoseconds, teardown: false))
        let stop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        let cleanup = try XCTUnwrap(registry.claimOutputBackendCleanup(stop.task, owner: owner))
        let invocation = try XCTUnwrap(cleanup.suspendInvocation)
        XCTAssertTrue(registry.completeOutputSuspend(.requiresRetirement, invocation: invocation, backend: backend))
        let retirement = try XCTUnwrap(registry.advanceOutputCleanup(owner: owner))
        XCTAssertNotNil(registry.claimOutputBackendCleanup(retirement, owner: owner))
        let result = await backend.retireOutput(epoch: stop.lifecycle)
        XCTAssertEqual(result, .confirmedLocalOutputStopped)
        XCTAssertTrue(registry.completeOutputRetirement(retirement, lifecycle: stop.lifecycle))
        XCTAssertEqual(try registry.retireOutputControlRecord(stop.task), .retired(followUp: nil))
        XCTAssertEqual(try registry.retireOutputControlRecord(retirement), .retired(followUp: nil))
        XCTAssertNotNil(try registry.renewOutputCycle(contextNonce: installed.contextNonce))
        let nextRebase = try XCTUnwrap(registry.rebaseRetainedOutput(contextNonce: installed.contextNonce,
            stableCommit: fixture.stable, owner: owner))
        let nextPrepare = try XCTUnwrap(registry.reprepareQuiescentOutput(nextRebase))
        XCTAssertTrue(registry.claimStart(nextPrepare))
        XCTAssertTrue(registry.completeOutputPrepare(nextPrepare))
        let next = try XCTUnwrap(registry.outputResourceContextSnapshot())
        XCTAssertFalse(next.suspendRequiresRetirement)
        XCTAssertFalse(registry.completeOutputSuspend(.requiresRetirement, invocation: invocation, backend: backend))
        let nextOwner = try XCTUnwrap(registry.beginOutputTransition(contextNonce: next.contextNonce,
            reason: .pause, anchorInstant: registry.clock.nowNanoseconds, teardown: false))
        let nextStop = try XCTUnwrap(registry.outputResourceContextSnapshot()?.suspend)
        XCTAssertNotEqual(nextStop.lifecycle, stop.lifecycle)
        XCTAssertEqual(try registry.advanceOutputCleanup(owner: nextOwner), nextStop.task,
            "新生命周期必须先调用自己的 suspend，不能继承旧退休要求跳过")
    }
}
