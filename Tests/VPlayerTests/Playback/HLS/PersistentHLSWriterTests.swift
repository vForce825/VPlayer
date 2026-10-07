// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class PersistentHLSWriterTests: XCTestCase {
    func testRemuxWriterByteBudgetUsesDeclaredRateAndExactFrozenFrameDuration() throws {
        for (count, rate, duration, charge, expected) in [
            (180, UInt64(25_500_000), ExactMediaTime(value: 1, timescale: 30), 648_828 + 64, 19_349_148),
            (300, UInt64(40_800_000), ExactMediaTime(value: 1, timescale: 50), 552_086 + 64, 30_823_328),
        ] {
            let budget = try WriterRemuxByteBudget(segmentInputCount: count,
                declaredBitsPerSecond: rate, frameDuration: duration)
            XCTAssertEqual(budget.maximumSegmentBytes, expected)
            XCTAssertEqual(try budget.forwardBytes(maximumInputBytes: charge), expected)
            XCTAssertGreaterThan((2 * count + 2) * charge, FMP4WriterLimits.video.writerHardByteCount)
            XCTAssertLessThan(expected, FMP4WriterLimits.video.writerHardByteCount)
        }
        let fractional = try WriterRemuxByteBudget(segmentInputCount: 1,
            declaredBitsPerSecond: 1, frameDuration: .init(value: 1, timescale: 3))
        XCTAssertEqual(fractional.maximumSegmentBytes, 193, "fractional payload bytes round up exactly")
    }

    func testRemuxWriterByteBudgetKeepsSmallHighLevelStreamsOnObservedMaximum() throws {
        let budget = try WriterRemuxByteBudget(segmentInputCount: 300,
            declaredBitsPerSecond: 81_600_000, frameDuration: .init(value: 1, timescale: 50))
        XCTAssertEqual(try budget.forwardBytes(maximumInputBytes: 128), 302 * 128)
        XCTAssertEqual(try budget.forwardBytes(maximumInputBytes: 256,
            currentSegmentBytes: 1_280, currentSegmentInputCount: 10, nextInputBytes: 256), 292 * 256)
        XCTAssertEqual(try budget.forwardBytes(maximumInputBytes: 552_150), budget.maximumSegmentBytes)
    }

    func testRemuxWriterByteBudgetAcceptsExactCeilingAndRejectsOneByteMore() throws {
        let budget = try WriterRemuxByteBudget(segmentInputCount: 1,
            declaredBitsPerSecond: 8, frameDuration: .init(value: 1, timescale: 1))
        XCTAssertEqual(budget.maximumSegmentBytes, 195)
        XCTAssertEqual(try budget.forwardBytes(maximumInputBytes: 195, nextInputBytes: 195), 195)
        XCTAssertEqual(try budget.forwardBytes(maximumInputBytes: 195,
            currentSegmentBytes: 130, currentSegmentInputCount: 1, nextInputBytes: 65), 65)
        for (used, incoming) in [(0, 196), (130, 66), (195, 1)] {
            XCTAssertThrowsError(try budget.forwardBytes(maximumInputBytes: 196,
                currentSegmentBytes: used, currentSegmentInputCount: used == 0 ? 0 : 1,
                nextInputBytes: incoming)) {
                XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .terminalOwnershipCapacityExceeded)
            }
        }
    }

    func testRemuxWriterByteBudgetRejectsOverflowWithoutWrappingOrRoundingDown() throws {
        for (count, rate, duration) in [
            (Int.max, UInt64(1), ExactMediaTime(value: 1, timescale: 1)),
            (Int.max - 2, UInt64.max, ExactMediaTime(value: Int64.max, timescale: 1)),
            (1, UInt64.max, ExactMediaTime(value: 8, timescale: 1)),
        ] {
            XCTAssertThrowsError(try WriterRemuxByteBudget(segmentInputCount: count,
                declaredBitsPerSecond: rate, frameDuration: duration)) {
                XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .arithmeticOverflow)
            }
        }
        let budget = try WriterRemuxByteBudget(segmentInputCount: 180,
            declaredBitsPerSecond: 25_500_000, frameDuration: .init(value: 1, timescale: 30))
        // A saturated observed-maximum product still has the exact finite ceiling.
        XCTAssertEqual(try budget.forwardBytes(maximumInputBytes: Int.max), budget.maximumSegmentBytes)
        XCTAssertThrowsError(try budget.forwardBytes(maximumInputBytes: 1,
            currentSegmentBytes: Int.max, nextInputBytes: 1))
        XCTAssertThrowsError(try WriterRemuxByteBudget(segmentInputCount: 0,
            declaredBitsPerSecond: 1, frameDuration: .init(value: 1, timescale: 1)))
        XCTAssertThrowsError(try WriterRemuxByteBudget(segmentInputCount: 1,
            declaredBitsPerSecond: 0, frameDuration: .init(value: 1, timescale: 1)))
    }

    func testFiveAndSixSecondHeadroomHasExplicitLiveAndEvidenceBounds() throws {
        for seconds in [5, 6] {
            let segment = (48_000 * seconds + 1_023) / 1_024
            let reserve = try WriterBoundaryReserve(samplesPerSecond: 48_000, samplesPerAccessUnit: 1_024,
                maximumBoundarySeconds: seconds, delayedPreviousInputs: segment, pendingPumpInputs: 32,
                interleavedInputs: 2, maximumInputBytes: 512, pendingOutputCallbacks: 3)
            XCTAssertEqual(reserve.segmentInputCount, segment)
            XCTAssertEqual(reserve.inputCount, segment * 2 + 34)
            XCTAssertTrue(reserve.fits(inputCapacity: 640, evidenceCapacity: 320,
                inputByteCapacity: 8 * 1_024 * 1_024, outputCallbackCapacity: 3))
        }
        let unsupported = try WriterBoundaryReserve(samplesPerSecond: 120, samplesPerAccessUnit: 1,
            maximumBoundarySeconds: 5, delayedPreviousInputs: 600, pendingPumpInputs: 0,
            interleavedInputs: 2, maximumInputBytes: 512, pendingOutputCallbacks: 3)
        XCTAssertFalse(unsupported.fits(inputCapacity: 1_024, evidenceCapacity: 512,
            inputByteCapacity: 64 * 1_024 * 1_024, outputCallbackCapacity: 3))
    }

    func testOrdinaryBoundariesPersistButPressureRequiresLegalCut() {
        let capacity = WriterCapacitySnapshot(liveCount: 0, liveBytes: 0, hardCount: 640,
            hardBytes: 8 * 1_024 * 1_024, nextBoundaryReserveCount: 316,
            nextBoundaryReserveBytes: 316 * 512, pendingCallbacks: 0, callbackCapacity: 3)
        for sequence in 1...300 {
            XCTAssertEqual(WriterContinuationPolicy.decide(boundary: .init(isSafeBoundary: true,
                nextNativeSequence: sequence), capacity: capacity, formatChanged: false), .continueCurrent)
        }
        var full = capacity; full.liveCount = 640
        XCTAssertEqual(WriterContinuationPolicy.decide(boundary: .init(isSafeBoundary: true,
            nextNativeSequence: 301), capacity: full, formatChanged: false), .rolloverAtBoundary)
        XCTAssertEqual(WriterContinuationPolicy.decide(boundary: .init(isSafeBoundary: false,
            nextNativeSequence: 301), capacity: full, formatChanged: false), .rejectUnsupported)
        XCTAssertEqual(WriterContinuationPolicy.decide(boundary: .init(isSafeBoundary: true,
            nextNativeSequence: 1_000_001), capacity: capacity, formatChanged: false), .newGeneration)
        XCTAssertFalse(HLSWriterSequencePolicy.supportedRange.contains(0))
        XCTAssertFalse(HLSWriterSequencePolicy.supportedRange.contains(Int(UInt32.max)))
    }

    func testProductionBoundaryTransitionAdmitsEverySampleOfFinalNativeSegmentThenFencesNextCut() throws {
        let capacity = WriterCapacitySnapshot(liveCount: 0, liveBytes: 0, hardCount: 1_024,
            hardBytes: 64 * 1_024 * 1_024, nextBoundaryReserveCount: 122,
            nextBoundaryReserveBytes: 122 * 512, pendingCallbacks: 0, callbackCapacity: 3)
        let enteringFinal = try WriterBoundaryState.beforeAppend(isSafeBoundary: true,
            currentNativeSequence: 999_999, hasCurrentSegment: true)
        XCTAssertEqual(enteringFinal.nextNativeSequence, 1_000_000)
        XCTAssertEqual(WriterContinuationPolicy.decide(boundary: enteringFinal,
            capacity: capacity, formatChanged: false), .continueCurrent)
        for _ in 1..<120 {
            let insideFinal = try WriterBoundaryState.beforeAppend(isSafeBoundary: false,
                currentNativeSequence: enteringFinal.nextNativeSequence, hasCurrentSegment: true)
            XCTAssertEqual(insideFinal.nextNativeSequence, 1_000_000)
            XCTAssertEqual(WriterContinuationPolicy.decide(boundary: insideFinal,
                capacity: capacity, formatChanged: false), .continueCurrent)
        }
        let afterFinal = try WriterBoundaryState.beforeAppend(isSafeBoundary: true,
            currentNativeSequence: 1_000_000, hasCurrentSegment: true)
        XCTAssertEqual(afterFinal.nextNativeSequence, 1_000_001)
        XCTAssertEqual(WriterContinuationPolicy.decide(boundary: afterFinal,
            capacity: capacity, formatChanged: false), .newGeneration)
        let emptySuccessor = try WriterBoundaryState.beforeAppend(isSafeBoundary: true,
            currentNativeSequence: 1_000_000, hasCurrentSegment: false)
        XCTAssertEqual(emptySuccessor.nextNativeSequence, 1_000_000)
        XCTAssertEqual(WriterContinuationPolicy.decide(boundary: emptySuccessor,
            capacity: capacity, formatChanged: false), .continueCurrent)
        for invalid in [0, Int(UInt32.max), Int.max] {
            XCTAssertThrowsError(try WriterBoundaryState.beforeAppend(isSafeBoundary: true,
                currentNativeSequence: invalid, hasCurrentSegment: true))
        }
    }

    func testFullCallbackLaneIsBoundedBackpressureRatherThanUnsupportedProfile() {
        var capacity = WriterCapacitySnapshot(liveCount: 1, liveBytes: 512, hardCount: 1_024,
            hardBytes: 64 * 1_024 * 1_024, nextBoundaryReserveCount: 122,
            nextBoundaryReserveBytes: 122 * 512, pendingCallbacks: 3, callbackCapacity: 3)
        for safe in [false, true] {
            XCTAssertEqual(WriterContinuationPolicy.decide(boundary: .init(isSafeBoundary: safe,
                nextNativeSequence: 4), capacity: capacity, formatChanged: false), .backpressure)
        }
        capacity.pendingCallbacks = 2
        XCTAssertEqual(WriterContinuationPolicy.decide(boundary: .init(isSafeBoundary: true,
            nextNativeSequence: 4), capacity: capacity, formatChanged: false), .continueCurrent)
    }

    func testNearLimitAACProfileRecoversOnlyAfterAcceptedFrozenAndNativePrefixRetire() throws {
        let profile = try AACWriterBoundaryProfile(maximumBoundarySeconds: 6,
            maximumNativePacketBytes: 1_708)
        let workspace = AACCalibrationWorkspace()
        let charge = try AACIncrementalEmission.allocationCharge(payloadBytes: 1, packetCount: 1)
        // Keep exactly one byte less than the headroom needed for this accepted
        // prefix, independently of platform packet-description metadata sizes.
        let poolBytes = profile.packetReservationBytes + charge - 1
        XCTAssertLessThanOrEqual(poolBytes, AACCalibrationWorkspace.aacPacketCapacity - 131_072)
        let pool = try workspace.reserveReusablePackets(bytes: poolBytes)
        XCTAssertEqual(pool.capacity - profile.packetReservationBytes, charge - 1)
        let reservation = try pool.reserveAvailable(preferredBytes: charge, minimumBytes: charge)
        var frozen: AACCalibrationWorkspace.Lease? = try reservation.claim(bytes: charge)
        frozen?.markWriterAccepted()
        reservation.releaseUnclaimed()
        var native: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            length: 1, lifetime: WriterInputLifetime { [lease = try XCTUnwrap(frozen)] in
                withExtendedLifetime(lease) {}
            })
        XCTAssertEqual(pool.nextBoundaryCapacity, profile.packetReservationBytes - 1)
        frozen = nil // Exactly what consuming a PendingBatch prefix now does.
        XCTAssertNotNil(native)
        XCTAssertEqual(pool.nextBoundaryCapacity, profile.packetReservationBytes - 1,
            "consuming a batch entry must never free a surviving native alias")
        native = nil
        XCTAssertEqual(pool.nextBoundaryCapacity, pool.capacity)
        XCTAssertEqual(pool.availableBytes, pool.capacity)
        let next = try pool.reserveAvailable(preferredBytes: profile.packetReservationBytes,
            minimumBytes: profile.packetReservationBytes)
        next.releaseUnclaimed()
    }

    func testMissingVideoBoundaryFailsAtDeclaredDeadlineAndCanResumeAfterRealCut() throws {
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: .zero,
            videoMode: .passthrough, maximumPassthroughInterval: CMTime(value: 6, timescale: 1)))
        let rendition = AudioRenditionIdentity(rawValue: 99)
        try boundary.registerAudioRendition(rendition, accessUnit: .aac(sampleRate: 48_000), firstEffectiveStart: .zero)
        _ = try boundary.inspectVideoBoundary(at: .zero, isIDR: true)
        XCTAssertNoThrow(try boundary.inspectAudioBoundary(rendition: rendition,
            at: CMTime(value: 287_744, timescale: 48_000)))
        let before = boundary.inspectionUsage
        XCTAssertThrowsError(try boundary.inspectAudioBoundary(rendition: rendition,
            at: CMTime(value: 6, timescale: 1))) {
            XCTAssertEqual($0 as? SegmentBoundaryFailure, .audioBoundaryExceeded)
        }
        XCTAssertEqual(boundary.inspectionUsage, before)
        _ = try boundary.inspectVideoBoundary(at: CMTime(value: 6, timescale: 1), isIDR: true)
        XCTAssertTrue(try boundary.inspectAudioBoundary(rendition: rendition,
            at: CMTime(value: 6, timescale: 1)).requiresFlushBeforeAppend)
    }

    func testAAC640PlusOneUsesMetadataNotAnotherPayloadCharge() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputs = WriterInputAdmission(capacity: 640, maximumBytes: 640 * 8_192, applicationLedger: ledger)
        var held: [WriterInputLifetime] = []
        for _ in 0..<640 { held.append(try inputs.admit(bytes: 8_192)) }
        XCTAssertEqual(ledger.chargedBytes, 640 * WriterInputAdmission.metadataBytes)
        XCTAssertThrowsError(try inputs.admit(bytes: 1))
        held.removeAll()
        XCTAssertEqual(inputs.usage.count, 0)
        XCTAssertEqual(inputs.allocationCount, inputs.releaseCount)
        XCTAssertEqual(ledger.chargedBytes, 0)
        XCTAssertEqual(AudioServiceRegistryCapacity.compressedWriterInputs, 384)
    }
}
