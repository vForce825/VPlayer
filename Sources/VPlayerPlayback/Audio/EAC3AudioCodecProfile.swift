// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import Foundation

struct EAC3AudioCodecProfile: CompressedAudioCodecProfile {
    let codec: AudioCodec = .eac3
    let framing: CompressedAudioFramingKind = .ffmpegParser

    func inspect(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> InspectedCompressedAudioFrame {
        guard source.codec == .eac3,
              !frame.containerMarkedCorrupt else {
            throw AudioCodecProfileValidation.error()
        }
        let header = try EAC3FrameInspector.inspect(frame.payload)
        guard source.sampleRate == header.sampleRate,
              source.channelLayout.channelCount == header.channelCount else {
            throw AudioCodecProfileValidation.error()
        }
        try AudioCodecProfileValidation.validateParserFacts(
            frame,
            source: source,
            sampleCount: header.sampleCount
        )
        return InspectedCompressedAudioFrame(
            payload: frame.payload,
            sampleCount: header.sampleCount,
            decoderExtradata: source.extradata,
            systemFormat: SystemCompressedAudioFormat(
                profileID: .eac3,
                codec: .eac3,
                formatID: kAudioFormatEnhancedAC3,
                sampleRate: header.sampleRate,
                channelCount: header.channelCount,
                framesPerPacket: 0,
                layout: try AudioCodecProfileValidation.layout(from: source.channelLayout),
                magicCookie: nil
            )
        )
    }

}
