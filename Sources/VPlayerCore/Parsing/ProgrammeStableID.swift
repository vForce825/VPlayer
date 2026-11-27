// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

/// 32 字节内联 SHA-256 摘要键，用于大规模 EPG 去重，避免为每个节目分配堆上字符串。
public struct ProgrammeDigestKey: Hashable, Sendable {
    let a: UInt64
    let b: UInt64
    let c: UInt64
    let d: UInt64

    init(digest: SHA256.Digest) {
        var a: UInt64 = 0
        var b: UInt64 = 0
        var c: UInt64 = 0
        var d: UInt64 = 0
        digest.withUnsafeBytes { bytes in
            a = Self.loadUInt64(bytes, offset: 0)
            b = Self.loadUInt64(bytes, offset: 8)
            c = Self.loadUInt64(bytes, offset: 16)
            d = Self.loadUInt64(bytes, offset: 24)
        }
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    init?(hexString: String) {
        let utf8 = hexString.utf8
        guard utf8.count == 64 else { return nil }
        var index = utf8.startIndex
        guard let a = Self.parseLowercaseHexUInt64(utf8, index: &index),
              let b = Self.parseLowercaseHexUInt64(utf8, index: &index),
              let c = Self.parseLowercaseHexUInt64(utf8, index: &index),
              let d = Self.parseLowercaseHexUInt64(utf8, index: &index) else {
            return nil
        }
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    private static func loadUInt64(_ bytes: UnsafeRawBufferPointer, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }

    private static func parseLowercaseHexUInt64(
        _ utf8: String.UTF8View,
        index: inout String.UTF8View.Index
    ) -> UInt64? {
        var value: UInt64 = 0
        for _ in 0..<16 {
            let byte = utf8[index]
            let nibble: UInt64
            switch byte {
            case 0x30...0x39:
                nibble = UInt64(byte - 0x30)
            case 0x61...0x66:
                nibble = UInt64(byte - 0x61 + 10)
            default:
                return nil
            }
            value = (value << 4) | nibble
            utf8.formIndex(after: &index)
        }
        return value
    }
}

enum ProgrammeStableID {
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    static func makeDigest(
        channelIDUTF8: UnsafeBufferPointer<UInt8>,
        startEpochSeconds: Int64,
        stopEpochSeconds: Int64,
        titleUTF8: UnsafeBufferPointer<UInt8>
    ) -> SHA256.Digest {
        var hasher = SHA256()
        var version: UInt8 = 1
        var channelLength = UInt64(channelIDUTF8.count).bigEndian
        var startBE = startEpochSeconds.bigEndian
        var stopBE = stopEpochSeconds.bigEndian
        var titleLength = UInt64(titleUTF8.count).bigEndian

        Swift.withUnsafeBytes(of: &version) { hasher.update(bufferPointer: $0) }
        Swift.withUnsafeBytes(of: &channelLength) { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(channelIDUTF8))
        Swift.withUnsafeBytes(of: &startBE) { hasher.update(bufferPointer: $0) }
        Swift.withUnsafeBytes(of: &stopBE) { hasher.update(bufferPointer: $0) }
        Swift.withUnsafeBytes(of: &titleLength) { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(titleUTF8))
        return hasher.finalize()
    }

    static func makeDigest(
        channelID: String,
        startEpochSeconds: Int64,
        stopEpochSeconds: Int64,
        title: String
    ) -> SHA256.Digest {
        var channelCopy = channelID
        var titleCopy = title
        return channelCopy.withUTF8 { channelBuffer in
            titleCopy.withUTF8 { titleBuffer in
                makeDigest(
                    channelIDUTF8: channelBuffer,
                    startEpochSeconds: startEpochSeconds,
                    stopEpochSeconds: stopEpochSeconds,
                    titleUTF8: titleBuffer
                )
            }
        }
    }

    static func hexString(for digest: SHA256.Digest) -> String {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
            var offset = 0
            for byte in digest {
                buffer[offset] = hexDigits[Int(byte >> 4)]
                buffer[offset + 1] = hexDigits[Int(byte & 0x0F)]
                offset += 2
            }
            return String(decoding: UnsafeBufferPointer(buffer), as: UTF8.self)
        }
    }

    static func make(
        channelID: String,
        startEpochSeconds: Int64,
        stopEpochSeconds: Int64,
        title: String
    ) -> String {
        hexString(for: makeDigest(
            channelID: channelID,
            startEpochSeconds: startEpochSeconds,
            stopEpochSeconds: stopEpochSeconds,
            title: title
        ))
    }
}
