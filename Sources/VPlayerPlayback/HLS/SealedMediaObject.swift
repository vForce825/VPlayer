// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CryptoKit
import Foundation

struct FMP4WriterIdentity: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

struct FMP4WriterBinding: Sendable, Hashable {
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let itemGeneration: AudioItemGenerationIdentity
    let mediaEpoch: AudioMediaEpochIdentity
    let publicationParticipantID: AudioPublicationParticipantIdentity
    let renditionIdentity: AudioRenditionIdentity
    let writerIdentity: FMP4WriterIdentity
}

struct SegmentCallbackTicket: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

enum SealedMediaObjectKind: UInt8, Sendable, Hashable {
    case initialization = 1
    case media = 2
}

struct SealedMediaBackingIdentity: RawRepresentable, Sendable, Hashable {
    let rawValue: UUID
}

final class SealedMediaBacking: @unchecked Sendable {
    let identity: SealedMediaBackingIdentity
    let bytes: Data

    init(copying bytes: NSData) {
        identity = .init(rawValue: UUID())
        self.bytes = Data(bytes: bytes.bytes, count: bytes.length)
    }
}

/// 系统 report 不允许直接构造；该读取边界允许测试注入缺轨、歧义和坏时间。
protocol SegmentedFMP4TrackReportReading {
    var mediaType: AVMediaType { get }
    var earliestPresentationTimeStamp: CMTime { get }
    var duration: CMTime { get }
}

protocol SegmentedFMP4ReportReading {
    var trackCount: Int { get }
    func track(at index: Int) -> any SegmentedFMP4TrackReportReading
}

extension AVAssetSegmentTrackReport: SegmentedFMP4TrackReportReading {}

private struct AVAssetSegmentReportReader: SegmentedFMP4ReportReading {
    let report: AVAssetSegmentReport
    var trackCount: Int { report.trackReports.count }
    func track(at index: Int) -> any SegmentedFMP4TrackReportReading { report.trackReports[index] }
}

/// callback 当场冻结唯一轨道的事实；validator 不接受调用方传入 start/duration。
struct SegmentedFMP4SystemReportEvidence: @unchecked Sendable {
    let systemReport: AVAssetSegmentReport?
    let earliestPresentationTimeStamp: CMTime?
    let duration: CMTime?
    let mediaType: AVMediaType?
    let hasUniqueMatchingTrack: Bool
    let systemProvenance: SegmentedFMP4SystemReportProvenance?
    let callbackCapsule: SegmentedFMP4SystemCallbackCapsule?

    /// 既有 writer mapping 适配入口不具备完整 range 证据，不能用于签发 segment receipt。
    init(systemReport: AVAssetSegmentReport?, earliestPresentationTimeStamp: CMTime?) {
        self.systemReport = systemReport
        self.earliestPresentationTimeStamp = earliestPresentationTimeStamp
        duration = nil
        mediaType = nil
        hasUniqueMatchingTrack = false
        systemProvenance = nil
        callbackCapsule = nil
    }

    private init(
        systemReport: AVAssetSegmentReport?,
        source: (any SegmentedFMP4ReportReading)?,
        mediaType: AVMediaType
    ) {
        self.systemReport = systemReport
        systemProvenance = nil
        callbackCapsule = nil
        guard let source, source.trackCount == 1 else {
            earliestPresentationTimeStamp = nil
            duration = nil
            self.mediaType = nil
            hasUniqueMatchingTrack = false
            return
        }
        let track = source.track(at: 0)
        hasUniqueMatchingTrack = track.mediaType == mediaType
        self.mediaType = track.mediaType
        earliestPresentationTimeStamp = track.earliestPresentationTimeStamp
        duration = track.duration
    }

    static func from(
        systemReport: AVAssetSegmentReport?,
        mediaType: AVMediaType
    ) -> Self {
        Self(
            systemReport: systemReport,
            source: systemReport.map { AVAssetSegmentReportReader(report: $0) },
            mediaType: mediaType
        )
    }

    /// 仅提取事实，不赋予正式签发资格；真实来源资格另由 production delegate 签出。
    static func reading(_ source: (any SegmentedFMP4ReportReading)?, mediaType: AVMediaType) -> Self {
        Self(systemReport: nil, source: source, mediaType: mediaType)
    }

    /// 资格本身不可构造；混用来源或时间会在 reference 绑定时被资格持有者拒绝。
    init(attesting evidence: Self, provenance: SegmentedFMP4SystemReportProvenance) {
        systemReport = evidence.systemReport
        earliestPresentationTimeStamp = evidence.earliestPresentationTimeStamp
        duration = evidence.duration
        mediaType = evidence.mediaType
        hasUniqueMatchingTrack = evidence.hasUniqueMatchingTrack
        systemProvenance = provenance
        callbackCapsule = evidence.callbackCapsule
    }

    /// capsule 构造和签发均封闭；该复制入口不能替换 capsule 内的原始事实。
    init(callback evidence: Self, capsule: SegmentedFMP4SystemCallbackCapsule) {
        systemReport = evidence.systemReport
        earliestPresentationTimeStamp = evidence.earliestPresentationTimeStamp
        duration = evidence.duration
        mediaType = evidence.mediaType
        hasUniqueMatchingTrack = evidence.hasUniqueMatchingTrack
        systemProvenance = evidence.systemProvenance
        callbackCapsule = capsule
    }
}

final class SegmentReportReference: @unchecked Sendable {
    let identity = UUID()
    let systemReport: AVAssetSegmentReport?
    let earliestPresentationTimeStamp: CMTime?
    let duration: CMTime?
    let mediaType: AVMediaType?
    let hasUniqueMatchingTrack: Bool
    let systemProvenance: SegmentedFMP4SystemReportProvenance?

    init(evidence: SegmentedFMP4SystemReportEvidence) {
        systemReport = evidence.systemReport
        earliestPresentationTimeStamp = evidence.earliestPresentationTimeStamp
        duration = evidence.duration
        mediaType = evidence.mediaType
        hasUniqueMatchingTrack = evidence.hasUniqueMatchingTrack
        if let provenance = evidence.systemProvenance,
           provenance.bind(referenceIdentity: identity, evidence: evidence) {
            systemProvenance = provenance
        } else {
            systemProvenance = nil
        }
    }
}

struct SealedMediaObject: @unchecked Sendable {
    let binding: FMP4WriterBinding
    let writerIdentity: FMP4WriterIdentity
    let callbackTicket: SegmentCallbackTicket
    let logicalSequence: UInt64
    let kind: SealedMediaObjectKind
    let backing: SealedMediaBacking
    let byteRange: AudioServiceByteRange
    let digest: Data
    let report: SegmentReportReference
    let publicationLease: UnpublishedLogicalSegmentLease?
    let publicationEvidence: SegmentedFMP4PublicationEvidence?

    /// 只从本对象真实 backing/report/binding 计算；没有 AAC system provenance
    /// 的对象不会产生 membership leaf。
    var aacMediaMembershipLeaf: AACMediaMembershipLeaf? {
        AACMediaMembershipLeaf(self)
    }

    /// callback 只复制一次；借用 backing 的冻结 `Data`，不会为每次访问创建切片。
    var bytes: Data {
        _read { yield backing.bytes }
    }

    init(
        binding: FMP4WriterBinding,
        writerIdentity: FMP4WriterIdentity,
        callbackTicket: SegmentCallbackTicket,
        logicalSequence: UInt64,
        kind: SealedMediaObjectKind,
        sourceBytes: NSData,
        report: SegmentReportReference,
        publicationLease: UnpublishedLogicalSegmentLease?,
        publicationEvidence: SegmentedFMP4PublicationEvidence? = nil
    ) {
        let backing = SealedMediaBacking(copying: sourceBytes)
        self.binding = binding
        self.writerIdentity = writerIdentity
        self.callbackTicket = callbackTicket
        self.logicalSequence = logicalSequence
        self.kind = kind
        self.backing = backing
        byteRange = AudioServiceByteRange(offset: 0, length: backing.bytes.count)!
        digest = Data(SHA256.hash(data: backing.bytes))
        self.report = report
        self.publicationLease = publicationLease
        self.publicationEvidence = publicationEvidence
    }
}
