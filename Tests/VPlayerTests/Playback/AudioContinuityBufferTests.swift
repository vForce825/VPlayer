// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class AudioContinuityBufferTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 7)

    func testSubMillisecondPositiveResidueNormalizesToPreviousEnd() throws {
        var subject = makeSubject()
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))

        let admitted = try admitted(subject.admit(makeFrame(
            id: 2,
            pts: time(1_005),
            duration: time(1_000)
        )))

        XCTAssertEqual(admitted.normalizedPresentationTimeStamp, time(1_000))
        XCTAssertEqual(admitted.effectiveCoverageStartPTS, time(1_000))
        XCTAssertNil(admitted.gapBefore)
        XCTAssertFalse(admitted.startsNewIsland)
        XCTAssertFalse(admitted.resetDecoderBeforeDecoding)
        XCTAssertFalse(admitted.fillDiscontinuitiesWithSilence)
    }

    func testSubMillisecondNegativeResidueNormalizesToPreviousEnd() throws {
        var subject = makeSubject()
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))

        let admitted = try admitted(subject.admit(makeFrame(
            id: 2,
            pts: time(995),
            duration: time(1_000)
        )))

        XCTAssertEqual(admitted.normalizedPresentationTimeStamp, time(1_000))
        XCTAssertNil(admitted.gapBefore)
        XCTAssertEqual(subject.activeIsland?.endPTS, time(2_000))
    }

    func testDuplicateFrameIsDroppedBeforeRendererAdmission() throws {
        var subject = makeSubject()
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))

        try assertDrop(
            subject.admit(makeFrame(id: 2, pts: time(0), duration: time(1_000))),
            is: .duplicate
        )

        XCTAssertEqual(subject.retainedFrameCount, 1)
        XCTAssertEqual(subject.activeIsland?.endPTS, time(1_000))
        XCTAssertEqual(subject.activeIsland?.frameCount, 1)
    }

    func testOverlapBeyondToleranceDropsWholeCompressedFrame() throws {
        var subject = makeSubject()
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))

        try assertDrop(
            subject.admit(makeFrame(id: 2, pts: time(980), duration: time(1_000))),
            is: .overlap
        )

        XCTAssertEqual(subject.retainedFrameCount, 1)
        XCTAssertEqual(subject.activeIsland?.endPTS, time(1_000))
    }

    func testPTSRegressionDoesNotMoveHighWatermark() throws {
        var subject = makeSubject()
        let island = try admitted(subject.admit(makeFrame(
            id: 1,
            pts: time(10_000),
            duration: time(1_000)
        ))).continuityIslandID

        try assertDrop(
            subject.admit(makeFrame(id: 2, pts: time(5_000), duration: time(1_000))),
            is: .ptsRegression
        )
        let next = try admitted(subject.admit(makeFrame(
            id: 3,
            pts: time(11_000),
            duration: time(1_000)
        )))

        XCTAssertEqual(next.normalizedPresentationTimeStamp, time(11_000))
        XCTAssertEqual(next.continuityIslandID, island)
        XCTAssertEqual(subject.activeIsland?.endPTS, time(12_000))
        XCTAssertEqual(subject.activeIsland?.frameCount, 2)
    }

    func testDecodeBreakResetsNextContiguousFrameWithoutInventingGap() throws {
        var subject = makeSubject()
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))
        subject.markDecodeBreak()
        try assertDrop(
            subject.admit(makeFrame(id: 2, pts: time(0), duration: time(1_000))),
            is: .duplicate
        )

        let resetFrame = try admitted(subject.admit(makeFrame(
            id: 3,
            pts: time(1_000),
            duration: time(1_000)
        )))
        let followingFrame = try admitted(subject.admit(makeFrame(
            id: 4,
            pts: time(2_000),
            duration: time(1_000)
        )))

        XCTAssertTrue(resetFrame.resetDecoderBeforeDecoding)
        XCTAssertNil(resetFrame.gapBefore)
        XCTAssertFalse(resetFrame.startsNewIsland)
        XCTAssertFalse(resetFrame.fillDiscontinuitiesWithSilence)
        XCTAssertFalse(followingFrame.resetDecoderBeforeDecoding)
    }

    func testGapAt250MillisecondsUsesResetAndSilenceFillInSameIsland() throws {
        var subject = makeSubject()
        let first = try admitted(subject.admit(makeFrame(
            id: 1,
            pts: time(0),
            duration: time(1_000)
        )))

        let afterGap = try admitted(subject.admit(makeFrame(
            id: 2,
            pts: time(3_500),
            duration: time(1_000)
        )))

        XCTAssertEqual(afterGap.gapBefore, time(2_500))
        XCTAssertEqual(afterGap.effectiveCoverageStartPTS, time(1_000))
        XCTAssertEqual(afterGap.continuityIslandID, first.continuityIslandID)
        XCTAssertFalse(afterGap.startsNewIsland)
        XCTAssertTrue(afterGap.resetDecoderBeforeDecoding)
        XCTAssertTrue(afterGap.fillDiscontinuitiesWithSilence)
    }

    func testGapOver250MillisecondsStartsNewIslandWithResetOnly() throws {
        var subject = makeSubject()
        let first = try admitted(subject.admit(makeFrame(
            id: 1,
            pts: time(0),
            duration: time(1_000)
        )))

        let afterGap = try admitted(subject.admit(makeFrame(
            id: 2,
            pts: time(3_510),
            duration: time(1_000)
        )))

        XCTAssertEqual(afterGap.gapBefore, time(2_510))
        XCTAssertEqual(afterGap.effectiveCoverageStartPTS, time(3_510))
        XCTAssertNotEqual(afterGap.continuityIslandID, first.continuityIslandID)
        XCTAssertTrue(afterGap.startsNewIsland)
        XCTAssertTrue(afterGap.resetDecoderBeforeDecoding)
        XCTAssertFalse(afterGap.fillDiscontinuitiesWithSilence)
        XCTAssertEqual(subject.activeIsland?.firstPTS, time(3_510))
        XCTAssertEqual(subject.activeIsland?.frameCount, 1)
    }

    func testGenerationResetRejectsStaleFrames() throws {
        var subject = makeSubject()
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))
        let nextGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        subject.reset(to: nextGeneration)

        try assertDrop(
            subject.admit(makeFrame(id: 2, pts: time(1_000), duration: time(1_000))),
            is: .staleGeneration
        )
        XCTAssertEqual(subject.retainedFrameCount, 0)
        XCTAssertNil(subject.activeIsland)

        let firstFresh = try admitted(subject.admit(makeFrame(
            id: 3,
            pts: time(0),
            duration: time(1_000),
            generation: nextGeneration
        )))
        XCTAssertTrue(firstFresh.startsNewIsland)
        XCTAssertEqual(firstFresh.frame.generation, nextGeneration)
    }

    func testRetentionFloorProtectsCoveringFrameAndRetainsNewestTailAtCapacity() throws {
        var subject = AudioContinuityBuffer(capacity: 2)
        subject.reset(to: generation)
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))
        _ = try subject.admit(makeFrame(id: 2, pts: time(1_000), duration: time(1_000)))
        try subject.updateRecoveryFloor(time(500))

        _ = try subject.admit(makeFrame(id: 3, pts: time(2_000), duration: time(1_000)))

        XCTAssertEqual(subject.retainedFrameCount, 2)
        let protected = try XCTUnwrap(subject.anchorCandidate(at: time(500)))
        XCTAssertEqual(protected.id, subject.activeIsland?.id)
        XCTAssertNil(subject.anchorCandidate(at: time(1_500)))
        XCTAssertNotNil(subject.anchorCandidate(at: time(2_500)))
        XCTAssertEqual(subject.activeIsland?.endPTS, time(3_000))
        XCTAssertEqual(subject.activeIsland?.frameCount, 3)
    }

    func testZeroContinuityLimitIsRejectedAsConfigurationError() {
        XCTAssertThrowsError(try CompressedAudioRetentionLimits(
            maximumCount: 0,
            maximumOwnedBytes: 8,
            latestTailHorizon: CMTime(value: 1, timescale: 1)
        ))
    }

    func testFloorProtectsOnlyCoveringFrameAndLatestTailKeepsSliding() throws {
        var subject = AudioContinuityBuffer(capacity: 2)
        subject.reset(to: generation)
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))
        _ = try subject.admit(makeFrame(id: 2, pts: time(1_000), duration: time(1_000)))
        try subject.updateRecoveryFloor(time(500))
        _ = try subject.admit(makeFrame(id: 3, pts: time(2_000), duration: time(1_000)))
        _ = try subject.admit(makeFrame(
            id: 4,
            pts: time(3_000),
            duration: time(1_000)
        ))

        XCTAssertNotNil(subject.anchorCandidate(at: time(500)))
        XCTAssertNil(subject.anchorCandidate(at: time(2_500)))
        XCTAssertNotNil(subject.anchorCandidate(at: time(3_500)))
        XCTAssertEqual(subject.activeIsland?.endPTS, time(4_000))
        XCTAssertEqual(subject.activeIsland?.frameCount, 4)
        XCTAssertEqual(subject.retainedFrameCount, 2)
    }

    func testRequestedCapacityAbove512RemainsHardBounded() throws {
        var subject = AudioContinuityBuffer(capacity: 513)
        subject.reset(to: generation)

        for index in 0..<513 {
            let admission = try subject.admit(makeFrame(
                id: UInt64(index + 1),
                pts: time(Int64(index) * 100),
                duration: time(100)
            ))
            guard case .admitted = admission else {
                XCTFail("Capacity must not reject otherwise valid live admissions")
                return
            }
        }

        XCTAssertEqual(subject.retainedFrameCount, 512)
        XCTAssertEqual(subject.activeIsland?.frameCount, 513)
        XCTAssertEqual(subject.activeIsland?.endPTS, time(51_300))
    }

    func testByteBudgetPrunesBeforeCountAndRetainsFloorPlusNewest() throws {
        var subject = AudioContinuityBuffer(retentionLimits: try limits(
            count: 4,
            bytes: 8,
            horizonSeconds: 10
        ))
        subject.reset(to: generation)
        _ = try subject.admit(makeFrame(
            id: 1,
            pts: time(0),
            duration: time(1_000),
            payloadBytes: 4
        ))
        _ = try subject.admit(makeFrame(
            id: 2,
            pts: time(1_000),
            duration: time(1_000),
            payloadBytes: 4
        ))
        try subject.updateRecoveryFloor(time(500))

        _ = try subject.admit(makeFrame(
            id: 3,
            pts: time(2_000),
            duration: time(1_000),
            payloadBytes: 4
        ))

        XCTAssertEqual(subject.retainedFrameCount, 2)
        XCTAssertEqual(subject.retainedPayloadBytes, 8)
        XCTAssertNotNil(subject.anchorCandidate(at: time(500)))
        XCTAssertNil(subject.anchorCandidate(at: time(1_500)))
        XCTAssertNotNil(subject.anchorCandidate(at: time(2_500)))
    }

    func testTimeHorizonPrunesLatestComponentButExemptsSingleFloorProtector() throws {
        var subject = AudioContinuityBuffer(retentionLimits: try limits(
            count: 10,
            bytes: 100,
            horizonSeconds: 2
        ))
        subject.reset(to: generation)
        for index in 0..<2 {
            _ = try subject.admit(makeFrame(
                id: UInt64(index + 1),
                pts: time(Int64(index) * 10_000),
                duration: time(10_000)
            ))
        }
        try subject.updateRecoveryFloor(time(5_000))
        for index in 2..<4 {
            _ = try subject.admit(makeFrame(
                id: UInt64(index + 1),
                pts: time(Int64(index) * 10_000),
                duration: time(10_000)
            ))
        }

        XCTAssertNotNil(subject.anchorCandidate(at: time(5_000)))
        XCTAssertNil(subject.anchorCandidate(at: time(15_000)))
        let latest = try XCTUnwrap(subject.activeRetainedInterval)
        XCTAssertEqual(latest.firstPTS, time(20_000))
        XCTAssertEqual(latest.endPTS, time(40_000))
        let candidate = try XCTUnwrap(subject.anchorCandidate(at: time(35_000)))
        XCTAssertEqual(candidate.coverageStartPTS, time(20_000))
        XCTAssertEqual(candidate.coverageEndPTS, time(40_000))
    }

    func testFailedReservationDoesNotAdvanceStateOrConsumeDecodeBreak() throws {
        var subject = AudioContinuityBuffer(retentionLimits: try limits(
            count: 1,
            bytes: 4,
            horizonSeconds: 10
        ))
        subject.reset(to: generation)
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))
        try subject.updateRecoveryFloor(time(500))
        subject.markDecodeBreak()
        let before = try XCTUnwrap(subject.activeIsland)

        XCTAssertThrowsError(try subject.admit(makeFrame(
            id: 2,
            pts: time(1_000),
            duration: time(1_000)
        ))) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .audioRendererFailed(CompressedAudioRetentionPolicy.continuityCapacityError)
            )
        }
        XCTAssertEqual(subject.activeIsland?.endPTS, before.endPTS)
        XCTAssertEqual(subject.activeIsland?.frameCount, before.frameCount)
        XCTAssertEqual(subject.retainedFrameCount, 1)
        XCTAssertEqual(subject.retainedPayloadBytes, 2)

        try subject.updateRecoveryFloor(nil)
        let retry = try admitted(try subject.admit(makeFrame(
            id: 2,
            pts: time(1_000),
            duration: time(1_000)
        )))
        XCTAssertTrue(retry.resetDecoderBeforeDecoding)
        XCTAssertEqual(subject.activeIsland?.endPTS, time(2_000))
    }

    func testNewIslandClearsOldFloorCandidateBeforeFirstNewFrame() throws {
        var subject = AudioContinuityBuffer(retentionLimits: try limits(
            count: 2,
            bytes: 8,
            horizonSeconds: 10
        ))
        subject.reset(to: generation)
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))
        try subject.updateRecoveryFloor(time(500))

        let fresh = try admitted(try subject.admit(makeFrame(
            id: 2,
            pts: time(4_000),
            duration: time(1_000)
        )))

        XCTAssertTrue(fresh.startsNewIsland)
        XCTAssertNil(subject.anchorCandidate(at: time(500)))
        XCTAssertNotNil(subject.anchorCandidate(at: time(4_500)))
        XCTAssertEqual(subject.retainedFrameCount, 1)
        XCTAssertEqual(subject.retainedPayloadBytes, 2)
    }

    func testFloorAtHalfOpenBoundaryProtectsOnlyFollowingFrame() throws {
        var subject = AudioContinuityBuffer(capacity: 2)
        subject.reset(to: generation)
        _ = try subject.admit(makeFrame(id: 1, pts: time(0), duration: time(1_000)))
        _ = try subject.admit(makeFrame(id: 2, pts: time(1_000), duration: time(1_000)))
        try subject.updateRecoveryFloor(time(1_000))
        _ = try subject.admit(makeFrame(id: 3, pts: time(2_000), duration: time(1_000)))

        XCTAssertNil(subject.anchorCandidate(at: time(500)))
        XCTAssertNotNil(subject.anchorCandidate(at: time(1_000)))
        XCTAssertNotNil(subject.anchorCandidate(at: time(2_500)))
    }

    func testIslandIDExhaustionDropsNewIslandWithoutMutatingContinuityState() throws {
        var subject = AudioContinuityBuffer(
            testingIslandIDAllocatorStartingAt: UInt64.max
        )
        subject.reset(to: generation)
        let lastIslandFrame = try admitted(subject.admit(makeFrame(
            id: 1,
            pts: time(0),
            duration: time(1_000)
        )))
        XCTAssertEqual(lastIslandFrame.continuityIslandID.rawValue, UInt64.max)
        subject.markDecodeBreak()
        let before = try XCTUnwrap(subject.activeIsland)
        let retainedBefore = subject.retainedFrameCount

        let exhausted = try subject.admit(makeFrame(
            id: 2,
            pts: time(3_510),
            duration: time(1_000)
        ))
        guard case let .dropped(reason) = exhausted else {
            XCTFail("A fresh island must be rejected after ID exhaustion")
            return
        }
        XCTAssertEqual(reason.rawValue, AudioContinuityDropReason.invalidTiming.rawValue)
        let after = try XCTUnwrap(subject.activeIsland)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.firstPTS, before.firstPTS)
        XCTAssertEqual(after.endPTS, before.endPTS)
        XCTAssertEqual(after.frameCount, before.frameCount)
        XCTAssertEqual(subject.retainedFrameCount, retainedBefore)
        XCTAssertNotNil(subject.anchorCandidate(at: time(500)))

        let contiguous = try admitted(subject.admit(makeFrame(
            id: 3,
            pts: time(1_000),
            duration: time(1_000)
        )))
        XCTAssertEqual(contiguous.continuityIslandID.rawValue, UInt64.max)
        XCTAssertFalse(contiguous.startsNewIsland)
        XCTAssertNil(contiguous.gapBefore)
        XCTAssertTrue(contiguous.resetDecoderBeforeDecoding)
        XCTAssertEqual(subject.activeIsland?.endPTS, time(2_000))
        XCTAssertEqual(subject.activeIsland?.frameCount, 2)

        let nextGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        subject.reset(to: nextGeneration)
        try assertDrop(
            subject.admit(makeFrame(
                id: 4,
                pts: time(0),
                duration: time(1_000),
                generation: nextGeneration
            )),
            is: .invalidTiming
        )
        XCTAssertNil(subject.activeIsland)
        XCTAssertEqual(subject.retainedFrameCount, 0)
    }

    private func makeSubject() -> AudioContinuityBuffer {
        var subject = AudioContinuityBuffer()
        subject.reset(to: generation)
        return subject
    }

    private func makeFrame(
        id: UInt64,
        pts: CMTime,
        duration: CMTime,
        generation: MediaGeneration? = nil,
        payloadBytes: Int = 2
    ) -> CompressedAudioFrame {
        CompressedAudioFrame(
            id: id,
            payload: Data(repeating: UInt8(truncatingIfNeeded: id), count: payloadBytes),
            codec: .aac,
            generation: generation ?? self.generation,
            presentationTimeStamp: pts,
            duration: duration,
            frameSampleCount: 4_800
        )
    }

    private func admitted(_ admission: AudioContinuityAdmission) throws -> AdmittedAudioFrame {
        guard case let .admitted(frame) = admission else {
            return try XCTUnwrap(nil as AdmittedAudioFrame?)
        }
        return frame
    }

    private func assertDrop(
        _ admission: AudioContinuityAdmission,
        is expected: AudioContinuityDropReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .dropped(actual) = admission else {
            XCTFail("Expected dropped admission", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.rawValue, expected.rawValue, file: file, line: line)
    }

    private func time(_ value: Int64) -> CMTime {
        CMTime(value: value, timescale: 10_000)
    }

    private func limits(
        count: Int,
        bytes: Int,
        horizonSeconds: Int64
    ) throws -> CompressedAudioRetentionLimits {
        try CompressedAudioRetentionLimits(
            maximumCount: count,
            maximumOwnedBytes: bytes,
            latestTailHorizon: CMTime(value: horizonSeconds, timescale: 1)
        )
    }
}
