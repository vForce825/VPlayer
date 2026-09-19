// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFAudio
import AVFoundation
import Foundation
import XCTest
@testable import VPlayerPlayback

final class RecoveryTrackingPlaybackBackend: PlaybackBackend, SampleBufferQuiescenceIssuerInstalling, @unchecked Sendable {
    let identity: PlaybackBackendIdentity
    let kind: PlaybackBackendKind
    weak var harness: PlaybackRecoveryTestHarness?

    private let lock = NSLock()
    private var isAudible = false
    private var isSuspended = false
    private var isRetired = false
    private var quiescenceIssuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer?
    private(set) var prepareCalls = 0
    private(set) var reprepareCalls = 0
    private(set) var activationCalls = 0
    private(set) var suspendCalls = 0
    private(set) var retireCalls = 0

    var isSuspendedSnapshot: Bool { lock.withLock { isSuspended } }
    var isRetiredSnapshot: Bool { lock.withLock { isRetired } }
    var suspendCallCount: Int { lock.withLock { suspendCalls } }
    var activationCallCount: Int { lock.withLock { activationCalls } }
    var prepareCallCount: Int { lock.withLock { prepareCalls } }
    var reprepareCallCount: Int { lock.withLock { reprepareCalls } }

    var presentation: PlaybackPresentation? {
        switch kind {
        case .sampleBuffer:
            return .sampleBuffer(PlaybackPresentationContext())
        case .hlsAVPlayer:
            return .avPlayer(AVPlayerPresentationContext(player: AVPlayer()))
        }
    }

    init(
        identity: PlaybackBackendIdentity,
        kind: PlaybackBackendKind,
        harness: PlaybackRecoveryTestHarness?
    ) {
        self.identity = identity
        self.kind = kind
        self.harness = harness
    }

    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
        lock.withLock { prepareCalls += 1 }
    }

    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
        lock.withLock { reprepareCalls += 1 }
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
        lock.withLock { activationCalls += 1; isSuspended = false }
        _ = invocation.performPositiveRateSideEffect {
            if markAudible() {
                harness?.incrementAudibleCount()
            }
        }
    }

    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async -> BackendSuspendResult {
        lock.withLock { suspendCalls += 1; isSuspended = true }
        if markInaudible() {
            harness?.decrementAudibleCount()
        }
        guard let proof = lock.withLock({
            quiescenceIssuer?.issue(
                backendIdentity: identity,
                invocation: invocation,
                observedRate: isAudible ? 1 : 0,
                preparedPreserved: true
            )
        }) else {
            return .requiresRetirement
        }
        return .quiescent(proof)
    }

    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        lock.withLock { retireCalls += 1; isRetired = true; isSuspended = false }
        if markInaudible() {
            harness?.decrementAudibleCount()
        }
        return .confirmedLocalOutputStopped
    }

    func installSampleBufferQuiescenceIssuer(
        _ issuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer
    ) {
        lock.withLock { quiescenceIssuer = issuer }
    }
}

final class RecoveryTrackingBackendFactory: PlaybackBackendFactory, @unchecked Sendable {
    weak var harness: PlaybackRecoveryTestHarness?
    private let lock = NSLock()
    private var _createdBackends: [RecoveryTrackingPlaybackBackend] = []

    init(harness: PlaybackRecoveryTestHarness? = nil) {
        self.harness = harness
    }

    var createdBackends: [RecoveryTrackingPlaybackBackend] {
        lock.withLock { _createdBackends }
    }

    func makeBackend(
        kind: PlaybackBackendKind,
        identity: PlaybackBackendIdentity,
        tuning: PlaybackTuning,
        channelID: String,
        url: URL,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackBackend {
        let backend = RecoveryTrackingPlaybackBackend(identity: identity, kind: kind, harness: harness)
        lock.withLock {
            _createdBackends.append(backend)
        }
        harness?.recordBackendCreation(kind: kind, backend: backend)
        return backend
    }
}

final class PlaybackRecoveryTestHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _backendHistory: [PlaybackBackendKind] = []
    private var _currentAudibleOutputs: Int = 0
    private var _maximumPotentiallyAudibleOutputs: Int = 0
    private var _backends: [RecoveryTrackingPlaybackBackend] = []

    let allocator: PlaybackIdentityAllocator
    let registry: ControlTaskRegistry
    let sdk: FakeAudioSessionSDK
    let owner: PlaybackAudioSessionOwner
    let routeService: PlaybackAudioRouteService
    let factory: RecoveryTrackingBackendFactory
    let controller: PlaybackController

    init(actualPolicy: AudioSessionActualPolicy = .longFormAudio) {
        let allocator = PlaybackIdentityAllocator()
        let registry = ControlTaskRegistry(allocator: allocator)
        let sdk = FakeAudioSessionSDK(initialPorts: .hdmi)
        if actualPolicy == .default {
            sdk.failLongFormCategory = true
        }
        let owner = try! PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let routeService = PlaybackAudioRouteService(registry: registry, owner: owner)
        let factory = RecoveryTrackingBackendFactory()
        let controller = PlaybackController(
            registry: registry,
            audioSessionOwner: owner,
            routeService: routeService,
            backendFactory: factory,
            allocator: allocator
        )

        self.allocator = allocator
        self.registry = registry
        self.sdk = sdk
        self.owner = owner
        self.routeService = routeService
        self.factory = factory
        self.controller = controller

        factory.harness = self
    }

    var backendHistory: [PlaybackBackendKind] {
        lock.withLock { _backendHistory }
    }

    var createdBackends: [RecoveryTrackingPlaybackBackend] {
        factory.createdBackends
    }

    var currentState: PlaybackState {
        registry.playbackStateSnapshot()
    }

    private(set) var currentRequest: PlaybackRequest?

    var maximumPotentiallyAudibleOutputs: Int {
        lock.withLock { _maximumPotentiallyAudibleOutputs }
    }

    var categoryCallCount: Int {
        sdk.lock.withLock { sdk.categoryCallCount }
    }

    var routeOnlyDeactivateCount: Int {
        sdk.lock.withLock { sdk.deactivateCallCount }
    }

    fileprivate func recordBackendCreation(kind: PlaybackBackendKind, backend: RecoveryTrackingPlaybackBackend) {
        lock.withLock {
            _backendHistory.append(kind)
            _backends.append(backend)
        }
    }

    fileprivate func incrementAudibleCount() {
        lock.withLock {
            _currentAudibleOutputs += 1
            if _currentAudibleOutputs > _maximumPotentiallyAudibleOutputs {
                _maximumPotentiallyAudibleOutputs = _currentAudibleOutputs
            }
        }
    }

    fileprivate func decrementAudibleCount() {
        lock.withLock {
            _currentAudibleOutputs = max(0, _currentAudibleOutputs - 1)
        }
    }

    func playThroughHDMI(url: URL = URL(string: "http://localhost/hdmi-stream.m3u8")!) async {
        sdk.lock.withLock { sdk.initialPorts = .hdmi }
        let request = PlaybackRequest(
            sourceProfileID: UUID(),
            channelID: "hdmi-channel",
            streamURL: url,
            title: "HDMI Test Stream"
        )
        self.currentRequest = request
        await controller.play(request)
        await advanceThroughRouteStability()
        await drainExecutor()
    }

    func switchToAirPlay() async {
        sdk.lock.withLock { sdk.initialPorts = .airPlay }
        routeService.resample(reason: .routeConfigurationChange)
        await advanceThroughRouteStability()
        await drainExecutor()
    }

    func switchToHDMI() async {
        sdk.lock.withLock { sdk.initialPorts = .hdmi }
        routeService.resample(reason: .routeConfigurationChange)
        await advanceThroughRouteStability()
        await drainExecutor()
    }

    func switchToBluetooth() async {
        sdk.lock.withLock { sdk.initialPorts = .bluetooth }
        routeService.resample(reason: .routeConfigurationChange)
        await advanceThroughRouteStability()
        await drainExecutor()
    }

    func switchToEmptyRoute() async {
        sdk.lock.withLock { sdk.initialPorts = [] }
        routeService.resample(reason: .routeConfigurationChange)
        await advanceThroughRouteStability()
        await drainExecutor()
    }

    func advanceThroughRouteStability() async {
        // Wait for the 120ms route stability window to fire on the real clock
        try? await Task.sleep(nanoseconds: 160_000_000)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 2_000_000)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                registry.executor.submit { cont.resume() }
            }
        }
    }

    func drainExecutor() async {
        await controller.recoveryCoordinator.waitForCurrentRecovery()
        for _ in 0..<15 {
            await Task.yield()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                registry.executor.submit { cont.resume() }
            }
        }
        await controller.recoveryCoordinator.waitForCurrentRecovery()
    }

    func stop() async {
        await controller.stop()
        await drainExecutor()
    }
}

final class PlaybackRecoveryTests: XCTestCase {
    func testFullRouteHotSwitchHDMIToAirPlayAndBackToHDMI() async throws {
        let harness = PlaybackRecoveryTestHarness()
        await harness.playThroughHDMI()
        await harness.switchToAirPlay()
        await harness.switchToHDMI()
        XCTAssertEqual(harness.backendHistory, [.sampleBuffer, .hlsAVPlayer, .sampleBuffer])
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
        XCTAssertEqual(harness.categoryCallCount, 1)
        XCTAssertEqual(harness.routeOnlyDeactivateCount, 0)
        await harness.stop()
    }

    func testFiveRoundsRouteOnlyHotSwitchingPreservesSingleCategoryAndZeroDeactivate() async throws {
        let harness = PlaybackRecoveryTestHarness()
        await harness.playThroughHDMI()
        for _ in 1...5 {
            await harness.switchToAirPlay()
            await harness.switchToHDMI()
        }
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
        XCTAssertEqual(harness.categoryCallCount, 1, "Route-only handoff must never call setCategory after initial acquisition")
        XCTAssertEqual(harness.routeOnlyDeactivateCount, 0, "Route-only handoff must never call deactivate")
        await harness.stop()
        XCTAssertEqual(harness.routeOnlyDeactivateCount, 1, "Explicit stop must call deactivate exactly once")
    }

    func testAirPlayWithDefaultPolicyFailsClosedWithoutBackendCreation() async throws {
        let harness = PlaybackRecoveryTestHarness(actualPolicy: .default)
        // With .default policy on AirPlay, backend selection throws .airPlayLongFormUnavailable
        await harness.playThroughHDMI()
        XCTAssertEqual(harness.backendHistory, [.sampleBuffer])

        // Changing to AirPlay with default policy fails closed
        await harness.switchToAirPlay()
        XCTAssertFalse(harness.backendHistory.contains(.hlsAVPlayer), "AirPlay on default policy must not create HLS backend")
        await harness.stop()
    }

    func testStopDuringRouteHandoffAbortsSuccessorActivation() async throws {
        let harness = PlaybackRecoveryTestHarness()
        await harness.playThroughHDMI()
        let handoffTask = Task {
            await harness.switchToAirPlay()
        }
        await harness.stop()
        _ = await handoffTask.result
        XCTAssertEqual(harness.maximumPotentiallyAudibleOutputs, 1)
        let finalState = harness.currentState
        XCTAssertEqual(finalState, .stopped)
    }

    func testQuiescentEndpointHandoffBetweenSampleBufferRoutesReusesBackendWithoutRecreation() async throws {
        let harness = PlaybackRecoveryTestHarness()
        await harness.playThroughHDMI()
        XCTAssertEqual(harness.backendHistory, [.sampleBuffer])
        XCTAssertEqual(harness.createdBackends.count, 1)
        let initialBackend = harness.createdBackends[0]
        XCTAssertEqual(initialBackend.suspendCallCount, 0)
        XCTAssertEqual(initialBackend.activationCallCount, 1)

        await harness.switchToBluetooth()
        XCTAssertEqual(harness.currentState, .playing(harness.currentRequest!), "Current state after switchToBluetooth")
        XCTAssertEqual(harness.backendHistory, [.sampleBuffer], "Switching between SampleBuffer routes must reuse quiescent backend")
        XCTAssertEqual(harness.createdBackends.count, 1, "No new backend should be created during quiescent endpoint handoff")
        XCTAssertEqual(initialBackend.suspendCallCount, 1, "Quiescent handoff must suspend the active backend")
        XCTAssertEqual(initialBackend.activationCallCount, 2, "Quiescent handoff must reactivate the suspended backend")
        XCTAssertFalse(initialBackend.isSuspendedSnapshot, "Backend must not remain suspended after reactivation")
        XCTAssertEqual(harness.categoryCallCount, 1)
        XCTAssertEqual(harness.routeOnlyDeactivateCount, 0)
        await harness.stop()
    }

    func testMediaServicesResetRecoveryRecordsStateAndComputesSuffix() {
        let recovery = MediaServicesResetRecovery()
        XCTAssertEqual(recovery.currentResetCount, 0)
        XCTAssertNil(recovery.currentAnchor)

        let suffix1 = recovery.recordReset(at: 10_000_000_000, isHLS: true)
        XCTAssertEqual(recovery.currentResetCount, 1)
        XCTAssertEqual(suffix1, 3_000_000_000) // 3.0s for HLS
        XCTAssertEqual(recovery.currentAnchor, 10_000_000_000)

        let suffix2 = recovery.recordReset(at: 15_000_000_000, isHLS: false)
        XCTAssertEqual(recovery.currentResetCount, 2)
        XCTAssertEqual(suffix2, 3_000_000_000) // Monotonic non-decreasing: max(3.0s, 2.0s) = 3.0s
        // Successive resets inherit parentAnchor
        XCTAssertEqual(recovery.currentAnchor, 10_000_000_000)

        recovery.resetFinished()
        XCTAssertNil(recovery.currentAnchor)
        XCTAssertEqual(recovery.currentResetCount, 0)

        // Verify independent resets after resetFinished start fresh
        let suffix3 = recovery.recordReset(at: 25_000_000_000, isHLS: true)
        XCTAssertEqual(recovery.currentResetCount, 1)
        XCTAssertEqual(suffix3, 3_000_000_000)
        XCTAssertEqual(recovery.currentAnchor, 25_000_000_000)
    }

    func testRouteUnavailablePublishesRecoveringAndCancelRestoresState() async throws {
        let harness = PlaybackRecoveryTestHarness()
        await harness.playThroughHDMI()
        guard let initialBackend = harness.createdBackends.first else {
            XCTFail("Initial backend should exist")
            return
        }
        await harness.switchToEmptyRoute()
        let intermediateState = harness.currentState
        if case .recovering = intermediateState {
            // expected
        } else {
            XCTFail("State should be .recovering while route is empty, got \(intermediateState)")
        }
        XCTAssertTrue(initialBackend.isSuspendedSnapshot, "Active output must be suspended immediately when route becomes unavailable")

        // Restoring to HDMI restores stability before timeout
        await harness.switchToHDMI()
        let restoredState = harness.currentState
        XCTAssertEqual(restoredState, .playing(harness.currentRequest!), "State should be restored to playing after route returns")
        XCTAssertEqual(harness.backendHistory.last, .sampleBuffer)
        XCTAssertFalse(initialBackend.isSuspendedSnapshot, "Backend should no longer be suspended after route recovery")
        await harness.stop()
    }

    func testRouteUnavailableTimeoutTerminatesSession() async throws {
        let harness = PlaybackRecoveryTestHarness()
        await harness.playThroughHDMI()
        guard let initialBackend = harness.createdBackends.first else {
            XCTFail("Initial backend should exist")
            return
        }
        await harness.switchToEmptyRoute()

        // Wait for the 3.0s route unavailable timeout to expire
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await harness.drainExecutor()
            if harness.currentState == .failed(PlaybackController.routeUnavailableFailure) {
                break
            }
        }

        let state = harness.currentState
        XCTAssertEqual(state, .failed(PlaybackController.routeUnavailableFailure))
        XCTAssertTrue(initialBackend.isRetiredSnapshot, "Backend must be retired on route unavailable timeout")
        await harness.stop()
    }

}
