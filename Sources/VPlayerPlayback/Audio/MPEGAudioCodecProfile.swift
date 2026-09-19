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
            decoderExtradata: source.extradata,
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

struct MPEGHeaderInputDomainEntry: Sendable, Hashable {
    let codec: AudioCodec
    let versionBits: UInt32
    let layerBits: UInt32
    let sampleRateIndex: UInt32
    let sampleRate: Int32
    let sampleCount: Int32
    let referenceBitrate: Int
}

struct MPEGHeader {
    enum Version: UInt32, Sendable, Hashable, CaseIterable {
        case mpeg25 = 0
        case mpeg2 = 2
        case mpeg1 = 3
    }

    enum Layer: UInt32, Sendable, Hashable, CaseIterable {
        case layer3 = 1
        case layer2 = 2
        case layer1 = 3
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
    private static let baseSampleRates = [44_100, 48_000, 32_000]

    let layer: Layer
    let sampleRate: Int32
    let channelCount: Int32
    let sampleCount: Int32

    static var supportedInputDomain: [MPEGHeaderInputDomainEntry] {
        Version.allCases.flatMap { version in
            Layer.allCases.flatMap { layer in
                (0..<3).map { sampleRateIndex in
                    let divisor: Int
                    switch version {
                    case .mpeg1: divisor = 1
                    case .mpeg2: divisor = 2
                    case .mpeg25: divisor = 4
                    }
                    let codec: AudioCodec
                    let sampleCount: Int32
                    switch layer {
                    case .layer1:
                        codec = .mp1
                        sampleCount = 384
                    case .layer2:
                        codec = .mp2
                        sampleCount = 1_152
                    case .layer3:
                        codec = .mp3
                        sampleCount = version == .mpeg1 ? 1_152 : 576
                    }
                    return MPEGHeaderInputDomainEntry(
                        codec: codec,
                        versionBits: version.rawValue,
                        layerBits: layer.rawValue,
                        sampleRateIndex: UInt32(sampleRateIndex),
                        sampleRate: Int32(baseSampleRates[sampleRateIndex] / divisor),
                        sampleCount: sampleCount,
                        referenceBitrate: bitrate(version: version, layer: layer, index: 0) * 1_000
                    )
                }
            }
        }
    }

    static func parse(_ data: Data) throws -> MPEGHeader {
        guard data.count >= 4 else { throw AudioCodecProfileValidation.error() }
        let bytes = [UInt8](data.prefix(4))
        let raw = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        guard raw >> 21 == 0x7FF else { throw AudioCodecProfileValidation.error() }
        let version: Version
        guard let parsedVersion = Version(rawValue: (raw >> 19) & 3) else {
            throw AudioCodecProfileValidation.error()
        }
        version = parsedVersion
        let layer: Layer
        guard let parsedLayer = Layer(rawValue: (raw >> 17) & 3) else {
            throw AudioCodecProfileValidation.error()
        }
        layer = parsedLayer
        let bitrateIndex = Int((raw >> 12) & 0xF)
        let sampleRateIndex = Int((raw >> 10) & 3)
        guard bitrateIndex > 0, bitrateIndex < 15, sampleRateIndex < 3 else {
            throw AudioCodecProfileValidation.error()
        }
        let bitrate = bitrate(
            version: version,
            layer: layer,
            index: bitrateIndex - 1
        ) * 1_000
        let divisor: Int
        switch version {
        case .mpeg1: divisor = 1
        case .mpeg2: divisor = 2
        case .mpeg25: divisor = 4
        }
        let sampleRate = baseSampleRates[sampleRateIndex] / divisor
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
    ) -> Int {
        switch (version, layer) {
        case (.mpeg1, .layer1): return mpeg1Layer1Bitrates[index]
        case (.mpeg1, .layer2): return mpeg1Layer2Bitrates[index]
        case (.mpeg1, .layer3): return mpeg1Layer3Bitrates[index]
        case (_, .layer1): return mpeg2Layer1Bitrates[index]
        case (_, .layer2), (_, .layer3): return mpeg2Layer23Bitrates[index]
        }
    }
}
