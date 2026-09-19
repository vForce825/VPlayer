// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public enum CBORMajorType: UInt8, Sendable {
    case unsigned = 0
    case negative = 1
    case byteString = 2
    case array = 4
}

public enum CBORValue: Equatable, Sendable {
    case unsigned(UInt64)
    case negative(UInt64) // represents -1 - n
    case byteString(Data)
    case array([CBORValue])
}

public enum CanonicalCBORError: Error, Equatable, Sendable {
    case unsupportedMajorType(UInt8)
    case nonShortestEncoding
    case trailingBytes
    case unexpectedEndOfData
    case invalidInteger
    case indefiniteLengthNotAllowed
    case invalidLength
    case disallowedType
    case duplicateElements
    case rationalDenominatorZero
    case rationalOverflow
    case arithmeticOverflow
}

public typealias CBORError = CanonicalCBORError

public struct ExactDigest32: Equatable, Hashable, Sendable {
    public let bytes: Data

    public init(_ data: Data) throws {
        guard data.count == 32 else {
            throw CanonicalCBORError.invalidLength
        }
        self.bytes = data
    }

    public static func sha256(of data: Data) -> ExactDigest32 {
        let digest = SHA256.hash(data: data)
        return try! ExactDigest32(Data(digest))
    }

    public static let zero = try! ExactDigest32(Data(repeating: 0, count: 32))

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct ExactRational: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    public let numerator: Int64
    public let denominator: UInt64

    public init(integerLiteral value: Int64) {
        self.numerator = value
        self.denominator = 1
    }

    public init(_ integer: Int64) {
        self.numerator = integer
        self.denominator = 1
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a
        var y = b
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return x
    }

    public init(numerator: Int64, denominator: UInt64) throws {
        guard denominator > 0 else {
            throw CanonicalCBORError.rationalDenominatorZero
        }
        if numerator == 0 {
            self.numerator = 0
            self.denominator = 1
            return
        }

        let absNum: UInt64
        if numerator == Int64.min {
            absNum = 0x8000_0000_0000_0000
        } else if numerator < 0 {
            absNum = UInt64(-numerator)
        } else {
            absNum = UInt64(numerator)
        }

        let g = Self.gcd(absNum, denominator)
        let redNum = absNum / g
        let redDen = denominator / g

        if numerator < 0 {
            if redNum == 0x8000_0000_0000_0000 {
                self.numerator = Int64.min
            } else if redNum <= UInt64(Int64.max) {
                self.numerator = -Int64(redNum)
            } else {
                throw CanonicalCBORError.rationalOverflow
            }
        } else {
            guard redNum <= UInt64(Int64.max) else {
                throw CanonicalCBORError.rationalOverflow
            }
            self.numerator = Int64(redNum)
        }
        self.denominator = redDen
    }

    public var description: String {
        if denominator == 1 {
            return "\(numerator)"
        }
        return "\(numerator)/\(denominator)"
    }

    public static func < (lhs: ExactRational, rhs: ExactRational) -> Bool {
        if lhs.numerator == 0 {
            return rhs.numerator > 0
        }
        if rhs.numerator == 0 {
            return lhs.numerator < 0
        }
        if lhs.numerator < 0 && rhs.numerator > 0 {
            return true
        }
        if lhs.numerator > 0 && rhs.numerator < 0 {
            return false
        }

        let absLhsNum = lhs.numerator == Int64.min ? UInt64(0x8000_0000_0000_0000) : (lhs.numerator < 0 ? UInt64(-lhs.numerator) : UInt64(lhs.numerator))
        let absRhsNum = rhs.numerator == Int64.min ? UInt64(0x8000_0000_0000_0000) : (rhs.numerator < 0 ? UInt64(-rhs.numerator) : UInt64(rhs.numerator))

        let (h1, l1) = absLhsNum.multipliedFullWidth(by: rhs.denominator)
        let (h2, l2) = absRhsNum.multipliedFullWidth(by: lhs.denominator)

        let magLess: Bool
        if h1 != h2 {
            magLess = h1 < h2
        } else {
            magLess = l1 < l2
        }

        if lhs.numerator > 0 {
            return magLess
        } else {
            // Both negative: larger absolute magnitude means strictly smaller value
            if h1 == h2 && l1 == l2 { return false }
            return !magLess
        }
    }

    public static func + (lhs: ExactRational, rhs: ExactRational) throws -> ExactRational {
        let g = gcd(lhs.denominator, rhs.denominator)
        let d1 = lhs.denominator / g
        let d2 = rhs.denominator / g

        let (denHigh, denLow) = lhs.denominator.multipliedFullWidth(by: d2)
        guard denHigh == 0 else {
            throw CanonicalCBORError.rationalOverflow
        }

        func multiplySigned(_ n: Int64, _ d: UInt64) throws -> (isNegative: Bool, high: UInt64, low: UInt64) {
            let isNeg = n < 0
            let absN: UInt64 = n == Int64.min ? 0x8000_0000_0000_0000 : (n < 0 ? UInt64(-n) : UInt64(n))
            let (h, l) = absN.multipliedFullWidth(by: d)
            return (isNeg, h, l)
        }

        let (neg1, h1, l1) = try multiplySigned(lhs.numerator, d2)
        let (neg2, h2, l2) = try multiplySigned(rhs.numerator, d1)

        var resNeg = false
        var resHigh: UInt64 = 0
        var resLow: UInt64 = 0

        if neg1 == neg2 {
            resNeg = neg1
            let (lowSum, overflow1) = l1.addingReportingOverflow(l2)
            let (highSum, overflow2) = h1.addingReportingOverflow(h2)
            let carry: UInt64 = overflow1 ? 1 : 0
            let (highSumFinal, overflow3) = highSum.addingReportingOverflow(carry)
            guard !overflow2 && !overflow3 else {
                throw CanonicalCBORError.rationalOverflow
            }
            resLow = lowSum
            resHigh = highSumFinal
        } else {
            let mag1Greater: Bool
            if h1 != h2 {
                mag1Greater = h1 > h2
            } else {
                mag1Greater = l1 >= l2
            }

            let (highBig, lowBig) = mag1Greater ? (h1, l1) : (h2, l2)
            let (highSmall, lowSmall) = mag1Greater ? (h2, l2) : (h1, l1)
            resNeg = mag1Greater ? neg1 : neg2

            let (lowDiff, borrow1) = lowBig.subtractingReportingOverflow(lowSmall)
            let borrowVal: UInt64 = borrow1 ? 1 : 0
            let (highDiff, _) = highBig.subtractingReportingOverflow(highSmall &+ borrowVal)
            resLow = lowDiff
            resHigh = highDiff
        }

        if resHigh == 0 && resLow == 0 {
            return ExactRational(0)
        }

        guard resHigh == 0 else {
            throw CanonicalCBORError.rationalOverflow
        }

        var finalNum = resLow
        var finalDen = denLow

        let gFinal = gcd(finalNum, finalDen)
        finalNum /= gFinal
        finalDen /= gFinal

        let signedNum: Int64
        if resNeg {
            if finalNum == 0x8000_0000_0000_0000 {
                signedNum = Int64.min
            } else if finalNum <= UInt64(Int64.max) {
                signedNum = -Int64(finalNum)
            } else {
                throw CanonicalCBORError.rationalOverflow
            }
        } else {
            guard finalNum <= UInt64(Int64.max) else {
                throw CanonicalCBORError.rationalOverflow
            }
            signedNum = Int64(finalNum)
        }

        return try ExactRational(numerator: signedNum, denominator: finalDen)
    }

    public static func - (lhs: ExactRational, rhs: ExactRational) throws -> ExactRational {
        let negRhs: ExactRational
        if rhs.numerator == Int64.min {
            return try lhs + ExactRational(numerator: Int64.max, denominator: rhs.denominator) + ExactRational(numerator: 1, denominator: rhs.denominator)
        } else {
            negRhs = try ExactRational(numerator: -rhs.numerator, denominator: rhs.denominator)
        }
        return try lhs + negRhs
    }

    public static func * (lhs: ExactRational, rhs: ExactRational) throws -> ExactRational {
        if lhs.numerator == 0 || rhs.numerator == 0 {
            return ExactRational(0)
        }

        let absN1: UInt64 = lhs.numerator == Int64.min ? 0x8000_0000_0000_0000 : (lhs.numerator < 0 ? UInt64(-lhs.numerator) : UInt64(lhs.numerator))
        let absN2: UInt64 = rhs.numerator == Int64.min ? 0x8000_0000_0000_0000 : (rhs.numerator < 0 ? UInt64(-rhs.numerator) : UInt64(rhs.numerator))

        let g1 = gcd(absN1, rhs.denominator)
        let g2 = gcd(absN2, lhs.denominator)

        let n1Red = absN1 / g1
        let d2Red = rhs.denominator / g1
        let n2Red = absN2 / g2
        let d1Red = lhs.denominator / g2

        let (numHigh, numLow) = n1Red.multipliedFullWidth(by: n2Red)
        guard numHigh == 0 else {
            throw CanonicalCBORError.rationalOverflow
        }
        let (denHigh, denLow) = d1Red.multipliedFullWidth(by: d2Red)
        guard denHigh == 0 else {
            throw CanonicalCBORError.rationalOverflow
        }

        let isNeg = (lhs.numerator < 0) != (rhs.numerator < 0)
        let signedNum: Int64
        if isNeg {
            if numLow == 0x8000_0000_0000_0000 {
                signedNum = Int64.min
            } else if numLow <= UInt64(Int64.max) {
                signedNum = -Int64(numLow)
            } else {
                throw CanonicalCBORError.rationalOverflow
            }
        } else {
            guard numLow <= UInt64(Int64.max) else {
                throw CanonicalCBORError.rationalOverflow
            }
            signedNum = Int64(numLow)
        }

        return try ExactRational(numerator: signedNum, denominator: denLow)
    }

    public static func / (lhs: ExactRational, rhs: ExactRational) throws -> ExactRational {
        guard rhs.numerator != 0 else {
            throw CanonicalCBORError.rationalDenominatorZero
        }
        let reciprocal: ExactRational
        let isNeg = rhs.numerator < 0
        let absNum: UInt64 = rhs.numerator == Int64.min ? 0x8000_0000_0000_0000 : (isNeg ? UInt64(-rhs.numerator) : UInt64(rhs.numerator))

        guard rhs.denominator <= UInt64(Int64.max) else {
            throw CanonicalCBORError.rationalOverflow
        }
        let signedNum = isNeg ? -Int64(rhs.denominator) : Int64(rhs.denominator)
        reciprocal = try ExactRational(numerator: signedNum, denominator: absNum)
        return try lhs * reciprocal
    }

    public func absVal() throws -> ExactRational {
        if numerator >= 0 { return self }
        if numerator == Int64.min {
            if denominator % 2 == 0 {
                return try ExactRational(numerator: -(numerator / 2), denominator: denominator / 2)
            } else {
                throw CanonicalCBORError.arithmeticOverflow
            }
        }
        return try ExactRational(numerator: -numerator, denominator: denominator)
    }

    public func toMilliseconds() throws -> ExactRational {
        try self * ExactRational(1000)
    }

    public func toSeconds() throws -> ExactRational {
        try self / ExactRational(1000)
    }

    public func toDouble() -> Double {
        Double(numerator) / Double(denominator)
    }

    public func roundedMicroseconds() -> Int64 {
        let isNeg = numerator < 0
        let absN: UInt64 = numerator == Int64.min ? 0x8000_0000_0000_0000 : (isNeg ? UInt64(-numerator) : UInt64(numerator))
        let (h, l) = absN.multipliedFullWidth(by: 1_000_000)
        let (q, rem) = denominator.dividingFullWidth((h, l))

        let doubleRem = rem &* 2
        let carry: Bool
        if doubleRem < denominator {
            carry = false
        } else if doubleRem > denominator {
            carry = true
        } else {
            carry = (q % 2 != 0)
        }

        let roundedMagnitude = carry ? (q + 1) : q
        if isNeg {
            return -Int64(roundedMagnitude)
        } else {
            return Int64(roundedMagnitude)
        }
    }
}

public enum CanonicalCBOR {
    public static func encodeHeader(major: UInt8, value: UInt64) -> Data {
        let majorBits = (major & 0x07) << 5
        if value <= 23 {
            return Data([majorBits | UInt8(value)])
        } else if value <= 0xFF {
            return Data([majorBits | 24, UInt8(value)])
        } else if value <= 0xFFFF {
            var valBE = UInt16(value).bigEndian
            return Data([majorBits | 25]) + Data(bytes: &valBE, count: 2)
        } else if value <= 0xFFFF_FFFF {
            var valBE = UInt32(value).bigEndian
            return Data([majorBits | 26]) + Data(bytes: &valBE, count: 4)
        } else {
            var valBE = value.bigEndian
            return Data([majorBits | 27]) + Data(bytes: &valBE, count: 8)
        }
    }

    public static func encode(_ value: CBORValue) throws -> Data {
        switch value {
        case .unsigned(let val):
            return encodeHeader(major: 0, value: val)
        case .negative(let val):
            return encodeHeader(major: 1, value: val)
        case .byteString(let data):
            var out = encodeHeader(major: 2, value: UInt64(data.count))
            out.append(data)
            return out
        case .array(let items):
            var out = encodeHeader(major: 4, value: UInt64(items.count))
            for item in items {
                out.append(try encode(item))
            }
            return out
        }
    }

    public static func decode(_ data: Data) throws -> CBORValue {
        var offset = 0
        let value = try decodeItem(data: data, offset: &offset)
        guard offset == data.count else {
            throw CanonicalCBORError.trailingBytes
        }
        return value
    }

    private static func decodeItem(data: Data, offset: inout Int) throws -> CBORValue {
        guard offset < data.count else {
            throw CanonicalCBORError.unexpectedEndOfData
        }
        let initialByte = data[offset]
        offset += 1

        let major = initialByte >> 5
        let info = initialByte & 0x1F

        guard major == 0 || major == 1 || major == 2 || major == 4 else {
            throw CanonicalCBORError.unsupportedMajorType(major)
        }

        if info == 31 {
            throw CanonicalCBORError.indefiniteLengthNotAllowed
        }
        if info >= 28 && info <= 30 {
            throw CanonicalCBORError.invalidInteger
        }

        let val: UInt64
        if info <= 23 {
            val = UInt64(info)
        } else if info == 24 {
            guard offset < data.count else { throw CanonicalCBORError.unexpectedEndOfData }
            let b = data[offset]
            offset += 1
            guard b >= 24 else { throw CanonicalCBORError.nonShortestEncoding }
            val = UInt64(b)
        } else if info == 25 {
            guard offset + 2 <= data.count else { throw CanonicalCBORError.unexpectedEndOfData }
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1])
            offset += 2
            let parsed = (b0 << 8) | b1
            guard parsed >= 256 else { throw CanonicalCBORError.nonShortestEncoding }
            val = UInt64(parsed)
        } else if info == 26 {
            guard offset + 4 <= data.count else { throw CanonicalCBORError.unexpectedEndOfData }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            offset += 4
            let parsed = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            guard parsed >= 65536 else { throw CanonicalCBORError.nonShortestEncoding }
            val = UInt64(parsed)
        } else if info == 27 {
            guard offset + 8 <= data.count else { throw CanonicalCBORError.unexpectedEndOfData }
            var raw: UInt64 = 0
            for i in 0..<8 {
                raw = (raw << 8) | UInt64(data[offset + i])
            }
            offset += 8
            guard raw >= 4294967296 else { throw CanonicalCBORError.nonShortestEncoding }
            val = raw
        } else {
            throw CanonicalCBORError.invalidInteger
        }

        switch major {
        case 0:
            return .unsigned(val)
        case 1:
            return .negative(val)
        case 2:
            guard val <= UInt64(Int.max) else { throw CanonicalCBORError.invalidLength }
            let length = Int(val)
            guard offset + length <= data.count else { throw CanonicalCBORError.unexpectedEndOfData }
            let bytes = data.subdata(in: offset..<(offset + length))
            offset += length
            return .byteString(bytes)
        case 4:
            guard val <= UInt64(Int.max) else { throw CanonicalCBORError.invalidLength }
            let count = Int(val)
            var elements: [CBORValue] = []
            elements.reserveCapacity(count)
            for _ in 0..<count {
                elements.append(try decodeItem(data: data, offset: &offset))
            }
            return .array(elements)
        default:
            throw CanonicalCBORError.unsupportedMajorType(major)
        }
    }
}
