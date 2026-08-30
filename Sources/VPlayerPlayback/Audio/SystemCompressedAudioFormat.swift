// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

public enum AudioCodecProfileID: UInt8, Sendable, Hashable {
    case aacLC = 1
    case heAACv1 = 2
    case heAACv2 = 3
    case mpegLayer1 = 4
    case mpegLayer2 = 5
    case mpegLayer3 = 6
    case ac3 = 7
    case eac3 = 8
}

public enum CoreAudioLayoutSpec: Sendable, Hashable {
    case tag(AudioChannelLayoutTag, equivalentBitmap: AudioChannelBitmap)
    case bitmap(AudioChannelBitmap)
    case discrete(UInt32)

    public static func == (lhs: CoreAudioLayoutSpec, rhs: CoreAudioLayoutSpec) -> Bool {
        switch (lhs, rhs) {
        case let (.tag(lhsTag, lhsBitmap), .tag(rhsTag, rhsBitmap)):
            lhsTag == rhsTag && lhsBitmap.rawValue == rhsBitmap.rawValue
        case let (.bitmap(lhsBitmap), .bitmap(rhsBitmap)):
            lhsBitmap.rawValue == rhsBitmap.rawValue
        case let (.discrete(lhsCount), .discrete(rhsCount)):
            lhsCount == rhsCount
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .tag(tag, equivalentBitmap):
            hasher.combine(0 as UInt8)
            hasher.combine(tag)
            hasher.combine(equivalentBitmap.rawValue)
        case let .bitmap(bitmap):
            hasher.combine(1 as UInt8)
            hasher.combine(bitmap.rawValue)
        case let .discrete(count):
            hasher.combine(2 as UInt8)
            hasher.combine(count)
        }
    }
}

struct SystemCompressedAudioFormat: Sendable, Hashable {
    let profileID: AudioCodecProfileID
    let codec: AudioCodec
    let formatID: AudioFormatID
    let sampleRate: Int32
    let channelCount: Int32
    let framesPerPacket: UInt32
    let layout: CoreAudioLayoutSpec
    let magicCookie: Data?
}

enum CompressedAudioFramingKind: Sendable, Hashable {
    case rawAAC
    case adts
    case ffmpegParser
}

struct FramedCompressedAudioFrame: Sendable {
    let payload: Data
    let presentationTimeStamp: CMTime
    let parserSampleCount: Int32?
    let parserSampleRate: Int32?
    let parserChannelLayout: AudioChannelLayout?
    let containerMarkedCorrupt: Bool
}

struct InspectedCompressedAudioFrame: Sendable {
    let payload: Data
    let sampleCount: Int32
    let decoderExtradata: Data
    let systemFormat: SystemCompressedAudioFormat
}

public struct CompressedAudioRenderConfiguration: @unchecked Sendable {
    public let formatDescription: CMAudioFormatDescription
    public let codec: AudioCodec
    public let decoderExtradata: Data
    public let fingerprint: MediaFormatFingerprint

    public init(
        formatDescription: CMAudioFormatDescription,
        codec: AudioCodec,
        decoderExtradata: Data,
        fingerprint: MediaFormatFingerprint
    ) {
        self.formatDescription = formatDescription
        self.codec = codec
        self.decoderExtradata = decoderExtradata
        self.fingerprint = fingerprint
    }
}
