// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import XCTest
import VPlayerPlayback

final class ScanTypeClassifierTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 7)

    func testPublicContractsExposeDefaultsEqualityAndSendability() {
        let configuration = ScanClassifierConfiguration()

        XCTAssertEqual(configuration.progressiveConfirmationFrames, 8)
        XCTAssertEqual(configuration.psfConfirmationFrames, 12)
        XCTAssertEqual(configuration.exitInterlacedConfirmationFrames, 12)
        XCTAssertEqual(configuration.combThreshold, 0.08)
        XCTAssertEqual(configuration.psfMaximumCombRatio, 0.02)
        XCTAssertEqual(configuration.motionThreshold, 0.015)
        XCTAssertEqual(configuration, ScanClassifierConfiguration())

        let change = ScanClassificationChange(
            previous: .unknown,
            current: .progressive,
            generation: generation
        )
        XCTAssertEqual(change.previous, .unknown)
        XCTAssertEqual(change.current, .progressive)
        XCTAssertEqual(change.generation, generation)

        requireSendable(ScanClassifierConfiguration.self)
        requireSendable(ScanClassificationChange.self)
        requireSendable(ScanTypeClassifier.self)
    }

    func testProgressiveTransitionsOnlyOnEighthTrustedPicture() {
        var sut = ScanTypeClassifier(generation: generation)

        let transitions = (1...9).map { _ in sut.observe(progressiveObservation())?.current }

        XCTAssertEqual(
            transitions,
            [nil, nil, nil, nil, nil, nil, nil, .progressive, nil]
        )
        XCTAssertEqual(sut.current, .progressive)
    }

    func testSeparatedTopAndBottomPicturesImmediatelyConfirmInterlaced() {
        let cases: [(PictureStructure, CodedFieldOrder, FieldParity)] = [
            (.topField, .tt, .top),
            (.bottomField, .bb, .bottom),
        ]

        for (picture, coded, parity) in cases {
            var sut = ScanTypeClassifier(generation: generation)
            let change = sut.observe(observation(picture: picture, fieldOrder: coded))

            XCTAssertEqual(
                change?.current,
                .interlaced(order(parity, confidence: .signaled, source: .parser))
            )
        }
    }

    func testEachFieldSignalAloneRemainsUnknownWithoutProbe() {
        let candidates = [
            observation(isInterlaced: true),
            observation(fieldOrder: .tt),
            observation(fieldCount: 2),
            observation(decodedOrder: order(.bottom, confidence: .signaled, source: .pixelBuffer)),
        ]

        for candidate in candidates {
            var sut = ScanTypeClassifier(generation: generation)
            for _ in 0..<20 {
                XCTAssertNil(sut.observe(candidate))
            }
            XCTAssertEqual(sut.current, .unknown)
        }
    }

    func testExactCombAndMotionThresholdsImmediatelyConfirmTrueInterlace() {
        var sut = ScanTypeClassifier(generation: generation)

        let change = sut.observe(observation(
            fieldOrder: .bb,
            isInterlaced: true,
            probe: probe(comb: 0.08, motion: 0.015)
        ))

        XCTAssertEqual(
            change?.current,
            .interlaced(order(.bottom, confidence: .signaled, source: .parser))
        )
    }

    func testBelowMotionAndMiddleCombProbesConfirmNeitherRoute() {
        var belowMotion = ScanTypeClassifier(generation: generation)
        XCTAssertNil(belowMotion.observe(observation(
            fieldOrder: .tt,
            isInterlaced: true,
            probe: probe(comb: 0.08, motion: 0.0149)
        )))
        XCTAssertEqual(belowMotion.current, .unknown)

        var middleComb = ScanTypeClassifier(generation: generation)
        for _ in 0..<20 {
            XCTAssertNil(middleComb.observe(observation(
                fieldOrder: .tt,
                isInterlaced: true,
                probe: probe(comb: 0.021, motion: 0.015)
            )))
        }
        XCTAssertEqual(middleComb.current, .unknown)
    }

    func testPsFTransitionsOnlyOnTwelfthConsecutiveMovingLowCombSample() {
        var sut = ScanTypeClassifier(generation: generation)
        let sample = observation(
            fieldOrder: .tt,
            isInterlaced: true,
            probe: probe(comb: 0.02, motion: 0.015)
        )

        let transitions = (1...13).map { _ in sut.observe(sample)?.current }

        XCTAssertEqual(
            transitions,
            [nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
             .progressiveSegmentedFrame(order(.top, confidence: .signaled, source: .parser)), nil]
        )
    }

    func testPsFStreakInterruptionRestartsTheCount() {
        var sut = ScanTypeClassifier(generation: generation)
        let sample = observation(
            fieldCount: 2,
            decodedOrder: order(.bottom, confidence: .signaled, source: .pixelBuffer),
            probe: probe(comb: 0.01, motion: 0.08)
        )

        for _ in 0..<11 { XCTAssertNil(sut.observe(sample)) }
        XCTAssertNil(sut.observe(observation(fieldCount: 2)))
        for _ in 0..<11 { XCTAssertNil(sut.observe(sample)) }
        XCTAssertEqual(
            sut.observe(sample)?.current,
            .progressiveSegmentedFrame(order(.bottom, confidence: .signaled, source: .pixelBuffer))
        )
    }

    func testInterlacedExitsOnlyOnTwelfthTrustedProgressivePicture() {
        var sut = ScanTypeClassifier(generation: generation)
        _ = sut.observe(observation(
            fieldOrder: .tt,
            probe: probe(comb: 0.4, motion: 0.2)
        ))

        let transitions = (1...13).map { _ in sut.observe(progressiveObservation())?.current }

        XCTAssertEqual(
            transitions,
            [nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, .progressive, nil]
        )
    }

    func testPsFExitsOnlyOnTwelfthTrustedProgressivePicture() {
        var sut = confirmedPsFClassifier()

        let transitions = (1...13).map { _ in sut.observe(progressiveObservation())?.current }

        XCTAssertEqual(
            transitions,
            [nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, .progressive, nil]
        )
    }

    func testAmbiguityInterruptsConfirmedRouteExitHysteresis() {
        var sut = confirmedInterlacedClassifier()

        for _ in 0..<11 { XCTAssertNil(sut.observe(progressiveObservation())) }
        XCTAssertNil(sut.observe(observation()))
        for _ in 0..<11 { XCTAssertNil(sut.observe(progressiveObservation())) }
        XCTAssertEqual(sut.current, .interlaced(order(.top, confidence: .signaled, source: .parser)))
        XCTAssertEqual(sut.observe(progressiveObservation())?.current, .progressive)
    }

    func testConclusiveInterlaceImmediatelyOverridesProgressiveAndPsF() {
        var progressive = confirmedProgressiveClassifier()
        XCTAssertEqual(
            progressive.observe(observation(
                fieldOrder: .bb,
                probe: probe(comb: 0.08, motion: 0.015)
            ))?.current,
            .interlaced(order(.bottom, confidence: .signaled, source: .parser))
        )

        var psf = confirmedPsFClassifier()
        XCTAssertEqual(
            psf.observe(observation(
                fieldOrder: .tb,
                probe: probe(comb: 0.3, motion: 0.2)
            ))?.current,
            .interlaced(order(.bottom, confidence: .signaled, source: .parser))
        )
    }

    func testResetAdoptsGenerationClearsStateAndNonmatchingObservationsAreIgnored() {
        var sut = confirmedInterlacedClassifier()
        let next = MediaGeneration(rawValue: generation.rawValue + 1)

        XCTAssertNil(sut.observe(progressiveObservation(generation: next)))
        XCTAssertNotEqual(sut.current, .unknown)

        sut.reset(generation: next)
        XCTAssertEqual(sut.current, .unknown)
        XCTAssertNil(sut.observe(progressiveObservation(generation: generation)))
        for _ in 0..<7 { XCTAssertNil(sut.observe(progressiveObservation(generation: next))) }
        XCTAssertEqual(sut.observe(progressiveObservation(generation: next))?.current, .progressive)
    }

    func testAgreeingExplicitOrdersUseDecodedThenCodedThenTopFieldFirstPrecedence() {
        let decoded = order(.bottom, confidence: .detected, source: .pixelBuffer)
        var withDecoded = ScanTypeClassifier(generation: generation)
        XCTAssertEqual(
            withDecoded.observe(observation(
                fieldOrder: .bb,
                topFieldFirst: false,
                fieldCount: 2,
                decodedOrder: decoded,
                probe: probe(comb: 0.2, motion: 0.2)
            ))?.current,
            .interlaced(decoded)
        )

        var withCoded = ScanTypeClassifier(generation: generation)
        XCTAssertEqual(
            withCoded.observe(observation(
                fieldOrder: .tt,
                topFieldFirst: true,
                probe: probe(comb: 0.2, motion: 0.2)
            ))?.current,
            .interlaced(order(.top, confidence: .signaled, source: .parser))
        )

        var withTopFieldFirst = ScanTypeClassifier(generation: generation)
        XCTAssertEqual(
            withTopFieldFirst.observe(observation(
                topFieldFirst: false,
                probe: probe(comb: 0.2, motion: 0.2)
            ))?.current,
            .interlaced(order(.bottom, confidence: .signaled, source: .parser))
        )
    }

    func testAssumedDecodedOrderDoesNotMaskAgreeingExplicitParserOrder() {
        var sut = ScanTypeClassifier(generation: generation)

        XCTAssertEqual(
            sut.observe(observation(
                fieldOrder: .tt,
                fieldCount: 2,
                decodedOrder: order(.top, confidence: .assumed, source: .contentProbe),
                probe: probe(comb: 0.2, motion: 0.2)
            ))?.current,
            .interlaced(order(.top, confidence: .signaled, source: .parser))
        )
    }

    func testOrderConflictAndAbsenceUseAssumedTopFallbackForTrueInterlace() {
        let assumed = order(.top, confidence: .assumed, source: .contentProbe)

        var conflicting = ScanTypeClassifier(generation: generation)
        XCTAssertEqual(
            conflicting.observe(observation(
                fieldOrder: .tt,
                topFieldFirst: false,
                probe: probe(comb: 0.2, motion: 0.2)
            ))?.current,
            .interlaced(assumed)
        )

        var absent = ScanTypeClassifier(generation: generation)
        XCTAssertEqual(
            absent.observe(observation(probe: probe(comb: 0.2, motion: 0.2)))?.current,
            .interlaced(assumed)
        )
    }

    func testAssumedInterlaceOrderCanRefineButExplicitOrderResistsContradiction() {
        var sut = ScanTypeClassifier(generation: generation)
        _ = sut.observe(observation(probe: probe(comb: 0.2, motion: 0.2)))

        let explicitTop = order(.top, confidence: .signaled, source: .parser)
        let refinement = sut.observe(observation(fieldOrder: .tt))
        XCTAssertEqual(refinement?.previous, .interlaced(order(.top, confidence: .assumed, source: .contentProbe)))
        XCTAssertEqual(refinement?.current, .interlaced(explicitTop))

        XCTAssertNil(sut.observe(observation(
            fieldOrder: .bb,
            probe: probe(comb: 0.3, motion: 0.2)
        )))
        XCTAssertEqual(sut.current, .interlaced(explicitTop))
    }

    func testTopFieldFirstAloneRefinesAssumedOrderAndResetsProgressiveExitStreak() {
        var sut = ScanTypeClassifier(generation: generation)
        _ = sut.observe(observation(probe: probe(comb: 0.2, motion: 0.2)))
        for _ in 0..<11 { XCTAssertNil(sut.observe(progressiveObservation())) }

        XCTAssertEqual(
            sut.observe(observation(topFieldFirst: false))?.current,
            .interlaced(order(.bottom, confidence: .signaled, source: .parser))
        )

        for _ in 0..<11 { XCTAssertNil(sut.observe(progressiveObservation())) }
        XCTAssertEqual(
            sut.current,
            .interlaced(order(.bottom, confidence: .signaled, source: .parser))
        )
        XCTAssertEqual(sut.observe(progressiveObservation())?.current, .progressive)
    }

    func testProgressiveExitEventDoesNotExposeAnUnemittedOrderRefinement() {
        let assumed = order(.top, confidence: .assumed, source: .contentProbe)
        var sut = ScanTypeClassifier(generation: generation)
        _ = sut.observe(observation(probe: probe(comb: 0.2, motion: 0.2)))
        for _ in 0..<11 { XCTAssertNil(sut.observe(progressiveObservation())) }

        let change = sut.observe(observation(
            picture: .frame,
            fieldOrder: .progressive,
            isInterlaced: false,
            topFieldFirst: false
        ))

        XCTAssertEqual(change?.previous, .interlaced(assumed))
        XCTAssertEqual(change?.current, .progressive)
        XCTAssertEqual(sut.current, .progressive)
    }

    func testConflictingPsFOrderRemainsNilAndIsHeldThroughAmbiguity() {
        var sut = ScanTypeClassifier(generation: generation)
        let conflictingSample = observation(
            fieldOrder: .tt,
            isInterlaced: true,
            topFieldFirst: false,
            probe: probe(comb: 0.01, motion: 0.08)
        )

        for _ in 0..<11 { XCTAssertNil(sut.observe(conflictingSample)) }
        XCTAssertEqual(sut.observe(conflictingSample)?.current, .progressiveSegmentedFrame(nil))
        XCTAssertNil(sut.observe(observation(fieldOrder: .bb)))
        XCTAssertEqual(sut.current, .progressiveSegmentedFrame(nil))
    }

    func testInvalidProbeValuesAndSampleCountsAreIgnoredRatherThanClamped() {
        let invalidProbes = [
            probe(comb: .nan, motion: 0.2),
            probe(comb: 0.2, motion: .infinity),
            probe(comb: -0.1, motion: 0.2),
            probe(comb: 1.1, motion: 0.2),
            probe(comb: 0.2, motion: -0.1),
            probe(comb: 0.2, motion: 1.1),
            probe(comb: 0.2, motion: 0.2, sampleCount: 0),
            probe(comb: 0.2, motion: 0.2, sampleCount: -1),
        ]

        for invalid in invalidProbes {
            var sut = ScanTypeClassifier(generation: generation)
            for _ in 0..<20 {
                XCTAssertNil(sut.observe(observation(
                    fieldOrder: .tt,
                    isInterlaced: true,
                    probe: invalid
                )))
            }
            XCTAssertEqual(sut.current, .unknown)
        }
    }

    func testZeroAndNegativeCustomCountsHaveEffectiveMinimumOne() {
        let configuration = ScanClassifierConfiguration(
            progressiveConfirmationFrames: 0,
            psfConfirmationFrames: -4,
            exitInterlacedConfirmationFrames: 0
        )

        var progressive = ScanTypeClassifier(generation: generation, configuration: configuration)
        XCTAssertEqual(progressive.observe(progressiveObservation())?.current, .progressive)

        var psf = ScanTypeClassifier(generation: generation, configuration: configuration)
        XCTAssertEqual(
            psf.observe(observation(
                fieldOrder: .tt,
                probe: probe(comb: 0.01, motion: 0.08)
            ))?.current,
            .progressiveSegmentedFrame(order(.top, confidence: .signaled, source: .parser))
        )
        XCTAssertEqual(psf.observe(progressiveObservation())?.current, .progressive)
    }

    func testFrameCodingDecodedFieldCountOneAndAbsentFlagsAreNotTrustedProgressive() {
        let ambiguous = [
            observation(picture: .frame),
            observation(fieldCount: 1),
            observation(),
        ]

        for sample in ambiguous {
            var sut = ScanTypeClassifier(generation: generation)
            for _ in 0..<20 { XCTAssertNil(sut.observe(sample)) }
            XCTAssertEqual(sut.current, .unknown)
        }
    }

    func testConflictingParserProgressiveAndDecodedFieldSignalIsNotTrustedProgressive() {
        var sut = ScanTypeClassifier(generation: generation)
        let conflict = observation(
            picture: .frame,
            fieldOrder: .progressive,
            isInterlaced: false,
            fieldCount: 2
        )

        for _ in 0..<20 { XCTAssertNil(sut.observe(conflict)) }
        XCTAssertEqual(sut.current, .unknown)
    }

    private func confirmedProgressiveClassifier() -> ScanTypeClassifier {
        var sut = ScanTypeClassifier(generation: generation)
        for _ in 0..<8 { _ = sut.observe(progressiveObservation()) }
        return sut
    }

    private func confirmedInterlacedClassifier() -> ScanTypeClassifier {
        var sut = ScanTypeClassifier(generation: generation)
        _ = sut.observe(observation(
            fieldOrder: .tt,
            probe: probe(comb: 0.2, motion: 0.2)
        ))
        return sut
    }

    private func confirmedPsFClassifier() -> ScanTypeClassifier {
        var sut = ScanTypeClassifier(generation: generation)
        let sample = observation(
            fieldOrder: .tt,
            isInterlaced: true,
            probe: probe(comb: 0.01, motion: 0.08)
        )
        for _ in 0..<12 { _ = sut.observe(sample) }
        return sut
    }

    private func progressiveObservation(
        generation: MediaGeneration? = nil
    ) -> ScanObservation {
        observation(
            generation: generation,
            picture: .frame,
            fieldOrder: .progressive,
            isInterlaced: false
        )
    }

    private func observation(
        generation suppliedGeneration: MediaGeneration? = nil,
        picture: PictureStructure? = nil,
        fieldOrder: CodedFieldOrder? = nil,
        isInterlaced: Bool? = nil,
        topFieldFirst: Bool? = nil,
        fieldCount: Int? = nil,
        decodedOrder: ResolvedFieldOrder? = nil,
        probe: ContentProbeSample? = nil
    ) -> ScanObservation {
        let source: FieldEvidenceSource = if decodedOrder != nil || fieldCount != nil {
            .pixelBuffer
        } else {
            .none
        }
        return ScanObservation(
            generation: suppliedGeneration ?? generation,
            parser: VideoParserMetadata(
                fieldOrder: fieldOrder,
                pictureStructure: picture,
                isInterlaced: isInterlaced,
                repeatFirstField: false,
                topFieldFirst: topFieldFirst,
                sourcePTS90k: nil
            ),
            decodedFields: FieldMetadataEvidence(
                fieldCount: fieldCount,
                fieldOrder: decodedOrder,
                source: source
            ),
            probe: probe,
            presentationTimeStamp: .zero
        )
    }

    private func probe(
        comb: Float,
        motion: Float,
        sampleCount: Int = 2_304
    ) -> ContentProbeSample {
        ContentProbeSample(combRatio: comb, motionRatio: motion, sampleCount: sampleCount)
    }

    private func order(
        _ parity: FieldParity,
        confidence: FieldOrderConfidence,
        source: FieldEvidenceSource
    ) -> ResolvedFieldOrder {
        ResolvedFieldOrder(parity: parity, confidence: confidence, source: source)
    }

    private func requireSendable<T: Sendable>(_: T.Type) {}
}
