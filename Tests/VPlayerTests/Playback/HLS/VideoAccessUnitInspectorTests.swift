// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class VideoAccessUnitInspectorTests: XCTestCase {
    func testGenerationSessionFreezesInitialCatalogAndReusesItWithoutInBandParameters() throws {
        let generation = MediaGeneration(rawValue: 21)
        var session = VideoAccessUnitInspectionSession(generation: generation, codec: .h264)
        let first = try session.inspect(inspectionInput(
            annexB(h264ParameterSets() + [h264HDRSEI(), h264Slice(nalType: 5)]),
            generation: generation,
            accessUnitID: 1,
            codec: .h264
        ))
        let withoutParameters = try session.inspect(inspectionInput(
            annexB([h264Slice(nalType: 1)]),
            generation: generation,
            accessUnitID: 2,
            codec: .h264
        ))

        XCTAssertEqual(withoutParameters.parameterSets, first.parameterSets)
        XCTAssertEqual(withoutParameters.format, first.format)
        XCTAssertEqual(withoutParameters.formatIdentity, first.formatIdentity)
        XCTAssertFalse(withoutParameters.containsInBandParameterSets)
    }

    func testHEVCGenerationSessionReusesFrozenVPSAndHDRWithoutInBandParameters() throws {
        let generation = MediaGeneration(rawValue: 25)
        var session = VideoAccessUnitInspectionSession(generation: generation, codec: .hevc)
        let first = try session.inspect(inspectionInput(
            annexB(hevcParameterSets() + [hevcHDRSEI(), hevcSlice(nalType: 19)]),
            generation: generation,
            accessUnitID: 1,
            codec: .hevc
        ))
        let withoutParameters = try session.inspect(inspectionInput(
            annexB([hevcSlice(nalType: 21)]),
            generation: generation,
            accessUnitID: 2,
            codec: .hevc
        ))

        XCTAssertEqual(withoutParameters.parameterSets.vpsID, 0)
        XCTAssertEqual(withoutParameters.parameterSets, first.parameterSets)
        XCTAssertEqual(withoutParameters.format, first.format)
        XCTAssertEqual(withoutParameters.formatIdentity, first.formatIdentity)
        XCTAssertFalse(withoutParameters.containsInBandParameterSets)
    }

    func testCurrentPartialParameterChangeWinsWithoutMutatingFrozenCatalog() throws {
        let generation = MediaGeneration(rawValue: 22)
        var session = VideoAccessUnitInspectionSession(generation: generation, codec: .h264)
        let frozen = try session.inspect(inspectionInput(
            annexB(h264ParameterSets(levelIDC: 40) + [h264Slice(nalType: 5)]),
            generation: generation,
            accessUnitID: 1,
            codec: .h264
        ))
        let changedSPS = try session.inspect(inspectionInput(
            annexB([h264SPS(levelIDC: 41), h264Slice(nalType: 5)]),
            generation: generation,
            accessUnitID: 2,
            codec: .h264
        ))
        let changedPPS = try session.inspect(inspectionInput(
            annexB([h264PPS(extraSyntaxBit: true), h264Slice(nalType: 5)]),
            generation: generation,
            accessUnitID: 3,
            codec: .h264
        ))
        let catalogStillFrozen = try session.inspect(inspectionInput(
            annexB([h264Slice(nalType: 1)]),
            generation: generation,
            accessUnitID: 4,
            codec: .h264
        ))

        XCTAssertNotEqual(changedSPS.parameterSets.spsSHA256, frozen.parameterSets.spsSHA256)
        XCTAssertEqual(changedSPS.parameterSets.ppsSHA256, frozen.parameterSets.ppsSHA256)
        XCTAssertNotEqual(changedSPS.formatIdentity, frozen.formatIdentity)
        XCTAssertEqual(changedPPS.parameterSets.spsSHA256, frozen.parameterSets.spsSHA256)
        XCTAssertNotEqual(changedPPS.parameterSets.ppsSHA256, frozen.parameterSets.ppsSHA256)
        XCTAssertNotEqual(changedPPS.formatIdentity, frozen.formatIdentity)
        XCTAssertEqual(catalogStillFrozen.parameterSets, frozen.parameterSets)
        XCTAssertEqual(catalogStillFrozen.formatIdentity, frozen.formatIdentity)
    }

    func testGenerationSessionRejectsMissingInitialAndExtraInactiveParameterSets() throws {
        let generation = MediaGeneration(rawValue: 23)
        var missing = VideoAccessUnitInspectionSession(generation: generation, codec: .h264)
        XCTAssertThrowsError(try missing.inspect(inspectionInput(
            annexB([h264Slice(nalType: 5)]),
            generation: generation,
            accessUnitID: 1,
            codec: .h264
        ))) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .missingInitialParameterCatalog)
        }

        var extra = VideoAccessUnitInspectionSession(generation: generation, codec: .h264)
        XCTAssertThrowsError(try extra.inspect(inspectionInput(
            annexB([
                h264SPS(id: 0),
                h264SPS(id: 1),
                h264PPS(id: 0, spsID: 0),
                h264Slice(nalType: 5, ppsID: 0),
            ]),
            generation: generation,
            accessUnitID: 2,
            codec: .h264
        ))) { error in
            XCTAssertEqual(
                error as? VideoAccessUnitInspectionError,
                .inactiveParameterSet(kind: .sequence, id: 1)
            )
        }
    }

    func testSessionInheritsMissingSEIAndChangesFormatIdentityForExplicitSEIDrift() throws {
        let generation = MediaGeneration(rawValue: 24)
        var session = VideoAccessUnitInspectionSession(generation: generation, codec: .h264)
        let frozen = try session.inspect(inspectionInput(
            annexB(h264ParameterSets() + [h264HDRSEI(), h264Slice(nalType: 5)]),
            generation: generation,
            accessUnitID: 1,
            codec: .h264
        ))
        let inherited = try session.inspect(inspectionInput(
            annexB([h264Slice(nalType: 1)]),
            generation: generation,
            accessUnitID: 2,
            codec: .h264
        ))
        let explicitDrift = try session.inspect(inspectionInput(
            annexB([h264HDRSEI(maximumContentLightLevel: 2_000), h264Slice(nalType: 1)]),
            generation: generation,
            accessUnitID: 3,
            codec: .h264
        ))

        XCTAssertEqual(inherited.format.masteringDisplay, frozen.format.masteringDisplay)
        XCTAssertEqual(inherited.format.contentLightLevel, frozen.format.contentLightLevel)
        XCTAssertEqual(inherited.formatIdentity, frozen.formatIdentity)
        XCTAssertEqual(explicitDrift.parameterSets, frozen.parameterSets)
        XCTAssertNotEqual(explicitDrift.format.contentLightLevel, frozen.format.contentLightLevel)
        XCTAssertNotEqual(explicitDrift.formatIdentity, frozen.formatIdentity)
    }

    func testProofBindsGenerationAccessUnitBackingRangeAndDigest() throws {
        let bytes = annexB(h264ParameterSets() + [h264Slice(nalType: 5)])
        let identity = VideoAccessUnitBackingIdentity(
            generation: MediaGeneration(rawValue: 7),
            accessUnitID: 41
        )
        let backing = try VideoAccessUnitBacking(identity: identity, bytes: bytes)
        let range = try XCTUnwrap(VideoAccessUnitByteRange(offset: 0, length: bytes.count))

        let proof = try VideoAccessUnitInspector.inspect(.init(
            backing: backing,
            byteRange: range,
            sourceSHA256: backing.sha256,
            codec: .h264,
            scanClassification: .progressive,
            presentationTimeStamp: ExactMediaTime(value: 3_003, timescale: 90_000),
            decodeTimeStamp: ExactMediaTime(value: 0, timescale: 90_000),
            duration: ExactMediaTime(value: 3_003, timescale: 90_000)
        ))

        XCTAssertEqual(proof.identity.generation, MediaGeneration(rawValue: 7))
        XCTAssertEqual(proof.identity.accessUnitID, 41)
        XCTAssertEqual(proof.identity.backingIdentity, identity)
        XCTAssertEqual(proof.identity.byteRange, range)
        XCTAssertEqual(proof.identity.sourceSHA256, backing.sha256)
        XCTAssertEqual(proof.presentationTimeStamp, ExactMediaTime(value: 1_001, timescale: 30_000))
        XCTAssertEqual(proof.decodeTimeStamp, ExactMediaTime(value: 0, timescale: 1))
        XCTAssertEqual(proof.duration, ExactMediaTime(value: 1_001, timescale: 30_000))

        var changed = bytes
        changed[changed.index(before: changed.endIndex)] ^= 0x01
        let substituted = try VideoAccessUnitBacking(identity: identity, bytes: changed)
        XCTAssertThrowsError(try VideoAccessUnitInspector.inspect(.init(
            backing: substituted,
            byteRange: range,
            sourceSHA256: backing.sha256,
            codec: .h264,
            scanClassification: .progressive
        ))) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .sourceDigestMismatch)
        }
    }

    func testProofRejectsNewOwnerWithSameLogicalIdentityRangeDigestAndBytes() throws {
        let bytes = annexB(h264ParameterSets() + [h264Slice(nalType: 5)])
        let logicalIdentity = VideoAccessUnitBackingIdentity(
            generation: MediaGeneration(rawValue: 11),
            accessUnitID: 29
        )
        let range = try XCTUnwrap(VideoAccessUnitByteRange(offset: 0, length: bytes.count))
        weak var releasedOriginal: VideoAccessUnitBacking?
        weak var retainedOwnerIdentity: VideoAccessUnitBackingOwnerIdentity?
        let originalProof = try { () throws -> VideoAccessUnitInspectionProof in
            let original = try VideoAccessUnitBacking(identity: logicalIdentity, bytes: bytes)
            releasedOriginal = original
            retainedOwnerIdentity = original.ownerIdentity
            let proof = try VideoAccessUnitInspector.inspect(.init(
                backing: original,
                byteRange: range,
                sourceSHA256: original.sha256,
                codec: .h264,
                scanClassification: .progressive
            ))
            XCTAssertTrue(proof.identity.matches(
                backing: original,
                byteRange: range,
                sourceSHA256: original.sha256
            ))
            return proof
        }()
        XCTAssertNil(releasedOriginal, "proof 不应复制或保留整个 backing")
        XCTAssertNotNil(retainedOwnerIdentity, "proof 必须强持有 owner identity，阻止地址复用")

        let replacement = try VideoAccessUnitBacking(identity: logicalIdentity, bytes: bytes)
        XCTAssertFalse(originalProof.identity.matches(
            backing: replacement,
            byteRange: range,
            sourceSHA256: replacement.sha256
        ), "内容与逻辑身份相同的新 owner 不能取得旧 proof 权限")

        let replacementProof = try VideoAccessUnitInspector.inspect(.init(
            backing: replacement,
            byteRange: range,
            sourceSHA256: replacement.sha256,
            codec: .h264,
            scanClassification: .progressive
        ))
        XCTAssertNotEqual(originalProof.identity, replacementProof.identity)
        XCTAssertTrue(replacementProof.identity.matches(
            backing: replacement,
            byteRange: range,
            sourceSHA256: replacement.sha256
        ))
    }

    func testH264ParsesActiveParameterSetsVUITimingAndHDRSEI() throws {
        let bytes = annexB(h264ParameterSets() + [h264HDRSEI(), h264Slice(nalType: 5)])
        let proof = try inspect(bytes, codec: .h264, expectedFormat: h264Descriptor())

        XCTAssertEqual(proof.randomAccessKind, .h264IDR)
        XCTAssertTrue(proof.containsVCL)
        XCTAssertTrue(proof.containsInBandParameterSets)
        XCTAssertEqual(proof.vclNALUnitCount, 1)
        XCTAssertEqual(proof.randomAccessNALUnitCount, 1)
        XCTAssertTrue(proof.allVCLNALUnitsAreRandomAccess)
        XCTAssertTrue(proof.hasPrimaryPictureStartSlice)
        XCTAssertEqual(proof.parameterSets.spsID, 0)
        XCTAssertEqual(proof.parameterSets.ppsID, 0)
        XCTAssertNil(proof.parameterSets.vpsID)
        XCTAssertEqual(proof.format.profileIDC, 100)
        XCTAssertEqual(proof.format.levelIDC, 40)
        XCTAssertEqual(proof.format.tier, .main)
        XCTAssertEqual(proof.format.chromaFormatIDC, 1)
        XCTAssertEqual(proof.format.bitDepthLuma, 8)
        XCTAssertEqual(proof.format.bitDepthChroma, 8)
        XCTAssertEqual(proof.format.width, 1_920)
        XCTAssertEqual(proof.format.height, 1_080)
        XCTAssertEqual(proof.format.codedPictureMacroblockCount, 8_160)
        XCTAssertNil(proof.format.codedPictureLumaSampleCount)
        XCTAssertEqual(proof.format.maximumReferenceFrames, 4)
        XCTAssertEqual(proof.format.sampleAspectRatio, MediaRational(num: 1, den: 1))
        XCTAssertEqual(proof.format.frameRate, MediaRational(num: 30_000, den: 1_001))
        XCTAssertEqual(proof.format.range, .limited)
        XCTAssertEqual(proof.format.primaries, .bt2020)
        XCTAssertEqual(proof.format.transfer, .pq)
        XCTAssertEqual(proof.format.matrix, .bt2020Nonconstant)
        XCTAssertEqual(proof.format.chromaLocation, .left)
        XCTAssertEqual(proof.format.masteringDisplay, expectedMasteringDisplay())
        XCTAssertEqual(
            proof.format.contentLightLevel,
            DemuxContentLightLevelMetadata(
                maximumContentLightLevel: 1_000,
                maximumFrameAverageLightLevel: 400
            )
        )
    }

    func testSequenceProofDistinguishesDefaultExplicitAndUnsupportedChromaLocation() throws {
        let omitted = try VideoSequenceParameterSetInspector.inspectH264(
            [UInt8](h264SPS(chromaLocationType: nil)))
        XCTAssertFalse(omitted.chromaLocationWasPresent)
        XCTAssertEqual(omitted.effectiveChromaLocation, .left)
        XCTAssertEqual(omitted.range, .limited)

        let explicitCenter = try VideoSequenceParameterSetInspector.inspectH264(
            [UInt8](h264SPS(chromaLocationType: 1)))
        XCTAssertTrue(explicitCenter.chromaLocationWasPresent)
        XCTAssertEqual(explicitCenter.effectiveChromaLocation, .center)

        let unsupported = try VideoSequenceParameterSetInspector.inspectH264(
            [UInt8](h264SPS(chromaLocationType: 3)))
        XCTAssertTrue(unsupported.chromaLocationWasPresent)
        XCTAssertNil(unsupported.effectiveChromaLocation)
    }

    func testHEVCProvesIDRAndCRAFromEveryVCLNALAndParsesProfileTierLevel() throws {
        let parameters = hevcParameterSets()
        let idr = try inspect(
            annexB(parameters + [hevcHDRSEI(), hevcSlice(nalType: 19)]),
            codec: .hevc
        )
        XCTAssertEqual(idr.randomAccessKind, .hevcIDR)
        XCTAssertEqual(idr.vclNALUnitCount, 1)
        XCTAssertEqual(idr.randomAccessNALUnitCount, 1)
        XCTAssertTrue(idr.allVCLNALUnitsAreRandomAccess)
        XCTAssertTrue(idr.hasPrimaryPictureStartSlice)
        XCTAssertEqual(idr.parameterSets.vpsID, 0)
        XCTAssertEqual(idr.parameterSets.spsID, 0)
        XCTAssertEqual(idr.parameterSets.ppsID, 0)
        XCTAssertEqual(idr.format.profileIDC, 2)
        XCTAssertEqual(idr.format.levelIDC, 153)
        XCTAssertEqual(idr.format.tier, .main)
        XCTAssertEqual(idr.format.bitDepthLuma, 10)
        XCTAssertEqual(idr.format.bitDepthChroma, 10)
        XCTAssertEqual(idr.format.width, 3_840)
        XCTAssertEqual(idr.format.height, 2_160)
        XCTAssertNil(idr.format.codedPictureMacroblockCount)
        XCTAssertEqual(idr.format.codedPictureLumaSampleCount, 8_294_400)
        XCTAssertEqual(idr.format.maximumReferenceFrames, 5)
        XCTAssertEqual(idr.format.frameRate, MediaRational(num: 60_000, den: 1_001))
        XCTAssertEqual(idr.format.masteringDisplay, expectedMasteringDisplay())
        XCTAssertEqual(
            idr.format.contentLightLevel,
            DemuxContentLightLevelMetadata(
                maximumContentLightLevel: 1_000,
                maximumFrameAverageLightLevel: 400
            )
        )

        let cra = try inspect(annexB(parameters + [hevcSlice(nalType: 21)]), codec: .hevc)
        XCTAssertEqual(cra.randomAccessKind, .hevcCRA)
        XCTAssertTrue(cra.allVCLNALUnitsAreRandomAccess)

        let mixed = try inspect(
            annexB(parameters + [
                hevcSlice(nalType: 19),
                hevcSlice(nalType: 1, firstSliceSegmentInPicture: false),
            ]),
            codec: .hevc
        )
        XCTAssertEqual(mixed.randomAccessKind, .hevcIDR)
        XCTAssertEqual(mixed.vclNALUnitCount, 2)
        XCTAssertEqual(mixed.randomAccessNALUnitCount, 1)
        XCTAssertFalse(mixed.allVCLNALUnitsAreRandomAccess)
        XCTAssertFalse(mixed.conflictingRandomAccessKinds)

        let conflicting = try inspect(
            annexB(parameters + [
                hevcSlice(nalType: 19),
                hevcSlice(nalType: 21, firstSliceSegmentInPicture: false),
            ]),
            codec: .hevc
        )
        XCTAssertEqual(conflicting.randomAccessKind, .hevcIDR)
        XCTAssertTrue(conflicting.allVCLNALUnitsAreRandomAccess)
        XCTAssertTrue(conflicting.conflictingRandomAccessKinds)
    }

    func testHEVCSequenceProofPreservesMissingExplicitAndUnsupportedChromaFacts() throws {
        let fixtures: [(UInt32?, DemuxChromaLocation?, Bool)] = [
            (nil, .left, false),
            (1, .center, true),
            (3, nil, true),
        ]
        for (syntaxValue, effective, present) in fixtures {
            let proof = try VideoSequenceParameterSetInspector.inspectHEVC(
                [UInt8](hevcSPS(chromaLocationType: syntaxValue)))
            XCTAssertEqual(proof.effectiveChromaLocation, effective)
            XCTAssertEqual(proof.chromaLocationWasPresent, present)
        }
    }

    func testFirstVCLMustBePrimaryPictureStartForH264AndHEVC() throws {
        let h264Cases = [
            [h264Slice(nalType: 5, firstMBInSlice: 3)],
            [
                h264Slice(nalType: 5, firstMBInSlice: 3),
                h264Slice(nalType: 5),
            ],
        ]
        for slices in h264Cases {
            XCTAssertThrowsError(try inspect(
                annexB(h264ParameterSets() + slices),
                codec: .h264
            )) { error in
                XCTAssertEqual(
                    error as? VideoAccessUnitInspectionError,
                    .continuationBeforePrimaryPictureStart
                )
            }
        }

        let hevcCases = [
            [hevcSlice(nalType: 21, firstSliceSegmentInPicture: false)],
            [
                hevcSlice(nalType: 19, firstSliceSegmentInPicture: false),
                hevcSlice(nalType: 19),
            ],
        ]
        for slices in hevcCases {
            XCTAssertThrowsError(try inspect(
                annexB(hevcParameterSets() + slices),
                codec: .hevc
            )) { error in
                XCTAssertEqual(
                    error as? VideoAccessUnitInspectionError,
                    .continuationBeforePrimaryPictureStart
                )
            }
        }
    }

    func testRejectsMultiplePrimaryPictureStartsInOneAccessUnit() throws {
        let h264 = annexB(h264ParameterSets() + [
            h264Slice(nalType: 5),
            h264Slice(nalType: 5),
        ])
        XCTAssertThrowsError(try inspect(h264, codec: .h264)) { error in
            XCTAssertEqual(
                error as? VideoAccessUnitInspectionError,
                .conflictingPrimaryPictureStartSlices
            )
        }

        let hevc = annexB(hevcParameterSets() + [
            hevcSlice(nalType: 19),
            hevcSlice(nalType: 19),
        ])
        XCTAssertThrowsError(try inspect(hevc, codec: .hevc)) { error in
            XCTAssertEqual(
                error as? VideoAccessUnitInspectionError,
                .conflictingPrimaryPictureStartSlices
            )
        }
    }

    func testUnsupportedH264VCLKindsCannotDisappearFromAllVCLEvidence() throws {
        for type in [UInt8(3), 4, 19, 20, 21] {
            let bytes = annexB(h264ParameterSets() + [
                h264Slice(nalType: 5),
                makeH264NAL(header: 0x60 | type, rbsp: Data([0x80])),
            ])
            XCTAssertThrowsError(try inspect(bytes, codec: .h264), "NAL type \(type)") {
                XCTAssertEqual(
                    $0 as? VideoAccessUnitInspectionError,
                    .unsupportedH264VCLNALUnitType(type)
                )
            }
        }
    }

    func testTruncatedParameterSetsReturnTypedErrors() throws {
        let cases: [(Data, VideoCodec)] = [
            (annexB([makeH264NAL(header: 0x68, rbsp: Data([0x80]))]), .h264),
            (annexB([makeHEVCNAL(type: 32, rbsp: Data([0x00]))]), .hevc),
            (annexB([makeHEVCNAL(type: 34, rbsp: Data([0xC0]))]), .hevc),
        ]
        for (bytes, codec) in cases {
            XCTAssertThrowsError(try inspect(bytes, codec: codec)) { error in
                XCTAssertEqual(error as? VideoAccessUnitInspectionError, .truncatedRBSP)
            }
        }
    }

    func testH264ConstraintFlagsAreParsedExposedAndBoundIntoFormatIdentity() throws {
        let baseline = try inspect(
            annexB(h264ParameterSets(compatibilityFlags: 0) + [h264Slice(nalType: 5)]),
            codec: .h264
        )
        let constrained = try inspect(
            annexB(h264ParameterSets(compatibilityFlags: 0x10) + [h264Slice(nalType: 5)]),
            codec: .h264
        )

        XCTAssertEqual(baseline.format.profileCompatibilityFlags, 0)
        XCTAssertEqual(constrained.format.profileCompatibilityFlags, 0x10)
        XCTAssertEqual(constrained.remuxProfileCompatibilityFlags, 0x10)
        XCTAssertNotEqual(constrained.formatIdentity, baseline.formatIdentity)
    }

    func testExplicitUnsupportedVUIColorEnumsCannotUseFrozenFallback() throws {
        let h264Generation = MediaGeneration(rawValue: 26)
        var h264Session = VideoAccessUnitInspectionSession(
            generation: h264Generation,
            codec: .h264
        )
        _ = try h264Session.inspect(inspectionInput(
            annexB(h264ParameterSets() + [h264Slice(nalType: 5)]),
            generation: h264Generation,
            accessUnitID: 1,
            codec: .h264
        ))
        let h264Cases: [(Data, VideoAccessUnitInspectionError)] = [
            (h264SPS(colorPrimaries: 2), .unsupportedColorPrimaries(2)),
            (h264SPS(colorTransfer: 2), .unsupportedColorTransfer(2)),
            (h264SPS(colorMatrix: 2), .unsupportedColorMatrix(2)),
        ]
        for (index, fixture) in h264Cases.enumerated() {
            XCTAssertThrowsError(try h264Session.inspect(inspectionInput(
                annexB([fixture.0, h264Slice(nalType: 5)]),
                generation: h264Generation,
                accessUnitID: UInt64(index + 2),
                codec: .h264
            ))) { error in
                XCTAssertEqual(error as? VideoAccessUnitInspectionError, fixture.1)
            }
        }

        let hevcGeneration = MediaGeneration(rawValue: 27)
        var hevcSession = VideoAccessUnitInspectionSession(
            generation: hevcGeneration,
            codec: .hevc
        )
        _ = try hevcSession.inspect(inspectionInput(
            annexB(hevcParameterSets() + [hevcSlice(nalType: 19)]),
            generation: hevcGeneration,
            accessUnitID: 1,
            codec: .hevc
        ))
        let hevcCases: [(Data, VideoAccessUnitInspectionError)] = [
            (hevcSPS(colorPrimaries: 2), .unsupportedColorPrimaries(2)),
            (hevcSPS(colorTransfer: 2), .unsupportedColorTransfer(2)),
            (hevcSPS(colorMatrix: 2), .unsupportedColorMatrix(2)),
        ]
        for (index, fixture) in hevcCases.enumerated() {
            XCTAssertThrowsError(try hevcSession.inspect(inspectionInput(
                annexB([fixture.0, hevcSlice(nalType: 19)]),
                generation: hevcGeneration,
                accessUnitID: UInt64(index + 2),
                codec: .hevc
            ))) { error in
                XCTAssertEqual(error as? VideoAccessUnitInspectionError, fixture.1)
            }
        }
    }

    func testBT2020ColorTransferSupportedInHEVC() throws {
        let generation = MediaGeneration(rawValue: 28)
        var session = VideoAccessUnitInspectionSession(
            generation: generation,
            codec: .hevc
        )
        let proof = try session.inspect(inspectionInput(
            annexB([hevcVPS(), hevcSPS(colorPrimaries: 9, colorTransfer: 14, colorMatrix: 9), hevcPPS(), hevcSlice(nalType: 19)]),
            generation: generation,
            accessUnitID: 1,
            codec: .hevc
        ))
        XCTAssertEqual(proof.format.primaries, .bt2020)
        XCTAssertEqual(proof.format.transfer, .bt2020)
        XCTAssertEqual(proof.format.matrix, .bt2020Nonconstant)
    }

    func testTruncatedFirstSliceHeadersReturnTypedError() throws {
        let truncatedH264 = annexB(h264ParameterSets() + [Data([0x65, 0x00, 0x80])])
        XCTAssertThrowsError(try inspect(truncatedH264, codec: .h264)) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .truncatedRBSP)
        }

        let truncatedHEVC = annexB(hevcParameterSets() + [Data([38, 1, 0x80])])
        XCTAssertThrowsError(try inspect(truncatedHEVC, codec: .hevc)) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .truncatedRBSP)
        }
    }

    func testActiveParameterSetIdentityChangesOnInBandDrift() throws {
        let first = try inspect(
            annexB(h264ParameterSets(levelIDC: 40) + [h264Slice(nalType: 5)]),
            codec: .h264
        )
        let changed = try inspect(
            annexB(h264ParameterSets(levelIDC: 41) + [h264Slice(nalType: 5)]),
            codec: .h264
        )

        XCTAssertNotEqual(first.parameterSets.spsSHA256, changed.parameterSets.spsSHA256)
        XCTAssertNotEqual(first.parameterSets.combinedSHA256, changed.parameterSets.combinedSHA256)
        XCTAssertEqual(first.parameterSets.ppsSHA256, changed.parameterSets.ppsSHA256)
    }

    func testRejectsMissingReferencesConflictsMalformedRBSPAndMetadataMismatch() throws {
        let missingPPS = annexB([h264SPS(), h264Slice(nalType: 5)])
        XCTAssertThrowsError(try inspect(missingPPS, codec: .h264)) { error in
            XCTAssertEqual(
                error as? VideoAccessUnitInspectionError,
                .missingParameterReference(kind: .picture, id: 0)
            )
        }

        let conflict = annexB([
            h264SPS(levelIDC: 40),
            h264SPS(levelIDC: 41),
            h264PPS(),
            h264Slice(nalType: 5),
        ])
        XCTAssertThrowsError(try inspect(conflict, codec: .h264)) { error in
            XCTAssertEqual(
                error as? VideoAccessUnitInspectionError,
                .conflictingParameterSet(kind: .sequence, id: 0)
            )
        }

        let overflowingUE = annexB([
            makeH264NAL(header: 0x68, rbsp: Data([0, 0, 0, 0, 0, 0x80])),
        ])
        XCTAssertThrowsError(try inspect(overflowingUE, codec: .h264)) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .expGolombOverflow)
        }

        var mismatched = h264Descriptor()
        mismatched = VideoTrackDescriptor(
            streamIndex: mismatched.streamIndex,
            codec: mismatched.codec,
            timeBase: mismatched.timeBase,
            width: 1_280,
            height: mismatched.height,
            videoDelay: mismatched.videoDelay,
            extradata: mismatched.extradata,
            frameRate: mismatched.frameRate,
            fieldOrder: mismatched.fieldOrder,
            metadata: mismatched.metadata,
            videoMetadata: mismatched.videoMetadata
        )
        let valid = annexB(h264ParameterSets() + [h264Slice(nalType: 5)])
        XCTAssertThrowsError(try inspect(valid, codec: .h264, expectedFormat: mismatched)) { error in
            XCTAssertEqual(
                error as? VideoAccessUnitInspectionError,
                .metadataMismatch(.dimensions)
            )
        }
    }

    func testMalformedSEIRPSAndReservedSublayerReturnTypedErrorsInsteadOfTrapping() throws {
        let truncatedSEI = annexB(
            h264ParameterSets() + [h264TruncatedMasteringSEI(), h264Slice(nalType: 5)]
        )
        XCTAssertThrowsError(try inspect(truncatedSEI, codec: .h264)) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .truncatedRBSP)
        }

        let reservedSubLayer = annexB([hevcVPS(), hevcReservedSubLayerSPS()])
        XCTAssertThrowsError(try inspect(reservedSubLayer, codec: .hevc)) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .unsupportedSyntax)
        }

        let truncatedPredictedRPS = annexB([
            hevcVPS(),
            hevcSPS(rpsMode: .truncatedPrediction),
        ])
        XCTAssertThrowsError(try inspect(truncatedPredictedRPS, codec: .hevc)) { error in
            XCTAssertEqual(error as? VideoAccessUnitInspectionError, .truncatedRBSP)
        }
    }

    private func inspect(
        _ bytes: Data,
        codec: VideoCodec,
        expectedFormat: VideoTrackDescriptor? = nil
    ) throws -> VideoAccessUnitInspectionProof {
        let backing = try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: MediaGeneration(rawValue: 3),
                accessUnitID: 19
            ),
            bytes: bytes
        )
        return try VideoAccessUnitInspector.inspect(.init(
            backing: backing,
            byteRange: try XCTUnwrap(VideoAccessUnitByteRange(offset: 0, length: bytes.count)),
            sourceSHA256: backing.sha256,
            codec: codec,
            scanClassification: .progressive,
            presentationTimeStamp: ExactMediaTime(value: 10, timescale: 1),
            decodeTimeStamp: ExactMediaTime(value: 9, timescale: 1),
            duration: ExactMediaTime(value: 1, timescale: 30),
            expectedFormat: expectedFormat
        ))
    }

    private func inspectionInput(
        _ bytes: Data,
        generation: MediaGeneration,
        accessUnitID: UInt64,
        codec: VideoCodec
    ) throws -> VideoAccessUnitInspectionInput {
        let backing = try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: generation,
                accessUnitID: accessUnitID
            ),
            bytes: bytes
        )
        return VideoAccessUnitInspectionInput(
            backing: backing,
            byteRange: try XCTUnwrap(VideoAccessUnitByteRange(offset: 0, length: bytes.count)),
            sourceSHA256: backing.sha256,
            codec: codec,
            scanClassification: .progressive,
            presentationTimeStamp: ExactMediaTime(value: Int64(accessUnitID), timescale: 30),
            decodeTimeStamp: ExactMediaTime(value: Int64(accessUnitID), timescale: 30),
            duration: ExactMediaTime(value: 1, timescale: 30)
        )
    }
}

private func h264Descriptor() -> VideoTrackDescriptor {
    VideoTrackDescriptor(
        streamIndex: 0,
        codec: .h264,
        timeBase: MediaRational(num: 1, den: 90_000)!,
        width: 1_920,
        height: 1_080,
        videoDelay: 1,
        extradata: Data(),
        frameRate: MediaRational(num: 30_000, den: 1_001),
        fieldOrder: .progressive,
        videoMetadata: DemuxVideoMetadata(
            sampleAspectRatio: MediaRational(num: 1, den: 1),
            range: .limited,
            primaries: .bt2020,
            transfer: .pq,
            matrix: .bt2020Nonconstant,
            chromaLocation: .left,
            masteringDisplay: expectedMasteringDisplay(),
            contentLightLevel: DemuxContentLightLevelMetadata(
                maximumContentLightLevel: 1_000,
                maximumFrameAverageLightLevel: 400
            )
        )
    )
}

private func expectedMasteringDisplay() -> DemuxMasteringDisplayMetadata {
    DemuxMasteringDisplayMetadata(
        redX: DemuxHDRRational(num: 35_400, den: 50_000)!,
        redY: DemuxHDRRational(num: 14_600, den: 50_000)!,
        greenX: DemuxHDRRational(num: 8_500, den: 50_000)!,
        greenY: DemuxHDRRational(num: 39_850, den: 50_000)!,
        blueX: DemuxHDRRational(num: 6_550, den: 50_000)!,
        blueY: DemuxHDRRational(num: 2_300, den: 50_000)!,
        whitePointX: DemuxHDRRational(num: 15_635, den: 50_000)!,
        whitePointY: DemuxHDRRational(num: 16_450, den: 50_000)!,
        minimumLuminance: DemuxHDRRational(num: 50, den: 10_000)!,
        maximumLuminance: DemuxHDRRational(num: 10_000_000, den: 10_000)!
    )!
}

private func h264ParameterSets(
    levelIDC: UInt8 = 40,
    compatibilityFlags: UInt8 = 0
) -> [Data] {
    [
        h264SPS(levelIDC: levelIDC, compatibilityFlags: compatibilityFlags),
        h264PPS(),
    ]
}

private func h264SPS(
    levelIDC: UInt8 = 40,
    id: UInt32 = 0,
    compatibilityFlags: UInt8 = 0,
    colorPrimaries: UInt8 = 9,
    colorTransfer: UInt8 = 16,
    colorMatrix: UInt8 = 9,
    chromaLocationType: UInt32? = 0
) -> Data {
    var bits = TestBitWriter()
    bits.write(100, count: 8) // profile_idc
    bits.write(UInt64(compatibilityFlags), count: 8) // constraint flags
    bits.write(UInt64(levelIDC), count: 8)
    bits.writeUE(id) // seq_parameter_set_id
    bits.writeUE(1) // 4:2:0
    bits.writeUE(0) // bit_depth_luma_minus8
    bits.writeUE(0) // bit_depth_chroma_minus8
    bits.write(0, count: 1) // qpprime_y_zero_transform_bypass_flag
    bits.write(0, count: 1) // seq_scaling_matrix_present_flag
    bits.writeUE(0) // log2_max_frame_num_minus4
    bits.writeUE(0) // pic_order_cnt_type
    bits.writeUE(0) // log2_max_pic_order_cnt_lsb_minus4
    bits.writeUE(4) // max_num_ref_frames
    bits.write(0, count: 1) // gaps_in_frame_num_value_allowed_flag
    bits.writeUE(119) // 120 宏块宽
    bits.writeUE(67) // 68 宏块高，裁剪至 1080
    bits.write(1, count: 1) // frame_mbs_only_flag
    bits.write(1, count: 1) // direct_8x8_inference_flag
    bits.write(1, count: 1) // frame_cropping_flag
    bits.writeUE(0)
    bits.writeUE(0)
    bits.writeUE(0)
    bits.writeUE(4)
    bits.write(1, count: 1) // vui_parameters_present_flag
    writeH264VUI(
        &bits,
        colorPrimaries: colorPrimaries,
        colorTransfer: colorTransfer,
        colorMatrix: colorMatrix,
        chromaLocationType: chromaLocationType
    )
    return makeH264NAL(header: 0x67, rbsp: bits.finishRBSP())
}

private func h264PPS(
    id: UInt32 = 0,
    spsID: UInt32 = 0,
    extraSyntaxBit: Bool = false
) -> Data {
    var bits = TestBitWriter()
    bits.writeUE(id)
    bits.writeUE(spsID)
    bits.write(0, count: 1) // entropy_coding_mode_flag
    bits.write(0, count: 1) // bottom_field_pic_order_in_frame_present_flag
    bits.writeUE(0) // num_slice_groups_minus1
    bits.writeUE(0) // num_ref_idx_l0_default_active_minus1
    bits.writeUE(0) // num_ref_idx_l1_default_active_minus1
    bits.write(0, count: 1) // weighted_pred_flag
    bits.write(0, count: 2) // weighted_bipred_idc
    bits.writeSE(0) // pic_init_qp_minus26
    bits.writeSE(0) // pic_init_qs_minus26
    bits.writeSE(0) // chroma_qp_index_offset
    bits.write(1, count: 1) // deblocking_filter_control_present_flag
    bits.write(extraSyntaxBit ? 1 : 0, count: 1) // constrained_intra_pred_flag
    bits.write(0, count: 1) // redundant_pic_cnt_present_flag
    return makeH264NAL(header: 0x68, rbsp: bits.finishRBSP())
}

private func h264Slice(
    nalType: UInt8,
    ppsID: UInt32 = 0,
    firstMBInSlice: UInt32 = 0
) -> Data {
    var bits = TestBitWriter()
    bits.writeUE(firstMBInSlice)
    bits.writeUE(nalType == 5 ? 2 : 0) // I/P
    bits.writeUE(ppsID) // pic_parameter_set_id
    return makeH264NAL(header: 0x60 | nalType, rbsp: bits.finishRBSP())
}

private func writeH264VUI(
    _ bits: inout TestBitWriter,
    colorPrimaries: UInt8,
    colorTransfer: UInt8,
    colorMatrix: UInt8,
    chromaLocationType: UInt32?
) {
    bits.write(1, count: 1) // aspect_ratio_info_present_flag
    bits.write(1, count: 8) // 1:1
    bits.write(0, count: 1) // overscan_info_present_flag
    bits.write(1, count: 1) // video_signal_type_present_flag
    bits.write(5, count: 3)
    bits.write(0, count: 1) // limited
    bits.write(1, count: 1) // colour_description_present_flag
    bits.write(UInt64(colorPrimaries), count: 8)
    bits.write(UInt64(colorTransfer), count: 8)
    bits.write(UInt64(colorMatrix), count: 8)
    bits.write(chromaLocationType == nil ? 0 : 1, count: 1)
    if let chromaLocationType {
        bits.writeUE(chromaLocationType)
        bits.writeUE(chromaLocationType)
    }
    bits.write(1, count: 1) // timing_info_present_flag
    bits.write(1_001, count: 32)
    bits.write(60_000, count: 32)
    bits.write(1, count: 1) // fixed_frame_rate_flag
    bits.write(0, count: 1) // nal_hrd_parameters_present_flag
    bits.write(0, count: 1) // vcl_hrd_parameters_present_flag
    bits.write(0, count: 1) // pic_struct_present_flag
    bits.write(0, count: 1) // bitstream_restriction_flag
}

private func h264HDRSEI(maximumContentLightLevel: UInt16 = 1_000) -> Data {
    makeH264NAL(
        header: 0x06,
        rbsp: hdrSEIRBSP(maximumContentLightLevel: maximumContentLightLevel)
    )
}

private func h264TruncatedMasteringSEI() -> Data {
    makeH264NAL(header: 0x06, rbsp: Data([137, 24, 1, 0x80]))
}

private func hevcHDRSEI(maximumContentLightLevel: UInt16 = 1_000) -> Data {
    makeHEVCNAL(
        type: 39,
        rbsp: hdrSEIRBSP(maximumContentLightLevel: maximumContentLightLevel)
    )
}

private func hdrSEIRBSP(maximumContentLightLevel: UInt16) -> Data {
    var rbsp = Data()
    rbsp.append(137)
    rbsp.append(24)
    // mastering_display_colour_volume 的原生顺序为 G、B、R。
    appendBigEndian(UInt16(8_500), to: &rbsp)
    appendBigEndian(UInt16(39_850), to: &rbsp)
    appendBigEndian(UInt16(6_550), to: &rbsp)
    appendBigEndian(UInt16(2_300), to: &rbsp)
    appendBigEndian(UInt16(35_400), to: &rbsp)
    appendBigEndian(UInt16(14_600), to: &rbsp)
    appendBigEndian(UInt16(15_635), to: &rbsp)
    appendBigEndian(UInt16(16_450), to: &rbsp)
    appendBigEndian(UInt32(10_000_000), to: &rbsp)
    appendBigEndian(UInt32(50), to: &rbsp)
    rbsp.append(144)
    rbsp.append(4)
    appendBigEndian(maximumContentLightLevel, to: &rbsp)
    appendBigEndian(UInt16(400), to: &rbsp)
    rbsp.append(0x80)
    return rbsp
}

private func hevcParameterSets() -> [Data] {
    [hevcVPS(), hevcSPS(), hevcPPS()]
}

private func hevcVPS() -> Data {
    var bits = TestBitWriter()
    bits.write(0, count: 4) // vps_video_parameter_set_id
    bits.write(1, count: 1) // vps_base_layer_internal_flag
    bits.write(1, count: 1) // vps_base_layer_available_flag
    bits.write(0, count: 6) // vps_max_layers_minus1
    bits.write(0, count: 3) // vps_max_sub_layers_minus1
    bits.write(1, count: 1) // vps_temporal_id_nesting_flag
    bits.write(0xFFFF, count: 16) // vps_reserved_0xffff_16bits
    bits.write(0, count: 2) // general_profile_space
    bits.write(0, count: 1) // general_tier_flag
    bits.write(2, count: 5) // general_profile_idc
    bits.write(0, count: 32) // general_profile_compatibility_flags
    bits.write(1, count: 1) // general_progressive_source_flag
    bits.write(0, count: 1) // general_interlaced_source_flag
    bits.write(0, count: 1) // general_non_packed_constraint_flag
    bits.write(1, count: 1) // general_frame_only_constraint_flag
    bits.write(0, count: 44) // general_reserved_zero_44bits
    bits.write(153, count: 8) // general_level_idc
    bits.write(0, count: 1) // vps_sub_layer_ordering_info_present_flag
    bits.writeUE(4) // vps_max_dec_pic_buffering_minus1
    bits.writeUE(0) // vps_max_num_reorder_pics
    bits.writeUE(0) // vps_max_latency_increase_plus1
    bits.write(0, count: 6) // vps_max_layer_id
    bits.writeUE(0) // vps_num_layer_sets_minus1
    bits.write(0, count: 1) // vps_timing_info_present_flag
    bits.write(0, count: 1) // vps_extension_flag
    return makeHEVCNAL(type: 32, rbsp: bits.finishRBSP())
}

private enum HEVCRPSFixtureMode {
    case none
    case truncatedPrediction
}

private func hevcSPS(
    rpsMode: HEVCRPSFixtureMode = .none,
    colorPrimaries: UInt8 = 9,
    colorTransfer: UInt8 = 16,
    colorMatrix: UInt8 = 9,
    chromaLocationType: UInt32? = 0
) -> Data {
    var bits = TestBitWriter()
    bits.write(0, count: 4) // sps_video_parameter_set_id
    bits.write(0, count: 3) // sps_max_sub_layers_minus1
    bits.write(1, count: 1) // sps_temporal_id_nesting_flag
    bits.write(0, count: 2) // general_profile_space
    bits.write(0, count: 1) // general_tier_flag
    bits.write(2, count: 5) // Main 10 profile
    bits.write(0, count: 32) // compatibility flags
    bits.write(1, count: 1) // progressive_source_flag
    bits.write(0, count: 1) // interlaced_source_flag
    bits.write(0, count: 1) // non_packed_constraint_flag
    bits.write(1, count: 1) // frame_only_constraint_flag
    bits.write(0, count: 44)
    bits.write(153, count: 8)
    bits.writeUE(0) // sps_seq_parameter_set_id
    bits.writeUE(1) // 4:2:0
    bits.writeUE(3_840)
    bits.writeUE(2_160)
    bits.write(0, count: 1) // conformance_window_flag
    bits.writeUE(2)
    bits.writeUE(2)
    bits.writeUE(4) // log2_max_pic_order_cnt_lsb_minus4
    bits.write(0, count: 1) // sub_layer_ordering_info_present_flag
    bits.writeUE(4)
    bits.writeUE(0)
    bits.writeUE(0)
    bits.writeUE(0)
    bits.writeUE(3)
    bits.writeUE(0)
    bits.writeUE(3)
    bits.writeUE(0)
    bits.writeUE(0)
    bits.write(0, count: 1) // scaling_list_enabled_flag
    bits.write(1, count: 1) // amp_enabled_flag
    bits.write(1, count: 1) // sample_adaptive_offset_enabled_flag
    bits.write(0, count: 1) // pcm_enabled_flag
    switch rpsMode {
    case .none:
        bits.writeUE(0) // num_short_term_ref_pic_sets
    case .truncatedPrediction:
        bits.writeUE(2)
        bits.writeUE(0) // 第一组 num_negative_pics
        bits.writeUE(0) // 第一组 num_positive_pics
        bits.write(1, count: 1) // 第二组 inter_ref_pic_set_prediction_flag
        return makeHEVCNAL(type: 33, rbsp: bits.finishRBSP())
    }
    bits.write(0, count: 1) // long_term_ref_pics_present_flag
    bits.write(0, count: 1) // sps_temporal_mvp_enabled_flag
    bits.write(1, count: 1) // strong_intra_smoothing_enabled_flag
    bits.write(1, count: 1) // vui_parameters_present_flag
    writeHEVCVUI(
        &bits,
        colorPrimaries: colorPrimaries,
        colorTransfer: colorTransfer,
        colorMatrix: colorMatrix,
        chromaLocationType: chromaLocationType
    )
    bits.write(0, count: 1) // sps_extension_present_flag
    return makeHEVCNAL(type: 33, rbsp: bits.finishRBSP())
}

private func hevcReservedSubLayerSPS() -> Data {
    var bits = TestBitWriter()
    bits.write(0, count: 4)
    bits.write(7, count: 3) // 标准保留值，合法范围是 0...6。
    bits.write(1, count: 1)
    return makeHEVCNAL(type: 33, rbsp: bits.finishRBSP())
}

private func hevcPPS() -> Data {
    var bits = TestBitWriter()
    bits.writeUE(0)
    bits.writeUE(0)
    bits.write(0, count: 1) // dependent_slice_segments_enabled_flag
    bits.write(0, count: 1) // output_flag_present_flag
    bits.write(0, count: 3) // num_extra_slice_header_bits
    bits.write(0, count: 1) // sign_data_hiding_enabled_flag
    bits.write(0, count: 1) // cabac_init_present_flag
    bits.writeUE(0) // num_ref_idx_l0_default_active_minus1
    bits.writeUE(0) // num_ref_idx_l1_default_active_minus1
    bits.writeSE(0) // init_qp_minus26
    bits.write(0, count: 1) // constrained_intra_pred_flag
    bits.write(0, count: 1) // transform_skip_enabled_flag
    bits.write(0, count: 1) // cu_qp_delta_enabled_flag
    bits.writeSE(0) // pps_cb_qp_offset
    bits.writeSE(0) // pps_cr_qp_offset
    bits.write(0, count: 1) // pps_slice_chroma_qp_offsets_present_flag
    bits.write(0, count: 1) // weighted_pred_flag
    bits.write(0, count: 1) // weighted_bipred_flag
    bits.write(0, count: 1) // transquant_bypass_enabled_flag
    bits.write(0, count: 1) // tiles_enabled_flag
    bits.write(0, count: 1) // entropy_coding_sync_enabled_flag
    bits.write(1, count: 1) // pps_loop_filter_across_slices_enabled_flag
    bits.write(1, count: 1) // deblocking_filter_control_present_flag
    bits.write(0, count: 1) // deblocking_filter_override_enabled_flag
    bits.write(0, count: 1) // pps_deblocking_filter_disabled_flag
    bits.writeSE(0) // pps_beta_offset_div2
    bits.writeSE(0) // pps_tc_offset_div2
    bits.write(0, count: 1) // pps_scaling_list_data_present_flag
    bits.write(0, count: 1) // lists_modification_present_flag
    bits.writeUE(0) // log2_parallel_merge_level_minus2
    bits.write(0, count: 1) // slice_segment_header_extension_present_flag
    bits.write(0, count: 1) // pps_extension_present_flag
    return makeHEVCNAL(type: 34, rbsp: bits.finishRBSP())
}

private func hevcSlice(
    nalType: UInt8,
    firstSliceSegmentInPicture: Bool = true
) -> Data {
    var bits = TestBitWriter()
    bits.write(firstSliceSegmentInPicture ? 1 : 0, count: 1)
    if (16...23).contains(nalType) { bits.write(0, count: 1) }
    bits.writeUE(0) // slice_pic_parameter_set_id
    return makeHEVCNAL(type: nalType, rbsp: bits.finishRBSP())
}

private func writeHEVCVUI(
    _ bits: inout TestBitWriter,
    colorPrimaries: UInt8,
    colorTransfer: UInt8,
    colorMatrix: UInt8,
    chromaLocationType: UInt32?
) {
    bits.write(1, count: 1)
    bits.write(1, count: 8)
    bits.write(0, count: 1)
    bits.write(1, count: 1)
    bits.write(5, count: 3)
    bits.write(0, count: 1)
    bits.write(1, count: 1)
    bits.write(UInt64(colorPrimaries), count: 8)
    bits.write(UInt64(colorTransfer), count: 8)
    bits.write(UInt64(colorMatrix), count: 8)
    bits.write(chromaLocationType == nil ? 0 : 1, count: 1)
    if let chromaLocationType {
        bits.writeUE(chromaLocationType)
        bits.writeUE(chromaLocationType)
    }
    bits.write(0, count: 1) // neutral_chroma_indication_flag
    bits.write(0, count: 1) // field_seq_flag
    bits.write(0, count: 1) // frame_field_info_present_flag
    bits.write(0, count: 1) // default_display_window_flag
    bits.write(1, count: 1) // vui_timing_info_present_flag
    bits.write(1_001, count: 32)
    bits.write(60_000, count: 32)
    bits.write(0, count: 1) // vui_poc_proportional_to_timing_flag
    bits.write(0, count: 1) // vui_hrd_parameters_present_flag
    bits.write(0, count: 1) // bitstream_restriction_flag
}

private func annexB(_ units: [Data]) -> Data {
    var data = Data()
    for unit in units {
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(unit)
    }
    return data
}

private func makeH264NAL(header: UInt8, rbsp: Data) -> Data {
    Data([header]) + escapeRBSP(rbsp)
}

private func makeHEVCNAL(type: UInt8, rbsp: Data) -> Data {
    Data([type << 1, 0x01]) + escapeRBSP(rbsp)
}

private func escapeRBSP(_ rbsp: Data) -> Data {
    var result = Data()
    var zeroCount = 0
    for byte in rbsp {
        if zeroCount >= 2, byte <= 3 {
            result.append(3)
            zeroCount = 0
        }
        result.append(byte)
        zeroCount = byte == 0 ? zeroCount + 1 : 0
    }
    return result
}

private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.bigEndian
    Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private struct TestBitWriter {
    private var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var usedBits = 0

    mutating func write(_ value: UInt64, count: Int) {
        precondition((0...64).contains(count))
        for shift in stride(from: count - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> UInt64(shift)) & 1)
            usedBits += 1
            if usedBits == 8 {
                bytes.append(current)
                current = 0
                usedBits = 0
            }
        }
    }

    mutating func writeUE(_ value: UInt32) {
        let codeNum = UInt64(value) + 1
        let bitCount = 64 - codeNum.leadingZeroBitCount
        if bitCount > 1 { write(0, count: bitCount - 1) }
        write(codeNum, count: bitCount)
    }

    mutating func writeSE(_ value: Int32) {
        let magnitude = UInt64(value >= 0 ? Int64(value) : -Int64(value))
        let codeNum = value > 0 ? magnitude * 2 - 1 : magnitude * 2
        precondition(codeNum <= UInt64(UInt32.max))
        writeUE(UInt32(codeNum))
    }

    mutating func finishRBSP() -> Data {
        write(1, count: 1)
        if usedBits != 0 { write(0, count: 8 - usedBits) }
        return Data(bytes)
    }
}
