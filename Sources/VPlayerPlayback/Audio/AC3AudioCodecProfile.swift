// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import Foundation

struct AC3AudioCodecProfile: CompressedAudioCodecProfile {
    let codec: AudioCodec = .ac3
    let framing: CompressedAudioFramingKind = .ffmpegParser

    func inspect(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> InspectedCompressedAudioFrame {
        guard source.codec == .ac3 else {
            throw AudioCodecProfileValidation.error()
        }
        let header = try AC3FrameInspector.inspect(frame.payload)
        guard header.sampleCount == 1_536,
              source.sampleRate == header.sampleRate,
              source.channelLayout.channelCount == header.channelCount,
              frame.parserSampleCount == header.sampleCount,
              frame.parserSampleRate == header.sampleRate,
              let parserLayout = frame.parserChannelLayout,
              parserLayout.channelCount == header.channelCount,
              parserLayout.channelCount > 0 else {
            throw AudioCodecProfileValidation.error()
        }
        if let parserMask = parserLayout.nativeMask {
            guard parserMask != 0,
                  parserMask.nonzeroBitCount == parserLayout.channelCount else {
                throw AudioCodecProfileValidation.error()
            }
            if let sourceMask = source.channelLayout.nativeMask,
               parserMask != sourceMask {
                throw AudioCodecProfileValidation.error()
            }
        }

        return InspectedCompressedAudioFrame(
            payload: frame.payload,
            sampleCount: header.sampleCount,
            systemFormat: SystemCompressedAudioFormat(
                profileID: .ac3,
                codec: .ac3,
                formatID: kAudioFormatAC3,
                sampleRate: header.sampleRate,
                channelCount: header.channelCount,
                framesPerPacket: UInt32(header.sampleCount),
                layout: try layout(for: header, source: source),
                magicCookie: magicCookie(for: header)
            )
        )
    }

    private func layout(
        for header: AC3FrameInspection,
        source: AudioTrackDescriptor
    ) throws -> CoreAudioLayoutSpec {
        switch (header.acmod, header.lfeon) {
        case (2, false):
            .tag(
                kAudioChannelLayoutTag_Stereo,
                equivalentBitmap: AudioChannelBitmap(rawValue: 0x03)
            )
        case (7, true):
            .tag(
                kAudioChannelLayoutTag_MPEG_5_1_A,
                equivalentBitmap: AudioChannelBitmap(rawValue: 0x3F)
            )
        default:
            try AudioCodecProfileValidation.layout(from: source.channelLayout)
        }
    }

    private func magicCookie(for header: AC3FrameInspection) -> Data {
        let bitRateCode = header.frmsizecod >> 1
        let payload = UInt32(header.fscod) << 22
            | UInt32(header.bsid) << 17
            | UInt32(header.bsmod) << 14
            | UInt32(header.acmod) << 11
            | UInt32(header.lfeon ? 1 : 0) << 10
            | UInt32(bitRateCode) << 5
        return Data([
            0x00, 0x00, 0x00, 0x0C, 0x66, 0x72, 0x6D, 0x61,
            0x61, 0x63, 0x2D, 0x33,
            0x00, 0x00, 0x00, 0x0B, 0x64, 0x61, 0x63, 0x33,
            UInt8((payload >> 16) & 0xFF),
            UInt8((payload >> 8) & 0xFF),
            UInt8(payload & 0xFF),
            0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00,
        ])
    }
}
