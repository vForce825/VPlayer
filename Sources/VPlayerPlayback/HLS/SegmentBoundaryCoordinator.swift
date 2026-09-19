// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CryptoKit
import Foundation

enum SegmentedFMP4TrackKind: UInt8, Sendable, Hashable {
    case video = 1
    case aac = 2
    case ac3 = 3
    case eac3 = 4
}

enum SegmentVideoBoundaryMode: UInt8, Sendable, Hashable {
    case passthrough = 1
    case reencodedClosedGOP = 2
}

enum SegmentBoundaryMode: Sendable, Hashable {
    case audioVideo(
        epochStart: CMTime,
        videoMode: SegmentVideoBoundaryMode,
        minimumPassthroughInterval: CMTime? = nil,
        maximumPassthroughInterval: CMTime? = nil
    )
    case audioOnly(epochStart: CMTime)
}

enum SegmentAudioAccessUnitKind: Sendable, Hashable {
    case aac(sampleRate: Int32)
    case ac3(sampleRate: Int32)
    case eac3Aggregated(sampleRate: Int32, sampleCount: Int32)

    var trackKind: SegmentedFMP4TrackKind {
        switch self {
        case .aac: .aac
        case .ac3: .ac3
        case .eac3Aggregated: .eac3
        }
    }

    var sampleRateAndCount: (rate: Int32, count: Int32) {
        switch self {
        case let .aac(sampleRate): (sampleRate, 1_024)
        case let .ac3(sampleRate): (sampleRate, 1_536)
        case let .eac3Aggregated(sampleRate, sampleCount): (sampleRate, sampleCount)
        }
    }
}

enum SegmentBoundaryFailure: Error, Sendable, Equatable {
    case invalidTime
    case videoBoundaryExceeded
    case audioBoundaryExceeded
    case incompleteEAC3AccessUnit
    case firstEffectiveStartMismatch
    case duplicateRendition
    case unknownRendition
    case renditionCapacityExceeded
    case ticketMismatch
    case arithmeticOverflow
}

/// 发布层拒绝任一轨相对最慢轨达到八段。隔行视频 writer 必须在现有领先量为
/// 七段时先停住，等音频提交共同边界后再继续，不能把容量错误当作终态恢复。
enum HLSInterlacedVideoLeadPolicy {
    static let maximumCommittedSegmentLead: UInt64 = 7

    static func canAdvance(
        videoOffset: UInt64,
        audioNextBoundaryOffsets: [UInt64]
    ) -> Bool {
        guard let slowestNext = audioNextBoundaryOffsets.min(), slowestNext > 0 else {
            return true
        }
        let slowestCommitted = slowestNext - 1
        guard videoOffset > slowestCommitted else { return true }
        return videoOffset - slowestCommitted < maximumCommittedSegmentLead
    }
}

struct SegmentSequenceAllocator: Sendable, Hashable {
    let initialValue: UInt64

    init(initialValue: UInt64 = 0) {
        self.initialValue = initialValue
    }

    func value(offset: UInt64) throws -> UInt64 {
        let result = initialValue.addingReportingOverflow(offset)
        guard !result.overflow else { throw SegmentBoundaryFailure.arithmeticOverflow }
        return result.partialValue
    }
}

struct SegmentBoundaryUsage: Sendable, Equatable {
    let commonBoundarySlotCount: Int
    let renditionCount: Int
    let lastLogicalSequence: UInt64
}

/// 只暴露算法观察值，不能被任何 writer 入口消费。
struct SegmentBoundaryInspection: Sendable, Equatable {
    let logicalSequence: UInt64
    let requiresFlushBeforeAppend: Bool
}

enum SegmentBoundarySampleIdentity: Sendable, Hashable {
    case video(
        source: VideoEncodingFrameIdentity,
        sample: ObjectIdentifier,
        presentationStart: ExactMediaTime,
        format: ObjectIdentifier,
        hardwareSession: VTCompressionSessionID,
        isIDR: Bool,
        backing: ObjectIdentifier,
        digest: Data
    )
    case videoRemux(
        source: VideoAccessUnitEvidenceIdentity,
        sampleEntry: HLSVideoSampleEntry,
        parameterSetIdentity: VideoAccessUnitSHA256,
        formatIdentity: VideoAccessUnitSHA256,
        submission: ObjectIdentifier,
        attempt: UUID,
        presentationStart: ExactMediaTime,
        decodeStart: ExactMediaTime?,
        duration: ExactMediaTime,
        formatAuthority: ObjectIdentifier,
        isIDR: Bool,
        digest: VideoAccessUnitSHA256
    )
    case aac(
        sample: ObjectIdentifier,
        presentationStart: ExactMediaTime,
        format: ObjectIdentifier,
        digest: Data
    )
    case compressed(
        codec: AudioCodec,
        sampleRate: Int32,
        channelCount: Int32,
        sampleCount: Int32,
        formatConfiguration: CompressedAudioFormatConfiguration,
        admission: AudioBranchAdmissionIdentity,
        payload: CompressedAudioPayloadIdentity,
        range: AudioServiceByteRange,
        digest: AudioServiceEvidenceDigest,
        presentationStart: ExactMediaTime
    )
}

/// 正式边界会话的身份只在协调器构造时产生；writer 必须冻结同一实例。
final class SegmentBoundarySession: @unchecked Sendable {
    fileprivate let identity = UUID()
    fileprivate init() {}
}

/// 只有成功 append 并提交正式边界事务后可读；inspection 和 caller 时间不能构造它。
final class SegmentCommittedBoundary: @unchecked Sendable {
    let session: SegmentBoundarySession
    let binding: FMP4WriterBinding
    let logicalSequence: UInt64
    let commonStart: ExactMediaTime
    let epochStart: ExactMediaTime
    let accessUnitDuration: ExactMediaTime?
    fileprivate init(session: SegmentBoundarySession, binding: FMP4WriterBinding, sequence: UInt64,
                     start: ExactMediaTime, epochStart: ExactMediaTime, accessUnitDuration: ExactMediaTime?) {
        self.session = session; self.binding = binding; logicalSequence = sequence
        commonStart = start; self.epochStart = epochStart; self.accessUnitDuration = accessUnitDuration
    }
}

private final class SegmentBoundaryTicketTransaction: @unchecked Sendable {
    weak var coordinator: SegmentBoundaryCoordinator?
    let identity: UUID
    let expectedRevision: UInt64
    let decision: SegmentBoundaryCoordinator.Decision

    init(
        coordinator: SegmentBoundaryCoordinator,
        identity: UUID,
        expectedRevision: UInt64,
        decision: SegmentBoundaryCoordinator.Decision
    ) {
        self.coordinator = coordinator
        self.identity = identity
        self.expectedRevision = expectedRevision
        self.decision = decision
    }
}

/// 只有正式会话可以签发；一次性事务仅在系统 append 成功后提交边界推进。
final class SegmentBoundaryAppendTicket: @unchecked Sendable {
    let writerBinding: FMP4WriterBinding
    let trackKind: SegmentedFMP4TrackKind
    let logicalSequence: UInt64
    let requiresFlushBeforeAppend: Bool
    private let session: SegmentBoundarySession
    private let sampleIdentity: SegmentBoundarySampleIdentity
    private let transaction: SegmentBoundaryTicketTransaction
    private let lock = NSLock()
    private enum State: Equatable { case issued, prepared, committed, aborted }
    private var state: State = .issued
    private let boundary: SegmentCommittedBoundary
    var committedBoundary: SegmentCommittedBoundary? { lock.withLock { state == .committed ? boundary : nil } }

    fileprivate init(
        writerBinding: FMP4WriterBinding,
        trackKind: SegmentedFMP4TrackKind,
        logicalSequence: UInt64,
        requiresFlushBeforeAppend: Bool,
        sampleIdentity: SegmentBoundarySampleIdentity,
        session: SegmentBoundarySession,
        transaction: SegmentBoundaryTicketTransaction,
        boundary: SegmentCommittedBoundary
    ) {
        self.writerBinding = writerBinding
        self.trackKind = trackKind
        self.logicalSequence = logicalSequence
        self.requiresFlushBeforeAppend = requiresFlushBeforeAppend
        self.sampleIdentity = sampleIdentity
        self.session = session
        self.transaction = transaction
        self.boundary = boundary
    }

    func accepts(
        binding: FMP4WriterBinding,
        trackKind: SegmentedFMP4TrackKind,
        sampleIdentity: SegmentBoundarySampleIdentity,
        session: SegmentBoundarySession
    ) -> Bool {
        lock.withLock {
            state == .issued
                && writerBinding == binding
                && self.trackKind == trackKind
                && self.sampleIdentity == sampleIdentity
                && self.session === session
                && transaction.coordinator?.accepts(transaction) == true
        }
    }

    func prepare(
        binding: FMP4WriterBinding,
        trackKind: SegmentedFMP4TrackKind,
        sampleIdentity: SegmentBoundarySampleIdentity,
        session: SegmentBoundarySession
    ) -> Bool {
        lock.withLock {
            guard state == .issued,
                  writerBinding == binding,
                  self.trackKind == trackKind,
                  self.sampleIdentity == sampleIdentity,
                  self.session === session,
                  transaction.coordinator?.accepts(transaction) == true else { return false }
            state = .prepared
            return true
        }
    }

    func commit(authority: SegmentedFMP4Writer.AppendSuccessAuthority? = nil) -> Bool {
        lock.withLock {
            guard state == .prepared,
                  let authority,
                  authority.consume(
                    binding: writerBinding,
                    trackKind: trackKind,
                    sampleIdentity: sampleIdentity,
                    session: session,
                    ticket: self
                  ),
                  transaction.coordinator?.commit(transaction) == true else { return false }
            state = .committed
            return true
        }
    }

    func abort(binding: FMP4WriterBinding, session: SegmentBoundarySession) {
        guard writerBinding == binding, self.session === session else { return }
        abortUnconditionally()
    }

    private func abortUnconditionally() {
        let shouldAbort = lock.withLock { () -> Bool in
            guard state == .issued || state == .prepared else { return false }
            state = .aborted
            return true
        }
        if shouldAbort { transaction.coordinator?.abort(transaction) }
    }

    deinit { abortUnconditionally() }
}

final class SegmentBoundaryCoordinator {
    fileprivate struct AudioState {
        let kind: SegmentAudioAccessUnitKind
        var nextBoundaryOffset: UInt64
    }

    fileprivate struct BoundaryEntry {
        let offset: UInt64
        let time: ExactMediaTime
    }

    fileprivate enum Mutation {
        case startVideo
        case advanceVideo(offset: UInt64, boundary: CMTime, entry: BoundaryEntry)
        case advanceAudio(
            rendition: AudioRenditionIdentity,
            nextBoundaryOffset: UInt64,
            audioOnlyEntry: BoundaryEntry?
        )
    }

    fileprivate struct Decision {
        let trackKind: SegmentedFMP4TrackKind
        let sequence: UInt64
        let flush: Bool
        let mutation: Mutation?
    }

    private struct InspectionState {
        var videoStarted: Bool
        var videoBoundary: CMTime
        var videoOffset: UInt64
        var audioStates: [AudioRenditionIdentity: AudioState]
        var boundaryWindow: [BoundaryEntry]
        var revision: UInt64
    }

    private static let audioOnlyBoundaryWindowCapacity = 4
    /// 音视频冷启动允许音频在已确认 origin 后最多落后 15 秒；TS 的包顺序会让
    /// 4K 视频边界先成批到达，因此还需保留起点边界。窗口仍是固定上限，不能
    /// 因直播时长增长。
    private static let audioVideoBoundaryWindowCapacity = 16
    private static let renditionCapacity = 3

    private let lock = NSLock()
    let session = SegmentBoundarySession()
    private let epochStart: CMTime
    private let videoMode: SegmentVideoBoundaryMode?
    private let minimumPassthroughInterval: CMTime
    private let maximumPassthroughInterval: CMTime
    private let sequenceAllocator: SegmentSequenceAllocator
    private var videoStarted = false
    private var videoBoundary: CMTime
    private var videoOffset: UInt64 = 0
    private var audioStates: [AudioRenditionIdentity: AudioState] = [:]
    private var boundaryWindow: [BoundaryEntry]
    private var revision: UInt64 = 0
    private var reservedMutation: UUID?
    private var inspectionState: InspectionState
    private var audioBoundaryAdvanceSink: (@Sendable () -> Void)?

    init(
        mode: SegmentBoundaryMode,
        sequenceAllocator: SegmentSequenceAllocator = SegmentSequenceAllocator()
    ) throws {
        let start: CMTime
        let selectedVideoMode: SegmentVideoBoundaryMode?
        let minInterval: CMTime
        let maxInterval: CMTime
        switch mode {
        case let .audioVideo(
            epochStart,
            videoMode,
            minimumInterval,
            maximumInterval
        ):
            start = epochStart
            selectedVideoMode = videoMode
            minInterval = minimumInterval ?? CMTime(value: 1, timescale: 1)
            maxInterval = maximumInterval ?? CMTime(value: 2, timescale: 1)
        case let .audioOnly(epochStart):
            start = epochStart
            selectedVideoMode = nil
            minInterval = CMTime(value: 1, timescale: 1)
            maxInterval = CMTime(value: 2, timescale: 1)
        }
        minimumPassthroughInterval = minInterval
        maximumPassthroughInterval = maxInterval
        guard start.isNumeric, start.epoch == 0, start.timescale > 0,
              minInterval.isNumeric, maxInterval.isNumeric,
              CMTimeCompare(minInterval, .zero) > 0,
              CMTimeCompare(minInterval, maxInterval) <= 0 else {
            throw SegmentBoundaryFailure.invalidTime
        }
        epochStart = start
        videoMode = selectedVideoMode
        self.sequenceAllocator = sequenceAllocator
        videoBoundary = start
        let initialBoundary = BoundaryEntry(offset: 0, time: try ExactMediaTime(start))
        boundaryWindow = [initialBoundary]
        inspectionState = InspectionState(
            videoStarted: false,
            videoBoundary: start,
            videoOffset: 0,
            audioStates: [:],
            boundaryWindow: [initialBoundary],
            revision: 0
        )
    }

    /// 仅观察由成功系统 append 提交的正式共同边界。
    var commonBoundaries: [ExactMediaTime] {
        lock.withLock { boundaryWindow.map(\.time) }
    }

    var usage: SegmentBoundaryUsage {
        lock.withLock {
            SegmentBoundaryUsage(
                commonBoundarySlotCount: boundaryWindow.count,
                renditionCount: audioStates.count,
                lastLogicalSequence: (try? sequenceAllocator.value(offset: videoOffset)) ?? UInt64.max
            )
        }
    }

    /// 只供边界算法 inspection 观察，不能代表正式 writer session 已提交。
    var inspectionCommonBoundaries: [ExactMediaTime] {
        lock.withLock { inspectionState.boundaryWindow.map(\.time) }
    }

    var inspectionUsage: SegmentBoundaryUsage {
        lock.withLock {
            SegmentBoundaryUsage(
                commonBoundarySlotCount: inspectionState.boundaryWindow.count,
                renditionCount: inspectionState.audioStates.count,
                lastLogicalSequence: (
                    try? sequenceAllocator.value(offset: inspectionState.videoOffset)
                ) ?? UInt64.max
            )
        }
    }

    var interlacedVideoLeadHasCapacity: Bool {
        lock.withLock {
            HLSInterlacedVideoLeadPolicy.canAdvance(
                videoOffset: videoOffset,
                audioNextBoundaryOffsets: audioStates.values.map(\.nextBoundaryOffset))
        }
    }

    func installAudioBoundaryAdvanceSink(_ sink: @escaping @Sendable () -> Void) {
        lock.withLock { audioBoundaryAdvanceSink = sink }
    }

    func registerAudioRendition(
        _ rendition: AudioRenditionIdentity,
        accessUnit: SegmentAudioAccessUnitKind,
        firstPhysicalStart: CMTime? = nil,
        startTrimSamples: Int64 = 0,
        firstEffectiveStart: CMTime
    ) throws {
        try lock.withLock {
            guard audioStates[rendition] == nil else { throw SegmentBoundaryFailure.duplicateRendition }
            let facts = accessUnit.sampleRateAndCount
            guard facts.rate > 0, facts.count > 0,
                  firstEffectiveStart.isNumeric,
                  CMTimeCompare(firstEffectiveStart, epochStart) == 0 else {
                throw SegmentBoundaryFailure.firstEffectiveStartMismatch
            }
            if case .eac3Aggregated = accessUnit, facts.count != 1_536 {
                throw SegmentBoundaryFailure.incompleteEAC3AccessUnit
            }
            guard audioStates.count < Self.renditionCapacity else {
                throw SegmentBoundaryFailure.renditionCapacityExceeded
            }
            if let firstPhysicalStart {
                guard startTrimSamples >= 0 else {
                    throw SegmentBoundaryFailure.firstEffectiveStartMismatch
                }
                let expected = CMTimeAdd(
                    firstPhysicalStart,
                    CMTime(value: startTrimSamples, timescale: facts.rate)
                )
                guard CMTimeCompare(expected, firstEffectiveStart) == 0 else {
                    throw SegmentBoundaryFailure.firstEffectiveStartMismatch
                }
            } else if startTrimSamples != 0 {
                throw SegmentBoundaryFailure.firstEffectiveStartMismatch
            }
            let state = AudioState(kind: accessUnit, nextBoundaryOffset: 1)
            audioStates[rendition] = state
            inspectionState.audioStates[rendition] = state
        }
    }

    func inspectVideoBoundary(
        at presentationStart: CMTime,
        isIDR: Bool
    ) throws -> SegmentBoundaryInspection {
        try lock.withLock {
            try withIsolatedInspectionState {
                let decision = try decideVideo(at: presentationStart, isIDR: isIDR)
                try applyInspectionMutation(decision.mutation)
                return SegmentBoundaryInspection(
                    logicalSequence: decision.sequence,
                    requiresFlushBeforeAppend: decision.flush
                )
            }
        }
    }

    func inspectAudioBoundary(
        rendition: AudioRenditionIdentity,
        at presentationStart: CMTime
    ) throws -> SegmentBoundaryInspection {
        try lock.withLock {
            try withIsolatedInspectionState {
                let decision = try decideAudio(rendition: rendition, at: presentationStart)
                try applyInspectionMutation(decision.mutation)
                return SegmentBoundaryInspection(
                    logicalSequence: decision.sequence,
                    requiresFlushBeforeAppend: decision.flush
                )
            }
        }
    }

    func issueVideoAppend(
        for output: HLSVideoEncodedOutput,
        writerBinding: FMP4WriterBinding
    ) throws -> SegmentBoundaryAppendTicket {
        let identity = try Self.videoIdentity(output)
        let isIDR = Self.isSync(output.sampleBuffer)
        let start = CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer)
        return try lock.withLock {
            let decision = try decideVideo(at: start, isIDR: isIDR)
            return try makeTicket(decision, binding: writerBinding, sampleIdentity: identity)
        }
    }

    func issueRemuxVideoAppend(
        for submission: HLSVideoRemuxSubmission,
        writerBinding: FMP4WriterBinding
    ) throws -> SegmentBoundaryAppendTicket {
        let attempt: HLSVideoRemuxWriterAttempt
        if let current = try? submission.currentWriterAttempt(binding: writerBinding) {
            attempt = current
        } else {
            attempt = try submission.claimWriterAttempt(binding: writerBinding)
        }
        return try issueRemuxVideoAppend(for: attempt)
    }

    func issueRemuxVideoAppend(
        for attempt: HLSVideoRemuxWriterAttempt
    ) throws -> SegmentBoundaryAppendTicket {
        let identity = try Self.remuxVideoIdentity(attempt)
        return try lock.withLock {
            let decision = try decideVideo(
                at: attempt.presentationTimeStamp.cmTime,
                isIDR: attempt.isIDR
            )
            return try makeTicket(
                decision, binding: attempt.writerBinding, sampleIdentity: identity)
        }
    }

    func issueAACAppend(
        for sampleBuffer: CMSampleBuffer,
        rendition: AudioRenditionIdentity,
        writerBinding: FMP4WriterBinding
    ) throws -> SegmentBoundaryAppendTicket {
        let identity = try Self.aacIdentity(sampleBuffer)
        return try lock.withLock {
            let decision = try decideAudio(
                rendition: rendition,
                at: CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            )
            guard decision.trackKind == .aac else { throw SegmentBoundaryFailure.ticketMismatch }
            guard rendition == writerBinding.renditionIdentity else {
                throw SegmentBoundaryFailure.ticketMismatch
            }
            return try makeTicket(decision, binding: writerBinding, sampleIdentity: identity)
        }
    }

    /// 在正式状态的临时副本上预演整批 AAC，供 writer 在任何 append 前判定 rollover。
    func previewAACAppends(
        for sampleBuffers: [CMSampleBuffer],
        rendition: AudioRenditionIdentity,
        writerBinding: FMP4WriterBinding
    ) throws -> [SegmentBoundaryInspection] {
        try lock.withLock {
            guard reservedMutation == nil,
                  rendition == writerBinding.renditionIdentity else {
                throw SegmentBoundaryFailure.ticketMismatch
            }
            let formal = InspectionState(
                videoStarted: videoStarted,
                videoBoundary: videoBoundary,
                videoOffset: videoOffset,
                audioStates: audioStates,
                boundaryWindow: boundaryWindow,
                revision: revision
            )
            defer {
                videoStarted = formal.videoStarted
                videoBoundary = formal.videoBoundary
                videoOffset = formal.videoOffset
                audioStates = formal.audioStates
                boundaryWindow = formal.boundaryWindow
                revision = formal.revision
                reservedMutation = nil
            }
            return try sampleBuffers.map {
                let decision = try decideAudio(
                    rendition: rendition,
                    at: CMSampleBufferGetOutputPresentationTimeStamp($0)
                )
                guard decision.trackKind == .aac else {
                    throw SegmentBoundaryFailure.ticketMismatch
                }
                try applyInspectionMutation(decision.mutation)
                return SegmentBoundaryInspection(
                    logicalSequence: decision.sequence,
                    requiresFlushBeforeAppend: decision.flush
                )
            }
        }
    }

    func issueCompressedAudioAppend(
        for accessUnit: CompressedAudioAccessUnit,
        writerBinding: FMP4WriterBinding
    ) throws -> SegmentBoundaryAppendTicket {
        let identity = try Self.compressedIdentity(accessUnit)
        return try lock.withLock {
            let decision = try decideAudio(
                rendition: writerBinding.renditionIdentity,
                at: accessUnit.presentationStart
            )
            return try makeTicket(decision, binding: writerBinding, sampleIdentity: identity)
        }
    }

    static func videoIdentity(
        _ output: HLSVideoEncodedOutput
    ) throws -> SegmentBoundarySampleIdentity {
        guard output.hardwareProof.generation == output.sourceIdentity.generation,
              let format = CMSampleBufferGetFormatDescription(output.sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(output.sampleBuffer) else {
            throw SegmentBoundaryFailure.ticketMismatch
        }
        let bytes = try payload(block)
        return .video(
            source: output.sourceIdentity,
            sample: ObjectIdentifier(output.sampleBuffer),
            presentationStart: try ExactMediaTime(
                CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer)
            ),
            format: ObjectIdentifier(format),
            hardwareSession: output.hardwareProof.sessionID,
            isIDR: isSync(output.sampleBuffer),
            backing: ObjectIdentifier(block),
            digest: Data(SHA256.hash(data: bytes))
        )
    }

    static func remuxVideoIdentity(
        _ submission: HLSVideoRemuxSubmission
    ) throws -> SegmentBoundarySampleIdentity {
        let attempt = try submission.currentWriterAttempt(binding: submission.writerBinding)
        return try remuxVideoIdentity(attempt)
    }

    static func remuxVideoIdentity(
        _ attempt: HLSVideoRemuxWriterAttempt
    ) throws -> SegmentBoundarySampleIdentity {
        guard try attempt.validatesFrozenIdentity() else {
            throw SegmentBoundaryFailure.ticketMismatch
        }
        return .videoRemux(
            source: attempt.admission.source.identity,
            sampleEntry: attempt.admission.sampleEntry,
            parameterSetIdentity: attempt.admission.parameterSetIdentity,
            formatIdentity: attempt.admission.formatIdentity,
            submission: attempt.pendingIdentity,
            attempt: attempt.attemptIdentity,
            presentationStart: attempt.presentationTimeStamp,
            decodeStart: attempt.decodeTimeStamp,
            duration: attempt.duration,
            formatAuthority: attempt.remuxFormatAuthorityIdentity,
            isIDR: attempt.isIDR,
            digest: attempt.outputSHA256
        )
    }

    static func aacIdentity(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> SegmentBoundarySampleIdentity {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw SegmentBoundaryFailure.ticketMismatch
        }
        let bytes = try payload(block)
        return .aac(
            sample: ObjectIdentifier(sampleBuffer),
            presentationStart: try ExactMediaTime(
                CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            ),
            format: ObjectIdentifier(format),
            digest: Data(SHA256.hash(data: bytes))
        )
    }

    static func compressedIdentity(
        _ accessUnit: CompressedAudioAccessUnit
    ) throws -> SegmentBoundarySampleIdentity {
        .compressed(
            codec: accessUnit.codec,
            sampleRate: accessUnit.sampleRate,
            channelCount: accessUnit.channelCount,
            sampleCount: accessUnit.sampleCount,
            formatConfiguration: accessUnit.formatConfiguration,
            admission: accessUnit.admissionIdentity,
            payload: accessUnit.payloadIdentity,
            range: accessUnit.payloadRange,
            digest: accessUnit.payloadDigest,
            presentationStart: try ExactMediaTime(accessUnit.presentationStart)
        )
    }

    private func makeTicket(
        _ decision: Decision,
        binding: FMP4WriterBinding,
        sampleIdentity: SegmentBoundarySampleIdentity
    ) throws -> SegmentBoundaryAppendTicket {
        guard reservedMutation == nil else { throw SegmentBoundaryFailure.ticketMismatch }
        let transactionIdentity = UUID()
        if decision.mutation != nil { reservedMutation = transactionIdentity }
        let transaction = SegmentBoundaryTicketTransaction(
            coordinator: self,
            identity: transactionIdentity,
            expectedRevision: revision,
            decision: decision
        )
        let offset = decision.sequence - sequenceAllocator.initialValue
        let start: ExactMediaTime
        if case let .advanceVideo(_, _, entry) = decision.mutation { start = entry.time }
        else { start = try ExactMediaTime(boundary(at: offset)) }
        let audio = audioStates[binding.renditionIdentity]?.kind.sampleRateAndCount
        let fact = SegmentCommittedBoundary(session: session, binding: binding, sequence: decision.sequence,
            start: start, epochStart: try ExactMediaTime(epochStart),
            accessUnitDuration: decision.trackKind == .video ? nil : audio.map { .init(value: Int64($0.count), timescale: $0.rate) })
        return SegmentBoundaryAppendTicket(
            writerBinding: binding,
            trackKind: decision.trackKind,
            logicalSequence: decision.sequence,
            requiresFlushBeforeAppend: decision.flush,
            sampleIdentity: sampleIdentity,
            session: session,
            transaction: transaction,
            boundary: fact
        )
    }

    private func decideVideo(at presentationStart: CMTime, isIDR: Bool) throws -> Decision {
        guard let videoMode,
              presentationStart.isNumeric,
              presentationStart.epoch == 0 else {
            throw SegmentBoundaryFailure.invalidTime
        }
        if !videoStarted {
            guard isIDR, CMTimeCompare(presentationStart, epochStart) == 0 else {
                throw SegmentBoundaryFailure.invalidTime
            }
            return Decision(
                trackKind: .video,
                sequence: try sequenceAllocator.value(offset: 0),
                flush: false,
                mutation: .startVideo
            )
        }

        let elapsed = CMTimeSubtract(presentationStart, videoBoundary)
        let oneSecond = CMTime(value: 1, timescale: 1)
        var startsNewSegment = false
        switch videoMode {
        case .passthrough:
            guard CMTimeCompare(elapsed, maximumPassthroughInterval) <= 0 else {
                throw SegmentBoundaryFailure.videoBoundaryExceeded
            }
            startsNewSegment = isIDR
                && CMTimeCompare(elapsed, minimumPassthroughInterval) >= 0
        case .reencodedClosedGOP:
            let compared = CMTimeCompare(elapsed, oneSecond)
            if compared < 0 {
                guard !isIDR else { throw SegmentBoundaryFailure.videoBoundaryExceeded }
            } else if compared == 0 {
                guard isIDR else { throw SegmentBoundaryFailure.videoBoundaryExceeded }
                startsNewSegment = true
            } else {
                throw SegmentBoundaryFailure.videoBoundaryExceeded
            }
        }
        if startsNewSegment {
            let next = videoOffset.addingReportingOverflow(1)
            guard !next.overflow else { throw SegmentBoundaryFailure.arithmeticOverflow }
            let entry = BoundaryEntry(
                offset: next.partialValue,
                time: try ExactMediaTime(presentationStart)
            )
            return Decision(
                trackKind: .video,
                sequence: try sequenceAllocator.value(offset: next.partialValue),
                flush: true,
                mutation: .advanceVideo(
                    offset: next.partialValue,
                    boundary: presentationStart,
                    entry: entry
                )
            )
        }
        return Decision(
            trackKind: .video,
            sequence: try sequenceAllocator.value(offset: videoOffset),
            flush: false,
            mutation: nil
        )
    }

    private func decideAudio(
        rendition: AudioRenditionIdentity,
        at presentationStart: CMTime
    ) throws -> Decision {
        guard let state = audioStates[rendition] else {
            throw SegmentBoundaryFailure.unknownRendition
        }
        guard presentationStart.isNumeric, presentationStart.epoch == 0 else {
            throw SegmentBoundaryFailure.invalidTime
        }
        let facts = state.kind.sampleRateAndCount
        let boundary = try boundary(at: state.nextBoundaryOffset)
        let previousOffset = state.nextBoundaryOffset - 1
        if boundary.isPositiveInfinity || CMTimeCompare(presentationStart, boundary) < 0 {
            return Decision(
                trackKind: state.kind.trackKind,
                sequence: try sequenceAllocator.value(offset: previousOffset),
                flush: false,
                mutation: nil
            )
        }
        let exclusiveEnd = CMTimeAdd(
            boundary,
            CMTime(value: Int64(facts.count), timescale: facts.rate)
        )
        guard CMTimeCompare(presentationStart, exclusiveEnd) < 0 else {
            throw SegmentBoundaryFailure.audioBoundaryExceeded
        }
        let audioOnlyEntry: BoundaryEntry? = if videoMode == nil {
            BoundaryEntry(
                offset: state.nextBoundaryOffset,
                time: try ExactMediaTime(boundary)
            )
        } else { nil }
        let next = state.nextBoundaryOffset.addingReportingOverflow(1)
        guard !next.overflow else { throw SegmentBoundaryFailure.arithmeticOverflow }
        return Decision(
            trackKind: state.kind.trackKind,
            sequence: try sequenceAllocator.value(offset: state.nextBoundaryOffset),
            flush: true,
            mutation: .advanceAudio(
                rendition: rendition,
                nextBoundaryOffset: next.partialValue,
                audioOnlyEntry: audioOnlyEntry
            )
        )
    }

    fileprivate func accepts(_ transaction: SegmentBoundaryTicketTransaction) -> Bool {
        lock.withLock {
            transaction.coordinator === self
                && transaction.expectedRevision == revision
                && (transaction.decision.mutation == nil || reservedMutation == transaction.identity)
        }
    }

    fileprivate func commit(_ transaction: SegmentBoundaryTicketTransaction) -> Bool {
        var advanceSink: (@Sendable () -> Void)?
        let committed = lock.withLock {
            guard transaction.coordinator === self,
                  transaction.expectedRevision == revision,
                  transaction.decision.mutation == nil || reservedMutation == transaction.identity else {
                return false
            }
            guard let mutation = transaction.decision.mutation else { return true }
            let next = revision.addingReportingOverflow(1)
            guard !next.overflow else { return false }
            switch mutation {
            case .startVideo:
                videoStarted = true
            case let .advanceVideo(offset, boundary, entry):
                videoOffset = offset
                videoBoundary = boundary
                appendBoundary(entry)
            case let .advanceAudio(rendition, nextBoundaryOffset, audioOnlyEntry):
                guard var state = audioStates[rendition] else { return false }
                state.nextBoundaryOffset = nextBoundaryOffset
                audioStates[rendition] = state
                if let audioOnlyEntry {
                    videoOffset = max(videoOffset, audioOnlyEntry.offset)
                    appendBoundary(audioOnlyEntry)
                }
                advanceSink = audioBoundaryAdvanceSink
            }
            revision = next.partialValue
            reservedMutation = nil
            return true
        }
        if committed { advanceSink?() }
        return committed
    }

    fileprivate func abort(_ transaction: SegmentBoundaryTicketTransaction) {
        lock.withLock {
            if reservedMutation == transaction.identity { reservedMutation = nil }
        }
    }

    private func appendBoundary(_ entry: BoundaryEntry) {
        boundaryWindow.append(entry)
        let capacity = videoMode == nil
            ? Self.audioOnlyBoundaryWindowCapacity
            : Self.audioVideoBoundaryWindowCapacity
        if boundaryWindow.count > capacity {
            boundaryWindow.removeFirst(boundaryWindow.count - capacity)
        }
    }

    /// inspection 复用完全相同的算法，但在隔离副本中推进，退出时恢复正式状态。
    private func withIsolatedInspectionState<T>(_ body: () throws -> T) rethrows -> T {
        let formal = InspectionState(
            videoStarted: videoStarted,
            videoBoundary: videoBoundary,
            videoOffset: videoOffset,
            audioStates: audioStates,
            boundaryWindow: boundaryWindow,
            revision: revision
        )
        let formalReservation = reservedMutation
        videoStarted = inspectionState.videoStarted
        videoBoundary = inspectionState.videoBoundary
        videoOffset = inspectionState.videoOffset
        audioStates = inspectionState.audioStates
        boundaryWindow = inspectionState.boundaryWindow
        revision = inspectionState.revision
        reservedMutation = nil
        defer {
            inspectionState = InspectionState(
                videoStarted: videoStarted,
                videoBoundary: videoBoundary,
                videoOffset: videoOffset,
                audioStates: audioStates,
                boundaryWindow: boundaryWindow,
                revision: revision
            )
            videoStarted = formal.videoStarted
            videoBoundary = formal.videoBoundary
            videoOffset = formal.videoOffset
            audioStates = formal.audioStates
            boundaryWindow = formal.boundaryWindow
            revision = formal.revision
            reservedMutation = formalReservation
        }
        return try body()
    }

    private func applyInspectionMutation(_ mutation: Mutation?) throws {
        guard let mutation else { return }
        guard reservedMutation == nil else { throw SegmentBoundaryFailure.ticketMismatch }
        let next = revision.addingReportingOverflow(1)
        guard !next.overflow else { throw SegmentBoundaryFailure.arithmeticOverflow }
        switch mutation {
        case .startVideo:
            videoStarted = true
        case let .advanceVideo(offset, boundary, entry):
            videoOffset = offset
            videoBoundary = boundary
            appendBoundary(entry)
        case let .advanceAudio(rendition, nextBoundaryOffset, audioOnlyEntry):
            guard var state = audioStates[rendition] else {
                throw SegmentBoundaryFailure.unknownRendition
            }
            state.nextBoundaryOffset = nextBoundaryOffset
            audioStates[rendition] = state
            if let audioOnlyEntry {
                videoOffset = max(videoOffset, audioOnlyEntry.offset)
                appendBoundary(audioOnlyEntry)
            }
        }
        revision = next.partialValue
    }

    private static func payload(_ block: CMBlockBuffer) throws -> Data {
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: $0.baseAddress!
            )
        }
        guard status == noErr else { throw SegmentBoundaryFailure.ticketMismatch }
        return bytes
    }

    private func boundary(at offset: UInt64) throws -> CMTime {
        if videoMode != nil {
            if let entry = boundaryWindow.first(where: { $0.offset == offset }) {
                return entry.time.cmTime
            }
            if offset > videoOffset { return .positiveInfinity }
            throw SegmentBoundaryFailure.audioBoundaryExceeded
        }
        guard let seconds = Int64(exactly: offset) else {
            throw SegmentBoundaryFailure.arithmeticOverflow
        }
        return CMTimeAdd(epochStart, CMTime(value: seconds, timescale: 1))
    }

    private static func isSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let raw = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) else { return true }
        let attachments = raw as NSArray
        guard let first = attachments.firstObject as? NSDictionary else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
