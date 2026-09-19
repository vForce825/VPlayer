// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation

struct FFmpegParserConfiguration {
    let codec: MediaCodec
    let timeBase: MediaRational
    let sampleRate: Int32
    let channelLayout: AudioChannelLayout?
    let extradata: Data

    init(video: VideoTrackDescriptor) {
        codec = .video(video.codec)
        timeBase = video.timeBase
        sampleRate = 0
        channelLayout = nil
        extradata = video.extradata
    }

    init(audio: AudioTrackDescriptor) {
        codec = .audio(audio.codec)
        timeBase = audio.timeBase
        sampleRate = audio.sampleRate
        channelLayout = audio.channelLayout
        extradata = audio.extradata
    }
}

struct FFmpegParsedFrame {
    private let storedBytes: Data
    let pts: Int64?
    let dts: Int64?
    let duration: CMTime
    let fieldOrder: Int32
    let pictureStructure: Int32
    let keyFrame: Bool?
    let repeatPicture: Bool
    let topFieldFirst: Bool?
    let interlaced: Bool?
    let sampleRate: Int32
    let channels: Int32
    let frameSamples: Int32
    let channelLayout: AudioChannelLayout?
    private let frameReservation: FFmpegParserFrameReservation?

    init(
        bytes: Data,
        pts: Int64?,
        dts: Int64?,
        duration: CMTime,
        fieldOrder: Int32,
        pictureStructure: Int32,
        keyFrame: Bool?,
        repeatPicture: Bool,
        topFieldFirst: Bool?,
        interlaced: Bool?,
        sampleRate: Int32,
        channels: Int32,
        frameSamples: Int32,
        channelLayout: AudioChannelLayout?
    ) {
        self.init(
            bytes: bytes,
            pts: pts,
            dts: dts,
            duration: duration,
            fieldOrder: fieldOrder,
            pictureStructure: pictureStructure,
            keyFrame: keyFrame,
            repeatPicture: repeatPicture,
            topFieldFirst: topFieldFirst,
            interlaced: interlaced,
            sampleRate: sampleRate,
            channels: channels,
            frameSamples: frameSamples,
            channelLayout: channelLayout,
            frameReservation: nil
        )
    }

    fileprivate init(
        bytes: Data,
        pts: Int64?,
        dts: Int64?,
        duration: CMTime,
        fieldOrder: Int32,
        pictureStructure: Int32,
        keyFrame: Bool?,
        repeatPicture: Bool,
        topFieldFirst: Bool?,
        interlaced: Bool?,
        sampleRate: Int32,
        channels: Int32,
        frameSamples: Int32,
        channelLayout: AudioChannelLayout?,
        frameReservation: FFmpegParserFrameReservation?
    ) {
        storedBytes = bytes
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.fieldOrder = fieldOrder
        self.pictureStructure = pictureStructure
        self.keyFrame = keyFrame
        self.repeatPicture = repeatPicture
        self.topFieldFirst = topFieldFirst
        self.interlaced = interlaced
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameSamples = frameSamples
        self.channelLayout = channelLayout
        self.frameReservation = frameReservation
    }

    func withBorrowedBytes<Result>(
        _ body: (borrowing Span<UInt8>) throws -> Result
    ) rethrows -> Result {
        return try body(storedBytes.span)
    }

    func makeVideoBacking(identity: VideoAccessUnitBackingIdentity) throws -> VideoAccessUnitBacking {
        try VideoAccessUnitBacking(
            identity: identity,
            bytes: storedBytes,
            parserFrameReservation: frameReservation
        )
    }

    /// 尚未接入 HLS paid factory 的传统音频 framing 消费点。若未来给音频 parser
    /// 注入 copy admission，必须先迁移为能持有 reservation 的音频 backing。
    func legacyUnadmittedBytes() -> Data {
        precondition(frameReservation == nil,
                     "HLS parser frame 不可作为裸音频 Data 交付")
        return storedBytes
    }
}

/// 仅 parser callback 建立的不可见所有者：Data 的底层可被值语义别名，故把费用
/// 绑定到没有裸 Data getter 的 frame，而不是给 struct 外壳附一个可绕开的 tail。
fileprivate final class FFmpegParserFrameReservation: @unchecked Sendable {
    let lease: HLSDataPlaneAdmission.Lease

    init(lease: HLSDataPlaneAdmission.Lease) { self.lease = lease }
}

private final class FFmpegParserNativeAllocationBridge: @unchecked Sendable {
    let admission: FFmpegParserCopyAdmission
    let codec: MediaCodec

    init(admission: FFmpegParserCopyAdmission, codec: MediaCodec) {
        self.admission = admission
        self.codec = codec
    }
}

/// HLS 注入的 parser native/borrowed-copy 准入。一个实例对应一个可取消生产域，
/// 所有费用仍进入调用方传入的同一 application ledger。
final class FFmpegParserCopyAdmission: @unchecked Sendable {
    private let admission: HLSDataPlaneAdmission
    private let lock = NSLock()
    private var failure: Error?

    /// 每个 parser 拥有专属 local admission；全局费用仍写入调用方传入的同一 ledger。
    /// 这样 cancel 的 broadcast 不能误伤其它 parser/producer。
    init(
        capacity: Int,
        maximumBytes: Int,
        applicationLedger: HLSDeliveryApplicationChargeLedger
    ) {
        admission = HLSDataPlaneAdmission(
            capacity: capacity,
            maximumBytes: maximumBytes,
            applicationLedger: applicationLedger
        )
    }

    func reserve(bytes: Int, codec: MediaCodec) -> UnsafeMutableRawPointer? {
        guard bytes >= 0 else {
            recordFailure(LiveFFmpegParserHandle.error(for: codec,
                                                        code: LiveFFmpegParserHandle.malformedFrameErrorCode))
            return nil
        }
        guard let lease = admission.waitForAdmission(bytes: bytes) else {
            recordFailure(LiveFFmpegParserHandle.error(for: codec,
                                                        code: LiveFFmpegParserHandle.malformedFrameErrorCode))
            return nil
        }
        return Unmanaged.passRetained(FFmpegParserFrameReservation(lease: lease)).toOpaque()
    }

    func release(_ token: UnsafeMutableRawPointer?) {
        guard let token else { return }
        Unmanaged<FFmpegParserFrameReservation>.fromOpaque(token).release()
    }

    func takeFailure() -> Error? { lock.withLock { defer { failure = nil }; return failure } }

    func cancel() { admission.cancel() }

#if DEBUG
    var waitingCount: Int { admission.waitingCount }
#endif

    private func recordFailure(_ error: Error) { lock.withLock { failure = error } }
}

/// factory 保存的是不可变配置而不是可取消 admission 实例；每个 native parser 都须有
/// 独立 cancel 域，重建或多轨不能复用已取消对象。
struct FFmpegParserCopyAdmissionConfiguration {
    let capacity: Int
    let maximumBytes: Int
    let applicationLedger: HLSDeliveryApplicationChargeLedger

    func makeAdmission() -> FFmpegParserCopyAdmission {
        FFmpegParserCopyAdmission(
            capacity: capacity,
            maximumBytes: maximumBytes,
            applicationLedger: applicationLedger
        )
    }
}

protocol FFmpegParserHandle: AnyObject {
    func push(
        _ bytes: Data,
        pts: Int64?,
        dts: Int64?,
        duration: Int64?
    ) throws
    func drain() throws
    func destroy()
}

protocol FFmpegParserFactory {
    func makeParser(
        configuration: FFmpegParserConfiguration,
        receiver: @escaping (FFmpegParsedFrame) throws -> Void
    ) throws -> any FFmpegParserHandle
}

struct LiveFFmpegParserFactory: FFmpegParserFactory {
    let copyAdmissionConfiguration: FFmpegParserCopyAdmissionConfiguration?

    init(copyAdmissionConfiguration: FFmpegParserCopyAdmissionConfiguration? = nil) {
        self.copyAdmissionConfiguration = copyAdmissionConfiguration
    }

    func makeParser(
        configuration: FFmpegParserConfiguration,
        receiver: @escaping (FFmpegParsedFrame) throws -> Void
    ) throws -> any FFmpegParserHandle {
        try LiveFFmpegParserHandle(
            configuration: configuration,
            copyAdmission: copyAdmissionConfiguration?.makeAdmission(),
            receiver: receiver
        )
    }
}

final class LiveFFmpegParserHandle: FFmpegParserHandle {
    static let malformedFrameErrorCode: Int32 = -1_448_143_363
    private static let maximumFrameBytes = 64 * 1_024 * 1_024

    private var native: OpaquePointer?
    private let codec: MediaCodec
    private let receiver: (FFmpegParsedFrame) throws -> Void
    private let copyAdmission: FFmpegParserCopyAdmission?
    private let nativeAllocationBridge: FFmpegParserNativeAllocationBridge?
    private let nativeCallLock = NSRecursiveLock()
    private var nativeCallInProgress = false
    private var destroyRequested = false
    private var callbackFailure: Error?

    init(
        configuration: FFmpegParserConfiguration,
        copyAdmission: FFmpegParserCopyAdmission? = nil,
        receiver: @escaping (FFmpegParsedFrame) throws -> Void
    ) throws {
        codec = configuration.codec
        self.receiver = receiver
        self.copyAdmission = copyAdmission
        nativeAllocationBridge = copyAdmission.map {
            FFmpegParserNativeAllocationBridge(admission: $0, codec: configuration.codec)
        }
        var rawConfiguration = VPFFParserConfigV1()
        rawConfiguration.abi_version = 1
        rawConfiguration.struct_size = UInt32(MemoryLayout<VPFFParserConfigV1>.stride)
        rawConfiguration.codec = try Self.rawCodec(configuration.codec)
        rawConfiguration.time_base_num = configuration.timeBase.num
        rawConfiguration.time_base_den = configuration.timeBase.den
        rawConfiguration.sample_rate = configuration.sampleRate
        if let layout = configuration.channelLayout {
            rawConfiguration.channel_count = layout.channelCount
            if let mask = layout.nativeMask {
                rawConfiguration.channel_order = VPFF_CHANNEL_ORDER_NATIVE
                rawConfiguration.has_channel_layout_mask = 1
                rawConfiguration.channel_layout_mask = mask
            } else {
                rawConfiguration.channel_order = VPFF_CHANNEL_ORDER_UNSPECIFIED
            }
        } else {
            rawConfiguration.channel_order = VPFF_CHANNEL_ORDER_UNSPECIFIED
        }

        let status = configuration.extradata.withUnsafeBytes { rawBuffer in
            rawConfiguration.extradata = rawBuffer.isEmpty
                ? nil
                : rawBuffer.bindMemory(to: UInt8.self).baseAddress
            rawConfiguration.extradata_size = rawBuffer.count
            if let nativeAllocationBridge {
                var v2 = VPFFParserConfigV2()
                v2.abi_version = VPFF_PARSER_ABI_VERSION_V2
                v2.struct_size = UInt32(MemoryLayout<VPFFParserConfigV2>.stride)
                v2.codec = rawConfiguration.codec
                v2.time_base_num = rawConfiguration.time_base_num
                v2.time_base_den = rawConfiguration.time_base_den
                v2.sample_rate = rawConfiguration.sample_rate
                v2.channel_count = rawConfiguration.channel_count
                v2.channel_order = rawConfiguration.channel_order
                v2.has_channel_layout_mask = rawConfiguration.has_channel_layout_mask
                v2.channel_layout_mask = rawConfiguration.channel_layout_mask
                v2.extradata = rawConfiguration.extradata
                v2.extradata_size = rawConfiguration.extradata_size
                v2.allocation_callbacks.reserve = liveFFmpegParserReserveNativeAllocation
                v2.allocation_callbacks.release = liveFFmpegParserReleaseNativeAllocation
                v2.allocation_callbacks.context = Unmanaged.passUnretained(nativeAllocationBridge).toOpaque()
                return vp_ffmpeg_parser_create_v2(
                    &v2,
                    liveFFmpegParserCallback,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &native
                )
            }
            return vp_ffmpeg_parser_create_v1(&rawConfiguration, liveFFmpegParserCallback,
                                              Unmanaged.passUnretained(self).toOpaque(), &native)
        }
        if let callbackFailure = copyAdmission?.takeFailure() { throw callbackFailure }
        guard status >= 0, native != nil else {
            throw Self.error(for: configuration.codec, code: status)
        }
    }

    deinit {
        destroy()
    }

    func push(
        _ bytes: Data,
        pts: Int64?,
        dts: Int64?,
        duration: Int64?
    ) throws {
        guard !bytes.isEmpty,
              pts != Int64.min,
              dts != Int64.min,
              duration != Int64.min else {
            throw Self.error(for: codec, code: Self.malformedFrameErrorCode)
        }
        let outcome: (status: Int32, callbackFailure: Error?, admissionFailure: Error?) = try nativeCallLock.withLock {
            guard !nativeCallInProgress, let native else {
                throw Self.error(for: codec, code: Self.malformedFrameErrorCode)
            }
            callbackFailure = nil
            nativeCallInProgress = true
            defer {
                nativeCallInProgress = false
                destroyIfRequestedWhileLocked()
            }
            let status = bytes.withUnsafeBytes { rawBuffer in
                vp_ffmpeg_parser_push(
                    native,
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                    rawBuffer.count,
                    pts ?? Int64.min,
                    dts ?? Int64.min,
                    duration ?? Int64.min
                )
            }
            return (status, callbackFailure, copyAdmission?.takeFailure())
        }
        if let callbackFailure = outcome.callbackFailure {
            throw callbackFailure
        }
        if let admissionFailure = outcome.admissionFailure { throw admissionFailure }
        guard outcome.status >= 0 else {
            throw Self.error(for: codec, code: outcome.status)
        }
    }

    func drain() throws {
        let outcome: (status: Int32, callbackFailure: Error?, admissionFailure: Error?)? = nativeCallLock.withLock {
            guard !nativeCallInProgress else {
                let nestedCallError = Self.error(for: codec, code: Self.malformedFrameErrorCode)
                return (Self.malformedFrameErrorCode, nestedCallError, nil)
            }
            guard let native else { return nil }
            callbackFailure = nil
            nativeCallInProgress = true
            defer {
                nativeCallInProgress = false
                destroyIfRequestedWhileLocked()
            }
            let status = vp_ffmpeg_parser_drain(native)
            return (status, callbackFailure, copyAdmission?.takeFailure())
        }
        guard let outcome else { return }
        if let callbackFailure = outcome.callbackFailure {
            throw callbackFailure
        }
        if let admissionFailure = outcome.admissionFailure { throw admissionFailure }
        guard outcome.status >= 0 else {
            throw Self.error(for: codec, code: outcome.status)
        }
    }

    func destroy() {
        copyAdmission?.cancel()
        nativeCallLock.withLock {
            if nativeCallInProgress {
                destroyRequested = true
            } else {
                destroyNativeWhileLocked()
            }
        }
    }

    private func destroyIfRequestedWhileLocked() {
        guard destroyRequested else { return }
        destroyRequested = false
        destroyNativeWhileLocked()
    }

    private func destroyNativeWhileLocked() {
        guard let native else { return }
        vp_ffmpeg_parser_destroy(native)
        self.native = nil
    }

    fileprivate func receive(_ pointer: UnsafePointer<VPFFParsedFrame>?) {
        guard callbackFailure == nil, !destroyRequested else { return }
        do {
            let frame = try Self.copy(pointer, codec: codec, copyAdmission: copyAdmission)
            try receiver(frame)
        } catch {
            callbackFailure = error
        }
    }

    private static func copy(
        _ pointer: UnsafePointer<VPFFParsedFrame>?,
        codec: MediaCodec,
        copyAdmission: FFmpegParserCopyAdmission?
    ) throws -> FFmpegParsedFrame {
        guard let raw = pointer?.pointee,
              raw.size > 0,
              raw.size <= maximumFrameBytes,
              let bytes = raw.bytes,
              [-1, 0, 1].contains(raw.key_frame),
              [0, 1].contains(raw.repeat_pict),
              [-1, 0, 1].contains(raw.top_field_first),
              [-1, 0, 1].contains(raw.interlaced),
              (0...5).contains(raw.field_order),
              (0...3).contains(raw.picture_structure),
              raw.sample_rate >= 0,
              raw.channels >= 0,
              raw.frame_samples >= 0 else {
            throw error(for: codec, code: malformedFrameErrorCode)
        }
        let channelLayout: AudioChannelLayout?
        switch raw.channel_order {
        case VPFF_CHANNEL_ORDER_UNSPECIFIED:
            guard raw.has_channel_layout_mask == 0,
                  raw.channel_layout_mask == 0 else {
                throw error(for: codec, code: malformedFrameErrorCode)
            }
            channelLayout = raw.channels > 0
                ? AudioChannelLayout(channelCount: raw.channels, nativeMask: nil)
                : nil
        case VPFF_CHANNEL_ORDER_NATIVE:
            guard raw.has_channel_layout_mask == 1,
                  raw.channel_layout_mask != 0,
                  raw.channel_layout_mask.nonzeroBitCount == raw.channels else {
                throw error(for: codec, code: malformedFrameErrorCode)
            }
            channelLayout = AudioChannelLayout(
                channelCount: raw.channels,
                nativeMask: raw.channel_layout_mask
            )
        default:
            throw error(for: codec, code: malformedFrameErrorCode)
        }

        let duration: CMTime
        if raw.duration_timescale == 0, raw.duration_value == Int64.min {
            duration = .invalid
        } else if raw.duration_timescale > 0, raw.duration_value >= 0 {
            duration = CMTime(value: raw.duration_value, timescale: raw.duration_timescale)
        } else {
            throw error(for: codec, code: malformedFrameErrorCode)
        }
        let frameReservation: FFmpegParserFrameReservation?
        if let copyAdmission {
            guard let token = copyAdmission.reserve(bytes: raw.size, codec: codec) else {
                throw copyAdmission.takeFailure() ?? error(for: codec, code: malformedFrameErrorCode)
            }
            frameReservation = Unmanaged<FFmpegParserFrameReservation>.fromOpaque(token)
                .takeRetainedValue()
        } else {
            frameReservation = nil
        }
        return FFmpegParsedFrame(
            bytes: Data(bytes: bytes, count: raw.size),
            pts: raw.pts == Int64.min ? nil : raw.pts,
            dts: raw.dts == Int64.min ? nil : raw.dts,
            duration: duration,
            fieldOrder: raw.field_order,
            pictureStructure: raw.picture_structure,
            keyFrame: optionalBool(raw.key_frame),
            repeatPicture: raw.repeat_pict == 1,
            topFieldFirst: optionalBool(raw.top_field_first),
            interlaced: optionalBool(raw.interlaced),
            sampleRate: raw.sample_rate,
            channels: raw.channels,
            frameSamples: raw.frame_samples,
            channelLayout: channelLayout,
            frameReservation: frameReservation
        )
    }

    private static func rawCodec(_ codec: MediaCodec) throws -> VPFFCodec {
        switch codec {
        case .video(.h264): VPFF_CODEC_H264
        case .video(.hevc): VPFF_CODEC_HEVC
        case .audio(.aac): VPFF_CODEC_AAC
        case .audio(.ac3): VPFF_CODEC_AC3
        case .audio(.eac3): VPFF_CODEC_EAC3
        case .audio(.mp2): VPFF_CODEC_MP2
        case .audio(.mp1): VPFF_CODEC_MP1
        case .audio(.mp3): VPFF_CODEC_MP3
        }
    }

    private static func optionalBool(_ value: Int8) -> Bool? {
        switch value {
        case 0: false
        case 1: true
        default: nil
        }
    }

    fileprivate static func error(for codec: MediaCodec, code: Int32) -> PlaybackCoreError {
        switch codec {
        case .video:
            .videoDecode(code)
        case .audio:
            .audioFallbackDecode(code)
        }
    }
}

private func liveFFmpegParserCallback(
    _ context: UnsafeMutableRawPointer?,
    _ frame: UnsafePointer<VPFFParsedFrame>?
) {
    guard let context else { return }
    Unmanaged<LiveFFmpegParserHandle>.fromOpaque(context).takeUnretainedValue().receive(frame)
}

private func liveFFmpegParserReserveNativeAllocation(
    _ context: UnsafeMutableRawPointer?,
    _ kind: VPFFParserAllocationKind,
    _ bytes: Int
) -> UnsafeMutableRawPointer? {
    guard let context,
          kind == VPFF_PARSER_ALLOCATION_EXTRADATA || kind == VPFF_PARSER_ALLOCATION_PUSH_INPUT else {
        return nil
    }
    let bridge = Unmanaged<FFmpegParserNativeAllocationBridge>.fromOpaque(context)
        .takeUnretainedValue()
    return bridge.admission.reserve(bytes: bytes, codec: bridge.codec)
}

private func liveFFmpegParserReleaseNativeAllocation(
    _ context: UnsafeMutableRawPointer?,
    _ token: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<FFmpegParserNativeAllocationBridge>.fromOpaque(context)
        .takeUnretainedValue().admission.release(token)
}
