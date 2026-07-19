// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class MediaTimestampTests: XCTestCase {
    func testTimestampConversionProducesExactReducedValues() throws {
        let ninetyKilohertz = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let ntsc = try XCTUnwrap(MediaRational(num: 1_001, den: 30_000))

        XCTAssertEqual(
            ninetyKilohertz.cmTime(forFFmpegValue: 90_000),
            CMTime(value: 1, timescale: 1)
        )
        XCTAssertEqual(
            ninetyKilohertz.cmTime(forFFmpegValue: 3_003),
            CMTime(value: 1_001, timescale: 30_000)
        )
        XCTAssertEqual(
            ntsc.cmTime(forFFmpegValue: 1),
            CMTime(value: 1_001, timescale: 30_000)
        )
        XCTAssertEqual(
            ninetyKilohertz.cmTime(forFFmpegValue: -3_003),
            CMTime(value: -1_001, timescale: 30_000)
        )
    }

    func testNOPTSAndOverflowReturnInvalidWithoutApproximating() throws {
        let ordinary = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let overflowing = try XCTUnwrap(MediaRational(num: 2, den: 1))

        XCTAssertFalse(ordinary.cmTime(forFFmpegValue: Int64.min).isValid)
        XCTAssertFalse(overflowing.cmTime(forFFmpegValue: Int64.max).isValid)
    }

    func testReducibleLargeTimestampRemainsExact() throws {
        let reducible = try XCTUnwrap(MediaRational(num: 2, den: 2))

        XCTAssertEqual(
            reducible.cmTime(forFFmpegValue: Int64.max),
            CMTime(value: Int64.max, timescale: 1)
        )
    }

    func testRationalRejectsZeroAndNegativeTerms() {
        XCTAssertNil(MediaRational(num: 0, den: 1))
        XCTAssertNil(MediaRational(num: 1, den: 0))
        XCTAssertNil(MediaRational(num: -1, den: 1))
        XCTAssertNil(MediaRational(num: 1, den: -1))
    }

    func testRationalIsHashableAndSendable() throws {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(MediaRational.self)

        let value = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        XCTAssertEqual(Set([value, value]).count, 1)
    }
}
