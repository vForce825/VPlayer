// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import XCTest
@testable import PhysicalSyncEvidence

final class GoldenVectorTests: XCTestCase {
    func testHeaderCanonicalEncodingGolden() throws {
        let challenge = try ExactDigest32(Data(repeating: 0x01, count: 32))
        let envDigest = try ExactDigest32(Data(repeating: 0x02, count: 32))
        let privDigest = try ExactDigest32(Data(repeating: 0x03, count: 32))

        let header = HeaderRecord(unitChallenge: challenge, environmentDigest: envDigest, privacyMaskManifestDigest: privDigest)
        let cbor = header.toCanonicalCBOR()

        // Verify decoded CBOR array
        let decoded = try CanonicalCBOR.decode(cbor)
        guard case .array(let items) = decoded else {
            XCTFail("Header must encode to array")
            return
        }
        XCTAssertEqual(items.count, 11)
        XCTAssertEqual(items[0], .unsigned(0)) // record kind = 0
        XCTAssertEqual(items[1], .unsigned(1)) // schemaVersion = 1
        XCTAssertEqual(items[2], .byteString(challenge.bytes))
        XCTAssertEqual(items[3], .byteString(envDigest.bytes))
        XCTAssertEqual(items[4], .byteString(privDigest.bytes))
        XCTAssertEqual(items[5], .unsigned(640))
        XCTAssertEqual(items[6], .unsigned(360))
        XCTAssertEqual(items[7], .unsigned(1)) // pixelFormatCode = 1
        XCTAssertEqual(items[8], .unsigned(200000000))
        XCTAssertEqual(items[9], .unsigned(100000000))
        XCTAssertEqual(items[10], .unsigned(300000000))
    }

    func testSingleBitTamperDetection() throws {
        let challenge = try ExactDigest32(Data(repeating: 0xAA, count: 32))
        let remoteReceipt = PublicRemoteEventReceiptV1(
            unitChallenge: challenge,
            publicRemoteEventOrdinal: 1,
            continuousClockNS: 1000,
            commandCode: 42,
            commandPhaseCode: 0
        )
        let originalBytes = remoteReceipt.toCanonicalCBOR()
        let originalDigest = ExactDigest32.sha256(of: originalBytes)

        // Flip a single bit in the encoded bytes
        var tamperedBytes = originalBytes
        tamperedBytes[tamperedBytes.count - 1] ^= 0x01

        let tamperedDigest = ExactDigest32.sha256(of: tamperedBytes)
        XCTAssertNotEqual(originalDigest, tamperedDigest)
    }

    func testDigestLengthValidation() {
        // Exactly 32 bytes must succeed
        XCTAssertNoThrow(try ExactDigest32(Data(repeating: 0, count: 32)))

        // 31 bytes must throw
        XCTAssertThrowsError(try ExactDigest32(Data(repeating: 0, count: 31))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .invalidLength)
        }

        // 33 bytes must throw
        XCTAssertThrowsError(try ExactDigest32(Data(repeating: 0, count: 33))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .invalidLength)
        }
    }
}
