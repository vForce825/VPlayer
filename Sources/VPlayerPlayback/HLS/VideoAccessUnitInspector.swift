// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum VideoParameterSetKind: UInt8, Sendable, Hashable {
    case video
    case sequence
    case picture
}

enum VideoFormatMetadataField: UInt8, Sendable, Hashable {
    case codec
    case dimensions
    case frameRate
    case fieldOrder
    case sampleAspectRatio
    case range
    case primaries
    case transfer
    case matrix
    case chromaLocation
    case masteringDisplay
    case contentLightLevel
}

enum VideoAccessUnitInspectionError: Error, Sendable, Equatable {
    case invalidRange
    case accessUnitTooLarge
    case sourceDigestMismatch
    case malformedAnnexB
    case truncatedRBSP
    case malformedEmulationPrevention
    case invalidRBSPTrailingBits
    case expGolombOverflow
    case arithmeticOverflow
    case unsupportedSyntax
    case unsupportedChromaFormat(UInt32)
    case unsupportedChromaLocation(UInt32)
    case unsupportedColorPrimaries(UInt16)
    case unsupportedColorTransfer(UInt16)
    case unsupportedColorMatrix(UInt16)
    case missingVCL
    case missingInitialParameterCatalog
    case sessionGenerationOrCodecMismatch
    case missingParameterReference(kind: VideoParameterSetKind, id: UInt32)
    case conflictingParameterSet(kind: VideoParameterSetKind, id: UInt32)
    case inactiveParameterSet(kind: VideoParameterSetKind, id: UInt32)
    case conflictingSliceReferences
    case continuationBeforePrimaryPictureStart
    case conflictingPrimaryPictureStartSlices
    case unsupportedH264VCLNALUnitType(UInt8)
    case invalidHDRMetadata
    case metadataMismatch(VideoFormatMetadataField)
}

struct VideoAccessUnitEvidenceIdentity: Sendable, Hashable {
    let generation: MediaGeneration
    let accessUnitID: UInt64
    let backingIdentity: VideoAccessUnitBackingIdentity
    let backingOwnerIdentity: VideoAccessUnitBackingOwnerIdentity
    let byteRange: VideoAccessUnitByteRange
    let sourceSHA256: VideoAccessUnitSHA256

    func matches(
        backing: VideoAccessUnitBacking,
        byteRange: VideoAccessUnitByteRange,
        sourceSHA256: VideoAccessUnitSHA256
    ) -> Bool {
        backingOwnerIdentity === backing.ownerIdentity
            && backingIdentity == backing.identity
            && generation == backing.identity.generation
            && accessUnitID == backing.identity.accessUnitID
            && self.byteRange == byteRange
            && self.sourceSHA256 == sourceSHA256
    }
}

struct VideoParameterSetSignature: Sendable, Hashable {
    let codec: VideoCodec
    let vpsID: Int32?
    let spsID: Int32
    let ppsID: Int32
    let vpsSHA256: VideoAccessUnitSHA256?
    let spsSHA256: VideoAccessUnitSHA256
    let ppsSHA256: VideoAccessUnitSHA256
    let combinedSHA256: VideoAccessUnitSHA256
}

struct VideoAccessUnitFormatIdentity: Sendable, Hashable {
    let sha256: VideoAccessUnitSHA256
}

struct VideoAccessUnitFormatSummary: Sendable, Hashable {
    let codec: VideoCodec
    let profileIDC: UInt8
    let profileCompatibilityFlags: UInt32
    let levelIDC: UInt8
    let tier: VideoCodecTier
    let chromaFormatIDC: UInt8
    let bitDepthLuma: UInt8
    let bitDepthChroma: UInt8
    let width: Int32
    let height: Int32
    let codedPictureMacroblockCount: UInt32?
    let codedPictureLumaSampleCount: UInt64?
    let maximumReferenceFrames: UInt32
    let progressiveSourceFlag: Bool?
    let interlacedSourceFlag: Bool?
    let sampleAspectRatio: MediaRational?
    let frameRate: MediaRational?
    let range: DemuxColorRange?
    let primaries: DemuxColorPrimaries?
    let transfer: DemuxColorTransfer?
    let matrix: DemuxColorMatrix?
    let chromaLocation: DemuxChromaLocation?
    let masteringDisplay: DemuxMasteringDisplayMetadata?
    let contentLightLevel: DemuxContentLightLevelMetadata?
}

/// 对单个完整 SPS 做语法闭合校验后返回的最小编码配置证明。
struct VideoSequenceParameterSetProof: Sendable, Hashable {
    let codec: VideoCodec
    let profileIDC: UInt8
    let compatibilityFlags: UInt32
    let hevcConstraintIndicatorFlags: UInt64?
    let levelIDC: UInt8
    let tier: VideoCodecTier?
    let chromaFormatIDC: UInt8
    let bitDepthLuma: UInt8
    let bitDepthChroma: UInt8
    let width: Int32
    let height: Int32
    /// 仅对4:2:0有效；VUI未携带字段时按H.264/H.265规定的type 0推导为left。
    let effectiveChromaLocation: DemuxChromaLocation?
    /// 区分VUI字段缺省与显式但本实现不支持的type 3...5。
    let chromaLocationWasPresent: Bool
    let range: DemuxColorRange?
}

enum VideoSequenceParameterSetInspector {
    static func inspectH264(_ bytes: [UInt8]) throws -> VideoSequenceParameterSetProof {
        try bytes.withUnsafeBytes { buffer in
            guard buffer.count > 1,
                  buffer[0] & 0x80 == 0,
                  buffer[0] & 0x1F == 7 else {
                throw VideoAccessUnitInspectionError.unsupportedSyntax
            }
            let parsed = try parseH264SPS(
                buffer,
                digest: VideoAccessUnitSHA256(bytes: buffer)
            )
            return VideoSequenceParameterSetProof(
                codec: .h264,
                profileIDC: parsed.profileIDC,
                compatibilityFlags: parsed.compatibilityFlags,
                hevcConstraintIndicatorFlags: nil,
                levelIDC: parsed.levelIDC,
                tier: nil,
                chromaFormatIDC: parsed.chromaFormatIDC,
                bitDepthLuma: parsed.bitDepthLuma,
                bitDepthChroma: parsed.bitDepthChroma,
                width: parsed.width,
                height: parsed.height,
                effectiveChromaLocation: parsed.chromaFormatIDC == 1
                    ? (parsed.vui.chromaLocationWasPresent
                        ? parsed.vui.chromaLocation
                        : .left)
                    : nil,
                chromaLocationWasPresent: parsed.vui.chromaLocationWasPresent,
                range: parsed.vui.range
            )
        }
    }

    static func inspectHEVC(_ bytes: [UInt8]) throws -> VideoSequenceParameterSetProof {
        try bytes.withUnsafeBytes { buffer in
            guard buffer.count > 2,
                  buffer[0] & 0x80 == 0,
                  buffer[0] >> 1 & 0x3F == 33,
                  buffer[1] & 0x07 > 0 else {
                throw VideoAccessUnitInspectionError.unsupportedSyntax
            }
            let parsed = try parseHEVCSPS(
                buffer,
                digest: VideoAccessUnitSHA256(bytes: buffer)
            )
            return VideoSequenceParameterSetProof(
                codec: .hevc,
                profileIDC: parsed.profileIDC,
                compatibilityFlags: parsed.compatibilityFlags,
                hevcConstraintIndicatorFlags: parsed.constraintIndicatorFlags,
                levelIDC: parsed.levelIDC,
                tier: parsed.tier,
                chromaFormatIDC: parsed.chromaFormatIDC,
                bitDepthLuma: parsed.bitDepthLuma,
                bitDepthChroma: parsed.bitDepthChroma,
                width: parsed.width,
                height: parsed.height,
                effectiveChromaLocation: parsed.chromaFormatIDC == 1
                    ? (parsed.vui.chromaLocationWasPresent
                        ? parsed.vui.chromaLocation
                        : .left)
                    : nil,
                chromaLocationWasPresent: parsed.vui.chromaLocationWasPresent,
                range: parsed.vui.range
            )
        }
    }
}

/// 让 inspection proof 的成员初始化器保持 file-scoped，模块内其他组件也不能伪造。
fileprivate final class VideoAccessUnitInspectionAuthority: @unchecked Sendable, Hashable {
    static let shared = VideoAccessUnitInspectionAuthority()

    private init() {}

    static func == (
        lhs: VideoAccessUnitInspectionAuthority,
        rhs: VideoAccessUnitInspectionAuthority
    ) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

struct VideoAccessUnitInspectionProof: Sendable, Hashable {
    fileprivate let authority: VideoAccessUnitInspectionAuthority
    let identity: VideoAccessUnitEvidenceIdentity
    let codec: VideoCodec
    let randomAccessKind: VideoRandomAccessKind
    let conflictingRandomAccessKinds: Bool
    let parameterSets: VideoParameterSetSignature
    let format: VideoAccessUnitFormatSummary
    let formatIdentity: VideoAccessUnitFormatIdentity
    let scanClassification: VideoScanClassificationEvidence
    let presentationTimeStamp: ExactMediaTime?
    let decodeTimeStamp: ExactMediaTime?
    let duration: ExactMediaTime?
    let containsVCL: Bool
    let containsInBandParameterSets: Bool
    let vclNALUnitCount: UInt32
    let randomAccessNALUnitCount: UInt32
    let allVCLNALUnitsAreRandomAccess: Bool
    let hasPrimaryPictureStartSlice: Bool
}

struct VideoAccessUnitInspectionInput: @unchecked Sendable {
    let backing: VideoAccessUnitBacking
    let byteRange: VideoAccessUnitByteRange
    let sourceSHA256: VideoAccessUnitSHA256
    let codec: VideoCodec
    let scanClassification: VideoScanClassificationEvidence
    let presentationTimeStamp: ExactMediaTime?
    let decodeTimeStamp: ExactMediaTime?
    let duration: ExactMediaTime?
    let expectedFormat: VideoTrackDescriptor?

    init(
        backing: VideoAccessUnitBacking,
        byteRange: VideoAccessUnitByteRange,
        sourceSHA256: VideoAccessUnitSHA256,
        codec: VideoCodec,
        scanClassification: VideoScanClassificationEvidence,
        presentationTimeStamp: ExactMediaTime? = nil,
        decodeTimeStamp: ExactMediaTime? = nil,
        duration: ExactMediaTime? = nil,
        expectedFormat: VideoTrackDescriptor? = nil
    ) {
        self.backing = backing
        self.byteRange = byteRange
        self.sourceSHA256 = sourceSHA256
        self.codec = codec
        self.scanClassification = scanClassification
        self.presentationTimeStamp = presentationTimeStamp
        self.decodeTimeStamp = decodeTimeStamp
        self.duration = duration
        self.expectedFormat = expectedFormat
    }
}

enum VideoAccessUnitInspector {
    fileprivate static let maximumParameterSetID: UInt32 = 1_023
    fileprivate static let maximumReferencePictures: UInt32 = 64

    static func inspect(
        _ input: VideoAccessUnitInspectionInput
    ) throws -> VideoAccessUnitInspectionProof {
        let state = try scan(input)
        let resolved = try state.resolve(
            expected: input.expectedFormat,
            inheriting: nil
        )
        try state.rejectInactiveCurrentParameterSets(
            state.currentParameterSetIDs,
            active: resolved.parameterSets
        )
        return try makeProof(input: input, state: state, resolved: resolved)
    }

    fileprivate static func scan(
        _ input: VideoAccessUnitInspectionInput
    ) throws -> InspectionState {
        guard input.byteRange.length <= AnnexBScanner.maximumAccessUnitBytes else {
            throw VideoAccessUnitInspectionError.accessUnitTooLarge
        }
        let actualDigest: VideoAccessUnitSHA256
        do {
            actualDigest = try input.backing.sha256(in: input.byteRange)
        } catch {
            throw VideoAccessUnitInspectionError.invalidRange
        }
        guard actualDigest == input.sourceSHA256 else {
            throw VideoAccessUnitInspectionError.sourceDigestMismatch
        }

        var state = InspectionState(codec: input.codec)
        do {
            try AnnexBScanner.visitNALUnits(
                in: input.backing,
                range: input.byteRange,
                codec: input.codec
            ) { view, bytes in
                // Unsafe pointer 只存在于本次同步解析调用内；对外 visitor 使用
                // 编译器禁止逃逸的 Span，不能把 backing 借用泄漏到 proof。
                try bytes.withUnsafeBytes { rawBytes in
                    try state.consume(view: view, bytes: rawBytes)
                }
            }
        } catch let error as VideoAccessUnitInspectionError {
            throw error
        } catch is VideoAccessUnitBackingError {
            throw VideoAccessUnitInspectionError.invalidRange
        } catch {
            throw VideoAccessUnitInspectionError.malformedAnnexB
        }
        return state
    }

    fileprivate static func makeProof(
        input: VideoAccessUnitInspectionInput,
        state: InspectionState,
        resolved: ResolvedInspection
    ) throws -> VideoAccessUnitInspectionProof {
        let actualDigest = try input.backing.sha256(in: input.byteRange)
        let identity = input.backing.identity
        return VideoAccessUnitInspectionProof(
            authority: .shared,
            identity: VideoAccessUnitEvidenceIdentity(
                generation: identity.generation,
                accessUnitID: identity.accessUnitID,
                backingIdentity: identity,
                backingOwnerIdentity: input.backing.ownerIdentity,
                byteRange: input.byteRange,
                sourceSHA256: actualDigest
            ),
            codec: input.codec,
            randomAccessKind: state.randomAccessKind,
            conflictingRandomAccessKinds: state.conflictingRandomAccessKinds,
            parameterSets: resolved.parameterSets,
            format: resolved.format,
            formatIdentity: makeFormatIdentity(
                parameterSets: resolved.parameterSets,
                format: resolved.format
            ),
            scanClassification: input.scanClassification,
            presentationTimeStamp: input.presentationTimeStamp,
            decodeTimeStamp: input.decodeTimeStamp,
            duration: input.duration,
            containsVCL: state.vclCount > 0,
            containsInBandParameterSets: state.containsParameterSets,
            vclNALUnitCount: state.vclCount,
            randomAccessNALUnitCount: state.randomAccessCount,
            allVCLNALUnitsAreRandomAccess: state.vclCount > 0
                && state.vclCount == state.randomAccessCount,
            hasPrimaryPictureStartSlice: state.hasPrimaryPictureStartSlice
        )
    }
}

fileprivate protocol ParameterSetRecord {
    var id: UInt32 { get }
    var digest: VideoAccessUnitSHA256 { get }
}

fileprivate struct ParsedVUI: Sendable, Hashable {
    var progressiveSourceFlag: Bool? = nil
    var interlacedSourceFlag: Bool? = nil
    var sampleAspectRatio: MediaRational? = nil
    var frameRate: MediaRational? = nil
    var range: DemuxColorRange? = nil
    var primaries: DemuxColorPrimaries? = nil
    var transfer: DemuxColorTransfer? = nil
    var matrix: DemuxColorMatrix? = nil
    var chromaLocation: DemuxChromaLocation? = nil
    var chromaLocationWasPresent = false
}

fileprivate struct H264SPSRecord: ParameterSetRecord {
    let id: UInt32
    let digest: VideoAccessUnitSHA256
    let profileIDC: UInt8
    let compatibilityFlags: UInt32
    let levelIDC: UInt8
    let chromaFormatIDC: UInt8
    let bitDepthLuma: UInt8
    let bitDepthChroma: UInt8
    let width: Int32
    let height: Int32
    let codedPictureMacroblockCount: UInt32
    let maximumReferenceFrames: UInt32
    let frameMBSOnly: Bool
    let vui: ParsedVUI

    func format(
        masteringDisplay: DemuxMasteringDisplayMetadata?,
        contentLightLevel: DemuxContentLightLevelMetadata?
    ) -> VideoAccessUnitFormatSummary {
        VideoAccessUnitFormatSummary(
            codec: .h264,
            profileIDC: profileIDC,
            profileCompatibilityFlags: compatibilityFlags,
            levelIDC: levelIDC,
            tier: .main,
            chromaFormatIDC: chromaFormatIDC,
            bitDepthLuma: bitDepthLuma,
            bitDepthChroma: bitDepthChroma,
            width: width,
            height: height,
            codedPictureMacroblockCount: codedPictureMacroblockCount,
            codedPictureLumaSampleCount: nil,
            maximumReferenceFrames: maximumReferenceFrames,
            progressiveSourceFlag: frameMBSOnly,
            interlacedSourceFlag: !frameMBSOnly,
            sampleAspectRatio: vui.sampleAspectRatio,
            frameRate: vui.frameRate,
            range: vui.range,
            primaries: vui.primaries,
            transfer: vui.transfer,
            matrix: vui.matrix,
            chromaLocation: vui.chromaLocation,
            masteringDisplay: masteringDisplay,
            contentLightLevel: contentLightLevel
        )
    }
}

fileprivate struct H264PPSRecord: ParameterSetRecord {
    let id: UInt32
    let spsID: UInt32
    let digest: VideoAccessUnitSHA256
}

fileprivate struct HEVCVPSRecord: ParameterSetRecord {
    let id: UInt32
    let digest: VideoAccessUnitSHA256
}

fileprivate struct HEVCSPSRecord: ParameterSetRecord {
    let id: UInt32
    let vpsID: UInt32
    let digest: VideoAccessUnitSHA256
    let profileIDC: UInt8
    let compatibilityFlags: UInt32
    let constraintIndicatorFlags: UInt64
    let levelIDC: UInt8
    let tier: VideoCodecTier
    let chromaFormatIDC: UInt8
    let bitDepthLuma: UInt8
    let bitDepthChroma: UInt8
    let width: Int32
    let height: Int32
    let codedPictureLumaSampleCount: UInt64
    let maximumReferenceFrames: UInt32
    let vui: ParsedVUI

    func format(
        masteringDisplay: DemuxMasteringDisplayMetadata?,
        contentLightLevel: DemuxContentLightLevelMetadata?
    ) -> VideoAccessUnitFormatSummary {
        VideoAccessUnitFormatSummary(
            codec: .hevc,
            profileIDC: profileIDC,
            profileCompatibilityFlags: compatibilityFlags,
            levelIDC: levelIDC,
            tier: tier,
            chromaFormatIDC: chromaFormatIDC,
            bitDepthLuma: bitDepthLuma,
            bitDepthChroma: bitDepthChroma,
            width: width,
            height: height,
            codedPictureMacroblockCount: nil,
            codedPictureLumaSampleCount: codedPictureLumaSampleCount,
            maximumReferenceFrames: maximumReferenceFrames,
            progressiveSourceFlag: vui.progressiveSourceFlag,
            interlacedSourceFlag: vui.interlacedSourceFlag,
            sampleAspectRatio: vui.sampleAspectRatio,
            frameRate: vui.frameRate,
            range: vui.range,
            primaries: vui.primaries,
            transfer: vui.transfer,
            matrix: vui.matrix,
            chromaLocation: vui.chromaLocation,
            masteringDisplay: masteringDisplay,
            contentLightLevel: contentLightLevel
        )
    }
}

fileprivate struct HEVCPPSRecord: ParameterSetRecord {
    let id: UInt32
    let spsID: UInt32
    let digest: VideoAccessUnitSHA256
}

fileprivate struct ResolvedInspection {
    let parameterSets: VideoParameterSetSignature
    let format: VideoAccessUnitFormatSummary
}

fileprivate struct FrozenVideoParameterCatalog {
    let h264SPS: [UInt32: H264SPSRecord]
    let h264PPS: [UInt32: H264PPSRecord]
    let hevcVPS: [UInt32: HEVCVPSRecord]
    let hevcSPS: [UInt32: HEVCSPSRecord]
    let hevcPPS: [UInt32: HEVCPPSRecord]
    let format: VideoAccessUnitFormatSummary
}

fileprivate struct CurrentVideoParameterSetIDs {
    let h264SPS: Set<UInt32>
    let h264PPS: Set<UInt32>
    let hevcVPS: Set<UInt32>
    let hevcSPS: Set<UInt32>
    let hevcPPS: Set<UInt32>
}

fileprivate struct InspectionState {
    let codec: VideoCodec
    var h264SPS: [UInt32: H264SPSRecord] = [:]
    var h264PPS: [UInt32: H264PPSRecord] = [:]
    var hevcVPS: [UInt32: HEVCVPSRecord] = [:]
    var hevcSPS: [UInt32: HEVCSPSRecord] = [:]
    var hevcPPS: [UInt32: HEVCPPSRecord] = [:]
    var referencedPPSID: UInt32?
    var masteringDisplay: DemuxMasteringDisplayMetadata?
    var contentLightLevel: DemuxContentLightLevelMetadata?
    var containsParameterSets = false
    var vclCount: UInt32 = 0
    var randomAccessCount: UInt32 = 0
    var randomAccessKind = VideoRandomAccessKind.none
    var randomAccessKindMask: UInt8 = 0
    var primaryPictureStartSliceCount: UInt32 = 0

    var conflictingRandomAccessKinds: Bool {
        randomAccessKindMask.nonzeroBitCount > 1
    }

    var hasPrimaryPictureStartSlice: Bool {
        primaryPictureStartSliceCount == 1
    }

    mutating func consume(
        view: AnnexBNALUnitView,
        bytes: UnsafeRawBufferPointer
    ) throws {
        let digest = VideoAccessUnitSHA256(bytes: bytes)
        switch codec {
        case .h264:
            try consumeH264(type: view.nalUnitType, bytes: bytes, digest: digest)
        case .hevc:
            try consumeHEVC(type: view.nalUnitType, bytes: bytes, digest: digest)
        }
        if view.isParameterSet { containsParameterSets = true }
        if view.randomAccessKind != .none {
            randomAccessCount = try checkedIncrement(randomAccessCount)
            switch view.randomAccessKind {
            case .h264IDR: randomAccessKindMask |= 1 << 0
            case .hevcIDR: randomAccessKindMask |= 1 << 1
            case .hevcCRA: randomAccessKindMask |= 1 << 2
            case .none, .containerKey: break
            }
            switch view.randomAccessKind {
            case .h264IDR, .hevcIDR:
                randomAccessKind = view.randomAccessKind
            case .hevcCRA where randomAccessKind == .none:
                randomAccessKind = .hevcCRA
            case .none, .containerKey, .hevcCRA:
                break
            }
        }
    }

    var currentParameterSetIDs: CurrentVideoParameterSetIDs {
        CurrentVideoParameterSetIDs(
            h264SPS: Set(h264SPS.keys),
            h264PPS: Set(h264PPS.keys),
            hevcVPS: Set(hevcVPS.keys),
            hevcSPS: Set(hevcSPS.keys),
            hevcPPS: Set(hevcPPS.keys)
        )
    }

    mutating func supplementMissingParameterSets(from catalog: FrozenVideoParameterCatalog) {
        for (id, value) in catalog.h264SPS where h264SPS[id] == nil { h264SPS[id] = value }
        for (id, value) in catalog.h264PPS where h264PPS[id] == nil { h264PPS[id] = value }
        for (id, value) in catalog.hevcVPS where hevcVPS[id] == nil { hevcVPS[id] = value }
        for (id, value) in catalog.hevcSPS where hevcSPS[id] == nil { hevcSPS[id] = value }
        for (id, value) in catalog.hevcPPS where hevcPPS[id] == nil { hevcPPS[id] = value }
    }

    func frozenCatalog(format: VideoAccessUnitFormatSummary) -> FrozenVideoParameterCatalog {
        FrozenVideoParameterCatalog(
            h264SPS: h264SPS,
            h264PPS: h264PPS,
            hevcVPS: hevcVPS,
            hevcSPS: hevcSPS,
            hevcPPS: hevcPPS,
            format: format
        )
    }

    private mutating func consumeH264(
        type: UInt8,
        bytes: UnsafeRawBufferPointer,
        digest: VideoAccessUnitSHA256
    ) throws {
        switch type {
        case 1, 2, 5:
            vclCount = try checkedIncrement(vclCount)
            var reader = try RBSPBitReader(ebsp: bytes, headerBytes: 1)
            try recordPrimaryPictureStartSlice(try reader.readUE() == 0)
            _ = try reader.readUE()
            try bindPPSReference(try reader.readUE())
        case 3, 4, 19...21:
            // data partition B/C、auxiliary picture 与扩展 slice 都属于 VCL，
            // 当前检查器不能证明其图片边界，不能把它们从 all-VCL 证据中漏掉。
            throw VideoAccessUnitInspectionError.unsupportedH264VCLNALUnitType(type)
        case 6:
            try parseSEI(bytes, headerBytes: 1)
        case 7:
            let parsed = try parseH264SPS(bytes, digest: digest)
            try insertParameterSet(parsed, into: &h264SPS, kind: .sequence)
        case 8:
            let parsed = try parseH264PPS(bytes, digest: digest)
            try insertParameterSet(parsed, into: &h264PPS, kind: .picture)
        case 13:
            // 当前签名合同不覆盖 SPS extension，不能把它静默当作已验证配置。
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        default:
            break
        }
    }

    private mutating func consumeHEVC(
        type: UInt8,
        bytes: UnsafeRawBufferPointer,
        digest: VideoAccessUnitSHA256
    ) throws {
        switch type {
        case 0...31:
            vclCount = try checkedIncrement(vclCount)
            var reader = try RBSPBitReader(ebsp: bytes, headerBytes: 2)
            try recordPrimaryPictureStartSlice(try reader.readFlag())
            if (16...23).contains(type) { _ = try reader.readFlag() }
            try bindPPSReference(try reader.readUE())
        case 32:
            let parsed = try parseHEVCVPS(bytes, digest: digest)
            try insertParameterSet(parsed, into: &hevcVPS, kind: .video)
        case 33:
            let parsed = try parseHEVCSPS(bytes, digest: digest)
            try insertParameterSet(parsed, into: &hevcSPS, kind: .sequence)
        case 34:
            let parsed = try parseHEVCPPS(bytes, digest: digest)
            try insertParameterSet(parsed, into: &hevcPPS, kind: .picture)
        case 39, 40:
            try parseSEI(bytes, headerBytes: 2)
        default:
            break
        }
    }

    private mutating func bindPPSReference(_ id: UInt32) throws {
        guard id <= VideoAccessUnitInspector.maximumParameterSetID else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        if let referencedPPSID, referencedPPSID != id {
            throw VideoAccessUnitInspectionError.conflictingSliceReferences
        }
        referencedPPSID = id
    }

    private mutating func recordPrimaryPictureStartSlice(_ isStart: Bool) throws {
        if vclCount == 1 {
            guard isStart else {
                throw VideoAccessUnitInspectionError.continuationBeforePrimaryPictureStart
            }
            primaryPictureStartSliceCount = 1
            return
        }
        guard !isStart else {
            throw VideoAccessUnitInspectionError.conflictingPrimaryPictureStartSlices
        }
    }

    mutating func parseSEI(
        _ bytes: UnsafeRawBufferPointer,
        headerBytes: Int
    ) throws {
        var reader = try RBSPByteReader(ebsp: bytes, headerBytes: headerBytes)
        while !(try reader.isAtTrailingBits()) {
            let type = try reader.readExtendedValue()
            let size = try reader.readExtendedValue()
            guard let payloadSize = Int(exactly: size) else {
                throw VideoAccessUnitInspectionError.arithmeticOverflow
            }
            switch type {
            case 137:
                guard size == 24 else {
                    throw VideoAccessUnitInspectionError.invalidHDRMetadata
                }
                let payload = try reader.readBytes(count: 24)
                let parsed = try parseMasteringDisplay(payload)
                if let masteringDisplay, masteringDisplay != parsed {
                    throw VideoAccessUnitInspectionError.invalidHDRMetadata
                }
                masteringDisplay = parsed
            case 144:
                guard size == 4 else {
                    throw VideoAccessUnitInspectionError.invalidHDRMetadata
                }
                let payload = try reader.readBytes(count: 4)
                guard
                      let parsed = DemuxContentLightLevelMetadata(
                        maximumContentLightLevel: try readUInt16(payload, at: 0),
                        maximumFrameAverageLightLevel: try readUInt16(payload, at: 2)
                      ) else {
                    throw VideoAccessUnitInspectionError.invalidHDRMetadata
                }
                if let contentLightLevel, contentLightLevel != parsed {
                    throw VideoAccessUnitInspectionError.invalidHDRMetadata
                }
                contentLightLevel = parsed
            default:
                try reader.skipBytes(count: payloadSize)
            }
        }
    }

    func resolve(
        expected: VideoTrackDescriptor?,
        inheriting frozenFormat: VideoAccessUnitFormatSummary?
    ) throws -> ResolvedInspection {
        guard vclCount > 0 else { throw VideoAccessUnitInspectionError.missingVCL }
        guard let ppsID = referencedPPSID else {
            throw VideoAccessUnitInspectionError.missingParameterReference(kind: .picture, id: 0)
        }
        switch codec {
        case .h264:
            guard let pps = h264PPS[ppsID] else {
                throw VideoAccessUnitInspectionError.missingParameterReference(
                    kind: .picture,
                    id: ppsID
                )
            }
            guard let sps = h264SPS[pps.spsID] else {
                throw VideoAccessUnitInspectionError.missingParameterReference(
                    kind: .sequence,
                    id: pps.spsID
                )
            }
            let signature = try makeSignature(
                codec: .h264,
                vps: nil,
                sps: sps,
                pps: pps
            )
            let parsedFormat = sps.format(
                masteringDisplay: masteringDisplay ?? frozenFormat?.masteringDisplay,
                contentLightLevel: contentLightLevel ?? frozenFormat?.contentLightLevel
            )
            let format = try mergeAndValidate(
                inheritingMissingFormatMetadata(parsedFormat, from: frozenFormat),
                expected: expected
            )
            return ResolvedInspection(parameterSets: signature, format: format)

        case .hevc:
            guard let pps = hevcPPS[ppsID] else {
                throw VideoAccessUnitInspectionError.missingParameterReference(
                    kind: .picture,
                    id: ppsID
                )
            }
            guard let sps = hevcSPS[pps.spsID] else {
                throw VideoAccessUnitInspectionError.missingParameterReference(
                    kind: .sequence,
                    id: pps.spsID
                )
            }
            guard let vps = hevcVPS[sps.vpsID] else {
                throw VideoAccessUnitInspectionError.missingParameterReference(
                    kind: .video,
                    id: sps.vpsID
                )
            }
            let signature = try makeSignature(codec: .hevc, vps: vps, sps: sps, pps: pps)
            let parsedFormat = sps.format(
                masteringDisplay: masteringDisplay ?? frozenFormat?.masteringDisplay,
                contentLightLevel: contentLightLevel ?? frozenFormat?.contentLightLevel
            )
            let format = try mergeAndValidate(
                inheritingMissingFormatMetadata(parsedFormat, from: frozenFormat),
                expected: expected
            )
            return ResolvedInspection(parameterSets: signature, format: format)
        }
    }

    func rejectInactiveCurrentParameterSets(
        _ current: CurrentVideoParameterSetIDs,
        active: VideoParameterSetSignature
    ) throws {
        guard let activeSPS = UInt32(exactly: active.spsID),
              let activePPS = UInt32(exactly: active.ppsID) else {
            throw VideoAccessUnitInspectionError.arithmeticOverflow
        }
        switch codec {
        case .h264:
            if let id = current.h264SPS.sorted().first(where: { $0 != activeSPS }) {
                throw VideoAccessUnitInspectionError.inactiveParameterSet(kind: .sequence, id: id)
            }
            if let id = current.h264PPS.sorted().first(where: { $0 != activePPS }) {
                throw VideoAccessUnitInspectionError.inactiveParameterSet(kind: .picture, id: id)
            }
        case .hevc:
            guard let activeVPSValue = active.vpsID,
                  let activeVPS = UInt32(exactly: activeVPSValue) else {
                throw VideoAccessUnitInspectionError.arithmeticOverflow
            }
            if let id = current.hevcVPS.sorted().first(where: { $0 != activeVPS }) {
                throw VideoAccessUnitInspectionError.inactiveParameterSet(kind: .video, id: id)
            }
            if let id = current.hevcSPS.sorted().first(where: { $0 != activeSPS }) {
                throw VideoAccessUnitInspectionError.inactiveParameterSet(kind: .sequence, id: id)
            }
            if let id = current.hevcPPS.sorted().first(where: { $0 != activePPS }) {
                throw VideoAccessUnitInspectionError.inactiveParameterSet(kind: .picture, id: id)
            }
        }
    }

    private func makeSignature<Sequence: ParameterSetRecord, Picture: ParameterSetRecord>(
        codec: VideoCodec,
        vps: HEVCVPSRecord?,
        sps: Sequence,
        pps: Picture
    ) throws -> VideoParameterSetSignature {
        let vpsID: Int32?
        if let vps {
            guard let exactID = Int32(exactly: vps.id) else {
                throw VideoAccessUnitInspectionError.arithmeticOverflow
            }
            vpsID = exactID
        } else {
            vpsID = nil
        }
        guard let spsID = Int32(exactly: sps.id),
              let ppsID = Int32(exactly: pps.id) else {
            throw VideoAccessUnitInspectionError.arithmeticOverflow
        }
        var canonical = Data([codec.rawValue])
        appendSignature(vps, marker: 0x20, to: &canonical)
        appendSignature(sps, marker: 0x21, to: &canonical)
        appendSignature(pps, marker: 0x22, to: &canonical)
        let combined = VideoAccessUnitSHA256(bytes: canonical.span)
        return VideoParameterSetSignature(
            codec: codec,
            vpsID: vpsID,
            spsID: spsID,
            ppsID: ppsID,
            vpsSHA256: vps?.digest,
            spsSHA256: sps.digest,
            ppsSHA256: pps.digest,
            combinedSHA256: combined
        )
    }
}

/// 一个实例只服务一个 generation/codec；冻结目录从不被后续 AU 改写。
struct VideoAccessUnitInspectionSession {
    let generation: MediaGeneration
    let codec: VideoCodec
    private var frozenCatalog: FrozenVideoParameterCatalog?

    init(generation: MediaGeneration, codec: VideoCodec) {
        self.generation = generation
        self.codec = codec
    }

    mutating func inspect(
        _ input: VideoAccessUnitInspectionInput
    ) throws -> VideoAccessUnitInspectionProof {
        guard input.backing.identity.generation == generation, input.codec == codec else {
            throw VideoAccessUnitInspectionError.sessionGenerationOrCodecMismatch
        }

        var state = try VideoAccessUnitInspector.scan(input)
        let currentParameterSetIDs = state.currentParameterSetIDs
        if let frozenCatalog {
            state.supplementMissingParameterSets(from: frozenCatalog)
            let resolved = try state.resolve(
                expected: input.expectedFormat,
                inheriting: frozenCatalog.format
            )
            try state.rejectInactiveCurrentParameterSets(
                currentParameterSetIDs,
                active: resolved.parameterSets
            )
            return try VideoAccessUnitInspector.makeProof(
                input: input,
                state: state,
                resolved: resolved
            )
        }

        let resolved: ResolvedInspection
        do {
            resolved = try state.resolve(expected: input.expectedFormat, inheriting: nil)
        } catch let error as VideoAccessUnitInspectionError {
            if case .missingParameterReference = error {
                throw VideoAccessUnitInspectionError.missingInitialParameterCatalog
            }
            throw error
        }
        try state.rejectInactiveCurrentParameterSets(
            currentParameterSetIDs,
            active: resolved.parameterSets
        )
        frozenCatalog = state.frozenCatalog(format: resolved.format)
        return try VideoAccessUnitInspector.makeProof(
            input: input,
            state: state,
            resolved: resolved
        )
    }
}

// MARK: - 有界 RBSP 读取

private struct RBSPByteReader {
    private let ebsp: UnsafeRawBufferPointer
    private var rawIndex: Int
    private var zeroCount = 0

    init(ebsp: UnsafeRawBufferPointer, headerBytes: Int) throws {
        guard headerBytes >= 0, headerBytes < ebsp.count else {
            throw VideoAccessUnitInspectionError.truncatedRBSP
        }
        self.ebsp = ebsp
        rawIndex = headerBytes
    }

    mutating func readByte() throws -> UInt8 {
        guard rawIndex < ebsp.count else {
            throw VideoAccessUnitInspectionError.truncatedRBSP
        }
        var byte = ebsp[rawIndex]
        rawIndex += 1
        if zeroCount == 2 {
            if byte < 3 {
                throw VideoAccessUnitInspectionError.malformedEmulationPrevention
            }
            if byte == 3 {
                guard rawIndex < ebsp.count else {
                    throw VideoAccessUnitInspectionError.malformedEmulationPrevention
                }
                byte = ebsp[rawIndex]
                rawIndex += 1
                guard byte <= 3 else {
                    throw VideoAccessUnitInspectionError.malformedEmulationPrevention
                }
                zeroCount = 0
            }
        }
        zeroCount = byte == 0 ? min(2, zeroCount + 1) : 0
        return byte
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, count <= AnnexBScanner.maximumAccessUnitBytes else {
            throw VideoAccessUnitInspectionError.arithmeticOverflow
        }
        var result: [UInt8] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try readByte()) }
        return result
    }

    mutating func skipBytes(count: Int) throws {
        guard count >= 0, count <= AnnexBScanner.maximumAccessUnitBytes else {
            throw VideoAccessUnitInspectionError.arithmeticOverflow
        }
        for _ in 0..<count { _ = try readByte() }
    }

    mutating func readExtendedValue() throws -> UInt32 {
        var result: UInt32 = 0
        while true {
            let byte = try readByte()
            let (sum, overflowed) = result.addingReportingOverflow(UInt32(byte))
            guard !overflowed else {
                throw VideoAccessUnitInspectionError.arithmeticOverflow
            }
            result = sum
            if byte != 0xFF { return result }
        }
    }

    var isAtEnd: Bool { rawIndex == ebsp.count }

    func isAtTrailingBits() throws -> Bool {
        var copy = self
        let first = try copy.readByte()
        guard first == 0x80 else { return false }
        while copy.rawIndex < copy.ebsp.count {
            guard try copy.readByte() == 0 else { return false }
        }
        return true
    }
}

private struct RBSPBitReader {
    private var bytes: RBSPByteReader
    private var currentByte: UInt8 = 0
    private var remainingBits = 0

    init(ebsp: UnsafeRawBufferPointer, headerBytes: Int) throws {
        bytes = try RBSPByteReader(ebsp: ebsp, headerBytes: headerBytes)
    }

    mutating func readFlag() throws -> Bool { try readBits(1) == 1 }

    mutating func readBits(_ count: Int) throws -> UInt64 {
        guard (0...64).contains(count) else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        var result: UInt64 = 0
        for _ in 0..<count {
            if remainingBits == 0 {
                currentByte = try bytes.readByte()
                remainingBits = 8
            }
            result = (result << 1) | UInt64((currentByte >> 7) & 1)
            currentByte <<= 1
            remainingBits -= 1
        }
        return result
    }

    mutating func readUE() throws -> UInt32 {
        var leadingZeros = 0
        while try readBits(1) == 0 {
            leadingZeros += 1
            guard leadingZeros <= 31 else {
                throw VideoAccessUnitInspectionError.expGolombOverflow
            }
        }
        if leadingZeros == 0 { return 0 }
        let suffix = try readBits(leadingZeros)
        let base = (UInt64(1) << UInt64(leadingZeros)) - 1
        let (codeNum, overflowed) = base.addingReportingOverflow(suffix)
        guard !overflowed, let result = UInt32(exactly: codeNum) else {
            throw VideoAccessUnitInspectionError.expGolombOverflow
        }
        return result
    }

    mutating func readSE() throws -> Int32 {
        let codeNum = try readUE()
        let magnitude = Int64((UInt64(codeNum) + 1) / 2)
        let signed = codeNum & 1 == 0 ? -magnitude : magnitude
        guard let result = Int32(exactly: signed) else {
            throw VideoAccessUnitInspectionError.expGolombOverflow
        }
        return result
    }

    mutating func skipBits(_ count: Int) throws {
        var remaining = count
        while remaining > 0 {
            let step = min(remaining, 64)
            _ = try readBits(step)
            remaining -= step
        }
    }

    /// 参数集语法结束后必须只剩一个 stop bit 与当前字节内的零填充。
    mutating func consumeRBSPTrailingBits() throws {
        guard try readFlag() else {
            throw VideoAccessUnitInspectionError.invalidRBSPTrailingBits
        }
        while remainingBits > 0 {
            guard try readBits(1) == 0 else {
                throw VideoAccessUnitInspectionError.invalidRBSPTrailingBits
            }
        }
        guard bytes.isAtEnd else {
            throw VideoAccessUnitInspectionError.invalidRBSPTrailingBits
        }
    }

    /// 仅用于判断带可选尾部语法的 PPS 是否已经抵达 rbsp_trailing_bits。
    func isAtRBSPTrailingBits() -> Bool {
        var copy = self
        return (try? copy.consumeRBSPTrailingBits()) != nil
    }
}

// MARK: - H.264

private func parseH264SPS(
    _ bytes: UnsafeRawBufferPointer,
    digest: VideoAccessUnitSHA256
) throws -> H264SPSRecord {
    var reader = try RBSPBitReader(ebsp: bytes, headerBytes: 1)
    let profileIDC = UInt8(try reader.readBits(8))
    let compatibilityFlags = UInt32(try reader.readBits(8))
    let levelIDC = UInt8(try reader.readBits(8))
    let id = try reader.readUE()

    var chromaFormatIDC: UInt32 = 1
    var separateColourPlane = false
    var bitDepthLuma: UInt32 = 8
    var bitDepthChroma: UInt32 = 8
    if h264HasExtendedProfileSyntax(profileIDC) {
        chromaFormatIDC = try reader.readUE()
        guard chromaFormatIDC <= 3 else {
            throw VideoAccessUnitInspectionError.unsupportedChromaFormat(chromaFormatIDC)
        }
        if chromaFormatIDC == 3 { separateColourPlane = try reader.readFlag() }
        bitDepthLuma = try checkedAdd(8, reader.readUE())
        bitDepthChroma = try checkedAdd(8, reader.readUE())
        guard bitDepthLuma <= 16, bitDepthChroma <= 16 else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        _ = try reader.readFlag()
        if try reader.readFlag() {
            let count = chromaFormatIDC == 3 ? 12 : 8
            for index in 0..<count {
                if try reader.readFlag() {
                    try skipH264ScalingList(&reader, size: index < 6 ? 16 : 64)
                }
            }
        }
    }

    _ = try reader.readUE() // log2_max_frame_num_minus4
    let picOrderCountType = try reader.readUE()
    switch picOrderCountType {
    case 0:
        _ = try reader.readUE()
    case 1:
        _ = try reader.readFlag()
        _ = try reader.readSE()
        _ = try reader.readSE()
        let cycleCount = try reader.readUE()
        guard cycleCount <= VideoAccessUnitInspector.maximumReferencePictures else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        for _ in 0..<cycleCount { _ = try reader.readSE() }
    case 2:
        break
    default:
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }

    let maximumReferenceFrames = try reader.readUE()
    guard maximumReferenceFrames <= VideoAccessUnitInspector.maximumReferencePictures else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    _ = try reader.readFlag()
    let widthInMBSMinusOne = try reader.readUE()
    let heightInMapUnitsMinusOne = try reader.readUE()
    let frameMBSOnly = try reader.readFlag()
    if !frameMBSOnly { _ = try reader.readFlag() }
    _ = try reader.readFlag()

    var cropLeft: UInt32 = 0
    var cropRight: UInt32 = 0
    var cropTop: UInt32 = 0
    var cropBottom: UInt32 = 0
    if try reader.readFlag() {
        cropLeft = try reader.readUE()
        cropRight = try reader.readUE()
        cropTop = try reader.readUE()
        cropBottom = try reader.readUE()
    }
    let dimensions = try h264Dimensions(
        widthInMBSMinusOne: widthInMBSMinusOne,
        heightInMapUnitsMinusOne: heightInMapUnitsMinusOne,
        frameMBSOnly: frameMBSOnly,
        chromaFormatIDC: chromaFormatIDC,
        separateColourPlane: separateColourPlane,
        cropLeft: cropLeft,
        cropRight: cropRight,
        cropTop: cropTop,
        cropBottom: cropBottom
    )
    var vui = ParsedVUI()
    if try reader.readFlag() { vui = try parseH264VUI(&reader) }
    try reader.consumeRBSPTrailingBits()
    return H264SPSRecord(
        id: id,
        digest: digest,
        profileIDC: profileIDC,
        compatibilityFlags: compatibilityFlags,
        levelIDC: levelIDC,
        chromaFormatIDC: UInt8(chromaFormatIDC),
        bitDepthLuma: UInt8(bitDepthLuma),
        bitDepthChroma: UInt8(bitDepthChroma),
        width: dimensions.width,
        height: dimensions.height,
        codedPictureMacroblockCount: dimensions.codedPictureMacroblockCount,
        maximumReferenceFrames: maximumReferenceFrames,
        frameMBSOnly: frameMBSOnly,
        vui: vui
    )
}

private func parseH264PPS(
    _ bytes: UnsafeRawBufferPointer,
    digest: VideoAccessUnitSHA256
) throws -> H264PPSRecord {
    var reader = try RBSPBitReader(ebsp: bytes, headerBytes: 1)
    let id = try reader.readUE()
    let spsID = try reader.readUE()
    _ = try reader.readFlag() // entropy_coding_mode_flag
    _ = try reader.readFlag() // bottom_field_pic_order_in_frame_present_flag

    let sliceGroupCountMinusOne = try reader.readUE()
    guard sliceGroupCountMinusOne < VideoAccessUnitInspector.maximumReferencePictures else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    if sliceGroupCountMinusOne > 0 {
        let mapType = try reader.readUE()
        switch mapType {
        case 0:
            for _ in 0...sliceGroupCountMinusOne { _ = try reader.readUE() }
        case 1:
            break
        case 2:
            for _ in 0..<sliceGroupCountMinusOne {
                _ = try reader.readUE()
                _ = try reader.readUE()
            }
        case 3...5:
            _ = try reader.readFlag()
            _ = try reader.readUE()
        case 6:
            let mapUnitCountMinusOne = try reader.readUE()
            guard mapUnitCountMinusOne <= 1_048_575 else {
                throw VideoAccessUnitInspectionError.unsupportedSyntax
            }
            let groupCount = try checkedAdd(sliceGroupCountMinusOne, 1)
            let bitCount = bitWidthForExclusiveUpperBound(groupCount)
            for _ in 0...mapUnitCountMinusOne { _ = try reader.readBits(bitCount) }
        default:
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
    }

    _ = try reader.readUE() // num_ref_idx_l0_default_active_minus1
    _ = try reader.readUE() // num_ref_idx_l1_default_active_minus1
    _ = try reader.readFlag() // weighted_pred_flag
    _ = try reader.readBits(2) // weighted_bipred_idc
    _ = try reader.readSE() // pic_init_qp_minus26
    _ = try reader.readSE() // pic_init_qs_minus26
    _ = try reader.readSE() // chroma_qp_index_offset
    _ = try reader.readFlag() // deblocking_filter_control_present_flag
    _ = try reader.readFlag() // constrained_intra_pred_flag
    _ = try reader.readFlag() // redundant_pic_cnt_present_flag

    if !reader.isAtRBSPTrailingBits() {
        _ = try reader.readFlag() // transform_8x8_mode_flag
        if try reader.readFlag() {
            // PPS scaling lists 依赖 active SPS 的 chroma_format_idc；本检查器
            // 尚不能在单次局部解析中可靠绑定，必须明确拒绝而非跳过。
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        _ = try reader.readSE() // second_chroma_qp_index_offset
    }
    try reader.consumeRBSPTrailingBits()
    return H264PPSRecord(id: id, spsID: spsID, digest: digest)
}

private func h264HasExtendedProfileSyntax(_ profile: UInt8) -> Bool {
    [44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 144, 244]
        .contains(profile)
}

private func skipH264ScalingList(
    _ reader: inout RBSPBitReader,
    size: Int
) throws {
    var lastScale = 8
    var nextScale = 8
    for _ in 0..<size {
        if nextScale != 0 {
            let delta = Int(try reader.readSE())
            nextScale = (lastScale + delta + 256) % 256
        }
        if nextScale != 0 { lastScale = nextScale }
    }
}

private func h264Dimensions(
    widthInMBSMinusOne: UInt32,
    heightInMapUnitsMinusOne: UInt32,
    frameMBSOnly: Bool,
    chromaFormatIDC: UInt32,
    separateColourPlane: Bool,
    cropLeft: UInt32,
    cropRight: UInt32,
    cropTop: UInt32,
    cropBottom: UInt32
) throws -> (width: Int32, height: Int32, codedPictureMacroblockCount: UInt32) {
    let widthInMBS = try checkedAdd(1, widthInMBSMinusOne)
    let frameFactor: UInt32 = frameMBSOnly ? 1 : 2
    let heightInMBS = try checkedMultiply(
        try checkedAdd(1, heightInMapUnitsMinusOne),
        frameFactor
    )
    let codedPictureMacroblockCount = try checkedMultiply(widthInMBS, heightInMBS)
    let macroblockWidth = try checkedMultiply(widthInMBS, 16)
    let macroblockHeight = try checkedMultiply(heightInMBS, 16)
    let chromaArrayType = separateColourPlane ? 0 : chromaFormatIDC
    let subWidth: UInt32 = chromaArrayType == 1 || chromaArrayType == 2 ? 2 : 1
    let subHeight: UInt32 = chromaArrayType == 1 ? 2 : 1
    let cropUnitX: UInt32 = chromaArrayType == 0 ? 1 : subWidth
    let cropUnitY = try checkedMultiply(chromaArrayType == 0 ? 1 : subHeight, frameFactor)
    let horizontalCrop = try checkedMultiply(try checkedAdd(cropLeft, cropRight), cropUnitX)
    let verticalCrop = try checkedMultiply(try checkedAdd(cropTop, cropBottom), cropUnitY)
    guard horizontalCrop < macroblockWidth, verticalCrop < macroblockHeight,
          let width = Int32(exactly: macroblockWidth - horizontalCrop),
          let height = Int32(exactly: macroblockHeight - verticalCrop) else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    return (width, height, codedPictureMacroblockCount)
}

private func parseH264VUI(_ reader: inout RBSPBitReader) throws -> ParsedVUI {
    var result = ParsedVUI()
    if try reader.readFlag() { result.sampleAspectRatio = try parseAspectRatio(&reader) }
    if try reader.readFlag() { _ = try reader.readFlag() }
    if try reader.readFlag() {
        _ = try reader.readBits(3)
        result.range = try reader.readFlag() ? .full : .limited
        if try reader.readFlag() {
            let description = try parseColorDescription(&reader)
            result.primaries = description.primaries
            result.transfer = description.transfer
            result.matrix = description.matrix
        }
    }
    if try reader.readFlag() {
        result.chromaLocationWasPresent = true
        let top = try reader.readUE()
        let bottom = try reader.readUE()
        guard top == bottom else { throw VideoAccessUnitInspectionError.unsupportedSyntax }
        result.chromaLocation = try parseChromaLocation(top)
    }
    if try reader.readFlag() {
        let numUnitsInTick = UInt32(try reader.readBits(32))
        let timeScale = UInt32(try reader.readBits(32))
        let fixedFrameRate = try reader.readFlag()
        if fixedFrameRate {
            result.frameRate = try makeMediaRational(
                numerator: UInt64(timeScale),
                denominator: UInt64(numUnitsInTick) * 2
            )
        }
    }
    let hasNALHRD = try reader.readFlag()
    if hasNALHRD { try skipH264HRD(reader: &reader) }
    let hasVCLHRD = try reader.readFlag()
    if hasVCLHRD { try skipH264HRD(reader: &reader) }
    if hasNALHRD || hasVCLHRD { _ = try reader.readFlag() }
    _ = try reader.readFlag() // pic_struct_present_flag
    if try reader.readFlag() {
        _ = try reader.readFlag() // motion_vectors_over_pic_boundaries_flag
        _ = try reader.readUE() // max_bytes_per_pic_denom
        _ = try reader.readUE() // max_bits_per_mb_denom
        _ = try reader.readUE() // log2_max_mv_length_horizontal
        _ = try reader.readUE() // log2_max_mv_length_vertical
        _ = try reader.readUE() // max_num_reorder_frames
        _ = try reader.readUE() // max_dec_frame_buffering
    }
    return result
}

private func skipH264HRD(reader: inout RBSPBitReader) throws {
    let cpbCountMinusOne = try reader.readUE()
    guard cpbCountMinusOne < VideoAccessUnitInspector.maximumReferencePictures else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    _ = try reader.readBits(4)
    _ = try reader.readBits(4)
    for _ in 0...cpbCountMinusOne {
        _ = try reader.readUE()
        _ = try reader.readUE()
        _ = try reader.readFlag()
    }
    _ = try reader.readBits(5)
    _ = try reader.readBits(5)
    _ = try reader.readBits(5)
    _ = try reader.readBits(5)
}

// MARK: - HEVC

private struct HEVCProfileTierLevel {
    let profileIDC: UInt8
    let compatibilityFlags: UInt32
    let constraintIndicatorFlags: UInt64
    let tier: VideoCodecTier
    let levelIDC: UInt8
    let progressiveSourceFlag: Bool
    let interlacedSourceFlag: Bool
}

private func parseHEVCVPS(
    _ bytes: UnsafeRawBufferPointer,
    digest: VideoAccessUnitSHA256
) throws -> HEVCVPSRecord {
    var reader = try RBSPBitReader(ebsp: bytes, headerBytes: 2)
    let id = UInt32(try reader.readBits(4))
    _ = try reader.readFlag() // vps_base_layer_internal_flag
    _ = try reader.readFlag() // vps_base_layer_available_flag
    let maximumLayersMinusOne = UInt32(try reader.readBits(6))
    guard maximumLayersMinusOne == 0 else {
        // 当前 HLS 路径只支持单层 HEVC。
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    let maximumSubLayersMinusOne = Int(try reader.readBits(3))
    guard (0...6).contains(maximumSubLayersMinusOne) else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    _ = try reader.readFlag() // vps_temporal_id_nesting_flag
    guard try reader.readBits(16) == 0xFFFF else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    _ = try parseHEVCProfileTierLevel(
        &reader,
        maximumSubLayersMinusOne: maximumSubLayersMinusOne
    )

    let orderingInfoPresent = try reader.readFlag()
    let orderingStart = orderingInfoPresent ? 0 : maximumSubLayersMinusOne
    for _ in orderingStart...maximumSubLayersMinusOne {
        let bufferingMinusOne = try reader.readUE()
        guard bufferingMinusOne < VideoAccessUnitInspector.maximumReferencePictures else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        _ = try reader.readUE()
        _ = try reader.readUE()
    }
    let maximumLayerID = UInt32(try reader.readBits(6))
    guard maximumLayerID == 0 else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    let layerSetCountMinusOne = try reader.readUE()
    guard layerSetCountMinusOne <= VideoAccessUnitInspector.maximumReferencePictures else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    if layerSetCountMinusOne > 0 {
        for _ in 1...layerSetCountMinusOne {
            for _ in 0...maximumLayerID { _ = try reader.readFlag() }
        }
    }
    if try reader.readFlag() {
        _ = try reader.readBits(32)
        _ = try reader.readBits(32)
        if try reader.readFlag() { _ = try reader.readUE() }
        let hrdParameterCount = try reader.readUE()
        guard hrdParameterCount == 0 else {
            // 多组 VPS HRD 依赖 layer-set 关系；当前不签发其 proof。
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
    }
    if try reader.readFlag() {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    try reader.consumeRBSPTrailingBits()
    return HEVCVPSRecord(id: id, digest: digest)
}

private func parseHEVCSPS(
    _ bytes: UnsafeRawBufferPointer,
    digest: VideoAccessUnitSHA256
) throws -> HEVCSPSRecord {
    var reader = try RBSPBitReader(ebsp: bytes, headerBytes: 2)
    let vpsID = UInt32(try reader.readBits(4))
    let maximumSubLayersMinusOne = Int(try reader.readBits(3))
    guard (0...6).contains(maximumSubLayersMinusOne) else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    _ = try reader.readFlag()
    let profile = try parseHEVCProfileTierLevel(
        &reader,
        maximumSubLayersMinusOne: maximumSubLayersMinusOne
    )
    let id = try reader.readUE()
    let chromaFormatIDC = try reader.readUE()
    guard chromaFormatIDC <= 3 else {
        throw VideoAccessUnitInspectionError.unsupportedChromaFormat(chromaFormatIDC)
    }
    var separateColourPlane = false
    if chromaFormatIDC == 3 { separateColourPlane = try reader.readFlag() }
    let codedWidth = try reader.readUE()
    let codedHeight = try reader.readUE()
    let codedPictureLumaSampleCount = try checkedMultiply(
        UInt64(codedWidth),
        UInt64(codedHeight)
    )
    var left: UInt32 = 0
    var right: UInt32 = 0
    var top: UInt32 = 0
    var bottom: UInt32 = 0
    if try reader.readFlag() {
        left = try reader.readUE()
        right = try reader.readUE()
        top = try reader.readUE()
        bottom = try reader.readUE()
    }
    let dimensions = try hevcDimensions(
        width: codedWidth,
        height: codedHeight,
        chromaFormatIDC: chromaFormatIDC,
        separateColourPlane: separateColourPlane,
        left: left,
        right: right,
        top: top,
        bottom: bottom
    )
    let bitDepthLuma = try checkedAdd(8, reader.readUE())
    let bitDepthChroma = try checkedAdd(8, reader.readUE())
    guard bitDepthLuma <= 16, bitDepthChroma <= 16 else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    let log2MaximumPictureOrderCountLSB = try checkedAdd(4, reader.readUE())
    guard log2MaximumPictureOrderCountLSB <= 32 else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }

    let orderingInfoPresent = try reader.readFlag()
    let orderingStart = orderingInfoPresent ? 0 : maximumSubLayersMinusOne
    var maximumReferenceFrames: UInt32 = 0
    for _ in orderingStart...maximumSubLayersMinusOne {
        let bufferingMinusOne = try reader.readUE()
        maximumReferenceFrames = max(maximumReferenceFrames, try checkedAdd(1, bufferingMinusOne))
        guard maximumReferenceFrames <= VideoAccessUnitInspector.maximumReferencePictures else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        _ = try reader.readUE()
        _ = try reader.readUE()
    }
    _ = try reader.readUE()
    _ = try reader.readUE()
    _ = try reader.readUE()
    _ = try reader.readUE()
    _ = try reader.readUE()
    _ = try reader.readUE()

    if try reader.readFlag(), try reader.readFlag() {
        try skipHEVCScalingList(&reader)
    }
    _ = try reader.readFlag()
    _ = try reader.readFlag()
    if try reader.readFlag() {
        _ = try reader.readBits(4)
        _ = try reader.readBits(4)
        _ = try reader.readUE()
        _ = try reader.readUE()
        _ = try reader.readFlag()
    }

    let shortTermSetCount = try reader.readUE()
    guard shortTermSetCount <= VideoAccessUnitInspector.maximumReferencePictures else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    var deltaPictureCounts: [UInt32] = []
    deltaPictureCounts.reserveCapacity(Int(shortTermSetCount))
    for index in 0..<Int(shortTermSetCount) {
        let count = try skipHEVCShortTermReferencePictureSet(
            &reader,
            index: index,
            previousDeltaPictureCounts: deltaPictureCounts
        )
        deltaPictureCounts.append(count)
    }
    if try reader.readFlag() {
        let count = try reader.readUE()
        guard count <= VideoAccessUnitInspector.maximumReferencePictures else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        for _ in 0..<count {
            _ = try reader.readBits(Int(log2MaximumPictureOrderCountLSB))
            _ = try reader.readFlag()
        }
    }
    _ = try reader.readFlag()
    _ = try reader.readFlag()
    var vui = ParsedVUI(
        progressiveSourceFlag: profile.progressiveSourceFlag,
        interlacedSourceFlag: profile.interlacedSourceFlag
    )
    if try reader.readFlag() {
        let parsed = try parseHEVCVUI(
            &reader,
            maximumSubLayersMinusOne: maximumSubLayersMinusOne
        )
        vui.sampleAspectRatio = parsed.sampleAspectRatio
        vui.frameRate = parsed.frameRate
        vui.range = parsed.range
        vui.primaries = parsed.primaries
        vui.transfer = parsed.transfer
        vui.matrix = parsed.matrix
        vui.chromaLocation = parsed.chromaLocation
        vui.chromaLocationWasPresent = parsed.chromaLocationWasPresent
    }
    if try reader.readFlag() {
        let rangeExtension = try reader.readFlag()
        let multilayerExtension = try reader.readFlag()
        let extension3D = try reader.readFlag()
        let sccExtension = try reader.readFlag()
        let extensionBits = try reader.readBits(4)
        guard !rangeExtension, !multilayerExtension, !extension3D,
              !sccExtension, extensionBits == 0 else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
    }
    try reader.consumeRBSPTrailingBits()
    return HEVCSPSRecord(
        id: id,
        vpsID: vpsID,
        digest: digest,
        profileIDC: profile.profileIDC,
        compatibilityFlags: profile.compatibilityFlags,
        constraintIndicatorFlags: profile.constraintIndicatorFlags,
        levelIDC: profile.levelIDC,
        tier: profile.tier,
        chromaFormatIDC: UInt8(chromaFormatIDC),
        bitDepthLuma: UInt8(bitDepthLuma),
        bitDepthChroma: UInt8(bitDepthChroma),
        width: dimensions.width,
        height: dimensions.height,
        codedPictureLumaSampleCount: codedPictureLumaSampleCount,
        maximumReferenceFrames: maximumReferenceFrames,
        vui: vui
    )
}

private func parseHEVCPPS(
    _ bytes: UnsafeRawBufferPointer,
    digest: VideoAccessUnitSHA256
) throws -> HEVCPPSRecord {
    var reader = try RBSPBitReader(ebsp: bytes, headerBytes: 2)
    let id = try reader.readUE()
    let spsID = try reader.readUE()
    _ = try reader.readFlag() // dependent_slice_segments_enabled_flag
    _ = try reader.readFlag() // output_flag_present_flag
    _ = try reader.readBits(3) // num_extra_slice_header_bits
    _ = try reader.readFlag() // sign_data_hiding_enabled_flag
    _ = try reader.readFlag() // cabac_init_present_flag
    _ = try reader.readUE() // num_ref_idx_l0_default_active_minus1
    _ = try reader.readUE() // num_ref_idx_l1_default_active_minus1
    _ = try reader.readSE() // init_qp_minus26
    _ = try reader.readFlag() // constrained_intra_pred_flag
    _ = try reader.readFlag() // transform_skip_enabled_flag
    if try reader.readFlag() { _ = try reader.readUE() }
    _ = try reader.readSE() // pps_cb_qp_offset
    _ = try reader.readSE() // pps_cr_qp_offset
    _ = try reader.readFlag() // pps_slice_chroma_qp_offsets_present_flag
    _ = try reader.readFlag() // weighted_pred_flag
    _ = try reader.readFlag() // weighted_bipred_flag
    _ = try reader.readFlag() // transquant_bypass_enabled_flag
    let tilesEnabled = try reader.readFlag()
    _ = try reader.readFlag() // entropy_coding_sync_enabled_flag
    if tilesEnabled {
        let columnCountMinusOne = try reader.readUE()
        let rowCountMinusOne = try reader.readUE()
        guard columnCountMinusOne < VideoAccessUnitInspector.maximumReferencePictures,
              rowCountMinusOne < VideoAccessUnitInspector.maximumReferencePictures else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        if !(try reader.readFlag()) {
            for _ in 0..<columnCountMinusOne { _ = try reader.readUE() }
            for _ in 0..<rowCountMinusOne { _ = try reader.readUE() }
        }
        _ = try reader.readFlag() // loop_filter_across_tiles_enabled_flag
    }
    _ = try reader.readFlag() // pps_loop_filter_across_slices_enabled_flag
    if try reader.readFlag() {
        _ = try reader.readFlag() // deblocking_filter_override_enabled_flag
        let disabled = try reader.readFlag()
        if !disabled {
            _ = try reader.readSE()
            _ = try reader.readSE()
        }
    }
    if try reader.readFlag() {
        // scaling_list_data() 很大且会改变解码配置，未完整支持时必须拒绝。
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    _ = try reader.readFlag() // lists_modification_present_flag
    _ = try reader.readUE() // log2_parallel_merge_level_minus2
    _ = try reader.readFlag() // slice_segment_header_extension_present_flag
    if try reader.readFlag() {
        let rangeExtension = try reader.readFlag()
        let multilayerExtension = try reader.readFlag()
        let extension3D = try reader.readFlag()
        let sccExtension = try reader.readFlag()
        let extensionBits = try reader.readBits(4)
        guard !rangeExtension, !multilayerExtension, !extension3D,
              !sccExtension, extensionBits == 0 else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
    }
    try reader.consumeRBSPTrailingBits()
    return HEVCPPSRecord(id: id, spsID: spsID, digest: digest)
}

private func parseHEVCProfileTierLevel(
    _ reader: inout RBSPBitReader,
    maximumSubLayersMinusOne: Int
) throws -> HEVCProfileTierLevel {
    _ = try reader.readBits(2)
    let tier: VideoCodecTier = try reader.readFlag() ? .high : .main
    let profileIDC = UInt8(try reader.readBits(5))
    let compatibilityFlags = UInt32(try reader.readBits(32))
    let constraintIndicatorFlags = try reader.readBits(48)
    let progressive = constraintIndicatorFlags & (UInt64(1) << 47) != 0
    let interlaced = constraintIndicatorFlags & (UInt64(1) << 46) != 0
    let levelIDC = UInt8(try reader.readBits(8))

    var subLayerProfilePresent = [Bool](repeating: false, count: maximumSubLayersMinusOne)
    var subLayerLevelPresent = [Bool](repeating: false, count: maximumSubLayersMinusOne)
    if maximumSubLayersMinusOne > 0 {
        for index in 0..<maximumSubLayersMinusOne {
            subLayerProfilePresent[index] = try reader.readFlag()
            subLayerLevelPresent[index] = try reader.readFlag()
        }
        for _ in maximumSubLayersMinusOne..<8 { try reader.skipBits(2) }
        for index in 0..<maximumSubLayersMinusOne {
            if subLayerProfilePresent[index] { try reader.skipBits(88) }
            if subLayerLevelPresent[index] { try reader.skipBits(8) }
        }
    }
    return HEVCProfileTierLevel(
        profileIDC: profileIDC,
        compatibilityFlags: compatibilityFlags,
        constraintIndicatorFlags: constraintIndicatorFlags,
        tier: tier,
        levelIDC: levelIDC,
        progressiveSourceFlag: progressive,
        interlacedSourceFlag: interlaced
    )
}

private func hevcDimensions(
    width: UInt32,
    height: UInt32,
    chromaFormatIDC: UInt32,
    separateColourPlane: Bool,
    left: UInt32,
    right: UInt32,
    top: UInt32,
    bottom: UInt32
) throws -> (width: Int32, height: Int32) {
    let chromaArrayType = separateColourPlane ? 0 : chromaFormatIDC
    let subWidth: UInt32 = chromaArrayType == 1 || chromaArrayType == 2 ? 2 : 1
    let subHeight: UInt32 = chromaArrayType == 1 ? 2 : 1
    let cropX = try checkedMultiply(try checkedAdd(left, right), subWidth)
    let cropY = try checkedMultiply(try checkedAdd(top, bottom), subHeight)
    guard cropX < width, cropY < height,
          let resultWidth = Int32(exactly: width - cropX),
          let resultHeight = Int32(exactly: height - cropY) else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    return (resultWidth, resultHeight)
}

private func skipHEVCScalingList(_ reader: inout RBSPBitReader) throws {
    for sizeID in 0..<4 {
        let step = sizeID == 3 ? 3 : 1
        for _ in stride(from: 0, to: 6, by: step) {
            if !(try reader.readFlag()) {
                _ = try reader.readUE()
            } else {
                let coefficientCount = min(64, 1 << (4 + 2 * sizeID))
                if sizeID > 1 { _ = try reader.readSE() }
                for _ in 0..<coefficientCount { _ = try reader.readSE() }
            }
        }
    }
}

private func skipHEVCShortTermReferencePictureSet(
    _ reader: inout RBSPBitReader,
    index: Int,
    previousDeltaPictureCounts: [UInt32]
) throws -> UInt32 {
    guard index >= 0, index == previousDeltaPictureCounts.count else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    let interPrediction: Bool
    if index == 0 {
        interPrediction = false
    } else {
        interPrediction = try reader.readFlag()
    }
    if interPrediction {
        _ = try reader.readFlag()
        _ = try reader.readUE()
        guard previousDeltaPictureCounts.indices.contains(index - 1) else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        let referenceCount = previousDeltaPictureCounts[index - 1]
        var count: UInt32 = 0
        for _ in 0...referenceCount {
            let used = try reader.readFlag()
            let useDelta: Bool
            if used {
                useDelta = false
            } else {
                useDelta = try reader.readFlag()
            }
            if used || useDelta { count = try checkedAdd(count, 1) }
        }
        guard count <= VideoAccessUnitInspector.maximumReferencePictures else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        return count
    }

    let negative = try reader.readUE()
    let positive = try reader.readUE()
    let count = try checkedAdd(negative, positive)
    guard count <= VideoAccessUnitInspector.maximumReferencePictures else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    for _ in 0..<negative {
        _ = try reader.readUE()
        _ = try reader.readFlag()
    }
    for _ in 0..<positive {
        _ = try reader.readUE()
        _ = try reader.readFlag()
    }
    return count
}

private func parseHEVCVUI(
    _ reader: inout RBSPBitReader,
    maximumSubLayersMinusOne: Int
) throws -> ParsedVUI {
    var result = ParsedVUI()
    if try reader.readFlag() { result.sampleAspectRatio = try parseAspectRatio(&reader) }
    if try reader.readFlag() { _ = try reader.readFlag() }
    if try reader.readFlag() {
        _ = try reader.readBits(3)
        result.range = try reader.readFlag() ? .full : .limited
        if try reader.readFlag() {
            let description = try parseColorDescription(&reader)
            result.primaries = description.primaries
            result.transfer = description.transfer
            result.matrix = description.matrix
        }
    }
    if try reader.readFlag() {
        result.chromaLocationWasPresent = true
        let top = try reader.readUE()
        let bottom = try reader.readUE()
        guard top == bottom else { throw VideoAccessUnitInspectionError.unsupportedSyntax }
        result.chromaLocation = try parseChromaLocation(top)
    }
    _ = try reader.readFlag()
    _ = try reader.readFlag()
    _ = try reader.readFlag()
    if try reader.readFlag() {
        _ = try reader.readUE()
        _ = try reader.readUE()
        _ = try reader.readUE()
        _ = try reader.readUE()
    }
    if try reader.readFlag() {
        let numUnitsInTick = UInt32(try reader.readBits(32))
        let timeScale = UInt32(try reader.readBits(32))
        var tickDivisor: UInt64 = 1
        if try reader.readFlag() {
            tickDivisor = try checkedAdd(UInt64(try reader.readUE()), 1)
        }
        result.frameRate = try makeMediaRational(
            numerator: UInt64(timeScale),
            denominator: try checkedMultiply(UInt64(numUnitsInTick), tickDivisor)
        )
        if try reader.readFlag() {
            try skipHEVCHRD(&reader, maximumSubLayersMinusOne: maximumSubLayersMinusOne)
        }
    }
    if try reader.readFlag() {
        _ = try reader.readFlag()
        _ = try reader.readFlag()
        _ = try reader.readFlag()
        _ = try reader.readUE()
        _ = try reader.readUE()
        _ = try reader.readUE()
        _ = try reader.readUE()
        _ = try reader.readUE()
    }
    return result
}

private func skipHEVCHRD(
    _ reader: inout RBSPBitReader,
    maximumSubLayersMinusOne: Int
) throws {
    let nalPresent = try reader.readFlag()
    let vclPresent = try reader.readFlag()
    var subPicture = false
    if nalPresent || vclPresent {
        subPicture = try reader.readFlag()
        if subPicture {
            try reader.skipBits(8)
            try reader.skipBits(5)
            _ = try reader.readFlag()
            try reader.skipBits(5)
        }
        try reader.skipBits(4)
        try reader.skipBits(4)
        if subPicture { try reader.skipBits(4) }
        try reader.skipBits(5)
        try reader.skipBits(5)
        try reader.skipBits(5)
    }
    for _ in 0...maximumSubLayersMinusOne {
        let fixedGeneral = try reader.readFlag()
        let fixedWithin: Bool
        if fixedGeneral {
            fixedWithin = true
        } else {
            fixedWithin = try reader.readFlag()
        }
        var lowDelay = false
        if fixedWithin {
            _ = try reader.readUE()
        } else {
            lowDelay = try reader.readFlag()
        }
        let cpbCountMinusOne: UInt32
        if lowDelay {
            cpbCountMinusOne = 0
        } else {
            cpbCountMinusOne = try reader.readUE()
        }
        guard cpbCountMinusOne <= 31 else {
            throw VideoAccessUnitInspectionError.unsupportedSyntax
        }
        if nalPresent {
            try skipHEVCSubLayerHRD(&reader, cpbCountMinusOne: cpbCountMinusOne, subPicture: subPicture)
        }
        if vclPresent {
            try skipHEVCSubLayerHRD(&reader, cpbCountMinusOne: cpbCountMinusOne, subPicture: subPicture)
        }
    }
}

private func skipHEVCSubLayerHRD(
    _ reader: inout RBSPBitReader,
    cpbCountMinusOne: UInt32,
    subPicture: Bool
) throws {
    for _ in 0...cpbCountMinusOne {
        _ = try reader.readUE()
        _ = try reader.readUE()
        if subPicture {
            _ = try reader.readUE()
            _ = try reader.readUE()
        }
        _ = try reader.readFlag()
    }
}

// MARK: - 颜色、HDR、签名与交叉校验

private func insertParameterSet<Record: ParameterSetRecord>(
    _ record: Record,
    into records: inout [UInt32: Record],
    kind: VideoParameterSetKind
) throws {
    guard record.id <= VideoAccessUnitInspector.maximumParameterSetID else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    if let existing = records[record.id], existing.digest != record.digest {
        throw VideoAccessUnitInspectionError.conflictingParameterSet(kind: kind, id: record.id)
    }
    records[record.id] = record
}

private func parseAspectRatio(_ reader: inout RBSPBitReader) throws -> MediaRational? {
    let idc = UInt8(try reader.readBits(8))
    let ratio: (UInt32, UInt32)?
    switch idc {
    case 0: ratio = nil
    case 1: ratio = (1, 1)
    case 2: ratio = (12, 11)
    case 3: ratio = (10, 11)
    case 4: ratio = (16, 11)
    case 5: ratio = (40, 33)
    case 6: ratio = (24, 11)
    case 7: ratio = (20, 11)
    case 8: ratio = (32, 11)
    case 9: ratio = (80, 33)
    case 10: ratio = (18, 11)
    case 11: ratio = (15, 11)
    case 12: ratio = (64, 33)
    case 13: ratio = (160, 99)
    case 14: ratio = (4, 3)
    case 15: ratio = (3, 2)
    case 16: ratio = (2, 1)
    case 255:
        ratio = (UInt32(try reader.readBits(16)), UInt32(try reader.readBits(16)))
    default:
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    guard let ratio else { return nil }
    return try makeMediaRational(
        numerator: UInt64(ratio.0),
        denominator: UInt64(ratio.1)
    )
}

private func parseChromaLocation(_ value: UInt32) throws -> DemuxChromaLocation? {
    switch value {
    case 0: return .left
    case 1: return .center
    case 2: return .topLeft
    case 3...5: return nil
    default: throw VideoAccessUnitInspectionError.unsupportedChromaLocation(value)
    }
}

private func parseColorDescription(
    _ reader: inout RBSPBitReader
) throws -> (
    primaries: DemuxColorPrimaries,
    transfer: DemuxColorTransfer,
    matrix: DemuxColorMatrix
) {
    let primariesValue = UInt16(try reader.readBits(8))
    guard let primaries = DemuxColorPrimaries(rawValue: primariesValue) else {
        throw VideoAccessUnitInspectionError.unsupportedColorPrimaries(primariesValue)
    }
    let transferValue = UInt16(try reader.readBits(8))
    guard let transfer = DemuxColorTransfer(rawValue: transferValue) else {
        throw VideoAccessUnitInspectionError.unsupportedColorTransfer(transferValue)
    }
    let matrixValue = UInt16(try reader.readBits(8))
    guard let matrix = DemuxColorMatrix(rawValue: matrixValue) else {
        throw VideoAccessUnitInspectionError.unsupportedColorMatrix(matrixValue)
    }
    return (primaries, transfer, matrix)
}

private func parseMasteringDisplay(
    _ payload: [UInt8]
) throws -> DemuxMasteringDisplayMetadata {
    func chroma(_ offset: Int) throws -> DemuxHDRRational? {
        DemuxHDRRational(num: Int32(try readUInt16(payload, at: offset)), den: 50_000)
    }
    func luminance(_ offset: Int) throws -> DemuxHDRRational? {
        let value = try readUInt32(payload, at: offset)
        guard let numerator = Int32(exactly: value) else { return nil }
        return DemuxHDRRational(num: numerator, den: 10_000)
    }
    // ISO/IEC 23008-2 的 payload 顺序是 green、blue、red。
    guard let greenX = try chroma(0), let greenY = try chroma(2),
          let blueX = try chroma(4), let blueY = try chroma(6),
          let redX = try chroma(8), let redY = try chroma(10),
          let whiteX = try chroma(12), let whiteY = try chroma(14),
          let maximum = try luminance(16), let minimum = try luminance(20),
          let result = DemuxMasteringDisplayMetadata(
            redX: redX,
            redY: redY,
            greenX: greenX,
            greenY: greenY,
            blueX: blueX,
            blueY: blueY,
            whitePointX: whiteX,
            whitePointY: whiteY,
            minimumLuminance: minimum,
            maximumLuminance: maximum
          ) else {
        throw VideoAccessUnitInspectionError.invalidHDRMetadata
    }
    return result
}

private func inheritingMissingFormatMetadata(
    _ current: VideoAccessUnitFormatSummary,
    from frozen: VideoAccessUnitFormatSummary?
) -> VideoAccessUnitFormatSummary {
    guard let frozen else { return current }
    return VideoAccessUnitFormatSummary(
        codec: current.codec,
        profileIDC: current.profileIDC,
        profileCompatibilityFlags: current.profileCompatibilityFlags,
        levelIDC: current.levelIDC,
        tier: current.tier,
        chromaFormatIDC: current.chromaFormatIDC,
        bitDepthLuma: current.bitDepthLuma,
        bitDepthChroma: current.bitDepthChroma,
        width: current.width,
        height: current.height,
        codedPictureMacroblockCount: current.codedPictureMacroblockCount,
        codedPictureLumaSampleCount: current.codedPictureLumaSampleCount,
        maximumReferenceFrames: current.maximumReferenceFrames,
        progressiveSourceFlag: current.progressiveSourceFlag ?? frozen.progressiveSourceFlag,
        interlacedSourceFlag: current.interlacedSourceFlag ?? frozen.interlacedSourceFlag,
        sampleAspectRatio: current.sampleAspectRatio ?? frozen.sampleAspectRatio,
        frameRate: current.frameRate ?? frozen.frameRate,
        range: current.range ?? frozen.range,
        primaries: current.primaries ?? frozen.primaries,
        transfer: current.transfer ?? frozen.transfer,
        matrix: current.matrix ?? frozen.matrix,
        chromaLocation: current.chromaLocation ?? frozen.chromaLocation,
        masteringDisplay: current.masteringDisplay ?? frozen.masteringDisplay,
        contentLightLevel: current.contentLightLevel ?? frozen.contentLightLevel
    )
}

private func makeFormatIdentity(
    parameterSets: VideoParameterSetSignature,
    format: VideoAccessUnitFormatSummary
) -> VideoAccessUnitFormatIdentity {
    var canonical = Data("VPlayer.VideoAccessUnitFormatIdentity.v1".utf8)
    canonical.append(0)

    func appendDigest(_ digest: VideoAccessUnitSHA256) {
        appendBigEndian(digest.word0, to: &canonical)
        appendBigEndian(digest.word1, to: &canonical)
        appendBigEndian(digest.word2, to: &canonical)
        appendBigEndian(digest.word3, to: &canonical)
    }
    func appendOptionalDigest(_ digest: VideoAccessUnitSHA256?) {
        canonical.append(digest == nil ? 0 : 1)
        if let digest { appendDigest(digest) }
    }
    func appendOptionalBool(_ value: Bool?) {
        switch value {
        case nil: canonical.append(0)
        case false?: canonical.append(1)
        case true?: canonical.append(2)
        }
    }
    func appendOptionalRational(_ value: MediaRational?) {
        canonical.append(value == nil ? 0 : 1)
        if let value {
            appendBigEndian(value.num, to: &canonical)
            appendBigEndian(value.den, to: &canonical)
        }
    }
    func appendHDRRational(_ value: DemuxHDRRational) {
        appendBigEndian(value.num, to: &canonical)
        appendBigEndian(value.den, to: &canonical)
    }

    canonical.append(parameterSets.codec.rawValue)
    canonical.append(parameterSets.vpsID == nil ? 0 : 1)
    if let value = parameterSets.vpsID { appendBigEndian(value, to: &canonical) }
    appendBigEndian(parameterSets.spsID, to: &canonical)
    appendBigEndian(parameterSets.ppsID, to: &canonical)
    appendOptionalDigest(parameterSets.vpsSHA256)
    appendDigest(parameterSets.spsSHA256)
    appendDigest(parameterSets.ppsSHA256)
    appendDigest(parameterSets.combinedSHA256)

    canonical.append(format.codec.rawValue)
    canonical.append(format.profileIDC)
    appendBigEndian(format.profileCompatibilityFlags, to: &canonical)
    canonical.append(format.levelIDC)
    canonical.append(format.tier.rawValue)
    canonical.append(format.chromaFormatIDC)
    canonical.append(format.bitDepthLuma)
    canonical.append(format.bitDepthChroma)
    appendBigEndian(format.width, to: &canonical)
    appendBigEndian(format.height, to: &canonical)
    canonical.append(format.codedPictureMacroblockCount == nil ? 0 : 1)
    if let value = format.codedPictureMacroblockCount {
        appendBigEndian(value, to: &canonical)
    }
    canonical.append(format.codedPictureLumaSampleCount == nil ? 0 : 1)
    if let value = format.codedPictureLumaSampleCount {
        appendBigEndian(value, to: &canonical)
    }
    appendBigEndian(format.maximumReferenceFrames, to: &canonical)
    appendOptionalBool(format.progressiveSourceFlag)
    appendOptionalBool(format.interlacedSourceFlag)
    appendOptionalRational(format.sampleAspectRatio)
    appendOptionalRational(format.frameRate)

    canonical.append(format.range == nil ? 0 : 1)
    if let value = format.range { canonical.append(value.rawValue) }
    canonical.append(format.primaries == nil ? 0 : 1)
    if let value = format.primaries { appendBigEndian(value.rawValue, to: &canonical) }
    canonical.append(format.transfer == nil ? 0 : 1)
    if let value = format.transfer { appendBigEndian(value.rawValue, to: &canonical) }
    canonical.append(format.matrix == nil ? 0 : 1)
    if let value = format.matrix { appendBigEndian(value.rawValue, to: &canonical) }
    canonical.append(format.chromaLocation == nil ? 0 : 1)
    if let value = format.chromaLocation { canonical.append(value.rawValue) }

    canonical.append(format.masteringDisplay == nil ? 0 : 1)
    if let value = format.masteringDisplay {
        appendHDRRational(value.redX)
        appendHDRRational(value.redY)
        appendHDRRational(value.greenX)
        appendHDRRational(value.greenY)
        appendHDRRational(value.blueX)
        appendHDRRational(value.blueY)
        appendHDRRational(value.whitePointX)
        appendHDRRational(value.whitePointY)
        appendHDRRational(value.minimumLuminance)
        appendHDRRational(value.maximumLuminance)
    }
    canonical.append(format.contentLightLevel == nil ? 0 : 1)
    if let value = format.contentLightLevel {
        appendBigEndian(value.maximumContentLightLevel, to: &canonical)
        appendBigEndian(value.maximumFrameAverageLightLevel, to: &canonical)
    }

    return VideoAccessUnitFormatIdentity(
        sha256: VideoAccessUnitSHA256(bytes: canonical.span)
    )
}

private func mergeAndValidate(
    _ parsed: VideoAccessUnitFormatSummary,
    expected: VideoTrackDescriptor?
) throws -> VideoAccessUnitFormatSummary {
    guard let expected else { return parsed }
    guard expected.codec == parsed.codec else {
        throw VideoAccessUnitInspectionError.metadataMismatch(.codec)
    }
    guard expected.width == parsed.width, expected.height == parsed.height else {
        throw VideoAccessUnitInspectionError.metadataMismatch(.dimensions)
    }
    try validateIfBoth(parsed.frameRate, expected.frameRate, field: .frameRate)
    switch expected.fieldOrder {
    case .unknown:
        break
    case .progressive:
        if parsed.interlacedSourceFlag == true {
            throw VideoAccessUnitInspectionError.metadataMismatch(.fieldOrder)
        }
    case .tt, .bb, .tb, .bt:
        if parsed.progressiveSourceFlag == true {
            throw VideoAccessUnitInspectionError.metadataMismatch(.fieldOrder)
        }
    }

    let metadata = expected.videoMetadata
    try validateIfBoth(parsed.sampleAspectRatio, metadata.sampleAspectRatio, field: .sampleAspectRatio)
    try validateIfBoth(parsed.range, metadata.range, field: .range)
    try validateIfBoth(parsed.primaries, metadata.primaries, field: .primaries)
    try validateIfBoth(parsed.transfer, metadata.transfer, field: .transfer)
    try validateIfBoth(parsed.matrix, metadata.matrix, field: .matrix)
    try validateIfBoth(parsed.chromaLocation, metadata.chromaLocation, field: .chromaLocation)
    try validateIfBoth(parsed.masteringDisplay, metadata.masteringDisplay, field: .masteringDisplay)
    try validateIfBoth(parsed.contentLightLevel, metadata.contentLightLevel, field: .contentLightLevel)

    return VideoAccessUnitFormatSummary(
        codec: parsed.codec,
        profileIDC: parsed.profileIDC,
        profileCompatibilityFlags: parsed.profileCompatibilityFlags,
        levelIDC: parsed.levelIDC,
        tier: parsed.tier,
        chromaFormatIDC: parsed.chromaFormatIDC,
        bitDepthLuma: parsed.bitDepthLuma,
        bitDepthChroma: parsed.bitDepthChroma,
        width: parsed.width,
        height: parsed.height,
        codedPictureMacroblockCount: parsed.codedPictureMacroblockCount,
        codedPictureLumaSampleCount: parsed.codedPictureLumaSampleCount,
        maximumReferenceFrames: parsed.maximumReferenceFrames,
        progressiveSourceFlag: parsed.progressiveSourceFlag,
        interlacedSourceFlag: parsed.interlacedSourceFlag,
        sampleAspectRatio: parsed.sampleAspectRatio ?? metadata.sampleAspectRatio,
        frameRate: parsed.frameRate ?? expected.frameRate,
        range: parsed.range ?? metadata.range,
        primaries: parsed.primaries ?? metadata.primaries,
        transfer: parsed.transfer ?? metadata.transfer,
        matrix: parsed.matrix ?? metadata.matrix,
        chromaLocation: parsed.chromaLocation ?? metadata.chromaLocation,
        masteringDisplay: parsed.masteringDisplay ?? metadata.masteringDisplay,
        contentLightLevel: parsed.contentLightLevel ?? metadata.contentLightLevel
    )
}

private func validateIfBoth<Value: Equatable>(
    _ parsed: Value?,
    _ expected: Value?,
    field: VideoFormatMetadataField
) throws {
    if let parsed, let expected, parsed != expected {
        throw VideoAccessUnitInspectionError.metadataMismatch(field)
    }
}

private func makeMediaRational(
    numerator: UInt64,
    denominator: UInt64
) throws -> MediaRational {
    guard numerator > 0, denominator > 0 else {
        throw VideoAccessUnitInspectionError.unsupportedSyntax
    }
    let divisor = greatestCommonDivisorForInspector(numerator, denominator)
    guard let reducedNumerator = Int32(exactly: numerator / divisor),
          let reducedDenominator = Int32(exactly: denominator / divisor),
          let result = MediaRational(num: reducedNumerator, den: reducedDenominator) else {
        throw VideoAccessUnitInspectionError.arithmeticOverflow
    }
    return result
}

private func appendSignature<Record: ParameterSetRecord>(
    _ record: Record?,
    marker: UInt8,
    to data: inout Data
) {
    data.append(marker)
    guard let record else {
        data.append(0)
        return
    }
    data.append(1)
    appendBigEndian(record.id, to: &data)
    appendBigEndian(record.digest.word0, to: &data)
    appendBigEndian(record.digest.word1, to: &data)
    appendBigEndian(record.digest.word2, to: &data)
    appendBigEndian(record.digest.word3, to: &data)
}

private func appendBigEndian<Value: FixedWidthInteger>(
    _ value: Value,
    to data: inout Data
) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private func readUInt16(_ bytes: [UInt8], at offset: Int) throws -> UInt16 {
    guard offset >= 0 else { throw VideoAccessUnitInspectionError.truncatedRBSP }
    let (end, overflowed) = offset.addingReportingOverflow(2)
    guard !overflowed, end <= bytes.count else {
        throw VideoAccessUnitInspectionError.truncatedRBSP
    }
    return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
    guard offset >= 0 else { throw VideoAccessUnitInspectionError.truncatedRBSP }
    let (end, overflowed) = offset.addingReportingOverflow(4)
    guard !overflowed, end <= bytes.count else {
        throw VideoAccessUnitInspectionError.truncatedRBSP
    }
    return UInt32(bytes[offset]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
}

private func checkedIncrement(_ value: UInt32) throws -> UInt32 {
    try checkedAdd(value, 1)
}

private func checkedAdd(_ lhs: UInt32, _ rhs: UInt32) throws -> UInt32 {
    let (result, overflowed) = lhs.addingReportingOverflow(rhs)
    guard !overflowed else { throw VideoAccessUnitInspectionError.arithmeticOverflow }
    return result
}

private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (result, overflowed) = lhs.addingReportingOverflow(rhs)
    guard !overflowed else { throw VideoAccessUnitInspectionError.arithmeticOverflow }
    return result
}

private func checkedMultiply(_ lhs: UInt32, _ rhs: UInt32) throws -> UInt32 {
    let (result, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflowed else { throw VideoAccessUnitInspectionError.arithmeticOverflow }
    return result
}

private func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (result, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflowed else { throw VideoAccessUnitInspectionError.arithmeticOverflow }
    return result
}

private func bitWidthForExclusiveUpperBound(_ upperBound: UInt32) -> Int {
    guard upperBound > 1 else { return 0 }
    return UInt32.bitWidth - (upperBound - 1).leadingZeroBitCount
}

private func greatestCommonDivisorForInspector(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var first = lhs
    var second = rhs
    while second != 0 { (first, second) = (second, first % second) }
    return first == 0 ? 1 : first
}

extension VideoAccessUnitInspectionProof: VideoRemuxInspectionEvidence {
    var remuxGeneration: MediaGeneration { identity.generation }
    var remuxCodec: VideoCodec { codec }
    var remuxRandomAccessKind: VideoRandomAccessKind { randomAccessKind }
    var remuxParameterSetIdentity: VideoAccessUnitSHA256? { parameterSets.combinedSHA256 }
    var remuxFormatIdentity: VideoAccessUnitSHA256? { formatIdentity.sha256 }
    var remuxProfileIDC: UInt8 { format.profileIDC }
    var remuxProfileCompatibilityFlags: UInt32 { format.profileCompatibilityFlags }
    var remuxLevelIDC: UInt8 { format.levelIDC }
    var remuxTier: VideoCodecTier { format.tier }
    var remuxWidth: Int32? { format.width }
    var remuxHeight: Int32? { format.height }
    var remuxCodedPictureSizeInMacroblocks: UInt32? { format.codedPictureMacroblockCount }
    var remuxCodedLumaPictureSize: UInt64? { format.codedPictureLumaSampleCount }
    var remuxMaximumReferenceFrames: UInt32? { format.maximumReferenceFrames }
    var remuxFrameRate: MediaRational? { format.frameRate }
    var remuxChromaFormatIDC: UInt8? { format.chromaFormatIDC }
    var remuxBitDepthLuma: UInt8? { format.bitDepthLuma }
    var remuxBitDepthChroma: UInt8? { format.bitDepthChroma }
    var remuxColorPrimaries: DemuxColorPrimaries? { format.primaries }
    var remuxColorTransfer: DemuxColorTransfer? { format.transfer }
    var remuxColorMatrix: DemuxColorMatrix? { format.matrix }
    var remuxMasteringDisplay: DemuxMasteringDisplayMetadata? { format.masteringDisplay }
    var remuxContentLightLevel: DemuxContentLightLevelMetadata? { format.contentLightLevel }
    var remuxScanClassification: VideoScanClassificationEvidence { scanClassification }
    var remuxPresentationTimeStamp: ExactMediaTime? { presentationTimeStamp }
    var remuxDecodeTimeStamp: ExactMediaTime? { decodeTimeStamp }
    var remuxDuration: ExactMediaTime? { duration }
    var remuxContainsVCL: Bool { containsVCL }
    var remuxContainsInBandParameterSets: Bool { containsInBandParameterSets }
    var remuxAllVCLAreRandomAccess: Bool { allVCLNALUnitsAreRandomAccess }
    var remuxConflictingRandomAccessKinds: Bool { conflictingRandomAccessKinds }
    var remuxHasSinglePrimaryPictureStartSlice: Bool { hasPrimaryPictureStartSlice }
}
