// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

/// Only this deterministic emitted-format mismatch may request compatible AAC.
/// Admission exhaustion, cancellation and other system errors keep their type.
enum CompressedAudioInitializationRejection: Error, Sendable, Equatable {
    case invalidConfiguration
}
enum CompressedAudioInitializationSystemFailure: Error, Sendable, Equatable {
    case layoutQuery(OSStatus)
}

enum CompressedAudioChannelPositions {
    /// FFmpeg native masks follow WAVE positions. Use explicit named CoreAudio
    /// labels: back surrounds and side/direct surrounds must remain distinct.
    static func bitmap(from source: AudioChannelLayout) throws -> UInt32 {
        guard let mask = source.nativeMask, (1...6).contains(source.channelCount),
              mask.nonzeroBitCount == source.channelCount, mask & ~UInt64(0x7FF) == 0 else {
            throw CompressedAudioInitializationRejection.invalidConfiguration
        }
        let positions: [(UInt64, AudioChannelLabel)] = [
            (1 << 0, kAudioChannelLabel_Left), (1 << 1, kAudioChannelLabel_Right),
            (1 << 2, kAudioChannelLabel_Center), (1 << 3, kAudioChannelLabel_LFEScreen),
            (1 << 4, kAudioChannelLabel_LeftSurround), (1 << 5, kAudioChannelLabel_RightSurround),
            (1 << 6, kAudioChannelLabel_LeftCenter), (1 << 7, kAudioChannelLabel_RightCenter),
            (1 << 8, kAudioChannelLabel_CenterSurround),
            (1 << 9, kAudioChannelLabel_LeftSurroundDirect), (1 << 10, kAudioChannelLabel_RightSurroundDirect),
        ]
        var result: UInt32 = 0
        for (bit, label) in positions where mask & bit != 0 {
            guard (1...32).contains(label) else { throw CompressedAudioInitializationRejection.invalidConfiguration }
            result |= UInt32(1) << (label - 1)
        }
        return result
    }

    static func bitmap(for layout: FMP4AudioChannelLayout) throws -> UInt32 {
        switch layout {
        case let .bitmap(value):
            guard value != 0, value & ~UInt32(0x7FF) == 0 else {
                throw CompressedAudioInitializationRejection.invalidConfiguration
            }
            return value
        case var .tag(tag):
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioFormatGetProperty(kAudioFormatProperty_BitmapForLayoutTag,
                UInt32(MemoryLayout<UInt32>.size), &tag, &size, &value)
            if status == kAudioFormatUnsupportedDataFormatError {
                throw CompressedAudioInitializationRejection.invalidConfiguration
            }
            guard status == noErr else { throw CompressedAudioInitializationSystemFailure.layoutQuery(status) }
            guard size == UInt32(MemoryLayout<UInt32>.size) else {
                throw CompressedAudioInitializationSystemFailure.layoutQuery(kAudioFormatBadPropertySizeError)
            }
            return try bitmap(for: .bitmap(value))
        }
    }

    static func bitmap(in description: CMAudioFormatDescription) throws -> UInt32 {
        var size = 0
        guard let pointer = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size),
              size >= 12, pointer.pointee.mNumberChannelDescriptions == 0 else {
            throw CompressedAudioInitializationRejection.invalidConfiguration
        }
        let layout = pointer.pointee
        return try bitmap(for: layout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
            ? .bitmap(layout.mChannelBitmap.rawValue) : .tag(layout.mChannelLayoutTag))
    }
}

private func emittedAudioFacts(_ bytes: Data) throws -> FMP4CompressedAudioInitialization {
    do { return try FMP4CompressedAudioInspection.initialization(bytes) }
    catch CompletedMediaEvidenceError.invalidDecodeMap {
        throw CompressedAudioInitializationRejection.invalidConfiguration
    }
}

struct DolbyWriterInitializationEvidence: Sendable {
    let sampleEntryDigest: Data
    let channelPositions: UInt32
    let timescale: Int32

    static func validate(_ bytes: Data, configuration: CompressedAudioFormatConfiguration,
                         sourceLayout: AudioChannelLayout) throws -> DolbyWriterInitializationEvidence {
        let facts = try emittedAudioFacts(bytes)
        let codingMode: UInt8
        let hasLFE: Bool
        let expectedEntry: UInt32
        switch configuration {
        case let .ac3(value):
            codingMode = value.audioCodingMode; hasLFE = value.hasLFE; expectedEntry = 0x61632d33
        case let .eac3(value):
            codingMode = value.audioCodingMode; hasLFE = value.hasLFE; expectedEntry = 0x65632d33
        }
        guard (1...7).contains(codingMode), facts.sampleEntry == expectedEntry,
              facts.sampleEntrySampleRate == UInt32(configuration.sampleRate),
              facts.decoderConfiguration == configuration.serializedBox else {
            throw CompressedAudioInitializationRejection.invalidConfiguration
        }
        let channelCounts: [Int32] = [2, 1, 2, 3, 3, 4, 4, 5]
        let channelCount = channelCounts[Int(codingMode)] + (hasLFE ? 1 : 0)
        guard channelCount == sourceLayout.channelCount else {
            throw CompressedAudioInitializationRejection.invalidConfiguration
        }
        // ETSI TS 102 366 F.3.2/F.5.2 ignores AudioSampleEntry.ChannelCount.
        // Actual count comes from exact dac3/dec3; positions still need emitted chan.
        let requestedPositions = try CompressedAudioChannelPositions.bitmap(from: sourceLayout)
        let emittedPositions: UInt32
        if let layout = facts.channelLayout {
            emittedPositions = try CompressedAudioChannelPositions.bitmap(for: layout)
        } else if !hasLFE, codingMode == 1 {
            emittedPositions = 0x4
        } else if !hasLFE, codingMode == 2 {
            emittedPositions = 0x3
        } else {
            throw CompressedAudioInitializationRejection.invalidConfiguration
        }
        guard emittedPositions == requestedPositions,
              emittedPositions.nonzeroBitCount == channelCount else {
            throw CompressedAudioInitializationRejection.invalidConfiguration
        }
        return .init(sampleEntryDigest: facts.sampleEntryDigest,
            channelPositions: emittedPositions, timescale: facts.timescale)
    }
}

struct SourceAACInitializationEvidence: Sendable {
    let sampleEntryDigest: Data
    let timescale: Int32

    static func validate(_ bytes: Data, configuration: SourceAACWriterConfiguration) throws -> SourceAACInitializationEvidence {
        let facts = try emittedAudioFacts(bytes)
        guard facts.sampleEntry == 0x6d703461,
              facts.decoderConfiguration == configuration.audioSpecificConfig else {
            throw CompressedAudioInitializationRejection.invalidConfiguration
        }
        // Exact LC ASC is authoritative for rate/count, not conventional mp4a fields.
        if let layout = facts.channelLayout {
            let actual = try CompressedAudioChannelPositions.bitmap(for: layout)
            let expected = try CompressedAudioChannelPositions.bitmap(from: .init(
                channelCount: configuration.channelCount, nativeMask: configuration.channelMask))
            guard actual == expected else { throw CompressedAudioInitializationRejection.invalidConfiguration }
        }
        return .init(sampleEntryDigest: facts.sampleEntryDigest, timescale: facts.timescale)
    }
}
