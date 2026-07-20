// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import XCTest
import VPlayerPlayback

final class FieldMetadataReaderTests: XCTestCase {
    func testFFmpegDisplayOrderMappingCoversEveryCodedValue() {
        let expectations: [(CodedFieldOrder, ResolvedFieldOrder)] = [
            (.unknown, order(.top, confidence: .assumed, source: .none)),
            (.progressive, order(.top, confidence: .assumed, source: .none)),
            (.tt, order(.top, confidence: .signaled, source: .parser)),
            (.bb, order(.bottom, confidence: .signaled, source: .parser)),
            (.tb, order(.bottom, confidence: .signaled, source: .parser)),
            (.bt, order(.top, confidence: .signaled, source: .parser)),
        ]

        for (coded, expected) in expectations {
            XCTAssertEqual(ResolvedFieldOrder(coded: coded), expected, "coded order: \(coded)")
        }
    }

    func testFieldCountTwoWithoutDetailDoesNotClaimOrder() throws {
        let format = try VideoTestFactories.formatDescription(fieldCount: number(2))

        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: format, pixelBuffer: nil),
            FieldMetadataEvidence(fieldCount: 2, fieldOrder: nil, source: .formatDescription)
        )
    }

    func testAllRecognizedCoreVideoDetailsMapToSignaledDisplayOrder() throws {
        let expectations: [(CFString, FieldParity)] = [
            (kCVImageBufferFieldDetailTemporalTopFirst, .top),
            (kCVImageBufferFieldDetailTemporalBottomFirst, .bottom),
            (kCVImageBufferFieldDetailSpatialFirstLineEarly, .top),
            (kCVImageBufferFieldDetailSpatialFirstLineLate, .bottom),
        ]

        for (detail, expectedParity) in expectations {
            let pixelBuffer = try VideoTestFactories.nv12(
                fieldCount: number(2),
                detail: detail
            )
            XCTAssertEqual(
                FieldMetadataReader().read(formatDescription: nil, pixelBuffer: pixelBuffer),
                FieldMetadataEvidence(
                    fieldCount: 2,
                    fieldOrder: order(expectedParity, confidence: .signaled, source: .pixelBuffer),
                    source: .pixelBuffer
                ),
                "detail: \(detail)"
            )
        }
    }

    func testPixelBufferTemporalBottomFirstOverridesConflictingFormatSpatialTopHint() throws {
        let format = try VideoTestFactories.formatDescription(
            fieldCount: number(2),
            detail: kCVImageBufferFieldDetailSpatialFirstLineEarly
        )
        let pixelBuffer = try VideoTestFactories.nv12(
            fieldCount: number(2),
            detail: kCVImageBufferFieldDetailTemporalBottomFirst
        )

        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: format, pixelBuffer: pixelBuffer),
            FieldMetadataEvidence(
                fieldCount: 2,
                fieldOrder: order(.bottom, confidence: .signaled, source: .pixelBuffer),
                source: .pixelBuffer
            )
        )
    }

    func testFormatDescriptionIsUsedWhenPixelBufferHasNoFieldMetadata() throws {
        let format = try VideoTestFactories.formatDescription(
            fieldCount: number(2),
            detail: kCVImageBufferFieldDetailTemporalTopFirst
        )
        let pixelBuffer = try VideoTestFactories.nv12()

        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: format, pixelBuffer: pixelBuffer),
            FieldMetadataEvidence(
                fieldCount: 2,
                fieldOrder: order(.top, confidence: .signaled, source: .formatDescription),
                source: .formatDescription
            )
        )
    }

    func testFieldCountOtherThanTwoDiscardsRecognizedDetail() throws {
        let pixelBuffer = try VideoTestFactories.nv12(
            fieldCount: number(1),
            detail: kCVImageBufferFieldDetailTemporalBottomFirst
        )

        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: nil, pixelBuffer: pixelBuffer),
            FieldMetadataEvidence(fieldCount: 1, fieldOrder: nil, source: .pixelBuffer)
        )
    }

    func testDetailWithoutCountDoesNotClaimOrderOrBorrowFormatCount() throws {
        let format = try VideoTestFactories.formatDescription(
            fieldCount: number(2),
            detail: kCVImageBufferFieldDetailTemporalTopFirst
        )
        let pixelBuffer = try VideoTestFactories.nv12(
            detail: kCVImageBufferFieldDetailTemporalBottomFirst
        )

        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: format, pixelBuffer: pixelBuffer),
            FieldMetadataEvidence(fieldCount: nil, fieldOrder: nil, source: .pixelBuffer)
        )
    }

    func testPixelCountWithoutDetailDoesNotBorrowFormatDetail() throws {
        let format = try VideoTestFactories.formatDescription(
            fieldCount: number(2),
            detail: kCVImageBufferFieldDetailTemporalTopFirst
        )
        let pixelBuffer = try VideoTestFactories.nv12(fieldCount: number(2))

        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: format, pixelBuffer: pixelBuffer),
            FieldMetadataEvidence(fieldCount: 2, fieldOrder: nil, source: .pixelBuffer)
        )
    }

    func testMalformedAndUnrecognizedValuesAreConservative() throws {
        let malformedCount = try VideoTestFactories.nv12(
            fieldCount: "two" as CFString,
            detail: kCVImageBufferFieldDetailTemporalTopFirst
        )
        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: nil, pixelBuffer: malformedCount),
            FieldMetadataEvidence(fieldCount: nil, fieldOrder: nil, source: .pixelBuffer)
        )

        let unrecognizedDetail = try VideoTestFactories.formatDescription(
            fieldCount: number(2),
            detail: "unknown-field-detail" as CFString
        )
        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: unrecognizedDetail, pixelBuffer: nil),
            FieldMetadataEvidence(fieldCount: 2, fieldOrder: nil, source: .formatDescription)
        )

        let booleanCount = try VideoTestFactories.nv12(
            fieldCount: kCFBooleanTrue,
            detail: kCVImageBufferFieldDetailSpatialFirstLineEarly
        )
        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: nil, pixelBuffer: booleanCount),
            FieldMetadataEvidence(fieldCount: nil, fieldOrder: nil, source: .pixelBuffer)
        )
    }

    func testNoMetadataProducesEmptyEvidence() throws {
        let format = try VideoTestFactories.formatDescription()
        let pixelBuffer = try VideoTestFactories.nv12()

        XCTAssertEqual(
            FieldMetadataReader().read(formatDescription: format, pixelBuffer: pixelBuffer),
            FieldMetadataEvidence(fieldCount: nil, fieldOrder: nil, source: .none)
        )
    }

    func testPublicValueContractsExposeInitializersEqualityAndSendability() {
        let resolved = order(.bottom, confidence: .detected, source: .contentProbe)
        let decodedFields = FieldMetadataEvidence(
            fieldCount: 2,
            fieldOrder: resolved,
            source: .contentProbe
        )
        let probe = ContentProbeSample(combRatio: 0.25, motionRatio: 0.5, sampleCount: 144)
        let parser = VideoParserMetadata(
            fieldOrder: .tb,
            pictureStructure: .frame,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: false,
            sourcePTS90k: 3_600
        )
        let observation = ScanObservation(
            generation: MediaGeneration(rawValue: 9),
            parser: parser,
            decodedFields: decodedFields,
            probe: probe,
            presentationTimeStamp: CMTime(value: 1, timescale: 25)
        )

        XCTAssertEqual(resolved, order(.bottom, confidence: .detected, source: .contentProbe))
        XCTAssertEqual(decodedFields.fieldOrder, resolved)
        XCTAssertEqual(probe, ContentProbeSample(combRatio: 0.25, motionRatio: 0.5, sampleCount: 144))
        XCTAssertEqual(observation.generation, MediaGeneration(rawValue: 9))
        XCTAssertEqual(observation.parser, parser)
        XCTAssertEqual(observation.decodedFields, decodedFields)
        XCTAssertEqual(observation.probe, probe)
        XCTAssertEqual(observation.presentationTimeStamp, CMTime(value: 1, timescale: 25))
        XCTAssertEqual(ScanType.interlaced(resolved), ScanType.interlaced(resolved))
        XCTAssertEqual(ScanType.progressiveSegmentedFrame(nil), .progressiveSegmentedFrame(nil))
        XCTAssertEqual(PresentationOrigin.metalYADIF(field: .bottom), .metalYADIF(field: .bottom))

        requireSendable(FieldParity.self)
        requireSendable(FieldOrderConfidence.self)
        requireSendable(FieldEvidenceSource.self)
        requireSendable(ResolvedFieldOrder.self)
        requireSendable(ScanType.self)
        requireSendable(FieldMetadataEvidence.self)
        requireSendable(ContentProbeSample.self)
        requireSendable(ScanObservation.self)
        requireSendable(PresentationOrigin.self)
    }

    func testPresentationOriginRemainsSeparateFromPresentationFrame() throws {
        let frame = VideoPresentationFrame(
            storage: .pixelBuffer(try VideoTestFactories.nv12()),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 25),
            generation: MediaGeneration(rawValue: 1),
            sequenceNumber: 1,
            sourceAccessUnitID: 1,
            formatMetadata: VideoFormatMetadata(
                dimensions: CMVideoDimensions(width: 64, height: 36),
                bitDepth: 8,
                range: .video,
                matrix: .bt709,
                transfer: .bt709,
                primaries: .bt709,
                cleanAperture: nil,
                chromaLocation: .init(topField: nil, bottomField: nil),
                hdrStaticMetadata: .init(
                    masteringDisplayColorVolume: nil,
                    contentLightLevelInfo: nil
                )
            )
        )

        XCTAssertFalse(Mirror(reflecting: frame).children.contains { $0.label == "origin" })
    }

    private func order(
        _ parity: FieldParity,
        confidence: FieldOrderConfidence,
        source: FieldEvidenceSource
    ) -> ResolvedFieldOrder {
        ResolvedFieldOrder(parity: parity, confidence: confidence, source: source)
    }

    private func number(_ value: Int32) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value)
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}
}
