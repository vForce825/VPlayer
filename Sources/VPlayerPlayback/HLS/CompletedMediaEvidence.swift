// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import CryptoKit
import Darwin
import ObjectiveC

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

/// One charge follows the immutable backing through all map/collection aliases.
/// Store adoption is recorded once; it never detaches or releases this owner.
fileprivate final class SealedDecodeMapPrepayment: @unchecked Sendable {
    private let lock = NSLock()
    private let owned: PlaybackApplicationChargeReservation
    private var claimed = false
    let bytes: Int
    static var allocationBytes: Int {
        Int(malloc_good_size(class_getInstanceSize(Self.self)))
            + Int(malloc_good_size(class_getInstanceSize(NSLock.self)))
    }
    private init(bytes: Int, reservation: PlaybackApplicationChargeReservation) {
        self.bytes = bytes
        owned = reservation
    }
    static func reserve(bytes: Int) throws -> SealedDecodeMapPrepayment {
        let reservation: PlaybackApplicationChargeReservation
        do { reservation = try HLSDeliveryApplicationChargeLedger.shared.reserve(allocationIdentity: UUID(), bytes: bytes) }
        catch is LoopbackHTTPReservationError { throw HLSPublicationFailure.capacityExceeded }
        let value = SealedDecodeMapPrepayment(bytes: bytes, reservation: reservation)
        let actual = malloc_size(UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque()))
            + malloc_size(UnsafeRawPointer(Unmanaged.passUnretained(value.lock).toOpaque()))
        guard actual <= allocationBytes else { throw CompletedMediaEvidenceError.capacityExceeded }
        return value
    }
    func claim() throws -> PlaybackApplicationChargeReservation {
        try lock.withLock {
            guard !claimed else { throw CompletedMediaEvidenceError.identityMismatch }
            claimed = true
            return owned
        }
    }
    deinit { HLSDeliveryApplicationChargeLedger.shared.release(owned) }
}

/// Collection aliases retain the same paid backing owner. The raw Array is never
/// returned, so copying samples or spans cannot shed the last-alias accounting.
struct SealedDecodeMapArray<Element: Sendable>: RandomAccessCollection, Sendable {
    typealias Index = Int
    private let values: [Element]
    private let storagePrepayment: SealedDecodeMapPrepayment?
    fileprivate init(_ values: [Element], storagePrepayment: SealedDecodeMapPrepayment?) {
        self.values = values
        self.storagePrepayment = storagePrepayment
    }
    var startIndex: Int { values.startIndex }
    var endIndex: Int { values.endIndex }
    var capacity: Int { values.capacity }
    subscript(position: Int) -> Element { values[position] }
    func index(after position: Int) -> Int { values.index(after: position) }
    func index(before position: Int) -> Int { values.index(before: position) }
    func index(_ position: Int, offsetBy distance: Int) -> Int { values.index(position, offsetBy: distance) }
    func distance(from start: Int, to end: Int) -> Int { values.distance(from: start, to: end) }
}

/// Source provenance is independent of encoder calibration and trim. Issuance
/// checks both genuine native callbacks against the same current source root;
/// consumers must still recheck currentness when they use this retained proof.
struct SourceAACSealedMediaProof: Sendable {
    let binding: SourceAACWriterTerminalBinding
    let callback: SourceAACCallbackEvidence
    private let initialization: SourceAACCallbackEvidence
    var isCurrent: Bool {
        binding.isCurrent && binding.accepts(callback) && binding.accepts(initialization)
    }
    fileprivate init(binding: SourceAACWriterTerminalBinding,
                     media: SealedMediaObject, initialization: SealedMediaObject) throws {
        guard binding.isCurrent, let callback = media.publicationEvidence?.sourceAAC,
              let initial = initialization.publicationEvidence?.sourceAAC,
              callback.matches(media), initial.matches(initialization),
              binding.accepts(callback), binding.accepts(initial),
              media.kind == .media, initialization.kind == .initialization,
              callback.sampleEntryDigest == initial.sampleEntryDigest else {
            throw CompletedMediaEvidenceError.identityMismatch
        }
        self.binding = binding; self.callback = callback; self.initialization = initial
    }
}

struct SealedDecodeCoverageMap: Sendable {
    static var prepaymentAllocationBytes: Int { SealedDecodeMapPrepayment.allocationBytes }
    enum MediaType: Sendable { case video, audio }
    enum SampleEntryMode: Sendable, Equatable { case audio, avc1, avc3, hvc1, hev1 }
    let mediaType: MediaType
    let sampleEntryMode: SampleEntryMode
    let resourceIdentity: SealedMediaBackingIdentity
    let sealedBodyLength: Int
    let commonByteSpans: SealedDecodeMapArray<Range<Int>>
    let samples: SealedDecodeMapArray<SealedDecodeSampleEntry>
    let maximumSampleCount: Int
    let applicationChargeableBytes: Int
    private let storagePrepayment: SealedDecodeMapPrepayment?
    let evidenceStateIdentity: UUID?
    let initializationStateIdentity: UUID?
    let epochProofIdentity: UUID?
    let segmentReceiptIdentity: UUID?
    let initializationBackingIdentity: SealedMediaBackingIdentity?
    let sourceAACProof: SourceAACSealedMediaProof?

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
            commonByteSpans: commonByteSpans, samples: samples, maximumSampleCount: 256, storagePrepayment: nil,
            evidenceStateIdentity: nil, initializationStateIdentity: nil,
            epochProofIdentity: nil, segmentReceiptIdentity: nil,
            initializationBackingIdentity: nil)
    }

    /// Only the original native callback can supply this cadence/boundary proof.
    /// Unauthenticated inspection maps retain their original256-record limit.
    private static func admittedSampleLimit(media: SealedMediaObject, proof: EpochFormatProof,
                                           receipt: SegmentValidationReceipt) throws
        -> (limit: FMP4DecodeMapParser.SampleCountLimit, cadence: ExactMediaTime?) {
        guard let evidence = media.publicationEvidence, evidence.matches(media),
              receipt.matches(media: media, proof: proof), let boundary = evidence.boundary,
              boundary.session === evidence.session, boundary.binding == media.binding,
              boundary.logicalSequence == media.logicalSequence else { return (.ordinary, nil) }
        let cadence: ExactMediaTime
        let limit: FMP4DecodeMapParser.SampleCountLimit
        switch proof.mediaType {
        case .video:
            guard let frame = evidence.frameDuration, frame.value > 0,
                  try HLSChecked.compare(frame, .init(value: 1, timescale: 60)) >= 0 else { return (.ordinary, nil) }
            cadence = frame
            limit = .authenticatedVideo
        case .audio:
            guard evidence.format.codec == "mp4a.40.2", evidence.format.sampleRate > 0,
                  evidence.format.sampleRate <= 48_000,
                  let quantum = boundary.accessUnitDuration else { return (.ordinary, nil) }
            let expected = ExactMediaTime(value: 1_024, timescale: Int32(evidence.format.sampleRate))
            guard try HLSChecked.compare(quantum, expected) == 0 else { return (.ordinary, nil) }
            cadence = expected
            limit = .authenticatedAAC
        }
        let envelope = try HLSChecked.six.adding(cadence)
        guard try HLSChecked.compare(receipt.presentationRange.duration, envelope) <= 0 else { return (.ordinary, nil) }
        let ordinarySpan = ExactMediaTime(value: try HLSChecked.multiply(cadence.value, 256), timescale: cadence.timescale)
        guard try HLSChecked.compare(receipt.presentationRange.duration, ordinarySpan) > 0 else { return (.ordinary, nil) }
        return (limit, cadence)
    }

    private static func validateAdmittedCadence(_ samples: [SealedDecodeSampleEntry],
                                                cadence: ExactMediaTime?) throws {
        guard let cadence else { return }
        guard try samples.allSatisfy({ try HLSChecked.compare($0.presentationRange.duration, cadence) == 0 }) else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
    }

    /// 只有 store 已持有封口对象、proof、receipt 与同 epoch init 时才走此签发入口。
    static func seal(media: SealedMediaObject, proof: EpochFormatProof,
                     receipt: SegmentValidationReceipt,
                     initialization: SealedMediaObject,
                     evidence: CompletedMediaBodyEvidenceState,
                     initializationEvidence: CompletedInitBodyEvidenceState) throws -> Self {
        guard media.publicationEvidence?.sourceAAC == nil,
              initialization.publicationEvidence?.sourceAAC == nil,
              media.kind == .media, initialization.kind == .initialization,
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
        let admission = try admittedSampleLimit(media: media, proof: proof, receipt: receipt)
        let prepayment = try SealedDecodeMapPrepayment.reserve(bytes: LoopbackStorageLayout.current.decodeMapAllocation(
            sampleCount: 1, commonSpanCount: 48, maximumSampleCount: admission.limit.value))
        let parsed = try FMP4DecodeMapParser.parse(initialization: initialization.bytes,
            media: media.bytes, mediaType: proof.mediaType,
            expectedPresentationRange: receipt.presentationRange, sampleCountLimit: admission.limit)
        try validateAdmittedCadence(parsed.samples, cadence: admission.cadence)
        return try Self(mediaType: proof.mediaType == .video ? .video : .audio,
            sampleEntryMode: parsed.mode, resourceIdentity: media.backing.identity,
            sealedBodyLength: media.bytes.count, commonByteSpans: parsed.commonByteSpans,
            samples: parsed.samples, maximumSampleCount: admission.limit.value, storagePrepayment: prepayment,
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
        guard media.publicationEvidence?.sourceAAC == nil,
              canonicalInitialization.publicationEvidence?.sourceAAC == nil,
              media.kind == .media, canonicalInitialization.kind == .initialization,
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
        let admission = try admittedSampleLimit(media: media, proof: proof, receipt: receipt)
        let prepayment = try SealedDecodeMapPrepayment.reserve(bytes: LoopbackStorageLayout.current.decodeMapAllocation(
            sampleCount: 1, commonSpanCount: 48, maximumSampleCount: admission.limit.value))
        let parsed = try FMP4DecodeMapParser.parse(initialization: canonicalInitialization.bytes,
            media: media.bytes, mediaType: proof.mediaType,
            expectedPresentationRange: receipt.presentationRange, sampleCountLimit: admission.limit)
        try validateAdmittedCadence(parsed.samples, cadence: admission.cadence)
        return try Self(mediaType: proof.mediaType == .video ? .video : .audio,
            sampleEntryMode: parsed.mode, resourceIdentity: media.backing.identity,
            sealedBodyLength: media.bytes.count, commonByteSpans: parsed.commonByteSpans,
            samples: parsed.samples, maximumSampleCount: admission.limit.value, storagePrepayment: prepayment,
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
        guard media.publicationEvidence?.sourceAAC == nil,
              canonicalInitialization.publicationEvidence?.sourceAAC == nil,
              media.kind == .media, canonicalInitialization.kind == .initialization,
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
        let admission = try admittedSampleLimit(media: media, proof: proof, receipt: receipt)
        let prepayment = try SealedDecodeMapPrepayment.reserve(bytes: LoopbackStorageLayout.current.decodeMapAllocation(
            sampleCount: 1, commonSpanCount: 48, maximumSampleCount: admission.limit.value))
        let parsed = try FMP4DecodeMapParser.parse(
            initialization: canonicalInitialization.bytes,
            media: media.bytes,
            mediaType: proof.mediaType,
            expectedPresentationRange: receipt.presentationRange, sampleCountLimit: admission.limit)
        try validateAdmittedCadence(parsed.samples, cadence: admission.cadence)
        return try Self(
            mediaType: proof.mediaType == .video ? .video : .audio,
            sampleEntryMode: parsed.mode,
            resourceIdentity: media.backing.identity,
            sealedBodyLength: media.bytes.count,
            commonByteSpans: parsed.commonByteSpans,
            samples: parsed.samples, maximumSampleCount: admission.limit.value, storagePrepayment: prepayment,
            evidenceStateIdentity: evidence.stateIdentity,
            initializationStateIdentity: initializationEvidence.stateIdentity,
            epochProofIdentity: proof.identity,
            segmentReceiptIdentity: receipt.identity,
            initializationBackingIdentity: canonicalInitialization.backing.identity)
    }

    static func sealSourceAAC(
        media: SealedMediaObject, proof: EpochFormatProof,
        receipt: SegmentValidationReceipt, initialization: SealedMediaObject,
        initializationProof: EpochFormatProof,
        compatibility: WriterInitializationCompatibility? = nil,
        binding: SourceAACWriterTerminalBinding,
        evidence: CompletedMediaBodyEvidenceState,
        initializationEvidence: CompletedInitBodyEvidenceState
    ) throws -> Self {
        let source = try SourceAACSealedMediaProof(binding: binding, media: media,
                                                 initialization: initialization)
        guard proof.mediaType == .audio, initializationProof.mediaType == .audio,
              receipt.matches(media: media, proof: proof),
              initializationProof.matches(initialization: initialization),
              proof.matches(initialization: initialization)
                || compatibility?.authorizes(canonicalInitialization: initialization,
                    canonicalProof: initializationProof, successorProof: proof) == true,
              source.callback.writtenRange == receipt.presentationRange,
              source.callback.timelineOffset == binding.timelineOffset,
              source.callback.sampleCount > 0, source.callback.sampleCount <= 320,
              binding.configuration.sampleRate > 0, binding.configuration.sampleRate <= 48_000,
              media.backing.identity == evidence.resourceIdentity,
              media.digest == evidence.sealedDigest, media.bytes.count == evidence.sealedBodyLength,
              media.binding.itemGeneration.rawValue == evidence.itemGeneration,
              media.binding.mediaEpoch.rawValue == evidence.mediaEpoch,
              media.binding.renditionIdentity == evidence.renditionIdentity,
              initialization.backing.identity == initializationEvidence.resourceIdentity,
              initialization.digest == initializationEvidence.sealedDigest,
              initialization.bytes.count == initializationEvidence.sealedBodyLength,
              initialization.binding.itemGeneration.rawValue == initializationEvidence.itemGeneration,
              initialization.binding.mediaEpoch.rawValue == initializationEvidence.mediaEpoch,
              initialization.binding.renditionIdentity == initializationEvidence.renditionIdentity else {
            throw CompletedMediaEvidenceError.identityMismatch
        }
        let quantum = ExactMediaTime(value: 1_024, timescale: binding.configuration.sampleRate)
        guard try HLSChecked.compare(receipt.presentationRange.duration,
                                     HLSChecked.six.adding(quantum)) <= 0 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let prepayment = try SealedDecodeMapPrepayment.reserve(bytes:
            LoopbackStorageLayout.current.decodeMapAllocation(sampleCount: 1, commonSpanCount: 48,
                                                              maximumSampleCount: 320))
        let parsed = try FMP4DecodeMapParser.parse(initialization: initialization.bytes,
            media: media.bytes, mediaType: .audio, expectedPresentationRange: receipt.presentationRange,
            sampleCountLimit: .authenticatedAAC)
        guard parsed.samples.count == source.callback.sampleCount else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        try validateAdmittedCadence(parsed.samples, cadence: quantum)
        return try Self(mediaType: .audio, sampleEntryMode: parsed.mode,
            resourceIdentity: media.backing.identity, sealedBodyLength: media.bytes.count,
            commonByteSpans: parsed.commonByteSpans, samples: parsed.samples,
            maximumSampleCount: 320, storagePrepayment: prepayment,
            evidenceStateIdentity: evidence.stateIdentity,
            initializationStateIdentity: initializationEvidence.stateIdentity,
            epochProofIdentity: proof.identity, segmentReceiptIdentity: receipt.identity,
            initializationBackingIdentity: initialization.backing.identity, sourceAACProof: source)
    }

    /// publication commit 只消费由上述两个 seal 入口生成的完整身份闭包；
    /// 普通 caller 可构造的无身份 map 永远不能通过。
    func authorizesPublication(media: SealedMediaObject,
                               proof: EpochFormatProof,
                               receipt: SegmentValidationReceipt,
                               initialization: SealedMediaObject,
                               mediaEvidence: CompletedBodyEvidenceState,
                               initializationEvidence: CompletedBodyEvidenceState) -> Bool {
        (sourceAACProof?.isCurrent ?? (media.publicationEvidence?.sourceAAC == nil))
            && resourceIdentity == media.backing.identity
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
                 samples: [SealedDecodeSampleEntry], maximumSampleCount: Int,
                 storagePrepayment: SealedDecodeMapPrepayment?, evidenceStateIdentity: UUID?,
                 initializationStateIdentity: UUID?, epochProofIdentity: UUID?,
                 segmentReceiptIdentity: UUID?,
                 initializationBackingIdentity: SealedMediaBackingIdentity?,
                 sourceAACProof: SourceAACSealedMediaProof? = nil) throws {
        guard sealedBodyLength > 0, !samples.isEmpty, [256, 320, 384].contains(maximumSampleCount),
              samples.count <= maximumSampleCount else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        let charge = try LoopbackStorageLayout.current.decodeMapAllocation(
            sampleCount: samples.count, commonSpanCount: commonByteSpans.count, maximumSampleCount: maximumSampleCount)
        let actualCapacityCharge = try LoopbackStorageLayout.current.decodeMapStorageAllocation(
            sampleCapacity: samples.capacity, commonSpanCapacity: commonByteSpans.capacity)
        guard actualCapacityCharge <= charge else { throw CompletedMediaEvidenceError.capacityExceeded }
        func validSpan(_ span: Range<Int>) -> Bool {
            span.lowerBound >= 0 && !span.isEmpty && span.upperBound <= sealedBodyLength
        }
        guard commonByteSpans.allSatisfy(validSpan), samples.allSatisfy({ validSpan($0.byteSpan) }) else {
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
        if mediaType == .audio { try Self.validateAudioContinuity(samples) }
        self.mediaType = mediaType
        self.sampleEntryMode = sampleEntryMode
        self.resourceIdentity = resourceIdentity
        self.sealedBodyLength = sealedBodyLength
        self.commonByteSpans = .init(commonByteSpans, storagePrepayment: storagePrepayment)
        self.samples = .init(samples, storagePrepayment: storagePrepayment)
        self.maximumSampleCount = maximumSampleCount
        guard storagePrepayment == nil || storagePrepayment?.bytes == charge else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        self.storagePrepayment = storagePrepayment
        applicationChargeableBytes = charge
        self.evidenceStateIdentity = evidenceStateIdentity
        self.initializationStateIdentity = initializationStateIdentity
        self.epochProofIdentity = epochProofIdentity
        self.segmentReceiptIdentity = segmentReceiptIdentity
        self.initializationBackingIdentity = initializationBackingIdentity
        self.sourceAACProof = sourceAACProof
    }

    func claimPrepaidAllocationForStore() throws -> PlaybackApplicationChargeReservation {
        guard let storagePrepayment else { throw CompletedMediaEvidenceError.identityMismatch }
        return try storagePrepayment.claim()
    }

    fileprivate static func validateAudioContinuity(_ samples: [SealedDecodeSampleEntry]) throws {
        guard let first = samples.first else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        var start = first.presentationRange.start
        var end = first.presentationRange.end
        for sample in samples {
            if try HLSChecked.compare(sample.presentationRange.start, start) < 0 { start = sample.presentationRange.start }
            if try HLSChecked.compare(sample.presentationRange.end, end) > 0 { end = sample.presentationRange.end }
        }
        var covered = start
        for _ in samples.indices {
            var next = covered
            for sample in samples where try HLSChecked.compare(sample.presentationRange.start, covered) <= 0 {
                if try HLSChecked.compare(sample.presentationRange.end, next) > 0 { next = sample.presentationRange.end }
            }
            if try HLSChecked.compare(next, end) >= 0 { return }
            guard try HLSChecked.compare(next, covered) > 0 else { break }
            covered = next
        }
        throw CompletedMediaEvidenceError.invalidDecodeMap
    }

    func isCovered(by evidence: CompletedBodyEvidenceSnapshot,
                   requested: FMP4PresentationRange) throws -> Bool {
        guard sourceAACProof?.isCurrent ?? true else { return false }
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
        guard sourceAACProof?.isCurrent ?? true,
              commonByteSpans.allSatisfy(evidence.covers) else { return [] }
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

/// Exact interval endpoints need not have a representable CMTime duration.
/// Keep both original rational points; clipping/coverage only compares endpoints.
struct ExactMediaInterval: Sendable, Hashable {
    let start: ExactMediaTime
    let end: ExactMediaTime

    init(start: ExactMediaTime, end: ExactMediaTime) throws {
        guard start.value >= 0, try HLSChecked.compare(start, end) < 0 else {
            throw FinalFMP4ValidationFailure.invalidPresentationRange
        }
        self.start = start
        self.end = end
    }

    init(_ range: FMP4PresentationRange) {
        start = range.start
        end = range.end
    }
}

/// Paused verification orders immutable sample ordinals in caller-owned storage.
/// It neither constructs Array backing nor changes the startup coverage path.
struct PausedDecodeCoverageEligibility {
    private var bits = SIMD8<UInt64>(repeating: 0)
    var videoHold: ExactMediaTime?

    func contains(_ ordinal: Int) -> Bool {
        bits[ordinal / 64] & (UInt64(1) << (ordinal % 64)) != 0
    }
    mutating func insert(_ ordinal: Int) {
        bits[ordinal / 64] |= UInt64(1) << (ordinal % 64)
    }
}

/// A fixed UInt8 minheap; ranges stay in the caller's already charged records.
/// The nonescaping projection is never stored and no element backing is created.
enum PausedCoverageTimeHeap {
    private static func precedes(_ left: UInt8, _ right: UInt8,
                                 rangeAt: (Int) -> ExactMediaInterval) throws -> Bool {
        let lhs = rangeAt(Int(left))
        let rhs = rangeAt(Int(right))
        let start = try HLSChecked.compare(lhs.start, rhs.start)
        if start != 0 { return start < 0 }
        return try HLSChecked.compare(lhs.end, rhs.end) < 0
    }

    static func insert(_ index: UInt8, storage: UnsafeMutableBufferPointer<UInt8>,
                       count: inout Int, rangeAt: (Int) -> ExactMediaInterval) throws {
        precondition(count < storage.count)
        var child = count
        count += 1
        storage[child] = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard try precedes(storage[child], storage[parent], rangeAt: rangeAt) else { break }
            storage.swapAt(parent, child)
            child = parent
        }
    }

    static func pop(storage: UnsafeMutableBufferPointer<UInt8>, count: inout Int,
                    rangeAt: (Int) -> ExactMediaInterval) throws -> UInt8 {
        precondition(count > 0)
        let result = storage[0]
        count -= 1
        guard count > 0 else { return result }
        storage[0] = storage[count]
        var parent = 0
        while parent * 2 + 1 < count {
            var child = parent * 2 + 1
            if child + 1 < count,
               try precedes(storage[child + 1], storage[child], rangeAt: rangeAt) { child += 1 }
            guard try precedes(storage[child], storage[parent], rangeAt: rangeAt) else { break }
            storage.swapAt(parent, child)
            parent = child
        }
        return result
    }
}

enum PausedDecodeCoverageOrder {
    /// O(n log n) heapsort, with constant auxiliary storage. UInt16 encodes
    /// authenticated sample ordinals through383; no byte truncation is allowed.
    static func prepare(map: SealedDecodeCoverageMap,
                        ordinals: UnsafeMutableBufferPointer<UInt16>) throws {
        guard ordinals.count == map.samples.count, (1...map.maximumSampleCount).contains(ordinals.count) else {
            throw CompletedMediaEvidenceError.capacityExceeded
        }
        for index in ordinals.indices { ordinals[index] = UInt16(index) }
        func precedes(_ left: UInt16, _ right: UInt16) throws -> Bool {
            let lhs = map.samples[Int(left)].presentationRange
            let rhs = map.samples[Int(right)].presentationRange
            let start = try HLSChecked.compare(lhs.start, rhs.start)
            if start != 0 { return start < 0 }
            return try HLSChecked.compare(lhs.end, rhs.end) < 0
        }
        func sift(_ root: Int, _ end: Int) throws {
            var parent = root
            while parent * 2 + 1 < end {
                var child = parent * 2 + 1
                if child + 1 < end, try precedes(ordinals[child], ordinals[child + 1]) {
                    child += 1
                }
                guard try precedes(ordinals[parent], ordinals[child]) else { return }
                ordinals.swapAt(parent, child)
                parent = child
            }
        }
        if ordinals.count > 1 {
            for root in stride(from: ordinals.count / 2 - 1, through: 0, by: -1) {
                try sift(root, ordinals.count)
            }
            for end in stride(from: ordinals.count - 1, through: 1, by: -1) {
                ordinals.swapAt(0, end)
                try sift(0, end)
            }
        }
    }

    static func intersection(map: SealedDecodeCoverageMap,
                             ordinals: UnsafeBufferPointer<UInt16>,
                             requested: ExactMediaInterval,
                             presentationOffset: ExactMediaTime = HLSChecked.zero) throws -> ExactMediaInterval? {
        guard ordinals.count == map.samples.count, let first = ordinals.first,
              let last = ordinals.last else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        let firstStart = try map.samples[Int(first)].presentationRange.start.adding(presentationOffset)
        let lastEnd = try map.samples[Int(last)].presentationRange.end.adding(presentationOffset)
        let start = try HLSChecked.compare(firstStart, requested.start) > 0
            ? firstStart : requested.start
        // Preserve the existing lexicographic-last end, including nested ranges.
        let end = try HLSChecked.compare(lastEnd, requested.end) < 0
            ? lastEnd : requested.end
        guard try HLSChecked.compare(start, end) < 0 else { return nil }
        return try .init(start: start, end: end)
    }

    /// Admission examines metadata only: HTTP eligibility is checked later.
    /// Match the verifier's lexicographic raw-map bounds and unextended sample
    /// overlap without allocating ordinals before workspace admission.
    static func canContribute(map: SealedDecodeCoverageMap,
                              requested: ExactMediaInterval,
                              presentationOffset: ExactMediaTime = HLSChecked.zero) throws -> Bool {
        guard let first = map.samples.first, map.samples.count <= map.maximumSampleCount else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        func precedes(_ lhs: FMP4PresentationRange, _ rhs: FMP4PresentationRange) throws -> Bool {
            let start = try HLSChecked.compare(lhs.start, rhs.start)
            if start != 0 { return start < 0 }
            return try HLSChecked.compare(lhs.end, rhs.end) < 0
        }
        var minimum = first.presentationRange
        var maximum = first.presentationRange
        for sample in map.samples.dropFirst() {
            if try precedes(sample.presentationRange, minimum) { minimum = sample.presentationRange }
            if try precedes(maximum, sample.presentationRange) { maximum = sample.presentationRange }
        }
        let firstStart = try minimum.start.adding(presentationOffset)
        let lastEnd = try maximum.end.adding(presentationOffset)
        let start = try HLSChecked.compare(firstStart, requested.start) > 0
            ? firstStart : requested.start
        let end = try HLSChecked.compare(lastEnd, requested.end) < 0
            ? lastEnd : requested.end
        guard try HLSChecked.compare(start, end) < 0 else { return false }
        for sample in map.samples {
            if try HLSChecked.compare(sample.presentationRange.start.adding(presentationOffset), end) < 0,
               try HLSChecked.compare(start, sample.presentationRange.end.adding(presentationOffset)) < 0 { return true }
        }
        return false
    }

    static func videoHold(map: SealedDecodeCoverageMap) throws -> ExactMediaTime? {
        guard map.mediaType == .video, let first = map.samples.first else { return nil }
        var maximum = first.presentationRange.duration
        for sample in map.samples.dropFirst() {
            if try HLSChecked.compare(sample.presentationRange.duration, maximum) > 0 {
                maximum = sample.presentationRange.duration
            }
        }
        let multiplied = maximum.value.multipliedReportingOverflow(by: 3)
        guard !multiplied.overflow else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        return .init(value: multiplied.partialValue, timescale: maximum.timescale)
    }

    /// Every required byte span is queried once. A video prefix is complete iff
    /// no missing decode ordinal is at or after this sample's nearest RAP.
    static func eligibility(map: SealedDecodeCoverageMap,
                            evidence: CompletedBodyEvidenceSnapshot) throws
        -> PausedDecodeCoverageEligibility {
        var result = PausedDecodeCoverageEligibility()
        guard map.commonByteSpans.allSatisfy(evidence.covers) else { return result }
        result.videoHold = try videoHold(map: map)
        var lastMissing = -1
        for index in map.samples.indices {
            let sample = map.samples[index]
            let complete = evidence.covers(sample.byteSpan)
            if !complete { lastMissing = index }
            if map.mediaType == .audio ? complete
                : Int(sample.nearestRandomAccessOrdinal) > lastMissing {
                result.insert(index)
            }
        }
        return result
    }

    /// Emits individual eligible clipped intervals in nondecreasing start order.
    /// A global heap may merge them without materializing per-map unions.
    static func nextRange(map: SealedDecodeCoverageMap,
                          ordinals: UnsafeBufferPointer<UInt16>, cursor: inout Int,
                          requested: ExactMediaInterval,
                          eligibility: PausedDecodeCoverageEligibility,
                          presentationOffset: ExactMediaTime = HLSChecked.zero) throws -> ExactMediaInterval? {
        while cursor < ordinals.count {
            let ordinal = Int(ordinals[cursor])
            cursor += 1
            guard eligibility.contains(ordinal) else { continue }
            let physical = map.samples[ordinal].presentationRange
            let range = try ExactMediaInterval(start: physical.start.adding(presentationOffset),
                                              end: physical.end.adding(presentationOffset))
            guard try HLSChecked.compare(range.start, requested.end) < 0,
                  try HLSChecked.compare(requested.start, range.end) < 0 else { continue }
            let start = try HLSChecked.compare(range.start, requested.start) < 0
                ? requested.start : range.start
            let heldEnd = try eligibility.videoHold.map { try range.end.adding($0) } ?? range.end
            let end = try HLSChecked.compare(heldEnd, requested.end) > 0 ? requested.end : heldEnd
            guard try HLSChecked.compare(start, end) < 0 else { continue }
            return try .init(start: start, end: end)
        }
        return nil
    }
}

/// 只读遍历已封口 init/fragment；保存最终固定上限的 sample 表，不复制媒体或物化 box 树。
/// Actual emitted initialization facts. These values alone authorize nothing;
/// the writer callback lane must compare them to its frozen producer evidence.
enum FMP4AudioChannelLayout: Sendable, Equatable {
    case bitmap(UInt32)
    case tag(UInt32)
}
struct FMP4CompressedAudioInitialization: Sendable {
    let sampleEntry: UInt32
    let timescale: Int32
    let sampleEntryChannelCount: UInt16
    let sampleEntrySampleRate: UInt32
    let decoderConfiguration: Data
    let channelLayout: FMP4AudioChannelLayout?
    let sampleEntryDigest: Data
}
/// Parsed metadata only: this object is not a callback seal or a publication
/// capability. Its last alias retains the exact prepaid parser storage envelope.
final class SourceAACFragmentInspection: @unchecked Sendable {
    let writtenRange: FMP4PresentationRange
    private let commonByteSpans: [Range<Int>]
    private let samples: [SealedDecodeSampleEntry]
    private let charge: HLSCompressedAudioApplicationReservation
    var sampleCount: Int { samples.count }
    var commonSpanCount: Int { commonByteSpans.count }
    func sample(at index: Int) -> SealedDecodeSampleEntry? {
        samples.indices.contains(index) ? samples[index] : nil
    }
    func commonSpan(at index: Int) -> Range<Int>? {
        commonByteSpans.indices.contains(index) ? commonByteSpans[index] : nil
    }
    fileprivate init(range: FMP4PresentationRange, common: [Range<Int>], samples: [SealedDecodeSampleEntry],
                     charge: HLSCompressedAudioApplicationReservation) {
        writtenRange = range; commonByteSpans = common; self.samples = samples; self.charge = charge
    }
}
enum FMP4CompressedAudioInspection {
    static func initialization(_ data: Data) throws -> FMP4CompressedAudioInitialization {
        guard data.count <= 65_536 else { throw CompletedMediaEvidenceError.capacityExceeded }
        return try data.withUnsafeBytes { try FMP4DecodeMapParser.compressedAudioInitialization(in: $0) }
    }

    static func sourceAACFragment(initialization: Data, media: Data,
                                  configuration: SourceAACWriterConfiguration,
                                  expectedDuration: ExactMediaTime,
                                  applicationLedger: HLSDeliveryApplicationChargeLedger = .shared) throws -> SourceAACFragmentInspection {
        guard configuration.authority.stream.isCurrent else { throw SourceAACFailure.sourceMismatch }
        guard media.count <= 8 * 1_024 * 1_024 else { throw CompletedMediaEvidenceError.capacityExceeded }
        // Two arrays account for decode and presentation ordering; init sample-entry
        // hashing may copy at most the separately bounded 64 KiB initialization.
        let storage = 65_536 + 2 * 320 * MemoryLayout<SealedDecodeSampleEntry>.stride + 8_192
        guard storage <= 131_072 else { throw CompletedMediaEvidenceError.capacityExceeded }
        let charge = try HLSCompressedAudioApplicationReservation.reserve(bytes: storage, ledger: applicationLedger)
        _ = try SourceAACInitializationEvidence.validate(initialization, configuration: configuration)
        let range = try FMP4DecodeMapParser.sourceAudioRange(initialization: initialization,
            media: media, duration: expectedDuration)
        let result = try FMP4DecodeMapParser.parse(initialization: initialization, media: media, mediaType: .audio,
            expectedPresentationRange: range, sampleCountLimit: .sourceAAC)
        let cadence = ExactMediaTime(value: 1_024, timescale: configuration.sampleRate)
        guard result.samples.allSatisfy({ $0.presentationRange.duration == cadence }) else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        return SourceAACFragmentInspection(range: range, common: result.commonByteSpans,
            samples: result.samples, charge: charge)
    }
}

private enum FMP4DecodeMapParser {
    enum SampleCountLimit: Equatable {
        case ordinary, sourceAAC, authenticatedAAC, authenticatedVideo
        var value: Int {
            switch self {
            case .ordinary: return 256
            case .sourceAAC, .authenticatedAAC: return 320
            case .authenticatedVideo: return 384
            }
        }
    }
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
                      expectedPresentationRange: FMP4PresentationRange,
                      sampleCountLimit: SampleCountLimit = .ordinary) throws -> Result {
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
                samples.reserveCapacity(sampleCountLimit.value)
                var nearestRandomAccess: UInt16?
                var childOffset = traf.payloadStart
                while childOffset < traf.end {
                    let child = try readBox(at: childOffset, limit: traf.end, bytes: mediaBytes)
                    if child.type == 0x7472756e {
                        try appendRun(child, moofStart: moof.start, defaults: defaults,
                            facts: facts, bytes: mediaBytes, decodeTime: &decodeTime,
                            payloadCursor: &payloadCursor, nearestRandomAccess: &nearestRandomAccess,
                            samples: &samples, sampleCountLimit: sampleCountLimit)
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
                    try SealedDecodeCoverageMap.validateAudioContinuity(samples)
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

    /// Reuses the same checked box reader as coverage. The source path requires
    /// exactly one audio track/entry/configuration; it cannot use the ordinary
    /// first-track parser as permission to overlook a conflicting second track.
    static func compressedAudioInitialization(in bytes: UnsafeRawBufferPointer) throws
        -> FMP4CompressedAudioInitialization {
        let moov = try uniqueBox(0x6d6f6f76, in: 0..<bytes.count, bytes: bytes)
        let trak = try uniqueBox(0x7472616b, in: moov.payload, bytes: bytes)
        let mdia = try uniqueBox(0x6d646961, in: trak.payload, bytes: bytes)
        let hdlr = try uniqueBox(0x68646c72, in: mdia.payload, bytes: bytes)
        guard try handlerType(hdlr, bytes: bytes) == 0x736f756e else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let mdhd = try uniqueBox(0x6d646864, in: mdia.payload, bytes: bytes)
        try require(mdhd.payloadStart, 4, within: mdhd.end)
        guard bytes[mdhd.payloadStart] <= 1 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
        let scale = try mediaTimescale(mdhd, bytes: bytes)
        let minf = try uniqueBox(0x6d696e66, in: mdia.payload, bytes: bytes)
        let stbl = try uniqueBox(0x7374626c, in: minf.payload, bytes: bytes)
        let stsd = try uniqueBox(0x73747364, in: stbl.payload, bytes: bytes)
        try require(stsd.payloadStart, 8, within: stsd.end)
        guard readUInt32(stsd.payloadStart, bytes: bytes) == 0,
              readUInt32(stsd.payloadStart + 4, bytes: bytes) == 1 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let entry = try readBox(at: stsd.payloadStart + 8, limit: stsd.end, bytes: bytes)
        try require(entry.payloadStart, 28, within: entry.end)
        guard entry.end == stsd.end,
              bytes[entry.payloadStart + 8] == 0, bytes[entry.payloadStart + 9] == 0 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let configurationType: UInt32
        switch entry.type {
        case 0x6d703461: configurationType = 0x65736473
        case 0x61632d33: configurationType = 0x64616333
        case 0x65632d33: configurationType = 0x64656333
        default: throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let children = (entry.payloadStart + 28)..<entry.end
        let configuration = try uniqueBox(configurationType, in: children, bytes: bytes)
        let decoder: Data
        if entry.type == 0x6d703461 {
            decoder = try sourceAACDecoderConfiguration(configuration, bytes: bytes)
        } else {
            guard configuration.range.count <= 64 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            decoder = Data(bytes[configuration.range])
        }
        let channelLayout: FMP4AudioChannelLayout?
        if let channel = try uniqueOptionalBox(0x6368616e, in: children, bytes: bytes) {
            try require(channel.payloadStart, 16, within: channel.end)
            guard channel.payload.count == 16,
                  readUInt32(channel.payloadStart, bytes: bytes) == 0,
                  readUInt32(channel.payloadStart + 12, bytes: bytes) == 0 else {
                throw CompletedMediaEvidenceError.invalidDecodeMap
            }
            let tag = readUInt32(channel.payloadStart + 4, bytes: bytes)
            let bitmap = readUInt32(channel.payloadStart + 8, bytes: bytes)
            if tag == 0x00010000 {
                guard bitmap != 0 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
                channelLayout = .bitmap(bitmap)
            } else {
                guard tag != 0, bitmap == 0 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
                channelLayout = .tag(tag)
            }
        } else { channelLayout = nil }
        let channelOffset = entry.payloadStart + 16
        return FMP4CompressedAudioInitialization(sampleEntry: entry.type, timescale: scale,
            sampleEntryChannelCount: UInt16(bytes[channelOffset]) << 8 | UInt16(bytes[channelOffset + 1]),
            sampleEntrySampleRate: readUInt32(entry.payloadStart + 24, bytes: bytes) >> 16,
            decoderConfiguration: decoder, channelLayout: channelLayout,
            sampleEntryDigest: Data(SHA256.hash(data: Data(bytes[entry.range]))))
    }

    private static func sourceAACDecoderConfiguration(_ esds: Box, bytes: UnsafeRawBufferPointer) throws -> Data {
        try require(esds.payloadStart, 4, within: esds.end)
        guard readUInt32(esds.payloadStart, bytes: bytes) == 0 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        var cursor = esds.payloadStart + 4
        func descriptor(_ tag: UInt8, end: Int) throws -> Range<Int> {
            try require(cursor, 2, within: end)
            guard bytes[cursor] == tag else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            cursor += 1
            var length = 0
            for index in 0..<4 {
                try require(cursor, 1, within: end)
                let byte = bytes[cursor]; cursor += 1
                length = length << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 {
                    try require(cursor, length, within: end)
                    return cursor..<(cursor + length)
                }
                guard index < 3 else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            }
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let es = try descriptor(3, end: esds.end)
        try require(cursor, 3, within: es.upperBound)
        guard es.upperBound == esds.end, bytes[cursor + 2] == 0 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        cursor += 3
        let decoder = try descriptor(4, end: es.upperBound)
        try require(cursor, 13, within: decoder.upperBound)
        guard bytes[cursor] == 0x40, bytes[cursor + 1] == 0x14 || bytes[cursor + 1] == 0x15 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        cursor += 13
        let asc = try descriptor(5, end: decoder.upperBound)
        guard (2...64).contains(asc.count), asc.upperBound == decoder.upperBound else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        let result = Data(bytes[asc])
        do { _ = try AudioSpecificConfig.parse(result) }
        catch { throw CompletedMediaEvidenceError.invalidDecodeMap }
        cursor = asc.upperBound
        let sl = try descriptor(6, end: es.upperBound)
        guard sl.count == 1, bytes[sl.lowerBound] == 2, sl.upperBound == es.upperBound else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        return result
    }

    private static func uniqueBox(_ type: UInt32, in range: Range<Int>, bytes: UnsafeRawBufferPointer) throws -> Box {
        guard let result = try uniqueOptionalBox(type, in: range, bytes: bytes) else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        return result
    }
    private static func uniqueOptionalBox(_ type: UInt32, in range: Range<Int>,
                                          bytes: UnsafeRawBufferPointer) throws -> Box? {
        var result: Box?
        var offset = range.lowerBound
        while offset < range.upperBound {
            let box = try readBox(at: offset, limit: range.upperBound, bytes: bytes)
            if box.type == type {
                guard result == nil else { throw CompletedMediaEvidenceError.invalidDecodeMap }
                result = box
            }
            offset = box.end
        }
        return result
    }

    static func sourceAudioRange(initialization: Data, media: Data,
                                 duration: ExactMediaTime) throws -> FMP4PresentationRange {
        let scale = try initialization.withUnsafeBytes {
            try compressedAudioInitialization(in: $0).timescale
        }
        return try media.withUnsafeBytes { bytes in
            let moof = try uniqueBox(0x6d6f6f66, in: 0..<bytes.count, bytes: bytes)
            let traf = try uniqueBox(0x74726166, in: moof.payload, bytes: bytes)
            let tfdt = try uniqueBox(0x74666474, in: traf.payload, bytes: bytes)
            let raw = try baseDecodeTime(tfdt, bytes: bytes)
            guard let start = Int64(exactly: raw) else { throw CompletedMediaEvidenceError.invalidDecodeMap }
            return try FMP4PresentationRange(start: ExactMediaTime(value: start, timescale: scale), duration: duration)
        }
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
                                  samples: inout [SealedDecodeSampleEntry], sampleCountLimit: SampleCountLimit) throws {
        try require(run.payloadStart, 8, within: run.end)
        let version = bytes[run.payloadStart]
        let flags = readUInt32(run.payloadStart, bytes: bytes) & 0x00ff_ffff
        guard flags & 0x000004 == 0 || flags & 0x000400 == 0 else {
            throw CompletedMediaEvidenceError.invalidDecodeMap
        }
        guard let count = Int(exactly: readUInt32(run.payloadStart + 4, bytes: bytes)),
              count > 0, count <= sampleCountLimit.value - samples.count else {
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
    let requested: ExactMediaInterval
    let presentationOffset: ExactMediaTime
    let offset: UInt8
    let count: UInt8

    init(rendition: AudioRenditionIdentity, requested: ExactMediaInterval,
         offset: UInt8, count: UInt8, presentationOffset: ExactMediaTime = HLSChecked.zero) {
        self.rendition = rendition; self.requested = requested
        self.presentationOffset = presentationOffset
        self.offset = offset; self.count = count
    }

    init(rendition: AudioRenditionIdentity, requested: FMP4PresentationRange,
         offset: UInt8, count: UInt8, presentationOffset: ExactMediaTime = HLSChecked.zero) {
        self.init(rendition: rendition, requested: ExactMediaInterval(requested),
                  offset: offset, count: count, presentationOffset: presentationOffset)
    }
}

struct ServedCoverageDependencies: RandomAccessCollection, Sendable, Equatable {
    enum Storage: Sendable {
        case explicit([ServedRenditionCoverageDependency])
        case frozen(owner: FrozenPreparationOwner, coverageIndex: UInt8)
        case paused(owner: PausedWindowCoverageLease, coverageIndex: UInt8)
    }
    let storage: Storage
    private var ownerProjection: (owner: FrozenCompletedCoverageOwner, index: UInt8)? {
        switch storage {
        case .explicit: return nil
        case .frozen(let owner, let index): return (.startup(owner), index)
        case .paused(let owner, let index): return (.paused(owner), index)
        }
    }
    var startIndex: Int { 0 }
    var endIndex: Int {
        if case .explicit(let values) = storage { return values.count }
        let projection = ownerProjection!
        return Int(projection.owner.coverage(at: projection.index)!.count)
    }
    func input(at slot: Int) -> SealedCoverageInput? {
        guard let (owner, _) = ownerProjection,
              owner.containsCompletedResource(slot),
              let input = owner.metadataStore?.preparationCoverageInput(slot: slot, owner: owner),
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
        guard let (owner, coverageIndex) = ownerProjection else { preconditionFailure() }
        return dependency(input(at: Int(owner.coverageResource(at: index, coverage: coverageIndex)))!)
    }
    func input(atOrdinal ordinal: Int) -> SealedCoverageInput? {
        guard let (owner, coverageIndex) = ownerProjection else { return nil }
        return input(at: Int(owner.coverageResource(at: ordinal, coverage: coverageIndex)))
    }
    static func frozen(owner: FrozenPreparationOwner, rendition: AudioRenditionIdentity,
                       requested: FMP4PresentationRange) throws -> Self? {
        try frozen(owner: .startup(owner), rendition: rendition, requested: requested)
    }
    static func frozen(owner: PausedWindowCoverageLease, rendition: AudioRenditionIdentity,
                       requested: FMP4PresentationRange) throws -> Self? {
        try frozen(owner: .paused(owner), rendition: rendition, requested: requested)
    }
    static func frozen(owner: FrozenCompletedCoverageOwner, rendition: AudioRenditionIdentity,
                       requested: FMP4PresentationRange) throws -> Self? {
        guard owner.completionIsFrozen else { return nil }
        var indices = FrozenCoverageIndices()
        for index in UInt8(0)..<2 {
            if let existing = owner.coverage(at: index),
               existing.rendition == rendition, existing.requested == ExactMediaInterval(requested),
               existing.presentationOffset == HLSChecked.zero {
                return owner.dependencies(at: index)
            }
        }
        guard owner.coverage(at: 1) == nil else { throw CompletedMediaEvidenceError.capacityExceeded }
        let coverageIndex: UInt8 = owner.coverage(at: 0) == nil ? 0 : 1
        let view = owner.dependencies(at: coverageIndex)
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

/// Immutable media verification only. A server must separately bind a paused
/// window to its original item/timeline and current owned resume scope.
struct FrozenRenditionCoverageReceipt: Sendable, Equatable {
    let renditionIdentity: AudioRenditionIdentity
    let itemGeneration: UInt64
    let canonicalCoverageDigest: FrozenCanonicalCoverageDigest
    let presentationRange: FMP4PresentationRange
    let dependencies: ServedCoverageDependencies

    init(authority: SealedCoverageIssuanceAuthority,
         renditionIdentity: AudioRenditionIdentity,
         itemGeneration: UInt64,
         canonicalCoverageDigest: FrozenCanonicalCoverageDigest,
         presentationRange: FMP4PresentationRange,
         dependencies: ServedCoverageDependencies) {
        self.renditionIdentity = renditionIdentity
        self.itemGeneration = itemGeneration
        self.canonicalCoverageDigest = canonicalCoverageDigest
        self.presentationRange = presentationRange
        self.dependencies = dependencies
    }
}

// Paused coverage preserves exact endpoints without manufacturing a duration.
struct PausedRenditionCoverageReceipt: Sendable, Equatable {
    let renditionIdentity: AudioRenditionIdentity
    let itemGeneration: UInt64
    let canonicalCoverageDigest: FrozenCanonicalCoverageDigest
    let presentationRange: ExactMediaInterval
    let presentationOffset: ExactMediaTime
    let dependencies: ServedCoverageDependencies

    init(authority: SealedCoverageIssuanceAuthority,
         renditionIdentity: AudioRenditionIdentity,
         itemGeneration: UInt64,
         canonicalCoverageDigest: FrozenCanonicalCoverageDigest,
         presentationRange: ExactMediaInterval, presentationOffset: ExactMediaTime,
         dependencies: ServedCoverageDependencies) {
        self.renditionIdentity = renditionIdentity
        self.itemGeneration = itemGeneration
        self.canonicalCoverageDigest = canonicalCoverageDigest
        self.presentationRange = presentationRange
        self.presentationOffset = presentationOffset
        self.dependencies = dependencies
    }
}

final class ServedRenditionCoverageAccumulator: @unchecked Sendable {
    private struct CoverageEntry {
        let dependency: ServedRenditionCoverageDependency
        let initializationDigest: Data
        let mediaDigest: Data
        let maximumSampleCount: Int
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
                guard entries[index].maximumSampleCount == map.maximumSampleCount else {
                    throw CompletedMediaEvidenceError.identityMismatch
                }
                entries[index].ranges = try Self.union(entries[index].ranges
                    + covered)
            } else {
                guard entries.count < LoopbackStorageLayout.current.coverageAccumulatorDependencyCapacity else {
                    throw CompletedMediaEvidenceError.capacityExceeded
                }
                entries.append(.init(dependency: dependency,
                    initializationDigest: initialization.sealedDigest,
                    mediaDigest: media.sealedDigest, maximumSampleCount: map.maximumSampleCount,
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
                Self.append(UInt64(item.maximumSampleCount), to: &canonical)
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
