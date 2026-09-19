// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

struct DemuxPacket: Sendable, Equatable {
    let streamIndex: Int32
    let codec: MediaCodec
    let data: Data
    let presentationTimeStamp: CMTime
    let decodeTimeStamp: CMTime
    let duration: CMTime
    let isKey: Bool
    let isCorrupt: Bool
}

enum DemuxDiscontinuityReason: Sendable, Equatable {
    case formatChange
    case timelineReset
}

enum DemuxEvent: Sendable, Equatable {
    case tracks(DemuxTrackSet)
    case packet(DemuxPacket)
    case discontinuity(DemuxTrackSet, reason: DemuxDiscontinuityReason)
    case endOfStream
    case cancelled
    case failure(PlaybackCoreError)
}

protocol DemuxDataPlaneAdmissionLease: AnyObject, Sendable {
    var bytes: Int { get }
    func release()
}

enum DemuxDataPlaneAdmissionResult: Sendable {
    case accepted(any DemuxDataPlaneAdmissionLease)
    case cancelled
    case permanentlyRejected
}

/// 生产 I/O lane 在复制 C callback 借用字节前调用；control/MainActor 不得等待此接口。
protocol DemuxDataPlaneAdmitting: AnyObject, Sendable {
    func waitForAdmission(bytes: Int, applicationBytes: Int)
        -> DemuxDataPlaneAdmissionResult
    func cancel()
}

/// 同一 owner 从 queue 移交给 envelope；消费者必须让 envelope 跟随所有裸媒体 alias。
/// 最后一个 owner alias 退出后才归还准入，不以 queue pop 或 sink 返回为退费点。
final class DemuxAdmissionTail: @unchecked Sendable {
    private let lease: any DemuxDataPlaneAdmissionLease

    init(lease: any DemuxDataPlaneAdmissionLease) {
        self.lease = lease
    }

    deinit { lease.release() }
}

/// 正式 HLS 消费入口。消费者把这个 owner 与 packet/extradata 一起移交，
/// 不把可复制的裸 Data 当作能独立携带准入的 owner。
final class AdmittedDemuxEvent: @unchecked Sendable {
    private let storedEvent: DemuxEvent
    private let admissionTail: DemuxAdmissionTail?

    init(event: DemuxEvent, admissionTail: DemuxAdmissionTail?) {
        storedEvent = event
        self.admissionTail = admissionTail
    }

    var isTerminal: Bool {
        switch storedEvent {
        case .endOfStream, .cancelled, .failure: true
        case .tracks, .packet, .discontinuity: false
        }
    }

    /// `event` 及其 Data 只在此同步借用窗有效。若下游异步保存 packet/extradata，
    /// 必须同时保存本 owner；若制造独立副本，则副本由下游另行申请 application charge。
    func withBorrowedEvent(_ body: (DemuxEvent) -> Void) {
        withExtendedLifetime(admissionTail) { body(storedEvent) }
    }
}

protocol AdmittedMediaDemuxing: AnyObject {
    func start(
        url: URL,
        admission: any DemuxDataPlaneAdmitting,
        sink: @escaping @Sendable (AdmittedDemuxEvent) -> Void
    ) throws
}

protocol MediaDemuxing: AnyObject {
    func start(url: URL, sink: @escaping @Sendable (DemuxEvent) -> Void) throws
    func cancel()
    /// Wall time the read thread has spent waiting for room in the delivery
    /// queue. This is the difference between "the source is not giving us
    /// realtime" and "we are not draining fast enough to keep reading it": if the
    /// reader never waits here, the shortfall is upstream of the app.
    var queueFullWaitNanoseconds: UInt64 { get }
}

extension MediaDemuxing {
    var queueFullWaitNanoseconds: UInt64 { 0 }
}
