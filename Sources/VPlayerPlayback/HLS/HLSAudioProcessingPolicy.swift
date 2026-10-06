// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Pure generated-audio selection. A Dolby result is permission to attempt real
/// native admission, never proof that the requested format was emitted or played.
enum HLSAudioProcessingPolicy {
    static func select(source: HLSSourceAudioFacts, capabilities: HLSOutputCapabilities,
                       hasVideo: Bool) -> HLSAudioDecision {
        guard source.formatValidated, source.service == .independentMain,
              let codec = source.codec, capabilities.compressedAudioCodecs.contains(codec),
              source.sampleRate > 0, source.channelCount > 0,
              source.channelMask.nonzeroBitCount == source.channelCount,
              preservesSourceTiming(source.priming) else { return .compatibleAAC }
        switch codec {
        case .aac:
            guard supportsSourceLC(source) else { return .compatibleAAC }
            return .passthrough(.aac)
        case .ac3, .eac3:
            guard capabilities.verifiedCompressedAudioConfigurations.contains(where: {
                !$0.requiresAACCompatibilityRendition && $0.matches(source)
            }) || capabilities.compressedAudioAdmissionCandidates.contains(where: {
                !$0.requiresAACCompatibilityRendition && $0.matches(source)
            }) else { return .compatibleAAC }
            return .passthrough(codec)
        default:
            return .compatibleAAC
        }
    }

    static func preservesSourceTiming(_ priming: HLSSourceAudioPriming) -> Bool {
        switch priming {
        case .notSignaledPreserveTimestamps: true
        case .explicit(leadingSamples: 0, trailingSamples: 0): true
        default: false
        }
    }

    static func supportsSourceLC(_ source: HLSSourceAudioFacts) -> Bool {
        guard source.codec == .aac, source.profile == 1,
              source.sampleRate == 44_100 || source.sampleRate == 48_000,
              let asc = try? AudioSpecificConfig.parse(source.decoderConfiguration),
              asc.kind == .aacLC, asc.outputSampleRate == source.sampleRate,
              asc.outputChannelCount == source.channelCount else { return false }
        // These channel configurations identify exact MPEG-4 positions. A count
        // alone cannot authorize a differently placed source layout.
        let mask: UInt64
        switch source.channelCount {
        case 1: mask = 0x4
        case 2: mask = 0x3
        case 3: mask = 0x7
        case 4: mask = 0x107
        case 5: mask = 0x37
        case 6: mask = 0x3F
        default: return false
        }
        return source.channelMask == mask
    }
}
