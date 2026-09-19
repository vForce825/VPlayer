// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class VideoRemuxEligibilityTests: XCTestCase {
    func testSampleEntryContractCoversAvc1Avc3Hvc1Hev1() throws {
        let cases: [(HLSVideoSampleEntry, VideoCodec, VideoRemuxParameterSetDisposition)] = [
            (.avc1, .h264, .stripInBandToConfiguration),
            (.avc3, .h264, .preserveInBand),
            (.hvc1, .hevc, .stripInBandToConfiguration),
            (.hev1, .hevc, .preserveInBand),
        ]
        for (entry, codec, disposition) in cases {
            let subject = try VideoRemuxEligibility(
                generation: MediaGeneration(rawValue: 7),
                codec: codec,
                sampleEntry: entry,
                requiresDecodeTimestamp: false
            )
            let decision = try subject.evaluate(remuxEvidence(
                codec: codec,
                randomAccessKind: codec == .h264 ? .h264IDR : .hevcIDR,
                profileIDC: codec == .h264 ? 66 : 1,
                levelIDC: codec == .h264 ? 40 : 120,
                containsInBandParameterSets: true
            ))
            XCTAssertEqual(decision.path, .remux, "源 in-band 形态不能代替最终 sample-entry 合同")
            XCTAssertEqual(decision.parameterSetDisposition, disposition)
            XCTAssertEqual(decision.sourceContainsInBandParameterSets, true)
        }

        let mismatches: [(HLSVideoSampleEntry, VideoCodec)] = [
            (.avc1, .hevc), (.avc3, .hevc), (.hvc1, .h264), (.hev1, .h264),
        ]
        for (entry, codec) in mismatches {
            XCTAssertThrowsError(try VideoRemuxEligibility(
                generation: MediaGeneration(rawValue: 7),
                codec: codec,
                sampleEntry: entry,
                requiresDecodeTimestamp: false
            )) { error in
                XCTAssertEqual(error as? VideoRemuxEligibilityError, .sampleEntryCodecMismatch)
            }
        }
    }

    func testGOPAndDTSAdmissionIsGenerationScoped() throws {
        let generation = MediaGeneration(rawValue: 7)
        let subject = try VideoRemuxEligibility(
            generation: generation,
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: true
        )
        XCTAssertEqual(try subject.evaluate(remuxEvidence(
            pts: ExactMediaTime(value: 1, timescale: 1),
            dts: ExactMediaTime(value: 0, timescale: 1)
        )).path, .remux)
        XCTAssertEqual(try subject.evaluate(remuxEvidence(
            randomAccessKind: .none,
            pts: ExactMediaTime(value: 1, timescale: 2),
            dts: ExactMediaTime(value: 1, timescale: 1),
            allVCLAreRandomAccess: false
        )).path, .remux, "PTS 可因 B 帧重排而倒退，也允许 PTS 小于 DTS")

        let equalDTS = try subject.evaluate(remuxEvidence(
            randomAccessKind: .none,
            pts: ExactMediaTime(value: 3, timescale: 2),
            dts: ExactMediaTime(value: 1, timescale: 1),
            allVCLAreRandomAccess: false
        ))
        XCTAssertEqual(equalDTS.path, .transcode)
        XCTAssertEqual(equalDTS.transcodeReason, .nonMonotonicDecodeTimestamp)
        let afterDTSFailure = try subject.evaluate(remuxEvidence(
            randomAccessKind: .none,
            pts: ExactMediaTime(value: 7, timescale: 4),
            dts: ExactMediaTime(value: 2, timescale: 1),
            allVCLAreRandomAccess: false
        ))
        XCTAssertEqual(afterDTSFailure.path, .transcode)
        XCTAssertEqual(afterDTSFailure.transcodeReason, .nonMonotonicDecodeTimestamp)

        let missingDTS = try VideoRemuxEligibility(
            generation: generation,
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: true
        ).evaluate(remuxEvidence(dts: nil))
        XCTAssertEqual(missingDTS.transcodeReason, .missingDecodeTimestamp)

        XCTAssertThrowsError(try subject.evaluate(remuxEvidence(
            generation: MediaGeneration(rawValue: 8),
            randomAccessKind: .none,
            pts: ExactMediaTime(value: 2, timescale: 1),
            dts: ExactMediaTime(value: 2, timescale: 1)
        ))) { error in
            XCTAssertEqual(error as? VideoRemuxEligibilityError, .generationMismatch)
        }

        let nextGeneration = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 8),
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: true
        )
        XCTAssertEqual(try nextGeneration.evaluate(remuxEvidence(
            generation: MediaGeneration(rawValue: 8),
            pts: ExactMediaTime(value: 0, timescale: 1),
            dts: ExactMediaTime(value: 0, timescale: 1)
        )).path, .remux, "新 generation 的 DTS 基线必须独立建立")
    }

    func testExistingDTSMustRemainStrictlyMonotonicWithoutReorderingHint() throws {
        for nextDTS in [
            ExactMediaTime(value: 1, timescale: 1),
            ExactMediaTime(value: 1, timescale: 2),
        ] {
            let subject = try VideoRemuxEligibility(
                generation: MediaGeneration(rawValue: 7),
                track: eligibilityTrack(videoDelay: 0),
                sampleEntry: .avc1
            )
            XCTAssertEqual(try subject.evaluate(remuxEvidence(
                pts: ExactMediaTime(value: 0, timescale: 1),
                dts: ExactMediaTime(value: 1, timescale: 1)
            )).path, .remux)
            let result = try subject.evaluate(remuxEvidence(
                randomAccessKind: .none,
                pts: ExactMediaTime(value: 1, timescale: 25),
                dts: nextDTS,
                allVCLAreRandomAccess: false
            ))
            XCTAssertEqual(result.path, .transcode)
            XCTAssertEqual(result.transcodeReason, .nonMonotonicDecodeTimestamp)
        }
    }

    func testRemuxTranscodeAndRejectBoundaryMatrix() throws {
        let transcodeCases: [(String, TestRemuxEvidence, VideoRemuxTranscodeReason)] = [
            ("隔行", remuxEvidence(scan: .interlaced), .interlaced),
            ("CRA", remuxEvidence(codec: .hevc, randomAccessKind: .hevcCRA), .notIDR),
            (
                "container key",
                remuxEvidence(randomAccessKind: .containerKey, allVCLAreRandomAccess: false),
                .notIDR
            ),
            (
                "非 IDR 起播",
                remuxEvidence(randomAccessKind: .none, allVCLAreRandomAccess: false),
                .openGOP
            ),
        ]
        for (label, evidence, reason) in transcodeCases {
            let entry: HLSVideoSampleEntry = evidence.remuxCodec == .h264 ? .avc1 : .hvc1
            let decision = try VideoRemuxEligibility(
                generation: evidence.remuxGeneration,
                codec: evidence.remuxCodec,
                sampleEntry: entry,
                requiresDecodeTimestamp: false
            )
            let first = try decision.evaluate(evidence)
            XCTAssertEqual(first.path, .transcode, label)
            XCTAssertEqual(first.transcodeReason, reason, label)
            let validFollowUp = remuxEvidence(
                codec: evidence.remuxCodec,
                randomAccessKind: evidence.remuxCodec == .h264 ? .h264IDR : .hevcIDR,
                profileIDC: evidence.remuxCodec == .h264 ? 66 : 1,
                levelIDC: evidence.remuxCodec == .h264 ? 40 : 120
            )
            XCTAssertEqual(try decision.evaluate(validFollowUp).transcodeReason, reason, label)
        }

        let rejected: [(String, TestRemuxEvidence, VideoRemuxEligibilityError)] = [
            ("未分类", remuxEvidence(scan: .unresolved), .unknownScanClassification),
            ("无 VCL", remuxEvidence(containsVCL: false), .missingVCL),
            ("无参数签名", remuxEvidence(parameterSetIdentity: nil), .unknownParameterSetSignature),
            ("无格式签名", remuxEvidence(formatIdentity: nil), .unknownFormatSignature),
            ("无 PTS", remuxEvidence(pts: nil), .invalidPresentationTimestamp),
            ("无 duration", remuxEvidence(duration: nil), .invalidDuration),
            (
                "零 duration",
                remuxEvidence(duration: ExactMediaTime(value: 0, timescale: 1)),
                .invalidDuration
            ),
        ]
        for (label, evidence, expected) in rejected {
            XCTAssertThrowsError(try VideoRemuxEligibility(
                generation: evidence.remuxGeneration,
                codec: evidence.remuxCodec,
                sampleEntry: .avc1,
                requiresDecodeTimestamp: false
            ).evaluate(evidence), label) { error in
                XCTAssertEqual(error as? VideoRemuxEligibilityError, expected, label)
            }
        }

        let gop = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: false
        )
        XCTAssertEqual(try gop.evaluate(remuxEvidence(
            pts: ExactMediaTime(value: 0, timescale: 1)
        )).path, .remux)
        XCTAssertEqual(try gop.evaluate(remuxEvidence(
            randomAccessKind: .none,
            pts: ExactMediaTime(value: 2, timescale: 1),
            allVCLAreRandomAccess: false
        )).path, .remux, "IDR 后恰好 2 秒仍在闭区间内")
        let tooLong = try gop.evaluate(remuxEvidence(
            randomAccessKind: .none,
            pts: ExactMediaTime(value: 2_000_001, timescale: 1_000_000),
            allVCLAreRandomAccess: false
        ))
        XCTAssertEqual(tooLong.transcodeReason, .randomAccessIntervalExceeded)

        let arithmetic = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: false
        )
        _ = try arithmetic.evaluate(remuxEvidence(
            pts: ExactMediaTime(value: Int64.min, timescale: 1)
        ))
        XCTAssertThrowsError(try arithmetic.evaluate(remuxEvidence(
            randomAccessKind: .none,
            pts: ExactMediaTime(value: Int64.max, timescale: 1),
            allVCLAreRandomAccess: false
        ))) { error in
            XCTAssertEqual(error as? VideoRemuxEligibilityError, .arithmeticOverflow)
        }
    }

    func testParameterSetDriftFencesChangedAUBeforeOldGenerationProof() throws {
        let subject = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .h264,
            sampleEntry: .avc3,
            requiresDecodeTimestamp: false
        )
        let first = try subject.evaluate(remuxEvidence(parameterSetIdentity: .fixtureA))
        XCTAssertEqual(first.path, .remux)

        let changed = try subject.evaluate(remuxEvidence(
            randomAccessKind: .none,
            parameterSetIdentity: .fixtureB,
            pts: ExactMediaTime(value: 1, timescale: 25),
            allVCLAreRandomAccess: false
        ))
        XCTAssertEqual(changed.path, .transcode)
        XCTAssertEqual(changed.transcodeReason, .parameterSetsChanged)
        XCTAssertTrue(changed.requiresNewItem)

        XCTAssertThrowsError(try subject.evaluate(remuxEvidence(
            randomAccessKind: .none,
            parameterSetIdentity: .fixtureA,
            pts: ExactMediaTime(value: 2, timescale: 25),
            allVCLAreRandomAccess: false
        ))) { error in
            XCTAssertEqual(error as? VideoRemuxEligibilityError, .generationFenced)
        }
    }

    func testFormatLimitsAndMissingEvidenceRejectFailClosed() throws {
        let accepted = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .hevc,
            sampleEntry: .hvc1,
            requiresDecodeTimestamp: false
        )
        XCTAssertEqual(try accepted.evaluate(remuxEvidence(
            codec: .hevc,
            randomAccessKind: .hevcIDR,
            profileIDC: 2,
            levelIDC: 153,
            width: 3_840,
            height: 2_160,
            frameRate: MediaRational(num: 60, den: 1),
            codedLumaPictureSize: 8_294_400,
            maximumReferenceFrames: 6,
            bitDepthLuma: 10,
            bitDepthChroma: 10
        )).path, .remux)

        let rejected: [(String, TestRemuxEvidence, VideoRemuxEligibilityError)] = [
            ("缺宽度", remuxEvidence(width: nil), .missingDimensions),
            ("缺高度", remuxEvidence(height: nil), .missingDimensions),
            ("零宽度", remuxEvidence(width: 0), .invalidDimensions),
            ("负高度", remuxEvidence(height: -1), .invalidDimensions),
            ("宽度超过 4K", remuxEvidence(width: 3_841), .dimensionsExceeded),
            ("高度超过 2160", remuxEvidence(height: 2_161), .dimensionsExceeded),
            ("缺帧率", remuxEvidence(frameRate: nil), .missingFrameRate),
            (
                "帧率超过 60",
                remuxEvidence(frameRate: MediaRational(num: 60_001, den: 1_000)),
                .frameRateExceeded
            ),
            ("缺 chroma", remuxEvidence(chromaFormatIDC: nil), .missingChromaFormat),
            ("非 4:2:0", remuxEvidence(chromaFormatIDC: 2), .unsupportedChromaFormat),
            ("缺 luma 位深", remuxEvidence(bitDepthLuma: nil), .missingBitDepth),
            ("缺 chroma 位深", remuxEvidence(bitDepthChroma: nil), .missingBitDepth),
            (
                "luma/chroma 位深冲突",
                remuxEvidence(bitDepthLuma: 8, bitDepthChroma: 10),
                .inconsistentBitDepth
            ),
            (
                "不支持 12-bit",
                remuxEvidence(bitDepthLuma: 12, bitDepthChroma: 12),
                .unsupportedBitDepth
            ),
        ]
        for (label, evidence, expected) in rejected {
            let subject = try VideoRemuxEligibility(
                generation: evidence.remuxGeneration,
                codec: evidence.remuxCodec,
                sampleEntry: .avc1,
                requiresDecodeTimestamp: false
            )
            XCTAssertThrowsError(try subject.evaluate(evidence), label) { error in
                XCTAssertEqual(error as? VideoRemuxEligibilityError, expected, label)
            }
            XCTAssertThrowsError(try subject.evaluate(remuxEvidence()), "\(label) 后不能恢复 remux") {
                error in
                XCTAssertEqual(error as? VideoRemuxEligibilityError, .generationFenced, label)
            }
        }
    }

    func testProfileBitDepthAndHDRColorConsistencyMatrix() throws {
        let transcode = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: false
        )
        let high10 = try transcode.evaluate(remuxEvidence(
            profileIDC: 110,
            bitDepthLuma: 10,
            bitDepthChroma: 10
        ))
        XCTAssertEqual(high10.path, .transcode)
        XCTAssertEqual(high10.transcodeReason, .h264TenBit)
        XCTAssertEqual(try transcode.evaluate(remuxEvidence(
            profileIDC: 110,
            bitDepthLuma: 10,
            bitDepthChroma: 10,
            pts: ExactMediaTime(value: 1, timescale: 25)
        )).transcodeReason, .h264TenBit)

        let validHDR = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .hevc,
            sampleEntry: .hvc1,
            requiresDecodeTimestamp: false
        )
        XCTAssertEqual(try validHDR.evaluate(remuxEvidence(
            codec: .hevc,
            randomAccessKind: .hevcIDR,
            profileIDC: 2,
            levelIDC: 153,
            bitDepthLuma: 10,
            bitDepthChroma: 10,
            primaries: .bt2020,
            transfer: .pq,
            matrix: .bt2020Nonconstant,
            masteringDisplay: .fixture,
            contentLightLevel: .fixture
        )).path, .remux)

        let rejected: [(String, TestRemuxEvidence, VideoRemuxEligibilityError)] = [
            (
                "H.264 8-bit profile 声明 10-bit",
                remuxEvidence(profileIDC: 66, bitDepthLuma: 10, bitDepthChroma: 10),
                .profileBitDepthMismatch
            ),
            ("H.264 未支持 profile", remuxEvidence(profileIDC: 88), .unsupportedProfile),
            (
                "HEVC Main 声明 10-bit",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    profileIDC: 1,
                    levelIDC: 153,
                    bitDepthLuma: 10,
                    bitDepthChroma: 10
                ),
                .profileBitDepthMismatch
            ),
            (
                "HEVC 未支持 profile",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    profileIDC: 3,
                    levelIDC: 153
                ),
                .unsupportedProfile
            ),
            (
                "8-bit PQ",
                remuxEvidence(
                    primaries: .bt2020,
                    transfer: .pq,
                    matrix: .bt2020Nonconstant
                ),
                .hdrRequiresTenBit
            ),
            (
                "8-bit HLG",
                remuxEvidence(
                    primaries: .bt2020,
                    transfer: .hlg,
                    matrix: .bt2020Nonconstant
                ),
                .hdrRequiresTenBit
            ),
            (
                "PQ 使用 BT.709 primaries",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    profileIDC: 2,
                    levelIDC: 153,
                    bitDepthLuma: 10,
                    bitDepthChroma: 10,
                    primaries: .bt709,
                    transfer: .pq,
                    matrix: .bt2020Nonconstant
                ),
                .inconsistentHDRColorMetadata
            ),
            (
                "PQ 缺 matrix",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    profileIDC: 2,
                    levelIDC: 153,
                    bitDepthLuma: 10,
                    bitDepthChroma: 10,
                    primaries: .bt2020,
                    transfer: .pq,
                    matrix: nil
                ),
                .inconsistentHDRColorMetadata
            ),
            (
                "PQ 缺 primaries",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    profileIDC: 2,
                    levelIDC: 153,
                    bitDepthLuma: 10,
                    bitDepthChroma: 10,
                    primaries: nil,
                    transfer: .pq,
                    matrix: .bt2020Nonconstant
                ),
                .inconsistentHDRColorMetadata
            ),
            (
                "SDR 携带 MDCV",
                remuxEvidence(masteringDisplay: .fixture),
                .inconsistentHDRColorMetadata
            ),
            (
                "SDR 携带 CLLI",
                remuxEvidence(contentLightLevel: .fixture),
                .inconsistentHDRColorMetadata
            ),
            (
                "SDR primaries/matrix 冲突",
                remuxEvidence(primaries: .bt709, matrix: .bt2020Nonconstant),
                .inconsistentColorMetadata
            ),
        ]
        for (label, evidence, expected) in rejected {
            let subject = try VideoRemuxEligibility(
                generation: evidence.remuxGeneration,
                codec: evidence.remuxCodec,
                sampleEntry: evidence.remuxCodec == .h264 ? .avc1 : .hvc1,
                requiresDecodeTimestamp: false
            )
            XCTAssertThrowsError(try subject.evaluate(evidence), label) { error in
                XCTAssertEqual(error as? VideoRemuxEligibilityError, expected, label)
            }
        }
    }

    func testMixedAndConflictingRandomAccessBecomeStickyTranscode() throws {
        let cases: [(String, TestRemuxEvidence, VideoRemuxTranscodeReason)] = [
            (
                "IDR AU 混入非随机访问 VCL",
                remuxEvidence(allVCLAreRandomAccess: false),
                .mixedRandomAccessAccessUnit
            ),
            (
                "同 AU 同时出现冲突随机访问类型",
                remuxEvidence(conflictingRandomAccessKinds: true),
                .conflictingRandomAccessKinds
            ),
            (
                "AU 缺少唯一 primary picture 起始 slice",
                remuxEvidence(hasSinglePrimaryPictureStartSlice: false),
                .invalidPrimaryPictureStructure
            ),
        ]
        for (label, evidence, reason) in cases {
            let subject = try VideoRemuxEligibility(
                generation: evidence.remuxGeneration,
                codec: evidence.remuxCodec,
                sampleEntry: .avc1,
                requiresDecodeTimestamp: false
            )
            let first = try subject.evaluate(evidence)
            XCTAssertEqual(first.transcodeReason, reason, label)
            XCTAssertEqual(try subject.evaluate(remuxEvidence()).transcodeReason, reason, label)
        }

        let inconsistent = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .h264,
            sampleEntry: .avc1,
            requiresDecodeTimestamp: false
        )
        XCTAssertThrowsError(try inconsistent.evaluate(remuxEvidence(
            randomAccessKind: .none,
            allVCLAreRandomAccess: true
        ))) { error in
            XCTAssertEqual(
                error as? VideoRemuxEligibilityError,
                .inconsistentRandomAccessEvidence
            )
        }
    }

    func testHEVCCRARemainsStickyTranscodeAfterIDR() throws {
        let subject = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            track: eligibilityTrack(codec: .hevc, videoDelay: 0),
            sampleEntry: .hvc1
        )
        XCTAssertEqual(try subject.evaluate(remuxEvidence(
            codec: .hevc,
            randomAccessKind: .hevcIDR,
            pts: ExactMediaTime(value: 0, timescale: 1)
        )).path, .remux)
        let cra = try subject.evaluate(remuxEvidence(
            codec: .hevc,
            randomAccessKind: .hevcCRA,
            pts: ExactMediaTime(value: 1, timescale: 1)
        ))
        XCTAssertEqual(cra.path, .transcode)
        XCTAssertEqual(cra.transcodeReason, .notIDR)
        XCTAssertEqual(try subject.evaluate(remuxEvidence(
            codec: .hevc,
            randomAccessKind: .hevcIDR,
            pts: ExactMediaTime(value: 2, timescale: 1)
        )).transcodeReason, .notIDR)
    }

    func testIDRPresentationTimestampMustStrictlyIncrease() throws {
        for nextPTS in [
            ExactMediaTime(value: 1, timescale: 1),
            ExactMediaTime(value: 1, timescale: 2),
        ] {
            let subject = try VideoRemuxEligibility(
                generation: MediaGeneration(rawValue: 7),
                codec: .h264,
                sampleEntry: .avc1,
                requiresDecodeTimestamp: false
            )
            XCTAssertEqual(try subject.evaluate(remuxEvidence(
                pts: ExactMediaTime(value: 1, timescale: 1)
            )).path, .remux)
            let result = try subject.evaluate(remuxEvidence(pts: nextPTS))
            XCTAssertEqual(result.path, .transcode)
            XCTAssertEqual(result.transcodeReason, .nonIncreasingIDRPresentationTimestamp)
            XCTAssertEqual(
                try subject.evaluate(remuxEvidence(
                    pts: ExactMediaTime(value: 3, timescale: 2)
                )).transcodeReason,
                .nonIncreasingIDRPresentationTimestamp
            )
        }
    }

    func testFormatIdentityDriftFencesBeforeProof() throws {
        let subject = try VideoRemuxEligibility(
            generation: MediaGeneration(rawValue: 7),
            codec: .h264,
            sampleEntry: .avc3,
            requiresDecodeTimestamp: false
        )
        XCTAssertEqual(try subject.evaluate(remuxEvidence(
            formatIdentity: .formatFixtureA
        )).path, .remux)

        let changed = try subject.evaluate(remuxEvidence(
            formatIdentity: .formatFixtureB,
            pts: ExactMediaTime(value: 1, timescale: 25)
        ))
        XCTAssertEqual(changed.path, .transcode)
        XCTAssertEqual(changed.transcodeReason, .formatChanged)
        XCTAssertTrue(changed.requiresNewItem)

        XCTAssertThrowsError(try subject.evaluate(remuxEvidence())) { error in
            XCTAssertEqual(error as? VideoRemuxEligibilityError, .generationFenced)
        }
    }

    func testProductionAdmissionRequiresConcreteInspectorProofAndPreservesSourceIdentity() throws {
        let generation = MediaGeneration(rawValue: 7)
        let bytes = eligibilityAnnexB([
            eligibilityH264SPS(),
            eligibilityH264PPS(),
            eligibilityH264Slice(),
        ])
        let backing = try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: generation,
                accessUnitID: 41
            ),
            bytes: bytes
        )
        let byteRange = try XCTUnwrap(
            VideoAccessUnitByteRange(offset: 0, length: bytes.count)
        )
        var inspector = VideoAccessUnitInspectionSession(
            generation: generation,
            codec: .h264
        )
        let track = eligibilityTrack(
            codec: .h264,
            width: 1_920,
            height: 1_080,
            frameRate: MediaRational(num: 25, den: 1)!,
            videoDelay: 0
        )
        let inspectionProof = try inspector.inspect(VideoAccessUnitInspectionInput(
            backing: backing,
            byteRange: byteRange,
            sourceSHA256: backing.sha256,
            codec: .h264,
            scanClassification: .progressive,
            presentationTimeStamp: ExactMediaTime(value: 0, timescale: 1),
            decodeTimeStamp: nil,
            duration: ExactMediaTime(value: 1, timescale: 25),
            expectedFormat: track
        ))
        let decision = try VideoRemuxEligibility(
            generation: generation,
            track: track,
            sampleEntry: .avc1
        ).evaluate(inspectionProof)

        XCTAssertEqual(decision.path, .remux)
        let admission = try XCTUnwrap(decision.proof)
        XCTAssertTrue(admission.source.identity.matches(
            backing: backing,
            byteRange: byteRange,
            sourceSHA256: backing.sha256
        ))
        XCTAssertEqual(admission.maximumReferenceFrames, 4)
    }

    func testDTSRequirementIsDerivedFromTrackVideoDelayAndCannotBeBypassed() throws {
        let generation = MediaGeneration(rawValue: 7)
        let noReordering = try VideoRemuxEligibility(
            generation: generation,
            track: eligibilityTrack(videoDelay: 0),
            sampleEntry: .avc1
        )
        XCTAssertEqual(try noReordering.evaluate(remuxEvidence(dts: nil)).path, .remux)

        let reordered = try VideoRemuxEligibility(
            generation: generation,
            track: eligibilityTrack(videoDelay: 1),
            sampleEntry: .avc1
        )
        let decision = try reordered.evaluate(remuxEvidence(dts: nil))
        XCTAssertEqual(decision.path, .transcode)
        XCTAssertEqual(decision.transcodeReason, .missingDecodeTimestamp)
    }

    func testH264LevelChecksFrameSizeSampleRateAndDecodedPictureBuffer() throws {
        let accepted = remuxEvidence(
            levelIDC: 31,
            width: 1_280,
            height: 720,
            frameRate: MediaRational(num: 30, den: 1),
            codedPictureSizeInMacroblocks: 3_600,
            maximumReferenceFrames: 5
        )
        XCTAssertEqual(try eligibilitySubject(for: accepted).evaluate(accepted).path, .remux)

        let rejected: [(String, TestRemuxEvidence, VideoRemuxEligibilityError)] = [
            (
                "L3.1 不能容纳 4K",
                remuxEvidence(
                    levelIDC: 31,
                    width: 3_840,
                    height: 2_160,
                    frameRate: MediaRational(num: 60, den: 1),
                    codedPictureSizeInMacroblocks: 32_400,
                    maximumReferenceFrames: 1
                ),
                .levelFrameSizeExceeded
            ),
            (
                "L3.1 720p31 超过 MaxMBPS",
                remuxEvidence(
                    levelIDC: 31,
                    width: 1_280,
                    height: 720,
                    frameRate: MediaRational(num: 31, den: 1),
                    codedPictureSizeInMacroblocks: 3_600,
                    maximumReferenceFrames: 5
                ),
                .levelSampleRateExceeded
            ),
            (
                "L3.1 720p 最多五张参考图",
                remuxEvidence(
                    levelIDC: 31,
                    width: 1_280,
                    height: 720,
                    frameRate: MediaRational(num: 30, den: 1),
                    codedPictureSizeInMacroblocks: 3_600,
                    maximumReferenceFrames: 6
                ),
                .levelDecodedPictureBufferExceeded
            ),
            (
                "缺 coded macroblock 证据",
                remuxEvidence(codedPictureSizeInMacroblocks: nil),
                .missingLevelEvidence
            ),
        ]
        for (label, evidence, expected) in rejected {
            XCTAssertThrowsError(try eligibilitySubject(for: evidence).evaluate(evidence), label) {
                error in
                XCTAssertEqual(error as? VideoRemuxEligibilityError, expected, label)
            }
        }
    }

    func testHEVCLevelChecksLumaPictureSampleRateAndDynamicDPB() throws {
        let accepted = remuxEvidence(
            codec: .hevc,
            randomAccessKind: .hevcIDR,
            profileIDC: 2,
            levelIDC: 153,
            width: 3_840,
            height: 2_160,
            frameRate: MediaRational(num: 60, den: 1),
            codedLumaPictureSize: 8_294_400,
            maximumReferenceFrames: 6,
            bitDepthLuma: 10,
            bitDepthChroma: 10
        )
        XCTAssertEqual(try eligibilitySubject(for: accepted).evaluate(accepted).path, .remux)

        let rejected: [(String, TestRemuxEvidence, VideoRemuxEligibilityError)] = [
            (
                "HEVC L4 不能容纳 4K",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    levelIDC: 120,
                    width: 3_840,
                    height: 2_160,
                    frameRate: MediaRational(num: 60, den: 1),
                    codedLumaPictureSize: 8_294_400
                ),
                .levelFrameSizeExceeded
            ),
            (
                "HEVC L5 4K60 超过 MaxLumaSr",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    levelIDC: 150,
                    width: 3_840,
                    height: 2_160,
                    frameRate: MediaRational(num: 60, den: 1),
                    codedLumaPictureSize: 8_294_400
                ),
                .levelSampleRateExceeded
            ),
            (
                "接近 MaxLumaPs 时 DPB 上限为六张",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    profileIDC: 2,
                    levelIDC: 153,
                    width: 3_840,
                    height: 2_160,
                    codedLumaPictureSize: 8_294_400,
                    maximumReferenceFrames: 7,
                    bitDepthLuma: 10,
                    bitDepthChroma: 10
                ),
                .levelDecodedPictureBufferExceeded
            ),
            (
                "缺 coded luma 证据",
                remuxEvidence(
                    codec: .hevc,
                    randomAccessKind: .hevcIDR,
                    codedLumaPictureSize: nil
                ),
                .missingLevelEvidence
            ),
        ]
        for (label, evidence, expected) in rejected {
            XCTAssertThrowsError(try eligibilitySubject(for: evidence).evaluate(evidence), label) {
                error in
                XCTAssertEqual(error as? VideoRemuxEligibilityError, expected, label)
            }
        }
    }

    func testRemuxBitrateEnvelopeUsesFrozenCheckedProfileLevelBounds() throws {
        let cases: [(String, VideoCodecProfileLevel, UInt64, UInt64, UInt64)] = [
            ("H.264 Baseline L3.1", .h264(
                profileIDC: 66,
                compatibilityFlags: 0,
                levelIDC: 31
            ),
             14_000_000, 280_000, 14_280_000),
            ("H.264 High L4.1", .h264(
                profileIDC: 100,
                compatibilityFlags: 0,
                levelIDC: 41
            ),
             62_500_000, 1_250_000, 63_750_000),
            ("HEVC Main L5.1", .hevc(profileIDC: 1, tier: .main, levelIDC: 153),
             40_000_000, 800_000, 40_800_000),
            ("HEVC Main10 High Tier L5.1 被 80M 截断",
             .hevc(profileIDC: 2, tier: .high, levelIDC: 153),
             80_000_000, 1_600_000, 81_600_000),
        ]
        for (label, profileLevel, payload, overhead, declared) in cases {
            let envelope = try VideoBitrateEnvelope.freeze(profileLevel: profileLevel)
            XCTAssertEqual(envelope.payloadBitsPerSecond, payload, label)
            XCTAssertEqual(envelope.overheadBitsPerSecond, overhead, label)
            XCTAssertEqual(envelope.declaredBitsPerSecond, declared, label)
            XCTAssertTrue(try envelope.admitsMediaFile(
                byteCount: declared / 8,
                duration: ExactMediaTime(value: 1, timescale: 1)
            ), label)
            XCTAssertFalse(try envelope.admitsMediaFile(
                byteCount: declared / 8 + 1,
                duration: ExactMediaTime(value: 1, timescale: 1)
            ), label)
        }

        let minimumOverhead = try VideoBitrateEnvelope.freeze(
            profileLevel: .h264(profileIDC: 66, compatibilityFlags: 0, levelIDC: 10)
        )
        XCTAssertEqual(minimumOverhead.payloadBitsPerSecond, 64_000)
        XCTAssertEqual(minimumOverhead.overheadBitsPerSecond, 256_000)
        XCTAssertEqual(minimumOverhead.declaredBitsPerSecond, 320_000)

        let unsupported: [VideoCodecProfileLevel] = [
            .h264(profileIDC: 244, compatibilityFlags: 0, levelIDC: 41),
            .h264(profileIDC: 66, compatibilityFlags: 0, levelIDC: 99),
            .hevc(profileIDC: 3, tier: .main, levelIDC: 153),
            .hevc(profileIDC: 1, tier: .main, levelIDC: 99),
        ]
        for profileLevel in unsupported {
            XCTAssertThrowsError(try VideoBitrateEnvelope.freeze(profileLevel: profileLevel)) { error in
                XCTAssertEqual(error as? VideoBitrateEnvelopeError, .unsupportedProfileLevel)
            }
        }

        let envelope = try VideoBitrateEnvelope.freeze(
            profileLevel: .hevc(profileIDC: 2, tier: .high, levelIDC: 153)
        )
        XCTAssertThrowsError(try envelope.admitsMediaFile(
            byteCount: UInt64.max,
            duration: ExactMediaTime(value: 1, timescale: 1)
        )) { error in
            XCTAssertEqual(error as? VideoBitrateEnvelopeError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try envelope.admitsMediaFile(
            byteCount: 1,
            duration: ExactMediaTime(value: 0, timescale: 1)
        )) { error in
            XCTAssertEqual(error as? VideoBitrateEnvelopeError, .invalidDuration)
        }
    }

    func testH264Level1BUsesConstraintSet3ForLimitsAndEnvelope() throws {
        let level1B = VideoCodecProfileLevel.h264(
            profileIDC: 66,
            compatibilityFlags: 0x10,
            levelIDC: 11
        )
        let level1BEvidence = remuxEvidence(
            profileCompatibilityFlags: 0x10,
            levelIDC: 11,
            width: 176,
            height: 144,
            frameRate: MediaRational(num: 15, den: 1),
            codedPictureSizeInMacroblocks: 99,
            maximumReferenceFrames: 4
        )
        XCTAssertEqual(
            try eligibilitySubject(for: level1BEvidence).evaluate(level1BEvidence).path,
            .remux
        )
        let envelope = try VideoBitrateEnvelope.freeze(profileLevel: level1B)
        XCTAssertEqual(envelope.payloadBitsPerSecond, 128_000)
        XCTAssertEqual(envelope.overheadBitsPerSecond, 256_000)
        XCTAssertEqual(envelope.declaredBitsPerSecond, 384_000)
        XCTAssertNoThrow(try VideoBitrateEnvelope.validateLevel(
            profileLevel: level1B,
            frameRate: MediaRational(num: 15, den: 1),
            codedPictureSizeInMacroblocks: 99,
            codedLumaPictureSize: nil,
            maximumReferenceFrames: 4
        ), "Level 1b 的 MaxFS、MaxMBPS、MaxDpbMbs 等号边界必须接受")
        XCTAssertThrowsError(try VideoBitrateEnvelope.validateLevel(
            profileLevel: level1B,
            frameRate: MediaRational(num: 16, den: 1),
            codedPictureSizeInMacroblocks: 99,
            codedLumaPictureSize: nil,
            maximumReferenceFrames: 4
        )) { error in
            XCTAssertEqual(error as? VideoBitrateEnvelopeError, .levelSampleRateExceeded)
        }

        let level11 = try VideoBitrateEnvelope.freeze(profileLevel: .h264(
            profileIDC: 66,
            compatibilityFlags: 0,
            levelIDC: 11
        ))
        XCTAssertEqual(level11.payloadBitsPerSecond, 192_000)
        let highIgnoresConstraintSet3 = try VideoBitrateEnvelope.freeze(profileLevel: .h264(
            profileIDC: 100,
            compatibilityFlags: 0x10,
            levelIDC: 11
        ))
        XCTAssertEqual(highIgnoresConstraintSet3.payloadBitsPerSecond, 240_000)
    }
}

private struct TestRemuxEvidence: VideoRemuxInspectionEvidence {
    let remuxGeneration: MediaGeneration
    let remuxCodec: VideoCodec
    let remuxRandomAccessKind: VideoRandomAccessKind
    let remuxParameterSetIdentity: VideoAccessUnitSHA256?
    let remuxFormatIdentity: VideoAccessUnitSHA256?
    let remuxProfileIDC: UInt8
    let remuxProfileCompatibilityFlags: UInt32
    let remuxLevelIDC: UInt8
    let remuxTier: VideoCodecTier
    let remuxWidth: Int32?
    let remuxHeight: Int32?
    let remuxFrameRate: MediaRational?
    let remuxCodedPictureSizeInMacroblocks: UInt32?
    let remuxCodedLumaPictureSize: UInt64?
    let remuxMaximumReferenceFrames: UInt32?
    let remuxChromaFormatIDC: UInt8?
    let remuxBitDepthLuma: UInt8?
    let remuxBitDepthChroma: UInt8?
    let remuxColorPrimaries: DemuxColorPrimaries?
    let remuxColorTransfer: DemuxColorTransfer?
    let remuxColorMatrix: DemuxColorMatrix?
    let remuxMasteringDisplay: DemuxMasteringDisplayMetadata?
    let remuxContentLightLevel: DemuxContentLightLevelMetadata?
    let remuxScanClassification: VideoScanClassificationEvidence
    let remuxPresentationTimeStamp: ExactMediaTime?
    let remuxDecodeTimeStamp: ExactMediaTime?
    let remuxDuration: ExactMediaTime?
    let remuxContainsVCL: Bool
    let remuxContainsInBandParameterSets: Bool
    let remuxAllVCLAreRandomAccess: Bool
    let remuxConflictingRandomAccessKinds: Bool
    let remuxHasSinglePrimaryPictureStartSlice: Bool
}

private extension VideoRemuxEligibility {
    convenience init(
        generation: MediaGeneration,
        codec: VideoCodec,
        sampleEntry: HLSVideoSampleEntry,
        requiresDecodeTimestamp: Bool
    ) throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let frameRate = try XCTUnwrap(MediaRational(num: 25, den: 1))
        let track = VideoTrackDescriptor(
            streamIndex: 0,
            codec: codec,
            timeBase: timeBase,
            width: 1_920,
            height: 1_080,
            videoDelay: requiresDecodeTimestamp ? 1 : 0,
            extradata: Data(),
            frameRate: frameRate,
            fieldOrder: .progressive
        )
        try self.init(
            generation: generation,
            track: track,
            sampleEntry: sampleEntry,
            maximumRandomAccessInterval: ExactMediaTime(value: 2, timescale: 1)
        )
    }

    func evaluate(_ evidence: TestRemuxEvidence) throws -> VideoRemuxPolicyDecision {
        try evaluatePolicyForTesting(evidence)
    }
}

private func eligibilitySubject(
    for evidence: TestRemuxEvidence,
    videoDelay: Int32 = 0
) throws -> VideoRemuxEligibility {
    try VideoRemuxEligibility(
        generation: evidence.remuxGeneration,
        track: eligibilityTrack(codec: evidence.remuxCodec, videoDelay: videoDelay),
        sampleEntry: evidence.remuxCodec == .h264 ? .avc1 : .hvc1
    )
}

private func eligibilityTrack(
    codec: VideoCodec = .h264,
    width: Int32 = 1_920,
    height: Int32 = 1_080,
    frameRate: MediaRational = MediaRational(num: 25, den: 1)!,
    videoDelay: Int32
) -> VideoTrackDescriptor {
    VideoTrackDescriptor(
        streamIndex: 0,
        codec: codec,
        timeBase: MediaRational(num: 1, den: 90_000)!,
        width: width,
        height: height,
        videoDelay: videoDelay,
        extradata: Data(),
        frameRate: frameRate,
        fieldOrder: .progressive,
        videoMetadata: DemuxVideoMetadata(
            range: .limited,
            primaries: .bt709,
            transfer: .bt709,
            matrix: .bt709,
            chromaLocation: .left
        )
    )
}

private func eligibilityH264SPS() -> Data {
    var bits = EligibilityBitWriter()
    bits.write(100, count: 8) // High profile
    bits.write(0, count: 8) // constraint flags
    bits.write(40, count: 8) // Level 4.0
    bits.writeUE(0) // seq_parameter_set_id
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
    bits.writeUE(119) // 120 个 coded 宏块宽
    bits.writeUE(67) // 68 个 coded 宏块高
    bits.write(1, count: 1) // frame_mbs_only_flag
    bits.write(1, count: 1) // direct_8x8_inference_flag
    bits.write(1, count: 1) // frame_cropping_flag
    bits.writeUE(0)
    bits.writeUE(0)
    bits.writeUE(0)
    bits.writeUE(4) // 从 coded 1088 裁剪到 1080
    bits.write(0, count: 1) // vui_parameters_present_flag
    return eligibilityH264NAL(header: 0x67, rbsp: bits.finishRBSP())
}

private func eligibilityH264PPS() -> Data {
    var bits = EligibilityBitWriter()
    bits.writeUE(0) // pic_parameter_set_id
    bits.writeUE(0) // seq_parameter_set_id
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
    bits.write(0, count: 1) // constrained_intra_pred_flag
    bits.write(0, count: 1) // redundant_pic_cnt_present_flag
    return eligibilityH264NAL(header: 0x68, rbsp: bits.finishRBSP())
}

private func eligibilityH264Slice() -> Data {
    var bits = EligibilityBitWriter()
    bits.writeUE(0) // first_mb_in_slice
    bits.writeUE(2) // I slice
    bits.writeUE(0) // pic_parameter_set_id
    return eligibilityH264NAL(header: 0x65, rbsp: bits.finishRBSP())
}

private func eligibilityAnnexB(_ units: [Data]) -> Data {
    var result = Data()
    for unit in units {
        result.append(contentsOf: [0, 0, 0, 1])
        result.append(unit)
    }
    return result
}

private func eligibilityH264NAL(header: UInt8, rbsp: Data) -> Data {
    var result = Data([header])
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

private struct EligibilityBitWriter {
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
        let codeNumber = UInt64(value) + 1
        let bitCount = 64 - codeNumber.leadingZeroBitCount
        if bitCount > 1 { write(0, count: bitCount - 1) }
        write(codeNumber, count: bitCount)
    }

    mutating func writeSE(_ value: Int32) {
        let magnitude = UInt64(value >= 0 ? Int64(value) : -Int64(value))
        let codeNumber = value > 0 ? magnitude * 2 - 1 : magnitude * 2
        precondition(codeNumber <= UInt64(UInt32.max))
        writeUE(UInt32(codeNumber))
    }

    mutating func finishRBSP() -> Data {
        write(1, count: 1)
        if usedBits != 0 { write(0, count: 8 - usedBits) }
        return Data(bytes)
    }
}

private func remuxEvidence(
    generation: MediaGeneration = MediaGeneration(rawValue: 7),
    codec: VideoCodec = .h264,
    randomAccessKind: VideoRandomAccessKind = .h264IDR,
    parameterSetIdentity: VideoAccessUnitSHA256? = .fixtureA,
    formatIdentity: VideoAccessUnitSHA256? = .formatFixtureA,
    profileIDC: UInt8? = nil,
    profileCompatibilityFlags: UInt32 = 0,
    levelIDC: UInt8? = nil,
    tier: VideoCodecTier = .main,
    width: Int32? = 1_920,
    height: Int32? = 1_080,
    frameRate: MediaRational? = MediaRational(num: 25, den: 1),
    codedPictureSizeInMacroblocks: UInt32? = 8_160,
    codedLumaPictureSize: UInt64? = 2_073_600,
    maximumReferenceFrames: UInt32? = 4,
    chromaFormatIDC: UInt8? = 1,
    bitDepthLuma: UInt8? = 8,
    bitDepthChroma: UInt8? = 8,
    primaries: DemuxColorPrimaries? = .bt709,
    transfer: DemuxColorTransfer? = .bt709,
    matrix: DemuxColorMatrix? = .bt709,
    masteringDisplay: DemuxMasteringDisplayMetadata? = nil,
    contentLightLevel: DemuxContentLightLevelMetadata? = nil,
    scan: VideoScanClassificationEvidence = .progressive,
    pts: ExactMediaTime? = ExactMediaTime(value: 0, timescale: 1),
    dts: ExactMediaTime? = nil,
    duration: ExactMediaTime? = ExactMediaTime(value: 1, timescale: 25),
    containsVCL: Bool = true,
    containsInBandParameterSets: Bool = false,
    allVCLAreRandomAccess: Bool = true,
    conflictingRandomAccessKinds: Bool = false,
    hasSinglePrimaryPictureStartSlice: Bool = true
) -> TestRemuxEvidence {
    TestRemuxEvidence(
        remuxGeneration: generation,
        remuxCodec: codec,
        remuxRandomAccessKind: randomAccessKind,
        remuxParameterSetIdentity: parameterSetIdentity,
        remuxFormatIdentity: formatIdentity,
        remuxProfileIDC: profileIDC ?? (codec == .h264 ? 66 : 1),
        remuxProfileCompatibilityFlags: profileCompatibilityFlags,
        remuxLevelIDC: levelIDC ?? (codec == .h264 ? 40 : 120),
        remuxTier: tier,
        remuxWidth: width,
        remuxHeight: height,
        remuxFrameRate: frameRate,
        remuxCodedPictureSizeInMacroblocks: codedPictureSizeInMacroblocks,
        remuxCodedLumaPictureSize: codedLumaPictureSize,
        remuxMaximumReferenceFrames: maximumReferenceFrames,
        remuxChromaFormatIDC: chromaFormatIDC,
        remuxBitDepthLuma: bitDepthLuma,
        remuxBitDepthChroma: bitDepthChroma,
        remuxColorPrimaries: primaries,
        remuxColorTransfer: transfer,
        remuxColorMatrix: matrix,
        remuxMasteringDisplay: masteringDisplay,
        remuxContentLightLevel: contentLightLevel,
        remuxScanClassification: scan,
        remuxPresentationTimeStamp: pts,
        remuxDecodeTimeStamp: dts,
        remuxDuration: duration,
        remuxContainsVCL: containsVCL,
        remuxContainsInBandParameterSets: containsInBandParameterSets,
        remuxAllVCLAreRandomAccess: allVCLAreRandomAccess,
        remuxConflictingRandomAccessKinds: conflictingRandomAccessKinds,
        remuxHasSinglePrimaryPictureStartSlice: hasSinglePrimaryPictureStartSlice
    )
}

private extension VideoAccessUnitSHA256 {
    static var fixtureA: VideoAccessUnitSHA256 {
        fixtureDigest("parameter-set-a")
    }

    static var fixtureB: VideoAccessUnitSHA256 {
        fixtureDigest("parameter-set-b")
    }

    static var formatFixtureA: VideoAccessUnitSHA256 {
        fixtureDigest("format-a")
    }

    static var formatFixtureB: VideoAccessUnitSHA256 {
        fixtureDigest("format-b")
    }

    private static func fixtureDigest(_ value: String) -> VideoAccessUnitSHA256 {
        let bytes = Data(value.utf8)
        return VideoAccessUnitSHA256(bytes: bytes.span)
    }
}

private extension DemuxMasteringDisplayMetadata {
    static var fixture: DemuxMasteringDisplayMetadata {
        DemuxMasteringDisplayMetadata(
            redX: DemuxHDRRational(num: 17, den: 25)!,
            redY: DemuxHDRRational(num: 8, den: 25)!,
            greenX: DemuxHDRRational(num: 53, den: 200)!,
            greenY: DemuxHDRRational(num: 69, den: 100)!,
            blueX: DemuxHDRRational(num: 3, den: 20)!,
            blueY: DemuxHDRRational(num: 3, den: 50)!,
            whitePointX: DemuxHDRRational(num: 31, den: 100)!,
            whitePointY: DemuxHDRRational(num: 33, den: 100)!,
            minimumLuminance: DemuxHDRRational(num: 1, den: 10_000)!,
            maximumLuminance: DemuxHDRRational(num: 1_000, den: 1)!
        )!
    }
}

private extension DemuxContentLightLevelMetadata {
    static var fixture: DemuxContentLightLevelMetadata {
        DemuxContentLightLevelMetadata(
            maximumContentLightLevel: 1_000,
            maximumFrameAverageLightLevel: 400
        )!
    }
}
