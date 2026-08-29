// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
@testable import VPlayerPlayback

final class DemuxEventRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var storedEvents: [DemuxEvent] = []

    func record(_ event: DemuxEvent) {
        condition.lock()
        storedEvents.append(event)
        condition.broadcast()
        condition.unlock()
    }

    func waitForTerminal(timeout: TimeInterval = 5) -> [DemuxEvent] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !storedEvents.contains(where: \.isTerminal), condition.wait(until: deadline) {}
        return storedEvents
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 5) -> [DemuxEvent] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while storedEvents.count < count, condition.wait(until: deadline) {}
        return storedEvents
    }

    var events: [DemuxEvent] {
        condition.lock()
        defer { condition.unlock() }
        return storedEvents
    }
}

private extension DemuxEvent {
    var isTerminal: Bool {
        switch self {
        case .endOfStream, .cancelled, .failure:
            true
        case .tracks, .packet, .discontinuity:
            false
        }
    }
}

struct RawTrackSpec: Sendable {
    var present = true
    var streamIndex: Int32 = 0
    var codec = VPFF_CODEC_UNSUPPORTED
    var timeBaseNum: Int32 = 1
    var timeBaseDen: Int32 = 90_000
    var width: Int32 = 0
    var height: Int32 = 0
    var videoDelay: Int32 = 0
    var frameRateNum: Int32 = 0
    var frameRateDen: Int32 = 0
    var sampleRate: Int32 = 0
    var channelCount: Int32 = 0
    var channelOrder = VPFF_CHANNEL_ORDER_UNSPECIFIED
    var hasChannelLayoutMask = false
    var channelLayoutMask: UInt64 = 0
    var extradata = Data()
}

struct RawPacketSpec: Sendable {
    var streamIndex: Int32 = 0
    var codec = VPFF_CODEC_UNSUPPORTED
    var data = Data()
    var pts: Int64 = 0
    var dts: Int64 = 0
    var duration: Int64 = 0
    var timeBaseNum: Int32 = 1
    var timeBaseDen: Int32 = 90_000
    var isKey = false
    var isCorrupt = false
}

final class FakeFFmpegDemuxBridge: FFmpegDemuxBridging, @unchecked Sendable {
    typealias RunScript = @Sendable (FakeFFmpegDemuxHandle) -> Int32

    private let lock = NSLock()
    private let runScript: RunScript
    private var storedCreateCount = 0
    private var storedURLBytes = Data()
    private var storedTimeoutUS: Int64 = 0
    private var storedHandle: FakeFFmpegDemuxHandle?

    init(runScript: @escaping RunScript = { handle in
        handle.emitTerminal(VPFF_EVENT_END)
        return 0
    }) {
        self.runScript = runScript
    }

    func create(
        urlBytes: Data,
        timeoutUS: Int64,
        receiver: @escaping RawFFmpegDemuxReceiver
    ) -> FFmpegDemuxCreateResult {
        let handle = FakeFFmpegDemuxHandle(receiver: receiver, runScript: runScript)
        lock.lock()
        storedCreateCount += 1
        storedURLBytes = urlBytes
        storedTimeoutUS = timeoutUS
        storedHandle = handle
        lock.unlock()
        return .success(handle)
    }

    var createCount: Int {
        lock.withLock { storedCreateCount }
    }

    var urlBytes: Data {
        lock.withLock { storedURLBytes }
    }

    var timeoutUS: Int64 {
        lock.withLock { storedTimeoutUS }
    }

    var handle: FakeFFmpegDemuxHandle? {
        lock.withLock { storedHandle }
    }
}

final class FakeFFmpegDemuxHandle: FFmpegDemuxHandle, @unchecked Sendable {
    private let condition = NSCondition()
    private let receiver: RawFFmpegDemuxReceiver
    private let runScript: FakeFFmpegDemuxBridge.RunScript
    private var storedCancelled = false
    private var storedRunCount = 0
    private var storedCancelCount = 0
    private var storedDestroyCount = 0

    init(
        receiver: @escaping RawFFmpegDemuxReceiver,
        runScript: @escaping FakeFFmpegDemuxBridge.RunScript
    ) {
        self.receiver = receiver
        self.runScript = runScript
    }

    func run() -> Int32 {
        condition.lock()
        storedRunCount += 1
        condition.broadcast()
        condition.unlock()
        return runScript(self)
    }

    func cancel() {
        condition.lock()
        storedCancelled = true
        storedCancelCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func destroy() {
        condition.lock()
        storedDestroyCount += 1
        condition.broadcast()
        condition.unlock()
    }

    var isCancelled: Bool {
        condition.withLock { storedCancelled }
    }

    var runCount: Int {
        condition.withLock { storedRunCount }
    }

    var cancelCount: Int {
        condition.withLock { storedCancelCount }
    }

    var destroyCount: Int {
        condition.withLock { storedDestroyCount }
    }

    @discardableResult
    func waitUntilCancelled(timeout: TimeInterval = 5) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !storedCancelled, condition.wait(until: deadline) {}
        return storedCancelled
    }

    func emitTracks(
        programID: Int32? = nil,
        video: RawTrackSpec? = nil,
        audio: RawTrackSpec? = nil,
        kind: VPFFDemuxEventKind = VPFF_EVENT_TRACKS,
        discontinuityReason: VPFFDemuxDiscontinuityReason? = nil,
        mutateBorrowedBytesAfterCallback: Bool = false
    ) {
        emit(
            kind: kind,
            programID: programID,
            video: video,
            audio: audio,
            packet: nil,
            errorKind: VPFF_DEMUX_ERROR_NONE,
            discontinuityReason: discontinuityReason
                ?? (kind == VPFF_EVENT_DISCONTINUITY
                    ? VPFF_DISCONTINUITY_FORMAT_CHANGE
                    : VPFF_DISCONTINUITY_NONE),
            ffmpegError: 0,
            mutateBorrowedBytesAfterCallback: mutateBorrowedBytesAfterCallback
        )
    }

    func emitPacket(
        _ packet: RawPacketSpec,
        mutateBorrowedBytesAfterCallback: Bool = false
    ) {
        emit(
            kind: VPFF_EVENT_PACKET,
            programID: nil,
            video: nil,
            audio: nil,
            packet: packet,
            errorKind: VPFF_DEMUX_ERROR_NONE,
            ffmpegError: 0,
            mutateBorrowedBytesAfterCallback: mutateBorrowedBytesAfterCallback
        )
    }

    func emitTerminal(
        _ kind: VPFFDemuxEventKind,
        errorKind: VPFFDemuxErrorKind = VPFF_DEMUX_ERROR_NONE,
        ffmpegError: Int32 = 0,
        errorStage: VPFFDemuxErrorStage? = nil
    ) {
        emit(
            kind: kind,
            programID: nil,
            video: nil,
            audio: nil,
            packet: nil,
            errorKind: errorKind,
            errorStage: errorStage ?? (kind == VPFF_EVENT_ERROR ? VPFF_DEMUX_STAGE_READ : VPFF_DEMUX_STAGE_NONE),
            ffmpegError: ffmpegError,
            mutateBorrowedBytesAfterCallback: false
        )
    }

    func emitMalformedPacketPointerSize() {
        var event = VPFFDemuxEvent()
        event.kind = VPFF_EVENT_PACKET
        event.packet.codec = VPFF_CODEC_H264
        event.packet.time_base_num = 1
        event.packet.time_base_den = 90_000
        event.packet.data = nil
        event.packet.size = 1
        withUnsafePointer(to: &event, receiver)
    }

    func emitRawEvent(_ configure: (inout VPFFDemuxEvent) -> Void) {
        var event = VPFFDemuxEvent()
        configure(&event)
        withUnsafePointer(to: &event, receiver)
    }

    func emitOversizedPacketSize() {
        var byte: UInt8 = 0
        withUnsafePointer(to: &byte) { bytePointer in
            var event = VPFFDemuxEvent()
            event.kind = VPFF_EVENT_PACKET
            event.packet.stream_index = 0
            event.packet.codec = VPFF_CODEC_H264
            event.packet.time_base_num = 1
            event.packet.time_base_den = 90_000
            event.packet.data = bytePointer
            event.packet.size = 64 * 1_024 * 1_024 + 1
            withUnsafePointer(to: &event, receiver)
        }
    }

    func emitOversizedTrackExtradata() {
        var byte: UInt8 = 0
        withUnsafePointer(to: &byte) { bytePointer in
            var event = VPFFDemuxEvent()
            event.kind = VPFF_EVENT_TRACKS
            event.video.present = 1
            event.video.stream_index = 0
            event.video.codec = VPFF_CODEC_H264
            event.video.time_base_num = 1
            event.video.time_base_den = 90_000
            event.video.width = 1_920
            event.video.height = 1_080
            event.video.extradata = bytePointer
            event.video.extradata_size = 1 * 1_024 * 1_024 + 1
            withUnsafePointer(to: &event, receiver)
        }
    }

    private func emit(
        kind: VPFFDemuxEventKind,
        programID: Int32?,
        video: RawTrackSpec?,
        audio: RawTrackSpec?,
        packet: RawPacketSpec?,
        errorKind: VPFFDemuxErrorKind,
        errorStage: VPFFDemuxErrorStage = VPFF_DEMUX_STAGE_NONE,
        discontinuityReason: VPFFDemuxDiscontinuityReason = VPFF_DISCONTINUITY_NONE,
        ffmpegError: Int32,
        mutateBorrowedBytesAfterCallback: Bool
    ) {
        var videoBytes = [UInt8](video?.extradata ?? Data())
        var audioBytes = [UInt8](audio?.extradata ?? Data())
        var packetBytes = [UInt8](packet?.data ?? Data())

        videoBytes.withUnsafeMutableBytes { videoBuffer in
            audioBytes.withUnsafeMutableBytes { audioBuffer in
                packetBytes.withUnsafeMutableBytes { packetBuffer in
                    var event = VPFFDemuxEvent()
                    event.kind = kind
                    event.has_program_id = programID == nil ? 0 : 1
                    event.selected_program_id = programID ?? 0
                    event.video = Self.makeTrack(video, buffer: videoBuffer)
                    event.audio = Self.makeTrack(audio, buffer: audioBuffer)
                    event.packet = Self.makePacket(packet, buffer: packetBuffer)
                    event.error_kind = errorKind
                    event.error_stage = errorStage
                    event.ffmpeg_error = ffmpegError
                    event.discontinuity_reason = discontinuityReason
                    withUnsafePointer(to: &event, receiver)
                }
            }
        }

        if mutateBorrowedBytesAfterCallback {
            videoBytes.indices.forEach { videoBytes[$0] = 0xEE }
            audioBytes.indices.forEach { audioBytes[$0] = 0xEE }
            packetBytes.indices.forEach { packetBytes[$0] = 0xEE }
        }
    }

    private static func makeTrack(
        _ spec: RawTrackSpec?,
        buffer: UnsafeMutableRawBufferPointer
    ) -> VPFFTrack {
        var track = VPFFTrack()
        guard let spec else { return track }
        track.present = spec.present ? 1 : 0
        track.stream_index = spec.streamIndex
        track.codec = spec.codec
        track.time_base_num = spec.timeBaseNum
        track.time_base_den = spec.timeBaseDen
        track.width = spec.width
        track.height = spec.height
        track.video_delay = spec.videoDelay
        track.frame_rate_num = spec.frameRateNum
        track.frame_rate_den = spec.frameRateDen
        track.sample_rate = spec.sampleRate
        track.channel_count = spec.channelCount
        track.channel_order = spec.channelOrder
        track.has_channel_layout_mask = spec.hasChannelLayoutMask ? 1 : 0
        track.channel_layout_mask = spec.channelLayoutMask
        track.extradata = buffer.isEmpty
            ? nil
            : buffer.baseAddress.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }
        track.extradata_size = buffer.count
        return track
    }

    private static func makePacket(
        _ spec: RawPacketSpec?,
        buffer: UnsafeMutableRawBufferPointer
    ) -> VPFFPacket {
        var packet = VPFFPacket()
        guard let spec else { return packet }
        packet.stream_index = spec.streamIndex
        packet.codec = spec.codec
        packet.data = buffer.isEmpty
            ? nil
            : buffer.baseAddress.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }
        packet.size = buffer.count
        packet.pts = spec.pts
        packet.dts = spec.dts
        packet.duration = spec.duration
        packet.time_base_num = spec.timeBaseNum
        packet.time_base_den = spec.timeBaseDen
        packet.is_key = spec.isKey ? 1 : 0
        packet.is_corrupt = spec.isCorrupt ? 1 : 0
        return packet
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension NSCondition {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}
