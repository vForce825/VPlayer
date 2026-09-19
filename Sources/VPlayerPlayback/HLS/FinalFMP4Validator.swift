// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CryptoKit
import Foundation

enum FinalFMP4ValidationFailure: Error, Equatable {
    case closed
    case initializationAlreadyValidated
    case identityMismatch
    case malformedTopLevelBox
    case missingRequiredBox
    case missingTrackReport
    case invalidPresentationRange
    case discontinuousTimeline
    case arithmeticOverflow
}

enum FinalFMP4MediaType: UInt8, Sendable {
    case video = 1
    case audio = 2

    var avMediaType: AVMediaType { self == .video ? .video : .audio }
}

/// 定长 SHA-256 值；凭据本体不持有 Data 或媒体分配。
struct FMP4Digest: Sendable, Hashable {
    private let word0: UInt64
    private let word1: UInt64
    private let word2: UInt64
    private let word3: UInt64

    init(rawDigest: Data) throws {
        guard rawDigest.count == 32 else { throw FinalFMP4ValidationFailure.identityMismatch }
        self = rawDigest.withUnsafeBytes { Self(rawBytes: $0) }
    }

    fileprivate init(_ digest: SHA256.Digest) {
        self = digest.withUnsafeBytes { Self(rawBytes: $0) }
    }

    private init(rawBytes: UnsafeRawBufferPointer) {
        word0 = rawBytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self).bigEndian
        word1 = rawBytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian
        word2 = rawBytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self).bigEndian
        word3 = rawBytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self).bigEndian
    }

    var bytes: Data {
        var result = Data(capacity: 32)
        append(word0, to: &result)
        append(word1, to: &result)
        append(word2, to: &result)
        append(word3, to: &result)
        return result
    }

    fileprivate func update(_ hasher: inout SHA256) {
        updateHash(word0, into: &hasher)
        updateHash(word1, into: &hasher)
        updateHash(word2, into: &hasher)
        updateHash(word3, into: &hasher)
    }

    private func append(_ word: UInt64, to data: inout Data) {
        var value = word.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

/// 可供 store 比较的普通身份快照，不具备签发或发布权限。
struct FMP4ObjectIdentity: Sendable, Hashable {
    var binding: FMP4WriterBinding
    var writerIdentity: FMP4WriterIdentity
    var callbackTicket: SegmentCallbackTicket
    var logicalSequence: UInt64
    var kind: SealedMediaObjectKind
    var backingIdentity: SealedMediaBackingIdentity
    var byteRange: AudioServiceByteRange
    var digest: FMP4Digest
    var reportIdentity: UUID

    init(_ object: SealedMediaObject) throws {
        binding = object.binding
        writerIdentity = object.writerIdentity
        callbackTicket = object.callbackTicket
        logicalSequence = object.logicalSequence
        kind = object.kind
        backingIdentity = object.backing.identity
        byteRange = object.byteRange
        digest = try FMP4Digest(rawDigest: object.digest)
        reportIdentity = object.report.identity
    }

    /// 所有字段按固定顺序、固定宽度编码；不依赖 Swift 随机 Hashable 或结构体 padding。
    var commitment: FMP4Digest {
        var hasher = SHA256()
        updateHash(UInt8(1), into: &hasher)
        let lifecycle = binding.outputLifecycleEpoch
        let backend = lifecycle.backendIdentity
        updateHash(backend.sessionIdentity.sessionID, into: &hasher)
        updateHash(backend.sessionIdentity.requestID, into: &hasher)
        updateHash(backend.backendGeneration, into: &hasher)
        updateHash(lifecycle.outputNonce, into: &hasher)
        updateHash(binding.itemGeneration.rawValue, into: &hasher)
        updateHash(binding.mediaEpoch.rawValue, into: &hasher)
        updateHash(binding.publicationParticipantID.rawValue, into: &hasher)
        updateHash(binding.renditionIdentity.rawValue, into: &hasher)
        updateHash(binding.writerIdentity.rawValue, into: &hasher)
        updateHash(writerIdentity.rawValue, into: &hasher)
        updateHash(callbackTicket.rawValue, into: &hasher)
        updateHash(logicalSequence, into: &hasher)
        updateHash(kind.rawValue, into: &hasher)
        updateHash(backingIdentity.rawValue, into: &hasher)
        updateHash(Int64(byteRange.offset), into: &hasher)
        updateHash(Int64(byteRange.length), into: &hasher)
        updateHash(Int64(byteRange.endOffset), into: &hasher)
        digest.update(&hasher)
        updateHash(reportIdentity, into: &hasher)
        return FMP4Digest(hasher.finalize())
    }
}

/// 只有本文件完成真实对象扫描后可以构造；同模块其他文件和 @testable 均不能伪造。
struct EpochFormatProof: Sendable, Hashable {
    let identity: UUID
    let initializationIdentity: FMP4ObjectIdentity
    let mediaType: FinalFMP4MediaType

    var binding: FMP4WriterBinding { initializationIdentity.binding }

    fileprivate init(initializationIdentity: FMP4ObjectIdentity, mediaType: FinalFMP4MediaType) {
        identity = UUID()
        self.initializationIdentity = initializationIdentity
        self.mediaType = mediaType
    }

    func matches(initializationIdentity: FMP4ObjectIdentity) -> Bool {
        self.initializationIdentity == initializationIdentity
    }

    func matches(initialization: SealedMediaObject) -> Bool {
        guard let identity = try? FMP4ObjectIdentity(initialization) else { return false }
        return matches(initializationIdentity: identity)
    }
}

/// 每个实例只签发一次 init proof；关闭不可逆，错误输入不消耗签发机会。
final class FinalFMP4Validator: @unchecked Sendable {
    private let lock = NSLock()
    private let binding: FMP4WriterBinding
    private let mediaType: FinalFMP4MediaType
    private var isClosed = false
    private var didIssueProof = false

    init(binding: FMP4WriterBinding, mediaType: FinalFMP4MediaType) {
        self.binding = binding
        self.mediaType = mediaType
    }

    func validateInitialization(_ object: SealedMediaObject) throws -> EpochFormatProof {
        try lock.withLock {
            guard !isClosed else { throw FinalFMP4ValidationFailure.closed }
            guard !didIssueProof else { throw FinalFMP4ValidationFailure.initializationAlreadyValidated }
            let identity = try Self.validateObject(object, kind: .initialization, binding: binding)
            let proof = EpochFormatProof(initializationIdentity: identity, mediaType: mediaType)
            didIssueProof = true
            return proof
        }
    }

    func close() { lock.withLock { isClosed = true } }

    /// 不签发任何凭据；timeline 在自身事务锁内借用同一 backing 调用。
    static func validateObject(
        _ object: SealedMediaObject,
        kind: SealedMediaObjectKind,
        binding: FMP4WriterBinding
    ) throws -> FMP4ObjectIdentity {
        guard object.binding == binding,
              object.writerIdentity == binding.writerIdentity,
              object.kind == kind,
              object.byteRange.offset == 0,
              object.byteRange.length == object.backing.bytes.count,
              object.byteRange.endOffset == object.backing.bytes.count else {
            throw FinalFMP4ValidationFailure.identityMismatch
        }
        let identity = try FMP4ObjectIdentity(object)
        try object.backing.bytes.withUnsafeBytes { bytes in
            var hasher = SHA256()
            hasher.update(bufferPointer: bytes)
            guard FMP4Digest(hasher.finalize()) == identity.digest else {
                throw FinalFMP4ValidationFailure.identityMismatch
            }
            try scanTopLevel(bytes, kind: kind)
        }
        return identity
    }

    /// 仅保存 offset 与四个存在位；不复制媒体、保存 box 数组或进入 box 内部。
    private static func scanTopLevel(_ bytes: UnsafeRawBufferPointer, kind: SealedMediaObjectKind) throws {
        guard !bytes.isEmpty else { throw FinalFMP4ValidationFailure.malformedTopLevelBox }
        var offset = 0
        var sawFTYP = false
        var sawMOOV = false
        var sawMOOF = false
        var sawMDAT = false
        while offset < bytes.count {
            let headerEnd = try checkedAdd(offset, 8)
            guard headerEnd <= bytes.count else { throw FinalFMP4ValidationFailure.malformedTopLevelBox }
            let size32 = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
            let typeOffset = try checkedAdd(offset, 4)
            let type = bytes.loadUnaligned(fromByteOffset: typeOffset, as: UInt32.self).bigEndian
            let headerSize: Int
            let size: Int
            switch size32 {
            case 0:
                headerSize = 8
                let remaining = bytes.count.subtractingReportingOverflow(offset)
                guard !remaining.overflow else { throw FinalFMP4ValidationFailure.arithmeticOverflow }
                size = remaining.partialValue
            case 1:
                headerSize = 16
                let extendedEnd = try checkedAdd(offset, headerSize)
                guard extendedEnd <= bytes.count else { throw FinalFMP4ValidationFailure.malformedTopLevelBox }
                let extendedSize = bytes.loadUnaligned(fromByteOffset: headerEnd, as: UInt64.self).bigEndian
                guard let exact = Int(exactly: extendedSize) else { throw FinalFMP4ValidationFailure.arithmeticOverflow }
                size = exact
            default:
                headerSize = 8
                guard let exact = Int(exactly: size32) else { throw FinalFMP4ValidationFailure.arithmeticOverflow }
                size = exact
            }
            guard size >= headerSize else { throw FinalFMP4ValidationFailure.malformedTopLevelBox }
            let end = try checkedAdd(offset, size)
            guard end > offset, end <= bytes.count else { throw FinalFMP4ValidationFailure.malformedTopLevelBox }
            switch type {
            case 0x66747970: sawFTYP = true
            case 0x6d6f6f76: sawMOOV = true
            case 0x6d6f6f66: sawMOOF = true
            case 0x6d646174: sawMDAT = true
            default: break
            }
            offset = end
        }
        guard kind == .initialization ? (sawFTYP && sawMOOV) : (sawMOOF && sawMDAT) else {
            throw FinalFMP4ValidationFailure.missingRequiredBox
        }
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw FinalFMP4ValidationFailure.arithmeticOverflow }
        return result.partialValue
    }
}

private func updateHash<T: FixedWidthInteger>(_ integer: T, into hasher: inout SHA256) {
    var value = integer.bigEndian
    withUnsafeBytes(of: &value) { hasher.update(bufferPointer: $0) }
}

private func updateHash(_ uuid: UUID, into hasher: inout SHA256) {
    var value = uuid.uuid
    withUnsafeBytes(of: &value) { hasher.update(bufferPointer: $0) }
}
