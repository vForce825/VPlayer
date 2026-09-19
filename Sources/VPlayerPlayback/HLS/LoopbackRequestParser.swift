// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation

enum LoopbackRequestError: Error, Equatable {
    case invalidSyntax
    case requestLineTooLarge
    case headerTooLarge
    case tooManyHeaderFields
    case requestBodyForbidden
    case transferEncodingForbidden
    case duplicateContentLength
    case obsoleteLineFolding
    case pipelinedBytes
}

struct LoopbackHTTPRequest: Sendable {
    enum Method: Sendable, Equatable { case get, head, unsupported }
    let method: Method
    private let storage: Data
    private let targetRange: Range<Int>
    private let headerRange: Range<Int>

    fileprivate init(method: Method, storage: Data, targetRange: Range<Int>,
                     headerRange: Range<Int>) {
        self.method = method
        self.storage = storage
        self.targetRange = targetRange
        self.headerRange = headerRange
    }

    var target: String { String(decoding: storage[targetRange], as: UTF8.self) }

    func values(forHeader name: String) -> [String] {
        let wanted = Array(name.utf8)
        return storage.withUnsafeBytes { raw in
            let octets = raw.bindMemory(to: UInt8.self)
            var result: [String] = []
            var cursor = headerRange.lowerBound
            while cursor < headerRange.upperBound {
                guard let lineEnd = LoopbackRequestParser.firstCRLF(
                    in: octets, from: cursor, before: headerRange.upperBound),
                      let colon = (cursor..<lineEnd).first(where: { octets[$0] == 58 }) else {
                    break
                }
                let fieldName = cursor..<colon
                var valueStart = colon + 1
                while valueStart < lineEnd
                    && (octets[valueStart] == 32 || octets[valueStart] == 9) {
                    valueStart += 1
                }
                var valueEnd = lineEnd
                while valueEnd > valueStart
                    && (octets[valueEnd - 1] == 32 || octets[valueEnd - 1] == 9) {
                    valueEnd -= 1
                }
                if Self.caseInsensitiveEqual(
                    UnsafeBufferPointer(rebasing: octets[fieldName]), wanted
                ) {
                    result.append(String(decoding:
                        UnsafeBufferPointer(rebasing: octets[valueStart..<valueEnd]),
                        as: UTF8.self))
                }
                cursor = lineEnd + 2
            }
            return result
        }
    }

    private static func caseInsensitiveEqual<C: Collection>(
        _ lhs: C, _ rhs: [UInt8]
    ) -> Bool where C.Element == UInt8 {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { asciiLowercased($0.0) == asciiLowercased($0.1) }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}

/// 唯一 16 KiB wire allocation 同时承载请求字节；header 在需要时按 byte range 重扫，不另设常驻 heap。
struct LoopbackRequestParser {
    static let fixedStorageBytes = 16 * 1_024
    static let fixedHeaderFieldCapacity = 32
    private static let headerLimit = fixedStorageBytes
    private static let requestLineLimit = 4 * 1_024
    private var storage: Data
    private var storedCount = 0

    init() {
        storage = Data(count: Self.fixedStorageBytes)
    }

    mutating func append(_ bytes: Data) throws -> LoopbackHTTPRequest? {
        guard bytes.count <= Self.headerLimit - storedCount else {
            throw LoopbackRequestError.headerTooLarge
        }
        storage.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                guard bytes.count > 0,
                      let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                memcpy(destinationBase.advanced(by: storedCount), sourceBase, bytes.count)
            }
        }
        storedCount += bytes.count

        return try storage.withUnsafeBytes { raw -> LoopbackHTTPRequest? in
            let octets = raw.bindMemory(to: UInt8.self)
            guard let firstLineEnd = Self.firstCRLF(in: octets, from: 0, before: storedCount) else {
                if storedCount > Self.requestLineLimit {
                    throw LoopbackRequestError.requestLineTooLarge
                }
                return nil
            }
            guard firstLineEnd <= Self.requestLineLimit else {
                throw LoopbackRequestError.requestLineTooLarge
            }
            guard let headerEnd = Self.headerBoundary(in: octets, before: storedCount) else {
                return nil
            }
            guard headerEnd + 4 == storedCount else { throw LoopbackRequestError.pipelinedBytes }
            guard (0..<storedCount).allSatisfy({ octets[$0] < 128 && octets[$0] != 0 }) else {
                throw LoopbackRequestError.invalidSyntax
            }

            let requestLine = 0..<firstLineEnd
            var firstSpace: Int?
            var secondSpace: Int?
            var spaceCount = 0
            for index in requestLine where octets[index] == 32 {
                spaceCount += 1
                if firstSpace == nil { firstSpace = index }
                else if secondSpace == nil { secondSpace = index }
            }
            guard spaceCount == 2,
                  let firstSpace,
                  let secondSpace,
                  firstSpace > requestLine.lowerBound,
                  secondSpace > firstSpace + 1,
                  secondSpace + 1 < requestLine.upperBound,
                  Self.equals(octets, (secondSpace + 1)..<requestLine.upperBound, "HTTP/1.1") else {
                throw LoopbackRequestError.invalidSyntax
            }
            let methodRange = requestLine.lowerBound..<firstSpace
            let method: LoopbackHTTPRequest.Method
            if Self.equals(octets, methodRange, "GET") { method = .get }
            else if Self.equals(octets, methodRange, "HEAD") { method = .head }
            else { method = .unsupported }

            var cursor = firstLineEnd + 2
            var contentLength: Range<Int>?
            var headerCount = 0
            while cursor < headerEnd {
                guard let lineEnd = Self.firstCRLF(in: octets, from: cursor, before: headerEnd + 2),
                      lineEnd > cursor else { throw LoopbackRequestError.invalidSyntax }
                guard octets[cursor] != 32 && octets[cursor] != 9 else {
                    throw LoopbackRequestError.obsoleteLineFolding
                }
                guard let colon = (cursor..<lineEnd).first(where: { octets[$0] == 58 }),
                      colon > cursor else { throw LoopbackRequestError.invalidSyntax }
                let name = cursor..<colon
                guard name.allSatisfy({ Self.isFieldNameByte(octets[$0]) }) else {
                    throw LoopbackRequestError.invalidSyntax
                }
                var valueStart = colon + 1
                while valueStart < lineEnd && (octets[valueStart] == 32 || octets[valueStart] == 9) {
                    valueStart += 1
                }
                var valueEnd = lineEnd
                while valueEnd > valueStart
                    && (octets[valueEnd - 1] == 32 || octets[valueEnd - 1] == 9) {
                    valueEnd -= 1
                }
                let value = valueStart..<valueEnd
                guard value.allSatisfy({ octets[$0] == 9 || (32...126).contains(octets[$0]) }) else {
                    throw LoopbackRequestError.invalidSyntax
                }
                guard headerCount < Self.fixedHeaderFieldCapacity else {
                    throw LoopbackRequestError.tooManyHeaderFields
                }
                headerCount += 1
                if Self.caseInsensitiveEquals(octets, name, "Transfer-Encoding") {
                    throw LoopbackRequestError.transferEncodingForbidden
                }
                if Self.caseInsensitiveEquals(octets, name, "Content-Length") {
                    guard contentLength == nil else { throw LoopbackRequestError.duplicateContentLength }
                    contentLength = value
                }
                cursor = lineEnd + 2
            }
            guard cursor == headerEnd + 2 else { throw LoopbackRequestError.invalidSyntax }
            if let value = contentLength, Self.equals(octets, value, "0") == false {
                guard Self.checkedUnsignedDecimal(octets, value) != nil else {
                    throw LoopbackRequestError.invalidSyntax
                }
                throw LoopbackRequestError.requestBodyForbidden
            }
            return LoopbackHTTPRequest(method: method, storage: storage,
                targetRange: (firstSpace + 1)..<secondSpace,
                headerRange: (firstLineEnd + 2)..<(headerEnd + 2))
        }
    }

    static func parseComplete(_ bytes: Data) throws -> LoopbackHTTPRequest {
        var parser = Self()
        guard let request = try parser.append(bytes) else { throw LoopbackRequestError.invalidSyntax }
        return request
    }

    fileprivate static func firstCRLF(in bytes: UnsafeBufferPointer<UInt8>, from start: Int,
                                      before end: Int) -> Int? {
        guard end - start >= 2 else { return nil }
        for index in start..<(end - 1) where bytes[index] == 13 && bytes[index + 1] == 10 {
            return index
        }
        return nil
    }

    private static func headerBoundary(in bytes: UnsafeBufferPointer<UInt8>, before end: Int) -> Int? {
        guard end >= 4 else { return nil }
        for index in 0...(end - 4)
            where bytes[index] == 13 && bytes[index + 1] == 10
                && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    private static func checkedUnsignedDecimal(
        _ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>
    ) -> UInt64? {
        guard !range.isEmpty else { return nil }
        var value: UInt64 = 0
        for index in range {
            let byte = bytes[index]
            guard (48...57).contains(byte) else { return nil }
            let multiplied = value.multipliedReportingOverflow(by: 10)
            guard !multiplied.overflow else { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(UInt64(byte - 48))
            guard !added.overflow else { return nil }
            value = added.partialValue
        }
        return value
    }

    private static func equals(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>,
                               _ literal: StaticString) -> Bool {
        literal.withUTF8Buffer { expected in
            range.count == expected.count && zip(range, expected).allSatisfy { bytes[$0.0] == $0.1 }
        }
    }

    private static func caseInsensitiveEquals(_ bytes: UnsafeBufferPointer<UInt8>,
                                              _ range: Range<Int>, _ literal: StaticString) -> Bool {
        literal.withUTF8Buffer { expected in
            range.count == expected.count && zip(range, expected).allSatisfy {
                asciiLowercased(bytes[$0.0]) == asciiLowercased($0.1)
            }
        }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func isFieldNameByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}
