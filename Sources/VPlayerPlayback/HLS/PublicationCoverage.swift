// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum HLSPublicationFailure: Error, Equatable {
    case identityMismatch, invalidSequence, invalidDuration, initialWindowInvariant
    case closed, staleTicket, deadlineExceeded, capacityExceeded, invalidPlaylist, arithmeticOverflow
}

/// 所有 publisher、store、availability 与 lease 操作共享此域；锁内不等待媒体或网络。
final class HLSLinearizationDomain: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    func sync<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

struct HLSProgramDateAnchor: Sendable, Hashable {
    let mediaOrigin: ExactMediaTime
    let utcMilliseconds: Int64
}

struct PublicationParticipantCoverage: Sendable, Hashable {
    let participantID: UInt64
    let itemGeneration: UInt64
    let ranges: [FMP4PresentationRange]
    let epochs: [UInt64]
}

/// 数组仅在封闭构造器中建立，最多四 participant、六 range 与七个已发布序号；不持有媒体。
/// 首次发布可为三至五段，随后增长为稳定的六段滑动窗口。
struct PublicationCoverage: Sendable, Hashable {
    let logicalSequences: [UInt64]
    let publishedWindow: [UInt64]
    let participants: [PublicationParticipantCoverage]
    let anchor: HLSProgramDateAnchor
    let isSixSegmentWindowEligible: Bool

    init(records: [UInt64: [HLSValidatedSegment]], anchor: HLSProgramDateAnchor) throws {
        guard !records.isEmpty, records.count <= 4, let first = records.values.first,
              (3...7).contains(first.count) else { throw HLSPublicationFailure.initialWindowInvariant }
        publishedWindow = first.map { $0.receipt.logicalSequence }
        logicalSequences = Array(publishedWindow.suffix(6))
        self.anchor = anchor
        var participants: [PublicationParticipantCoverage] = []
        var eligible = true
        for id in records.keys.sorted() {
            let segments = records[id]!
            guard segments.map({ $0.receipt.logicalSequence }) == publishedWindow else {
                throw HLSPublicationFailure.invalidSequence
            }
            for pair in zip(segments, segments.dropFirst()) {
                guard try HLSChecked.increment(pair.0.receipt.logicalSequence) == pair.1.receipt.logicalSequence,
                      pair.1.discontinuity || HLSSegmentContinuity.accepts(
                          previousEnd: pair.0.receipt.presentationRange.end,
                          nextStart: pair.1.receipt.presentationRange.start,
                          mediaType: pair.1.proof.mediaType,
                          accessUnitDuration: pair.1.boundary.accessUnitDuration,
                          hasPublicationEvidence: true
                      ) else {
                    throw HLSPublicationFailure.invalidSequence
                }
            }
            let tail = segments.suffix(6)
            let duration = try tail.reduce(HLSChecked.zero) { try $0.adding($1.receipt.presentationRange.duration) }
            let participantEligible = try HLSChecked.compare(duration, HLSChecked.six) >= 0
            eligible = eligible && participantEligible
            participants.append(PublicationParticipantCoverage(participantID: id,
                itemGeneration: segments[0].key.itemGeneration,
                ranges: tail.map { $0.receipt.presentationRange }, epochs: tail.map { $0.key.mediaEpoch }))
        }
        self.participants = participants
        isSixSegmentWindowEligible = eligible
    }
}

struct HLSValidatedSegment: Sendable {
    let key: HLSResourceKey
    let initializationKey: HLSResourceKey
    let proof: EpochFormatProof
    let receipt: SegmentValidationReceipt
    /// offer 时冻结的完整对象身份；natural-end 必须用它复验 writer terminal
    /// 对应的真实 media/backing/digest/report，不能只比较时间值。
    let objectIdentity: FMP4ObjectIdentity
    let bodyBytes: Int
    let commonStart: ExactMediaTime
    let commonDuration: ExactMediaTime
    let discontinuity: Bool
    let boundary: SegmentCommittedBoundary
}

enum HLSChecked {
    static let zero = ExactMediaTime(value: 0, timescale: 1)
    static let one = ExactMediaTime(value: 1, timescale: 1)
    static let three = ExactMediaTime(value: 3, timescale: 1)
    static let six = ExactMediaTime(value: 6, timescale: 1)
    static func add<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw HLSPublicationFailure.arithmeticOverflow }
        return result.partialValue
    }
    static func multiply<T: FixedWidthInteger>(_ a: T, _ b: T) throws -> T {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw HLSPublicationFailure.arithmeticOverflow }
        return result.partialValue
    }
    static func increment(_ value: UInt64) throws -> UInt64 {
        do { return try add(value, 1) }
        catch { PlaybackIdentityAllocator.shared.markIdentitySpaceExhausted(); throw error }
    }
    static func compare(_ a: ExactMediaTime, _ b: ExactMediaTime) throws -> Int {
        let lhs = try multiply(a.value, Int64(b.timescale))
        let rhs = try multiply(b.value, Int64(a.timescale))
        return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
    }
    static func nanoseconds(_ time: ExactMediaTime) throws -> Int64 {
        let numerator = try multiply(time.value, 1_000_000_000)
        let quotient = numerator / Int64(time.timescale)
        return try add(quotient, numerator % Int64(time.timescale) == 0 ? 0 : 1)
    }
}

struct HLSCapacityDerivation: Sendable {
    let requiredSegmentsPerRendition: Int
    let videoCoverageSeconds: Int
    let participantBitrates: [UInt64]
    let initializationBytes: Int
    let mapEvidenceBytes: Int
    let totalBytes: Int

    static func calculate(hard: Bool) throws -> Self {
        let backlog = hard ? 8 : 4
        let tail = hard ? 8 : 6
        let required = 22 + 7 + backlog + tail
        let seconds = 19 + 14 + backlog * 2
        let bitrates: [UInt64] = [81_600_000, 6_208_000, 704_000, 264_000]
        let offsets: [ExactMediaTime] = [HLSChecked.zero, .init(value: 192, timescale: 1000),
            .init(value: 1024, timescale: 48000), .init(value: 1024, timescale: 48000)]
        var bodies: UInt64 = 0
        for (bitrate, offset) in zip(bitrates, offsets) {
            let duration = try ExactMediaTime(value: Int64(seconds), timescale: 1).adding(offset)
            let numerator = try HLSChecked.multiply(bitrate, UInt64(duration.value))
            let denominator = UInt64(duration.timescale) * 8
            bodies = try HLSChecked.add(bodies, numerator / denominator + (numerator % denominator == 0 ? 0 : 1))
        }
        let initBytes = (hard ? 160 : 144) * 65_536
        let maps = 4 * (hard ? 48 : 42) * 16_384
        let total = try HLSChecked.add(Int(bodies), (hard ? 128 : 96) * 1_048_576 + initBytes + maps)
        return Self(requiredSegmentsPerRendition: required, videoCoverageSeconds: seconds,
            participantBitrates: bitrates, initializationBytes: initBytes, mapEvidenceBytes: maps, totalBytes: total)
    }
}
