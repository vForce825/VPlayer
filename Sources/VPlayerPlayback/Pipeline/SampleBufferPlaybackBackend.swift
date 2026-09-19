// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

final class SampleBufferPlaybackBackend: PlaybackBackend,
    SampleBufferQuiescenceIssuerInstalling, @unchecked Sendable {
    let identity: PlaybackBackendIdentity
    private let factory: any PlaybackPipelineFactory
    private let tuning: PlaybackTuning
    private let channelID: String
    private let url: URL
    private let eventSink: (@Sendable (PlaybackPipelineEvent) -> Void)?
    private let quiescenceLock = NSLock()
    private var quiescenceIssuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer?
    
    private(set) var pipeline: (any PlaybackPipelineProtocol)?

    var presentation: PlaybackPresentation? {
        pipeline?.presentationContext.map(PlaybackPresentation.sampleBuffer)
    }
    
    init(
        identity: PlaybackBackendIdentity,
        factory: any PlaybackPipelineFactory,
        tuning: PlaybackTuning,
        channelID: String,
        url: URL,
        eventSink: (@Sendable (PlaybackPipelineEvent) -> Void)? = nil
    ) {
        self.identity = identity
        self.factory = factory
        self.tuning = tuning
        self.channelID = channelID
        self.url = url
        self.eventSink = eventSink
    }
    
    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("sb_prepare_start")
        #endif
        let sink = self.eventSink
        let p = try await factory.makePipeline(tuning: tuning, channelID: channelID) { event in
            sink?(event)
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("sb_prepare_pipeline_made")
        #endif
        self.pipeline = p
    }

    func startPipeline(readinessCycle: UInt64, initiallyPaused: Bool) {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("sb_startPipeline_pipeline_\(pipeline != nil)")
        #endif
        pipeline?.start(url: url, readinessCycle: readinessCycle, initiallyPaused: initiallyPaused)
        if initiallyPaused {
            pipeline?.setPlaybackRate(0.0)
        }
    }
    
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws {
        _ = invocation.ticket
        pipeline?.setPlaybackRate(0.0)
    }
    
    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws {
        guard invocation.performPositiveRateSideEffect({
            pipeline?.setPlaybackRate(1.0)
        }) else {
            throw PlaybackCoreError.demuxOpen(-1)
        }
    }

    func installSampleBufferQuiescenceIssuer(
        _ issuer: ControlTaskRegistry.SampleBufferQuiescenceIssuer
    ) {
        quiescenceLock.withLock { quiescenceIssuer = issuer }
    }
    
    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async -> BackendSuspendResult {
        guard let rateOwner = pipeline as? any SampleBufferPlaybackRateOwner,
              let observedRate = await rateOwner.setRateZeroAndReadBack(),
              let issuer = quiescenceLock.withLock({ quiescenceIssuer }),
              let proof = issuer.issue(
                backendIdentity: identity,
                invocation: invocation,
                observedRate: observedRate,
                preparedPreserved: true) else {
            return .requiresRetirement
        }
        return .quiescent(proof)
    }
    
    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult {
        await pipeline?.stop()
        pipeline = nil
        quiescenceLock.withLock { quiescenceIssuer = nil }
        return .confirmedLocalOutputStopped
    }
}

extension PlaybackBackend {
    func metricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot? {
        if let sbpb = self as? SampleBufferPlaybackBackend {
            return sbpb.pipeline?.metricsSnapshot(window: window)
        }
        if let hlspb = self as? HLSAVPlayerPlaybackBackend {
            return hlspb.metricsSnapshot(window: window)
        }
        return nil
    }

    var terminalMetricsProvider: (any PlaybackTerminalMetricsProviding)? {
        (self as? SampleBufferPlaybackBackend)?.pipeline?.terminalMetricsProvider
    }
}
