// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public enum HLSScanEvidence: String, Sendable, Hashable { case unknown, progressive, interlaced, contradictory }
public enum HLSVideoTier: String, Sendable, Hashable { case main, high }
public enum HLSVideoRange: String, Sendable, Hashable { case sdr, pq, hlg }
public enum HLSSourceAudioService: String, Sendable, Hashable { case unknown, independentMain, dependent, associated }
public enum HLSSourceAudioPriming: Sendable, Hashable {
    case unknown
    case notSignaledPreserveTimestamps
    case explicit(leadingSamples: UInt32, trailingSamples: UInt32)
}

public struct HLSVideoFacts: Sendable, Hashable {
    public let codec: VideoCodec?
    public let profile: Int32
    public let scan: HLSScanEvidence
    public let parameterSetsValidated: Bool
    public let configurationFingerprint: Data
    public let width: Int32, height: Int32
    public let chromaFormat: UInt8, bitDepth: UInt8, level: UInt8
    public let parserProgressiveFrames: Int32, parserInterlacedFrames: Int32
    public let compatibilityFlags: UInt32?
    public let constraintIndicatorFlags: UInt64?
    public let tier: HLSVideoTier?
    public let frameRate: MediaRational?
    public let videoRange: HLSVideoRange?
    public let colorPrimaries: DemuxColorPrimaries?
    public let colorTransfer: DemuxColorTransfer?
    public let colorMatrix: DemuxColorMatrix?
    public let sampleEntry: String?
    public init(codec: VideoCodec?, profile: Int32, scan: HLSScanEvidence, parameterSetsValidated: Bool,
                configurationFingerprint: Data = Data(), width: Int32 = 0, height: Int32 = 0,
                chromaFormat: UInt8 = 0, bitDepth: UInt8 = 0, level: UInt8 = 0,
                parserProgressiveFrames: Int32 = 0, parserInterlacedFrames: Int32 = 0,
                compatibilityFlags: UInt32? = nil, constraintIndicatorFlags: UInt64? = nil,
                tier: HLSVideoTier? = nil, frameRate: MediaRational? = nil, videoRange: HLSVideoRange? = nil,
                colorPrimaries: DemuxColorPrimaries? = nil, colorTransfer: DemuxColorTransfer? = nil,
                colorMatrix: DemuxColorMatrix? = nil, sampleEntry: String? = nil) {
        self.codec = codec; self.profile = profile; self.scan = scan; self.parameterSetsValidated = parameterSetsValidated
        self.configurationFingerprint = configurationFingerprint; self.width = width; self.height = height
        self.chromaFormat = chromaFormat; self.bitDepth = bitDepth; self.level = level
        self.parserProgressiveFrames = parserProgressiveFrames; self.parserInterlacedFrames = parserInterlacedFrames
        self.compatibilityFlags = compatibilityFlags; self.constraintIndicatorFlags = constraintIndicatorFlags
        self.tier = tier; self.frameRate = frameRate; self.videoRange = videoRange
        self.colorPrimaries = colorPrimaries; self.colorTransfer = colorTransfer; self.colorMatrix = colorMatrix; self.sampleEntry = sampleEntry
    }
}

public struct HLSSourceAudioFacts: Sendable, Hashable {
    public let codec: AudioCodec?
    public let profile: Int32
    public let sampleRate: Int32, channelCount: Int32
    public let channelMask: UInt64
    public let decoderConfiguration: Data
    public let priming: HLSSourceAudioPriming
    public let service: HLSSourceAudioService
    public let formatValidated: Bool
    public init(codec: AudioCodec?, profile: Int32 = -1, sampleRate: Int32 = 0, channelCount: Int32 = 0,
                channelMask: UInt64 = 0, decoderConfiguration: Data = Data(), priming: HLSSourceAudioPriming = .unknown,
                service: HLSSourceAudioService = .unknown, formatValidated: Bool = false) {
        self.codec = codec; self.profile = profile; self.sampleRate = sampleRate; self.channelCount = channelCount
        self.channelMask = channelMask; self.decoderConfiguration = decoderConfiguration; self.priming = priming
        self.service = service; self.formatValidated = formatValidated
    }
}

public struct HLSMediaFacts: Sendable, CustomStringConvertible, CustomReflectable {
    public enum Container: String, Sendable { case mpegTS, fragmentedMP4, isoBMFF, webVTT, unknown }
    public let url: URL
    public let container: Container
    public let video: HLSVideoFacts?
    public let audio: [HLSSourceAudioFacts]
    public let hasUnsupportedTracks: Bool
    public init(url: URL, container: Container, video: HLSVideoFacts?, audio: [HLSSourceAudioFacts], hasUnsupportedTracks: Bool) {
        self.url = url; self.container = container; self.video = video; self.audio = audio; self.hasUnsupportedTracks = hasUnsupportedTracks
    }
    public var description: String { "HLSMediaFacts(container=\(container), audioTracks=\(audio.count))" }
    public var customMirror: Mirror { Mirror(self, children: ["container": container.rawValue, "audioTracks": audio.count]) }
}
public struct HLSCompatibilityFacts: Sendable, CustomStringConvertible, CustomReflectable {
    public let owner: PlaybackSourceOwner?
    public let resolutionGeneration: UInt64
    public let media: [HLSMediaFacts]
    public let complete: Bool
    public let inspectedBytes: Int
    public let formatFingerprint: Data
    public let initializationReceipts: HLSInitializationReceipts
    public init(source: ResolvedPlaybackSource, media: [HLSMediaFacts], complete: Bool, inspectedBytes: Int,
                initializationReceipts: HLSInitializationReceipts = .empty) {
        owner = source.context.owner; resolutionGeneration = source.generation
        self.media = media; self.complete = complete; self.inspectedBytes = inspectedBytes
        self.initializationReceipts = initializationReceipts
        var components: [String] = []
        if case let .hls(graph) = source.topology {
            for document in graph.orderedDocuments where document.kind == .master {
                for variant in document.variants + document.iframeVariants {
                    components.append("variant:\(variant.url.path)")
                    components += variant.attributes.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
                }
                for rendition in document.renditions {
                    components.append("rendition:\(rendition.url?.path ?? "in-band")")
                    components += rendition.attributes.filter { $0.key != "URI" }.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
                }
            }
        }
        for item in media {
            components.append(item.container.rawValue)
            if let video = item.video {
                components.append("video:\(video.codec?.rawValue ?? 0):\(video.profile):\(video.scan.rawValue):\(video.configurationFingerprint.base64EncodedString())")
                components.append("entry:\(String(describing: video.sampleEntry)):\(String(describing: video.compatibilityFlags)):\(String(describing: video.constraintIndicatorFlags))")
                components.append("format:\(video.width):\(video.height):\(video.level):\(String(describing: video.tier)):\(String(describing: video.frameRate)):\(String(describing: video.videoRange)):\(video.chromaFormat):\(video.bitDepth):\(String(describing: video.colorPrimaries)):\(String(describing: video.colorTransfer)):\(String(describing: video.colorMatrix))")
            }
            for audio in item.audio {
                components.append("audio:\(audio.codec?.rawValue ?? 0):\(audio.profile):\(audio.sampleRate):\(audio.channelCount):\(audio.channelMask):\(audio.service.rawValue):\(audio.decoderConfiguration.base64EncodedString()):\(audio.priming)")
            }
        }
        formatFingerprint = Data(SHA256.hash(data: Data(components.joined(separator: "\n").utf8)))
    }
    public var description: String { "HLSCompatibilityFacts(generation=\(resolutionGeneration), complete=\(complete))" }
    public var customMirror: Mirror { Mirror(self, children: ["generation": resolutionGeneration, "complete": complete]) }
}

/// Platform codec existence is only one prerequisite. Native video uses precise
/// format envelopes; generated Dolby candidates remain distinct from verified output.
public struct HLSOutputCapabilities: Sendable {
    public let videoProfiles: [VideoCodec: Set<Int32>]
    public let videoFormats: [HLSVideoCapability]
    public let nativeAudioCodecs: Set<AudioCodec>
    public let nativeAudioAdmissionCandidates: [HLSNativeAudioAdmissionCandidate]
    public let compressedAudioCodecs: Set<AudioCodec>
    public let verifiedCompressedAudioConfigurations: [HLSVerifiedCompressedAudioConfiguration]
    public let compressedAudioAdmissionCandidates: [HLSCompressedAudioAdmissionCandidate]
    public let supportsWebVTT: Bool
    public let supportsGenerated: Bool
    public let supportsInBandClosedCaptions: Bool
    public init(videoProfiles: [VideoCodec: Set<Int32>] = [:], videoFormats: [HLSVideoCapability] = [],
                nativeAudioCodecs: Set<AudioCodec> = [], nativeAudioAdmissionCandidates: [HLSNativeAudioAdmissionCandidate] = [],
                compressedAudioCodecs: Set<AudioCodec> = [],
                verifiedCompressedAudioConfigurations: [HLSVerifiedCompressedAudioConfiguration] = [],
                compressedAudioAdmissionCandidates: [HLSCompressedAudioAdmissionCandidate] = [],
                supportsWebVTT: Bool = false, supportsGenerated: Bool = false, supportsInBandClosedCaptions: Bool = false) {
        self.videoProfiles = videoProfiles; self.videoFormats = videoFormats; self.nativeAudioCodecs = nativeAudioCodecs
        self.nativeAudioAdmissionCandidates = nativeAudioAdmissionCandidates
        self.compressedAudioCodecs = compressedAudioCodecs; self.verifiedCompressedAudioConfigurations = verifiedCompressedAudioConfigurations
        self.compressedAudioAdmissionCandidates = compressedAudioAdmissionCandidates
        self.supportsWebVTT = supportsWebVTT; self.supportsGenerated = supportsGenerated; self.supportsInBandClosedCaptions = supportsInBandClosedCaptions
    }
}

public enum HLSAudioDecision: Sendable, Equatable { case source, passthrough(AudioCodec), compatibleAAC }
public struct HLSPlaybackPlan: Sendable {
    public enum Transport: String, Sendable { case native, proxy, generated }
    public enum Video: String, Sendable { case source, remux, deinterlaceAndEncode, unsupported }
    public let owner: PlaybackSourceOwner
    public let resolutionGeneration: UInt64
    public let transport: Transport
    public let video: Video
    public let audio: HLSAudioDecision
    public let selectedServiceURL: URL?
    public let formatFingerprint: Data
    public let compressedAudioConfiguration: HLSVerifiedCompressedAudioConfiguration?
    public let compressedAudioAdmissionCandidate: HLSCompressedAudioAdmissionCandidate?
    public init(owner: PlaybackSourceOwner, resolutionGeneration: UInt64, transport: Transport, video: Video,
                audio: HLSAudioDecision, selectedServiceURL: URL?, formatFingerprint: Data,
                compressedAudioConfiguration: HLSVerifiedCompressedAudioConfiguration? = nil,
                compressedAudioAdmissionCandidate: HLSCompressedAudioAdmissionCandidate? = nil) {
        self.owner = owner; self.resolutionGeneration = resolutionGeneration; self.transport = transport
        self.video = video; self.audio = audio; self.selectedServiceURL = selectedServiceURL; self.formatFingerprint = formatFingerprint
        self.compressedAudioConfiguration = compressedAudioConfiguration; self.compressedAudioAdmissionCandidate = compressedAudioAdmissionCandidate
    }
}
