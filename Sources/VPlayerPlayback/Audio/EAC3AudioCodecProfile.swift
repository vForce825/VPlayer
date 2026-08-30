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
              frame.payload.count >= 4,
              frame.payload[frame.payload.startIndex] == 0x0B,
              frame.payload[frame.payload.index(after: frame.payload.startIndex)] == 0x77,
              Self.headerFrameByteCount(frame.payload) == frame.payload.count,
              let sampleCount = frame.parserSampleCount,
              [256, 512, 768, 1_536].contains(sampleCount) else {
            throw AudioCodecProfileValidation.error()
        }
        try AudioCodecProfileValidation.validateParserFacts(
            frame,
            source: source,
            sampleCount: sampleCount
        )
        return InspectedCompressedAudioFrame(
            payload: frame.payload,
            sampleCount: sampleCount,
            decoderExtradata: source.extradata,
            systemFormat: SystemCompressedAudioFormat(
                profileID: .eac3,
                codec: .eac3,
                formatID: kAudioFormatEnhancedAC3,
                sampleRate: source.sampleRate,
                channelCount: source.channelLayout.channelCount,
                framesPerPacket: 0,
                layout: try AudioCodecProfileValidation.layout(from: source.channelLayout),
                magicCookie: nil
            )
        )
    }

    private static func headerFrameByteCount(_ payload: Data) -> Int {
        let highIndex = payload.index(payload.startIndex, offsetBy: 2)
        let lowIndex = payload.index(after: highIndex)
        let frameSizeCode = Int(payload[highIndex] & 0x07) << 8
            | Int(payload[lowIndex])
        return 2 * (frameSizeCode + 1)
    }
}
