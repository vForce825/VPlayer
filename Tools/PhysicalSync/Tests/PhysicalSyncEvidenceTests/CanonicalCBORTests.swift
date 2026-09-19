// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import PhysicalSyncEvidence

final class CanonicalCBORTests: XCTestCase {
    func testMajor0UnsignedShortestEncoding() throws {
        // Test inline 0...23
        let v0 = try CanonicalCBOR.encode(.unsigned(0))
        XCTAssertEqual(v0, Data([0x00]))
        let d0 = try CanonicalCBOR.decode(v0)
        XCTAssertEqual(d0, .unsigned(0))

        let v23 = try CanonicalCBOR.encode(.unsigned(23))
        XCTAssertEqual(v23, Data([0x17]))
        let d23 = try CanonicalCBOR.decode(v23)
        XCTAssertEqual(d23, .unsigned(23))

        // Test 1-byte 24...255
        let v24 = try CanonicalCBOR.encode(.unsigned(24))
        XCTAssertEqual(v24, Data([0x18, 0x18]))
        let d24 = try CanonicalCBOR.decode(v24)
        XCTAssertEqual(d24, .unsigned(24))

        let v255 = try CanonicalCBOR.encode(.unsigned(255))
        XCTAssertEqual(v255, Data([0x18, 0xFF]))
        let d255 = try CanonicalCBOR.decode(v255)
        XCTAssertEqual(d255, .unsigned(255))

        // Test 2-byte 256...65535
        let v256 = try CanonicalCBOR.encode(.unsigned(256))
        XCTAssertEqual(v256, Data([0x19, 0x01, 0x00]))
        let d256 = try CanonicalCBOR.decode(v256)
        XCTAssertEqual(d256, .unsigned(256))

        let v65535 = try CanonicalCBOR.encode(.unsigned(65535))
        XCTAssertEqual(v65535, Data([0x19, 0xFF, 0xFF]))
        let d65535 = try CanonicalCBOR.decode(v65535)
        XCTAssertEqual(d65535, .unsigned(65535))

        // Test 4-byte 65536...4294967295
        let v65536 = try CanonicalCBOR.encode(.unsigned(65536))
        XCTAssertEqual(v65536, Data([0x1A, 0x00, 0x01, 0x00, 0x00]))
        let d65536 = try CanonicalCBOR.decode(v65536)
        XCTAssertEqual(d65536, .unsigned(65536))

        // Test 8-byte 4294967296...UInt64.max
        let v4294967296 = try CanonicalCBOR.encode(.unsigned(4294967296))
        XCTAssertEqual(v4294967296, Data([0x1B, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]))
        let d4294967296 = try CanonicalCBOR.decode(v4294967296)
        XCTAssertEqual(d4294967296, .unsigned(4294967296))
    }

    func testRejectNonShortestEncoding() throws {
        // 0 encoded as 1-byte: [0x18, 0x00] must be rejected
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x18, 0x00]))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .nonShortestEncoding)
        }
        // 23 encoded as 1-byte: [0x18, 0x17] must be rejected
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x18, 0x17]))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .nonShortestEncoding)
        }
        // 255 encoded as 2-byte: [0x19, 0x00, 0xFF] must be rejected
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x19, 0x00, 0xFF]))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .nonShortestEncoding)
        }
        // 65535 encoded as 4-byte: [0x1A, 0x00, 0x00, 0xFF, 0xFF] must be rejected
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x1A, 0x00, 0x00, 0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .nonShortestEncoding)
        }
        // 4294967295 encoded as 8-byte: must be rejected
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x1B, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .nonShortestEncoding)
        }
    }

    func testMajor1NegativeInt64() throws {
        // In CBOR, -1 is encoded as major 1 value 0
        let vNeg1 = try CanonicalCBOR.encode(.negative(0))
        XCTAssertEqual(vNeg1, Data([0x20]))
        let dNeg1 = try CanonicalCBOR.decode(vNeg1)
        XCTAssertEqual(dNeg1, .negative(0))

        // -10 is encoded as major 1 value 9
        let vNeg10 = try CanonicalCBOR.encode(.negative(9))
        XCTAssertEqual(vNeg10, Data([0x29]))

        // Int64.min = -9223372036854775808 -> -1 - n = Int64.min -> n = 9223372036854775807 (Int64.max)
        let maxVal = UInt64(Int64.max)
        let vMin = try CanonicalCBOR.encode(.negative(maxVal))
        let dMin = try CanonicalCBOR.decode(vMin)
        XCTAssertEqual(dMin, .negative(maxVal))
    }

    func testMajor2ByteString() throws {
        let empty = try CanonicalCBOR.encode(.byteString(Data()))
        XCTAssertEqual(empty, Data([0x40]))
        XCTAssertEqual(try CanonicalCBOR.decode(empty), .byteString(Data()))

        let hello = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = try CanonicalCBOR.encode(.byteString(hello))
        XCTAssertEqual(encoded, Data([0x44, 0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(try CanonicalCBOR.decode(encoded), .byteString(hello))

        // Reject if length exceeds available bytes
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x44, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .unexpectedEndOfData)
        }
    }

    func testMajor4Array() throws {
        let arr = CBORValue.array([.unsigned(1), .unsigned(2), .byteString(Data([0xAA]))])
        let encoded = try CanonicalCBOR.encode(arr)
        XCTAssertEqual(encoded, Data([0x83, 0x01, 0x02, 0x41, 0xAA]))
        let decoded = try CanonicalCBOR.decode(encoded)
        XCTAssertEqual(decoded, arr)
    }

    func testRejections() throws {
        // Disallowed major types:
        // Major 3 (text string)
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x60]))) // empty text string
        // Major 5 (map)
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0xA0]))) // empty map
        // Major 6 (tag)
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0xC0])))
        // Major 7 (float/simple)
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0xE0])))
        // Indefinite length
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x9F]))) // indefinite array
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x5F]))) // indefinite byte string
        // Trailing bytes
        XCTAssertThrowsError(try CanonicalCBOR.decode(Data([0x01, 0x02]))) { error in
            XCTAssertEqual(error as? CanonicalCBORError, .trailingBytes)
        }
    }
}
