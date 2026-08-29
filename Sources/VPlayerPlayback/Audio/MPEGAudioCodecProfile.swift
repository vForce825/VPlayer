// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import Foundation

struct MPEGAudioCodecProfile: CompressedAudioCodecProfile {
    let codec: AudioCodec
    let framing: CompressedAudioFramingKind = .ffmpegParser

    init(codec: AudioCodec) throws {
        guard [.mp1, .mp2, .mp3].contains(codec) else {
            throw AudioCodecProfileValidation.error()
        }
        self.codec = codec
    }

    func inspect(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> InspectedCompressedAudioFrame {
        guard source.codec == codec else { throw AudioCodecProfileValidation.error() }
        let header = try MPEGHeader.parse(frame.payload)
        let facts: (layer: MPEGHeader.Layer, profileID: AudioCodecProfileID,
                    formatID: AudioFormatID, framesPerPacket: UInt32)
        switch codec {
        case .mp1:
            facts = (.layer1, .mpegLayer1, kAudioFormatMPEGLayer1, 384)
        case .mp2:
            facts = (.layer2, .mpegLayer2, kAudioFormatMPEGLayer2, 1_152)
        case .mp3:
            facts = (.layer3, .mpegLayer3, kAudioFormatMPEGLayer3, 0)
        default:
            throw AudioCodecProfileValidation.error()
        }
        guard header.layer == facts.layer,
              header.sampleRate == source.sampleRate,
              header.channelCount == source.channelLayout.channelCount else {
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
            systemFormat: SystemCompressedAudioFormat(
                profileID: facts.profileID,
                codec: codec,
                formatID: facts.formatID,
                sampleRate: header.sampleRate,
                channelCount: header.channelCount,
                framesPerPacket: facts.framesPerPacket,
                layout: try AudioCodecProfileValidation.layout(from: source.channelLayout),
                magicCookie: nil
            )
        )
    }
}

private struct MPEGHeader {
    enum Version {
        case mpeg1
        case mpeg2
        case mpeg25
    }

    enum Layer {
        case layer1
        case layer2
        case layer3
    }

    private static let mpeg1Layer1Bitrates = [
        32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448,
    ]
    private static let mpeg1Layer2Bitrates = [
        32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384,
    ]
    private static let mpeg1Layer3Bitrates = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ]
    private static let mpeg2Layer1Bitrates = [
        32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256,
    ]
    private static let mpeg2Layer23Bitrates = [
        8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
    ]

    let layer: Layer
    let sampleRate: Int32
    let channelCount: Int32
    let sampleCount: Int32

    static func parse(_ data: Data) throws -> MPEGHeader {
        guard data.count >= 4 else { throw AudioCodecProfileValidation.error() }
        let bytes = [UInt8](data.prefix(4))
        let raw = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        guard raw >> 21 == 0x7FF else { throw AudioCodecProfileValidation.error() }
        let version: Version
        switch (raw >> 19) & 3 {
        case 3: version = .mpeg1
        case 2: version = .mpeg2
        case 0: version = .mpeg25
        default: throw AudioCodecProfileValidation.error()
        }
        let layer: Layer
        switch (raw >> 17) & 3 {
        case 3: layer = .layer1
        case 2: layer = .layer2
        case 1: layer = .layer3
        default: throw AudioCodecProfileValidation.error()
        }
        let bitrateIndex = Int((raw >> 12) & 0xF)
        let sampleRateIndex = Int((raw >> 10) & 3)
        guard bitrateIndex > 0, bitrateIndex < 15, sampleRateIndex < 3 else {
            throw AudioCodecProfileValidation.error()
        }
        let bitrate = try bitrate(
            version: version,
            layer: layer,
            index: bitrateIndex - 1
        ) * 1_000
        let baseRates = [44_100, 48_000, 32_000]
        let divisor: Int
        switch version {
        case .mpeg1: divisor = 1
        case .mpeg2: divisor = 2
        case .mpeg25: divisor = 4
        }
        let sampleRate = baseRates[sampleRateIndex] / divisor
        let padding = Int((raw >> 9) & 1)
        let expectedLength: Int
        switch layer {
        case .layer1:
            expectedLength = (12 * bitrate / sampleRate + padding) * 4
        case .layer2:
            expectedLength = 144 * bitrate / sampleRate + padding
        case .layer3:
            let coefficient = version == .mpeg1 ? 144 : 72
            expectedLength = coefficient * bitrate / sampleRate + padding
        }
        guard data.count == expectedLength else {
            throw AudioCodecProfileValidation.error()
        }
        let sampleCount: Int32
        switch layer {
        case .layer1: sampleCount = 384
        case .layer2: sampleCount = 1_152
        case .layer3: sampleCount = version == .mpeg1 ? 1_152 : 576
        }
        let channelMode = (raw >> 6) & 3
        return MPEGHeader(
            layer: layer,
            sampleRate: Int32(sampleRate),
            channelCount: channelMode == 3 ? 1 : 2,
            sampleCount: sampleCount
        )
    }

    private static func bitrate(
        version: Version,
        layer: Layer,
        index: Int
    ) throws -> Int {
        switch (version, layer) {
        case (.mpeg1, .layer1): return mpeg1Layer1Bitrates[index]
        case (.mpeg1, .layer2): return mpeg1Layer2Bitrates[index]
        case (.mpeg1, .layer3): return mpeg1Layer3Bitrates[index]
        case (_, .layer1): return mpeg2Layer1Bitrates[index]
        case (_, .layer2), (_, .layer3): return mpeg2Layer23Bitrates[index]
        }
    }
}
