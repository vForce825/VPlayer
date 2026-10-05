// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class NativeHLSAdapterLifecycleTests: XCTestCase {
    func testExactNativeFirstClockAdvanceSettlesDeadlineAndOldActivationCannotSettleSuccessor() async throws {
        let clock = ManualPlaybackClock(100)
        try await NativeAdapterFixture.withFixture(clock: clock) { fixture in
            fixture.play(); try await fixture.until { fixture.isPlaying }
            let original = try XCTUnwrap(fixture.driver.lastPositiveInvocation)
            let originalItem = try XCTUnwrap(fixture.driver.currentItemIdentity)
            XCTAssertNotNil(fixture.registry.outputResourceContextSnapshot()?.parentDeadline)
            fixture.driver.advanceMedia(to: ExactMediaTime(value: 1, timescale: 1))
            clock.advance(nanoseconds: 250_000_000)
            try await fixture.until { fixture.registry.outputResourceContextSnapshot()?.parentDeadline == nil }
            let backend = try XCTUnwrap(fixture.factory.backend)
            let accepted = await backend.requestWatchdogRecovery(activation: original.activation)
            XCTAssertTrue(accepted)
            try await fixture.until { fixture.isPlaying && fixture.driver.currentItemIdentity != originalItem }
            let successor = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.parentDeadline)
            let arm = try XCTUnwrap(fixture.registry.playbackOperationDeadlineArmSnapshot())
            XCTAssertFalse(original.completeObservedMediaProgress())
            XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.parentDeadline, successor)
            XCTAssertEqual(fixture.registry.playbackOperationDeadlineArmSnapshot(), arm)
            fixture.driver.advanceMedia(to: ExactMediaTime(value: 2, timescale: 1))
            clock.advance(nanoseconds: 250_000_000)
            try await fixture.until { fixture.registry.outputResourceContextSnapshot()?.parentDeadline == nil }
        }
    }

    func testNativeRateWithoutClockAdvanceDoesNotSettleOriginalStartupDeadline() async throws {
        let clock = ManualPlaybackClock(100)
        try await NativeAdapterFixture.withFixture(clock: clock) { fixture in
            fixture.play(); try await fixture.until { fixture.isPlaying }
            let parent = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.parentDeadline)
            let budget: PlaybackProgressBudgetTicket
            switch parent { case .coldStart(let value), .outputRecovery(let value): budget = value }
            XCTAssertNotNil(fixture.registry.playbackOperationDeadlineArmSnapshot())
            let remaining = try budget.remainingNanoseconds(at: clock.nowNanoseconds)
            XCTAssertGreaterThan(remaining, 0)
            clock.advance(nanoseconds: remaining - 1)
            fixture.registry.executor.sync {}
            XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.parentDeadline, parent)
            clock.advance(nanoseconds: 1)
            try await fixture.until { fixture.registry.outputResourceContextSnapshot() == nil }
            XCTAssertEqual(fixture.driver.plays, 1)
            XCTAssertEqual(fixture.driver.installs, 1)
        }
    }

    func testActualAdapterPreparesActivatesPausesResumesAndRetiresWithoutGeneratedWork() async throws {
        try await NativeAdapterFixture.withFixture { fixture in
            fixture.play()
            try await fixture.until { fixture.isPlaying }
            let backend = try XCTUnwrap(fixture.factory.backend)
            XCTAssertEqual(backend.routedTransportForTesting, .native)
            XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
            XCTAssertEqual(fixture.driver.installs, 1)
            XCTAssertGreaterThanOrEqual(fixture.driver.prerolls, 2)
            let physical = try XCTUnwrap(fixture.driver.physical)
            await fixture.controller.setPaused(true)
            try await fixture.until { fixture.driver.disconnectedFromSystemAudio }
            let reads = fixture.inspector.reads
            await fixture.controller.setPaused(false)
            try await fixture.until { fixture.isPlaying && fixture.driver.plays == 2 }
            XCTAssertTrue(fixture.driver.physical === physical)
            XCTAssertGreaterThan(fixture.inspector.reads, reads, "Resume must reload selected format before positive rate")
            XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
        }
    }

    func testCancellationInsensitiveReadyPrerollProbeAndFormatWaitsCannotInstallOrActivateLate() async throws {
        for phase in NativeAdapterFixture.Phase.allCases {
            try await NativeAdapterFixture.withFixture { fixture in
                let gate = fixture.hold(phase)
                fixture.play()
                try await fixture.until { gate.entered }
                fixture.spawn { await fixture.controller.stop() }
                try await fixture.until { fixture.registry.outputResourceContextSnapshot()?.teardownRequested == true }
                gate.release()
                try await fixture.until { fixture.registry.outputResourceContextSnapshot() == nil }
                XCTAssertEqual(fixture.driver.plays, 0, "Late \(phase) continuation consumed revoked authority")
                XCTAssertNil(fixture.driver.currentItemIdentity)
                if phase == .probe { XCTAssertEqual(fixture.driver.installs, 0) }
            }
        }
    }

    func testFixtureTimeoutReleasesAndJoinsHeldPreparationBeforeRethrowing() async throws {
        enum Expected: Error { case fixtureFailure }
        var fixtureForVerification: NativeAdapterFixture?
        do {
            try await NativeAdapterFixture.withFixture { fixture in
                fixtureForVerification = fixture
                let gate = fixture.hold(.ready)
                fixture.play()
                try await fixture.until { gate.entered }
                throw Expected.fixtureFailure
            }
            XCTFail("The body failure must survive physical teardown")
        } catch Expected.fixtureFailure {}
        let fixture = try XCTUnwrap(fixtureForVerification)
        XCTAssertTrue(fixture.cleanupCompleted)
        XCTAssertNil(fixture.driver.currentItemIdentity)
        XCTAssertEqual(fixture.driver.rate, 0)
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot())
    }

    func testSameBackendRecoveryRequiresFreshPhysicalItemAndRejectsLateOldOwner() async throws {
        try await NativeAdapterFixture.withFixture { fixture in
            fixture.play(); try await fixture.until { fixture.isPlaying }
            let backend = try XCTUnwrap(fixture.factory.backend)
            let oldCoordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
            let oldItem = try XCTUnwrap(fixture.driver.physical)
            let oldIdentity = try XCTUnwrap(fixture.driver.currentItemIdentity)
            let oldActivation = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.activation)
            let recoveryAccepted = await backend.requestWatchdogRecovery(activation: oldActivation)
            XCTAssertTrue(recoveryAccepted)
            try await fixture.until {
                fixture.isPlaying && fixture.driver.currentItemIdentity != oldIdentity && fixture.driver.plays == 2
            }
            let freshIdentity = try XCTUnwrap(fixture.driver.currentItemIdentity)
            XCTAssertNotEqual(freshIdentity.outputLifecycleEpoch, oldIdentity.outputLifecycleEpoch)
            XCTAssertFalse(fixture.driver.physical === oldItem)
            XCTAssertTrue(fixture.factory.backend === backend)
            XCTAssertFalse(oldCoordinator.owned.requestNewGeneration())
            XCTAssertFalse(oldCoordinator.owned.requestCompatibleAudioGeneration())
            await oldCoordinator.observeSelectedFormatChangeForTesting()
            XCTAssertEqual(fixture.driver.currentItemIdentity, freshIdentity)
            XCTAssertTrue(fixture.isPlaying)
            XCTAssertEqual(backend.generatedBundleCallsForTesting, 0)
        }
    }

    func testRecoveryReadyFailureHasNoSuccessorActivationAndTeardownJoins() async throws {
        try await NativeAdapterFixture.withFixture { fixture in
            fixture.play(); try await fixture.until { fixture.isPlaying }
            let backend = try XCTUnwrap(fixture.factory.backend)
            let activation = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot()?.activation)
            let gate = fixture.hold(.ready)
            fixture.driver.failReady = true
            let recoveryAccepted = await backend.requestWatchdogRecovery(activation: activation)
            XCTAssertTrue(recoveryAccepted)
            try await fixture.until { gate.entered }
            gate.release()
            try await fixture.until { fixture.registry.outputResourceContextSnapshot() == nil }
            XCTAssertEqual(fixture.driver.plays, 1)
        }
    }

    func testPausedFormatContradictionAndHeldReconnectCannotResumeWithOldSnapshot() async throws {
        for holdReconnect in [false, true] {
            try await NativeAdapterFixture.withFixture { fixture in
                fixture.play(); try await fixture.until { fixture.isPlaying }
                await fixture.controller.setPaused(true)
                try await fixture.until { fixture.driver.disconnectedFromSystemAudio }
                if holdReconnect {
                    let gate = NativeFixtureGate(); fixture.gates.append(gate); fixture.driver.connectionGate = gate
                    fixture.spawn { await fixture.controller.setPaused(false) }
                    try await fixture.until { gate.entered }
                    fixture.inspector.rejectFormat = true
                    gate.release()
                } else {
                    fixture.inspector.rejectFormat = true
                    fixture.spawn { await fixture.controller.setPaused(false) }
                }
                try await fixture.until { fixture.registry.outputResourceContextSnapshot() == nil }
                XCTAssertEqual(fixture.driver.plays, 1, "Same-size format contradiction must be checked before resumed play")
            }
        }
    }

    func testKnownVariantAndAlternateSelectionDuringHeldLoadGetOneFreshStableSnapshot() async throws {
        try await NativeAdapterFixture.withFixture { fixture in
            let preparing = fixture.hold(.format)
            fixture.play(); try await fixture.until { preparing.entered }
            fixture.driver.selectionRevision += 1
            fixture.inspector.useAlternate = true
            preparing.release()
            try await fixture.until { fixture.isPlaying }
            let original = try XCTUnwrap(fixture.registry.outputResourceContextSnapshot())
            let backend = try XCTUnwrap(fixture.factory.backend)
            XCTAssertGreaterThanOrEqual(fixture.inspector.reads, 2)
            XCTAssertEqual(fixture.driver.installs, 1)
            let runtime = NativeFixtureGate(); fixture.gates.append(runtime); fixture.inspector.gate = runtime
            let coordinator = try XCTUnwrap(backend.nativeCoordinatorForTesting)
            let oldReads = fixture.inspector.reads
            fixture.spawn { await coordinator.observeSelectedFormatChangeForTesting() }
            try await fixture.until { runtime.entered }
            fixture.driver.selectionRevision += 1
            fixture.driver.selectedAudio = NSObject()
            fixture.inspector.useAlternate = false
            runtime.release()
            try await fixture.until {
                fixture.inspector.reads >= oldReads + 2 &&
                    backend.preparedMediaInformation(for: coordinator.item.outputLifecycleEpoch)?.information?.width == 1_920
            }
            XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.prepareTicket, original.prepareTicket)
            XCTAssertEqual(fixture.registry.outputResourceContextSnapshot()?.activation, original.activation)
            XCTAssertEqual(fixture.driver.installs, 1)
            XCTAssertEqual(fixture.driver.plays, 1)
            XCTAssertEqual(backend.preparedMediaInformation(for: coordinator.item.outputLifecycleEpoch)?.information?.width, 1_920)
        }
    }

    func testMissingExpectedAudioStillFailsBeforePlayWithoutSelectionRetry() async throws {
        try await NativeAdapterFixture.withFixture { fixture in
            fixture.inspector.missingExpectedAudio = true
            fixture.play()
            try await fixture.until { fixture.factory.backend != nil && fixture.registry.outputResourceContextSnapshot() == nil }
            XCTAssertEqual(fixture.driver.plays, 0)
            XCTAssertEqual(fixture.inspector.reads, 1)
        }
    }

    func testOwnedCompressedInitRejectionJoinsBeforeOneAACAttemptAndSecondFailureIsTerminal() async throws {
        try await NativeAdapterFixture.withFixture(generated: true) { fixture in
            let retirement = NativeFixtureGate(); fixture.gates.append(retirement)
            fixture.factory.retry.retirementGate = retirement
            fixture.play()
            try await fixture.until { retirement.entered }
            XCTAssertEqual(fixture.factory.retry.decisions, [.passthrough(.ac3)])
            XCTAssertEqual(fixture.factory.retry.accepted, [true])
            XCTAssertEqual(fixture.driver.installs, 0)
            let original = try XCTUnwrap(fixture.factory.retry.firstOwner)
            let rejection = try XCTUnwrap(original.audioRejectionRecord())
            XCTAssertTrue(rejection.matches(try compatibleCandidate(from: original, newSignature: true)))
            XCTAssertFalse(rejection.matches(try compatibleCandidate(from: original, differentLayout: true)))
            XCTAssertFalse(rejection.matches(try compatibleCandidate(from: original, differentRequest: true)))
            retirement.release()
            try await fixture.until { fixture.factory.retry.decisions.count == 2 && fixture.registry.outputResourceContextSnapshot() == nil }
            XCTAssertEqual(fixture.factory.retry.decisions, [.passthrough(.ac3), .compatibleAAC])
            XCTAssertEqual(fixture.factory.retry.accepted, [true, false], "Second fallback failure cannot claim another compatible retry")
            XCTAssertEqual(fixture.factory.retry.retired, 2)
            XCTAssertEqual(fixture.driver.installs, 0)
            XCTAssertFalse(original.requestCompatibleAudioGeneration(), "A retired failed attempt cannot poison its successor")
            XCTAssertEqual(fixture.factory.backend?.generatedBundleCallsForTesting, 2)
        }
    }

    func testNativeMetadataChangesReachControllerStreamAndPauseInvalidatesSameLifecycle() async throws {
        try await NativeAdapterFixture.withFixture { fixture in
            let stream = await fixture.controller.playbackMediaInformation()
            fixture.spawn {
                for await information in stream {
                    fixture.metadata.append(information)
                    if Task.isCancelled { break }
                }
            }
            fixture.play(); try await fixture.until { fixture.isPlaying && fixture.metadata.contains { $0?.width == 1_920 } }
            let coordinator = try XCTUnwrap(fixture.factory.backend?.nativeCoordinatorForTesting)
            fixture.inspector.useAlternate = true
            await coordinator.observeSelectedFormatChangeForTesting()
            try await fixture.until { fixture.metadata.last??.width == 1_280 }
            await fixture.controller.setPaused(true)
            try await fixture.until { fixture.metadata.last != nil && fixture.metadata.last! == nil }
            let count = fixture.metadata.count
            await coordinator.observeSelectedFormatChangeForTesting()
            XCTAssertEqual(fixture.metadata.count, count, "Paused stale events cannot republish the prior activation")
        }
    }
    private func compatibleCandidate(from original: HLSOwnedSourcePlan, newSignature: Bool = false,
                                     differentLayout: Bool = false, differentRequest: Bool = false) throws -> HLSOwnedSourcePlan {
        let previous = try original.selectedMediaFacts()
        let request = differentRequest ? UUID() : original.source.context.requestID
        let session = PlaybackSessionIdentity(sessionID: differentRequest ? 999 : original.plan.owner.backendIdentity.sessionIdentity.sessionID, requestID: request)
        let backend = PlaybackBackendIdentity(sessionIdentity: session, backendGeneration: original.plan.owner.backendIdentity.backendGeneration)
        let owner = PlaybackSourceOwner(backendIdentity: backend, prepareNonce: 2, outputLifecycleNonce: 2)
        let url = newSignature ? URL(string: "https://native-fixture.invalid/master?signature=refreshed")! : original.source.responseURL
        let context = try PlaybackSourceContext(requestID: request, sourceProfileID: original.source.context.sourceProfileID,
            channelID: original.source.context.channelID, entryURL: url).bound(to: owner)
        let source = ResolvedPlaybackSource(context: context, responseURL: url, generation: 2, topology: .media(Data([0x47])))
        let audio = HLSSourceAudioFacts(codec: .ac3, profile: 8, sampleRate: 48_000,
            channelCount: differentLayout ? 2 : 6, channelMask: differentLayout ? 3 : 0x3F,
            priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true)
        let facts = HLSCompatibilityFacts(source: source, media: [.init(url: url, container: .mpegTS,
            video: previous.video, audio: [audio], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 188)
        let candidate = HLSCompressedAudioAdmissionCandidate(codec: .ac3, profile: 8, sampleRate: audio.sampleRate,
            channelCount: audio.channelCount, channelMask: audio.channelMask, decoderConfiguration: Data(),
            outputRouteIdentifier: "fresh-preparation-scope", requiresAACCompatibilityRendition: false)
        let plan = HLSPlaybackPlan(owner: owner, resolutionGeneration: 2, transport: .generated, video: .remux,
            audio: .passthrough(.ac3), selectedServiceURL: url, formatFingerprint: facts.formatFingerprint,
            compressedAudioAdmissionCandidate: candidate)
        return try .init(source: source, facts: facts, plan: plan, resolver: original.resolver,
            sourceCharge: original.sourceCharge, factsCharge: HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention))
    }

}

/// Every exit, including assertion helper timeout and a throwing test body,
/// releases gates and joins tasks before Registry/controller teardown finishes.
@MainActor
private final class NativeAdapterFixture {
    enum Phase: CaseIterable { case probe, ready, preroll, format }
    let registry: ControlTaskRegistry
    let controller: PlaybackController
    let driver = NativeFixtureDriver()
    let inspector: NativeFixtureInspector
    let factory: NativeFixtureFactory
    let probe = NativeFixtureProbe()
    var gates: [NativeFixtureGate] = []
    var tasks: [Task<Void, Never>] = []
    var metadata: [PlaybackMediaInformation?] = []
    var cleanupCompleted = false
    private let manualClock: ManualPlaybackClock?
    private init(generated: Bool, clock: ManualPlaybackClock?) throws {
        manualClock = clock
        registry = clock.map { ControlTaskRegistry(allocator: PlaybackIdentityAllocator(), clock: $0) } ?? ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        inspector = NativeFixtureInspector(driver: driver)
        probe.generated = generated
        factory = NativeFixtureFactory(driver: driver, inspector: inspector, probe: probe, generated: generated)
        let sdk = FakeAudioSessionSDK(initialPorts: .airPlay)
        let monitor = SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress, notificationCenter: NotificationCenter())
        let owner = try PlaybackAudioSessionOwner(registry: registry, sdk: sdk, monitor: monitor)
        controller = PlaybackController(registry: registry, audioSessionOwner: owner,
            routeService: PlaybackAudioRouteService(registry: registry, owner: owner), backendFactory: factory)
    }
    static func withFixture(generated: Bool = false, clock: ManualPlaybackClock? = nil,
                            _ body: (NativeAdapterFixture) async throws -> Void) async throws {
        let fixture = try NativeAdapterFixture(generated: generated, clock: clock)
        var failure: (any Error)?
        do { try await body(fixture) } catch { failure = error }
        fixture.gates.forEach { $0.release() }
        fixture.tasks.forEach { $0.cancel() }
        for task in fixture.tasks { await task.value }
        await fixture.controller.stop()
        await fixture.registry.joinOwnedTerminalCleanup()
        fixture.factory.backend = nil
        fixture.tasks.removeAll(); fixture.metadata.removeAll()
        fixture.cleanupCompleted = true
        XCTAssertNil(fixture.driver.currentItemIdentity)
        XCTAssertEqual(fixture.driver.rate, 0)
        XCTAssertNil(fixture.registry.outputResourceContextSnapshot())
        if let failure { throw failure }
    }
    var isPlaying: Bool {
        let context = registry.outputResourceContextSnapshot()
        guard let context, let task = context.sourceTask else { return false }
        return context.prepared && context.interval != nil && registry.phase(of: task) == .terminal(.completed)
            && driver.rate > 0 && driver.currentItemIdentity != nil
    }
    func spawn(_ body: @escaping @MainActor () async -> Void) { tasks.append(Task { await body() }) }
    func play() {
        spawn { await self.controller.play(.init(sourceProfileID: UUID(), channelID: "native-fixture",
            streamURL: NativeFixtureFactory.rootURL, title: "Native fixture")) }
    }
    func hold(_ phase: Phase) -> NativeFixtureGate {
        let gate = NativeFixtureGate(); gates.append(gate)
        switch phase {
        case .probe: probe.gate = gate
        case .ready: driver.readyGate = gate
        case .preroll: driver.prerollGate = gate
        case .format: inspector.gate = gate
        }
        return gate
    }
    func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            if let manualClock, case .pending(let pending) = registry.outputRouteObservationSnapshot(),
               let observation = pending.ticket, let stability = try registry.armOutputRouteStability(observation: observation) {
                manualClock.set(max(manualClock.nowNanoseconds, stability.deadlineInstant))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard predicate() else {
            XCTFail("Native fixture timed out: \(String(describing: registry.outputResourceContextSnapshot()))")
            throw HLSSourceError.deadline
        }
    }
}

private final class NativeFixtureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false, enteredValue = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var entered: Bool { lock.withLock { enteredValue } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                enteredValue = true
                if open { return true }
                precondition(waiters.count < 4)
                waiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
    func release() {
        let values = lock.withLock { let values = waiters; waiters.removeAll(); open = true; return values }
        values.forEach { $0.resume() }
    }
}

@MainActor
private final class NativeFixtureFactory: PlaybackBackendFactory, @unchecked Sendable {
    nonisolated static let rootURL = URL(string: "https://native-fixture.invalid/master")!
    var backend: HLSAVPlayerPlaybackBackend?
    private let driver: NativeFixtureDriver
    private let inspector: NativeFixtureInspector
    private let probe: NativeFixtureProbe
    private let generated: Bool
    let retry = NativeRetryRecorder()
    init(driver: NativeFixtureDriver, inspector: NativeFixtureInspector, probe: NativeFixtureProbe, generated: Bool) {
        self.driver = driver; self.inspector = inspector; self.probe = probe; self.generated = generated
    }
    nonisolated func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        throw HLSSourceError.unboundOwner
    }
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
        channelID: String, url: URL, sourceContext: PlaybackSourceContext?,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        let context = try XCTUnwrap(sourceContext)
        let media = URL(string: "https://native-fixture.invalid/media")!
        let alternate = URL(string: "https://native-fixture.invalid/alternate")!
        let root = generated ? "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n" :
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nmedia\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nalternate\n"
        let transport = SourceTestTransport(responses: [url: .init(responseURL: url, data: Data(root.utf8)),
            media: .init(responseURL: media, data: Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n".utf8)),
            alternate: .init(responseURL: alternate, data: Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n".utf8))])
        var dependencies = HLSNativeSourceDependencies(context: context)
        dependencies.makeResolver = { URLSessionPlaybackSourceResolver(transport: transport) }
        dependencies.probe = probe
        dependencies.makeInspector = { [inspector] _ in inspector }
        if generated {
            dependencies.capabilities = { _, _ in
                .init(videoProfiles: [.h264: [100]], compressedAudioCodecs: [.ac3],
                    compressedAudioAdmissionCandidates: [.init(codec: .ac3, profile: 8, sampleRate: 48_000,
                        channelCount: 6, channelMask: 0x3F, decoderConfiguration: Data(),
                        outputRouteIdentifier: "bounded-fixture-candidate", requiresAACCompatibilityRendition: false)], supportsGenerated: true)
            }
        } else { dependencies.capabilities = { _, _ in NativeFixtureProbe.capabilities } }
        let lease = try HomePodAVPlayerSession(identity: identity.sessionIdentity, driver: driver).claim(backend: identity)
        let slot = ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot()
        let backend = HLSAVPlayerPlaybackBackend(identity: identity,
            bundleBuilder: try SystemHLSOutputItemBundleBuilder(validating: url),
            coordinatorFactory: { _ in throw HLSSourceError.unsupportedMedia }, replacementSlot: slot)
        backend.configureSourceRouting(dependencies: dependencies, sessionLease: lease,
            builderFactory: { [retry] _, owned in
                guard let owned else { throw HLSSourceError.unboundOwner }
                return NativeRetryBuilder(owned: owned, recorder: retry)
            }, eventSink: eventSink)
        self.backend = backend
        return backend
    }
}

private final class NativeFixtureProbe: HLSCompatibilityProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var gateValue: NativeFixtureGate?
    private var generatedValue = false
    var generated: Bool { get { lock.withLock { generatedValue } } set { lock.withLock { generatedValue = newValue } } }
    var gate: NativeFixtureGate? { get { lock.withLock { gateValue } } set { lock.withLock { gateValue = newValue } } }
    static func video(width: Int32 = 1_920) -> HLSVideoFacts {
        .init(codec: .h264, profile: 100, scan: .progressive, parameterSetsValidated: true,
            configurationFingerprint: Data([UInt8(width == 1_920 ? 1 : 2)]), width: width, height: width == 1_920 ? 1_080 : 720,
            chromaFormat: 1, bitDepth: 8, level: 40, parserProgressiveFrames: 2, compatibilityFlags: 0,
            tier: .main, frameRate: MediaRational(num: 25, den: 1), videoRange: .sdr,
            colorPrimaries: .bt709, colorTransfer: .bt709, colorMatrix: .bt709, sampleEntry: "avc1")
    }
    static let audio = HLSSourceAudioFacts(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2,
        channelMask: 3, decoderConfiguration: Data([0x11, 0x90]), priming: .notSignaledPreserveTimestamps,
        service: .independentMain, formatValidated: true)
    static var capabilities: HLSOutputCapabilities {
        .init(videoProfiles: [.h264: [100]], videoFormats: [.init(codec: .h264, profiles: [100], maximumLevel: 52,
            maximumWidth: 1_920, maximumHeight: 1_080, maximumFrameRate: MediaRational(num: 60, den: 1)!,
            bitDepths: [8], chromaFormats: [1], tiers: [.main], videoRanges: [.sdr])], nativeAudioCodecs: [.aac], supportsGenerated: true)
    }
    func inspect(_ source: ResolvedPlaybackSource) async throws -> HLSCompatibilityFacts {
        await gate?.wait()
        guard case let .hls(graph) = source.topology else { throw HLSSourceError.unsupportedMedia }
        let audio = generated ? HLSSourceAudioFacts(codec: .ac3, profile: 8, sampleRate: 48_000, channelCount: 6,
            channelMask: 0x3F, priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true) : Self.audio
        let media = graph.orderedDocuments.filter { $0.kind == .media }.map {
            HLSMediaFacts(url: $0.responseURL, container: .mpegTS, video: Self.video(width: $0.responseURL.path == "/alternate" ? 1_280 : 1_920), audio: [audio], hasUnsupportedTracks: false)
        }
        return .init(source: source, media: media, complete: true, inspectedBytes: 188)
    }
}

@MainActor
private final class NativeFixtureInspector: NativeHLSAssetInspecting {
    private let driver: NativeFixtureDriver
    var gate: NativeFixtureGate?
    var reads = 0, useAlternate = false, rejectFormat = false, missingExpectedAudio = false
    init(driver: NativeFixtureDriver) { self.driver = driver }
    func snapshot(item: AVPlayerItemInstanceIdentity, source: HLSOwnedSourcePlan) async throws -> NativeHLSSelectionSnapshot {
        reads += 1
        let physical = try XCTUnwrap(driver.physical), selection = driver.selectionRevision
        await gate?.wait()
        guard source.isCurrent, driver.currentItemIdentity == item, driver.physical === physical,
              driver.selectionRevision == selection else { throw AVPlayerItemCoordinatorFailure.selectionChanged }
        guard !rejectFormat, !missingExpectedAudio else { throw HLSSourceError.incompleteEvidence }
        return try .init(item: item, physicalItem: ObjectIdentifier(physical), audioSelection: ObjectIdentifier(driver.selectedAudio),
            video: NativeFixtureProbe.video(width: useAlternate ? 1_280 : 1_920), audio: NativeFixtureProbe.audio,
            audioConfigurationDigest: Data([1]), observedFrameRate: 25, sourceOwner: source,
            retention: HLSApplicationLifetimeCharge(bytes: 8 * 1_024))
    }
}

@MainActor
private final class NativeFixtureDriver: AVPlayerDriving {
    var disconnectedFromSystemAudio = true
    var rate: Float = 0
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var currentItemIdentity: AVPlayerItemInstanceIdentity?
    var physical: NSObject?
    var selectedAudio = NSObject()
    var readyGate: NativeFixtureGate?, prerollGate: NativeFixtureGate?, connectionGate: NativeFixtureGate?
    var installs = 0, prerolls = 0, plays = 0, joins = 0, selectionRevision = 0
    var failReady = false
    var lastPositiveInvocation: ControlTaskRegistry.BackendPositiveRateInvocation?
    private var clock = ExactMediaTime(value: 0, timescale: 1)
    func advanceMedia(to time: ExactMediaTime) { clock = time }
    func install(url: URL, identity: AVPlayerItemInstanceIdentity) throws { throw HLSSourceError.unboundOwner }
    func install(url: URL, identity: AVPlayerItemInstanceIdentity, admission: AVPlayerInstallationMutation) throws {
        guard try admission({ currentItemIdentity = identity; physical = NSObject(); installs += 1 }) else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
    }
    func setDisconnectedFromSystemAudio(_ disconnected: Bool, item: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) {
        if !disconnected { await connectionGate?.wait() }
        guard item == currentItemIdentity else { throw .staleIdentity }
        disconnectedFromSystemAudio = disconnected
    }
    func waitUntilReady(item: AVPlayerItemInstanceIdentity) async throws -> AVPlayerItemInstanceIdentity {
        await readyGate?.wait()
        if failReady { throw HLSSourceError.network }
        return item
    }
    func primeMediaData(item: AVPlayerItemInstanceIdentity) async throws { prerolls += 1; await prerollGate?.wait() }
    func joinNativeCallbackTails() async { joins += 1 }
    func seekNative(to time: ExactMediaTime, item: AVPlayerItemInstanceIdentity) async throws -> ExactMediaTime { clock = time; return time }
    func reservePausedResumeCallbacks(item: AVPlayerItemInstanceIdentity) throws {}
    func play(invocation: ControlTaskRegistry.BackendPositiveRateInvocation, item: AVPlayerItemInstanceIdentity) async throws {
        guard invocation.revalidateCurrentAuthority(), currentItemIdentity == item else { throw AVPlayerItemCoordinatorFailure.staleIdentity }
        lastPositiveInvocation = invocation
        rate = 1; timeControlStatus = .playing; plays += 1
    }
    func playbackClockObservation(item: AVPlayerItemInstanceIdentity) -> AVPlayerPlaybackClockObservation { item == currentItemIdentity ? .currentItem(clock) : .staleItem }
    func pausedTime(item: AVPlayerItemInstanceIdentity) -> ExactMediaTime? { item == currentItemIdentity ? clock : nil }
    func pausedItemObjectIdentity(item: AVPlayerItemInstanceIdentity) -> ObjectIdentifier? { item == currentItemIdentity ? physical.map(ObjectIdentifier.init) : nil }
    func cancelPendingPrerolls(item: AVPlayerItemInstanceIdentity) {}
    func pause(item: AVPlayerItemInstanceIdentity) { if currentItemIdentity == item { rate = 0; timeControlStatus = .paused } }
    func waitUntilPaused(item: AVPlayerItemInstanceIdentity) async throws {}
    func directState(item: AVPlayerItemInstanceIdentity) async throws(AVPlayerItemCoordinatorFailure) -> AVPlayerDirectState {
        guard currentItemIdentity == item else { throw .staleIdentity }
        return .init(item: item, rate: rate, timeControlStatus: timeControlStatus)
    }
    func replaceCurrentItemWithNil(item: AVPlayerItemInstanceIdentity) { if currentItemIdentity == item { currentItemIdentity = nil; physical = nil } }
    func removeObservers(item: AVPlayerItemInstanceIdentity) {}
    func constrainPlaybackEnd(to time: ExactMediaTime, item: AVPlayerItemInstanceIdentity) throws {}
    func installNaturalEndTerminalHandler(item: AVPlayerItemInstanceIdentity, handler: @escaping @MainActor @Sendable (AVPlayerNaturalEndTerminalCapability, AVPlayerItemInstanceIdentity) -> Void) throws {}
    func consumeNaturalEndTerminal(_ capability: AVPlayerNaturalEndTerminalCapability, item: AVPlayerItemInstanceIdentity) -> AVPlayerNaturalEndTerminalResult? { nil }
    func installTimeControlStatusRelay(item: AVPlayerItemInstanceIdentity, activation: ActivationEpoch, handler: @escaping @MainActor @Sendable (AVPlayer.TimeControlStatus, AVPlayerItemInstanceIdentity, ActivationEpoch) -> Void) throws {}
    func installAccessLogURIObservation(item: AVPlayerItemInstanceIdentity, classify: @escaping @Sendable (URL) -> AccessLogURIClassification, handler: @escaping @MainActor @Sendable (AccessLogURIClassification, AVPlayerItemInstanceIdentity) -> Void) throws {}
    func preparationFenceReached(_ fence: AVPlayerPreparationFence, item: AVPlayerItemInstanceIdentity) {}
    func seek(to time: ExactMediaTime, item: AVPlayerItemInstanceIdentity, playhead: PreparedPlayheadIdentity) async throws -> AVPlayerSeekReceipt { throw HLSSourceError.unsupportedMedia }
    func waitForLoadedTimeRanges(item: AVPlayerItemInstanceIdentity, playhead: PreparedPlayheadIdentity, covering requested: ExactMediaInterval) async throws -> AVPlayerLoadedRangeReceipt { throw HLSSourceError.unsupportedMedia }
    func preroll(item: AVPlayerItemInstanceIdentity, playhead: PreparedPlayheadIdentity) async throws -> AVPlayerPrerollReceipt { throw HLSSourceError.unsupportedMedia }
}

private final class NativeRetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var decisionsValue: [HLSAudioDecision] = [], acceptedValue: [Bool] = []
    private var retiredValue = 0
    private var owner: HLSOwnedSourcePlan?
    private var gate: NativeFixtureGate?
    var decisions: [HLSAudioDecision] { lock.withLock { decisionsValue } }
    var accepted: [Bool] { lock.withLock { acceptedValue } }
    var retired: Int { lock.withLock { retiredValue } }
    var firstOwner: HLSOwnedSourcePlan? { lock.withLock { owner } }
    var retirementGate: NativeFixtureGate? { get { lock.withLock { gate } } set { lock.withLock { gate = newValue } } }
    func record(_ source: HLSOwnedSourcePlan) {
        lock.withLock { precondition(decisionsValue.count < 3); decisionsValue.append(source.plan.audio); if owner == nil { owner = source } }
    }
    func reject(_ source: HLSOwnedSourcePlan) {
        let accepted = source.requestCompatibleAudioGeneration()
        lock.withLock { precondition(acceptedValue.count < 3); acceptedValue.append(accepted) }
    }
    func retire() async -> Bool {
        await retirementGate?.wait()
        lock.withLock { retiredValue += 1 }
        return true
    }
}
private struct NativeRetryBuilder: HLSOutputItemBundleBuilding {
    let owned: HLSOwnedSourcePlan
    let recorder: NativeRetryRecorder
    func makeBundle(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws -> HLSOutputItemBundle {
        recorder.record(owned)
        return HLSOutputItemBundle(startProducer: {
            recorder.reject(owned)
            throw HLSSourceError.unsupportedMedia
        }, retireProducer: { await recorder.retire() })
    }
}
