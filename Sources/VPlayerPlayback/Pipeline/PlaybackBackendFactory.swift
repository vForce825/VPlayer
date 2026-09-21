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
}

extension PlaybackBackendFactory {
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

    init(
        pipelineFactory: any PlaybackPipelineFactory = SystemPlaybackPipelineFactory(),
        hlsGraphFactory: SystemHLSOutputItemBundleBuilder.GraphFactory? = nil
    ) {
        self.pipelineFactory = pipelineFactory
        self.hlsGraphFactory = hlsGraphFactory
    }

    func makeBackend(
        kind: PlaybackBackendKind,
        identity: PlaybackBackendIdentity,
        tuning: PlaybackTuning,
        channelID: String,
        url: URL,
        eventSink: @escaping @Sendable (PlaybackPipelineEvent) -> Void
    ) async throws -> any PlaybackBackend {
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
            let builder: SystemHLSOutputItemBundleBuilder
            if let hlsGraphFactory {
                builder = try SystemHLSOutputItemBundleBuilder(
                    sourceURL: url, graphFactory: hlsGraphFactory)
            } else {
                builder = try SystemHLSOutputItemBundleBuilder(sourceURL: url)
            }
            let driver = try await MainActor.run {
                try SystemAVPlayerDriver.make(
                    preferredForwardBufferDuration: tuning.videoBufferSeconds
                )
            }
            let presentation = await MainActor.run {
                AVPlayerPresentationContext(player: driver.player)
            }
            let replacementSlot = ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot()
            let metrics = PlaybackMetrics(channelID: channelID)
            return HLSAVPlayerPlaybackBackend(
                identity: identity,
                bundleBuilder: builder,
                presentationContext: presentation,
                metrics: metrics,
                channelID: channelID,
                coordinatorFactory: { replacement in
                    try await MainActor.run {
                        try AVPlayerItemCoordinator(
                            driver: driver,
                            evidenceSource: replacement.evidenceSource,
                            backendPublicationReplacementAuthoritySlot: replacementSlot
                        )
                    }
                },
                replacementSlot: replacementSlot
            )
        }
    }
}
