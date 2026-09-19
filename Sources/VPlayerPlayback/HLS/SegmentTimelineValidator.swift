// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// writer timeline、publisher offer 与最终 coverage 必须共享同一连续性定义。
/// AAC 只允许完整 AU 对齐误差；系统签发的视频片段只允许系统 report 的 100ms
/// 边界量化误差。没有 publication evidence 的视频仍要求精确连续。
enum HLSSegmentContinuity {
    static func accepts(
        previousEnd: ExactMediaTime,
        nextStart: ExactMediaTime,
        mediaType: FinalFMP4MediaType,
        accessUnitDuration: ExactMediaTime?,
        hasPublicationEvidence: Bool
    ) -> Bool {
        guard previousEnd != nextStart else { return true }
        let delta = abs(nextStart.cmTime.seconds - previousEnd.cmTime.seconds)
        switch mediaType {
        case .audio:
            let tolerance = max((accessUnitDuration?.cmTime.seconds ?? 0.035) * 2, 0.10)
            return delta <= tolerance
        case .video:
            return hasPublicationEvidence && delta <= 0.10
        }
    }
}

struct FMP4PresentationRange: Sendable, Hashable {
    let start: ExactMediaTime
    let duration: ExactMediaTime
    let end: ExactMediaTime

    /// 无签发权限的事实检查，供诊断使用；正式 timeline 另须先验证系统来源资格。
    static func inspect(report: SegmentReportReference, mediaType: FinalFMP4MediaType) throws -> Self {
        try Self(report: report, mediaType: mediaType)
    }

    private init(report: SegmentReportReference, mediaType: FinalFMP4MediaType) throws {
        guard report.hasUniqueMatchingTrack,
              report.mediaType == mediaType.avMediaType,
              let reportedStart = report.earliestPresentationTimeStamp,
              let reportedDuration = report.duration else {
            throw FinalFMP4ValidationFailure.missingTrackReport
        }
        start = try ExactMediaTime(reportedStart)
        duration = try ExactMediaTime(reportedDuration)
        guard start.value >= 0, duration.value > 0 else {
            throw FinalFMP4ValidationFailure.invalidPresentationRange
        }
        end = try start.adding(duration)
    }
}

/// 定长 commitment 绑定完整 binding、writer、backing/range/digest、report、kind 和 callback。
/// receipt 本体不保留对象、report、媒体 bytes 或可增长集合；只能在本文件事务成功后签发。
struct SegmentValidationReceipt: Sendable, Hashable {
    let identity: UUID
    let epochProofIdentity: UUID
    let logicalSequence: UInt64
    let presentationRange: FMP4PresentationRange
    private let objectCommitment: FMP4Digest

    fileprivate init(proof: EpochFormatProof, identity: FMP4ObjectIdentity, range: FMP4PresentationRange) {
        self.identity = UUID()
        epochProofIdentity = proof.identity
        logicalSequence = identity.logicalSequence
        presentationRange = range
        objectCommitment = identity.commitment
    }

    func matches(mediaIdentity: FMP4ObjectIdentity, proof: EpochFormatProof) -> Bool {
        epochProofIdentity == proof.identity
            && mediaIdentity.binding == proof.binding
            && mediaIdentity.writerIdentity == proof.binding.writerIdentity
            && mediaIdentity.kind == .media
            && mediaIdentity.logicalSequence == logicalSequence
            && mediaIdentity.commitment == objectCommitment
    }

    func matches(media: SealedMediaObject, proof: EpochFormatProof) -> Bool {
        guard let identity = try? FMP4ObjectIdentity(media) else { return false }
        return matches(mediaIdentity: identity, proof: proof)
    }
}

struct SegmentTimelineValidationState: Sendable, Equatable {
    let nextLogicalSequence: UInt64
    let previousEnd: ExactMediaTime?
    let isClosed: Bool
}

/// 每条 rendition 的独立时间线；验证与提交使用同一把锁，失败不改变任何已提交字段。
final class SegmentTimelineValidator: @unchecked Sendable {
    private let lock = NSLock()
    private let proof: EpochFormatProof
    private var nextLogicalSequence: UInt64
    private var previousEnd: ExactMediaTime?
    private var isClosed = false

    init(proof: EpochFormatProof, firstLogicalSequence: UInt64 = 0) {
        self.proof = proof
        nextLogicalSequence = firstLogicalSequence
    }

    var state: SegmentTimelineValidationState {
        lock.withLock {
            SegmentTimelineValidationState(nextLogicalSequence: nextLogicalSequence,
                previousEnd: previousEnd, isClosed: isClosed)
        }
    }

    func validate(_ object: SealedMediaObject, using proof: EpochFormatProof) throws -> SegmentValidationReceipt {
        try lock.withLock {
            guard !isClosed else { throw FinalFMP4ValidationFailure.closed }
            guard self.proof == proof else { throw FinalFMP4ValidationFailure.identityMismatch }
            guard object.logicalSequence == nextLogicalSequence else {
                throw FinalFMP4ValidationFailure.discontinuousTimeline
            }
            let identity = try FinalFMP4Validator.validateObject(object, kind: .media, binding: proof.binding)
            guard let provenance = object.report.systemProvenance,
                  provenance.accepts(reference: object.report, mediaType: proof.mediaType.avMediaType) else {
                throw FinalFMP4ValidationFailure.missingTrackReport
            }
            let range = try FMP4PresentationRange.inspect(report: object.report, mediaType: proof.mediaType)
            if let previousEnd,
               !HLSSegmentContinuity.accepts(
                   previousEnd: previousEnd,
                   nextStart: range.start,
                   mediaType: proof.mediaType,
                   accessUnitDuration: object.publicationEvidence?.boundary?.accessUnitDuration,
                   hasPublicationEvidence: object.publicationEvidence != nil
               ) {
                    let diffStr = (try? range.start.subtracting(previousEnd)).map { "\($0.value)/\($0.timescale)" } ?? "unknown"
                    PlaybackDiagnosticTracker.shared.set("fail_val_seq\(object.logicalSequence)_\(proof.mediaType)_s\(range.start.value)t\(range.start.timescale)_p\(previousEnd.value)t\(previousEnd.timescale)_d\(diffStr)")
                    throw FinalFMP4ValidationFailure.discontinuousTimeline
            }
            let next = nextLogicalSequence.addingReportingOverflow(1)
            guard !next.overflow else { throw FinalFMP4ValidationFailure.arithmeticOverflow }
            let receipt = SegmentValidationReceipt(proof: proof, identity: identity, range: range)
            nextLogicalSequence = next.partialValue
            previousEnd = range.end
            return receipt
        }
    }

    func close() { lock.withLock { isClosed = true } }
}
