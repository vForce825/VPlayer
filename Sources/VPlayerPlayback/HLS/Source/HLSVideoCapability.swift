// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// One combined format envelope. Independent broad codec/profile sets must not
/// accidentally form unsupported dimension/rate/tier/HDR combinations.
public struct HLSVideoCapability: Sendable {
    public let codec: VideoCodec
    public let profiles: Set<Int32>
    public let maximumLevel: UInt8
    public let maximumWidth: Int32, maximumHeight: Int32
    public let maximumFrameRate: MediaRational
    public let bitDepths: Set<UInt8>, chromaFormats: Set<UInt8>
    public let tiers: Set<HLSVideoTier>
    public let videoRanges: Set<HLSVideoRange>
    public init(codec: VideoCodec, profiles: Set<Int32>, maximumLevel: UInt8, maximumWidth: Int32, maximumHeight: Int32,
                maximumFrameRate: MediaRational, bitDepths: Set<UInt8>, chromaFormats: Set<UInt8>,
                tiers: Set<HLSVideoTier>, videoRanges: Set<HLSVideoRange>) {
        self.codec = codec; self.profiles = profiles; self.maximumLevel = maximumLevel
        self.maximumWidth = maximumWidth; self.maximumHeight = maximumHeight; self.maximumFrameRate = maximumFrameRate
        self.bitDepths = bitDepths; self.chromaFormats = chromaFormats; self.tiers = tiers; self.videoRanges = videoRanges
    }
    public func matches(_ facts: HLSVideoFacts) -> Bool {
        guard facts.parameterSetsValidated, facts.scan == .progressive, facts.codec == codec,
              profiles.contains(facts.profile), facts.level > 0, facts.level <= maximumLevel,
              facts.width > 0, facts.width <= maximumWidth, facts.height > 0, facts.height <= maximumHeight,
              bitDepths.contains(facts.bitDepth), chromaFormats.contains(facts.chromaFormat),
              let tier = facts.tier, tiers.contains(tier), let range = facts.videoRange, videoRanges.contains(range),
              let rate = facts.frameRate, rate.num > 0, rate.den > 0, maximumFrameRate.num > 0,
              Int64(rate.num) * Int64(maximumFrameRate.den) <= Int64(maximumFrameRate.num) * Int64(rate.den),
              facts.colorPrimaries != nil, facts.colorTransfer != nil, facts.colorMatrix != nil else { return false }
        return true
    }
}
