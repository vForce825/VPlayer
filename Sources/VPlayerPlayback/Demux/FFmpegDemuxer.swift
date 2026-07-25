// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Dispatch
import Foundation

typealias RawFFmpegDemuxReceiver = @Sendable (UnsafePointer<VPFFDemuxEvent>) -> Void

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
}

final class FFmpegDemuxer: MediaDemuxing, @unchecked Sendable {
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
        timeoutUS: Int64 = 10_000_000,
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

        try state.begin(sink: sink)
        let receiver: RawFFmpegDemuxReceiver = { [state] event in
            state.receive(event)
        }
        switch bridge.create(urlBytes: urlBytes, timeoutUS: timeoutUS, receiver: receiver) {
        case let .failure(code):
            state.failStart()
            throw PlaybackCoreError.demuxOpen(code)
        case let .success(handle):
            state.install(handle: handle)
            ioQueue.async { [state] in
                let result = handle.run()
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
    private var lastTracks: DemuxTrackSet?
    private var liveHandle: (any FFmpegDemuxHandle)?
    private var liveHandleID: ObjectIdentifier?

    init(executor: PlaybackSerialExecutor, capacity: Int, maximumQueuedBytes: Int) {
        self.executor = executor
        self.maximumQueuedBytes = maximumQueuedBytes
        queue = BoundedMediaQueue(capacity: capacity, overflow: .rejectNewest)
    }

    func begin(sink newSink: @escaping @Sendable (DemuxEvent) -> Void) throws {
        condition.lock()
        guard !started else {
            condition.unlock()
            throw PlaybackCoreError.demuxOpen(FFmpegDemuxer.doubleStartErrorCode)
        }
        started = true
        sink = newSink
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.unlock()
        if shouldSchedule { submitDrain() }
    }

    func failStart() {
        condition.lock()
        sink = nil
        terminalDelivered = true
        condition.broadcast()
        condition.unlock()
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

    func receive(_ rawEvent: UnsafePointer<VPFFDemuxEvent>) {
        let copied: CopiedDemuxEvent
        let mustCancelRun: Bool
        do {
            copied = try RawDemuxEventCopier.copy(rawEvent.pointee)
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

        if case let .tracks(tracks) = copied.event {
            lastTracks = tracks
        } else if case let .discontinuity(tracks) = copied.event {
            if tracks == lastTracks {
                condition.unlock()
                return
            }
            lastTracks = tracks
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
        guard queue.push(QueuedDemuxEvent(event: copied.event, byteCount: copied.byteCount)) == nil else {
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
        let shouldSchedule = scheduleDrainIfNeededLocked()
        condition.broadcast()
        condition.unlock()
        if shouldSchedule { submitDrain() }
    }

    /// The condition must be held so the terminal winner and native cancellation are linearized.
    private func cancelLiveHandleLocked() {
        handleLock.lock()
        liveHandle?.cancel()
        handleLock.unlock()
    }

    private func scheduleDrainIfNeededLocked() -> Bool {
        guard !drainScheduled, sink != nil,
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
                condition.broadcast()
                condition.unlock()
                currentSink?(queued.event)
                deliveredCount += 1
                continue
            }
            if let terminal = pendingTerminal {
                pendingTerminal = nil
                terminalDelivered = true
                drainScheduled = false
                let currentSink = sink
                sink = nil
                condition.broadcast()
                condition.unlock()
                currentSink?(terminal)
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

private enum RawDemuxCopyError: Error {
    case malformed
    case unsupportedVideo
    case unsupportedAudio
}

private enum RawDemuxEventCopier {
    private static let maximumExtradataBytes = 1 * 1_024 * 1_024
    private static let maximumPacketBytes = 64 * 1_024 * 1_024

    static func copy(_ raw: VPFFDemuxEvent) throws -> CopiedDemuxEvent {
        guard isKnownStage(raw.error_stage), isBoolean(raw.has_program_id) else {
            throw RawDemuxCopyError.malformed
        }
        switch raw.kind {
        case VPFF_EVENT_TRACKS, VPFF_EVENT_DISCONTINUITY:
            guard raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            let video = try copyTrack(raw.video, mediaType: .video)
            let audio = try copyTrack(raw.audio, mediaType: .audio)
            guard video.video != nil || audio.audio != nil else {
                throw RawDemuxCopyError.malformed
            }
            let tracks = DemuxTrackSet(
                selectedProgramID: raw.has_program_id == 1 ? raw.selected_program_id : nil,
                video: video.video,
                audio: audio.audio
            )
            let event: DemuxEvent = raw.kind == VPFF_EVENT_TRACKS
                ? .tracks(tracks)
                : .discontinuity(tracks)
            return CopiedDemuxEvent(event: event, byteCount: video.byteCount + audio.byteCount)
        case VPFF_EVENT_PACKET:
            guard raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            let packet = try copyPacket(raw.packet)
            return CopiedDemuxEvent(event: .packet(packet.0), byteCount: packet.1)
        case VPFF_EVENT_END:
            guard raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            return CopiedDemuxEvent(event: .endOfStream, byteCount: 0)
        case VPFF_EVENT_CANCELLED:
            guard raw.error_stage == VPFF_DEMUX_STAGE_NONE,
                  raw.error_kind == VPFF_DEMUX_ERROR_NONE else {
                throw RawDemuxCopyError.malformed
            }
            return CopiedDemuxEvent(event: .cancelled, byteCount: 0)
        case VPFF_EVENT_ERROR:
            guard raw.error_stage != VPFF_DEMUX_STAGE_NONE else {
                throw RawDemuxCopyError.malformed
            }
            return CopiedDemuxEvent(event: .failure(try mapError(raw)), byteCount: 0)
        default:
            throw RawDemuxCopyError.malformed
        }
    }

    private enum TrackMediaType { case video, audio }
    private struct CopiedTrack {
        let video: VideoTrackDescriptor?
        let audio: AudioTrackDescriptor?
        let byteCount: Int
    }

    private static func copyTrack(_ raw: VPFFTrack, mediaType: TrackMediaType) throws -> CopiedTrack {
        guard isBoolean(raw.present), isBoolean(raw.has_channel_layout_mask) else {
            throw RawDemuxCopyError.malformed
        }
        guard raw.present == 1 else {
            guard try copyBytes(raw.extradata, size: raw.extradata_size, maximum: maximumExtradataBytes).isEmpty else {
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
        switch mediaType {
        case .video:
            guard raw.width > 0, raw.height > 0, raw.video_delay >= 0 else {
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
                    extradata: extradata
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
                    extradata: extradata
                ),
                byteCount: extradata.count
            )
        }
    }

    private static func copyPacket(_ raw: VPFFPacket) throws -> (DemuxPacket, Int) {
        guard raw.stream_index >= 0,
              isBoolean(raw.is_key), isBoolean(raw.is_corrupt),
              let rational = MediaRational(num: raw.time_base_num, den: raw.time_base_den),
              let codec = mediaCodec(raw.codec) else {
            throw RawDemuxCopyError.malformed
        }
        let data = try copyBytes(raw.data, size: raw.size, maximum: maximumPacketBytes)
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

    private static func audioCodec(_ value: VPFFCodec) -> AudioCodec? {
        switch value {
        case VPFF_CODEC_AAC: .aac
        case VPFF_CODEC_AC3: .ac3
        case VPFF_CODEC_EAC3: .eac3
        case VPFF_CODEC_MP2: .mp2
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

private func liveDemuxCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?
) {
    guard let context, let event else { return }
    Unmanaged<LiveReceiverBox>.fromOpaque(context).takeUnretainedValue().receiver(event)
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
        return .success(LiveFFmpegDemuxHandle(rawHandle: rawHandle, context: context))
    }
}

private final class LiveFFmpegDemuxHandle: FFmpegDemuxHandle, @unchecked Sendable {
    private let rawHandle: OpaquePointer
    private let context: UnsafeMutableRawPointer

    init(rawHandle: OpaquePointer, context: UnsafeMutableRawPointer) {
        self.rawHandle = rawHandle
        self.context = context
    }

    func run() -> Int32 { vp_ffmpeg_demuxer_run(rawHandle) }
    func cancel() { vp_ffmpeg_demuxer_cancel(rawHandle) }

    func destroy() {
        vp_ffmpeg_demuxer_destroy(rawHandle)
        Unmanaged<LiveReceiverBox>.fromOpaque(context).release()
    }
}
