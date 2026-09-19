// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Dispatch
import Foundation

typealias RawFFmpegDemuxReceiver = @Sendable (UnsafePointer<VPFFDemuxEvent>) -> Void
typealias RawFFmpegDemuxReceiverV2 = @Sendable (
    UnsafePointer<VPFFDemuxEvent>,
    UnsafePointer<VPFFDemuxEventExtras>?
) -> Void

enum FFmpegDemuxCreateResult: @unchecked Sendable {
    case success(any FFmpegDemuxHandle)
    case failure(Int32)
}

protocol FFmpegDemuxHandle: AnyObject, Sendable {
    func run() -> Int32
    func cancel()
    func destroy()
}

protocol FFmpegDemuxBridging: Sendable {
    func create(
        urlBytes: Data,
        timeoutUS: Int64,
        receiver: @escaping RawFFmpegDemuxReceiver
    ) -> FFmpegDemuxCreateResult
    func createV2(
        urlBytes: Data,
        timeoutUS: Int64,
        receiver: @escaping RawFFmpegDemuxReceiverV2
    ) -> FFmpegDemuxCreateResult
}

extension FFmpegDemuxBridging {
    func createV2(
        urlBytes: Data,
        timeoutUS: Int64,
        receiver: @escaping RawFFmpegDemuxReceiverV2
    ) -> FFmpegDemuxCreateResult {
        create(urlBytes: urlBytes, timeoutUS: timeoutUS) { event in
            receiver(event, nil)
        }
    }
}

final class FFmpegDemuxer: MediaDemuxing, AdmittedMediaDemuxing, @unchecked Sendable {
    static let doubleStartErrorCode: Int32 = -1_448_078_337
    static let malformedEventErrorCode: Int32 = -1_448_078_338
    static let oversizedValueErrorCode: Int32 = -1_448_078_339

    private static let maximumURLBytes = 64 * 1_024
    private let bridge: any FFmpegDemuxBridging
    private let state: DemuxSessionState
    private let ioQueue: DispatchQueue
    private let timeoutUS: Int64

    init(
        bridge: any FFmpegDemuxBridging = LiveFFmpegDemuxBridge(),
        executor: PlaybackSerialExecutor = PlaybackSerialExecutor(),
        capacity: Int = 256,
        maximumQueuedBytes: Int = 64 * 1_024 * 1_024,
        // A live HLS read can legitimately span a playlist target duration plus
        // a retry. Keep the interrupt deadline long enough for several 5-second
        // segments so transient playlist latency does not terminate playback.
        timeoutUS: Int64 = 30_000_000,
        ioQueue: DispatchQueue? = nil
    ) {
        self.bridge = bridge
        state = DemuxSessionState(
            executor: executor,
            capacity: max(1, capacity),
            maximumQueuedBytes: max(1, maximumQueuedBytes)
        )
        self.timeoutUS = timeoutUS
        self.ioQueue = ioQueue ?? DispatchQueue(
            label: "org.vplayer.playback.demux.io",
            qos: .userInitiated
        )
    }

    deinit {
        state.cancel()
    }

    var queueFullWaitNanoseconds: UInt64 { state.queueFullWaitNanoseconds }

    func start(url: URL, sink: @escaping @Sendable (DemuxEvent) -> Void) throws {
        try startValidated(url: url) { urlBytes in
            try state.begin(sink: sink)
            return urlBytes
        }
    }

    func start(
        url: URL,
        admission: any DemuxDataPlaneAdmitting,
        sink: @escaping @Sendable (AdmittedDemuxEvent) -> Void
    ) throws {
        try startValidated(url: url) { urlBytes in
            try state.begin(admission: admission, sink: sink)
            return urlBytes
        }
    }

    private func startValidated(
        url: URL,
        begin: (Data) throws -> Data
    ) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw PlaybackCoreError.unsupportedProtocol(scheme)
        }
        guard timeoutUS > 0 else {
            throw PlaybackCoreError.demuxOpen(Self.malformedEventErrorCode)
        }

        let urlBytes = Data(url.absoluteString.utf8)
        guard !urlBytes.isEmpty, urlBytes.count <= Self.maximumURLBytes else {
            throw PlaybackCoreError.demuxOpen(Self.oversizedValueErrorCode)
        }

        let admittedURLBytes = try begin(urlBytes)
        let receiver: RawFFmpegDemuxReceiverV2 = { [state] event, extras in
            state.receive(event, extras: extras)
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("demux_bridge_create")
        #endif
        switch bridge.createV2(
            urlBytes: admittedURLBytes,
            timeoutUS: timeoutUS,
            receiver: receiver
        ) {
        case let .failure(code):
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("demux_bridge_fail_\(code)")
            #endif
            state.failStart()
            throw PlaybackCoreError.demuxOpen(code)
        case let .success(handle):
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("demux_bridge_ok")
            #endif
            state.install(handle: handle)
            ioQueue.async { [state] in
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("demux_run_async")
                #endif
                let result = handle.run()
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("demux_run_ret_\(result)")
                #endif
                state.runReturned(handle: handle, result: result)
            }
        }
    }

    func cancel() {
        state.cancel()
    }
}

private struct QueuedDemuxEvent: Sendable {
    let event: DemuxEvent
    let byteCount: Int
    let admissionTail: DemuxAdmissionTail?
}

private final class DemuxSessionState: @unchecked Sendable {
    private static let drainBatchSize = 16

    private let condition = NSCondition()
    private let handleLock = NSLock()
    private let executor: PlaybackSerialExecutor
    private let maximumQueuedBytes: Int
    private var queue: BoundedMediaQueue<QueuedDemuxEvent>
    private var queuedBytes = 0
    // Guarded by `condition`, like every other counter here.
    private var queueFullWaitNanosecondsLocked: UInt64 = 0
    private var drainScheduled = false
    private var pendingTerminal: DemuxEvent?
    private var terminalDelivered = false
    private var cancelled = false
    private var started = false
    private var sink: (@Sendable (DemuxEvent) -> Void)?
    private var admittedSink: (@Sendable (AdmittedDemuxEvent) -> Void)?
    private var admission: (any DemuxDataPlaneAdmitting)?
    private var liveHandle: (any FFmpegDemuxHandle)?
    private var liveHandleID: ObjectIdentifier?

    init(executor: PlaybackSerialExecutor, capacity: Int, maximumQueuedBytes: Int) {
        self.executor = executor
        self.maximumQueuedBytes = maximumQueuedBytes
        queue = BoundedMediaQueue(capacity: capacity, overflow: .rejectNewest)
    }

    func begin(sink newSink: @escaping @Sendable (DemuxEvent) -> Void) throws {
        try begin(sink: newSink, admittedSink: nil, admission: nil)
    }

    func begin(
        admission: any DemuxDataPlaneAdmitting,
        sink newSink: @escaping @Sendable (AdmittedDemuxEvent) -> Void
    ) throws {
        try begin(sink: nil, admittedSink: newSink, admission: admission)
    }

    private func begin(
        sink newSink: (@Sendable (DemuxEvent) -> Void)?,
        admittedSink newAdmittedSink: (@Sendable (AdmittedDemuxEvent) -> Void)?,
        admission newAdmission: (any DemuxDataPlaneAdmitting)?
    ) throws {
        condition.lock()
        guard !started else {
            condition.unlock()
            throw PlaybackCoreError.demuxOpen(FFmpegDemuxer.doubleStartErrorCode)
        }
        started = true
        sink = newSink
        admittedSink = newAdmittedSink
        admission = newAdmission
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.unlock()
        if shouldSchedule { submitDrain() }
    }

    func failStart() {
        condition.lock()
        sink = nil
        admittedSink = nil
        terminalDelivered = true
        let admission = self.admission
        condition.broadcast()
        condition.unlock()
        admission?.cancel()
    }

    func install(handle: any FFmpegDemuxHandle) {
        condition.lock()
        handleLock.lock()
        liveHandle = handle
        liveHandleID = ObjectIdentifier(handle)
        if cancelled { handle.cancel() }
        handleLock.unlock()
        condition.unlock()
    }

    func runReturned(handle: any FFmpegDemuxHandle, result: Int32) {
        handleLock.lock()
        if liveHandleID == ObjectIdentifier(handle) {
            liveHandle = nil
            liveHandleID = nil
        }
        handle.destroy()
        handleLock.unlock()

        condition.lock()
        if pendingTerminal == nil, !terminalDelivered {
            if cancelled {
                pendingTerminal = .cancelled
            } else if result == 0 {
                pendingTerminal = .endOfStream
            } else {
                pendingTerminal = .failure(.demuxRead(result))
            }
        }
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.broadcast()
        condition.unlock()
        if shouldSchedule { submitDrain() }
    }

    func receive(
        _ rawEvent: UnsafePointer<VPFFDemuxEvent>,
        extras: UnsafePointer<VPFFDemuxEventExtras>?
    ) {
        let measurement: RawDemuxMeasurement
        do {
            measurement = try RawDemuxEventCopier.measure(rawEvent.pointee, extras: extras)
        } catch let error as RawDemuxCopyError {
            receiveCopyFailure(error)
            return
        } catch {
            receiveCopyFailure(.malformed)
            return
        }

        let admissionTail: DemuxAdmissionTail?
        if !measurement.isTerminal, let admission {
            switch admission.waitForAdmission(
                bytes: measurement.byteCount,
                applicationBytes: measurement.applicationChargeBytes
            ) {
            case let .accepted(lease):
                admissionTail = DemuxAdmissionTail(lease: lease)
            case .cancelled:
                cancel()
                return
            case .permanentlyRejected:
                receiveAdmissionFailure()
                return
            }
        } else {
            admissionTail = nil
        }

        let copied: CopiedDemuxEvent
        let mustCancelRun: Bool
        do {
            copied = try RawDemuxEventCopier.copy(
                rawEvent.pointee,
                extras: extras
            )
            mustCancelRun = false
        } catch let error as RawDemuxCopyError {
            let coreError: PlaybackCoreError
            switch error {
            case .malformed:
                coreError = .demuxRead(FFmpegDemuxer.malformedEventErrorCode)
            case .unsupportedVideo:
                coreError = .unsupportedVideoCodec
            case .unsupportedAudio:
                coreError = .unsupportedAudioCodec
            }
            copied = CopiedDemuxEvent(event: .failure(coreError), byteCount: 0)
            mustCancelRun = true
        } catch {
            copied = CopiedDemuxEvent(
                event: .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode)),
                byteCount: 0
            )
            mustCancelRun = true
        }

        condition.lock()
        guard pendingTerminal == nil, !terminalDelivered, !cancelled else {
            condition.unlock()
            return
        }

        if copied.event.isTerminal {
            pendingTerminal = copied.event
            if mustCancelRun { cancelLiveHandleLocked() }
            let shouldSchedule = scheduleDrainIfNeededLocked()
            condition.broadcast()
            condition.unlock()
            if shouldSchedule { submitDrain() }
            return
        }

        guard copied.byteCount <= maximumQueuedBytes else {
            pendingTerminal = .failure(.demuxRead(FFmpegDemuxer.oversizedValueErrorCode))
            cancelLiveHandleLocked()
            let shouldSchedule = scheduleDrainIfNeededLocked()
            condition.broadcast()
            condition.unlock()
            if shouldSchedule { submitDrain() }
            return
        }

        var waitStart: UInt64?
        while (queue.count == queue.capacity || queuedBytes > maximumQueuedBytes - copied.byteCount),
              pendingTerminal == nil,
              !terminalDelivered,
              !cancelled {
            if waitStart == nil { waitStart = DispatchTime.now().uptimeNanoseconds }
            condition.wait()
        }
        if let waitStart {
            queueFullWaitNanosecondsLocked &+= DispatchTime.now().uptimeNanoseconds &- waitStart
        }
        guard pendingTerminal == nil, !terminalDelivered, !cancelled else {
            condition.unlock()
            return
        }
        guard queue.push(QueuedDemuxEvent(
            event: copied.event,
            byteCount: copied.byteCount,
            admissionTail: admissionTail
        )) == nil else {
            pendingTerminal = .failure(.demuxRead(FFmpegDemuxer.oversizedValueErrorCode))
            cancelLiveHandleLocked()
            let shouldSchedule = scheduleDrainIfNeededLocked()
            condition.broadcast()
            condition.unlock()
            if shouldSchedule { submitDrain() }
            return
        }
        queuedBytes += copied.byteCount
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.unlock()
        if shouldSchedule { submitDrain() }
    }

    private func receiveCopyFailure(_ error: RawDemuxCopyError) {
        let coreError: PlaybackCoreError
        switch error {
        case .malformed:
            coreError = .demuxRead(FFmpegDemuxer.malformedEventErrorCode)
        case .unsupportedVideo:
            coreError = .unsupportedVideoCodec
        case .unsupportedAudio:
            coreError = .unsupportedAudioCodec
        }
        condition.lock()
        guard pendingTerminal == nil, !terminalDelivered, !cancelled else {
            condition.unlock()
            return
        }
        pendingTerminal = .failure(coreError)
        cancelLiveHandleLocked()
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.broadcast()
        condition.unlock()
        if shouldSchedule { submitDrain() }
    }

    private func receiveAdmissionFailure() {
        condition.lock()
        guard pendingTerminal == nil, !terminalDelivered, !cancelled else {
            condition.unlock()
            return
        }
        pendingTerminal = .failure(.demuxRead(FFmpegDemuxer.oversizedValueErrorCode))
        cancelLiveHandleLocked()
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.broadcast()
        condition.unlock()
        if shouldSchedule { submitDrain() }
    }

    var queueFullWaitNanoseconds: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return queueFullWaitNanosecondsLocked
    }

    func cancel() {
        condition.lock()
        guard pendingTerminal == nil, !terminalDelivered else {
            condition.unlock()
            return
        }
        cancelLiveHandleLocked()
        cancelled = true
        queue.removeAll(keepingCapacity: true)
        queuedBytes = 0
        pendingTerminal = .cancelled
        let admission = self.admission
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.broadcast()
        condition.unlock()
        admission?.cancel()
        if shouldSchedule { submitDrain() }
    }

    /// The condition must be held so the terminal winner and native cancellation are linearized.
    private func cancelLiveHandleLocked() {
        handleLock.lock()
        liveHandle?.cancel()
        handleLock.unlock()
    }

    private func scheduleDrainIfNeededLocked() -> Bool {
        guard !drainScheduled, sink != nil || admittedSink != nil,
              queue.count > 0 || pendingTerminal != nil else { return false }
        drainScheduled = true
        return true
    }

    private func submitDrain() {
        executor.submit { [self] in drain() }
    }

    private func drain() {
        var deliveredCount = 0
        while deliveredCount < Self.drainBatchSize {
            condition.lock()
            if let queued = queue.popFirst() {
                queuedBytes -= queued.byteCount
                let currentSink = sink
                let currentAdmittedSink = admittedSink
                condition.broadcast()
                condition.unlock()
                currentSink?(queued.event)
                currentAdmittedSink?(AdmittedDemuxEvent(
                    event: queued.event,
                    admissionTail: queued.admissionTail
                ))
                deliveredCount += 1
                continue
            }
            if let terminal = pendingTerminal {
                #if DEBUG
                PlaybackDiagnosticTracker.shared.set("demux_term")
                #endif
                pendingTerminal = nil
                terminalDelivered = true
                drainScheduled = false
                let currentSink = sink
                let currentAdmittedSink = admittedSink
                sink = nil
                admittedSink = nil
                condition.broadcast()
                condition.unlock()
                currentSink?(terminal)
                currentAdmittedSink?(AdmittedDemuxEvent(
                    event: terminal,
                    admissionTail: nil
                ))
                return
            }
            drainScheduled = false
            condition.unlock()
            return
        }

        condition.lock()
        drainScheduled = false
        let shouldReschedule = scheduleDrainIfNeededLocked()
        condition.unlock()
        if shouldReschedule { submitDrain() }
    }
}

private struct CopiedDemuxEvent: Sendable {
    let event: DemuxEvent
    let byteCount: Int
}

private struct RawDemuxMeasurement {
    let byteCount: Int
    let backingCount: Int
    let isTerminal: Bool

    var applicationChargeBytes: Int {
        // event/envelope/tail/ledger reservation 的保守固定峰值，加每个 NSData backing 元数据。
        byteCount + 1_024 + backingCount * 128
    }
}

private enum RawDemuxCopyError: Error {
    case malformed
    case unsupportedVideo
    case unsupportedAudio
}

// 这些 C 宏包含 UINT64_C，Swift Clang importer 不会导入；这里保持逐位同值。
private let VPFF_TRACK_EXTRAS_HAS_ROLE: UInt64 = 1 << 0
private let VPFF_TRACK_EXTRAS_HAS_LANGUAGE: UInt64 = 1 << 1
private let VPFF_TRACK_EXTRAS_HAS_SERVICE: UInt64 = 1 << 2
private let VPFF_TRACK_EXTRAS_HAS_DISPOSITIONS: UInt64 = 1 << 3
private let VPFF_TRACK_EXTRAS_HAS_SAMPLE_ASPECT_RATIO: UInt64 = 1 << 4
private let VPFF_TRACK_EXTRAS_HAS_COLOR_RANGE: UInt64 = 1 << 5
private let VPFF_TRACK_EXTRAS_HAS_COLOR_PRIMARIES: UInt64 = 1 << 6
private let VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER: UInt64 = 1 << 7
private let VPFF_TRACK_EXTRAS_HAS_COLOR_MATRIX: UInt64 = 1 << 8
private let VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION: UInt64 = 1 << 9
private let VPFF_TRACK_EXTRAS_HAS_MASTERING_DISPLAY: UInt64 = 1 << 10
private let VPFF_TRACK_EXTRAS_HAS_CONTENT_LIGHT_LEVEL: UInt64 = 1 << 11
private let VPFF_TRACK_EXTRAS_HAS_SERVICE_CONFLICT: UInt64 = 1 << 12

private enum RawDemuxEventCopier {
    /// C ABI `VPFF_TRACK_EXTRAS_HAS_ROLE_CONFLICT` 当前由桥接宏定义；Swift
    /// importer 不导入新增宏时仍只在这里保留同一个定长 ABI 位号。
    private static let roleConflictPresenceMask = UInt64(1) << 13
    private static let maximumExtradataBytes = 1 * 1_024 * 1_024
    private static let maximumPacketBytes = 64 * 1_024 * 1_024

    static func measure(
        _ raw: VPFFDemuxEvent,
        extras: UnsafePointer<VPFFDemuxEventExtras>?
    ) throws -> RawDemuxMeasurement {
        guard isKnownStage(raw.error_stage), isBoolean(raw.has_program_id) else {
            throw RawDemuxCopyError.malformed
        }
        let byteCount: Int
        let backingCount: Int
        let isTerminal: Bool
        switch raw.kind {
        case VPFF_EVENT_TRACKS, VPFF_EVENT_DISCONTINUITY:
            guard raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE,
                  isBoolean(raw.video.present), isBoolean(raw.audio.present) else {
                throw RawDemuxCopyError.malformed
            }
            let videoBytes = try measuredBytes(
                raw.video.extradata,
                size: raw.video.extradata_size,
                maximum: maximumExtradataBytes
            )
            let audioBytes = try measuredBytes(
                raw.audio.extradata,
                size: raw.audio.extradata_size,
                maximum: maximumExtradataBytes
            )
            guard raw.video.present == 1 || videoBytes == 0,
                  raw.audio.present == 1 || audioBytes == 0 else {
                throw RawDemuxCopyError.malformed
            }
            let total = videoBytes.addingReportingOverflow(audioBytes)
            guard !total.overflow else { throw RawDemuxCopyError.malformed }
            byteCount = total.partialValue
            backingCount = (videoBytes > 0 ? 1 : 0) + (audioBytes > 0 ? 1 : 0)
            isTerminal = false
        case VPFF_EVENT_PACKET:
            guard extras == nil,
                  raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            byteCount = try measuredBytes(
                raw.packet.data,
                size: raw.packet.size,
                maximum: maximumPacketBytes
            )
            backingCount = byteCount > 0 ? 1 : 0
            isTerminal = false
        case VPFF_EVENT_END, VPFF_EVENT_CANCELLED, VPFF_EVENT_ERROR:
            byteCount = 0
            backingCount = 0
            isTerminal = true
        default:
            throw RawDemuxCopyError.malformed
        }
        let backingCharge = backingCount.multipliedReportingOverflow(by: 128)
        let fixedCharge = byteCount.addingReportingOverflow(1_024)
        guard !backingCharge.overflow, !fixedCharge.overflow,
              !fixedCharge.partialValue.addingReportingOverflow(
                backingCharge.partialValue
              ).overflow else {
            throw RawDemuxCopyError.malformed
        }
        return RawDemuxMeasurement(
            byteCount: byteCount,
            backingCount: backingCount,
            isTerminal: isTerminal
        )
    }

    static func copy(
        _ raw: VPFFDemuxEvent,
        extras: UnsafePointer<VPFFDemuxEventExtras>?
    ) throws -> CopiedDemuxEvent {
        guard isKnownStage(raw.error_stage), isBoolean(raw.has_program_id) else {
            throw RawDemuxCopyError.malformed
        }
        switch raw.kind {
        case VPFF_EVENT_TRACKS, VPFF_EVENT_DISCONTINUITY:
            guard raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            let copiedExtras = try copyExtras(
                extras,
                hasVideo: raw.video.present == 1,
                hasAudio: raw.audio.present == 1
            )
            let video = try copyTrack(
                raw.video,
                extras: copiedExtras.video,
                mediaType: .video
            )
            let audio = try copyTrack(
                raw.audio,
                extras: copiedExtras.audio,
                mediaType: .audio
            )
            guard video.video != nil || audio.audio != nil else {
                throw RawDemuxCopyError.malformed
            }
            let tracks = DemuxTrackSet(
                selectedProgramID: raw.has_program_id == 1 ? raw.selected_program_id : nil,
                video: video.video,
                audio: audio.audio,
                audioPrimaryEvidence: try copyAudioPrimaryEvidence(
                    copiedExtras.audioPrimaryEvidence, selectedProgramID: raw.has_program_id == 1 ? raw.selected_program_id : nil,
                    selectedAudio: audio.audio
                )
            )
            let event: DemuxEvent
            if raw.kind == VPFF_EVENT_TRACKS {
                event = .tracks(tracks)
            } else {
                let reason: DemuxDiscontinuityReason
                switch raw.discontinuity_reason {
                case VPFF_DISCONTINUITY_FORMAT_CHANGE:
                    reason = .formatChange
                case VPFF_DISCONTINUITY_TIMELINE_RESET:
                    reason = .timelineReset
                default:
                    throw RawDemuxCopyError.malformed
                }
                event = .discontinuity(tracks, reason: reason)
            }
            return CopiedDemuxEvent(event: event, byteCount: video.byteCount + audio.byteCount)
        case VPFF_EVENT_PACKET:
            guard extras == nil,
                  raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            let packet = try copyPacket(raw.packet)
            return CopiedDemuxEvent(event: .packet(packet.0), byteCount: packet.1)
        case VPFF_EVENT_END:
            guard extras == nil,
                  raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            return CopiedDemuxEvent(event: .endOfStream, byteCount: 0)
        case VPFF_EVENT_CANCELLED:
            guard extras == nil,
                  raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            return CopiedDemuxEvent(event: .cancelled, byteCount: 0)
        case VPFF_EVENT_ERROR:
            guard extras == nil, raw.error_stage != VPFF_DEMUX_STAGE_NONE else {
                throw RawDemuxCopyError.malformed
            }
            return CopiedDemuxEvent(event: .failure(try mapError(raw)), byteCount: 0)
        default:
            throw RawDemuxCopyError.malformed
        }
    }

    private enum TrackMediaType { case video, audio }

    private static func copyAudioPrimaryEvidence(
        _ raw: VPFFAudioPrimaryEvidenceV1?,
        selectedProgramID: Int32?,
        selectedAudio: AudioTrackDescriptor?
    ) throws -> DemuxTrackSet.AudioPrimaryEvidence? {
        guard let raw else { return nil }
        guard let selectedAudio,
              raw.version == 1,
              raw.selected_stream_index == selectedAudio.streamIndex,
              raw.audio_stream_count > 0,
              raw.default_audio_stream_count <= raw.audio_stream_count,
              raw.explicit_main_stream_count <= raw.audio_stream_count,
              raw.unclassifiable_role_stream_count <= raw.audio_stream_count else {
            throw RawDemuxCopyError.malformed
        }
        let scope: DemuxTrackSet.AudioPrimaryScope
        switch raw.scope {
        case VPFF_AUDIO_PRIMARY_SCOPE_PROGRAM:
            guard let selectedProgramID,
                  raw.program_index >= 0, raw.program_id == selectedProgramID else {
                throw RawDemuxCopyError.malformed
            }
            scope = .avProgram(index: raw.program_index, id: selectedProgramID)
        case VPFF_AUDIO_PRIMARY_SCOPE_FORMAT_STREAM_TABLE:
            guard selectedProgramID == nil,
                  raw.program_index == -1 else { throw RawDemuxCopyError.malformed }
            scope = .formatStreamTableWithoutProgram
        default:
            throw RawDemuxCopyError.malformed
        }
        let basis: DemuxTrackSet.AudioPrimaryBasis?
        switch raw.primary_basis {
        case VPFF_AUDIO_PRIMARY_NONE: basis = nil
        case VPFF_AUDIO_PRIMARY_EXPLICIT_MAIN: basis = .explicitMain
        case VPFF_AUDIO_PRIMARY_SOLE_AUDIO: basis = .soleAudio
        case VPFF_AUDIO_PRIMARY_UNIQUE_DEFAULT: basis = .uniqueDefault
        default: throw RawDemuxCopyError.malformed
        }
        return .init(
            scope: scope,
            selectedStreamIndex: raw.selected_stream_index,
            audioStreamCount: raw.audio_stream_count,
            defaultAudioStreamCount: raw.default_audio_stream_count,
            explicitMainStreamCount: raw.explicit_main_stream_count,
            unclassifiableRoleStreamCount: raw.unclassifiable_role_stream_count,
            primaryBasis: basis
        )
    }
    private struct CopiedTrack {
        let video: VideoTrackDescriptor?
        let audio: AudioTrackDescriptor?
        let byteCount: Int
    }

    private struct CopiedExtras {
        let video: VPFFTrackExtrasV1?
        let audio: VPFFTrackExtrasV1?
        let audioPrimaryEvidence: VPFFAudioPrimaryEvidenceV1?
    }

    private static func copyTrack(
        _ raw: VPFFTrack,
        extras: VPFFTrackExtrasV1?,
        mediaType: TrackMediaType
    ) throws -> CopiedTrack {
        guard isBoolean(raw.present), isBoolean(raw.has_channel_layout_mask) else {
            throw RawDemuxCopyError.malformed
        }
        guard raw.present == 1 else {
            guard extras == nil else { throw RawDemuxCopyError.malformed }
            guard try copyBytes(
                raw.extradata,
                size: raw.extradata_size,
                maximum: maximumExtradataBytes
            ).isEmpty else {
                throw RawDemuxCopyError.malformed
            }
            return CopiedTrack(video: nil, audio: nil, byteCount: 0)
        }
        guard raw.stream_index >= 0,
              let rational = MediaRational(num: raw.time_base_num, den: raw.time_base_den) else {
            throw RawDemuxCopyError.malformed
        }
        let extradata = try copyBytes(
            raw.extradata,
            size: raw.extradata_size,
            maximum: maximumExtradataBytes
        )
        let trackMetadata = try copyTrackMetadata(extras)
        switch mediaType {
        case .video:
            guard raw.width > 0, raw.height > 0, raw.video_delay >= 0 else {
                throw RawDemuxCopyError.malformed
            }
            guard let fieldOrder = codedFieldOrder(raw.field_order) else {
                throw RawDemuxCopyError.malformed
            }
            guard let codec = videoCodec(raw.codec) else {
                if raw.codec == VPFF_CODEC_UNSUPPORTED {
                    throw RawDemuxCopyError.unsupportedVideo
                }
                throw RawDemuxCopyError.malformed
            }
            return CopiedTrack(
                video: VideoTrackDescriptor(
                    streamIndex: raw.stream_index,
                    codec: codec,
                    timeBase: rational,
                    width: raw.width,
                    height: raw.height,
                    videoDelay: raw.video_delay,
                    extradata: extradata,
                    frameRate: MediaRational(
                        num: raw.frame_rate_num,
                        den: raw.frame_rate_den
                    ),
                    fieldOrder: fieldOrder,
                    metadata: trackMetadata,
                    videoMetadata: try copyVideoMetadata(extras)
                ),
                audio: nil,
                byteCount: extradata.count
            )
        case .audio:
            guard let codec = audioCodec(raw.codec) else {
                if raw.codec == VPFF_CODEC_UNSUPPORTED {
                    throw RawDemuxCopyError.unsupportedAudio
                }
                throw RawDemuxCopyError.malformed
            }
            guard raw.sample_rate > 0, raw.channel_count > 0 else {
                throw RawDemuxCopyError.malformed
            }
            let mask: UInt64?
            switch raw.channel_order {
            case VPFF_CHANNEL_ORDER_UNSPECIFIED:
                guard raw.has_channel_layout_mask == 0 else { throw RawDemuxCopyError.malformed }
                mask = nil
            case VPFF_CHANNEL_ORDER_NATIVE:
                guard raw.has_channel_layout_mask == 1,
                      raw.channel_layout_mask.nonzeroBitCount == Int(raw.channel_count) else {
                    throw RawDemuxCopyError.malformed
                }
                mask = raw.channel_layout_mask
            case VPFF_CHANNEL_ORDER_CUSTOM, VPFF_CHANNEL_ORDER_AMBISONIC:
                throw RawDemuxCopyError.unsupportedAudio
            default:
                throw RawDemuxCopyError.malformed
            }
            return CopiedTrack(
                video: nil,
                audio: AudioTrackDescriptor(
                    streamIndex: raw.stream_index,
                    codec: codec,
                    timeBase: rational,
                    sampleRate: raw.sample_rate,
                    channelLayout: AudioChannelLayout(
                        channelCount: raw.channel_count,
                        nativeMask: mask
                    ),
                    extradata: extradata,
                    metadata: trackMetadata
                ),
                byteCount: extradata.count
            )
        }
    }

    private static func copyExtras(
        _ pointer: UnsafePointer<VPFFDemuxEventExtras>?,
        hasVideo: Bool,
        hasAudio: Bool
    ) throws -> CopiedExtras {
        guard let pointer else { return CopiedExtras(video: nil, audio: nil, audioPrimaryEvidence: nil) }
        let header = pointer.pointee
        let expectedV1Size = UInt32(MemoryLayout<VPFFDemuxEventExtrasV1>.size)
        let expectedV2Size = UInt32(MemoryLayout<VPFFDemuxEventExtrasV2>.size)
        let videoOffset = UInt32(MemoryLayout<VPFFDemuxEventExtrasV1>.offset(of: \.video)!)
        let audioOffset = UInt32(MemoryLayout<VPFFDemuxEventExtrasV1>.offset(of: \.audio)!)
        guard (header.version == VPFF_DEMUX_EVENT_EXTRAS_VERSION_1 && header.size == expectedV1Size) ||
              (header.version == 2 && header.size == expectedV2Size),
              header.video_track_offset == (hasVideo ? videoOffset : 0),
              header.audio_track_offset == (hasAudio ? audioOffset : 0) else {
            throw RawDemuxCopyError.malformed
        }
        let base = UnsafeRawPointer(pointer)
        func load(_ offset: UInt32, present: Bool) -> VPFFTrackExtrasV1? {
            guard present else { return nil }
            return base.advanced(by: Int(offset))
                .assumingMemoryBound(to: VPFFTrackExtrasV1.self).pointee
        }
        let video = load(header.video_track_offset, present: hasVideo)
        let audio = load(header.audio_track_offset, present: hasAudio)
        try validateExtras(video)
        try validateExtras(audio)
        let primary: VPFFAudioPrimaryEvidenceV1?
        if header.version == 2 {
            let v2 = base.assumingMemoryBound(to: VPFFDemuxEventExtrasV2.self).pointee
            guard isBoolean(v2.has_audio_primary_evidence) else { throw RawDemuxCopyError.malformed }
            primary = v2.has_audio_primary_evidence == 1 ? v2.audio_primary_evidence : nil
        } else {
            primary = nil
        }
        return CopiedExtras(video: video, audio: audio, audioPrimaryEvidence: primary)
    }

    private static func validateExtras(_ raw: VPFFTrackExtrasV1?) throws {
        guard let raw else { return }
        let knownPresence = UInt64(VPFF_TRACK_EXTRAS_HAS_ROLE |
            VPFF_TRACK_EXTRAS_HAS_LANGUAGE |
            VPFF_TRACK_EXTRAS_HAS_SERVICE |
            VPFF_TRACK_EXTRAS_HAS_DISPOSITIONS |
            VPFF_TRACK_EXTRAS_HAS_SAMPLE_ASPECT_RATIO |
            VPFF_TRACK_EXTRAS_HAS_COLOR_RANGE |
            VPFF_TRACK_EXTRAS_HAS_COLOR_PRIMARIES |
            VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER |
            VPFF_TRACK_EXTRAS_HAS_COLOR_MATRIX |
            VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION |
            VPFF_TRACK_EXTRAS_HAS_MASTERING_DISPLAY |
            VPFF_TRACK_EXTRAS_HAS_CONTENT_LIGHT_LEVEL |
            VPFF_TRACK_EXTRAS_HAS_SERVICE_CONFLICT |
            Self.roleConflictPresenceMask)
        guard raw.presence & ~knownPresence == 0 else { throw RawDemuxCopyError.malformed }
        guard !(has(raw, VPFF_TRACK_EXTRAS_HAS_SERVICE) &&
            has(raw, VPFF_TRACK_EXTRAS_HAS_SERVICE_CONFLICT)) else {
            throw RawDemuxCopyError.malformed
        }
        guard !(has(raw, VPFF_TRACK_EXTRAS_HAS_ROLE)
            && has(raw, Self.roleConflictPresenceMask)) else {
            throw RawDemuxCopyError.malformed
        }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_ROLE) { _ = try role(raw.role) }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_SERVICE) { _ = try service(raw.service) }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_DISPOSITIONS), raw.dispositions & ~0x3F != 0 {
            throw RawDemuxCopyError.malformed
        }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_LANGUAGE) {
            guard raw.language_size > 0, raw.language_size <= 1_024, raw.language != nil,
                  String(data: Data(bytes: raw.language!, count: raw.language_size), encoding: .utf8) != nil else {
                throw RawDemuxCopyError.malformed
            }
        } else if raw.language != nil || raw.language_size != 0 {
            throw RawDemuxCopyError.malformed
        }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_SAMPLE_ASPECT_RATIO) {
            _ = try rational(raw.sample_aspect_ratio, positive: true)
        }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_RANGE) { _ = try colorRange(raw.color_range) }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_PRIMARIES) { _ = try primaries(raw.color_primaries) }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER) { _ = try transfer(raw.color_transfer) }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_MATRIX) { _ = try matrix(raw.color_matrix) }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION) { _ = try chroma(raw.chroma_location) }
        if has(raw, VPFF_TRACK_EXTRAS_HAS_MASTERING_DISPLAY) {
            _ = try masteringDisplay(raw)
        }
    }

    private static func copyTrackMetadata(_ raw: VPFFTrackExtrasV1?) throws -> DemuxTrackMetadata {
        guard let raw else { return DemuxTrackMetadata() }
        let language: String?
        if has(raw, VPFF_TRACK_EXTRAS_HAS_LANGUAGE) {
            language = String(
                data: Data(bytes: raw.language!, count: raw.language_size),
                encoding: .utf8
            )
        } else {
            language = nil
        }
        let serviceEvidence: DemuxTrackServiceEvidence
        if has(raw, VPFF_TRACK_EXTRAS_HAS_SERVICE_CONFLICT) {
            serviceEvidence = .unclassifiable
        } else if has(raw, VPFF_TRACK_EXTRAS_HAS_SERVICE) {
            serviceEvidence = .resolved(try service(raw.service))
        } else {
            serviceEvidence = .absent
        }
        let roleEvidence: DemuxTrackRoleEvidence
        if has(raw, Self.roleConflictPresenceMask) {
            roleEvidence = .unclassifiable
        } else if has(raw, VPFF_TRACK_EXTRAS_HAS_ROLE) {
            roleEvidence = .resolved(try role(raw.role))
        } else {
            roleEvidence = .absent
        }
        return DemuxTrackMetadata(
            role: has(raw, VPFF_TRACK_EXTRAS_HAS_ROLE) ? try role(raw.role) : nil,
            roleEvidence: roleEvidence,
            language: language,
            serviceEvidence: serviceEvidence,
            dispositions: has(raw, VPFF_TRACK_EXTRAS_HAS_DISPOSITIONS)
                ? DemuxTrackDisposition(rawValue: raw.dispositions)
                : []
        )
    }

    private static func copyVideoMetadata(_ raw: VPFFTrackExtrasV1?) throws -> DemuxVideoMetadata {
        guard let raw else { return DemuxVideoMetadata() }
        let contentLightLevel: DemuxContentLightLevelMetadata?
        if has(raw, VPFF_TRACK_EXTRAS_HAS_CONTENT_LIGHT_LEVEL) {
            guard let value = DemuxContentLightLevelMetadata(
                maximumContentLightLevel: raw.maximum_content_light_level,
                maximumFrameAverageLightLevel: raw.maximum_frame_average_light_level
            ) else { throw RawDemuxCopyError.malformed }
            contentLightLevel = value
        } else {
            contentLightLevel = nil
        }
        return DemuxVideoMetadata(
            sampleAspectRatio: has(raw, VPFF_TRACK_EXTRAS_HAS_SAMPLE_ASPECT_RATIO)
                ? try rational(raw.sample_aspect_ratio, positive: true) : nil,
            range: has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_RANGE) ? try colorRange(raw.color_range) : nil,
            primaries: has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_PRIMARIES)
                ? try primaries(raw.color_primaries) : nil,
            transfer: has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_TRANSFER)
                ? try transfer(raw.color_transfer) : nil,
            matrix: has(raw, VPFF_TRACK_EXTRAS_HAS_COLOR_MATRIX) ? try matrix(raw.color_matrix) : nil,
            chromaLocation: has(raw, VPFF_TRACK_EXTRAS_HAS_CHROMA_LOCATION)
                ? try chroma(raw.chroma_location) : nil,
            masteringDisplay: has(raw, VPFF_TRACK_EXTRAS_HAS_MASTERING_DISPLAY)
                ? try masteringDisplay(raw) : nil,
            contentLightLevel: contentLightLevel
        )
    }

    private static func has(_ raw: VPFFTrackExtrasV1, _ flag: UInt64) -> Bool {
        raw.presence & flag != 0
    }

    private static func rational(_ raw: VPFFRational, positive: Bool = false) throws -> MediaRational {
        guard let value = MediaRational(num: raw.num, den: raw.den),
              !positive || value.num > 0 else { throw RawDemuxCopyError.malformed }
        return value
    }

    private static func role(_ value: VPFFTrackRole) throws -> DemuxTrackRole {
        switch value {
        case VPFF_TRACK_ROLE_MAIN: .main
        case VPFF_TRACK_ROLE_ALTERNATE: .alternate
        case VPFF_TRACK_ROLE_COMMENTARY: .commentary
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func service(_ value: VPFFTrackService) throws -> DemuxTrackService {
        switch value {
        case VPFF_TRACK_SERVICE_INDEPENDENT_MAIN: .independentMain
        case VPFF_TRACK_SERVICE_ASSOCIATED: .associated
        case VPFF_TRACK_SERVICE_DVS: .dvs
        case VPFF_TRACK_SERVICE_DEPENDENT: .dependent
        case VPFF_TRACK_SERVICE_JOC: .joc
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func colorRange(_ value: VPFFColorRange) throws -> DemuxColorRange {
        switch value {
        case VPFF_COLOR_RANGE_LIMITED: .limited
        case VPFF_COLOR_RANGE_FULL: .full
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func primaries(_ value: VPFFColorPrimaries) throws -> DemuxColorPrimaries {
        switch value {
        case VPFF_COLOR_PRIMARIES_BT709: .bt709
        case VPFF_COLOR_PRIMARIES_BT2020: .bt2020
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func transfer(_ value: VPFFColorTransfer) throws -> DemuxColorTransfer {
        switch value {
        case VPFF_COLOR_TRANSFER_BT709: .bt709
        case VPFF_COLOR_TRANSFER_BT2020: .bt2020
        case VPFF_COLOR_TRANSFER_BT2020_12: .bt2020_12
        case VPFF_COLOR_TRANSFER_PQ: .pq
        case VPFF_COLOR_TRANSFER_HLG: .hlg
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func matrix(_ value: VPFFColorMatrix) throws -> DemuxColorMatrix {
        switch value {
        case VPFF_COLOR_MATRIX_BT709: .bt709
        case VPFF_COLOR_MATRIX_BT2020_NONCONSTANT: .bt2020Nonconstant
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func chroma(_ value: VPFFChromaLocation) throws -> DemuxChromaLocation {
        switch value {
        case VPFF_CHROMA_LOCATION_LEFT: .left
        case VPFF_CHROMA_LOCATION_CENTER: .center
        case VPFF_CHROMA_LOCATION_TOP_LEFT: .topLeft
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func masteringDisplay(_ raw: VPFFTrackExtrasV1) throws -> DemuxMasteringDisplayMetadata {
        guard let value = DemuxMasteringDisplayMetadata(
            redX: try hdrRational(raw.mastering_display_red_x),
            redY: try hdrRational(raw.mastering_display_red_y),
            greenX: try hdrRational(raw.mastering_display_green_x),
            greenY: try hdrRational(raw.mastering_display_green_y),
            blueX: try hdrRational(raw.mastering_display_blue_x),
            blueY: try hdrRational(raw.mastering_display_blue_y),
            whitePointX: try hdrRational(raw.mastering_display_white_point_x),
            whitePointY: try hdrRational(raw.mastering_display_white_point_y),
            minimumLuminance: try hdrRational(raw.mastering_display_minimum_luminance),
            maximumLuminance: try hdrRational(raw.mastering_display_maximum_luminance)
        ) else { throw RawDemuxCopyError.malformed }
        return value
    }

    private static func hdrRational(_ raw: VPFFRational) throws -> DemuxHDRRational {
        guard let value = DemuxHDRRational(num: raw.num, den: raw.den) else {
            throw RawDemuxCopyError.malformed
        }
        return value
    }

    private static func copyPacket(_ raw: VPFFPacket) throws -> (DemuxPacket, Int) {
        guard raw.stream_index >= 0,
              isBoolean(raw.is_key), isBoolean(raw.is_corrupt),
              let rational = MediaRational(num: raw.time_base_num, den: raw.time_base_den),
              let codec = mediaCodec(raw.codec) else {
            throw RawDemuxCopyError.malformed
        }
        let data = try copyBytes(
            raw.data,
            size: raw.size,
            maximum: maximumPacketBytes
        )
        let duration: CMTime = raw.duration == Int64.min || raw.duration < 0
            ? .invalid
            : rational.cmTime(forFFmpegValue: raw.duration)
        return (
            DemuxPacket(
                streamIndex: raw.stream_index,
                codec: codec,
                data: data,
                presentationTimeStamp: rational.cmTime(forFFmpegValue: raw.pts),
                decodeTimeStamp: rational.cmTime(forFFmpegValue: raw.dts),
                duration: duration,
                isKey: raw.is_key == 1,
                isCorrupt: raw.is_corrupt == 1
            ),
            data.count
        )
    }

    private static func copyBytes(
        _ pointer: UnsafePointer<UInt8>?,
        size: Int,
        maximum: Int
    ) throws -> Data {
        guard size >= 0, size <= maximum, (pointer == nil) == (size == 0) else {
            throw RawDemuxCopyError.malformed
        }
        guard let pointer else { return Data() }
        return Data(bytes: pointer, count: size)
    }

    private static func measuredBytes(
        _ pointer: UnsafePointer<UInt8>?,
        size: Int,
        maximum: Int
    ) throws -> Int {
        guard size >= 0, size <= maximum, (pointer == nil) == (size == 0) else {
            throw RawDemuxCopyError.malformed
        }
        return size
    }

    private static func mapError(_ raw: VPFFDemuxEvent) throws -> PlaybackCoreError {
        switch raw.error_kind {
        case VPFF_DEMUX_ERROR_OPEN: .demuxOpen(raw.ffmpeg_error)
        case VPFF_DEMUX_ERROR_READ: .demuxRead(raw.ffmpeg_error)
        case VPFF_DEMUX_ERROR_TIMEOUT: .networkTimeout
        case VPFF_DEMUX_ERROR_UNSUPPORTED_VIDEO: .unsupportedVideoCodec
        case VPFF_DEMUX_ERROR_UNSUPPORTED_AUDIO: .unsupportedAudioCodec
        default: throw RawDemuxCopyError.malformed
        }
    }

    private static func isKnownStage(_ value: VPFFDemuxErrorStage) -> Bool {
        switch value {
        case VPFF_DEMUX_STAGE_NONE, VPFF_DEMUX_STAGE_VALIDATION, VPFF_DEMUX_STAGE_OPEN,
             VPFF_DEMUX_STAGE_STREAM_INFO, VPFF_DEMUX_STAGE_SELECTION, VPFF_DEMUX_STAGE_BSF_INIT,
             VPFF_DEMUX_STAGE_READ, VPFF_DEMUX_STAGE_BSF_SEND, VPFF_DEMUX_STAGE_BSF_RECEIVE:
            true
        default:
            false
        }
    }

    private static func isBoolean(_ value: UInt8) -> Bool { value == 0 || value == 1 }

    private static func videoCodec(_ value: VPFFCodec) -> VideoCodec? {
        switch value {
        case VPFF_CODEC_H264: .h264
        case VPFF_CODEC_HEVC: .hevc
        default: nil
        }
    }

    private static func codedFieldOrder(_ value: UInt8) -> CodedFieldOrder? {
        switch value {
        case 0: .unknown
        case 1: .progressive
        case 2: .tt
        case 3: .bb
        case 4: .tb
        case 5: .bt
        default: nil
        }
    }

    private static func audioCodec(_ value: VPFFCodec) -> AudioCodec? {
        switch value {
        case VPFF_CODEC_AAC: .aac
        case VPFF_CODEC_AC3: .ac3
        case VPFF_CODEC_EAC3: .eac3
        case VPFF_CODEC_MP2: .mp2
        case VPFF_CODEC_MP1: .mp1
        case VPFF_CODEC_MP3: .mp3
        default: nil
        }
    }

    private static func mediaCodec(_ value: VPFFCodec) -> MediaCodec? {
        if let video = videoCodec(value) { return .video(video) }
        if let audio = audioCodec(value) { return .audio(audio) }
        return nil
    }
}

private extension DemuxEvent {
    var isTerminal: Bool {
        switch self {
        case .endOfStream, .cancelled, .failure: true
        case .tracks, .packet, .discontinuity: false
        }
    }
}

private final class LiveReceiverBox: @unchecked Sendable {
    let receiver: RawFFmpegDemuxReceiver
    init(receiver: @escaping RawFFmpegDemuxReceiver) { self.receiver = receiver }
}

private final class LiveReceiverBoxV2: @unchecked Sendable {
    let receiver: RawFFmpegDemuxReceiverV2
    init(receiver: @escaping RawFFmpegDemuxReceiverV2) { self.receiver = receiver }
}

private func liveDemuxCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?
) {
    guard let context, let event else { return }
    Unmanaged<LiveReceiverBox>.fromOpaque(context).takeUnretainedValue().receiver(event)
}

private func liveDemuxCallbackV2(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?,
    _ extras: UnsafePointer<VPFFDemuxEventExtras>?
) {
    guard let context, let event else { return }
    Unmanaged<LiveReceiverBoxV2>.fromOpaque(context)
        .takeUnretainedValue().receiver(event, extras)
}

private struct LiveFFmpegDemuxBridge: FFmpegDemuxBridging {
    func create(
        urlBytes: Data,
        timeoutUS: Int64,
        receiver: @escaping RawFFmpegDemuxReceiver
    ) -> FFmpegDemuxCreateResult {
        let box = LiveReceiverBox(receiver: receiver)
        let context = Unmanaged.passRetained(box).toOpaque()
        var rawHandle: OpaquePointer?
        let result = urlBytes.withUnsafeBytes { bytes in
            vp_ffmpeg_demuxer_create(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                timeoutUS,
                liveDemuxCallback,
                context,
                &rawHandle
            )
        }
        guard result == 0, let rawHandle else {
            Unmanaged<LiveReceiverBox>.fromOpaque(context).release()
            return .failure(result)
        }
        return .success(LiveFFmpegDemuxHandle(
            rawHandle: rawHandle,
            releaseContext: {
                Unmanaged<LiveReceiverBox>.fromOpaque(context).release()
            }
        ))
    }

    func createV2(
        urlBytes: Data,
        timeoutUS: Int64,
        receiver: @escaping RawFFmpegDemuxReceiverV2
    ) -> FFmpegDemuxCreateResult {
        let box = LiveReceiverBoxV2(receiver: receiver)
        let context = Unmanaged.passRetained(box).toOpaque()
        var rawHandle: OpaquePointer?
        let result = urlBytes.withUnsafeBytes { bytes in
            vp_ffmpeg_demuxer_create_v2(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                timeoutUS,
                liveDemuxCallbackV2,
                context,
                &rawHandle
            )
        }
        guard result == 0, let rawHandle else {
            Unmanaged<LiveReceiverBoxV2>.fromOpaque(context).release()
            return .failure(result)
        }
        return .success(LiveFFmpegDemuxHandle(
            rawHandle: rawHandle,
            releaseContext: {
                Unmanaged<LiveReceiverBoxV2>.fromOpaque(context).release()
            }
        ))
    }
}

private final class LiveFFmpegDemuxHandle: FFmpegDemuxHandle, @unchecked Sendable {
    private let rawHandle: OpaquePointer
    private let releaseContext: () -> Void

    init(rawHandle: OpaquePointer, releaseContext: @escaping () -> Void) {
        self.rawHandle = rawHandle
        self.releaseContext = releaseContext
    }

    func run() -> Int32 { vp_ffmpeg_demuxer_run(rawHandle) }
    func cancel() { vp_ffmpeg_demuxer_cancel(rawHandle) }

    func destroy() {
        vp_ffmpeg_demuxer_destroy(rawHandle)
        releaseContext()
    }
}
