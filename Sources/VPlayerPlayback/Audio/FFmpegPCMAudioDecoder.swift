// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

final class HLSAudioCopyOwnership: @unchecked Sendable {
    enum Phase: Sendable, Equatable { case compressedInput, nativePacket, pcmData, cmBlock, framing }
    struct CopyEvent: Sendable, Equatable { let phase: Phase; let wasChargedBeforeCopy: Bool }
    let compressedInput: HLSDataPlaneAdmission
    let nativeAllocation: HLSDataPlaneAdmission
    let pcmTemporary: HLSDataPlaneAdmission
    let finalBlock: HLSDataPlaneAdmission
    let framing: HLSDataPlaneAdmission
    #if DEBUG
    private let lock = NSLock()
    private var events: [CopyEvent] = []
    private static let eventCapacity = 64
    #endif
    private let observationLock = NSLock()
    private weak var drainObservation: FFmpegDrainCancelOrderingObservation?
    init(maximumCompressedBytes: Int, maximumPCMBytes: Int, capacity: Int,
         applicationLedger: HLSDeliveryApplicationChargeLedger = .shared) {
        compressedInput = .init(capacity: capacity, maximumBytes: maximumCompressedBytes, applicationLedger: applicationLedger)
        nativeAllocation = .init(capacity: capacity, maximumBytes: maximumCompressedBytes, applicationLedger: applicationLedger)
        pcmTemporary = .init(capacity: capacity, maximumBytes: maximumPCMBytes, applicationLedger: applicationLedger)
        finalBlock = .init(capacity: capacity, maximumBytes: maximumPCMBytes, applicationLedger: applicationLedger)
        framing = .init(capacity: capacity, maximumBytes: maximumCompressedBytes, applicationLedger: applicationLedger)
    }
    #if DEBUG
    var copyEvents: [CopyEvent] { lock.withLock { events } }
    #endif
    func admit(_ phase: Phase, bytes: Int) -> HLSDataPlaneAdmission.Lease? {
        let domain: HLSDataPlaneAdmission
        switch phase { case .compressedInput: domain = compressedInput; case .nativePacket: domain = nativeAllocation; case .pcmData: domain = pcmTemporary; case .cmBlock: domain = finalBlock; case .framing: domain = framing }
        if phase == .pcmData { observationLock.withLock { drainObservation?.pcmAdmissionWillWait() } }
        let lease = domain.waitForAdmission(bytes: bytes)
        if phase == .pcmData { observationLock.withLock { drainObservation?.pcmAdmissionDidReturn() } }
        #if DEBUG
        if lease != nil { lock.withLock {
            if events.count == Self.eventCapacity { events.removeFirst() }
            events.append(.init(phase: phase, wasChargedBeforeCopy: true))
        } }
        #endif
        return lease
    }
    func cancel() { compressedInput.cancel(); nativeAllocation.cancel(); pcmTemporary.cancel(); finalBlock.cancel(); framing.cancel() }
    fileprivate func observeDrain(_ observation: FFmpegDrainCancelOrderingObservation) {
        observationLock.withLock { drainObservation = observation }
    }
}

/// 只由真实 pcm admission、drain native call 与 destroy 状态机驱动的调试观测，
/// 不以测试侧 flag 模拟时序。
final class FFmpegDrainCancelOrderingObservation: @unchecked Sendable {
    private let condition = NSCondition()
    private var pcmBlocked = false
    private var drainReturned = false
    private var destroyed = false
    fileprivate func pcmAdmissionWillWait() { condition.lock(); pcmBlocked = true; condition.broadcast(); condition.unlock() }
    fileprivate func pcmAdmissionDidReturn() { condition.lock(); condition.broadcast(); condition.unlock() }
    fileprivate func nativeDrainReturned() { condition.lock(); drainReturned = true; condition.broadcast(); condition.unlock() }
    fileprivate func nativeDestroyed() { condition.lock(); destroyed = true; condition.broadcast(); condition.unlock() }
    func waitUntilPCMAdmissionBlocked(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !pcmBlocked && condition.wait(until: deadline) {}
        return pcmBlocked
    }
    var destroyOccurredAfterDrainReturned: Bool {
        condition.lock(); defer { condition.unlock() }
        return destroyed && drainReturned
    }
}

/// 受费的压缩帧/拼接尾。Data 为值语义，不能以临时作用域的 defer 代替其最后 alias。
final class HLSAudioCopyTail: @unchecked Sendable {
    private var leases: [HLSDataPlaneAdmission.Lease]
    init(_ lease: HLSDataPlaneAdmission.Lease) { leases = [lease] }
    init(_ leases: [HLSDataPlaneAdmission.Lease]) { self.leases = leases }
    deinit { leases.forEach { $0.release() } }
}

struct BorrowedFFmpegPCMFrame: @unchecked Sendable {
    let interleaved: UnsafePointer<Float>?
    let frameCount: Int
    let sampleRate: Int32
    let channels: Int32
    let token: Int64
    let abiVersion: UInt32
    let structSize: UInt32
    let channelOrder: VPFFChannelOrder
    let hasChannelLayoutMask: UInt8
    let reserved: (UInt8, UInt8, UInt8)
    let channelLayoutMask: UInt64
}

protocol FFmpegAudioDecoderHandle: AnyObject, Sendable {
    func push(_ bytes: Data, token: Int64) -> Int32
    func drain() -> Int32
    func flush()
    func destroy()
}

protocol FFmpegAudioDecoderAPI: Sendable {
    func create(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        hlsCopyOwnership: HLSAudioCopyOwnership?,
        receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void
    ) throws -> any FFmpegAudioDecoderHandle
}

extension FFmpegAudioDecoderAPI {
    func create(codec: VPlayerPlayback.AudioCodec, extradata: Data,
                receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void) throws -> any FFmpegAudioDecoderHandle {
        try create(codec: codec, extradata: extradata, hlsCopyOwnership: nil, receiver: receiver)
    }
}

private final class LiveFFmpegAudioCallbackBox: @unchecked Sendable {
    let receiver: @Sendable (BorrowedFFmpegPCMFrame) -> Void
    let ownership: HLSAudioCopyOwnership?
    init(receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void,
         ownership: HLSAudioCopyOwnership?) {
        self.receiver = receiver
        self.ownership = ownership
    }
}

private final class LiveFFmpegAudioAllocationLease {
    var lease: HLSDataPlaneAdmission.Lease?
    init(_ lease: HLSDataPlaneAdmission.Lease) { self.lease = lease }
    deinit { lease?.release() }
}

private func liveFFmpegAudioReserve(
    context: UnsafeMutableRawPointer?, bytes: Int, role _: VPFFAudioAllocationRole
) -> UnsafeMutableRawPointer? {
    guard let context, bytes > 0 else { return nil }
    let box = Unmanaged<LiveFFmpegAudioCallbackBox>.fromOpaque(context).takeUnretainedValue()
    guard let ownership = box.ownership else { return nil }
    let phase: HLSAudioCopyOwnership.Phase = .nativePacket
    guard let lease = ownership.admit(phase, bytes: bytes) else { return nil }
    return Unmanaged.passRetained(LiveFFmpegAudioAllocationLease(lease)).toOpaque()
}

private func liveFFmpegAudioRelease(context _: UnsafeMutableRawPointer?, token: UnsafeMutableRawPointer?) {
    guard let token else { return }
    Unmanaged<LiveFFmpegAudioAllocationLease>.fromOpaque(token).release()
}

private func liveFFmpegAudioCallback(
    context: UnsafeMutableRawPointer?,
    frame: UnsafePointer<VPFFPCMFrame>?
) {
    guard let context, let frame else { return }
    let box = Unmanaged<LiveFFmpegAudioCallbackBox>.fromOpaque(context)
        .takeUnretainedValue()
    let abiVersion = frame.pointee.abi_version
    let structSize = frame.pointee.struct_size
    let minimumSize = MemoryLayout<VPFFPCMFrame>.offset(of: \.channel_layout_mask)
        .map { $0 + MemoryLayout<UInt64>.size } ?? Int.max
    guard Int(structSize) >= minimumSize else {
        box.receiver(BorrowedFFmpegPCMFrame(
            interleaved: nil,
            frameCount: 0,
            sampleRate: 0,
            channels: 0,
            token: 0,
            abiVersion: abiVersion,
            structSize: structSize,
            channelOrder: VPFF_CHANNEL_ORDER_UNSPECIFIED,
            hasChannelLayoutMask: 0,
            reserved: (0, 0, 0),
            channelLayoutMask: 0
        ))
        return
    }
    let value = frame.pointee
    box.receiver(BorrowedFFmpegPCMFrame(
        interleaved: value.interleaved,
        frameCount: value.frame_count,
        sampleRate: value.sample_rate,
        channels: value.channels,
        token: value.pts,
        abiVersion: abiVersion,
        structSize: structSize,
        channelOrder: value.channel_order,
        hasChannelLayoutMask: value.has_channel_layout_mask,
        reserved: value.reserved,
        channelLayoutMask: value.channel_layout_mask
    ))
}

private final class LiveFFmpegAudioDecoderHandle: FFmpegAudioDecoderHandle, @unchecked Sendable {
    private let callbackBox: LiveFFmpegAudioCallbackBox
    private var native: OpaquePointer?

    init(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void,
        hlsCopyOwnership: HLSAudioCopyOwnership? = nil
    ) throws {
        callbackBox = LiveFFmpegAudioCallbackBox(receiver: receiver, ownership: hlsCopyOwnership)
        var created: OpaquePointer?
        let rawCodec: VPFFCodec
        switch codec {
        case .aac: rawCodec = VPFF_CODEC_AAC
        case .ac3: rawCodec = VPFF_CODEC_AC3
        case .eac3: rawCodec = VPFF_CODEC_EAC3
        case .mp2: rawCodec = VPFF_CODEC_MP2
        case .mp1: rawCodec = VPFF_CODEC_MP1
        case .mp3: rawCodec = VPFF_CODEC_MP3
        }
        var admission = VPFFAudioAllocationAdmission()
        admission.context = Unmanaged.passUnretained(callbackBox).toOpaque()
        admission.reserve = liveFFmpegAudioReserve
        admission.release = liveFFmpegAudioRelease
        let result = extradata.withUnsafeBytes { bytes in
            let extradataPointer = bytes.isEmpty
                ? nil
                : bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            if hlsCopyOwnership == nil {
                return vp_ffmpeg_audio_decoder_create(
                    rawCodec, extradataPointer, bytes.count, liveFFmpegAudioCallback,
                    Unmanaged.passUnretained(callbackBox).toOpaque(), nil, &created
                )
            }
            return withUnsafePointer(to: &admission) { admissionPointer in
                vp_ffmpeg_audio_decoder_create(
                    rawCodec, extradataPointer, bytes.count, liveFFmpegAudioCallback,
                    Unmanaged.passUnretained(callbackBox).toOpaque(), admissionPointer, &created
                )
            }
        }
        guard result >= 0, let created else {
            throw PlaybackCoreError.audioFallbackDecode(result)
        }
        native = created
    }

    deinit {
        destroy()
    }

    func push(_ bytes: Data, token: Int64) -> Int32 {
        guard let native else { return FFmpegPCMAudioDecoder.destroyedErrorCode }
        return bytes.withUnsafeBytes { rawBuffer in
            vp_ffmpeg_audio_decoder_push(
                native,
                rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                rawBuffer.count,
                token
            )
        }
    }

    func flush() {
        guard let native else { return }
        vp_ffmpeg_audio_decoder_flush(native)
    }

    func drain() -> Int32 {
        guard let native else { return FFmpegPCMAudioDecoder.destroyedErrorCode }
        return vp_ffmpeg_audio_decoder_drain(native)
    }

    func destroy() {
        guard let native else { return }
        self.native = nil
        vp_ffmpeg_audio_decoder_destroy(native)
    }
}

struct LiveFFmpegAudioDecoderAPI: FFmpegAudioDecoderAPI {
    func create(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        hlsCopyOwnership: HLSAudioCopyOwnership?,
        receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void
    ) throws -> any FFmpegAudioDecoderHandle {
        try LiveFFmpegAudioDecoderHandle(codec: codec, extradata: extradata, receiver: receiver,
                                         hlsCopyOwnership: hlsCopyOwnership)
    }
}

private struct CopiedFFmpegPCMFrame: @unchecked Sendable {
    let bytes: Data
    let frameCount: Int
    let sampleRate: Int32
    let channels: Int32
    let token: Int64
    let channelOrder: PCMChannelOrder
    let channelLayoutMask: UInt64?
    let retainedLease: HLSDataPlaneAdmission.Lease?
}

private final class FFmpegPCMCallbackCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CopiedFFmpegPCMFrame] = []
    private var storedError: PlaybackCoreError?
    private var streamingConsumer: ((CopiedFFmpegPCMFrame) throws -> Void)?
    private let hlsCopyOwnership: HLSAudioCopyOwnership?

    init(hlsCopyOwnership: HLSAudioCopyOwnership? = nil) { self.hlsCopyOwnership = hlsCopyOwnership }

    func receive(_ frame: BorrowedFFmpegPCMFrame) {
        // 准入可阻塞，绝不能持有 collector 锁；否则低余量下 callback 会等待
        // 同一 native push 结束后才可释放的前帧，形成自等待。
        lock.lock(); let accepts = storedError == nil; lock.unlock()
        guard accepts else { return }
        do {
            let copied = try Self.copy(frame, hlsCopyOwnership: hlsCopyOwnership)
            let consumer = lock.withLock { streamingConsumer }
            if let consumer {
                try consumer(copied)
            } else {
                lock.withLock { if storedError == nil { frames.append(copied) } }
            }
        } catch let error as PlaybackCoreError {
            lock.withLock { storedError = error }
        } catch {
            lock.withLock { storedError = .audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode) }
        }
    }

    /// consumer 在同步 native callback 中运行。它必须在返回前完成最终 CMBlock
    /// 的交付，从而释放 pcmData 临时 lease；等待过程不持有 collector 锁。
    func beginStreaming(_ consumer: @escaping (CopiedFFmpegPCMFrame) throws -> Void) {
        lock.withLock {
            precondition(streamingConsumer == nil && frames.isEmpty)
            streamingConsumer = consumer
        }
    }

    func endStreaming() -> PlaybackCoreError? {
        lock.withLock {
            streamingConsumer = nil
            let error = storedError
            storedError = nil
            return error
        }
    }

    func take() -> (frames: [CopiedFFmpegPCMFrame], error: PlaybackCoreError?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (frames, storedError)
        frames.removeAll(keepingCapacity: false)
        storedError = nil
        return result
    }

    private static func copy(_ frame: BorrowedFFmpegPCMFrame, hlsCopyOwnership: HLSAudioCopyOwnership?) throws -> CopiedFFmpegPCMFrame {
        let minimumSize = MemoryLayout<VPFFPCMFrame>.offset(of: \.channel_layout_mask)
            .map { $0 + MemoryLayout<UInt64>.size } ?? Int.max
        guard frame.abiVersion == VPFF_AUDIO_DECODER_ABI_VERSION,
              Int(frame.structSize) >= minimumSize,
              frame.frameCount > 0,
              frame.sampleRate > 0,
              frame.channels > 0,
              frame.token > 0,
              frame.reserved.0 == 0,
              frame.reserved.1 == 0,
              frame.reserved.2 == 0,
              frame.hasChannelLayoutMask <= 1,
              let pointer = frame.interleaved else {
            throw PlaybackCoreError.audioFallbackDecode(
                FFmpegPCMAudioDecoder.invalidCallbackErrorCode
            )
        }
        let channels = Int(frame.channels)
        let (sampleCount, sampleOverflow) = frame.frameCount.multipliedReportingOverflow(by: channels)
        let (byteCount, byteOverflow) = sampleCount.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard !sampleOverflow, !byteOverflow,
              byteCount <= FFmpegPCMAudioDecoder.maximumBytes else {
            throw PlaybackCoreError.audioFallbackDecode(
                FFmpegPCMAudioDecoder.overflowErrorCode
            )
        }
        let order: PCMChannelOrder
        let mask: UInt64?
        if frame.channelOrder == VPFF_CHANNEL_ORDER_NATIVE {
            let supportedMask = (UInt64(1) << 18) - 1
            guard frame.hasChannelLayoutMask == 1,
                  frame.channelLayoutMask != 0,
                  frame.channelLayoutMask & ~supportedMask == 0,
                  frame.channelLayoutMask.nonzeroBitCount == channels else {
                throw PlaybackCoreError.audioFallbackDecode(
                    FFmpegPCMAudioDecoder.invalidCallbackErrorCode
                )
            }
            order = .native
            mask = frame.channelLayoutMask
        } else if frame.channelOrder == VPFF_CHANNEL_ORDER_UNSPECIFIED {
            guard frame.hasChannelLayoutMask == 0,
                  frame.channelLayoutMask == 0,
                  channels <= 64 else {
                throw PlaybackCoreError.audioFallbackDecode(
                    FFmpegPCMAudioDecoder.invalidCallbackErrorCode
                )
            }
            order = .discrete
            mask = nil
        } else {
            throw PlaybackCoreError.audioFallbackDecode(
                FFmpegPCMAudioDecoder.invalidCallbackErrorCode
            )
        }
        let lease = hlsCopyOwnership?.admit(.pcmData, bytes: byteCount)
        guard hlsCopyOwnership == nil || lease != nil else { throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.overflowErrorCode) }
        return CopiedFFmpegPCMFrame(
            bytes: Data(bytes: pointer, count: byteCount),
            frameCount: frame.frameCount,
            sampleRate: frame.sampleRate,
            channels: frame.channels,
            token: frame.token,
            channelOrder: order,
            channelLayoutMask: mask,
            retainedLease: lease
        )
    }
}

final class FFmpegPCMAudioDecoder: PCMAudioDecoding, @unchecked Sendable {
    static let maximumBytes = 64 * 1_024 * 1_024
    // FFmpeg's stable AVERROR_INVALIDDATA value (FFERRTAG('I', 'N', 'D', 'A')).
    static let invalidPacketErrorCode: Int32 = -1_094_995_529
    static let invalidCallbackErrorCode: Int32 = -1_448_339_201
    static let overflowErrorCode: Int32 = -1_448_339_202
    static let tokenCapacityErrorCode: Int32 = -1_448_339_203
    static let tokenExhaustedErrorCode: Int32 = -1_448_339_204
    static let destroyedErrorCode: Int32 = -1_448_339_205

    private struct PendingToken {
        let presentationTimeStamp: CMTime
        var emittedDuration: CMTime
    }

    private enum NativeDestructionState: Equatable {
        case open
        case destroying
        case destroyed
    }

    private let collector: FFmpegPCMCallbackCollector
    private let hlsCopyOwnership: HLSAudioCopyOwnership?
    private var handle: (any FFmpegAudioDecoderHandle)?
    private var nextToken: Int64? = 1
    private var pending: [Int64: PendingToken] = [:]
    private let nativeCondition = NSCondition()
    private var nativeLaneOwner: Thread?
    private var nativeAccessClosed = false
    private var destroyRequested = false
    private var destructionState: NativeDestructionState = .open
    private var drainObservation: FFmpegDrainCancelOrderingObservation?

    convenience init(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        hlsCopyOwnership: HLSAudioCopyOwnership? = nil
    ) throws {
        try self.init(codec: codec, extradata: extradata, api: LiveFFmpegAudioDecoderAPI(), hlsCopyOwnership: hlsCopyOwnership)
    }

    init(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        api: any FFmpegAudioDecoderAPI,
        hlsCopyOwnership: HLSAudioCopyOwnership? = nil
    ) throws {
        let collector = FFmpegPCMCallbackCollector(hlsCopyOwnership: hlsCopyOwnership)
        self.collector = collector
        self.hlsCopyOwnership = hlsCopyOwnership
        handle = try api.create(codec: codec, extradata: extradata, hlsCopyOwnership: hlsCopyOwnership) { frame in
            collector.receive(frame)
        }
    }

    deinit {
        destroy()
    }

    func push(_ sample: CompressedAudioSample) throws -> [CMSampleBuffer] {
        guard beginNativeCall() else { throw PlaybackCoreError.audioFallbackDecode(Self.destroyedErrorCode) }
        defer { endNativeCall() }
        guard let handle else {
            throw PlaybackCoreError.audioFallbackDecode(Self.destroyedErrorCode)
        }
        guard pending.count < 96 else {
            throw PlaybackCoreError.audioFallbackDecode(Self.tokenCapacityErrorCode)
        }
        let (bytes, inputLease) = try Self.compressedBytes(sample.sampleBuffer, ownership: hlsCopyOwnership)
        defer { inputLease?.release() }
        guard sample.presentationTimeStamp.isNumeric,
              let token = nextToken,
              token > 0 else {
            throw PlaybackCoreError.audioFallbackDecode(Self.tokenExhaustedErrorCode)
        }
        nextToken = token == Int64.max ? nil : token + 1
        pending[token] = PendingToken(
            presentationTimeStamp: sample.presentationTimeStamp,
            emittedDuration: .zero
        )
        let result = handle.push(bytes, token: token)
        let callbacks = collector.take()
        if let error = callbacks.error {
            pending.removeValue(forKey: token)
            throw error
        }
        guard result >= 0 else {
            pending.removeValue(forKey: token)
            throw PlaybackCoreError.audioFallbackDecode(result)
        }

        var outputs: [CMSampleBuffer] = []
        var emittedTokens = Set<Int64>()
        for callback in callbacks.frames {
            guard var state = pending[callback.token] else {
                throw PlaybackCoreError.audioFallbackDecode(Self.invalidCallbackErrorCode)
            }
            let pts = state.emittedDuration == .zero
                ? state.presentationTimeStamp
                : CMTimeAdd(state.presentationTimeStamp, state.emittedDuration)
            guard pts.isNumeric,
                  let frameValue = CMTimeValue(exactly: callback.frameCount),
                  callback.sampleRate > 0 else {
                throw PlaybackCoreError.audioFallbackDecode(Self.overflowErrorCode)
            }
            let duration = CMTime(value: frameValue, timescale: callback.sampleRate)
            let accumulated = CMTimeAdd(state.emittedDuration, duration)
            guard accumulated.isNumeric else {
                throw PlaybackCoreError.audioFallbackDecode(Self.overflowErrorCode)
            }
            outputs.append(try PCMSampleBufferBuilder.make(
                bytes: callback.bytes,
                frameCount: callback.frameCount,
                sampleRate: callback.sampleRate,
                channels: callback.channels,
                channelOrder: callback.channelOrder,
                channelLayoutMask: callback.channelLayoutMask,
                presentationTimeStamp: pts,
                hlsCopyOwnership: hlsCopyOwnership,
                pcmLease: callback.retainedLease
            ))
            state.emittedDuration = accumulated
            pending[callback.token] = state
            emittedTokens.insert(callback.token)
        }
        for emittedToken in emittedTokens { pending.removeValue(forKey: emittedToken) }
        // receive callback 不能证明 token 已终结：解码器可在后续 packet 或 EOF
        // 继续为同一 opaque token 输出帧。仅 flush/destroy/真实 EOF 清理。
        return outputs
    }

    /// HLS 专用入口在同步 callback 内完成最终 CMBlock；普通 `push` 的收集语义不变。
    /// 真实 HLS 分支使用此交付入口：consumer 在 callback 内决定是否保留 sample。
    /// 因而单帧预算下能在下一 native callback 前归还上一帧的最终 block lease。
    func pushStreamingForHLS(_ sample: CompressedAudioSample,
                             consumer: @escaping (CMSampleBuffer) throws -> Void) throws {
        guard hlsCopyOwnership != nil else {
            for output in try push(sample) { try consumer(output) }
            return
        }
        guard beginNativeCall() else { throw PlaybackCoreError.audioFallbackDecode(Self.destroyedErrorCode) }
        defer { endNativeCall() }
        guard let handle else { throw PlaybackCoreError.audioFallbackDecode(Self.destroyedErrorCode) }
        guard pending.count < 96 else { throw PlaybackCoreError.audioFallbackDecode(Self.tokenCapacityErrorCode) }
        let (bytes, inputLease) = try Self.compressedBytes(sample.sampleBuffer, ownership: hlsCopyOwnership)
        defer { inputLease?.release() }
        guard sample.presentationTimeStamp.isNumeric, let token = nextToken, token > 0 else {
            throw PlaybackCoreError.audioFallbackDecode(Self.tokenExhaustedErrorCode)
        }
        nextToken = token == Int64.max ? nil : token + 1
        pending[token] = PendingToken(presentationTimeStamp: sample.presentationTimeStamp, emittedDuration: .zero)
        var emittedTokens = Set<Int64>()
        collector.beginStreaming { [self] callback in
            guard var state = pending[callback.token] else {
                throw PlaybackCoreError.audioFallbackDecode(Self.invalidCallbackErrorCode)
            }
            let output = try makeOutput(callback, state: &state)
            pending[callback.token] = state
            emittedTokens.insert(callback.token)
            try consumer(output)
        }
        let result = handle.push(bytes, token: token)
        if let error = collector.endStreaming() {
            pending.removeValue(forKey: token)
            throw error
        }
        guard result >= 0 else {
            pending.removeValue(forKey: token)
            throw PlaybackCoreError.audioFallbackDecode(result)
        }
        for emittedToken in emittedTokens { pending.removeValue(forKey: emittedToken) }
        return
    }

    func drainForNaturalEOF() throws -> [CMSampleBuffer] {
        guard beginNativeCall() else { throw PlaybackCoreError.audioFallbackDecode(Self.destroyedErrorCode) }
        defer { drainObservation?.nativeDrainReturned(); endNativeCall() }
        guard let handle else { throw PlaybackCoreError.audioFallbackDecode(Self.destroyedErrorCode) }
        let result = handle.drain()
        let callbacks = collector.take()
        if let error = callbacks.error { throw error }
        guard result == -541_478_725 else { throw PlaybackCoreError.audioFallbackDecode(result) }
        var outputs: [CMSampleBuffer] = []
        for callback in callbacks.frames {
            guard var state = pending[callback.token] else {
                throw PlaybackCoreError.audioFallbackDecode(Self.invalidCallbackErrorCode)
            }
            let pts = CMTimeAdd(state.presentationTimeStamp, state.emittedDuration)
            guard let value = CMTimeValue(exactly: callback.frameCount), callback.sampleRate > 0 else {
                throw PlaybackCoreError.audioFallbackDecode(Self.overflowErrorCode)
            }
            let duration = CMTime(value: value, timescale: callback.sampleRate)
            outputs.append(try PCMSampleBufferBuilder.make(bytes: callback.bytes, frameCount: callback.frameCount,
                sampleRate: callback.sampleRate, channels: callback.channels, channelOrder: callback.channelOrder,
                channelLayoutMask: callback.channelLayoutMask, presentationTimeStamp: pts,
                hlsCopyOwnership: hlsCopyOwnership, pcmLease: callback.retainedLease))
            state.emittedDuration = CMTimeAdd(state.emittedDuration, duration)
            pending[callback.token] = state
        }
        pending.removeAll(keepingCapacity: false)
        return outputs
    }

    func flush() {
        guard beginNativeCall() else { return }
        defer { endNativeCall() }
        handle?.flush()
        pending.removeAll(keepingCapacity: false)
        _ = collector.take()
    }

    func destroy() {
        closeNativeAccessAndDestroy()
    }

    private func destroyClosedHandle() {
        defer { markNativeDestroyCompleted() }
        guard let handle else { return }
        self.handle = nil
        handle.destroy()
        drainObservation?.nativeDestroyed()
        pending.removeAll(keepingCapacity: false)
        _ = collector.take()
    }

    private func markNativeDestroyCompleted() {
        nativeCondition.lock()
        precondition(destructionState == .destroying, "native destroy 完成状态不匹配")
        destructionState = .destroyed
        nativeCondition.broadcast()
        nativeCondition.unlock()
    }

    func cancelHLSAdmission() {
        hlsCopyOwnership?.cancel()
        closeNativeAccessAndDestroy()
    }

    /// cancel/destroy 不持有 native lane 或 condition 锁等待 native destroy。关闭先发生，
    /// 故等待者会因 admission cancel 或 accessClosed 醒来；非 lane-owner close 会等到
    /// 真实 destroy 已返回，避免把「已开始 teardown」误报为「teardown 已完成」。
    private func closeNativeAccessAndDestroy() {
        nativeCondition.lock()
        nativeAccessClosed = true
        destroyRequested = true
        nativeCondition.broadcast()
        if nativeLaneOwner === Thread.current {
            nativeCondition.unlock()
            return
        }
        while nativeLaneOwner != nil { nativeCondition.wait() }
        switch destructionState {
        case .destroyed:
            nativeCondition.unlock()
            return
        case .destroying:
            while destructionState == .destroying { nativeCondition.wait() }
            nativeCondition.unlock()
            return
        case .open:
            destructionState = .destroying
        }
        nativeCondition.unlock()
        destroyClosedHandle()
    }

    func debugDrainCancelOrderingProbe() -> FFmpegDrainCancelOrderingObservation {
        let observation = FFmpegDrainCancelOrderingObservation()
        drainObservation = observation
        hlsCopyOwnership?.observeDrain(observation)
        return observation
    }

    private func beginNativeCall() -> Bool {
        nativeCondition.lock()
        // 同步 C callback/consumer 若重入 decoder，不能在自身 lane 上无限自锁，也
        // 绝不能递归进入同一 AVCodecContext；将其作为受控 destroyed-style rejection。
        guard nativeLaneOwner !== Thread.current else { nativeCondition.unlock(); return false }
        while nativeLaneOwner != nil && !nativeAccessClosed { nativeCondition.wait() }
        guard !nativeAccessClosed else { nativeCondition.unlock(); return false }
        nativeLaneOwner = Thread.current
        nativeCondition.unlock()
        return true
    }

    private func endNativeCall() {
        nativeCondition.lock()
        precondition(nativeLaneOwner === Thread.current, "native lane owner 不匹配")
        nativeLaneOwner = nil
        let shouldDestroy = destroyRequested && destructionState == .open
        if shouldDestroy { destructionState = .destroying }
        nativeCondition.broadcast()
        nativeCondition.unlock()
        if shouldDestroy { destroyClosedHandle() }
    }

    private func makeOutput(_ callback: CopiedFFmpegPCMFrame,
                            state: inout PendingToken) throws -> CMSampleBuffer {
        let pts = CMTimeAdd(state.presentationTimeStamp, state.emittedDuration)
        guard pts.isNumeric,
              let value = CMTimeValue(exactly: callback.frameCount),
              callback.sampleRate > 0 else {
            throw PlaybackCoreError.audioFallbackDecode(Self.overflowErrorCode)
        }
        let duration = CMTime(value: value, timescale: callback.sampleRate)
        let accumulated = CMTimeAdd(state.emittedDuration, duration)
        guard accumulated.isNumeric else { throw PlaybackCoreError.audioFallbackDecode(Self.overflowErrorCode) }
        let output = try PCMSampleBufferBuilder.make(
            bytes: callback.bytes, frameCount: callback.frameCount, sampleRate: callback.sampleRate,
            channels: callback.channels, channelOrder: callback.channelOrder,
            channelLayoutMask: callback.channelLayoutMask, presentationTimeStamp: pts,
            hlsCopyOwnership: hlsCopyOwnership, pcmLease: callback.retainedLease
        )
        state.emittedDuration = accumulated
        return output
    }

    private static func compressedBytes(_ sample: CMSampleBuffer,
                                        ownership: HLSAudioCopyOwnership?) throws -> (Data, HLSDataPlaneAdmission.Lease?) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw PlaybackCoreError.audioFallbackDecode(invalidCallbackErrorCode)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= maximumBytes else {
            throw PlaybackCoreError.audioFallbackDecode(overflowErrorCode)
        }
        let lease = ownership?.admit(.compressedInput, bytes: length)
        guard ownership == nil || lease != nil else { throw PlaybackCoreError.audioFallbackDecode(overflowErrorCode) }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { destination in
            guard let address = destination.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: address
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw PlaybackCoreError.audioFallbackDecode(status)
        }
        return (data, lease)
    }
}

struct LivePCMAudioDecoderFactory: PCMAudioDecoderFactory {
    let hlsCopyOwnership: HLSAudioCopyOwnership?

    init(hlsCopyOwnership: HLSAudioCopyOwnership? = nil) {
        self.hlsCopyOwnership = hlsCopyOwnership
    }
    func makeDecoder(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data
    ) throws -> any PCMAudioDecoding {
        try FFmpegPCMAudioDecoder(codec: codec, extradata: extradata,
                                  hlsCopyOwnership: hlsCopyOwnership)
    }
}

enum PCMChannelOrder: Sendable, Equatable {
    case native
    case discrete
}

enum PCMSampleBufferBuilder {
    static func make(
        bytes: Data,
        frameCount: Int,
        sampleRate: Int32,
        channels: Int32,
        channelOrder: PCMChannelOrder,
        channelLayoutMask: UInt64?,
        presentationTimeStamp: CMTime,
        hlsCopyOwnership: HLSAudioCopyOwnership? = nil,
        pcmLease: HLSDataPlaneAdmission.Lease? = nil
    ) throws -> CMSampleBuffer {
        guard frameCount > 0, sampleRate > 0, channels > 0,
              presentationTimeStamp.isNumeric,
              let channelCount = UInt32(exactly: channels),
              let sampleCount = CMItemCount(exactly: frameCount) else {
            throw PlaybackCoreError.audioFallbackDecode(
                FFmpegPCMAudioDecoder.invalidCallbackErrorCode
            )
        }
        let (bytesPerFrameInt, frameOverflow) = Int(channels).multipliedReportingOverflow(by: 4)
        let (byteCount, byteOverflow) = frameCount.multipliedReportingOverflow(by: bytesPerFrameInt)
        guard !frameOverflow, !byteOverflow,
              bytesPerFrameInt <= Int(UInt32.max),
              bytes.count == byteCount,
              byteCount <= FFmpegPCMAudioDecoder.maximumBytes else {
            throw PlaybackCoreError.audioFallbackDecode(
                FFmpegPCMAudioDecoder.overflowErrorCode
            )
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(bytesPerFrameInt),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrameInt),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = try makeLayout(
            channels: channelCount,
            order: channelOrder,
            mask: channelLayoutMask
        )
        var format: CMAudioFormatDescription?
        let formatStatus = withUnsafePointer(to: &layout) { layoutPointer in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: MemoryLayout<AudioToolbox.AudioChannelLayout>.size,
                layout: layoutPointer,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        guard formatStatus == noErr, let format else {
            throw PlaybackCoreError.audioFormatDescription(formatStatus)
        }

        let finalLease = hlsCopyOwnership?.admit(.cmBlock, bytes: byteCount)
        guard hlsCopyOwnership == nil || finalLease != nil else {
            throw PlaybackCoreError.audioFallbackDecode(FFmpegPCMAudioDecoder.overflowErrorCode)
        }
        let blockContext = PCMBlockLeaseContext(finalLease)
        let refCon = Unmanaged.passRetained(blockContext).toOpaque()
        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: pcmBlockAllocate,
            FreeBlock: pcmBlockFree,
            refCon: refCon
        )
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            Unmanaged<PCMBlockLeaseContext>.fromOpaque(refCon).release()
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        status = bytes.withUnsafeBytes { source in
            guard let address = source.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: address,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: sampleCount,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw PlaybackCoreError.audioFormatDescription(status)
        }
        // Data 的临时 backing 只需活到 CMBlock 完成真正拷贝；最终 lease 由
        // custom FreeBlock 绑定到最后一个 CMBlock/CMSampleBuffer alias。
        pcmLease?.release()
        return sampleBuffer
    }

    private static func makeLayout(
        channels: UInt32,
        order: PCMChannelOrder,
        mask: UInt64?
    ) throws -> AudioToolbox.AudioChannelLayout {
        switch order {
        case .native:
            let supported = (UInt64(1) << 18) - 1
            guard let mask,
                  mask != 0,
                  mask & ~supported == 0,
                  mask.nonzeroBitCount == Int(channels),
                  let bitmap = UInt32(exactly: mask) else {
                throw PlaybackCoreError.audioFallbackDecode(
                    FFmpegPCMAudioDecoder.invalidCallbackErrorCode
                )
            }
            // AVSampleBufferAudioRenderer's tvOS 18 time-stretching unit
            // repeatedly rejects a bitmap layout for the standard stereo pair.
            // A named tag carries the same channel order without provoking a
            // per-buffer kAudioUnitProperty_ChannelLayout retry.
            if channels == 2, mask == 0b11 {
                return AudioToolbox.AudioChannelLayout(
                    mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                    mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                    mNumberChannelDescriptions: 0,
                    mChannelDescriptions: (AudioChannelDescription(),)
                )
            }
            return AudioToolbox.AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_UseChannelBitmap,
                mChannelBitmap: AudioChannelBitmap(rawValue: bitmap),
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: (AudioChannelDescription(),)
            )
        case .discrete:
            guard mask == nil, channels <= 64 else {
                throw PlaybackCoreError.audioFallbackDecode(
                    FFmpegPCMAudioDecoder.invalidCallbackErrorCode
                )
            }
            return AudioToolbox.AudioChannelLayout(
                mChannelLayoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels,
                mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: (AudioChannelDescription(),)
            )
        }
    }
}

private final class PCMBlockLeaseContext {
    private let lock = NSLock()
    private var claimed = false
    private var lease: HLSDataPlaneAdmission.Lease?
    init(_ lease: HLSDataPlaneAdmission.Lease?) { self.lease = lease }
    func claim() -> Bool { lock.withLock { guard !claimed else { return false }; claimed = true; return true } }
    func release() { lease?.release(); lease = nil }
}

private func pcmBlockAllocate(_ refCon: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    guard refCon != nil, size > 0 else { return nil }
    return malloc(size)
}

private func pcmBlockFree(_ refCon: UnsafeMutableRawPointer?, _ block: UnsafeMutableRawPointer, _: Int) {
    guard let refCon else { free(block); return }
    let context = Unmanaged<PCMBlockLeaseContext>.fromOpaque(refCon).takeUnretainedValue()
    guard context.claim() else { return }
    let retained = Unmanaged<PCMBlockLeaseContext>.fromOpaque(refCon).takeRetainedValue()
    free(block)
    retained.release()
}
