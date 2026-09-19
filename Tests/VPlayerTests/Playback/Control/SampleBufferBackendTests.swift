// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class SampleBufferBackendTests: XCTestCase {
    func testLifecycleTransitions() async throws {
        let harness = BackendTestHarness.sampleBuffer()
        try await harness.prepare(initiallyPaused: true)
        XCTAssertTrue(harness.isPrepared)
        XCTAssertEqual(harness.clockRate, 0)
        await harness.activateCurrentPermit()
        XCTAssertEqual(harness.clockRate, 1)
        await harness.suspendAndConfirm()
        XCTAssertEqual(harness.clockRate, 0)
    }

    func testFinalSampleBufferRateZeroRequiresPrivateIssuerAndRejectsBooleanReplayAndWrongIncarnation()
        async throws {
        let sticky = try await FinalSampleBufferBackendProbe.make(honorsRateZero: false)
        let stickyResult = await sticky.runSuspend()
        if case .succeeded = stickyResult {
            XCTFail("pipeline 忽略 rate=0 时，caller bool/普通 proof 不能关闭 interval")
        }
        XCTAssertEqual(sticky.backend.physicalRate, 1,
                       "拒绝路径必须保持真实 SampleBuffer pipeline 物理时钟非零")
        XCTAssertNotNil(sticky.graph.registry.outputResourceContextSnapshot()?.interval)
        XCTAssertNil(sticky.backend.lastProof,
                     "未静止的 pipeline 不得为了兼容 caller bool 而签发 opaque proof")

        let consumed = try await FinalSampleBufferBackendProbe.make(
            honorsRateZero: true, holdQuiescenceProof: true)
        let consumedOwner = try await consumed.beginSuspend()
        XCTAssertTrue(consumed.graph.registry.startOutputSuspendOperation(
            consumedOwner.suspend.task, owner: consumedOwner.owner))
        await consumed.backend.waitForHeldProof()
        let consumedInvocation = try XCTUnwrap(consumed.backend.lastInvocation)
        let consumedProof = try XCTUnwrap(consumed.backend.lastProof)
        XCTAssertTrue(consumed.graph.registry.completeOutputSuspend(
            .quiescent(consumedProof), invocation: consumedInvocation,
            backend: consumed.backend),
            "真实 rate-zero pipeline 私有 issuer 的 proof 首次消费必须关闭 interval")
        XCTAssertFalse(consumed.graph.registry.completeOutputSuspend(
            .quiescent(consumedProof), invocation: consumedInvocation,
            backend: consumed.backend),
            "同一 opaque proof 重放必须失败")

        let wrongIncarnation = try await FinalSampleBufferBackendProbe.make(
            honorsRateZero: true, holdQuiescenceProof: true)
        let wrongOwner = try await wrongIncarnation.beginSuspend()
        XCTAssertTrue(wrongIncarnation.graph.registry.startOutputSuspendOperation(
            wrongOwner.suspend.task, owner: wrongOwner.owner))
        await wrongIncarnation.backend.waitForHeldProof()
        let wrongInvocation = try XCTUnwrap(wrongIncarnation.backend.lastInvocation)
        let unconsumedProof = try XCTUnwrap(wrongIncarnation.backend.lastProof)
        let wrong = FinalWrongIncarnationBackend(identity: .init(
            sessionIdentity: wrongIncarnation.backend.identity.sessionIdentity,
            backendGeneration: wrongIncarnation.backend.identity.backendGeneration + 1))
        XCTAssertFalse(wrongIncarnation.graph.registry.completeOutputSuspend(
            .quiescent(unconsumedProof), invocation: wrongInvocation, backend: wrong),
            "错 backend incarnation 不得抢先消费尚未使用的真实静止证明")
        XCTAssertTrue(wrongIncarnation.graph.registry.completeOutputSuspend(
            .quiescent(unconsumedProof), invocation: wrongInvocation,
            backend: wrongIncarnation.backend),
            "错 incarnation 拒绝后，同一未消费 proof 仍须可由正确 backend 首次消费")

        await consumed.backend.releaseHeldProof()
        await wrongIncarnation.backend.releaseHeldProof()
        _ = await consumed.graph.registry.joinOutputBackendOperation(
            consumedOwner.suspend.task)
        _ = await wrongIncarnation.graph.registry.joinOutputBackendOperation(
            wrongOwner.suspend.task)
    }
}

private final class FinalSampleBufferBackendProbe: PlaybackBackend,
    SampleBufferQuiescenceIssuerInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let pipeline: FinalRatePipeline
    private let proofGate: FinalQuiescenceProofGate?
    private var configuredIdentity = PlaybackBackendIdentity(
        sessionIdentity: .init(sessionID: 0, requestID: UUID()), backendGeneration: 0)
    private var inner: SampleBufferPlaybackBackend?
    private var pendingIssuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer?
    private(set) var lastProof: ControlTaskRegistry.BackendQuiescenceProof?
    private(set) var lastInvocation: ControlTaskRegistry.BackendSuspendInvocation?

    var identity: PlaybackBackendIdentity { lock.withLock { configuredIdentity } }
    var presentation: PlaybackPresentation? { inner?.presentation }
    var physicalRate: Float { pipeline.rate }

    init(honorsRateZero: Bool, holdQuiescenceProof: Bool = false) {
        pipeline = FinalRatePipeline(honorsRateZero: honorsRateZero)
        proofGate = holdQuiescenceProof ? FinalQuiescenceProofGate() : nil
    }

    func configure(identity: PlaybackBackendIdentity) {
        lock.withLock { configuredIdentity = identity }
        inner = SampleBufferPlaybackBackend(identity: identity,
            factory: FinalRatePipelineFactory(pipeline: pipeline),
            tuning: .default, channelID: "final-sample-buffer",
            url: URL(string: "http://127.0.0.1/final-sample-buffer")!)
        if let pendingIssuer {
            inner?.installSampleBufferQuiescenceIssuer(pendingIssuer)
        }
    }

    func installSampleBufferQuiescenceIssuer(
        _ issuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer
    ) {
        pendingIssuer = issuer
        inner?.installSampleBufferQuiescenceIssuer(issuer)
    }

    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        guard let inner else { throw PlaybackCoreError.demuxOpen(-1) }
        try await inner.prepare(invocation: invocation)
        inner.startPipeline(readinessCycle: 1, initiallyPaused: true)
    }
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        try await inner?.reprepare(invocation: invocation)
    }
    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {
        try await inner?.activateOutput(invocation: invocation)
    }
    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async
        -> BackendSuspendResult {
        guard let inner else { return .requiresRetirement }
        let result = await inner.suspendOutput(invocation: invocation)
        lastInvocation = invocation
        if case .quiescent(let proof) = result {
            lastProof = proof
            await proofGate?.hold()
        }
        return result
    }
    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        await inner?.retireOutput(epoch: epoch) ?? .confirmedLocalOutputStopped
    }

    func waitForHeldProof() async { await proofGate?.waitUntilHeld() }
    func releaseHeldProof() async { await proofGate?.release() }
}

private final class FinalRatePipelineFactory: PlaybackPipelineFactory, @unchecked Sendable {
    let pipeline: FinalRatePipeline
    init(pipeline: FinalRatePipeline) { self.pipeline = pipeline }
    func makePipeline(tuning: PlaybackTuning, channelID: String,
                      eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws
        -> any PlaybackPipelineProtocol { pipeline }
}

private final class FinalRatePipeline: PlaybackPipelineProtocol,
    SampleBufferPlaybackRateOwner, @unchecked Sendable {
    private let lock = NSLock()
    private let honorsRateZero: Bool
    private var storedRate: Float = 0
    init(honorsRateZero: Bool) { self.honorsRateZero = honorsRateZero }
    var rate: Float { lock.withLock { storedRate } }
    var presentationContext: PlaybackPresentationContext? { PlaybackPresentationContext() }
    var terminalMetricsProvider: (any PlaybackTerminalMetricsProviding)? { nil }
    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot? { nil }
    func start(url: URL, readinessCycle: UInt64, initiallyPaused: Bool) {}
    func setPaused(_ paused: Bool, readinessCycle: UInt64) {}
    func setPlaybackRate(_ rate: Float) {
        lock.withLock {
            if rate > 0 || honorsRateZero { storedRate = rate }
        }
    }
    func setRateZeroAndReadBack() async -> Float? {
        setPlaybackRate(0)
        return rate
    }
    func recoverFromAudioSessionReset(readinessCycle: UInt64) {}
    func setTuning(_ tuning: PlaybackTuning) {}
    func stop() async {}
}

private actor FinalQuiescenceProofGate {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func hold() async {
        held = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

private extension FinalSampleBufferBackendProbe {
    struct Harness {
        let backend: FinalSampleBufferBackendProbe
        let graph: OutputGraphFixture

        func beginSuspend() async throws -> (
            owner: OutputTransitionOwnerTicket, suspend: OutputSuspendTicket
        ) {
            let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
            let owner = try XCTUnwrap(graph.coordinator.begin(
                contextNonce: context.contextNonce, reason: .pause,
                at: graph.registry.clock.nowNanoseconds))
            guard await graph.registry.joinOutputBackendOperations(owner: owner) else {
                throw PlaybackCoreError.demuxOpen(-1)
            }
            let suspend = try XCTUnwrap(
                graph.registry.outputResourceContextSnapshot()?.suspend)
            return (owner, suspend)
        }

        func runSuspend() async -> PlaybackBackendOperationResult {
            guard let pair = try? await beginSuspend(),
                  graph.registry.startOutputSuspendOperation(pair.suspend.task,
                                                            owner: pair.owner) else {
                return .canceled
            }
            return await graph.registry.joinOutputBackendOperation(pair.suspend.task)
        }
    }

    static func make(honorsRateZero: Bool, holdQuiescenceProof: Bool = false)
        async throws -> Harness {
        let backend = FinalSampleBufferBackendProbe(
            honorsRateZero: honorsRateZero,
            holdQuiescenceProof: holdQuiescenceProof)
        let graph = try OutputGraphFixture(backendObject: backend)
        backend.configure(identity: graph.lifecycle.backendIdentity)
        let source = try XCTUnwrap(
            graph.registry.outputResourceContextSnapshot()?.sourceTask)
        XCTAssertTrue(graph.registry.startOutputPrepareOperation(source))
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(source) else {
            throw PlaybackCoreError.demuxOpen(-1)
        }
        let context = try XCTUnwrap(graph.registry.outputResourceContextSnapshot())
        let activation = try XCTUnwrap(graph.registry.beginOutputActivation(
            contextNonce: context.contextNonce))
        XCTAssertTrue(graph.registry.startOutputActivationOperation(activation))
        guard case .succeeded = await graph.registry.joinOutputBackendOperation(activation) else {
            throw PlaybackCoreError.demuxOpen(-1)
        }
        return Harness(backend: backend, graph: graph)
    }
}

private final class FinalWrongIncarnationBackend: PlaybackBackend, @unchecked Sendable {
    let identity: PlaybackBackendIdentity
    init(identity: PlaybackBackendIdentity) { self.identity = identity }
    var presentation: PlaybackPresentation? { nil }
    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {}
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
    }
    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {}
    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async
        -> BackendSuspendResult { .requiresRetirement }
    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        .confirmedLocalOutputStopped
    }
}
