// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class ExactRationalTests: XCTestCase {
    func testReductionAndInvariants() throws {
        let r1 = try ExactRational(numerator: 4, denominator: 8)
        XCTAssertEqual(r1.numerator, 1)
        XCTAssertEqual(r1.denominator, 2)

        let r2 = try ExactRational(numerator: -6, denominator: 9)
        XCTAssertEqual(r2.numerator, -2)
        XCTAssertEqual(r2.denominator, 3)

        let r3 = try ExactRational(numerator: 0, denominator: 50)
        XCTAssertEqual(r3.numerator, 0)
        XCTAssertEqual(r3.denominator, 1)

        XCTAssertThrowsError(try ExactRational(numerator: 1, denominator: 0)) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .rationalDenominatorZero)
        }
    }

    func testComparisons() throws {
        let r1 = try ExactRational(numerator: 1, denominator: 3)
        let r2 = try ExactRational(numerator: 1, denominator: 2)
        let r3 = try ExactRational(numerator: -1, denominator: 2)
        let r4 = try ExactRational(numerator: -1, denominator: 3)

        XCTAssertTrue(r1 < r2)
        XCTAssertTrue(r3 < r4)
        XCTAssertTrue(r3 < r1)
        XCTAssertFalse(r2 < r1)
        XCTAssertEqual(r1, try ExactRational(numerator: 2, denominator: 6))
    }

    func testCheckedArithmetic() throws {
        let r1 = try ExactRational(numerator: 1, denominator: 3)
        let r2 = try ExactRational(numerator: 1, denominator: 6)

        let sum = try r1 + r2
        XCTAssertEqual(sum, try ExactRational(numerator: 1, denominator: 2))

        let diff = try r1 - r2
        XCTAssertEqual(diff, try ExactRational(numerator: 1, denominator: 6))

        let prod = try r1 * r2
        XCTAssertEqual(prod, try ExactRational(numerator: 1, denominator: 18))

        let quot = try r1 / r2
        XCTAssertEqual(quot, try ExactRational(numerator: 2, denominator: 1))
    }

    func testMicrosecondRounding() throws {
        // 1.5 microseconds = 1.5 * 10^-6 s = 3 / 2_000_000 seconds
        // Nearest-even for 1.5 -> 2
        let r1 = try ExactRational(numerator: 3, denominator: 2_000_000)
        XCTAssertEqual(r1.roundedMicroseconds(), 2)

        // 2.5 microseconds = 5 / 2_000_000 seconds -> round to even: 2
        let r2 = try ExactRational(numerator: 5, denominator: 2_000_000)
        XCTAssertEqual(r2.roundedMicroseconds(), 2)

        // 3.5 microseconds = 7 / 2_000_000 seconds -> round to even: 4
        let r3 = try ExactRational(numerator: 7, denominator: 2_000_000)
        XCTAssertEqual(r3.roundedMicroseconds(), 4)
    }

    func testMillisecondConversion() throws {
        let seconds = try ExactRational(numerator: 1, denominator: 2) // 0.5s
        let ms = try seconds.toMilliseconds()
        XCTAssertEqual(ms, ExactRational(500))
        let backToSec = try ms.toSeconds()
        XCTAssertEqual(backToSec, seconds)
    }

    func testInt64MinAbsVal() throws {
        // Int64.min with odd denominator cannot be represented as positive ExactRational without overflow
        let rOdd = try ExactRational(numerator: Int64.min, denominator: 1)
        XCTAssertThrowsError(try rOdd.absVal()) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .arithmeticOverflow)
            XCTAssertEqual(error as? CBORError, .arithmeticOverflow)
        }

        // Int64.min with even denominator can be reduced during/before absVal
        let rEven2 = try ExactRational(numerator: Int64.min, denominator: 2)
        let absR2 = try rEven2.absVal()
        XCTAssertEqual(absR2.numerator, 4611686018427387904)
        XCTAssertEqual(absR2.denominator, 1)

        let rEven4 = try ExactRational(numerator: Int64.min, denominator: 4)
        let absR4 = try rEven4.absVal()
        XCTAssertEqual(absR4.numerator, 2305843009213693952)
        XCTAssertEqual(absR4.denominator, 1)
    }
}
