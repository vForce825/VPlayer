// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import Foundation

struct AACAudioCodecProfile: CompressedAudioCodecProfile {
    private static let sampleRates: [Int32] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
        22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]
    private static let channelCounts: [Int32] = [0, 1, 2, 3, 4, 5, 6, 8]

    let codec: AudioCodec = .aac
    let framing: CompressedAudioFramingKind

    init(source: AudioTrackDescriptor) throws {
        guard source.codec == .aac else { throw AudioCodecProfileValidation.error() }
        if source.extradata.isEmpty {
            framing = .adts
        } else {
            _ = try AudioSpecificConfig.parse(source.extradata)
            framing = .rawAAC
        }
    }

    func initialSystemFormat(
        source: AudioTrackDescriptor
    ) throws -> SystemCompressedAudioFormat? {
        guard framing == .rawAAC else { return nil }
        return try rawFormatFacts(source: source).systemFormat
    }

    func inspect(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> InspectedCompressedAudioFrame {
        guard source.codec == .aac,
              !frame.payload.isEmpty,
              frame.payload.count <= AudioCodecProfileValidation.maximumFrameBytes,
              !frame.containerMarkedCorrupt else {
            throw AudioCodecProfileValidation.error()
        }
        switch framing {
        case .rawAAC:
            return try inspectRaw(frame, source: source)
        case .adts:
            return try inspectADTS(frame, source: source)
        case .ffmpegParser:
            throw AudioCodecProfileValidation.error()
        }
    }

    private func inspectRaw(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> InspectedCompressedAudioFrame {
        guard !source.extradata.isEmpty,
              frame.payload.count <= AudioCodecProfileValidation.maximumRawAACAccessUnitBytes,
              !Self.hasADTSSync(frame.payload),
              !Self.hasLATMOrLOASSync(frame.payload) else {
            throw AudioCodecProfileValidation.error()
        }
        let facts = try rawFormatFacts(source: source)
        return InspectedCompressedAudioFrame(
            payload: frame.payload,
            sampleCount: facts.sampleCount,
            decoderExtradata: source.extradata,
            systemFormat: facts.systemFormat
        )
    }

    private func rawFormatFacts(
        source: AudioTrackDescriptor
    ) throws -> (sampleCount: Int32, systemFormat: SystemCompressedAudioFormat) {
        let asc = try AudioSpecificConfig.parse(source.extradata)
        guard asc.outputSampleRate == source.sampleRate,
              asc.outputChannelCount == source.channelLayout.channelCount else {
            throw AudioCodecProfileValidation.error()
        }
        let formatFacts: (AudioCodecProfileID, AudioFormatID, Int32, UInt32)
        switch asc.kind {
        case .aacLC:
            formatFacts = (.aacLC, kAudioFormatMPEG4AAC, 1_024, 1_024)
        case .heAACv1:
            formatFacts = (.heAACv1, kAudioFormatMPEG4AAC_HE, 2_048, 2_048)
        case .heAACv2:
            formatFacts = (.heAACv2, kAudioFormatMPEG4AAC_HE_V2, 2_048, 2_048)
        }
        return (
            sampleCount: formatFacts.2,
            systemFormat: try makeFormat(
                profileID: formatFacts.0,
                formatID: formatFacts.1,
                sampleRate: asc.outputSampleRate,
                channelCount: asc.outputChannelCount,
                framesPerPacket: formatFacts.3,
                cookie: asc.coreAudioMagicCookie,
                source: source
            )
        )
    }

    private func inspectADTS(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> InspectedCompressedAudioFrame {
        guard source.extradata.isEmpty, frame.payload.count >= 7 else {
            throw AudioCodecProfileValidation.error()
        }
        let bytes = [UInt8](frame.payload.prefix(7))
        guard bytes[0] == 0xFF,
              bytes[1] & 0xF6 == 0xF0,
              bytes[2] >> 6 == 1 else {
            throw AudioCodecProfileValidation.error()
        }
        let frequencyIndex = Int((bytes[2] >> 2) & 0x0F)
        let channelConfiguration = Int(((bytes[2] & 1) << 2) | (bytes[3] >> 6))
        guard frequencyIndex < Self.sampleRates.count,
              channelConfiguration > 0,
              channelConfiguration < Self.channelCounts.count,
              Self.sampleRates[frequencyIndex] == source.sampleRate,
              Self.channelCounts[channelConfiguration] == source.channelLayout.channelCount,
              bytes[6] & 3 == 0 else {
            throw AudioCodecProfileValidation.error()
        }
        let headerLength = bytes[1] & 1 == 1 ? 7 : 9
        let frameLength = Int(bytes[3] & 3) << 11
            | Int(bytes[4]) << 3
            | Int(bytes[5] >> 5)
        guard frameLength == frame.payload.count, frameLength > headerLength else {
            throw AudioCodecProfileValidation.error()
        }
        let asc = try AudioSpecificConfig.parse(Data([
            UInt8((2 << 3) | (frequencyIndex >> 1)),
            UInt8(((frequencyIndex & 1) << 7) | (channelConfiguration << 3)),
        ]))
        return InspectedCompressedAudioFrame(
            payload: Data(frame.payload.dropFirst(headerLength)),
            sampleCount: 1_024,
            decoderExtradata: asc.bytes,
            systemFormat: try makeFormat(
                profileID: .aacLC,
                formatID: kAudioFormatMPEG4AAC,
                sampleRate: source.sampleRate,
                channelCount: source.channelLayout.channelCount,
                framesPerPacket: 1_024,
                cookie: asc.coreAudioMagicCookie,
                source: source
            )
        )
    }

    private func makeFormat(
        profileID: AudioCodecProfileID,
        formatID: AudioFormatID,
        sampleRate: Int32,
        channelCount: Int32,
        framesPerPacket: UInt32,
        cookie: Data,
        source: AudioTrackDescriptor
    ) throws -> SystemCompressedAudioFormat {
        SystemCompressedAudioFormat(
            profileID: profileID,
            codec: .aac,
            formatID: formatID,
            sampleRate: sampleRate,
            channelCount: channelCount,
            framesPerPacket: framesPerPacket,
            layout: try AudioCodecProfileValidation.layout(from: source.channelLayout),
            magicCookie: cookie
        )
    }

    private static func hasADTSSync(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] & 0xF6 == 0xF0
    }

    private static func hasLATMOrLOASSync(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x56
            && data[data.index(after: data.startIndex)] & 0xE0 == 0xE0
    }
}
