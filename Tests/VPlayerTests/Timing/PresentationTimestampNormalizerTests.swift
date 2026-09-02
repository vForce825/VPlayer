// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class PresentationTimestampNormalizerTests: XCTestCase {
    func testMissingVideoPTSWaitsForFirstAudioOriginAndStartsOnThatTimeline() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(2)
        sut.beginAwaitingAudioTimelineOrigin()

        XCTAssertTrue(sut.push(
            try decodedFrame(id: 1, pts90k: nil),
            discontinuity: false
        ).isEmpty)
        XCTAssertTrue(sut.push(
            try decodedFrame(id: 2, pts90k: nil),
            discontinuity: false
        ).isEmpty)

        let output = sut.observeAudioTimelineOrigin(CMTime(value: 10, timescale: 1))

        XCTAssertEqual(output.map(ptsValue), [900_000, 903_600])
        XCTAssertTrue(output.allSatisfy(\.timingWasSynthesized))
    }

    func testTrustedVideoPTSIsNotShiftedByAudioOrigin() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        _ = sut.observeAudioTimelineOrigin(CMTime(value: 10, timescale: 1))

        let output = sut.push(
            try decodedFrame(id: 1, pts90k: 1_080_000),
            discontinuity: false
        ) + sut.drain()

        XCTAssertEqual(output.map(ptsValue), [1_080_000])
        XCTAssertFalse(try XCTUnwrap(output.first).timingWasSynthesized)
    }

    func testDecoderGenerationRebindPreservesTimelineCursorAndAudioOrigin() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(2)
        XCTAssertTrue(sut.push(
            try decodedFrame(id: 1, pts90k: nil),
            discontinuity: false
        ).isEmpty)
        XCTAssertEqual(
            sut.observeAudioTimelineOrigin(CMTime(value: 10, timescale: 1)).map(ptsValue),
            [900_000]
        )

        sut.rebindDecoderGeneration(generation(2))
        XCTAssertTrue(sut.push(
            try decodedFrame(id: 2, pts90k: nil, generation: 2),
            discontinuity: false
        ).isEmpty)

        XCTAssertEqual(sut.drain().map(ptsValue), [903_600])
    }

    func testAudioOriginWaitRetainsAtMostSixteenMissingPTSFrames() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(8)
        sut.beginAwaitingAudioTimelineOrigin()
        for index in 0..<17 {
            XCTAssertTrue(sut.push(
                try decodedFrame(id: UInt64(index), pts90k: nil),
                discontinuity: false
            ).isEmpty)
        }

        let output = sut.observeAudioTimelineOrigin(CMTime(value: 10, timescale: 1))

        XCTAssertEqual(output.count, 16)
        XCTAssertEqual(output.first?.frame.accessUnitID, 1)
        XCTAssertEqual(output.first.map(ptsValue), 900_000)
    }

    func testReordersBFramesByTransportPTSNotCallbackOrder() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(7))
        sut.configureMaximumReorderDepth(4)
        let frames = try [
            decodedFrame(id: 1, pts90k: 7_200, generation: 7),
            decodedFrame(id: 2, pts90k: 3_600, generation: 7),
            decodedFrame(id: 3, pts90k: 10_800, generation: 7),
        ]

        let output = frames.flatMap { sut.push($0, discontinuity: false) } + sut.drain()

        XCTAssertEqual(output.map(ptsValue), [3_600, 7_200, 10_800])
        XCTAssertEqual(output.map(\.provenance), [
            .trustedPresentationCadence,
            .trustedPresentationCadence,
            .trustedPresentationCadence,
        ])
        XCTAssertEqual(
            output.map(\.frameDuration),
            Array(repeating: CMTime(value: 1, timescale: 25), count: 3)
        )
    }

    func testReordersBFramesAcrossEstablishedThirtyThreeBitWrapEpoch() throws {
        let modulus: UInt64 = 1 << 33
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(8)
        let frames = try [
            decodedFrame(id: 0, rawPTS90k: modulus - 10_800),
            decodedFrame(id: 1, rawPTS90k: modulus - 3_600),
            decodedFrame(id: 2, rawPTS90k: modulus - 7_200),
            decodedFrame(id: 3, rawPTS90k: 0),
        ]

        let output = frames.flatMap { sut.push($0, discontinuity: false) } + sut.drain()

        XCTAssertEqual(output.map { $0.frame.accessUnitID }, [0, 2, 1, 3])
        XCTAssertEqual(output.map(ptsValue), [
            Int64(modulus - 10_800),
            Int64(modulus - 7_200),
            Int64(modulus - 3_600),
            Int64(modulus),
        ])
    }

    func testEqualTransportPTSUsesAccessUnitIDAsDeterministicTieBreak() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(4)
        let frames = try [
            decodedFrame(id: 9, pts90k: 3_600),
            decodedFrame(id: 4, pts90k: 3_600),
            decodedFrame(id: 7, pts90k: 3_600),
        ]

        let output = frames.flatMap { sut.push($0, discontinuity: false) } + sut.drain()

        XCTAssertEqual(output.map { $0.frame.accessUnitID }, [4, 7, 9])
        XCTAssertEqual(output.map(ptsValue), [3_600, 7_200, 10_800])
        XCTAssertEqual(output.map(\.timingWasSynthesized), [false, true, true])
    }

    func testMissingTransportPTSIsPlacedAfterTrustedPTSThenByAccessUnitID() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(8)
        let frames = try [
            decodedFrame(id: 9, pts90k: nil),
            decodedFrame(id: 8, pts90k: 7_200),
            decodedFrame(id: 3, pts90k: nil),
            decodedFrame(id: 2, pts90k: 3_600),
        ]

        let output = frames.flatMap { sut.push($0, discontinuity: false) } + sut.drain()

        XCTAssertEqual(output.map { $0.frame.accessUnitID }, [2, 8, 3, 9])
        XCTAssertEqual(output.map(ptsValue), [3_600, 7_200, 10_800, 14_400])
        XCTAssertEqual(output.map(\.timingWasSynthesized), [false, false, true, true])
    }

    func testSourcePTSIsAuthorityInsteadOfDecodedCallbackTimestamp() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        let frame = try decodedFrame(
            id: 1,
            pts90k: 9_000,
            decodedPTS: CMTime(value: 123, timescale: 1)
        )

        let output = sut.push(frame, discontinuity: false) + sut.drain()

        XCTAssertEqual(output.map(ptsValue), [9_000])
    }

    func testReorderDepthClampsToMinimumTwoAndEmitsOnlyWhenExceeded() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(1)

        XCTAssertTrue(sut.push(try decodedFrame(id: 3, pts90k: 10_800), discontinuity: false).isEmpty)
        XCTAssertTrue(sut.push(try decodedFrame(id: 2, pts90k: 7_200), discontinuity: false).isEmpty)
        let emitted = sut.push(try decodedFrame(id: 1, pts90k: 3_600), discontinuity: false)

        XCTAssertEqual(emitted.map(ptsValue), [3_600])
    }

    func testReorderDepthClampsToMaximumEight() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(99)

        for index in 0..<8 {
            XCTAssertTrue(
                sut.push(
                    try decodedFrame(id: UInt64(index), pts90k: Int64(index * 3_600)),
                    discontinuity: false
                ).isEmpty
            )
        }

        let emitted = sut.push(try decodedFrame(id: 8, pts90k: 28_800), discontinuity: false)
        XCTAssertEqual(emitted.map(ptsValue), [0])
    }

    func testDrainEmitsSortedRemainderAndIsIdempotent() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(8)
        _ = sut.push(try decodedFrame(id: 2, pts90k: 7_200), discontinuity: false)
        _ = sut.push(try decodedFrame(id: 1, pts90k: 3_600), discontinuity: false)

        XCTAssertEqual(sut.drain().map(ptsValue), [3_600, 7_200])
        XCTAssertTrue(sut.drain().isEmpty)
    }

    func testRepairsMissingAndDuplicatePTSWithMedianCadence() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(2))
        // Keep the nil PTS below its latency bound here so this matrix isolates
        // deterministic PTS repair; the continuous-live test covers expiration.
        sut.configureMaximumReorderDepth(3)
        let values: [Int64?] = [0, 3_600, 7_200, nil, 7_200, 14_400]
        let frames = try values.enumerated().map { index, value in
            try decodedFrame(id: UInt64(index), pts90k: value, generation: 2)
        }

        let output = frames.flatMap { sut.push($0, discontinuity: false) } + sut.drain()

        XCTAssertEqual(output.map(ptsValue), [0, 3_600, 7_200, 10_800, 14_400, 18_000])
        XCTAssertEqual(output.map { $0.frame.accessUnitID }, [0, 1, 2, 4, 5, 3])
        XCTAssertEqual(output.filter(\.timingWasSynthesized).count, 2)
    }

    func testMissingPTSExpiresAfterConfiguredDepthOfContinuousTrustedPushes() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(2)
        var output: [NormalizedDecodedFrame] = []
        for index in 0..<3 {
            output += sut.push(
                try decodedFrame(id: UInt64(index), pts90k: Int64(index * 3_600)),
                discontinuity: false
            )
        }
        output += sut.push(try decodedFrame(id: 99, pts90k: nil), discontinuity: false)

        let firstSubsequent = sut.push(
            try decodedFrame(id: 3, pts90k: 10_800),
            discontinuity: false
        )
        let secondSubsequent = sut.push(
            try decodedFrame(id: 4, pts90k: 14_400),
            discontinuity: false
        )
        output += firstSubsequent + secondSubsequent

        XCTAssertEqual(firstSubsequent.map { $0.frame.accessUnitID }, [2])
        XCTAssertEqual(secondSubsequent.map { $0.frame.accessUnitID }, [99])
        XCTAssertEqual(secondSubsequent.map(ptsValue), [10_800])
        XCTAssertEqual(secondSubsequent.map(\.timingWasSynthesized), [true])
        XCTAssertEqual(output.map { $0.frame.accessUnitID }, [0, 1, 2, 99])
    }

    func testDiscontinuityDropsBufferedFramesAndPreservesNewAbsolutePTS() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(2))
        sut.configureMaximumReorderDepth(8)
        _ = sut.push(try decodedFrame(id: 1, pts90k: 900_000, generation: 2), discontinuity: false)

        let immediate = sut.push(
            try decodedFrame(id: 2, pts90k: 1_000, generation: 3),
            discontinuity: true
        )
        let output = immediate + sut.drain()

        XCTAssertEqual(output.map(ptsValue), [1_000])
        XCTAssertEqual(output.map { $0.frame.generation }, [generation(3)])
    }

    func testForwardGenerationDropsBufferedFramesWithoutExplicitDiscontinuity() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(2))
        sut.configureMaximumReorderDepth(8)
        _ = sut.push(try decodedFrame(id: 1, pts90k: 900_000, generation: 2), discontinuity: false)

        _ = sut.push(try decodedFrame(id: 2, pts90k: 4_500, generation: 4), discontinuity: false)

        XCTAssertEqual(sut.drain().map(ptsValue), [4_500])
    }

    func testStaleGenerationIsIgnoredAndCannotRollStateBackward() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(4))
        sut.configureMaximumReorderDepth(8)
        _ = sut.push(try decodedFrame(id: 4, pts90k: 4_500, generation: 4), discontinuity: false)

        let stale = sut.push(
            try decodedFrame(id: 2, pts90k: 900_000, generation: 2),
            discontinuity: true
        )

        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(sut.drain().map(ptsValue), [4_500])
    }

    func testResetClearsTimingHistoryButRetainsNominalAndDepthConfiguration() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureNominalFrameDuration(CMTime(value: 1_001, timescale: 30_000))
        sut.configureMaximumReorderDepth(8)
        _ = sut.push(try decodedFrame(id: 1, pts90k: 0), discontinuity: false)
        _ = sut.push(try decodedFrame(id: 2, pts90k: 3_600), discontinuity: false)
        sut.reset(generation: generation(2))

        for index in 0..<8 {
            XCTAssertTrue(
                sut.push(
                    try decodedFrame(id: UInt64(index), pts90k: nil, generation: 2),
                    discontinuity: false
                ).isEmpty
            )
        }
        let emitted = sut.push(
            try decodedFrame(id: 8, pts90k: nil, generation: 2),
            discontinuity: false
        )

        XCTAssertEqual(emitted.first?.provenance, .configuredNominalDuration)
        XCTAssertEqual(emitted.first?.frameDuration, CMTime(value: 1_001, timescale: 30_000))
    }

    func testCadenceEstimatorUsesLatestSevenSamplesAndSortedMedian() {
        var sut = FrameCadenceEstimator()
        for _ in 0..<7 {
            sut.appendTrustedDelta(CMTime(value: 9_000, timescale: 90_000))
        }
        for _ in 0..<4 {
            sut.appendTrustedDelta(CMTime(value: 3_600, timescale: 90_000))
        }

        XCTAssertEqual(sut.medianFrameDuration, CMTime(value: 3_600, timescale: 90_000))

        sut.reset()
        [3_600, 3_600, 9_000, 1_800, 3_600].forEach {
            sut.appendTrustedDelta(CMTime(value: Int64($0), timescale: 90_000))
        }
        XCTAssertEqual(sut.medianFrameDuration, CMTime(value: 3_600, timescale: 90_000))
    }

    func testCadenceEstimatorRejectsInvalidAndOutOfRangeSamples() {
        var sut = FrameCadenceEstimator()
        let rejected: [CMTime] = [
            .zero,
            CMTime(value: -1, timescale: 25),
            .invalid,
            .indefinite,
            .positiveInfinity,
            CMTime(value: 1, timescale: 300),
            CMTime(value: 1, timescale: 5),
        ]

        rejected.forEach { sut.appendTrustedDelta($0) }

        XCTAssertNil(sut.medianFrameDuration)
        sut.appendTrustedDelta(CMTime(value: 1, timescale: 240))
        sut.appendTrustedDelta(CMTime(value: 1, timescale: 10))
        XCTAssertEqual(sut.medianFrameDuration, CMTime(value: 1, timescale: 10))
    }

    func testDurationFallbackOrderAndExactFieldDurations() throws {
        let callbackDuration = CMTime(value: 1_001, timescale: 30_000)
        var callback = PresentationTimestampNormalizer(generation: generation(1))
        callback.configureNominalFrameDuration(CMTime(value: 1, timescale: 24))
        _ = callback.push(
            try decodedFrame(id: 1, pts90k: 0, duration: callbackDuration),
            discontinuity: false
        )
        let callbackResult = try XCTUnwrap(callback.drain().first)
        XCTAssertEqual(callbackResult.provenance, .decodedCallbackDuration)
        XCTAssertEqual(callbackResult.frameDuration, callbackDuration)
        XCTAssertEqual(callbackResult.fieldDuration, CMTime(value: 1_001, timescale: 60_000))

        var nominal = PresentationTimestampNormalizer(generation: generation(1))
        nominal.configureNominalFrameDuration(CMTime(value: 1_001, timescale: 30_000))
        _ = nominal.push(try decodedFrame(id: 1, pts90k: 0), discontinuity: false)
        let nominalResult = try XCTUnwrap(nominal.drain().first)
        XCTAssertEqual(nominalResult.provenance, .configuredNominalDuration)
        XCTAssertEqual(nominalResult.fieldDuration, CMTime(value: 1_001, timescale: 60_000))

        var fallback = PresentationTimestampNormalizer(generation: generation(1))
        fallback.configureNominalFrameDuration(.indefinite)
        _ = fallback.push(try decodedFrame(id: 1, pts90k: 0), discontinuity: false)
        let fallbackResult = try XCTUnwrap(fallback.drain().first)
        XCTAssertEqual(fallbackResult.provenance, .assumed25i)
        XCTAssertEqual(fallbackResult.frameDuration, CMTime(value: 1, timescale: 25))
        XCTAssertEqual(fallbackResult.fieldDuration, CMTime(value: 1, timescale: 50))
    }

    func testTrustedPresentationCadenceOverridesCallbackAndNominalDurations() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureNominalFrameDuration(CMTime(value: 1, timescale: 24))
        sut.configureMaximumReorderDepth(8)
        for index in 0..<3 {
            _ = sut.push(
                try decodedFrame(
                    id: UInt64(index),
                    pts90k: Int64(index * 3_600),
                    duration: CMTime(value: 1, timescale: 30)
                ),
                discontinuity: false
            )
        }

        let output = sut.drain()

        XCTAssertEqual(output[0].provenance, .trustedPresentationCadence)
        XCTAssertEqual(output[1].provenance, .trustedPresentationCadence)
        XCTAssertEqual(output[1].frameDuration, CMTime(value: 1, timescale: 25))
        XCTAssertEqual(output[2].provenance, .trustedPresentationCadence)
    }

    func testMissingPTSRepairHasNoRationalDriftAcrossOneHundredTwentyFields() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureNominalFrameDuration(CMTime(value: 1_001, timescale: 30_000))
        sut.configureMaximumReorderDepth(8)
        var output: [NormalizedDecodedFrame] = []
        for index in 0..<60 {
            output += sut.push(
                try decodedFrame(id: UInt64(index), pts90k: nil),
                discontinuity: false
            )
        }
        output += sut.drain()

        XCTAssertEqual(output.count, 60)
        XCTAssertTrue(output.allSatisfy { $0.presentationTimeStamp.timescale == 90_000 })
        XCTAssertEqual(output.last?.presentationTimeStamp, CMTime(value: 59 * 1_001, timescale: 30_000))
        let oneHundredTwentiethFieldPTS = CMTimeAdd(
            try XCTUnwrap(output.last?.presentationTimeStamp),
            try XCTUnwrap(output.last?.fieldDuration)
        )
        XCTAssertEqual(oneHundredTwentiethFieldPTS, CMTime(value: 119 * 1_001, timescale: 60_000))
    }

    func testExoticNominalUsesAbsoluteRationalAccumulationBeforeNinetyKilohertzRounding() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureNominalFrameDuration(CMTime(value: 1_001, timescale: 24_000))
        sut.configureMaximumReorderDepth(8)
        var output: [NormalizedDecodedFrame] = []
        for index in 0..<60 {
            output += sut.push(
                try decodedFrame(id: UInt64(index), pts90k: nil),
                discontinuity: false
            )
        }
        output += sut.drain()

        let expectedPTS90k = (0..<60).map { index in
            // 90_000 / 24_000 reduces to 15 / 4. All values are positive,
            // so adding 2 implements half-away-from-zero before division.
            (Int64(index) * 1_001 * 15 + 2) / 4
        }
        XCTAssertEqual(output.map(ptsValue), expectedPTS90k)
        XCTAssertTrue(zip(output, output.dropFirst()).allSatisfy {
            CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
        })
        XCTAssertEqual(output.last?.fieldDuration, CMTime(value: 1_001, timescale: 48_000))
    }

    func testTimingContractsAreSendableValues() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(FrameCadenceEstimator.self)
        requireSendable(TimingProvenance.self)
        requireSendable(NormalizedDecodedFrame.self)
        requireSendable(PresentationTimestampNormalizer.self)
    }
}

private extension PresentationTimestampNormalizerTests {
    func generation(_ rawValue: UInt64) -> MediaGeneration {
        MediaGeneration(rawValue: rawValue)
    }

    func testMultiFieldFramesUseFieldDurationAndSingleFieldStepPTS() throws {
        var sut = PresentationTimestampNormalizer(generation: generation(1))
        sut.configureMaximumReorderDepth(4)
        let frames = try [
            decodedFrame(id: 1, pts90k: 0),
            decodedFrame(id: 1, pts90k: 0),
            decodedFrame(id: 2, pts90k: 3_600),
            decodedFrame(id: 2, pts90k: 3_600),
        ]

        let output = frames.flatMap { sut.push($0, discontinuity: false) } + sut.drain()

        XCTAssertEqual(output.count, 4)
        XCTAssertEqual(output.map(ptsValue), [0, 1_800, 3_600, 5_400])
        XCTAssertEqual(
            output.map(\.frameDuration),
            Array(repeating: CMTime(value: 1, timescale: 50), count: 4)
        )
    }

    func decodedFrame(
        id: UInt64,
        pts90k: Int64?,
        decodedPTS: CMTime = .invalid,
        duration: CMTime = .invalid,
        generation rawGeneration: UInt64 = 1
    ) throws -> DecodedVideoFrame {
        DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: try VideoTestFactories.nv12(),
            presentationTimeStamp: decodedPTS,
            duration: duration,
            generation: generation(rawGeneration),
            parserMetadata: VideoParserMetadata(
                fieldOrder: nil,
                pictureStructure: nil,
                isInterlaced: nil,
                repeatFirstField: false,
                topFieldFirst: nil,
                sourcePTS90k: pts90k.map(UInt64.init)
            ),
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
    }

    func decodedFrame(
        id: UInt64,
        rawPTS90k: UInt64,
        duration: CMTime = .invalid,
        generation rawGeneration: UInt64 = 1
    ) throws -> DecodedVideoFrame {
        try decodedFrame(
            id: id,
            pts90k: Int64(rawPTS90k),
            duration: duration,
            generation: rawGeneration
        )
    }

    func ptsValue(_ output: NormalizedDecodedFrame) -> Int64 {
        XCTAssertEqual(output.presentationTimeStamp.timescale, 90_000)
        return output.presentationTimeStamp.value
    }
}
