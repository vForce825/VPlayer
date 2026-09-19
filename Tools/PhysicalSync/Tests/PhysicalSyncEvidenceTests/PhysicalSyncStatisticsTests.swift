// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class PhysicalSyncStatisticsTests: XCTestCase {
    func testSpecEvaluationExample() throws {
        let result = try PhysicalSyncStatistics.evaluate(
            eventOffsetsMilliseconds: Array(repeating: ExactRational(20), count: 36),
            elapsedSeconds: (0..<36).map { ExactRational(Int64($0 * 10)) }
        )
        XCTAssertEqual(result.medianAbsoluteMilliseconds, ExactRational(20))
        XCTAssertEqual(result.p95AbsoluteMilliseconds, ExactRational(20))
        XCTAssertEqual(result.driftMillisecondsPerMinute, ExactRational(0))
        XCTAssertTrue(result.passesThresholds)
    }

    func testEventCountValidation() throws {
        // Must reject 35 events
        XCTAssertThrowsError(try PhysicalSyncStatistics.evaluate(
            eventOffsetsMilliseconds: Array(repeating: ExactRational(20), count: 35),
            elapsedSeconds: (0..<35).map { ExactRational(Int64($0 * 10)) }
        )) { error in
            XCTAssertEqual(error as? PhysicalSyncStatisticsError, .invalidEventCount(expected: 36, actual: 35))
        }

        // Must reject 37 events
        XCTAssertThrowsError(try PhysicalSyncStatistics.evaluate(
            eventOffsetsMilliseconds: Array(repeating: ExactRational(20), count: 37),
            elapsedSeconds: (0..<37).map { ExactRational(Int64($0 * 10)) }
        )) { error in
            XCTAssertEqual(error as? PhysicalSyncStatisticsError, .invalidEventCount(expected: 36, actual: 37))
        }
    }

    func testElapsedMonotonicity() throws {
        var elapsed = (0..<36).map { ExactRational(Int64($0 * 10)) }
        // Duplicate elapsed
        elapsed[5] = elapsed[4]
        XCTAssertThrowsError(try PhysicalSyncStatistics.evaluate(
            eventOffsetsMilliseconds: Array(repeating: ExactRational(20), count: 36),
            elapsedSeconds: elapsed
        )) { error in
            XCTAssertEqual(error as? PhysicalSyncStatisticsError, .nonMonotonicElapsed)
        }

        // Reversed elapsed
        var reversedElapsed = (0..<36).map { ExactRational(Int64($0 * 10)) }
        reversedElapsed[10] = try reversedElapsed[9] - ExactRational(1)
        XCTAssertThrowsError(try PhysicalSyncStatistics.evaluate(
            eventOffsetsMilliseconds: Array(repeating: ExactRational(20), count: 36),
            elapsedSeconds: reversedElapsed
        )) { error in
            XCTAssertEqual(error as? PhysicalSyncStatisticsError, .nonMonotonicElapsed)
        }
    }

    func testExactStatisticsReductionsAndBoundaries() throws {
        // Construct offsets to test median (items 18 and 19), p95 (item 35), max (item 36)
        // Values 1...36
        var offsets = (1...36).map { ExactRational(Int64($0)) }
        let elapsed = (0..<36).map { ExactRational(Int64($0 * 10)) }

        var result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: offsets, elapsedSeconds: elapsed)
        // sorted items 18 and 19 (1-based): values 18 and 19 -> average 18.5 = 37/2
        XCTAssertEqual(result.medianAbsoluteMilliseconds, try ExactRational(numerator: 37, denominator: 2))
        // sorted item 35 (1-based): 35
        XCTAssertEqual(result.p95AbsoluteMilliseconds, ExactRational(35))
        // sorted item 36 (1-based): 36
        XCTAssertEqual(result.maxAbsoluteMilliseconds, ExactRational(36))

        // Boundary tests for passing:
        // Median <= 40: exactly 40 passes, 40.001 fails
        offsets = Array(repeating: ExactRational(40), count: 36)
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: offsets, elapsedSeconds: elapsed)
        XCTAssertTrue(result.passesThresholds)

        // 40ms + 1/1000 ms = 40.001ms
        offsets = Array(repeating: try ExactRational(numerator: 40001, denominator: 1000), count: 36)
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: offsets, elapsedSeconds: elapsed)
        XCTAssertFalse(result.passesThresholds)

        // p95 <= 80: 34 items 10, 2 items 80 -> p95 = 80 passes
        var offsetsP95 = Array(repeating: ExactRational(10), count: 34) + [ExactRational(80), ExactRational(80)]
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: offsetsP95, elapsedSeconds: elapsed)
        XCTAssertTrue(result.passesThresholds)

        // p95 = 80.001 fails
        offsetsP95 = Array(repeating: ExactRational(10), count: 34) + [try ExactRational(numerator: 80001, denominator: 1000), ExactRational(90)]
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: offsetsP95, elapsedSeconds: elapsed)
        XCTAssertFalse(result.passesThresholds)

        // max <= 100: max 100 passes, max 100.001 fails
        var offsetsMax = Array(repeating: ExactRational(10), count: 35) + [ExactRational(100)]
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: offsetsMax, elapsedSeconds: elapsed)
        XCTAssertTrue(result.passesThresholds)

        offsetsMax = Array(repeating: ExactRational(10), count: 35) + [try ExactRational(numerator: 100001, denominator: 1000)]
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: offsetsMax, elapsedSeconds: elapsed)
        XCTAssertFalse(result.passesThresholds)

        // Drift Theil-Sen: drift of 1 ms / min
        // 1 ms / 60 s = 1/60 ms/s
        // offset_i = (i * 10) * (1 / 60) ms
        let driftOffsets = try (0..<36).map { i -> ExactRational in
            try ExactRational(numerator: Int64(i * 10), denominator: 60)
        }
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: driftOffsets, elapsedSeconds: elapsed)
        XCTAssertEqual(result.driftMillisecondsPerMinute, ExactRational(1))
        XCTAssertTrue(result.passesThresholds)

        // Drift > 1 ms/min fails
        let overDriftOffsets = try (0..<36).map { i -> ExactRational in
            try ExactRational(numerator: Int64(i * 10 * 1001), denominator: 60 * 1000)
        }
        result = try PhysicalSyncStatistics.evaluate(eventOffsetsMilliseconds: overDriftOffsets, elapsedSeconds: elapsed)
        XCTAssertFalse(result.passesThresholds)
    }
}
