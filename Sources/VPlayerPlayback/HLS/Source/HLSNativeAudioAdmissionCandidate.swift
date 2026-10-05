// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Exact route-scoped proposal to attempt system playback. This is neither
/// generated-writer evidence nor proof of the selected AVPlayer output format.
public struct HLSNativeAudioAdmissionCandidate: Sendable, Hashable {
    public let owner: PlaybackSourceOwner
    public let codec: AudioCodec
    public let profile: Int32
    public let sampleRate: Int32, channelCount: Int32
    public let channelMask: UInt64
    public let decoderConfiguration: Data
    public let outputRouteIdentifier: String
    public init(owner: PlaybackSourceOwner, codec: AudioCodec, profile: Int32, sampleRate: Int32,
                channelCount: Int32, channelMask: UInt64, decoderConfiguration: Data, outputRouteIdentifier: String) {
        self.owner = owner; self.codec = codec; self.profile = profile; self.sampleRate = sampleRate
        self.channelCount = channelCount; self.channelMask = channelMask; self.decoderConfiguration = decoderConfiguration
        self.outputRouteIdentifier = outputRouteIdentifier
    }
    public func matches(_ source: HLSSourceAudioFacts, owner: PlaybackSourceOwner) -> Bool {
        guard self.owner == owner, !outputRouteIdentifier.isEmpty, source.formatValidated,
              source.service == .independentMain, source.codec == codec, source.profile == profile,
              source.sampleRate == sampleRate, source.channelCount == channelCount,
              source.channelMask == channelMask, source.decoderConfiguration == decoderConfiguration,
              sampleRate > 0, channelCount > 0, channelMask.nonzeroBitCount == channelCount else { return false }
        switch codec { case .ac3: return (0...10).contains(profile); case .eac3: return (11...16).contains(profile); default: return false }
    }
}
