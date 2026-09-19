// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum VideoCodecTier: UInt8, Sendable, Hashable {
    case main
    case high
}

/// Inspector 与 generation 准入器之间的最小不可变合同。
///
/// 具体 inspection proof 仍负责强持有准确 backing/range/digest；这里仅消费决定
/// 整个输出 generation 能否继续 remux 所需的规范化字段。
protocol VideoRemuxInspectionEvidence: Sendable {
    var remuxGeneration: MediaGeneration { get }
    var remuxCodec: VideoCodec { get }
    var remuxRandomAccessKind: VideoRandomAccessKind { get }
    var remuxParameterSetIdentity: VideoAccessUnitSHA256? { get }
    var remuxFormatIdentity: VideoAccessUnitSHA256? { get }
    var remuxProfileIDC: UInt8 { get }
    var remuxProfileCompatibilityFlags: UInt32 { get }
    var remuxLevelIDC: UInt8 { get }
    var remuxTier: VideoCodecTier { get }
    var remuxWidth: Int32? { get }
    var remuxHeight: Int32? { get }
    var remuxFrameRate: MediaRational? { get }
    var remuxCodedPictureSizeInMacroblocks: UInt32? { get }
    var remuxCodedLumaPictureSize: UInt64? { get }
    var remuxMaximumReferenceFrames: UInt32? { get }
    var remuxChromaFormatIDC: UInt8? { get }
    var remuxBitDepthLuma: UInt8? { get }
    var remuxBitDepthChroma: UInt8? { get }
    var remuxColorPrimaries: DemuxColorPrimaries? { get }
    var remuxColorTransfer: DemuxColorTransfer? { get }
    var remuxColorMatrix: DemuxColorMatrix? { get }
    var remuxMasteringDisplay: DemuxMasteringDisplayMetadata? { get }
    var remuxContentLightLevel: DemuxContentLightLevelMetadata? { get }
    var remuxScanClassification: VideoScanClassificationEvidence { get }
    var remuxPresentationTimeStamp: ExactMediaTime? { get }
    var remuxDecodeTimeStamp: ExactMediaTime? { get }
    var remuxDuration: ExactMediaTime? { get }
    var remuxContainsVCL: Bool { get }
    var remuxContainsInBandParameterSets: Bool { get }
    var remuxAllVCLAreRandomAccess: Bool { get }
    var remuxConflictingRandomAccessKinds: Bool { get }
    var remuxHasSinglePrimaryPictureStartSlice: Bool { get }
}

enum VideoRemuxPath: UInt8, Sendable, Equatable {
    case remux
    case transcode
}

enum VideoRemuxTranscodeReason: UInt8, Sendable, Equatable {
    case interlaced
    case notIDR
    case openGOP
    case missingDecodeTimestamp
    case nonMonotonicDecodeTimestamp
    case nonIncreasingIDRPresentationTimestamp
    case randomAccessIntervalExceeded
    case mixedRandomAccessAccessUnit
    case conflictingRandomAccessKinds
    case invalidPrimaryPictureStructure
    case h264TenBit
    case parameterSetsChanged
    case formatChanged
}

enum VideoRemuxEligibilityError: Error, Sendable, Equatable {
    case sampleEntryCodecMismatch
    case generationMismatch
    case generationFenced
    case codecMismatch
    case randomAccessCodecMismatch
    case unknownScanClassification
    case missingVCL
    case unknownParameterSetSignature
    case unknownFormatSignature
    case invalidPresentationTimestamp
    case invalidDuration
    case missingDimensions
    case invalidDimensions
    case dimensionsExceeded
    case missingFrameRate
    case frameRateExceeded
    case missingChromaFormat
    case unsupportedChromaFormat
    case missingBitDepth
    case inconsistentBitDepth
    case unsupportedBitDepth
    case unsupportedProfile
    case unsupportedProfileLevel
    case profileBitDepthMismatch
    case hdrRequiresTenBit
    case inconsistentHDRColorMetadata
    case inconsistentColorMetadata
    case inconsistentRandomAccessEvidence
    case missingLevelEvidence
    case levelFrameSizeExceeded
    case levelSampleRateExceeded
    case levelDecodedPictureBufferExceeded
    case arithmeticOverflow
}

enum VideoRemuxParameterSetDisposition: UInt8, Sendable, Equatable {
    /// 从媒体 AU 删除 in-band 参数集，并只写入 sample description 配置。
    case stripInBandToConfiguration

    /// 保留与冻结配置完全一致的 in-band 参数集。
    case preserveInBand
}

struct VideoRemuxAdmissionProof: @unchecked Sendable {
    let source: VideoAccessUnitInspectionProof
    let generation: MediaGeneration
    let sampleEntry: HLSVideoSampleEntry
    let parameterSetIdentity: VideoAccessUnitSHA256
    let formatIdentity: VideoAccessUnitSHA256
    let parameterSetDisposition: VideoRemuxParameterSetDisposition
    let sourceContainsInBandParameterSets: Bool
    let maximumReferenceFrames: UInt32
    let bitrateEnvelope: VideoBitrateEnvelope

    fileprivate init(
        source: VideoAccessUnitInspectionProof,
        generation: MediaGeneration,
        sampleEntry: HLSVideoSampleEntry,
        parameterSetIdentity: VideoAccessUnitSHA256,
        formatIdentity: VideoAccessUnitSHA256,
        parameterSetDisposition: VideoRemuxParameterSetDisposition,
        sourceContainsInBandParameterSets: Bool,
        maximumReferenceFrames: UInt32,
        bitrateEnvelope: VideoBitrateEnvelope
    ) {
        self.source = source
        self.generation = generation
        self.sampleEntry = sampleEntry
        self.parameterSetIdentity = parameterSetIdentity
        self.formatIdentity = formatIdentity
        self.parameterSetDisposition = parameterSetDisposition
        self.sourceContainsInBandParameterSets = sourceContainsInBandParameterSets
        self.maximumReferenceFrames = maximumReferenceFrames
        self.bitrateEnvelope = bitrateEnvelope
    }
}

struct VideoRemuxPolicyAdmission: Sendable {
    let parameterSetIdentity: VideoAccessUnitSHA256
    let formatIdentity: VideoAccessUnitSHA256
    let parameterSetDisposition: VideoRemuxParameterSetDisposition
    let sourceContainsInBandParameterSets: Bool
    let maximumReferenceFrames: UInt32
    let bitrateEnvelope: VideoBitrateEnvelope
}

enum VideoRemuxPolicyDecision: Sendable {
    case remux(VideoRemuxPolicyAdmission)
    case transcode(VideoRemuxTranscodeReason, requiresNewItem: Bool)

    var path: VideoRemuxPath {
        switch self {
        case .remux: return .remux
        case .transcode: return .transcode
        }
    }

    var transcodeReason: VideoRemuxTranscodeReason? {
        guard case let .transcode(reason, _) = self else { return nil }
        return reason
    }

    var requiresNewItem: Bool {
        guard case let .transcode(_, requiresNewItem) = self else { return false }
        return requiresNewItem
    }

    var parameterSetDisposition: VideoRemuxParameterSetDisposition? {
        guard case let .remux(admission) = self else { return nil }
        return admission.parameterSetDisposition
    }

    var sourceContainsInBandParameterSets: Bool? {
        guard case let .remux(admission) = self else { return nil }
        return admission.sourceContainsInBandParameterSets
    }
}

struct VideoRemuxDecision: @unchecked Sendable {
    let path: VideoRemuxPath
    let transcodeReason: VideoRemuxTranscodeReason?
    let requiresNewItem: Bool
    let proof: VideoRemuxAdmissionProof?

    static func transcode(
        _ reason: VideoRemuxTranscodeReason,
        requiresNewItem: Bool = false
    ) -> Self {
        Self(
            path: .transcode,
            transcodeReason: reason,
            requiresNewItem: requiresNewItem,
            proof: nil
        )
    }
}

/// 一个实例只服务一个 immutable output generation。
///
/// 参数签名一旦漂移会先封死旧 generation，变化 AU 不可能取得旧 proof；调用方
/// 必须创建新 item/generation 后用新的实例重新检查。
final class VideoRemuxEligibility {
    private static let defaultMaximumRandomAccessInterval = ExactMediaTime(value: 6, timescale: 1)

    private let generation: MediaGeneration
    private let codec: VideoCodec
    private let sampleEntry: HLSVideoSampleEntry
    private let requiresDecodeTimestamp: Bool
    private let maximumRandomAccessInterval: ExactMediaTime
    private var parameterSetIdentity: VideoAccessUnitSHA256?
    private var formatIdentity: VideoAccessUnitSHA256?
    private var lastDecodeTimeStamp: ExactMediaTime?
    private var lastIDRPresentationTimeStamp: ExactMediaTime?
    private var stickyTranscodeReason: VideoRemuxTranscodeReason?
    private var fenced = false

    init(
        generation: MediaGeneration,
        track: VideoTrackDescriptor,
        sampleEntry: HLSVideoSampleEntry,
        maximumRandomAccessInterval: ExactMediaTime = ExactMediaTime(value: 6, timescale: 1)
    ) throws {
        guard sampleEntry.codec == track.codec else {
            throw VideoRemuxEligibilityError.sampleEntryCodecMismatch
        }
        self.generation = generation
        codec = track.codec
        self.sampleEntry = sampleEntry
        requiresDecodeTimestamp = track.videoDelay > 0
        self.maximumRandomAccessInterval = maximumRandomAccessInterval
    }

    /// 只有 Inspector 签发的具体 proof 能换取 writer admission authority。
    func evaluate(_ proof: VideoAccessUnitInspectionProof) throws -> VideoRemuxDecision {
        switch try evaluatePolicy(proof) {
        case let .transcode(reason, requiresNewItem):
            return .transcode(reason, requiresNewItem: requiresNewItem)
        case let .remux(policy):
            let admission = VideoRemuxAdmissionProof(
                source: proof,
                generation: generation,
                sampleEntry: sampleEntry,
                parameterSetIdentity: policy.parameterSetIdentity,
                formatIdentity: policy.formatIdentity,
                parameterSetDisposition: policy.parameterSetDisposition,
                sourceContainsInBandParameterSets: policy.sourceContainsInBandParameterSets,
                maximumReferenceFrames: policy.maximumReferenceFrames,
                bitrateEnvelope: policy.bitrateEnvelope
            )
            return VideoRemuxDecision(
                path: .remux,
                transcodeReason: nil,
                requiresNewItem: false,
                proof: admission
            )
        }
    }

    #if DEBUG
    /// 单元测试的纯策略入口；Release 构建不存在，且永远不签发 admission proof。
    func evaluatePolicyForTesting(
        _ evidence: any VideoRemuxInspectionEvidence
    ) throws -> VideoRemuxPolicyDecision {
        try evaluatePolicy(evidence)
    }
    #endif

    private func evaluatePolicy(
        _ evidence: any VideoRemuxInspectionEvidence
    ) throws -> VideoRemuxPolicyDecision {
        guard !fenced else { throw VideoRemuxEligibilityError.generationFenced }
        guard evidence.remuxGeneration == generation else {
            throw VideoRemuxEligibilityError.generationMismatch
        }
        guard evidence.remuxCodec == codec else {
            try reject(.codecMismatch)
        }
        guard evidence.remuxContainsVCL else {
            try reject(.missingVCL)
        }
        guard let incomingParameterSetIdentity = evidence.remuxParameterSetIdentity else {
            try reject(.unknownParameterSetSignature)
        }
        guard let incomingFormatIdentity = evidence.remuxFormatIdentity else {
            try reject(.unknownFormatSignature)
        }
        if let frozen = parameterSetIdentity,
           frozen != incomingParameterSetIdentity {
            fenced = true
            return .transcode(.parameterSetsChanged, requiresNewItem: true)
        }
        if parameterSetIdentity == nil {
            parameterSetIdentity = incomingParameterSetIdentity
        }
        if let frozen = formatIdentity,
           frozen != incomingFormatIdentity {
            fenced = true
            return .transcode(.formatChanged, requiresNewItem: true)
        }
        if formatIdentity == nil {
            formatIdentity = incomingFormatIdentity
        }

        if let stickyTranscodeReason {
            return .transcode(stickyTranscodeReason, requiresNewItem: false)
        }

        guard let presentationTimeStamp = evidence.remuxPresentationTimeStamp else {
            try reject(.invalidPresentationTimestamp)
        }
        guard evidence.remuxDuration?.value ?? 0 > 0 else {
            try reject(.invalidDuration)
        }
        switch evidence.remuxScanClassification {
        case .unresolved:
            try reject(.unknownScanClassification)
        case .interlaced:
            return transcode(.interlaced)
        case .progressive:
            break
        }

        if let formatTranscodeReason = try validateFormat(evidence) {
            return transcode(formatTranscodeReason)
        }

        do {
            try validateRandomAccessCodec(evidence.remuxRandomAccessKind)
        } catch let error as VideoRemuxEligibilityError {
            try reject(error)
        }
        if evidence.remuxConflictingRandomAccessKinds {
            return transcode(.conflictingRandomAccessKinds)
        }
        guard evidence.remuxHasSinglePrimaryPictureStartSlice else {
            return transcode(.invalidPrimaryPictureStructure)
        }
        switch evidence.remuxRandomAccessKind {
        case .h264IDR, .hevcIDR, .hevcCRA:
            guard evidence.remuxAllVCLAreRandomAccess else {
                return transcode(.mixedRandomAccessAccessUnit)
            }
        case .none, .containerKey:
            guard !evidence.remuxAllVCLAreRandomAccess else {
                try reject(.inconsistentRandomAccessEvidence)
            }
        }

        if evidence.remuxRandomAccessKind == .hevcCRA {
            return transcode(.notIDR)
        }

        if let decodeTimeStamp = evidence.remuxDecodeTimeStamp {
            if let previous = lastDecodeTimeStamp {
                let order: Int
                do {
                    order = try checkedCompare(decodeTimeStamp, previous)
                } catch {
                    try reject(.arithmeticOverflow)
                }
                guard order > 0 else {
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.set("fail_mono_cur_\(decodeTimeStamp.value)/\(decodeTimeStamp.timescale)_prev_\(previous.value)/\(previous.timescale)_ord_\(order)")
                    #endif
                    return transcode(.nonMonotonicDecodeTimestamp)
                }
            }
            lastDecodeTimeStamp = decodeTimeStamp
        } else if requiresDecodeTimestamp {
            return transcode(.missingDecodeTimestamp)
        }

        let randomAccessDecision = try evaluateRandomAccess(
            evidence.remuxRandomAccessKind,
            presentationTimeStamp: presentationTimeStamp
        )
        if let randomAccessDecision { return randomAccessDecision }

        let profileLevel: VideoCodecProfileLevel
        switch codec {
        case .h264:
            profileLevel = .h264(
                profileIDC: evidence.remuxProfileIDC,
                compatibilityFlags: evidence.remuxProfileCompatibilityFlags,
                levelIDC: evidence.remuxLevelIDC
            )
        case .hevc:
            profileLevel = .hevc(
                profileIDC: evidence.remuxProfileIDC,
                tier: evidence.remuxTier,
                levelIDC: evidence.remuxLevelIDC
            )
        }
        do {
            try VideoBitrateEnvelope.validateLevel(
                profileLevel: profileLevel,
                frameRate: evidence.remuxFrameRate,
                codedPictureSizeInMacroblocks: evidence.remuxCodedPictureSizeInMacroblocks,
                codedLumaPictureSize: evidence.remuxCodedLumaPictureSize,
                maximumReferenceFrames: evidence.remuxMaximumReferenceFrames
            )
        } catch VideoBitrateEnvelopeError.missingLevelEvidence {
            try reject(.missingLevelEvidence)
        } catch VideoBitrateEnvelopeError.levelFrameSizeExceeded {
            try reject(.levelFrameSizeExceeded)
        } catch VideoBitrateEnvelopeError.levelSampleRateExceeded {
            try reject(.levelSampleRateExceeded)
        } catch VideoBitrateEnvelopeError.levelDecodedPictureBufferExceeded {
            try reject(.levelDecodedPictureBufferExceeded)
        } catch VideoBitrateEnvelopeError.unsupportedProfileLevel {
            try reject(.unsupportedProfileLevel)
        } catch {
            try reject(.arithmeticOverflow)
        }

        guard let maximumReferenceFrames = evidence.remuxMaximumReferenceFrames else {
            try reject(.missingLevelEvidence)
        }
        let envelope: VideoBitrateEnvelope
        do {
            envelope = try VideoBitrateEnvelope.freeze(profileLevel: profileLevel)
        } catch VideoBitrateEnvelopeError.unsupportedProfileLevel {
            try reject(.unsupportedProfileLevel)
        } catch {
            try reject(.arithmeticOverflow)
        }
        return .remux(VideoRemuxPolicyAdmission(
            parameterSetIdentity: incomingParameterSetIdentity,
            formatIdentity: incomingFormatIdentity,
            parameterSetDisposition: sampleEntry.parameterSetDisposition,
            sourceContainsInBandParameterSets: evidence.remuxContainsInBandParameterSets,
            maximumReferenceFrames: maximumReferenceFrames,
            bitrateEnvelope: envelope
        ))
    }

    private func evaluateRandomAccess(
        _ kind: VideoRandomAccessKind,
        presentationTimeStamp: ExactMediaTime
    ) throws -> VideoRemuxPolicyDecision? {
        let isIDR = kind == .h264IDR || kind == .hevcIDR
        guard let previousIDR = lastIDRPresentationTimeStamp else {
            guard isIDR else {
                return transcode(kind == .none ? .openGOP : .notIDR)
            }
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("idr_0_\(presentationTimeStamp.value / Int64(presentationTimeStamp.timescale))s")
            #endif
            lastIDRPresentationTimeStamp = presentationTimeStamp
            return nil
        }

        let elapsed: ExactMediaTime
        let overLimit: ExactMediaTime
        do {
            elapsed = try presentationTimeStamp.subtracting(previousIDR)
            overLimit = try elapsed.subtracting(maximumRandomAccessInterval)
        } catch {
            try reject(.arithmeticOverflow)
        }
        if isIDR, elapsed.value <= 0 {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("nonInc_pts_\(presentationTimeStamp.value)/\(presentationTimeStamp.timescale)_prev_\(previousIDR.value)/\(previousIDR.timescale)_el_\(elapsed.value)")
            #endif
            return transcode(.nonIncreasingIDRPresentationTimestamp)
        }
        if overLimit.value > 0 {
            return transcode(.randomAccessIntervalExceeded)
        }
        if isIDR {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("idr_adv_\(presentationTimeStamp.value / Int64(presentationTimeStamp.timescale))s")
            #endif
            lastIDRPresentationTimeStamp = presentationTimeStamp
        }
        return nil
    }

    private func validateRandomAccessCodec(_ kind: VideoRandomAccessKind) throws {
        switch (codec, kind) {
        case (.h264, .hevcIDR), (.h264, .hevcCRA),
             (.hevc, .h264IDR):
            throw VideoRemuxEligibilityError.randomAccessCodecMismatch
        case (.h264, .none), (.h264, .h264IDR), (.h264, .containerKey),
             (.hevc, .none), (.hevc, .hevcIDR), (.hevc, .hevcCRA),
             (.hevc, .containerKey):
            break
        }
    }

    private func validateFormat(
        _ evidence: any VideoRemuxInspectionEvidence
    ) throws -> VideoRemuxTranscodeReason? {
        guard let width = evidence.remuxWidth,
              let height = evidence.remuxHeight else {
            try reject(.missingDimensions)
        }
        guard width > 0, height > 0 else {
            try reject(.invalidDimensions)
        }
        guard width <= 3_840, height <= 2_160 else {
            try reject(.dimensionsExceeded)
        }

        guard let frameRate = evidence.remuxFrameRate else {
            try reject(.missingFrameRate)
        }
        let maximumFrameRateNumerator = Int64(frameRate.den) * 60
        guard Int64(frameRate.num) <= maximumFrameRateNumerator else {
            try reject(.frameRateExceeded)
        }

        guard let chromaFormatIDC = evidence.remuxChromaFormatIDC else {
            try reject(.missingChromaFormat)
        }
        guard chromaFormatIDC == 1 else {
            try reject(.unsupportedChromaFormat)
        }
        guard let bitDepthLuma = evidence.remuxBitDepthLuma,
              let bitDepthChroma = evidence.remuxBitDepthChroma else {
            try reject(.missingBitDepth)
        }
        guard bitDepthLuma == bitDepthChroma else {
            try reject(.inconsistentBitDepth)
        }
        guard bitDepthLuma == 8 || bitDepthLuma == 10 else {
            try reject(.unsupportedBitDepth)
        }

        try validateColorMetadata(evidence, bitDepth: bitDepthLuma)

        switch codec {
        case .h264:
            if bitDepthLuma == 10 {
                guard evidence.remuxProfileIDC == 110
                        || evidence.remuxProfileIDC == 122
                        || evidence.remuxProfileIDC == 244 else {
                    try reject(.profileBitDepthMismatch)
                }
                return .h264TenBit
            }
            guard evidence.remuxProfileIDC == 66
                    || evidence.remuxProfileIDC == 77
                    || evidence.remuxProfileIDC == 100 else {
                try reject(.unsupportedProfile)
            }

        case .hevc:
            switch evidence.remuxProfileIDC {
            case 1:
                guard bitDepthLuma == 8 else {
                    try reject(.profileBitDepthMismatch)
                }
            case 2:
                break
            default:
                try reject(.unsupportedProfile)
            }
        }
        return nil
    }

    private func validateColorMetadata(
        _ evidence: any VideoRemuxInspectionEvidence,
        bitDepth: UInt8
    ) throws {
        let isHDRTransfer = evidence.remuxColorTransfer == .pq
            || evidence.remuxColorTransfer == .hlg
        if isHDRTransfer {
            guard bitDepth == 10 else { try reject(.hdrRequiresTenBit) }
            guard evidence.remuxColorPrimaries == .bt2020,
                  evidence.remuxColorMatrix == .bt2020Nonconstant else {
                try reject(.inconsistentHDRColorMetadata)
            }
        } else if evidence.remuxMasteringDisplay != nil
                    || evidence.remuxContentLightLevel != nil {
            try reject(.inconsistentHDRColorMetadata)
        }

        switch (evidence.remuxColorPrimaries, evidence.remuxColorMatrix) {
        case (.bt709?, .bt2020Nonconstant?), (.bt2020?, .bt709?):
            try reject(.inconsistentColorMetadata)
        default:
            break
        }
    }

    private func transcode(_ reason: VideoRemuxTranscodeReason) -> VideoRemuxPolicyDecision {
        if let stickyTranscodeReason {
            return .transcode(stickyTranscodeReason, requiresNewItem: false)
        }
        stickyTranscodeReason = reason
        return .transcode(reason, requiresNewItem: false)
    }

    private func reject(_ error: VideoRemuxEligibilityError) throws -> Never {
        fenced = true
        throw error
    }

    private func checkedCompare(_ lhs: ExactMediaTime, _ rhs: ExactMediaTime) throws -> Int {
        let delta: ExactMediaTime
        do {
            delta = try lhs.subtracting(rhs)
        } catch {
            throw VideoRemuxEligibilityError.arithmeticOverflow
        }
        if delta.value < 0 { return -1 }
        if delta.value > 0 { return 1 }
        return 0
    }
}

private extension HLSVideoSampleEntry {
    var codec: VideoCodec {
        switch self {
        case .avc1, .avc3: return .h264
        case .hvc1, .hev1: return .hevc
        }
    }

    var parameterSetDisposition: VideoRemuxParameterSetDisposition {
        switch self {
        case .avc1, .hvc1:
            return .stripInBandToConfiguration
        case .avc3, .hev1:
            return .preserveInBand
        }
    }
}
