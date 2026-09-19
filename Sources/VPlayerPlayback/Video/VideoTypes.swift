// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

public enum CodedFieldOrder: UInt8, Sendable, Equatable, Hashable {
    case unknown, progressive, tt, bb, tb, bt
}

public enum PictureStructure: UInt8, Sendable, Equatable {
    case unknown, frame, topField, bottomField
}

public struct VideoParserMetadata: Sendable, Equatable {
    public let fieldOrder: CodedFieldOrder?
    public let pictureStructure: PictureStructure?
    public let isInterlaced: Bool?
    public let repeatFirstField: Bool
    public let topFieldFirst: Bool?
    public let sourcePTS90k: UInt64?

    public init(
        fieldOrder: CodedFieldOrder?,
        pictureStructure: PictureStructure?,
        isInterlaced: Bool?,
        repeatFirstField: Bool,
        topFieldFirst: Bool?,
        sourcePTS90k: UInt64?
    ) {
        self.fieldOrder = fieldOrder
        self.pictureStructure = pictureStructure
        self.isInterlaced = isInterlaced
        self.repeatFirstField = repeatFirstField
        self.topFieldFirst = topFieldFirst
        self.sourcePTS90k = sourcePTS90k
    }
}

public enum VideoScanClassificationEvidence: UInt8, Sendable, Hashable {
    case unresolved
    case progressive
    case interlaced

    public var isResolved: Bool { self != .unresolved }
}

enum CompressedVideoAccessUnitRebindingError: Error, Sendable, Equatable {
    case missingSourceEvidence
    case staleTargetGeneration(source: MediaGeneration, target: MediaGeneration)
    case sourceIdentityMismatch
    case sourceDigestMismatch
}

public struct CompressedVideoAccessUnit: @unchecked Sendable {
    public let id: UInt64
    public let sampleBuffer: CMSampleBuffer
    public let generation: MediaGeneration
    public let isRandomAccess: Bool
    public let randomAccessKind: VideoRandomAccessKind
    public let scanClassification: VideoScanClassificationEvidence
    public let parserMetadata: VideoParserMetadata
    public let sourceBacking: VideoAccessUnitBacking?
    public let sourceByteRange: VideoAccessUnitByteRange?
    public let sourceSHA256: VideoAccessUnitSHA256?

    public init(
        id: UInt64,
        sampleBuffer: CMSampleBuffer,
        generation: MediaGeneration,
        isRandomAccess: Bool,
        randomAccessKind: VideoRandomAccessKind? = nil,
        scanClassification: VideoScanClassificationEvidence? = nil,
        parserMetadata: VideoParserMetadata
    ) {
        self.init(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: generation,
            isRandomAccess: isRandomAccess,
            randomAccessKind: randomAccessKind,
            scanClassification: scanClassification,
            parserMetadata: parserMetadata,
            sourceEvidence: nil
        )
    }

    public init(
        id: UInt64,
        sampleBuffer: CMSampleBuffer,
        generation: MediaGeneration,
        isRandomAccess: Bool,
        randomAccessKind: VideoRandomAccessKind? = nil,
        scanClassification: VideoScanClassificationEvidence? = nil,
        parserMetadata: VideoParserMetadata,
        sourceBacking: VideoAccessUnitBacking,
        sourceByteRange: VideoAccessUnitByteRange
    ) throws {
        guard sourceBacking.identity == VideoAccessUnitBackingIdentity(
            generation: generation,
            accessUnitID: id
        ) else {
            throw VideoAccessUnitBackingError.identityMismatch
        }
        let digest = try sourceBacking.sha256(in: sourceByteRange)
        self.init(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: generation,
            isRandomAccess: isRandomAccess,
            randomAccessKind: randomAccessKind,
            scanClassification: scanClassification,
            parserMetadata: parserMetadata,
            sourceEvidence: (sourceBacking, sourceByteRange, digest)
        )
    }

    private init(
        id: UInt64,
        sampleBuffer: CMSampleBuffer,
        generation: MediaGeneration,
        isRandomAccess: Bool,
        randomAccessKind: VideoRandomAccessKind?,
        scanClassification: VideoScanClassificationEvidence?,
        parserMetadata: VideoParserMetadata,
        sourceEvidence: (
            backing: VideoAccessUnitBacking,
            byteRange: VideoAccessUnitByteRange,
            sha256: VideoAccessUnitSHA256
        )?
    ) {
        self.id = id
        self.sampleBuffer = sampleBuffer
        self.generation = generation
        self.isRandomAccess = isRandomAccess
        self.randomAccessKind = randomAccessKind ?? (isRandomAccess ? .containerKey : .none)
        self.scanClassification = scanClassification ?? Self.classification(from: parserMetadata)
        self.parserMetadata = parserMetadata
        sourceBacking = sourceEvidence?.backing
        sourceByteRange = sourceEvidence?.byteRange
        sourceSHA256 = sourceEvidence?.sha256
    }

    private static func classification(
        from metadata: VideoParserMetadata
    ) -> VideoScanClassificationEvidence {
        guard let interlaced = metadata.isInterlaced else { return .unresolved }
        return interlaced ? .interlaced : .progressive
    }

    /// pending-track replay 必须复制并重新归属原始 AU，不能把旧 generation 的 owner 带入新世代。
    func rebindingSourceEvidence(
        to targetGeneration: MediaGeneration
    ) throws -> CompressedVideoAccessUnit {
        guard targetGeneration >= generation else {
            throw CompressedVideoAccessUnitRebindingError.staleTargetGeneration(
                source: generation,
                target: targetGeneration
            )
        }
        guard let sourceBacking, let sourceByteRange, let sourceSHA256 else {
            throw CompressedVideoAccessUnitRebindingError.missingSourceEvidence
        }
        guard sourceBacking.identity == VideoAccessUnitBackingIdentity(
            generation: generation,
            accessUnitID: id
        ) else {
            throw CompressedVideoAccessUnitRebindingError.sourceIdentityMismatch
        }
        guard try sourceBacking.sha256(in: sourceByteRange) == sourceSHA256 else {
            throw CompressedVideoAccessUnitRebindingError.sourceDigestMismatch
        }

        let sourceBytes = try sourceBacking.withBytes(in: sourceBacking.wholeRange) { bytes in
            bytes.withUnsafeBytes { Data($0) }
        }
        let reboundBacking = try VideoAccessUnitBacking(
            identity: VideoAccessUnitBackingIdentity(
                generation: targetGeneration,
                accessUnitID: id
            ),
            bytes: sourceBytes
        )
        let rebound = try CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: targetGeneration,
            isRandomAccess: isRandomAccess,
            randomAccessKind: randomAccessKind,
            scanClassification: scanClassification,
            parserMetadata: parserMetadata,
            sourceBacking: reboundBacking,
            sourceByteRange: sourceByteRange
        )
        guard rebound.sourceSHA256 == sourceSHA256 else {
            throw CompressedVideoAccessUnitRebindingError.sourceDigestMismatch
        }
        return rebound
    }
}

enum VideoAssemblerEvent: @unchecked Sendable {
    case format(CMVideoFormatDescription, MediaFormatFingerprint)
    case accessUnit(CompressedVideoAccessUnit)
}
