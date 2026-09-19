// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

/// 原始压缩视频 AU backing 的进程内值型身份。
public struct VideoAccessUnitBackingIdentity: Sendable, Hashable {
    public let generation: MediaGeneration
    public let accessUnitID: UInt64

    public init(generation: MediaGeneration, accessUnitID: UInt64) {
        self.generation = generation
        self.accessUnitID = accessUnitID
    }
}

/// 以 checked 加法建立的半开字节范围。
public struct VideoAccessUnitByteRange: Sendable, Hashable {
    public let offset: Int
    public let length: Int
    public let endOffset: Int

    public init?(offset: Int, length: Int) {
        guard offset >= 0, length >= 0 else { return nil }
        let (endOffset, overflowed) = offset.addingReportingOverflow(length)
        guard !overflowed else { return nil }
        self.offset = offset
        self.length = length
        self.endOffset = endOffset
    }

    public func contains(_ other: Self) -> Bool {
        other.offset >= offset && other.endOffset <= endOffset
    }
}

/// 不带堆 backing 的 256-bit SHA-256 值，供 proof 逐字段绑定。
public struct VideoAccessUnitSHA256: Sendable, Hashable {
    public let word0: UInt64
    public let word1: UInt64
    public let word2: UInt64
    public let word3: UInt64

    init(bytes: borrowing Span<UInt8>) {
        self = bytes.withUnsafeBytes { Self(bytes: $0) }
    }

    /// 仅供已由同步 Span/Data 闭包约束生命周期的内部解析路径使用。
    init(bytes: UnsafeRawBufferPointer) {
        var hasher = SHA256()
        hasher.update(bufferPointer: bytes)
        let digest = hasher.finalize()
        word0 = digest.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self).bigEndian
        }
        word1 = digest.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian
        }
        word2 = digest.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self).bigEndian
        }
        word3 = digest.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self).bigEndian
        }
    }

    public var hexString: String {
        String(
            format: "%016llx%016llx%016llx%016llx",
            word0,
            word1,
            word2,
            word3
        )
    }
}

public enum VideoAccessUnitBackingError: Error, Sendable, Equatable {
    case identityMismatch
    case rangeOutsideBacking
    case accessUnitTooLarge(byteCount: Int, maximumByteCount: Int)
}

/// backing owner 的强身份；proof 持有 token 时其对象地址不会被释放后复用。
public final class VideoAccessUnitBackingOwnerIdentity: @unchecked Sendable, Hashable {
    fileprivate init() {}

    public static func == (
        lhs: VideoAccessUnitBackingOwnerIdentity,
        rhs: VideoAccessUnitBackingOwnerIdentity
    ) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// 单个原始压缩视频 AU 的不可变 owner；slice 与 proof 只引用该对象。
public final class VideoAccessUnitBacking: @unchecked Sendable {
    public let identity: VideoAccessUnitBackingIdentity
    public let ownerIdentity: VideoAccessUnitBackingOwnerIdentity
    public let byteCount: Int
    public let sha256: VideoAccessUnitSHA256

    private let bytes: Data
    /// parser 的付费 frame owner；仅延续同一 Data backing 的费用，不宣称复制。
    private let parserFrameReservation: AnyObject?

    public init(
        identity: VideoAccessUnitBackingIdentity,
        bytes: Data,
        parserFrameReservation: AnyObject? = nil
    ) throws {
        guard bytes.count <= AnnexBScanner.maximumAccessUnitBytes else {
            throw VideoAccessUnitBackingError.accessUnitTooLarge(
                byteCount: bytes.count,
                maximumByteCount: AnnexBScanner.maximumAccessUnitBytes
            )
        }
        self.identity = identity
        ownerIdentity = VideoAccessUnitBackingOwnerIdentity()
        self.bytes = bytes
        self.parserFrameReservation = parserFrameReservation
        byteCount = bytes.count
        sha256 = VideoAccessUnitSHA256(bytes: bytes.span)
    }

    public var wholeRange: VideoAccessUnitByteRange {
        // Data.count 必为非负且 offset 为零，因此该范围必可表示。
        VideoAccessUnitByteRange(offset: 0, length: byteCount)!
    }

    func withBytes<Result>(
        in range: VideoAccessUnitByteRange,
        _ body: (borrowing Span<UInt8>) throws -> Result
    ) throws -> Result {
        guard range.endOffset <= byteCount else {
            throw VideoAccessUnitBackingError.rangeOutsideBacking
        }
        return try body(bytes.span.extracting(range.offset..<range.endOffset))
    }

    public func sha256(in range: VideoAccessUnitByteRange) throws -> VideoAccessUnitSHA256 {
        if range == wholeRange { return sha256 }
        return try withBytes(in: range, VideoAccessUnitSHA256.init(bytes:))
    }
}
