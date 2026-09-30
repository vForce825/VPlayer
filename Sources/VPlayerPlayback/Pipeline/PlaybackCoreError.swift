// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import VPlayerCore

enum FFmpegFailureKind: String, Sendable, Equatable {
    case open, read, timeout, unsupportedVideo, unsupportedAudio
}

enum FFmpegFailureStage: String, Sendable, Equatable {
    case unspecified, validation, open, streamInfo, selection, bsfInit, read, bsfSend, bsfReceive

    var displayName: String {
        switch self {
        case .unspecified: "频道流处理"
        case .validation: "频道流参数验证"
        case .open: "打开频道流"
        case .streamInfo: "读取频道流信息"
        case .selection: "选择音视频轨道"
        case .bsfInit: "初始化码流过滤器"
        case .read: "读取频道数据"
        case .bsfSend: "向码流过滤器发送数据"
        case .bsfReceive: "从码流过滤器接收数据"
        }
    }
}

enum PlaybackCoreError: Error, Sendable, Equatable {
    case unsupportedProtocol(String)
    case demuxOpen(Int32)
    case demuxRead(Int32)
    case ffmpegFailure(kind: FFmpegFailureKind, stage: FFmpegFailureStage, status: Int32)
    case networkTimeout
    case unsupportedVideoCodec
    case unsupportedAudioCodec
    case videoFormatDescription(OSStatus)
    case hardwareDecoderUnavailable
    case videoDecoderTransitionTimeout
    case videoDecode(OSStatus)
    case videoDecoderFailure(VideoDecoderFailure)
    case videoSampleBuffer(String)
    case videoRendererFailed(String)
    case audioFormatDescription(OSStatus)
    case audioFallbackDecode(Int32)
    case audioRendererFailed(String)
    case renderTextureMapping
    case metalCommand(String)
    case cancelled
    case controlEventCapacityExceeded
    case outputActivationRejected
    case backendPublicationReplacementRejected
    case presented(PlaybackFailure)
    case unexpected(stage: String, diagnostic: ErrorDiagnosticSnapshot)
}

extension PlaybackCoreError {
    static func capture(_ error: any Error, stage: String) -> Self {
        if let core = error as? Self { return core }
        if let failure = error as? VideoDecoderFailure { return .videoDecoderFailure(failure) }
        if let failure = error as? PlaybackFailure { return .presented(failure) }
        return .unexpected(stage: stage, diagnostic: PlaybackErrorDiagnostics.snapshot(error))
    }

    var retryDisposition: PlaybackRetryDisposition {
        switch self {
        case .videoDecoderFailure(.softwareDecoder): .retrySameRequest
        case .videoDecoderFailure: .chooseAnotherChannel
        case .ffmpegFailure(let kind, _, _):
            kind == .unsupportedVideo || kind == .unsupportedAudio ? .chooseAnotherChannel : .retrySameRequest
        case .unexpected(let stage, _):
            // 这些边界此前归为致命 decode 失败；新增原始诊断不改变原重试动作。
            switch stage {
            case "video.assembly", "audio.pcm-output", "audio.renderer.replay-prune",
                 "audio.recovery.replay-prune", "audio.recovery.replay", "audio.renderer.configure",
                 "audio.renderer.retry-replay", "audio.renderer.reset", "audio.renderer.reset-pcm",
                 "audio.renderer.fallback", "audio.renderer.drive": .chooseAnotherChannel
            default: .retrySameRequest
            }
        case .unsupportedProtocol, .unsupportedVideoCodec, .unsupportedAudioCodec,
             .videoFormatDescription, .videoDecode, .audioFormatDescription,
             .audioFallbackDecode:
            .chooseAnotherChannel
        case .demuxOpen, .demuxRead, .networkTimeout, .hardwareDecoderUnavailable,
             .videoDecoderTransitionTimeout,
             .videoSampleBuffer, .videoRendererFailed, .audioRendererFailed,
             .renderTextureMapping, .metalCommand, .outputActivationRejected,
             .backendPublicationReplacementRejected:
            .retrySameRequest
        case .cancelled, .controlEventCapacityExceeded:
            .doNotRetry
        case .presented(let failure): failure.retryDisposition
        }
    }
}
