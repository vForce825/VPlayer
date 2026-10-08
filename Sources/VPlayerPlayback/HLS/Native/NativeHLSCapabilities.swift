// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Darwin
import Foundation
import VideoToolbox

enum NativeHLSPlatform: Sendable, Equatable {
    case appleTV
    case iPhone

    static var current: Self {
        #if os(iOS)
        .iPhone
        #else
        .appleTV
        #endif
    }
}

struct NativeHLSPlatformEvidence: Sendable {
    let platform: NativeHLSPlatform
    let model: String
    let hardwareH264: Bool
    let hardwareHEVC: Bool
    let hdrEligible: Bool
    let playable: @Sendable (String) -> Bool

    init(platform: NativeHLSPlatform = .appleTV, model: String,
         hardwareH264: Bool, hardwareHEVC: Bool, hdrEligible: Bool,
         playable: @escaping @Sendable (String) -> Bool) {
        self.platform = platform
        self.model = model
        self.hardwareH264 = hardwareH264
        self.hardwareHEVC = hardwareHEVC
        self.hdrEligible = hdrEligible
        self.playable = playable
    }
}

/// Public system format queries are combined with bounded documented device
/// limits. These are app playback candidates, not HomePod bit-perfect proof.
enum NativeHLSCapabilities {
    @MainActor static func current(facts: HLSCompatibilityFacts, route: PlaybackRouteSemanticIdentity?) -> HLSOutputCapabilities {
        make(facts: facts, route: route, evidence: .init(platform: .current, model: hardwareModel(),
            hardwareH264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
            hardwareHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            hdrEligible: AVPlayer.eligibleForHDRPlayback,
            playable: { AVURLAsset.isPlayableExtendedMIMEType($0) }))
    }

    static func make(facts: HLSCompatibilityFacts, route: PlaybackRouteSemanticIdentity?, evidence: NativeHLSPlatformEvidence) -> HLSOutputCapabilities {
        let known4K = evidence.platform == .appleTV &&
            ["AppleTV6,2", "AppleTV11,1", "AppleTV14,1"].contains(evidence.model)
        // iOS uses its own conservative SDR envelope. This identifies a phone,
        // not a simulator masquerading as one; hardware/MIME/source evidence
        // below remains mandatory and does not promise measured performance.
        let knownPhone = evidence.platform == .iPhone &&
            evidence.model.range(of: "^iPhone[0-9]+,[0-9]+$", options: .regularExpression) != nil
        let modernHDR = ["AppleTV11,1", "AppleTV14,1"].contains(evidence.model)
        // Since tvOS 17 the public API interprets codecs in the MIME container's
        // namespace. A playlist is not a media-data container: qualifying the
        // HLS MIME with MP4 codec tokens can return false for playable HLS.
        // Query playlist support separately; never use WebKit's private SPI.
        let playlistPlayable = evidence.playable("application/vnd.apple.mpegurl")
        let containersPlayable = !facts.media.isEmpty && facts.media.allSatisfy {
            nativeHLSMediaPlayable($0, evidence: evidence)
        }
        var videoFormats: [HLSVideoCapability] = []
        var everyVideoPlayable = facts.media.allSatisfy { $0.video == nil } || known4K || knownPhone
        // Apple HLS authoring 1.3/1.6 and Apple TV 4K technical specifications:
        // https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices
        // https://support.apple.com/en-us/111922
        // https://support.apple.com/en-us/111839
        // Unknown hardware stays outside this device envelope. Exact per-source
        // MIME queries remain necessary even for an allowlisted model.
        if known4K || knownPhone {
            for video in facts.media.compactMap(\.video) {
                guard let codec = video.codec, let mimeCodec = codecString(video),
                      (codec == .h264 ? evidence.hardwareH264 : evidence.hardwareHEVC),
                      evidence.playable("video/mp4; codecs=\"\(mimeCodec)\"") else {
                    everyVideoPlayable = false; continue
                }
                let ranges: Set<HLSVideoRange>
                if codec == .h264 || knownPhone { ranges = [.sdr] }
                else { ranges = evidence.hdrEligible ? [.sdr, .pq, .hlg] : [.sdr] }
                let isHDR = video.videoRange == .pq || video.videoRange == .hlg
                let capability: HLSVideoCapability
                if knownPhone {
                    capability = HLSVideoCapability(codec: codec,
                        profiles: codec == .h264 ? [66, 77, 100] : [1, 2],
                        maximumLevel: codec == .h264 ? 41 : 120,
                        maximumWidth: 1_920, maximumHeight: 1_080,
                        maximumFrameRate: MediaRational(num: 30, den: 1)!,
                        bitDepths: codec == .h264 ? [8] : [8, 10], chromaFormats: [1],
                        tiers: [.main], videoRanges: [.sdr])
                } else {
                    capability = HLSVideoCapability(codec: codec, profiles: codec == .h264 ? [66, 77, 100] : [1, 2],
                    maximumLevel: codec == .h264 ? 52 : 153, maximumWidth: 3_840, maximumHeight: 2_160,
                    maximumFrameRate: MediaRational(num: isHDR && !modernHDR ? 30 : 60, den: 1)!,
                    bitDepths: codec == .h264 ? [8] : [8, 10], chromaFormats: [1], tiers: [.main, .high], videoRanges: ranges)
                }
                if capability.matches(video) { videoFormats.append(capability) }
                else { everyVideoPlayable = false }
            }
        }
        // Candidates for generated audio depend on validated audio decoder
        // support, not on an unrelated native video/container rejection.
        var playableAudio: Set<AudioCodec> = [], generatedAudio: Set<AudioCodec> = [.aac]
        var candidates: [HLSCompressedAudioAdmissionCandidate] = []
        var nativeCandidates: [HLSNativeAudioAdmissionCandidate] = []
        for codec in [AudioCodec.aac, .ac3, .eac3] {
            let audio = facts.media.flatMap(\.audio).filter { $0.codec == codec }
            guard playlistPlayable, !audio.isEmpty, audio.allSatisfy({ value in
                guard value.formatValidated, value.service == .independentMain, value.sampleRate > 0,
                      value.sampleRate <= 96_000, (1...8).contains(value.channelCount), value.channelMask != 0,
                      value.channelMask.nonzeroBitCount == value.channelCount, let token = audioCodecString(value) else { return false }
                return evidence.playable("audio/mp4; codecs=\"\(token)\"")
            }) else { continue }
            playableAudio.insert(codec)
        }
        // Capabilities are broad envelopes. A passing sibling must not lend its
        // envelope to a rejected container, codec query or device/HDR format.
        let nativeGraphPlayable = playlistPlayable && containersPlayable && everyVideoPlayable
        let nativeAudio: Set<AudioCodec> = nativeGraphPlayable ? playableAudio : []
        if !nativeGraphPlayable { videoFormats.removeAll() }
        if let owner = facts.owner, facts.complete, route?.backend == .hlsAVPlayer,
           route?.ports.contains(.airPlay) == true, route?.ports.contains(.bluetooth) == false {
            for audio in facts.media.flatMap(\.audio) {
                guard let codec = audio.codec, codec == .ac3 || codec == .eac3, playableAudio.contains(codec) else { continue }
                let routeScope = "owned-\(owner.backendIdentity.sessionIdentity.sessionID)-\(owner.backendIdentity.backendGeneration)-\(owner.prepareNonce)-\(owner.outputLifecycleNonce)"
                if nativeAudio.contains(codec) {
                    nativeCandidates.append(.init(owner: owner, codec: codec, profile: audio.profile,
                        sampleRate: audio.sampleRate, channelCount: audio.channelCount, channelMask: audio.channelMask,
                        decoderConfiguration: audio.decoderConfiguration, outputRouteIdentifier: routeScope))
                }
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

    private static func nativeHLSMediaPlayable(_ media: HLSMediaFacts, evidence: NativeHLSPlatformEvidence) -> Bool {
        guard !media.hasUnsupportedTracks, media.audio.count <= 8 else { return false }
        if media.container == .webVTT { return media.video == nil && media.audio.isEmpty }
        let mime: String
        switch media.container {
        case .mpegTS:
            // Apple HLS authoring permits AVC in TS. This narrowly admitted
            // AVC/LC-AAC contract is backed by the byte-fed PAT/PMT/PES probe;
            // selected AVPlayer tracks must still match before activation.
            // video/mp2t uses the ISO/IEC 13818-1 codec namespace, so feeding it
            // avc1/mp4a tokens is not an HLS capability test. Query those tokens
            // in their BMFF namespace for decoder/format evidence, NOT TS proof.
            // Other TS combinations retain generated handling until separately
            // verified; HEVC remains fMP4-only for native HLS.
            guard media.video == nil || media.video?.codec == .h264,
                  media.audio.allSatisfy({ $0.formatValidated && $0.service == .independentMain &&
                      HLSAudioProcessingPolicy.supportsSourceLC($0) }) else { return false }
            mime = media.video == nil ? "audio/mp4" : "video/mp4"
        case .fragmentedMP4: mime = media.video == nil ? "audio/mp4" : "video/mp4"
        case .isoBMFF, .webVTT, .unknown: return false
        }
        var codecs: [String] = []
        if let video = media.video {
            guard let token = codecString(video) else { return false }
            codecs.append(token)
        }
        for audio in media.audio {
            guard let token = audioCodecString(audio) else { return false }
            codecs.append(token)
        }
        guard !codecs.isEmpty else { return false }
        return evidence.playable("\(mime); codecs=\"\(codecs.joined(separator: ","))\"")
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
