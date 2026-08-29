// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation

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
    func flush()
    func destroy()
}

protocol FFmpegAudioDecoderAPI: Sendable {
    func create(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void
    ) throws -> any FFmpegAudioDecoderHandle
}

private final class LiveFFmpegAudioCallbackBox: @unchecked Sendable {
    let receiver: @Sendable (BorrowedFFmpegPCMFrame) -> Void
    init(receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void) {
        self.receiver = receiver
    }
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
        receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void
    ) throws {
        callbackBox = LiveFFmpegAudioCallbackBox(receiver: receiver)
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
        let result = extradata.withUnsafeBytes { bytes in
            let extradataPointer = bytes.isEmpty
                ? nil
                : bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return vp_ffmpeg_audio_decoder_create(
                rawCodec,
                extradataPointer,
                bytes.count,
                liveFFmpegAudioCallback,
                Unmanaged.passUnretained(callbackBox).toOpaque(),
                &created
            )
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
        receiver: @escaping @Sendable (BorrowedFFmpegPCMFrame) -> Void
    ) throws -> any FFmpegAudioDecoderHandle {
        try LiveFFmpegAudioDecoderHandle(codec: codec, extradata: extradata, receiver: receiver)
    }
}

private struct CopiedFFmpegPCMFrame: Sendable {
    let bytes: Data
    let frameCount: Int
    let sampleRate: Int32
    let channels: Int32
    let token: Int64
    let channelOrder: PCMChannelOrder
    let channelLayoutMask: UInt64?
}

private final class FFmpegPCMCallbackCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CopiedFFmpegPCMFrame] = []
    private var storedError: PlaybackCoreError?

    func receive(_ frame: BorrowedFFmpegPCMFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard storedError == nil else { return }
        do {
            frames.append(try Self.copy(frame))
        } catch let error as PlaybackCoreError {
            storedError = error
        } catch {
            storedError = .audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)
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

    private static func copy(_ frame: BorrowedFFmpegPCMFrame) throws -> CopiedFFmpegPCMFrame {
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
        return CopiedFFmpegPCMFrame(
            bytes: Data(bytes: pointer, count: byteCount),
            frameCount: frame.frameCount,
            sampleRate: frame.sampleRate,
            channels: frame.channels,
            token: frame.token,
            channelOrder: order,
            channelLayoutMask: mask
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

    private let collector: FFmpegPCMCallbackCollector
    private var handle: (any FFmpegAudioDecoderHandle)?
    private var nextToken: Int64? = 1
    private var pending: [Int64: PendingToken] = [:]

    convenience init(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data
    ) throws {
        try self.init(codec: codec, extradata: extradata, api: LiveFFmpegAudioDecoderAPI())
    }

    init(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        api: any FFmpegAudioDecoderAPI
    ) throws {
        let collector = FFmpegPCMCallbackCollector()
        self.collector = collector
        handle = try api.create(codec: codec, extradata: extradata) { frame in
            collector.receive(frame)
        }
    }

    deinit {
        destroy()
    }

    func push(_ sample: CompressedAudioSample) throws -> [CMSampleBuffer] {
        guard let handle else {
            throw PlaybackCoreError.audioFallbackDecode(Self.destroyedErrorCode)
        }
        guard pending.count < 96 else {
            throw PlaybackCoreError.audioFallbackDecode(Self.tokenCapacityErrorCode)
        }
        let bytes = try Self.compressedBytes(sample.sampleBuffer)
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
                presentationTimeStamp: pts
            ))
            state.emittedDuration = accumulated
            pending[callback.token] = state
            emittedTokens.insert(callback.token)
        }
        for emittedToken in emittedTokens {
            pending.removeValue(forKey: emittedToken)
        }
        return outputs
    }

    func flush() {
        handle?.flush()
        pending.removeAll(keepingCapacity: false)
        _ = collector.take()
    }

    func destroy() {
        guard let handle else { return }
        self.handle = nil
        handle.destroy()
        pending.removeAll(keepingCapacity: false)
        _ = collector.take()
    }

    private static func compressedBytes(_ sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw PlaybackCoreError.audioFallbackDecode(invalidCallbackErrorCode)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= maximumBytes else {
            throw PlaybackCoreError.audioFallbackDecode(overflowErrorCode)
        }
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
        return data
    }
}

struct LivePCMAudioDecoderFactory: PCMAudioDecoderFactory {
    func makeDecoder(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data
    ) throws -> any PCMAudioDecoding {
        try FFmpegPCMAudioDecoder(codec: codec, extradata: extradata)
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
        presentationTimeStamp: CMTime
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

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
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
