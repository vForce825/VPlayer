// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Darwin
import Foundation
import VideoToolbox

struct NativeHLSPlatformEvidence: Sendable {
    let model: String
    let hardwareH264: Bool
    let hardwareHEVC: Bool
    let hdrEligible: Bool
    let playable: @Sendable (String) -> Bool
}

/// Public system format queries are combined with bounded documented device
/// limits. These are app playback candidates, not HomePod bit-perfect proof.
enum NativeHLSCapabilities {
    @MainActor static func current(facts: HLSCompatibilityFacts, route: PlaybackRouteSemanticIdentity?) -> HLSOutputCapabilities {
        make(facts: facts, route: route, evidence: .init(model: hardwareModel(),
            hardwareH264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
            hardwareHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            hdrEligible: AVPlayer.eligibleForHDRPlayback,
            playable: { AVURLAsset.isPlayableExtendedMIMEType($0) }))
    }

    static func make(facts: HLSCompatibilityFacts, route: PlaybackRouteSemanticIdentity?, evidence: NativeHLSPlatformEvidence) -> HLSOutputCapabilities {
        let known4K = ["AppleTV6,2", "AppleTV11,1", "AppleTV14,1"].contains(evidence.model)
        let modernHDR = ["AppleTV11,1", "AppleTV14,1"].contains(evidence.model)
        var videoFormats: [HLSVideoCapability] = []
        // Apple HLS authoring 1.3/1.6 and Apple TV 4K technical specifications:
        // https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices
        // https://support.apple.com/en-us/111922
        // https://support.apple.com/en-us/111839
        // Unknown hardware stays outside this device envelope. Exact per-source
        // MIME queries remain necessary even for an allowlisted model.
        if known4K {
            for video in facts.media.compactMap(\.video) {
                guard let codec = video.codec, let mimeCodec = codecString(video),
                      (codec == .h264 ? evidence.hardwareH264 : evidence.hardwareHEVC),
                      evidence.playable("video/mp4; codecs=\"\(mimeCodec)\""),
                      evidence.playable("application/vnd.apple.mpegurl; codecs=\"\(mimeCodec)\"") else { continue }
                let ranges: Set<HLSVideoRange>
                if codec == .h264 { ranges = [.sdr] }
                else { ranges = evidence.hdrEligible ? [.sdr, .pq, .hlg] : [.sdr] }
                let isHDR = video.videoRange == .pq || video.videoRange == .hlg
                let capability = HLSVideoCapability(codec: codec, profiles: codec == .h264 ? [66, 77, 100] : [1, 2],
                    maximumLevel: codec == .h264 ? 52 : 153, maximumWidth: 3_840, maximumHeight: 2_160,
                    maximumFrameRate: MediaRational(num: isHDR && !modernHDR ? 30 : 60, den: 1)!,
                    bitDepths: codec == .h264 ? [8] : [8, 10], chromaFormats: [1], tiers: [.main, .high], videoRanges: ranges)
                if capability.matches(video) { videoFormats.append(capability) }
            }
        }
        var nativeAudio: Set<AudioCodec> = [], generatedAudio: Set<AudioCodec> = [.aac]
        var candidates: [HLSCompressedAudioAdmissionCandidate] = []
        var nativeCandidates: [HLSNativeAudioAdmissionCandidate] = []
        for codec in [AudioCodec.aac, .ac3, .eac3] {
            let audio = facts.media.flatMap(\.audio).filter { $0.codec == codec }
            guard !audio.isEmpty, audio.allSatisfy({ value in
                guard value.formatValidated, value.service == .independentMain, value.sampleRate > 0,
                      value.sampleRate <= 96_000, (1...8).contains(value.channelCount), value.channelMask != 0,
                      value.channelMask.nonzeroBitCount == value.channelCount, let token = audioCodecString(value) else { return false }
                return evidence.playable("audio/mp4; codecs=\"\(token)\"") &&
                    evidence.playable("application/vnd.apple.mpegurl; codecs=\"\(token)\"")
            }) else { continue }
            nativeAudio.insert(codec)
        }
        if let owner = facts.owner, facts.complete, route?.backend == .hlsAVPlayer,
           route?.ports.contains(.airPlay) == true, route?.ports.contains(.bluetooth) == false {
            for audio in facts.media.flatMap(\.audio) {
                guard let codec = audio.codec, codec == .ac3 || codec == .eac3, nativeAudio.contains(codec) else { continue }
                let routeScope = "owned-\(owner.backendIdentity.sessionIdentity.sessionID)-\(owner.backendIdentity.backendGeneration)-\(owner.prepareNonce)-\(owner.outputLifecycleNonce)"
                nativeCandidates.append(.init(owner: owner, codec: codec, profile: audio.profile,
                    sampleRate: audio.sampleRate, channelCount: audio.channelCount, channelMask: audio.channelMask,
                    decoderConfiguration: audio.decoderConfiguration, outputRouteIdentifier: routeScope))
                guard audio.sampleRate == 48_000, (1...6).contains(audio.channelCount),
                      audio.priming == .notSignaledPreserveTimestamps,
                      audio.channelMask & ~UInt64(0x7FF) == 0,
                      (codec == .ac3 ? (0...10).contains(audio.profile) : (11...16).contains(audio.profile)) else { continue }
                generatedAudio.insert(codec)
                candidates.append(.init(codec: codec, profile: audio.profile, sampleRate: audio.sampleRate,
                    channelCount: audio.channelCount, channelMask: audio.channelMask, decoderConfiguration: audio.decoderConfiguration,
                    outputRouteIdentifier: routeScope,
                    requiresAACCompatibilityRendition: false))
            }
        }
        return .init(videoProfiles: [.h264: [66, 77, 100], .hevc: [1, 2]], videoFormats: videoFormats,
            nativeAudioCodecs: nativeAudio, nativeAudioAdmissionCandidates: nativeCandidates,
            compressedAudioCodecs: generatedAudio,
            compressedAudioAdmissionCandidates: candidates, supportsWebVTT: true, supportsGenerated: true,
            supportsInBandClosedCaptions: true)
    }

    static func codecString(_ video: HLSVideoFacts) -> String? {
        guard video.parameterSetsValidated, video.level > 0 else { return nil }
        switch video.codec {
        case .h264:
            guard (0...255).contains(video.profile), let flags = video.compatibilityFlags, flags <= 255 else { return nil }
            let entry = video.sampleEntry ?? "avc1"
            guard entry == "avc1" || entry == "avc3" else { return nil }
            return entry + "." + String(format: "%02X%02X%02X", video.profile, flags, video.level)
        case .hevc:
            guard (1...31).contains(video.profile), let compatibility = video.compatibilityFlags,
                  let constraints = video.constraintIndicatorFlags, constraints < (UInt64(1) << 48), let tier = video.tier else { return nil }
            var reversed: UInt32 = 0, input = compatibility
            for _ in 0..<32 { reversed = reversed << 1 | input & 1; input >>= 1 }
            var constraintBytes = (0..<6).map { UInt8(truncatingIfNeeded: constraints >> ((5 - $0) * 8)) }
            while constraintBytes.last == 0 { constraintBytes.removeLast() }
            let suffix = constraintBytes.isEmpty ? "" : "." + constraintBytes.map { String(format: "%02X", $0) }.joined(separator: ".")
            let entry = video.sampleEntry ?? "hvc1"
            guard entry == "hvc1" || entry == "hev1" else { return nil }
            return "\(entry).\(video.profile).\(String(reversed, radix: 16, uppercase: true)).\(tier == .high ? "H" : "L")\(video.level)\(suffix)"
        case nil: return nil
        }
    }
    private static func audioCodecString(_ audio: HLSSourceAudioFacts) -> String? {
        switch audio.codec {
        case .aac:
            guard audio.profile == 1, let value = try? AudioSpecificConfig.parse(audio.decoderConfiguration),
                  value.kind == .aacLC, value.outputSampleRate == audio.sampleRate,
                  value.outputChannelCount == audio.channelCount else { return nil }
            return "mp4a.40.2"
        case .ac3: return (0...10).contains(audio.profile) ? "ac-3" : nil
        case .eac3: return (11...16).contains(audio.profile) ? "ec-3" : nil
        default: return nil
        }
    }
    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        var count = 0
        guard sysctlbyname("hw.machine", nil, &count, nil, 0) == 0, count > 1, count <= 256 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname("hw.machine", $0.baseAddress, &count, nil, 0) }
        guard result == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        #endif
    }
}
