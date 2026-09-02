// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

enum PlaybackCoreError: Error, Sendable, Equatable {
    case unsupportedProtocol(String)
    case demuxOpen(Int32)
    case demuxRead(Int32)
    case networkTimeout
    case unsupportedVideoCodec
    case unsupportedAudioCodec
    case videoFormatDescription(OSStatus)
    case hardwareDecoderUnavailable
    case videoDecoderTransitionTimeout
    case videoDecode(OSStatus)
    case videoSampleBuffer(String)
    case videoRendererFailed(String)
    case audioFormatDescription(OSStatus)
    case audioFallbackDecode(Int32)
    case audioRendererFailed(String)
    case renderTextureMapping
    case metalCommand(String)
    case cancelled
}

extension PlaybackCoreError {
    var retryDisposition: PlaybackRetryDisposition {
        switch self {
        case .unsupportedProtocol, .unsupportedVideoCodec, .unsupportedAudioCodec,
             .videoFormatDescription, .videoDecode, .audioFormatDescription,
             .audioFallbackDecode:
            .chooseAnotherChannel
        case .demuxOpen, .demuxRead, .networkTimeout, .hardwareDecoderUnavailable,
             .videoDecoderTransitionTimeout,
             .videoSampleBuffer, .videoRendererFailed, .audioRendererFailed,
             .renderTextureMapping, .metalCommand:
            .retrySameRequest
        case .cancelled:
            .doNotRetry
        }
    }
}
