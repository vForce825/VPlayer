// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import Foundation

protocol CompressedAudioCodecProfile: Sendable {
    var codec: AudioCodec { get }
    var framing: CompressedAudioFramingKind { get }

    func inspect(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> InspectedCompressedAudioFrame
    func initialSystemFormat(source: AudioTrackDescriptor) throws -> SystemCompressedAudioFormat?
    func decodeBreakReason(
        forRejected frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) -> AudioDecodeBreakReason
}

extension CompressedAudioCodecProfile {
    func initialSystemFormat(source _: AudioTrackDescriptor) throws
        -> SystemCompressedAudioFormat? {
        nil
    }

    func decodeBreakReason(
        forRejected frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) -> AudioDecodeBreakReason {
        guard frame.containerMarkedCorrupt else { return .invalidFrame }
        let cleanFrame = FramedCompressedAudioFrame(
            payload: frame.payload,
            presentationTimeStamp: frame.presentationTimeStamp,
            parserSampleCount: frame.parserSampleCount,
            parserSampleRate: frame.parserSampleRate,
            parserChannelLayout: frame.parserChannelLayout,
            containerMarkedCorrupt: false
        )
        return (try? inspect(cleanFrame, source: source)) != nil
            ? .corruptPacket
            : .invalidFrame
    }
}

enum AudioCodecProfileRegistry {
    static let approvedCodecs: [AudioCodec] = [.aac, .mp1, .mp2, .mp3, .ac3, .eac3]

    static func profile(
        for source: AudioTrackDescriptor
    ) throws -> any CompressedAudioCodecProfile {
        switch source.codec {
        case .aac:
            try AACAudioCodecProfile(source: source)
        case .mp1, .mp2, .mp3:
            try MPEGAudioCodecProfile(codec: source.codec)
        case .ac3:
            AC3AudioCodecProfile()
        case .eac3:
            EAC3AudioCodecProfile()
        }
    }
}

enum AudioCodecProfileValidation {
    static let invalidInputErrorCode: Int32 = -1_448_208_906
    static let maximumFrameBytes = 64 * 1_024 * 1_024
    static let maximumRawAACAccessUnitBytes =
        CompressedAudioRetentionPolicy.rawAACMaximumAccessUnitBytes

    static func error() -> PlaybackCoreError {
        .audioFallbackDecode(invalidInputErrorCode)
    }

    static func layout(from source: AudioChannelLayout) throws -> CoreAudioLayoutSpec {
        guard source.channelCount > 0 else { throw error() }
        if let mask = source.nativeMask {
            guard mask != 0,
                  mask.nonzeroBitCount == source.channelCount,
                  let bitmap = UInt32(exactly: mask) else {
                throw error()
            }
            return .bitmap(AudioChannelBitmap(rawValue: bitmap))
        }
        guard let count = UInt32(exactly: source.channelCount) else { throw error() }
        return .discrete(count)
    }

    static func validateParserFacts(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor,
        sampleCount: Int32
    ) throws {
        guard !frame.payload.isEmpty,
              frame.payload.count <= maximumFrameBytes,
              !frame.containerMarkedCorrupt,
              frame.parserSampleCount == sampleCount,
              frame.parserSampleRate == source.sampleRate,
              let parserLayout = frame.parserChannelLayout,
              parserLayout.channelCount == source.channelLayout.channelCount,
              parserLayout.channelCount > 0 else {
            throw error()
        }
        if let parserMask = parserLayout.nativeMask {
            guard parserMask != 0,
                  parserMask.nonzeroBitCount == parserLayout.channelCount else {
                throw error()
            }
            if let sourceMask = source.channelLayout.nativeMask,
               parserMask != sourceMask {
                throw error()
            }
        }
    }
}
