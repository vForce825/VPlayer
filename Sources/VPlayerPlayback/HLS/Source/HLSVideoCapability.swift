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
        return Self.supportsNativeColor(facts)
    }

    static func supportsNativeColor(_ facts: HLSVideoFacts) -> Bool {
        switch facts.videoRange {
        case .sdr:
            if facts.colorPrimaries == .bt709 && facts.colorTransfer == .bt709 && facts.colorMatrix == .bt709 { return true }
            // Rec.601: keep distinct primaries and source codes; native AVPlayer
            // owns their interpretation. H.273 transfer 6 equals 1, matrix 5 equals 6.
            return facts.colorPrimaries?.isRec601 == true && facts.colorMatrix?.isRec601 == true &&
                (facts.colorTransfer == .bt709 || facts.colorTransfer == .smpte170M)
        case .pq: return facts.codec == .hevc && facts.bitDepth == 10 && facts.colorPrimaries == .bt2020 && facts.colorTransfer == .pq && facts.colorMatrix == .bt2020Nonconstant
        case .hlg: return facts.codec == .hevc && facts.bitDepth == 10 && facts.colorPrimaries == .bt2020 && facts.colorTransfer == .hlg && facts.colorMatrix == .bt2020Nonconstant
        case nil: return false
        }
    }
}

// Source recognition is broader than the current generated color contract.
// Missing evidence retains its existing policy; only newly recognized codes
// are fenced here, before any fallback can normalize them to BT.709.
extension HLSVideoFacts {
    var requiresNativeRec601Color: Bool {
        colorPrimaries?.isRec601 == true || colorTransfer?.isRec601 == true || colorMatrix?.isRec601 == true
    }
}
