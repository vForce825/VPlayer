// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum HLSVideoSampleEntry: UInt8, Sendable, Hashable {
    case avc1
    case avc3
    case hvc1
    case hev1
}

enum HLSVideoDynamicRange: UInt8, Sendable, Hashable {
    case sdr
    case hlg
    case pq
}

struct SignedMediaRational: Sendable, Hashable {
    let num: Int32
    let den: Int32

    init?(num: Int32, den: Int32) {
        guard den > 0 else { return nil }
        if num == 0 {
            self.num = 0
            self.den = 1
            return
        }
        let divisor = signatureRationalGCD(UInt64(num.magnitude), UInt64(den))
        self.num = num / Int32(divisor)
        self.den = den / Int32(divisor)
    }
}

struct HLSCleanApertureSignature: Sendable, Hashable {
    let width: MediaRational
    let height: MediaRational
    let horizontalOffset: SignedMediaRational
    let verticalOffset: SignedMediaRational
}

struct OutputSelectionSignature: Sendable, Hashable {
    let sampleEntry: HLSVideoSampleEntry
    let codec: VideoCodec
    let profile: Int32
    let level: Int32
    let width: Int32
    let height: Int32
    let frameRate: MediaRational
    let pixelFormat: UInt32
    let bitDepth: UInt8
    let dynamicRange: HLSVideoDynamicRange
    let frozenBitrateEnvelope: UInt64
}

struct OutputSampleDescriptionSignature: Sendable, Hashable {
    let range: DemuxColorRange?
    let primaries: DemuxColorPrimaries?
    let transfer: DemuxColorTransfer?
    let matrix: DemuxColorMatrix?
    let cleanAperture: HLSCleanApertureSignature?
    let sampleAspectRatio: MediaRational?
    let chromaLocation: DemuxChromaLocation?
    let masteringDisplay: DemuxMasteringDisplayMetadata?
    let contentLightLevel: DemuxContentLightLevelMetadata?
    let codecConfigurationDigest: Data
}

struct OutputVideoSignature: Sendable, Hashable {
    let renditionIdentity: String
    let selection: OutputSelectionSignature
    let sampleDescription: OutputSampleDescriptionSignature
}

struct OutputAudioRenditionSignature: Sendable, Hashable {
    let renditionIdentity: String
    let codec: AudioCodec
    let channelCount: Int32
    let channelLayoutMask: UInt64?
    let frozenBitrateEnvelope: UInt64
    let cookieDigest: Data
    let trackMetadata: DemuxTrackMetadata
}

enum OutputFormatSignatureError: Error, Equatable {
    case empty
    case duplicateAudioRenditionIdentity(String)
}

struct OutputFormatSignature: Sendable, Hashable {
    let video: OutputVideoSignature?
    let audioRenditions: [OutputAudioRenditionSignature]
    let measuredBitrate: UInt64

    init(
        video: OutputVideoSignature?,
        audioRenditions: [OutputAudioRenditionSignature],
        measuredBitrate: UInt64
    ) throws {
        guard video != nil || !audioRenditions.isEmpty else {
            throw OutputFormatSignatureError.empty
        }
        var identities = Set<String>()
        for rendition in audioRenditions {
            guard identities.insert(rendition.renditionIdentity).inserted else {
                throw OutputFormatSignatureError.duplicateAudioRenditionIdentity(
                    rendition.renditionIdentity
                )
            }
        }
        self.video = video
        self.audioRenditions = audioRenditions.sorted {
            $0.renditionIdentity < $1.renditionIdentity
        }
        self.measuredBitrate = measuredBitrate
    }

    func requiresNewGeneration(comparedTo previous: Self) -> Bool {
        video != previous.video || audioRenditions != previous.audioRenditions
    }
}

private func signatureRationalGCD(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var first = lhs
    var second = rhs
    while second != 0 { (first, second) = (second, first % second) }
    return first == 0 ? 1 : first
}
