// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import CryptoKit

enum CompletedMediaEvidenceError: Error, Equatable {
    case identityMismatch
    case invalidRange
    case capacityExceeded
    case invalidDecodeMap
    case retired
}

/// Loopback server 的不可恢复终态边沿。它不授予任何权限，只让同一 server 的
/// evidence source 结束固定 timeline waiter；真正的 publication/endpoint 权威仍
/// 必须从原有 opaque capability 取得。
enum LoopbackTimelineFailureEvent: Sendable, Equatable {
    case serverTerminated(itemGeneration: UInt64)
    case publicationTerminated(
        itemGeneration: UInt64,
        publicationSequence: UInt64,
        resource: HLSResourceKey,
        failure: CompletedMediaEvidenceError)
}

enum CompletedBodyEvidence: Sendable, Equatable {
    case none
    case ranges(uniqueResponseCount: Int, normalizedByteRanges: [Range<Int>])
    case capacityExceeded
}

struct CompletedBodyEvidenceSnapshot: Sendable, Equatable {
    let itemGeneration: UInt64
    let renditionIdentity: AudioRenditionIdentity
    let mediaEpoch: UInt64
    let resourceIdentity: SealedMediaBackingIdentity
    let sealedDigest: Data
    let sealedBodyLength: Int
    let stateIdentity: UUID
    private let source: CompletedBodyEvidenceState
    private let capacityWasExceeded: Bool
    let uniqueResponseCount: Int
    var normalizedByteRanges: [Range<Int>] {
        source.normalizedPrefix(uniqueResponseCount)
    }
    var evidence: CompletedBodyEvidence {
        if capacityWasExceeded { return .capacityExceeded }
        return uniqueResponseCount == 0 ? .none
            : .ranges(uniqueResponseCount: uniqueResponseCount,
                      normalizedByteRanges: normalizedByteRanges)
    }
    let isComplete: Bool

    fileprivate init(source: CompletedBodyEvidenceState, count: Int,
                     capacityWasExceeded: Bool, isComplete: Bool) {
        self.source = source
        itemGeneration = source.itemGeneration
        renditionIdentity = source.renditionIdentity
        mediaEpoch = source.mediaEpoch
        resourceIdentity = source.resourceIdentity
        sealedDigest = source.sealedDigest
        sealedBodyLength = source.sealedBodyLength
        stateIdentity = source.stateIdentity
        uniqueResponseCount = count
        self.capacityWasExceeded = capacityWasExceeded
        self.isComplete = isComplete
    }

    func covers(_ required: Range<Int>) -> Bool {
        !capacityWasExceeded && source.coversPrefix(required, count: uniqueResponseCount)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stateIdentity == rhs.stateIdentity
            && lhs.uniqueResponseCount == rhs.uniqueResponseCount
            && lhs.capacityWasExceeded == rhs.capacityWasExceeded
            && lhs.isComplete == rhs.isComplete
    }
}

class CompletedBodyEvidenceState: @unchecked Sendable {
    let itemGeneration: UInt64
    let renditionIdentity: AudioRenditionIdentity
    let mediaEpoch: UInt64
    let resourceIdentity: SealedMediaBackingIdentity
    let sealedDigest: Data
    let sealedBodyLength: Int
    let stateIdentity = UUID()
    private let lock = NSLock()
    // 两个 backing 在对象建立时一次预留到规格上限；响应完成不会再扩容。
    private var completedRanges: [Range<Int>]
    private var normalizedRanges: [Range<Int>]
    private var capacityWasExceeded = false
    private var retired = false
    var evidence: CompletedBodyEvidence { lock.withLock {
        if capacityWasExceeded { return .capacityExceeded }
        return completedRanges.isEmpty ? .none
            : .ranges(uniqueResponseCount: completedRanges.count,
                      normalizedByteRanges: normalizedRanges)
    } }
    var uniqueCompletedResponseCount: Int { lock.withLock { completedRanges.count } }
    var normalizedCompletedByteRanges: [Range<Int>] { lock.withLock { normalizedRanges } }
    var isComplete: Bool { lock.withLock {
        !retired && !capacityWasExceeded && normalizedRanges == [0..<sealedBodyLength]
    } }

    init(itemGeneration: UInt64, renditionIdentity: AudioRenditionIdentity, mediaEpoch: UInt64,
         resourceIdentity: SealedMediaBackingIdentity, sealedDigest: Data, sealedBodyLength: Int) {
        self.itemGeneration = itemGeneration
        self.renditionIdentity = renditionIdentity
        self.mediaEpoch = mediaEpoch
        self.resourceIdentity = resourceIdentity
        self.sealedDigest = sealedDigest
        self.sealedBodyLength = sealedBodyLength
        completedRanges = []
        completedRanges.reserveCapacity(64)
        normalizedRanges = []
        normalizedRanges.reserveCapacity(64)
    }

    func joinCompletedLease(_ lease: HLSMediaResponseLease) throws {
        try lock.withLock {
            guard !retired else { throw CompletedMediaEvidenceError.retired }
            if capacityWasExceeded { throw CompletedMediaEvidenceError.capacityExceeded }
            guard lease.backingIdentity == resourceIdentity else {
                throw CompletedMediaEvidenceError.identityMismatch
            }
            let range = lease.completedRange
            guard sealedBodyLength > 0, range.lowerBound >= 0, range.lowerBound < range.upperBound,
                  range.upperBound <= sealedBodyLength else { throw CompletedMediaEvidenceError.invalidRange }
            guard !completedRanges.contains(range) else { return }
            if completedRanges.count == 64 {
                capacityWasExceeded = true
                throw CompletedMediaEvidenceError.capacityExceeded
            }
            completedRanges.append(range)
            // 槽号是完成到达次序，冻结watermark只能引用稳定追加槽。
            // 最多64项，反复选择下一个规范key，无需移动原槽或另造排序backing。
            normalizedRanges.removeAll(keepingCapacity: true)
            var previous: Range<Int>?
            for _ in 0..<completedRanges.count {
                var next: Range<Int>?
                for candidate in completedRanges {
                    if let previous,
                       candidate.lowerBound < previous.lowerBound
                        || (candidate.lowerBound == previous.lowerBound
                            && candidate.upperBound <= previous.upperBound) { continue }
                    if let current = next,
                       candidate.lowerBound > current.lowerBound
                        || (candidate.lowerBound == current.lowerBound
                            && candidate.upperBound >= current.upperBound) { continue }
                    next = candidate
                }
                guard let range = next else { break }
                previous = range
                guard let last = normalizedRanges.last else {
                    normalizedRanges.append(range); continue
                }
                if range.lowerBound <= last.upperBound {
                    normalizedRanges[normalizedRanges.count - 1] =
                        last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    normalizedRanges.append(range)
                }
            }
        }
    }

    func covers(_ required: [Range<Int>]) -> Bool {
        lock.withLock {
            guard !retired, !capacityWasExceeded else { return false }
            return required.allSatisfy { wanted in
                normalizedRanges.contains { $0.lowerBound <= wanted.lowerBound && $0.upperBound >= wanted.upperBound }
            }
        }
    }

    func covers(_ required: Range<Int>) -> Bool {
        lock.withLock {
            guard !retired, !capacityWasExceeded else { return false }
            return normalizedRanges.contains {
                $0.lowerBound <= required.lowerBound && $0.upperBound >= required.upperBound
            }
        }
    }

    func retire() { lock.withLock { retired = true } }
    func completedRangeSlot(_ range: Range<Int>) -> UInt8? {
        lock.withLock { completedRanges.firstIndex(of: range).map(UInt8.init) }
    }
    func completedRange(at slot: UInt8) -> Range<Int>? {
        lock.withLock {
            Int(slot) < completedRanges.count ? completedRanges[Int(slot)] : nil
        }
    }

    // 只由store已验证完整且仍持有原metadata租约的owner调用。
    func preparationSnapshot(completedCount: Int, authority: SealedCoverageIssuanceAuthority)
        -> CompletedBodyEvidenceSnapshot {
        .init(source: self, count: completedCount, capacityWasExceeded: false, isComplete: true)
    }

    fileprivate func coversPrefix(_ required: Range<Int>, count: Int) -> Bool {
        lock.withLock {
            var cursor = required.lowerBound
            for _ in 0..<count {
                var next = cursor
                for index in 0..<min(count, completedRanges.count) {
                    let range = completedRanges[index]
                    if range.lowerBound <= cursor { next = max(next, range.upperBound) }
                }
                if next >= required.upperBound { return true }
                guard next > cursor else { return false }
                cursor = next
            }
            return false
        }
    }

    // 兼容诊断值接口；生产coverage只调用coversPrefix，不取得或保留normalized backing。
    fileprivate func normalizedPrefix(_ count: Int) -> [Range<Int>] {
        lock.withLock {
            var result: [Range<Int>] = []
            var previous: Range<Int>?
            for _ in 0..<count {
                var next: Range<Int>?
                for index in 0..<min(count, completedRanges.count) {
                    let range = completedRanges[index]
                    if let previous, range.lowerBound < previous.lowerBound
                        || (range.lowerBound == previous.lowerBound
                            && range.upperBound <= previous.upperBound) { continue }
                    if let next, range.lowerBound > next.lowerBound
                        || (range.lowerBound == next.lowerBound
                            && range.upperBound >= next.upperBound) { continue }
                    next = range
                }
                guard let range = next else { break }
                previous = range
                if let last = result.last, range.lowerBound <= last.upperBound {
                    result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else { result.append(range) }
            }
            return result
        }
    }

    var snapshot: CompletedBodyEvidenceSnapshot { lock.withLock {
        return .init(source: self, count: completedRanges.count,
            capacityWasExceeded: capacityWasExceeded,
            isComplete: !retired && !capacityWasExceeded
                && normalizedRanges == [0..<sealedBodyLength])
    } }

}

final class CompletedInitBodyEvidenceState: CompletedBodyEvidenceState, @unchecked Sendable {}
final class CompletedMediaBodyEvidenceState: CompletedBodyEvidenceState, @unchecked Sendable {}

struct SealedDecodeSampleEntry: Sendable, Hashable {
    let decodeOrdinal: UInt16
    let presentationRange: FMP4PresentationRange
    let byteSpan: Range<Int>
    let nearestRandomAccessOrdinal: UInt16
    let isRandomAccess: Bool
    let containsInBandConfiguration: Bool
}

struct FMP4InitializationCompatibilityFacts: Sendable, Equatable {
    let mediaType: FinalFMP4MediaType
    let sampleEntryMode: SealedDecodeCoverageMap.SampleEntryMode
    let decoderConfigurationDigest: Data
}

struct SealedDecodeCoverageMap: Sendable {
    enum MediaType: Sendable { case video, audio }
    enum SampleEntryMode: Sendable, Equatable { case audio, avc1, avc3, hvc1, hev1 }
    let mediaType: MediaType
    let sampleEntryMode: SampleEntryMode
    let resourceIdentity: SealedMediaBackingIdentity
    let sealedBodyLength: Int
    let commonByteSpans: [Range<Int>]
    let samples: [SealedDecodeSampleEntry]
    let applicationChargeableBytes: Int
    let evidenceStateIdentity: UUID?
    let initializationStateIdentity: UUID?
    let epochProofIdentity: UUID?
    let segmentReceiptIdentity: UUID?
    let initializationBackingIdentity: SealedMediaBackingIdentity?

    static func initializationCompatibilityFacts(
        _ initialization: SealedMediaObject,
        mediaType: FinalFMP4MediaType
    ) throws -> FMP4InitializationCompatibilityFacts {
        guard initialization.kind == .initialization else {
            throw CompletedMediaEvidenceError.identityMismatch
        }
        let facts = try initialization.bytes.withUnsafeBytes {
            try FMP4DecodeMapParser.initializationFacts(
                in: $0, mediaType: mediaType)
        }
        return .init(
            mediaType: mediaType,
            sampleEntryMode: facts.mode,
            decoderConfigurationDigest: facts.decoderConfigurationDigest)
    }

    init(mediaType: MediaType, sealedBodyLength: Int, commonByteSpans: [Range<Int>],
         samples: [SealedDecodeSampleEntry]) throws {
        try self.init(mediaType: mediaType,
            sampleEntryMode: mediaType == .video ? .avc3 : .audio,
            resourceIdentity: .init(rawValue: UUID()), sealedBodyLength: sealedBodyLength,
            commonByteSpans: commonByteSpans, samples: samples,
            evidenceStateIdentity: nil, initializationStateIdentity: nil,
            epochProofIdentity: nil, segmentReceiptIdentity: nil,
            initializationBackingIdentity: nil)
    }

    /// 只有 store 已持有封口对象、proof、receipt 与同 epoch init 时才走此签发入口。
    static func seal(media: SealedMediaObject, proof: EpochFormatProof,
                     receipt: SegmentValidationReceipt,
                     initialization: SealedMediaObject,
                     evidence: CompletedMediaBodyEvidenceState,
                     initializationEvidence: CompletedInitBodyEvidenceState) throws -> Self {
        guard media.kind == .media, initialization.kind == .initialization,
              receipt.matches(media: media, proof: proof), proof.matches(initialization: initialization),
              media.backing.identity == evidence.resourceIdentity,
              initialization.backing.identity == initializationEvidence.resourceIdentity,
              media.binding.itemGeneration.rawValue == evidence.itemGeneration,
              media.binding.mediaEpoch.rawValue == evidence.mediaEpoch,
              media.binding.renditionIdentity == evidence.renditionIdentity,
              media.digest == evidence.sealedDigest, media.bytes.count == evidence.sealedBodyLength,
              initialization.binding.itemGeneration.rawValue == initializationEvidence.itemGeneration,
              initialization.binding.mediaEpoch.rawValue == initializationEvidence.mediaEpoch,
              initialization.binding.renditionIdentity == initializationEvidence.renditionIdentity,
              initialization.digest == initializationEvidence.sealedDigest,
              initialization.bytes.count == initializationEvidence.sealedBodyLength else {
            throw CompletedMediaEvidenceError.identityMismatch
        }
        let parsed = try FMP4DecodeMapParser.parse(initialization: initialization.bytes,
            media: media.bytes, mediaType: proof.mediaType,
            expectedPresentationRange: receipt.presentationRange)
        return try Self(mediaType: proof.mediaType == .video ? .video : .audio,
            sampleEntryMode: parsed.mode, resourceIdentity: media.backing.identity,
            sealedBodyLength: media.bytes.count, commonByteSpans: parsed.commonByteSpans,
            samples: parsed.samples,
            evidenceStateIdentity: evidence.stateIdentity,
            initializationStateIdentity: initializationEvidence.stateIdentity,
            epochProofIdentity: proof.identity,
            segmentReceiptIdentity: receipt.identity,
            initializationBackingIdentity: initialization.backing.identity)
    }

    /// 同一 rendition 的后继物理 AAC writer 继续使用 canonical init URL 时，
    /// 只有 writer continuation 私签的兼容能力可以走此入口。parser 仍以实际
    /// HTTP 服务的 canonical init 字节解析后继 media，不能用 capability 代替解析。
    static func sealAACWriterWindow(
        media: SealedMediaObject,
        proof: EpochFormatProof,
        receipt: SegmentValidationReceipt,
        canonicalInitialization: SealedMediaObject,
        canonicalProof: EpochFormatProof,
        compatibility: AACWriterInitializationCompatibility,
        evidence: CompletedMediaBodyEvidenceState,
        initializationEvidence: CompletedInitBodyEvidenceState
    ) throws -> Self {
        guard media.kind == .media, canonicalInitialization.kind == .initialization,
              compatibility.authorizes(canonicalInitialization: canonicalInitialization,
                  canonicalProof: canonicalProof, successorProof: proof),
              receipt.matches(media: media, proof: proof),
              media.backing.identity == evidence.resourceIdentity,
              canonicalInitialization.backing.identity == initializationEvidence.resourceIdentity,
              media.binding.itemGeneration.rawValue == evidence.itemGeneration,
              media.binding.mediaEpoch.rawValue == evidence.mediaEpoch,
              media.binding.renditionIdentity == evidence.renditionIdentity,
              media.digest == evidence.sealedDigest, media.bytes.count == evidence.sealedBodyLength,
              canonicalInitialization.binding.itemGeneration.rawValue == initializationEvidence.itemGeneration,
              canonicalInitialization.binding.mediaEpoch.rawValue == initializationEvidence.mediaEpoch,
              canonicalInitialization.binding.renditionIdentity == initializationEvidence.renditionIdentity,
              canonicalInitialization.digest == initializationEvidence.sealedDigest,
              canonicalInitialization.bytes.count == initializationEvidence.sealedBodyLength else {
            throw CompletedMediaEvidenceError.identityMismatch
        }
        let parsed = try FMP4DecodeMapParser.parse(initialization: canonicalInitialization.bytes,
            media: media.bytes, mediaType: proof.mediaType,
            expectedPresentationRange: receipt.presentationRange)
        return try Self(mediaType: proof.mediaType == .video ? .video : .audio,
            sampleEntryMode: parsed.mode, resourceIdentity: media.backing.identity,
            sealedBodyLength: media.bytes.count, commonByteSpans: parsed.commonByteSpans,
            samples: parsed.samples,
            evidenceStateIdentity: evidence.stateIdentity,
            initializationStateIdentity: initializationEvidence.stateIdentity,
            epochProofIdentity: proof.identity,
            segmentReceiptIdentity: receipt.identity,
            initializationBackingIdentity: canonicalInitialization.backing.identity)
    }

    static func sealWriterWindow(
        media: SealedMediaObject,
        proof: EpochFormatProof,
        receipt: SegmentValidationReceipt,
        canonicalInitialization: SealedMediaObject,
        canonicalProof: EpochFormatProof,
        compatibility: WriterInitializationCompatibility,
        evidence: CompletedMediaBodyEvidenceState,
        initializationEvidence: CompletedInitBodyEvidenceState
    ) throws -> Self {
        guard media.kind == .media, canonicalInitialization.kind == .initialization,
              compatibility.authorizes(
                canonicalInitialization: canonicalInitialization,
                canonicalProof: canonicalProof,
                successorProof: proof),
              receipt.matches(media: media, proof: proof),
              media.backing.identity == evidence.resourceIdentity,
              canonicalInitialization.backing.identity
                == initializationEvidence.resourceIdentity,
              media.binding.itemGeneration.rawValue == evidence.itemGeneration,
              media.binding.mediaEpoch.rawValue == evidence.mediaEpoch,
              media.binding.renditionIdentity == evidence.renditionIdentity,
              media.digest == evidence.sealedDigest,
              media.bytes.count == evidence.sealedBodyLength,
              canonicalInitialization.binding.itemGeneration.rawValue
                == initializationEvidence.itemGeneration,
              canonicalInitialization.binding.mediaEpoch.rawValue
                == initializationEvidence.mediaEpoch,
              canonicalInitialization.binding.renditionIdentity
                == initializationEvidence.renditionIdentity,
              canonicalInitialization.digest == initializationEvidence.sealedDigest,
              canonicalInitialization.bytes.count
                == initializationEvidence.sealedBodyLength else {
            throw CompletedMediaEvidenceError.identityMismatch
        }
        let parsed = try FMP4DecodeMapParser.parse(
            initialization: canonicalInitialization.bytes,
            media: media.bytes,
            mediaType: proof.mediaType,
            expectedPresentationRange: receipt.presentationRange)
        return try Self(
            mediaType: proof.mediaType == .video ? .video : .audio,
            sampleEntryMode: parsed.mode,
            resourceIdentity: media.backing.identity,
            sealedBodyLength: media.bytes.count,
            commonByteSpans: parsed.commonByteSpans,
            samples: parsed.samples,
            evidenceStateIdentity: evidence.stateIdentity,
            initializationStateIdentity: initializationEvidence.stateIdentity,
            epochProofIdentity: proof.identity,
            segmentReceiptIdentity: receipt.identity,
            initializationBackingIdentity: canonicalInitialization.backing.identity)
    }

    /// publication commit 只消费由上述两个 seal 入口生成的完整身份闭包；
    /// 普通 caller 可构造的无身份 map 永远不能通过。
    func authorizesPublication(media: SealedMediaObject,
                               proof: EpochFormatProof,
                               receipt: SegmentValidationReceipt,
                               initialization: SealedMediaObject,
                               mediaEvidence: CompletedBodyEvidenceState,
                               initializationEvidence: CompletedBodyEvidenceState) -> Bool {
        resourceIdentity == media.backing.identity
            && sealedBodyLength == media.bytes.count
            && evidenceStateIdentity == mediaEvidence.stateIdentity
            && initializationStateIdentity == initializationEvidence.stateIdentity
            && epochProofIdentity == proof.identity
            && segmentReceiptIdentity == receipt.identity
            && initializationBackingIdentity == initialization.backing.identity
            && receipt.matches(media: media, proof: proof)
    }

    private init(mediaType: MediaType, sampleEntryMode: SampleEntryMode,
                 resourceIdentity: SealedMediaBackingIdentity,
                 sealedBodyLength: Int, commonByteSpans: [Range<Int>],
                 samples: [SealedDecodeSampleEntry], evidenceStateIdentity: UUID?,
                 initializationStateIdentity: UUID?, epochProofIdentity: UUID?,
                 segmentReceiptIdentity: UUID?,
                 initializationBackingIdentity: SealedMediaBackingIdentity?) throws {
        guard sealedBodyLength > 0, !samples.isEmpty, samples.count <= 256 else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        let charge = try LoopbackStorageLayout.current.decodeMapAllocation(
            sampleCount: samples.count, commonSpanCount: commonByteSpans.count)
        let allSpans = commonByteSpans + samples.map(\.byteSpan)
        guard allSpans.allSatisfy({ $0.lowerBound >= 0 && !$0.isEmpty && $0.upperBound <= sealedBodyLength }) else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        for (index, sample) in samples.enumerated() {
            guard sample.decodeOrdinal == UInt16(index), sample.presentationRange.duration.value > 0 else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            if mediaType == .video {
                let rap = Int(sample.nearestRandomAccessOrdinal)
                guard rap <= index, samples[rap].isRandomAccess else {
                    throw CompletedMediaEvidenceError.invalidDecodeMap
                }
            } else {
                guard sample.nearestRandomAccessOrdinal == sample.decodeOrdinal else {
                    throw CompletedMediaEvidenceError.invalidDecodeMap
                }
            }
        }
        if mediaType == .audio {
            let presentationOrdered = try samples.sorted {
                let start = try HLSChecked.compare($0.presentationRange.start,
                                                   $1.presentationRange.start)
                if start != 0 { return start < 0 }
                return try HLSChecked.compare($0.presentationRange.end,
                                              $1.presentationRange.end) < 0
            }
            var presentationEnd = presentationOrdered[0].presentationRange.end
            for sample in presentationOrdered.dropFirst() {
                guard try HLSChecked.compare(sample.presentationRange.start,
                                             presentationEnd) <= 0 else {
                    throw CompletedMediaEvidenceError.invalidDecodeMap
                }
                if try HLSChecked.compare(sample.presentationRange.end,
                                          presentationEnd) > 0 {
                    presentationEnd = sample.presentationRange.end
                }
            }
        }
        self.mediaType = mediaType
        self.sampleEntryMode = sampleEntryMode
        self.resourceIdentity = resourceIdentity
        self.sealedBodyLength = sealedBodyLength
        self.commonByteSpans = commonByteSpans
        self.samples = samples
        applicationChargeableBytes = charge
        self.evidenceStateIdentity = evidenceStateIdentity
        self.initializationStateIdentity = initializationStateIdentity
        self.epochProofIdentity = epochProofIdentity
        self.segmentReceiptIdentity = segmentReceiptIdentity
        self.initializationBackingIdentity = initializationBackingIdentity
    }

    func isCovered(by evidence: CompletedBodyEvidenceSnapshot,
                   requested: FMP4PresentationRange) throws -> Bool {
        func reject(_ marker: String) -> Bool {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.append(marker)
            #endif
            return false
        }
        let selected = try samples.indices.filter {
            try Self.intersects(samples[$0].presentationRange, requested)
        }
        guard !selected.isEmpty else { return reject("mapcov_empty") }
        let ordered = try selected.map { samples[$0].presentationRange }.sorted {
            let start = try HLSChecked.compare($0.start, $1.start)
            if start != 0 { return start < 0 }
            return try HLSChecked.compare($0.end, $1.end) < 0
        }
        guard try HLSChecked.compare(ordered[0].start, requested.start) <= 0 else {
            return reject("mapcov_late_start")
        }
        var coveredEnd = ordered[0].end
        for range in ordered.dropFirst() where try HLSChecked.compare(coveredEnd, requested.end) < 0 {
            guard try HLSChecked.compare(range.start, coveredEnd) <= 0 else {
                return reject("mapcov_sample_gap")
            }
            if try HLSChecked.compare(range.end, coveredEnd) > 0 { coveredEnd = range.end }
        }
        guard try HLSChecked.compare(coveredEnd, requested.end) >= 0 else {
            return reject("mapcov_early_end")
        }
        let firstSelected = selected.min()!
        let lastSelected = selected.max()!
        let firstRequired = mediaType == .video
            ? Int(samples[firstSelected].nearestRandomAccessOrdinal) : firstSelected
        for span in commonByteSpans where !evidence.covers(span) {
            return reject("mapcov_common_bytes")
        }
        for index in firstRequired...lastSelected where !evidence.covers(samples[index].byteSpan) {
            return reject("mapcov_sample_bytes")
        }
        return true
    }

    /// 视频重排序允许相邻 fragment 的 presentation sample 互相填补时间线。
    /// 单个 map 只返回自身真实可解码且字节已完成的连续片段，上层再对同一
    /// rendition 的多个 completed response 求并集。
    func coveredFragments(
        by evidence: CompletedBodyEvidenceSnapshot,
        intersecting requested: FMP4PresentationRange
    ) throws -> [FMP4PresentationRange] {
        guard commonByteSpans.allSatisfy(evidence.covers) else { return [] }
        let videoHold: ExactMediaTime?
        if mediaType == .video,
           let maximumDuration = try samples.map(\.presentationRange.duration).max(by: {
               try HLSChecked.compare($0, $1) < 0
           }) {
            let multiplied = maximumDuration.value.multipliedReportingOverflow(by: 3)
            guard !multiplied.overflow else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            videoHold = .init(value: multiplied.partialValue,
                              timescale: maximumDuration.timescale)
        } else {
            videoHold = nil
        }
        var coveredSamples: [FMP4PresentationRange] = []
        coveredSamples.reserveCapacity(min(samples.count, 64))
        for index in samples.indices {
            let sample = samples[index]
            guard try Self.intersects(sample.presentationRange, requested) else { continue }
            let firstRequired = mediaType == .video
                ? Int(sample.nearestRandomAccessOrdinal) : index
            guard (firstRequired...index).allSatisfy({
                evidence.covers(samples[$0].byteSpan)
            }) else { continue }
            let start = try HLSChecked.compare(sample.presentationRange.start,
                                               requested.start) < 0
                ? requested.start : sample.presentationRange.start
            let heldEnd = try videoHold.map {
                try sample.presentationRange.end.adding($0)
            } ?? sample.presentationRange.end
            let end = try HLSChecked.compare(heldEnd, requested.end) > 0
                ? requested.end : heldEnd
            guard try HLSChecked.compare(start, end) < 0 else { continue }
            coveredSamples.append(try FMP4PresentationRange(
                start: start,
                duration: end.subtracting(start)
            ))
        }
        let ordered = try coveredSamples.sorted {
            let start = try HLSChecked.compare($0.start, $1.start)
            if start != 0 { return start < 0 }
            return try HLSChecked.compare($0.end, $1.end) < 0
        }
        var fragments: [FMP4PresentationRange] = []
        fragments.reserveCapacity(ordered.count)
        for clipped in ordered {
            if let previous = fragments.last,
               try HLSChecked.compare(clipped.start, previous.end) <= 0 {
                let mergedEnd = try HLSChecked.compare(clipped.end, previous.end) > 0
                    ? clipped.end : previous.end
                fragments[fragments.count - 1] = try FMP4PresentationRange(
                    start: previous.start,
                    duration: mergedEnd.subtracting(previous.start)
                )
            } else {
                fragments.append(clipped)
            }
        }
        return fragments
    }

    func intersection(with requested: FMP4PresentationRange) throws -> FMP4PresentationRange? {
        let ordered = try samples.map(\.presentationRange).sorted {
            let start = try HLSChecked.compare($0.start, $1.start)
            if start != 0 { return start < 0 }
            return try HLSChecked.compare($0.end, $1.end) < 0
        }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        let start = try HLSChecked.compare(first.start, requested.start) > 0
            ? first.start : requested.start
        let end = try HLSChecked.compare(last.end, requested.end) < 0
            ? last.end : requested.end
        guard try HLSChecked.compare(start, end) < 0 else { return nil }
        return try FMP4PresentationRange(start: start, duration: end.subtracting(start))
    }

    private static func intersects(_ lhs: FMP4PresentationRange,
                                   _ rhs: FMP4PresentationRange) throws -> Bool {
        try HLSChecked.compare(lhs.start, rhs.end) < 0 && HLSChecked.compare(rhs.start, lhs.end) < 0
    }

}

/// 只读遍历已封口 init/fragment；保存最终固定上限的 sample 表，不复制媒体或物化 box 树。
private enum FMP4DecodeMapParser {
    private struct Box {
        let start: Int
        let payloadStart: Int
        let end: Int
        let type: UInt32
        var range: Range<Int> { start..<end }
        var payload: Range<Int> { payloadStart..<end }
    }

    fileprivate struct InitializationFacts {
        let timescale: Int32
        let mode: SealedDecodeCoverageMap.SampleEntryMode
        let nalLengthBytes: Int
        let decoderConfigurationDigest: Data
    }

    private struct TrackDefaults {
        let baseDataOffset: Int
        let duration: UInt32?
        let size: UInt32?
        let flags: UInt32?
    }

    struct Result {
        let mode: SealedDecodeCoverageMap.SampleEntryMode
        let commonByteSpans: [Range<Int>]
        let samples: [SealedDecodeSampleEntry]
    }

    static func parse(initialization: Data, media: Data, mediaType: FinalFMP4MediaType,
                      expectedPresentationRange: FMP4PresentationRange) throws -> Result {
        try initialization.withUnsafeBytes { initBytes in
            try media.withUnsafeBytes { mediaBytes in
                let facts = try initializationFacts(in: initBytes, mediaType: mediaType)
                let moof = try requiredBox(0x6d6f6f66, in: 0..<mediaBytes.count, bytes: mediaBytes)
                let traf = try requiredBox(0x74726166, in: moof.payload, bytes: mediaBytes)
                let tfhd = try requiredBox(0x74666864, in: traf.payload, bytes: mediaBytes)
                let tfdt = try requiredBox(0x74666474, in: traf.payload, bytes: mediaBytes)
                let mdat = try requiredBox(0x6d646174, in: 0..<mediaBytes.count, bytes: mediaBytes)
                let defaults = try trackDefaults(tfhd, moofStart: moof.start, bytes: mediaBytes)
                var decodeTime = try baseDecodeTime(tfdt, bytes: mediaBytes)
                let initialDecodeTime = decodeTime
                var payloadCursor = mdat.payloadStart
                var samples: [SealedDecodeSampleEntry] = []
                samples.reserveCapacity(256)
                var nearestRandomAccess: UInt16?
                var childOffset = traf.payloadStart
                while childOffset < traf.end {
                    let child = try readBox(at: childOffset, limit: traf.end, bytes: mediaBytes)
                    if child.type == 0x7472756e {
                        try appendRun(child, moofStart: moof.start, defaults: defaults,
                            facts: facts, bytes: mediaBytes, decodeTime: &decodeTime,
                            payloadCursor: &payloadCursor, nearestRandomAccess: &nearestRandomAccess,
                            samples: &samples)
                    }
                    childOffset = child.end
                }
                guard !samples.isEmpty else {
                    throw CompletedMediaEvidenceError.invalidDecodeMap
                }
                let firstStart = try samples.reduce(samples[0].presentationRange.start) {
                    try HLSChecked.compare($1.presentationRange.start, $0) < 0
                        ? $1.presentationRange.start : $0
                }
                let lastEnd = try samples.reduce(samples[0].presentationRange.end) {
                    try HLSChecked.compare($1.presentationRange.end, $0) > 0
                        ? $1.presentationRange.end : $0
                }
                let startCmp = try HLSChecked.compare(firstStart, expectedPresentationRange.start)
                guard startCmp == 0 else {
                    throw CompletedMediaEvidenceError.invalidDecodeMap
                }
                if mediaType == .audio {
                    let endCmp = try HLSChecked.compare(lastEnd, expectedPresentationRange.end)
                    guard endCmp == 0 else {
                        throw CompletedMediaEvidenceError.invalidDecodeMap
                    }
                    let presentationOrdered = try samples.sorted {
                        let start = try HLSChecked.compare($0.presentationRange.start,
                                                           $1.presentationRange.start)
                        if start != 0 { return start < 0 }
                        return try HLSChecked.compare($0.presentationRange.end,
                                                      $1.presentationRange.end) < 0
                    }
                    var presentationEnd = presentationOrdered[0].presentationRange.end
                    for sample in presentationOrdered.dropFirst() {
                        guard try HLSChecked.compare(sample.presentationRange.start,
                                                     presentationEnd) <= 0 else {
                            throw CompletedMediaEvidenceError.invalidDecodeMap
                        }
                        if try HLSChecked.compare(sample.presentationRange.end,
                                                  presentationEnd) > 0 {
                            presentationEnd = sample.presentationRange.end
                        }
                    }
                } else {
                    guard decodeTime >= initialDecodeTime else {
                        throw CompletedMediaEvidenceError.invalidDecodeMap
                    }
                    let totalDecodeDuration = ExactMediaTime(
                        value: Int64(decodeTime - initialDecodeTime),
                        timescale: facts.timescale
                    )
                    let durationCmp = try HLSChecked.compare(totalDecodeDuration, expectedPresentationRange.duration)
                    guard durationCmp == 0 else {
                        throw CompletedMediaEvidenceError.invalidDecodeMap
                    }
                    let maxAllowedEnd = try expectedPresentationRange.end.adding(ExactMediaTime(value: 2, timescale: 1))
                    guard try HLSChecked.compare(lastEnd, expectedPresentationRange.start) >= 0,
                          try HLSChecked.compare(lastEnd, maxAllowedEnd) <= 0 else {
                        throw CompletedMediaEvidenceError.invalidDecodeMap
                    }
                }
                var common: [Range<Int>] = []
                common.reserveCapacity(2)
                common.append(moof.range)
                common.append(mdat.start..<mdat.payloadStart)
                return Result(mode: facts.mode, commonByteSpans: common, samples: samples)
            }
        }
    }

    fileprivate static func initializationFacts(in bytes: UnsafeRawBufferPointer,
                                                 mediaType: FinalFMP4MediaType) throws -> InitializationFacts {
        let moov = try requiredBox(0x6d6f6f76, in: 0..<bytes.count, bytes: bytes)
        var offset = moov.payloadStart
        while offset < moov.end {
            let trak = try readBox(at: offset, limit: moov.end, bytes: bytes)
            offset = trak.end
            guard trak.type == 0x7472616b,
                  let mdia = try optionalBox(0x6d646961, in: trak.payload, bytes: bytes),
                  let hdlr = try optionalBox(0x68646c72, in: mdia.payload, bytes: bytes),
                  try handlerType(hdlr, bytes: bytes) == (mediaType == .video ? 0x76696465 : 0x736f756e) else {
                continue
            }
            let mdhd = try requiredBox(0x6d646864, in: mdia.payload, bytes: bytes)
            let timescale = try mediaTimescale(mdhd, bytes: bytes)
            let minf = try requiredBox(0x6d696e66, in: mdia.payload, bytes: bytes)
            let stbl = try requiredBox(0x7374626c, in: minf.payload, bytes: bytes)
            let stsd = try requiredBox(0x73747364, in: stbl.payload, bytes: bytes)
            if mediaType == .audio {
                return try audioSampleEntry(stsd, timescale: timescale, bytes: bytes)
            }
            return try videoSampleEntry(stsd, timescale: timescale, bytes: bytes)
        }
        throw CompletedMediaEvidenceError.invalidDecodeMap
    }

    private static func handlerType(_ box: Box, bytes: UnsafeRawBufferPointer) throws -> UInt32 {
        try require(box.payloadStart, 12, within: box.end)
        return readUInt32(box.payloadStart + 8, bytes: bytes)
    }

    private static func mediaTimescale(_ box: Box, bytes: UnsafeRawBufferPointer) throws -> Int32 {
        try require(box.payloadStart, 4, within: box.end)
        let version = bytes[box.payloadStart]
        let offset = box.payloadStart + (version == 1 ? 20 : 12)
        try require(offset, 4, within: box.end)
        let value = readUInt32(offset, bytes: bytes)
        guard value > 0, let timescale = Int32(exactly: value) else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        return timescale
    }

    private static func videoSampleEntry(_ stsd: Box, timescale: Int32,
                                         bytes: UnsafeRawBufferPointer) throws -> InitializationFacts {
        let entryOffset = stsd.payloadStart + 8
        try require(stsd.payloadStart, 8, within: stsd.end)
        guard readUInt32(stsd.payloadStart + 4, bytes: bytes) == 1 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let entry = try readBox(at: entryOffset, limit: stsd.end, bytes: bytes)
        let mode: SealedDecodeCoverageMap.SampleEntryMode
        let configurationType: UInt32
        switch entry.type {
        case 0x61766331: mode = .avc1; configurationType = 0x61766343
        case 0x61766333: mode = .avc3; configurationType = 0x61766343
        case 0x68766331: mode = .hvc1; configurationType = 0x68766343
        case 0x68657631: mode = .hev1; configurationType = 0x68766343
        default: throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let extensionStart = entry.payloadStart + 78
        try require(entry.payloadStart, 78, within: entry.end)
        let configuration = try requiredBox(configurationType,
            in: extensionStart..<entry.end, bytes: bytes)
        let fieldOffset = configuration.payloadStart + (configurationType == 0x61766343 ? 4 : 21)
        try require(fieldOffset, 1, within: configuration.end)
        let nalLengthBytes = Int(bytes[fieldOffset] & 0x03) + 1
        return InitializationFacts(
            timescale: timescale, mode: mode,
            nalLengthBytes: nalLengthBytes,
            decoderConfigurationDigest: Data(SHA256.hash(
                data: Data(bytes[entry.range]))))
    }

    private static func audioSampleEntry(
        _ stsd: Box,
        timescale: Int32,
        bytes: UnsafeRawBufferPointer
    ) throws -> InitializationFacts {
        try require(stsd.payloadStart, 8, within: stsd.end)
        guard readUInt32(stsd.payloadStart + 4, bytes: bytes) == 1 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let entry = try readBox(
            at: stsd.payloadStart + 8, limit: stsd.end, bytes: bytes)
        guard entry.type == 0x6d703461 || entry.type == 0x61632d33
                || entry.type == 0x65632d33 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        return InitializationFacts(
            timescale: timescale, mode: .audio, nalLengthBytes: 0,
            decoderConfigurationDigest: Data(SHA256.hash(
                data: Data(bytes[entry.range]))))
    }

    private static func trackDefaults(_ tfhd: Box, moofStart: Int,
                                      bytes: UnsafeRawBufferPointer) throws -> TrackDefaults {
        try require(tfhd.payloadStart, 8, within: tfhd.end)
        let flags = readUInt32(tfhd.payloadStart, bytes: bytes) & 0x00ff_ffff
        var offset = tfhd.payloadStart + 8
        var base = moofStart
        if flags & 0x000001 != 0 {
            try require(offset, 8, within: tfhd.end)
            guard let exact = Int(exactly: readUInt64(offset, bytes: bytes)) else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            base = exact; offset += 8
        }
        if flags & 0x000002 != 0 { try require(offset, 4, within: tfhd.end); offset += 4 }
        let duration = try optionalUInt32(flag: 0x000008, flags: flags, offset: &offset,
                                          limit: tfhd.end, bytes: bytes)
        let size = try optionalUInt32(flag: 0x000010, flags: flags, offset: &offset,
                                      limit: tfhd.end, bytes: bytes)
        let sampleFlags = try optionalUInt32(flag: 0x000020, flags: flags, offset: &offset,
                                             limit: tfhd.end, bytes: bytes)
        return TrackDefaults(baseDataOffset: base, duration: duration, size: size, flags: sampleFlags)
    }

    private static func optionalUInt32(flag: UInt32, flags: UInt32, offset: inout Int,
                                       limit: Int, bytes: UnsafeRawBufferPointer) throws -> UInt32? {
        guard flags & flag != 0 else { return nil }
        try require(offset, 4, within: limit)
        defer { offset += 4 }
        return readUInt32(offset, bytes: bytes)
    }

    private static func baseDecodeTime(_ tfdt: Box, bytes: UnsafeRawBufferPointer) throws -> UInt64 {
        try require(tfdt.payloadStart, 8, within: tfdt.end)
        if bytes[tfdt.payloadStart] == 1 {
            try require(tfdt.payloadStart + 4, 8, within: tfdt.end)
            return readUInt64(tfdt.payloadStart + 4, bytes: bytes)
        }
        return UInt64(readUInt32(tfdt.payloadStart + 4, bytes: bytes))
    }

    private static func appendRun(_ run: Box, moofStart: Int, defaults: TrackDefaults,
                                  facts: InitializationFacts, bytes: UnsafeRawBufferPointer,
                                  decodeTime: inout UInt64, payloadCursor: inout Int,
                                  nearestRandomAccess: inout UInt16?,
                                  samples: inout [SealedDecodeSampleEntry]) throws {
        try require(run.payloadStart, 8, within: run.end)
        let version = bytes[run.payloadStart]
        let flags = readUInt32(run.payloadStart, bytes: bytes) & 0x00ff_ffff
        guard flags & 0x000004 == 0 || flags & 0x000400 == 0 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        guard let count = Int(exactly: readUInt32(run.payloadStart + 4, bytes: bytes)),
              count > 0, samples.count + count <= 256 else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        var offset = run.payloadStart + 8
        if flags & 0x000001 != 0 {
            try require(offset, 4, within: run.end)
            let relative = Int(Int32(bitPattern: readUInt32(offset, bytes: bytes)))
            payloadCursor = try checkedAdd(defaults.baseDataOffset, relative)
            offset += 4
        }
        var firstSampleFlags: UInt32?
        if flags & 0x000004 != 0 {
            try require(offset, 4, within: run.end)
            firstSampleFlags = readUInt32(offset, bytes: bytes)
            offset += 4
        }
        for index in 0..<count {
            let duration: UInt32
            if flags & 0x000100 != 0 {
                try require(offset, 4, within: run.end)
                duration = readUInt32(offset, bytes: bytes); offset += 4
            } else if let value = defaults.duration { duration = value }
            else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            let size: UInt32
            if flags & 0x000200 != 0 {
                try require(offset, 4, within: run.end)
                size = readUInt32(offset, bytes: bytes); offset += 4
            } else if let value = defaults.size { size = value }
            else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            let sampleFlags: UInt32
            if flags & 0x000400 != 0 {
                try require(offset, 4, within: run.end)
                sampleFlags = readUInt32(offset, bytes: bytes); offset += 4
            } else { sampleFlags = index == 0 ? (firstSampleFlags ?? defaults.flags ?? 0) : (defaults.flags ?? 0) }
            var compositionOffset: Int64 = 0
            if flags & 0x000800 != 0 {
                try require(offset, 4, within: run.end)
                let raw = readUInt32(offset, bytes: bytes); offset += 4
                compositionOffset = version == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
            }
            guard duration > 0, size > 0, let sampleBytes = Int(exactly: size) else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            let sampleEnd = try checkedAdd(payloadCursor, sampleBytes)
            let byteSpan = payloadCursor..<sampleEnd
            guard try isInsideMediaPayload(byteSpan, bytes: bytes),
                  let ordinal = UInt16(exactly: samples.count),
                  let decodeValue = Int64(exactly: decodeTime) else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            let presentationValue = decodeValue.addingReportingOverflow(compositionOffset)
            guard !presentationValue.overflow, presentationValue.partialValue >= 0 else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            let range = try FMP4PresentationRange(
                start: ExactMediaTime(value: presentationValue.partialValue, timescale: facts.timescale),
                duration: ExactMediaTime(value: Int64(duration), timescale: facts.timescale))
            let randomAccess = facts.mode == .audio || sampleFlags & 0x0001_0000 == 0
            if randomAccess { nearestRandomAccess = ordinal }
            guard facts.mode == .audio || nearestRandomAccess != nil else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            let inBand = try configurationPresence(in: byteSpan, facts: facts, bytes: bytes)
            samples.append(.init(decodeOrdinal: ordinal, presentationRange: range, byteSpan: byteSpan,
                nearestRandomAccessOrdinal: facts.mode == .audio ? ordinal : nearestRandomAccess!,
                isRandomAccess: randomAccess, containsInBandConfiguration: inBand))
            decodeTime = try checkedAdd(decodeTime, UInt64(duration))
            payloadCursor = sampleEnd
        }
        guard offset == run.end else { throw CompletedMediaEvidenceError.invalidDecodeMap }
    }

    private static func configurationPresence(in span: Range<Int>, facts: InitializationFacts,
                                              bytes: UnsafeRawBufferPointer) throws -> Bool {
        guard facts.mode != .audio else { return false }
        var offset = span.lowerBound
        var found = false
        while offset < span.upperBound {
            try require(offset, facts.nalLengthBytes, within: span.upperBound)
            var length = 0
            for index in 0..<facts.nalLengthBytes {
                let shifted = length.multipliedReportingOverflow(by: 256)
                guard !shifted.overflow else { throw CompletedMediaEvidenceError.invalidDecodeMap }
                let added = shifted.partialValue.addingReportingOverflow(Int(bytes[offset + index]))
                guard !added.overflow else { throw CompletedMediaEvidenceError.invalidDecodeMap }
                length = added.partialValue
            }
            offset += facts.nalLengthBytes
            guard length > 0 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            let nalEnd = try checkedAdd(offset, length)
            guard nalEnd <= span.upperBound else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            let parameterSet: Bool
            switch facts.mode {
            case .avc1, .avc3:
                let type = bytes[offset] & 0x1f
                parameterSet = type == 7 || type == 8
            case .hvc1, .hev1:
                guard length >= 2 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
                let type = (bytes[offset] >> 1) & 0x3f
                parameterSet = type == 32 || type == 33 || type == 34
            case .audio:
                parameterSet = false
            }
            if parameterSet {
                guard facts.mode == .avc3 || facts.mode == .hev1 else {
                    throw CompletedMediaEvidenceError.invalidDecodeMap
                }
                found = true
            }
            offset = nalEnd
        }
        return found
    }

    private static func firstMediaPayload(in bytes: UnsafeRawBufferPointer) throws -> Int {
        try requiredBox(0x6d646174, in: 0..<bytes.count, bytes: bytes).payloadStart
    }

    private static func isInsideMediaPayload(_ range: Range<Int>,
                                             bytes: UnsafeRawBufferPointer) throws -> Bool {
        var offset = 0
        while offset < bytes.count {
            let box = try readBox(at: offset, limit: bytes.count, bytes: bytes)
            if box.type == 0x6d646174, box.payloadStart <= range.lowerBound, box.end >= range.upperBound {
                return true
            }
            offset = box.end
        }
        return false
    }

    private static func requiredBox(_ type: UInt32, in range: Range<Int>,
                                    bytes: UnsafeRawBufferPointer) throws -> Box {
        guard let box = try optionalBox(type, in: range, bytes: bytes) else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        return box
    }

    private static func optionalBox(_ type: UInt32, in range: Range<Int>,
                                    bytes: UnsafeRawBufferPointer) throws -> Box? {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let box = try readBox(at: offset, limit: range.upperBound, bytes: bytes)
            if box.type == type { return box }
            offset = box.end
        }
        return nil
    }

    private static func readBox(at offset: Int, limit: Int,
                                bytes: UnsafeRawBufferPointer) throws -> Box {
        try require(offset, 8, within: limit)
        let size32 = readUInt32(offset, bytes: bytes)
        let type = readUInt32(offset + 4, bytes: bytes)
        let header: Int
        let size: Int
        if size32 == 1 {
            try require(offset, 16, within: limit)
            guard let exact = Int(exactly: readUInt64(offset + 8, bytes: bytes)) else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            header = 16; size = exact
        } else if size32 == 0 {
            header = 8; size = limit - offset
        } else {
            guard let exact = Int(exactly: size32) else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            header = 8; size = exact
        }
        guard size >= header else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        let end = try checkedAdd(offset, size)
        guard end <= limit, end > offset else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        return Box(start: offset, payloadStart: offset + header, end: end, type: type)
    }

    private static func require(_ offset: Int, _ count: Int, within limit: Int) throws {
        guard offset >= 0, count >= 0 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        let end = offset.addingReportingOverflow(count)
        guard !end.overflow, end.partialValue <= limit else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
    }

    private static func checkedAdd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) throws -> T {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        return result.partialValue
    }

    private static func readUInt32(_ offset: Int, bytes: UnsafeRawBufferPointer) -> UInt32 {
        bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
    }

    private static func readUInt64(_ offset: Int, bytes: UnsafeRawBufferPointer) -> UInt64 {
        bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
    }
}

extension FMP4PresentationRange {
    init(start: ExactMediaTime, duration: ExactMediaTime) throws {
        guard start.value >= 0, duration.value > 0 else {
            throw FinalFMP4ValidationFailure.invalidPresentationRange
        }
        let checkedEnd = try start.adding(duration)
        self.start = start
        self.duration = duration
        end = checkedEnd
    }
}

struct PreparedPlayheadIdentity: Sendable, Hashable {
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let itemGeneration: UInt64
    let publicationSequence: UInt64
    /// Task 18–20 的 source presentation timeline。
    let mediaTime: ExactMediaTime
    /// AVPlayerItem 自身从零开始的 timeline；与 source time 共同冻结在身份中。
    let playerItemTime: ExactMediaTime
    let seekNonce: UInt64
    let renditionSelectionSlotNonce: UInt64
    /// 同一条 audio media full-body response 签出的选择权；后续 coverage fence
    /// 必须复验对象身份，不能用 rendition 数字重建。
    let audioSelectionCapability: LoopbackAudioMediaSelectionCapability?
    /// 同一 server/publication 在 completed HTTP 与 writer endpoint 汇合后签出的
    /// source↔AVPlayerItem 映射；coverage/EOS 都复验同一对象身份。
    let timelineMappingAuthority: PlayerItemTimelineMappingAuthority

    init(outputLifecycleEpoch: OutputLifecycleEpoch,
         itemGeneration: UInt64,
         publicationSequence: UInt64,
         mediaTime: ExactMediaTime,
         playerItemTime: ExactMediaTime,
         seekNonce: UInt64,
         renditionSelectionSlotNonce: UInt64,
         audioSelectionCapability: LoopbackAudioMediaSelectionCapability? = nil,
         timelineMappingAuthority: PlayerItemTimelineMappingAuthority) {
        self.outputLifecycleEpoch = outputLifecycleEpoch
        self.itemGeneration = itemGeneration
        self.publicationSequence = publicationSequence
        self.mediaTime = mediaTime
        self.playerItemTime = playerItemTime
        self.seekNonce = seekNonce
        self.renditionSelectionSlotNonce = renditionSelectionSlotNonce
        self.audioSelectionCapability = audioSelectionCapability
        self.timelineMappingAuthority = timelineMappingAuthority
    }
}

struct ObservedRenditionSetReceipt: Sendable, Hashable {
    let identity = UUID()
    let preparedPlayheadIdentity: PreparedPlayheadIdentity
    let selectionFenceRevision: UInt64
    let orderedRenditionIdentities: [AudioRenditionIdentity]
}

struct LoopbackCoverageContext: Sendable, Hashable {
    let preparedPlayheadIdentity: PreparedPlayheadIdentity
    let observedRenditionSetReceipt: ObservedRenditionSetReceipt
    let renditionIdentity: AudioRenditionIdentity
}

struct ServedRenditionCoverageDependency: Sendable, Equatable {
    let mediaEpoch: UInt64
    let epochProofIdentity: UUID
    let segmentReceiptIdentity: UUID
    let initializationBackingIdentity: SealedMediaBackingIdentity
    let mediaBackingIdentity: SealedMediaBackingIdentity
    let initializationEvidenceIdentity: UUID
    let mediaEvidenceIdentity: UUID
}

struct FrozenCoverageIndices: Sendable {
    private var first = SIMD64<UInt16>(repeating: 0)
    private var second = SIMD64<UInt16>(repeating: 0)
    var count: UInt8 = 0
    subscript(index: Int) -> UInt16 {
        get { index < 64 ? first[index] : second[index - 64] }
        set { if index < 64 { first[index] = newValue } else { second[index - 64] = newValue } }
    }
}

struct FrozenCoverageStorage: Sendable {
    let rendition: AudioRenditionIdentity
    let requested: FMP4PresentationRange
    let offset: UInt8
    let count: UInt8
}

struct ServedCoverageDependencies: RandomAccessCollection, Sendable, Equatable {
    enum Storage: Sendable {
        case explicit([ServedRenditionCoverageDependency])
        case frozen(owner: FrozenPreparationOwner, coverageIndex: UInt8)
    }
    let storage: Storage
    var startIndex: Int { 0 }
    var endIndex: Int {
        switch storage {
        case .explicit(let values): return values.count
        case .frozen(let owner, let index): return Int(owner.coverage(at: index)!.count)
        }
    }
    func input(at slot: Int) -> SealedCoverageInput? {
        guard case .frozen(let owner, _) = storage,
              owner.containsCompletedResource(slot),
              let input = owner.metadataStore?.preparationCoverageInput(slot: slot, ownerSlot: owner.slot),
              input.map.epochProofIdentity != nil, input.map.segmentReceiptIdentity != nil,
              input.map.initializationBackingIdentity != nil else {
            return nil
        }
        return input
    }
    func dependency(_ input: SealedCoverageInput) -> ServedRenditionCoverageDependency {
        .init(mediaEpoch: input.media.mediaEpoch, epochProofIdentity: input.map.epochProofIdentity!,
            segmentReceiptIdentity: input.map.segmentReceiptIdentity!,
            initializationBackingIdentity: input.initialization.resourceIdentity,
            mediaBackingIdentity: input.media.resourceIdentity,
            initializationEvidenceIdentity: input.initialization.stateIdentity,
            mediaEvidenceIdentity: input.media.stateIdentity)
    }
    static func precedes(_ lhs: ServedRenditionCoverageDependency,
                         _ rhs: ServedRenditionCoverageDependency) -> Bool {
        if lhs.mediaEpoch != rhs.mediaEpoch { return lhs.mediaEpoch < rhs.mediaEpoch }
        func less(_ lhs: UUID, _ rhs: UUID) -> Bool {
            withUnsafeBytes(of: lhs.uuid) { left in
                withUnsafeBytes(of: rhs.uuid) { right in left.lexicographicallyPrecedes(right) }
            }
        }
        if lhs.mediaBackingIdentity != rhs.mediaBackingIdentity {
            return less(lhs.mediaBackingIdentity.rawValue, rhs.mediaBackingIdentity.rawValue)
        }
        return less(lhs.mediaEvidenceIdentity, rhs.mediaEvidenceIdentity)
    }
    subscript(index: Int) -> ServedRenditionCoverageDependency {
        if case .explicit(let values) = storage { return values[index] }
        guard case .frozen(let owner, let coverageIndex) = storage else { preconditionFailure() }
        return dependency(input(at: Int(owner.coverageResource(at: index, coverage: coverageIndex)))!)
    }
    func input(atOrdinal ordinal: Int) -> SealedCoverageInput? {
        guard case .frozen(let owner, let coverageIndex) = storage else { return nil }
        return input(at: Int(owner.coverageResource(at: ordinal, coverage: coverageIndex)))
    }
    static func frozen(owner: FrozenPreparationOwner, rendition: AudioRenditionIdentity,
                       requested: FMP4PresentationRange) throws -> Self? {
        var indices = FrozenCoverageIndices()
        for index in UInt8(0)..<2 {
            if let existing = owner.coverage(at: index),
               existing.rendition == rendition, existing.requested == requested {
                return .init(storage: .frozen(owner: owner, coverageIndex: index))
            }
        }
        guard owner.coverage(at: 1) == nil else { throw CompletedMediaEvidenceError.capacityExceeded }
        let coverageIndex: UInt8 = owner.coverage(at: 0) == nil ? 0 : 1
        let view = Self(storage: .frozen(owner: owner, coverageIndex: coverageIndex))
        for slot in 0..<300 {
            guard let input = view.input(at: slot), input.media.renditionIdentity == rendition,
                  let intersection = try input.map.intersection(with: requested),
                  try !input.map.coveredFragments(
                    by: input.media,
                    intersecting: intersection
                  ).isEmpty else { continue }
            guard indices.count < 128 else { throw CompletedMediaEvidenceError.capacityExceeded }
            let candidate = view.dependency(input)
            var insertion = Int(indices.count)
            while insertion > 0,
                  Self.precedes(candidate, view.dependency(view.input(at: Int(indices[insertion - 1]))!)) {
                indices[insertion] = indices[insertion - 1]
                insertion -= 1
            }
            indices[insertion] = UInt16(slot)
            indices.count += 1
        }
        let previousCount = owner.coverage(at: 0).map { Int($0.count) } ?? 0
        guard previousCount + Int(indices.count) <= 128 else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        guard indices.count > 0 else { return nil }
        var cursor = requested.start
        for _ in 0..<Int(indices.count) {
            var next = cursor
            for ordinal in 0..<Int(indices.count) {
                let input = view.input(at: Int(indices[ordinal]))!
                guard try input.map.intersection(with: requested) != nil else { continue }
                for fragment in try input.map.coveredFragments(
                    by: input.media,
                    intersecting: requested
                ) where try HLSChecked.compare(fragment.start, cursor) <= 0
                    && HLSChecked.compare(fragment.end, next) > 0 {
                    next = fragment.end
                }
            }
            if try HLSChecked.compare(next, requested.end) >= 0 { cursor = next; break }
            guard try HLSChecked.compare(next, cursor) > 0 else { return nil }
            cursor = next
        }
        guard try HLSChecked.compare(cursor, requested.end) >= 0 else { return nil }
        owner.setCoverage(.init(rendition: rendition, requested: requested,
            offset: UInt8(previousCount), count: indices.count), indices: indices, at: coverageIndex)
        return view
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.elementsEqual(rhs) }
}

/// 对外摘要是32字节内联值；重复查询不能把新的 Data backing 留在旧 receipt 别名中。
struct FrozenCanonicalCoverageDigest: Sendable, Equatable {
    private let first: UInt64
    private let second: UInt64
    private let third: UInt64
    private let fourth: UInt64
    init(_ digest: SHA256.Digest) {
        (first, second, third, fourth) = digest.withUnsafeBytes { bytes in
            precondition(bytes.count == 32)
            return (bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                    bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                    bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                    bytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
        }
    }
}

struct ServedRenditionCoverageReceipt: Sendable, Equatable {
    let preparedPlayheadIdentity: PreparedPlayheadIdentity
    let observedRenditionSetReceiptIdentity: UUID
    let renditionIdentity: AudioRenditionIdentity
    let itemGeneration: UInt64
    let canonicalCoverageDigest: FrozenCanonicalCoverageDigest
    let presentationRange: FMP4PresentationRange
    let dependencies: ServedCoverageDependencies

    init(authority: SealedCoverageIssuanceAuthority,
         preparedPlayheadIdentity: PreparedPlayheadIdentity,
         observedRenditionSetReceiptIdentity: UUID,
         renditionIdentity: AudioRenditionIdentity,
         itemGeneration: UInt64,
         canonicalCoverageDigest: FrozenCanonicalCoverageDigest,
         presentationRange: FMP4PresentationRange,
         dependencies: ServedCoverageDependencies) {
        self.preparedPlayheadIdentity = preparedPlayheadIdentity
        self.observedRenditionSetReceiptIdentity = observedRenditionSetReceiptIdentity
        self.renditionIdentity = renditionIdentity
        self.itemGeneration = itemGeneration
        self.canonicalCoverageDigest = canonicalCoverageDigest
        self.presentationRange = presentationRange
        self.dependencies = dependencies
    }

    static func == (lhs: ServedRenditionCoverageReceipt,
                    rhs: ServedRenditionCoverageReceipt) -> Bool {
        lhs.preparedPlayheadIdentity == rhs.preparedPlayheadIdentity
            && lhs.observedRenditionSetReceiptIdentity == rhs.observedRenditionSetReceiptIdentity
            && lhs.renditionIdentity == rhs.renditionIdentity
            && lhs.itemGeneration == rhs.itemGeneration
            && lhs.canonicalCoverageDigest == rhs.canonicalCoverageDigest
            && lhs.presentationRange == rhs.presentationRange
            && lhs.dependencies == rhs.dependencies
    }
}

final class ServedRenditionCoverageAccumulator: @unchecked Sendable {
    private struct CoverageEntry {
        let dependency: ServedRenditionCoverageDependency
        let initializationDigest: Data
        let mediaDigest: Data
        var ranges: [FMP4PresentationRange]
    }
    private let lock = NSLock()
    private let preparedPlayheadIdentity: PreparedPlayheadIdentity
    private let observedRenditionSetReceipt: ObservedRenditionSetReceipt
    private let renditionIdentity: AudioRenditionIdentity
    private let authority: SealedCoverageIssuanceAuthority
    private var entries: [CoverageEntry]

    init(authority: SealedCoverageIssuanceAuthority,
         preparedPlayheadIdentity: PreparedPlayheadIdentity,
         observedRenditionSetReceipt: ObservedRenditionSetReceipt,
         renditionIdentity: AudioRenditionIdentity) {
        self.authority = authority
        self.preparedPlayheadIdentity = preparedPlayheadIdentity
        self.observedRenditionSetReceipt = observedRenditionSetReceipt
        self.renditionIdentity = renditionIdentity
        entries = []
        entries.reserveCapacity(LoopbackStorageLayout.current.coverageAccumulatorDependencyCapacity)
    }

    func join(media: CompletedBodyEvidenceSnapshot, map: SealedDecodeCoverageMap,
              initialization: CompletedBodyEvidenceSnapshot,
              requestedPresentationRange: FMP4PresentationRange) throws -> ServedRenditionCoverageReceipt? {
        guard preparedPlayheadIdentity == observedRenditionSetReceipt.preparedPlayheadIdentity,
              observedRenditionSetReceipt.orderedRenditionIdentities.contains(renditionIdentity),
              preparedPlayheadIdentity.itemGeneration == media.itemGeneration,
              media.itemGeneration == initialization.itemGeneration,
              media.renditionIdentity == renditionIdentity,
              initialization.renditionIdentity == renditionIdentity,
              media.mediaEpoch == initialization.mediaEpoch,
              map.resourceIdentity == media.resourceIdentity,
              map.evidenceStateIdentity == media.stateIdentity,
              map.initializationStateIdentity == initialization.stateIdentity,
              let proofIdentity = map.epochProofIdentity,
              let receiptIdentity = map.segmentReceiptIdentity,
              let initializationBackingIdentity = map.initializationBackingIdentity,
              initializationBackingIdentity == initialization.resourceIdentity,
              initialization.isComplete else { return nil }
        let covered = try map.coveredFragments(
            by: media,
            intersecting: requestedPresentationRange
        )
        guard !covered.isEmpty else { return nil }
        return try lock.withLock {
            let dependency = ServedRenditionCoverageDependency(mediaEpoch: media.mediaEpoch,
                epochProofIdentity: proofIdentity, segmentReceiptIdentity: receiptIdentity,
                initializationBackingIdentity: initializationBackingIdentity,
                mediaBackingIdentity: media.resourceIdentity,
                initializationEvidenceIdentity: initialization.stateIdentity,
                mediaEvidenceIdentity: media.stateIdentity)
            if let index = entries.firstIndex(where: { $0.dependency == dependency }) {
                entries[index].ranges = try Self.union(entries[index].ranges
                    + covered)
            } else {
                guard entries.count < LoopbackStorageLayout.current.coverageAccumulatorDependencyCapacity else {
                    throw CompletedMediaEvidenceError.capacityExceeded
                }
                entries.append(.init(dependency: dependency,
                    initializationDigest: initialization.sealedDigest,
                    mediaDigest: media.sealedDigest,
                    ranges: covered))
            }
            entries.sort { Self.dependencyOrder($0.dependency, $1.dependency) }
            let canonicalRanges = try Self.union(entries.flatMap(\.ranges))
            guard canonicalRanges.count == 1, let presentationRange = canonicalRanges.first else {
                return nil
            }
            var canonical = Data()
            canonical.reserveCapacity(LoopbackStorageLayout.current.coverageAccumulatorAllocationBytes / 2)
            Self.append(media.itemGeneration, to: &canonical)
            Self.append(renditionIdentity.rawValue, to: &canonical)
            for item in entries {
                let dependency = item.dependency
                Self.append(dependency.mediaEpoch, to: &canonical)
                Self.append(dependency.epochProofIdentity, to: &canonical)
                Self.append(dependency.segmentReceiptIdentity, to: &canonical)
                Self.append(dependency.initializationBackingIdentity.rawValue, to: &canonical)
                Self.append(dependency.mediaBackingIdentity.rawValue, to: &canonical)
                Self.append(dependency.initializationEvidenceIdentity, to: &canonical)
                Self.append(dependency.mediaEvidenceIdentity, to: &canonical)
                Self.append(item.initializationDigest, to: &canonical)
                Self.append(item.mediaDigest, to: &canonical)
                for range in item.ranges {
                    Self.append(range.start.value, to: &canonical)
                    Self.append(UInt64(range.start.timescale), to: &canonical)
                    Self.append(range.end.value, to: &canonical)
                    Self.append(UInt64(range.end.timescale), to: &canonical)
                }
            }
            return ServedRenditionCoverageReceipt(authority: authority,
                preparedPlayheadIdentity: preparedPlayheadIdentity,
                observedRenditionSetReceiptIdentity: observedRenditionSetReceipt.identity,
                renditionIdentity: renditionIdentity, itemGeneration: media.itemGeneration,
                canonicalCoverageDigest: .init(SHA256.hash(data: canonical)),
                presentationRange: presentationRange,
                dependencies: .init(storage: .explicit(entries.map(\.dependency))))
        }
    }

    private static func dependencyOrder(_ lhs: ServedRenditionCoverageDependency,
                                        _ rhs: ServedRenditionCoverageDependency) -> Bool {
        if lhs.mediaEpoch != rhs.mediaEpoch { return lhs.mediaEpoch < rhs.mediaEpoch }
        if lhs.mediaBackingIdentity.rawValue != rhs.mediaBackingIdentity.rawValue {
            return lhs.mediaBackingIdentity.rawValue.uuidString
                < rhs.mediaBackingIdentity.rawValue.uuidString
        }
        return lhs.mediaEvidenceIdentity.uuidString < rhs.mediaEvidenceIdentity.uuidString
    }

    private static func union(_ input: [FMP4PresentationRange]) throws
        -> [FMP4PresentationRange] {
        let ordered = try input.sorted {
            let start = try HLSChecked.compare($0.start, $1.start)
            if start != 0 { return start < 0 }
            return try HLSChecked.compare($0.end, $1.end) < 0
        }
        var result: [FMP4PresentationRange] = []
        result.reserveCapacity(min(LoopbackStorageLayout.current.coverageAccumulatorRangeCapacity,
                                   ordered.count))
        for range in ordered {
            guard let last = result.last else { result.append(range); continue }
            if try HLSChecked.compare(range.start, last.end) <= 0 {
                let end = try HLSChecked.compare(range.end, last.end) > 0 ? range.end : last.end
                result[result.count - 1] = try FMP4PresentationRange(start: last.start,
                    duration: end.subtracting(last.start))
            } else {
                guard result.count < LoopbackStorageLayout.current.coverageAccumulatorRangeCapacity else {
                    throw CompletedMediaEvidenceError.capacityExceeded
                }
                result.append(range)
            }
        }
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func append(_ value: UUID, to data: inout Data) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }
}

enum LoopbackSendTerminal: Sendable, Equatable { case success, cancelled, failed, disconnected }
