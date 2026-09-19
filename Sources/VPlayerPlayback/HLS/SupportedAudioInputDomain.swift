// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct SupportedAudioInputFacts: Sendable, Hashable {
    let codec: AudioCodec
    let framing: CompressedAudioFramingKind
    let profileID: AudioCodecProfileID
    let sampleRate: Int32
    let sampleCount: Int32
    let channelCount: Int32
}

enum SupportedAudioInputDomain {
    static var approvedCodecs: [AudioCodec] {
        AudioCodecProfileRegistry.approvedCodecs
    }

    static var aacIndexedSampleRates: [Int32] {
        AudioSpecificConfig.indexedSampleRates
    }

    static var aacRawKinds: [AudioSpecificConfig.Kind] {
        AudioSpecificConfig.Kind.allCases
    }

    static var aacExplicitSampleRateRange: ClosedRange<Int32> {
        AudioSpecificConfig.explicitSampleRateRange
    }

    static var mpegHeaderEntries: [MPEGHeaderInputDomainEntry] {
        MPEGHeader.supportedInputDomain
    }

    static var ac3HeaderEntries: [AC3HeaderInputDomainEntry] {
        AC3FrameInspector.supportedInputDomain
    }

    static var eac3HeaderEntries: [EAC3HeaderInputDomainEntry] {
        EAC3FrameInspector.supportedInputDomain
    }

    static func inspect(
        _ frame: FramedCompressedAudioFrame,
        source: AudioTrackDescriptor
    ) throws -> SupportedAudioInputFacts {
        let profile = try AudioCodecProfileRegistry.profile(for: source)
        let inspected = try profile.inspect(frame, source: source)
        return SupportedAudioInputFacts(
            codec: inspected.systemFormat.codec,
            framing: profile.framing,
            profileID: inspected.systemFormat.profileID,
            sampleRate: inspected.systemFormat.sampleRate,
            sampleCount: inspected.sampleCount,
            channelCount: inspected.systemFormat.channelCount
        )
    }
}
