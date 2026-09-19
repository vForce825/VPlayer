// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class HTTPRangeTests: XCTestCase {
    func testClosedOpenEndedAndSuffixSingleRangesUseHalfOpenByteOffsets() throws {
        let cases: [(String, Int, HTTPRangeSelection)] = [
            ("bytes=0-3", 10, .single(0..<4)),
            ("bytes=3-", 10, .single(3..<10)),
            ("bytes=-3", 10, .single(7..<10)),
            ("bytes=9-99", 10, .single(9..<10)),
            ("bytes=-99", 10, .single(0..<10)),
        ]
        for (field, length, expected) in cases {
            XCTAssertEqual(try HTTPRange.parse(field, resourceLength: length), expected, field)
        }
    }

    func testSingleUnsatisfiedRangesAndEmptyResourcesReturnUnsatisfied() throws {
        let cases: [(String, Int)] = [
            ("bytes=10-", 10),
            ("bytes=99-100", 10),
            ("bytes=-0", 10),
            ("bytes=0-0", 0),
            ("bytes=-1", 0),
        ]
        for (field, length) in cases {
            XCTAssertEqual(try HTTPRange.parse(field, resourceLength: length), .unsatisfied, field)
        }
    }

    func testLegalMultipleRangesIgnoreFieldWhenAnyMemberIsSatisfiable() throws {
        let cases = [
            "bytes=0-0,2-3",
            "bytes=99-100,1-2",
            "bytes=-0,-2",
            "bytes=0-0,99-100",
        ]
        for field in cases {
            XCTAssertEqual(try HTTPRange.parse(field, resourceLength: 10), .ignoreAndServeFull, field)
        }
    }

    func testLegalMultipleRangesAreUnsatisfiedOnlyWhenEveryMemberIsUnsatisfied() throws {
        XCTAssertEqual(try HTTPRange.parse("bytes=10-20,30-, -0", resourceLength: 10), .unsatisfied)
        XCTAssertEqual(try HTTPRange.parse("bytes=0-1,2-3", resourceLength: 0), .unsatisfied)
    }

    func testMalformedRangeGrammarIsRejectedRatherThanReportedUnsatisfied() {
        let malformed = [
            "", "bytes", "bytes=", "items=0-1", "bytes =0-1", "bytes=0 -1",
            "bytes=0- 1", "bytes=+0-1", "bytes=-1-2", "bytes=3-2", "bytes=--1",
            "bytes=0x1-2", "bytes=0-1,", "bytes=,0-1", "bytes=0-1,,2-3",
            "bytes=18446744073709551616-", "bytes=-18446744073709551616",
        ]
        for field in malformed {
            XCTAssertThrowsError(try HTTPRange.parse(field, resourceLength: 10), field) { error in
                XCTAssertEqual(error as? HTTPRangeError, .invalidSyntax)
            }
        }
    }

    func testRangeArithmeticNeverOverflowsAtIntegerBoundaries() throws {
        XCTAssertEqual(
            try HTTPRange.parse("bytes=18446744073709551614-18446744073709551615", resourceLength: Int.max),
            .unsatisfied
        )
        XCTAssertEqual(try HTTPRange.parse("bytes=0-9223372036854775807", resourceLength: Int.max),
                       .single(0..<Int.max))
    }
}
