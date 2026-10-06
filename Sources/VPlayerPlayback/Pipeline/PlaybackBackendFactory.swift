// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

protocol PlaybackBackendFactory: Sendable {
    func makeBackend(
        kind: PlaybackBackendKind,
        identity: PlaybackBackendIdentity,
        tuning: PlaybackTuning,
        channelID: String,
        url: URL,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackBackend

    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
                     channelID: String, url: URL, sourceContext: PlaybackSourceContext?,
                     eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend
}

extension PlaybackBackendFactory {
    /// Existing injected factories keep their explicit legacy contract.
    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
                     channelID: String, url: URL, sourceContext: PlaybackSourceContext?,
                     eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        try await makeBackend(kind: kind, identity: identity, tuning: tuning, channelID: channelID, url: url, eventSink: eventSink)
    }

    func makeBackend(
        kind: PlaybackBackendKind,
        identity: PlaybackBackendIdentity,
        tuning: PlaybackTuning,
        channelID: String,
        url: URL
    ) async throws -> any PlaybackBackend {
        try await makeBackend(
            kind: kind,
            identity: identity,
            tuning: tuning,
            channelID: channelID,
            url: url,
            eventSink: { _ in }
        )
    }
}

final class SystemPlaybackBackendFactory: PlaybackBackendFactory, @unchecked Sendable {
    private let pipelineFactory: any PlaybackPipelineFactory
    /// 应用启动时注入唯一的 writer/publisher/store/server 装配 authority。没有 authority
    /// 时 AirPlay 仍创建 HLS backend，但 prepare 必须 fail-closed，绝不退回 SampleBuffer。
    private let hlsGraphFactory: SystemHLSOutputItemBundleBuilder.GraphFactory?
    private let hlsAcceptanceProbe: HLSWriterAcceptanceProbe?
    private let sourceDependencies: @Sendable (PlaybackSourceContext) -> HLSNativeSourceDependencies

    init(
        pipelineFactory: any PlaybackPipelineFactory = SystemPlaybackPipelineFactory(),
        hlsGraphFactory: SystemHLSOutputItemBundleBuilder.GraphFactory? = nil,
        hlsAcceptanceProbe: HLSWriterAcceptanceProbe? = nil,
        sourceDependencies: @escaping @Sendable (PlaybackSourceContext) -> HLSNativeSourceDependencies = { .init(context: $0) }
    ) {
        self.pipelineFactory = pipelineFactory
        self.hlsGraphFactory = hlsGraphFactory
        self.hlsAcceptanceProbe = hlsAcceptanceProbe
        self.sourceDependencies = sourceDependencies
    }

    func makeBackend(
        kind: PlaybackBackendKind,
        identity: PlaybackBackendIdentity,
        tuning: PlaybackTuning,
        channelID: String,
        url: URL,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackBackend {
        try await makeBackend(kind: kind, identity: identity, tuning: tuning, channelID: channelID,
            url: url, sourceContext: nil, eventSink: eventSink)
    }

    func makeBackend(kind: PlaybackBackendKind, identity: PlaybackBackendIdentity, tuning: PlaybackTuning,
                     channelID: String, url: URL, sourceContext: PlaybackSourceContext?,
                     eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void) async throws -> any PlaybackBackend {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("factory_making_\(kind)")
        #endif
        switch kind {
        case .sampleBuffer:
            return SampleBufferPlaybackBackend(
                identity: identity,
                factory: pipelineFactory,
                tuning: tuning,
                channelID: channelID,
                url: url,
                eventSink: eventSink
            )
        case .hlsAVPlayer:
            // The production graph selects A/V or same-layout audio-only AAC from
            // demux track facts, then returns a validated master or direct media item.
            // Source topology must not be guessed from the URL or a prebuilt selector.
            let builder: SystemHLSOutputItemBundleBuilder
            if let hlsGraphFactory {
                builder = try SystemHLSOutputItemBundleBuilder(
                    sourceURL: url, runtimeEventSink: eventSink, graphFactory: hlsGraphFactory)
            } else if sourceContext != nil {
                // Dormant construction validates the URL only. Source resolution,
                // planning and all media work begin under admitted preparation.
                builder = try SystemHLSOutputItemBundleBuilder(validating: url)
            } else {
                builder = try SystemHLSOutputItemBundleBuilder(sourceURL: url,
                    startupBufferSeconds: tuning.videoBufferSeconds, runtimeEventSink: eventSink)
            }
            let lease = try await MainActor.run {
                try HomePodAVPlayerSession(identity: identity.sessionIdentity,
                    preferredForwardBufferDuration: tuning.videoBufferSeconds).claim(backend: identity)
            }
            let presentation = await lease.presentation
            let replacementSlot = ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot()
            let metrics = PlaybackMetrics(channelID: channelID)
            let backend = HLSAVPlayerPlaybackBackend(
                identity: identity,
                bundleBuilder: builder,
                presentationContext: presentation,
                metrics: metrics,
                channelID: channelID,
                coordinatorFactory: { replacement in
                    try await MainActor.run {
                        try AVPlayerItemCoordinator(
                            driver: lease.driver,
                            evidenceSource: replacement.evidenceSource,
                            backendPublicationReplacementAuthoritySlot: replacementSlot
                        )
                    }
                },
                replacementSlot: replacementSlot
            )
            if let sourceContext, hlsGraphFactory == nil {
                backend.configureSourceRouting(dependencies: sourceDependencies(sourceContext), sessionLease: lease,
                    builderFactory: { [probe = hlsAcceptanceProbe] input, owned in
                        try SystemHLSOutputItemBundleBuilder(sourceURL: input,
                            startupBufferSeconds: tuning.videoBufferSeconds, runtimeEventSink: eventSink,
                            acceptanceProbe: probe, generatedSource: owned)
                    }, eventSink: eventSink)
            }
            return backend
        }
    }
}
