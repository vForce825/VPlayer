// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Exact source/output configuration backed by actual route evidence.
public struct HLSVerifiedCompressedAudioConfiguration: Sendable, Hashable {
    public let codec: AudioCodec
    public let profile: Int32
    public let sampleRate: Int32, channelCount: Int32
    public let channelMask: UInt64
    public let decoderConfiguration: Data
    public let outputRouteIdentifier: String
    public let requiresAACCompatibilityRendition: Bool
    public init(codec: AudioCodec, profile: Int32, sampleRate: Int32, channelCount: Int32, channelMask: UInt64,
                decoderConfiguration: Data, outputRouteIdentifier: String, requiresAACCompatibilityRendition: Bool) {
        self.codec = codec; self.profile = profile; self.sampleRate = sampleRate; self.channelCount = channelCount
        self.channelMask = channelMask; self.decoderConfiguration = decoderConfiguration
        self.outputRouteIdentifier = outputRouteIdentifier; self.requiresAACCompatibilityRendition = requiresAACCompatibilityRendition
    }
    public func matches(_ source: HLSSourceAudioFacts) -> Bool {
        guard [.ac3, .eac3].contains(codec), !outputRouteIdentifier.isEmpty,
              source.formatValidated, source.service == .independentMain,
              source.codec == codec, source.profile == profile, source.sampleRate == sampleRate,
              source.channelCount == channelCount, source.channelMask == channelMask,
              source.decoderConfiguration == decoderConfiguration, channelMask != 0,
              sampleRate > 0, channelCount > 0 else { return false }
        return codec == .ac3 ? (0...10).contains(profile) : (11...16).contains(profile)
    }
}

/// Eligible proposal only; a generated graph must still obtain real output admission.
public struct HLSCompressedAudioAdmissionCandidate: Sendable, Hashable {
    public let codec: AudioCodec
    public let profile: Int32
    public let sampleRate: Int32, channelCount: Int32
    public let channelMask: UInt64
    public let decoderConfiguration: Data
    public let outputRouteIdentifier: String
    public let requiresAACCompatibilityRendition: Bool
    public init(codec: AudioCodec, profile: Int32, sampleRate: Int32, channelCount: Int32, channelMask: UInt64,
                decoderConfiguration: Data, outputRouteIdentifier: String, requiresAACCompatibilityRendition: Bool) {
        self.codec = codec; self.profile = profile; self.sampleRate = sampleRate; self.channelCount = channelCount
        self.channelMask = channelMask; self.decoderConfiguration = decoderConfiguration
        self.outputRouteIdentifier = outputRouteIdentifier; self.requiresAACCompatibilityRendition = requiresAACCompatibilityRendition
    }
    public func matches(_ source: HLSSourceAudioFacts) -> Bool {
        guard [.ac3, .eac3].contains(codec), !outputRouteIdentifier.isEmpty,
              source.formatValidated, source.service == .independentMain,
              source.codec == codec, source.profile == profile, source.sampleRate == sampleRate,
              source.channelCount == channelCount, source.channelMask == channelMask,
              source.decoderConfiguration == decoderConfiguration, channelMask != 0,
              sampleRate > 0, channelCount > 0 else { return false }
        return codec == .ac3 ? (0...10).contains(profile) : (11...16).contains(profile)
    }
}
