// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class Timestamp33UnwrapperTests: XCTestCase {
    private let modulus: UInt64 = 1 << 33
    private let halfRange: UInt64 = 1 << 32

    func testUnwrapsForwardAcrossMPEGTSBoundary() {
        var sut = Timestamp33Unwrapper()

        XCTAssertEqual(sut.unwrap(raw: modulus - 90_000), Int64(modulus - 90_000))
        XCTAssertEqual(sut.unwrap(raw: 45_000), Int64(modulus + 45_000))
    }

    func testUnwrapsBackwardAcrossMPEGTSBoundary() {
        var sut = Timestamp33Unwrapper()

        XCTAssertEqual(sut.unwrap(raw: 45_000), 45_000)
        XCTAssertEqual(sut.unwrap(raw: modulus - 90_000), -90_000)
    }

    func testSmallBFrameReorderingDoesNotChangeEpoch() {
        var sut = Timestamp33Unwrapper()

        XCTAssertEqual(sut.unwrap(raw: 7_200), 7_200)
        XCTAssertEqual(sut.unwrap(raw: 3_600), 3_600)
        XCTAssertEqual(sut.unwrap(raw: 10_800), 10_800)
    }

    func testMasksIncomingValueToThirtyThreeBits() {
        var sut = Timestamp33Unwrapper()

        XCTAssertEqual(sut.unwrap(raw: (5 * modulus) + 12_345), 12_345)
    }

    func testExactHalfRangeIsNotTreatedAsWrapInEitherDirection() {
        var forward = Timestamp33Unwrapper()
        XCTAssertEqual(forward.unwrap(raw: 0), 0)
        XCTAssertEqual(forward.unwrap(raw: halfRange), Int64(halfRange))

        var backward = Timestamp33Unwrapper()
        XCTAssertEqual(backward.unwrap(raw: halfRange), Int64(halfRange))
        XCTAssertEqual(backward.unwrap(raw: 0), 0)
    }

    func testResetRemovesEpochAndRawHistory() {
        var sut = Timestamp33Unwrapper()
        _ = sut.unwrap(raw: modulus - 90_000)
        XCTAssertEqual(sut.unwrap(raw: 45_000), Int64(modulus + 45_000))

        sut.reset()

        XCTAssertEqual(sut.unwrap(raw: 45_000), 45_000)
    }

    func testUnwrapperIsSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(Timestamp33Unwrapper.self)
    }
}
