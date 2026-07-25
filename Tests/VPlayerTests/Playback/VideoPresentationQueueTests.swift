// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import XCTest
@testable import VPlayerPlayback

final class VideoPresentationQueueTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 8)

    func testOutOfOrderCallbacksPresentInExactPTSOrder() throws {
        let queue = VideoPresentationQueue(generation: generation)
        for pts in [3, 1, 2] {
            XCTAssertTrue(queue.enqueue(try frame(id: UInt64(pts), pts: rational(pts, 25))))
        }

        let selections = [1, 2, 3].map {
            queue.select(targetMediaTime: rational($0, 25), displayInterval: rational(1, 50))
        }
        XCTAssertEqual(selections.map(\.action), [.presented, .presented, .presented])
        XCTAssertEqual(selections.compactMap { $0.frame?.sourceAccessUnitID }, [1, 2, 3])
    }

    func testEqualPTSUsesAccessUnitIDThenSequenceNumberAsStableTieBreaks() throws {
        let queue = VideoPresentationQueue(generation: generation)
        XCTAssertTrue(queue.enqueue(try frame(id: 9, sequence: 2, pts: rational(1, 1))))
        XCTAssertTrue(queue.enqueue(try frame(id: 7, sequence: 5, pts: rational(1, 1))))
        XCTAssertTrue(queue.enqueue(try frame(id: 9, sequence: 1, pts: rational(1, 1))))

        let selected = queue.select(
            targetMediaTime: rational(1, 1),
            displayInterval: rational(1, 50)
        )
        XCTAssertEqual(selected.action, .presented)
        XCTAssertEqual(selected.frame?.sourceAccessUnitID, 9)
        XCTAssertEqual(selected.frame?.sequenceNumber, 2)
        XCTAssertEqual(selected.droppedFrameCount, 2)
    }

    func testStaleAndInvalidInputAreRejectedWithoutMutation() throws {
        let queue = VideoPresentationQueue(generation: generation)
        XCTAssertTrue(queue.enqueue(try frame(id: 1, pts: rational(1, 1))))
        XCTAssertFalse(queue.enqueue(try frame(
            id: 2,
            pts: rational(2, 1),
            generation: MediaGeneration(rawValue: 7)
        )))
        XCTAssertFalse(queue.enqueue(try frame(id: 3, pts: .invalid)))
        XCTAssertFalse(queue.enqueue(try frame(id: 4, pts: .indefinite)))
        XCTAssertEqual(queue.unpresentedCount, 1)

        let invalidTarget = queue.select(targetMediaTime: .invalid, displayInterval: rational(1, 50))
        let invalidInterval = queue.select(targetMediaTime: rational(1, 1), displayInterval: .zero)
        XCTAssertEqual(invalidTarget.action, .waiting)
        XCTAssertEqual(invalidInterval.action, .waiting)
        XCTAssertEqual(queue.unpresentedCount, 1)
    }

    func testQueueIsBoundedByDurationRegardlessOfFrameRate() throws {
        // 60 field-rate frames span 1.18 s, so a one-second horizon keeps the 51
        // that fit. Bounding by frames instead made this depend on the output
        // frame rate, which field-rate deinterlacing doubles.
        let fieldRate = VideoPresentationQueue(generation: generation, horizon: rational(1, 1))
        for index in (0..<60).reversed() {
            XCTAssertTrue(fieldRate.enqueue(
                try frame(id: UInt64(index), pts: rational(index, 50), duration: rational(1, 50))
            ))
        }
        XCTAssertEqual(fieldRate.unpresentedCount, 51)

        // Half the frame rate, same duration, so half as many frames survive.
        let frameRate = VideoPresentationQueue(generation: generation, horizon: rational(1, 1))
        for index in (0..<60).reversed() {
            XCTAssertTrue(frameRate.enqueue(
                try frame(id: UInt64(index), pts: rational(index, 25), duration: rational(1, 25))
            ))
        }
        XCTAssertEqual(frameRate.unpresentedCount, 26)

        // The newest frame is the overflow victim. The next-due frame has to
        // survive, otherwise a producer running ahead of the clock deletes every
        // frame just before the clock reaches it and nothing is ever presented.
        let first = fieldRate.select(
            targetMediaTime: .zero,
            displayInterval: rational(1, 50)
        )
        XCTAssertEqual(first.action, .presented)
        XCTAssertEqual(first.frame?.sourceAccessUnitID, 0)
        XCTAssertEqual(first.droppedFrameCount, 9)
    }

    func testHorizonIsConfigurableAndRejectsNonPositiveValues() throws {
        let half = VideoPresentationQueue(generation: generation, horizon: rational(1, 2))
        XCTAssertEqual(half.horizonSeconds, 0.5, accuracy: 0.0001)
        for index in (0..<60).reversed() {
            XCTAssertTrue(half.enqueue(
                try frame(id: UInt64(index), pts: rational(index, 50), duration: rational(1, 50))
            ))
        }
        XCTAssertEqual(half.unpresentedCount, 26)

        for invalid in [CMTime.invalid, .zero, rational(-1, 1)] {
            let fallback = VideoPresentationQueue(generation: generation, horizon: invalid)
            XCTAssertEqual(
                fallback.horizonSeconds,
                PlaybackTuning.default.videoBufferSeconds,
                accuracy: 0.0001
            )
        }
    }

    // The viewer changes the buffer length from a sheet raised over the running
    // stream, so it has to take effect without restarting playback.
    func testBufferLengthAppliesToAQueueThatIsAlreadyRunning() throws {
        let queue = VideoPresentationQueue(generation: generation, horizon: rational(1, 2))
        for index in (0..<120).reversed() {
            XCTAssertTrue(queue.enqueue(
                try frame(id: UInt64(index), pts: rational(index, 50), duration: rational(1, 50))
            ))
        }
        XCTAssertEqual(queue.unpresentedCount, 26)

        queue.setBuffer(horizon: rational(2, 1), frameCeiling: 240)
        XCTAssertEqual(queue.horizonSeconds, 2, accuracy: 0.0001)
        for index in (26..<120).reversed() {
            XCTAssertTrue(queue.enqueue(
                try frame(id: UInt64(index), pts: rational(index, 50), duration: rational(1, 50))
            ))
        }
        XCTAssertEqual(queue.unpresentedCount, 101, "a longer buffer must hold more video")

        // Shrinking trims straight away rather than waiting for the next arrival,
        // and the next-due frame still has to survive the trim.
        queue.setBuffer(horizon: rational(1, 2), frameCeiling: 120)
        XCTAssertEqual(queue.unpresentedCount, 26)
        let next = queue.select(targetMediaTime: .zero, displayInterval: rational(1, 50))
        XCTAssertEqual(next.action, .presented)
        XCTAssertEqual(next.frame?.sourceAccessUnitID, 0)
    }

    func testInvalidBufferChangesLeaveTheQueueOnItsDefaults() throws {
        let queue = VideoPresentationQueue(generation: generation, horizon: rational(1, 1))
        for invalid in [CMTime.invalid, .zero, rational(-1, 1)] {
            queue.setBuffer(horizon: invalid, frameCeiling: 0)
            XCTAssertEqual(
                queue.horizonSeconds,
                PlaybackTuning.default.videoBufferSeconds,
                accuracy: 0.0001
            )
        }
        queue.setBuffer(
            horizon: rational(1, 1),
            frameCeiling: PlaybackTuning.default.videoBufferFrameCeiling
        )
        for index in (0..<60).reversed() {
            XCTAssertTrue(queue.enqueue(
                try frame(id: UInt64(index), pts: rational(index, 50), duration: rational(1, 50))
            ))
        }
        XCTAssertEqual(queue.unpresentedCount, 51)
    }

    func testExpiryUsesStrictBoundaryAndInvalidDurationFallsBackToInterval() throws {
        do {
            let queue = VideoPresentationQueue(generation: generation)
            XCTAssertTrue(queue.enqueue(try frame(id: 1, pts: .zero, duration: rational(1, 1))))
            let boundary = queue.select(
                targetMediaTime: rational(1, 1),
                displayInterval: rational(1, 50)
            )
            XCTAssertEqual(boundary.action, .presented, "PTS + duration == target must survive strict expiry")
            XCTAssertEqual(boundary.droppedFrameCount, 0)
        }

        do {
            let queue = VideoPresentationQueue(generation: generation)
            XCTAssertTrue(queue.enqueue(try frame(id: 1, pts: .zero, duration: .invalid)))
            let expired = queue.select(
                targetMediaTime: rational(21, 1_000),
                displayInterval: rational(20, 1_000)
            )
            XCTAssertEqual(expired.action, .waiting)
            XCTAssertEqual(expired.droppedFrameCount, 1)
        }
    }

    func testEarlyWaitSupersededDropAndCurrentRepeatAreDistinct() throws {
        let queue = VideoPresentationQueue(generation: generation)
        XCTAssertTrue(queue.enqueue(try frame(id: 1, pts: rational(1, 1))))
        XCTAssertTrue(queue.enqueue(try frame(id: 2, pts: rational(11, 10))))
        XCTAssertEqual(
            queue.select(targetMediaTime: .zero, displayInterval: rational(1, 50)).action,
            .waiting
        )

        let newest = queue.select(
            targetMediaTime: rational(11, 10),
            displayInterval: rational(1, 50)
        )
        XCTAssertEqual(newest.action, .presented)
        XCTAssertEqual(newest.frame?.sourceAccessUnitID, 2)
        XCTAssertEqual(newest.droppedFrameCount, 1)

        let repeated = queue.select(
            targetMediaTime: rational(112, 100),
            displayInterval: rational(1, 50)
        )
        XCTAssertEqual(repeated.action, .repeated)
        XCTAssertEqual(repeated.frame?.sourceAccessUnitID, 2)
        XCTAssertEqual(repeated.droppedFrameCount, 0)
    }

    func testTwentyFiveFPSFrameRemainsCurrentAcrossTwoFiftyHertzTicks() throws {
        let queue = VideoPresentationQueue(generation: generation)
        XCTAssertTrue(queue.enqueue(try frame(id: 1, pts: .zero, duration: rational(1, 25))))

        let first = queue.select(targetMediaTime: .zero, displayInterval: rational(1, 50))
        let second = queue.select(targetMediaTime: rational(1, 50), displayInterval: rational(1, 50))
        XCTAssertEqual(first.action, .presented)
        XCTAssertEqual(second.action, .repeated)
        XCTAssertEqual(second.frame?.sourceAccessUnitID, 1)
    }

    func testNinetyKilohertzTarget3500Selects3600AndDropsTwoSupersededFrames() throws {
        let queue = VideoPresentationQueue(generation: generation)
        for pts: Int64 in [0, 1_800, 3_600] {
            XCTAssertTrue(queue.enqueue(try frame(
                id: UInt64(pts),
                pts: CMTime(value: pts, timescale: 90_000),
                duration: CMTime(value: 1_800, timescale: 90_000)
            )))
        }

        let selection = queue.select(
            targetMediaTime: CMTime(value: 3_500, timescale: 90_000),
            displayInterval: CMTime(value: 1_800, timescale: 90_000)
        )

        XCTAssertEqual(selection.frame?.presentationTimeStamp.value, 3_600)
        XCTAssertEqual(selection.droppedFrameCount, 2)
    }

    func testGenerationFlushClearsQueueCurrentOverflowIntervalAndMetricsEpoch() throws {
        let queue = VideoPresentationQueue(generation: generation)
        for pts in 1...13 {
            XCTAssertTrue(queue.enqueue(try frame(id: UInt64(pts), pts: rational(pts, 25))))
        }
        _ = queue.select(targetMediaTime: rational(13, 25), displayInterval: rational(1, 50))
        XCTAssertNotNil(queue.currentFrame)
        XCTAssertGreaterThan(queue.metricsEpochDroppedFrameCount, 0)

        let nextGeneration = MediaGeneration(rawValue: 9)
        queue.flush(to: nextGeneration)
        XCTAssertEqual(queue.generation, nextGeneration)
        XCTAssertEqual(queue.unpresentedCount, 0)
        XCTAssertNil(queue.currentFrame)
        XCTAssertEqual(queue.metricsEpochDroppedFrameCount, 0)

        let empty = queue.select(targetMediaTime: .zero, displayInterval: rational(1, 60))
        XCTAssertEqual(empty.action, .waiting)
        XCTAssertEqual(empty.droppedFrameCount, 0)
        XCTAssertFalse(queue.enqueue(try frame(id: 20, pts: .zero, generation: generation)))
    }

    func testInvalidArithmeticNeverTrapsAndDeterministicallyWaits() throws {
        let queue = VideoPresentationQueue(generation: generation)
        XCTAssertTrue(queue.enqueue(try frame(
            id: 1,
            pts: CMTime(value: Int64.max, timescale: 1),
            duration: CMTime(value: Int64.max, timescale: 1)
        )))
        let selection = queue.select(
            targetMediaTime: CMTime(value: Int64.max, timescale: 1),
            displayInterval: rational(1, 60)
        )
        XCTAssertTrue([.waiting, .presented].contains(selection.action))
    }

    private func frame(
        id: UInt64,
        sequence: UInt64 = 0,
        pts: CMTime,
        duration: CMTime = CMTime(value: 1, timescale: 25),
        generation: MediaGeneration? = nil
    ) throws -> VideoPresentationFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        return VideoPresentationFrame(
            storage: .pixelBuffer(try XCTUnwrap(pixelBuffer)),
            presentationTimeStamp: pts,
            duration: duration,
            generation: generation ?? self.generation,
            sequenceNumber: sequence,
            sourceAccessUnitID: id,
            formatMetadata: makeMetadata()
        )
    }

    private func makeMetadata() -> VideoFormatMetadata {
        VideoFormatMetadata(
            dimensions: CMVideoDimensions(width: 2, height: 2),
            bitDepth: 8,
            range: .video,
            matrix: .bt709,
            transfer: .bt709,
            primaries: .bt709,
            cleanAperture: nil,
            chromaLocation: .init(topField: nil, bottomField: nil),
            hdrStaticMetadata: .init(masteringDisplayColorVolume: nil, contentLightLevelInfo: nil)
        )
    }

    private func rational(_ value: Int, _ timescale: Int32) -> CMTime {
        CMTime(value: Int64(value), timescale: timescale)
    }
}
