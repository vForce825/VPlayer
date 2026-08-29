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
    let bytes: Data
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
    func makeParser(
        configuration: FFmpegParserConfiguration,
        receiver: @escaping (FFmpegParsedFrame) throws -> Void
    ) throws -> any FFmpegParserHandle {
        try LiveFFmpegParserHandle(configuration: configuration, receiver: receiver)
    }
}

final class LiveFFmpegParserHandle: FFmpegParserHandle {
    static let malformedFrameErrorCode: Int32 = -1_448_143_363
    private static let maximumFrameBytes = 64 * 1_024 * 1_024

    private var native: OpaquePointer?
    private let codec: MediaCodec
    private let receiver: (FFmpegParsedFrame) throws -> Void
    private var callbackFailure: Error?

    init(
        configuration: FFmpegParserConfiguration,
        receiver: @escaping (FFmpegParsedFrame) throws -> Void
    ) throws {
        codec = configuration.codec
        self.receiver = receiver
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
            return vp_ffmpeg_parser_create_v1(
                &rawConfiguration,
                liveFFmpegParserCallback,
                Unmanaged.passUnretained(self).toOpaque(),
                &native
            )
        }
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
        guard let native,
              !bytes.isEmpty,
              pts != Int64.min,
              dts != Int64.min,
              duration != Int64.min else {
            throw Self.error(for: codec, code: Self.malformedFrameErrorCode)
        }
        callbackFailure = nil
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
        if let callbackFailure {
            throw callbackFailure
        }
        guard status >= 0 else {
            throw Self.error(for: codec, code: status)
        }
    }

    func drain() throws {
        guard let native else { return }
        callbackFailure = nil
        let status = vp_ffmpeg_parser_drain(native)
        if let callbackFailure {
            throw callbackFailure
        }
        guard status >= 0 else {
            throw Self.error(for: codec, code: status)
        }
    }

    func destroy() {
        guard let native else { return }
        vp_ffmpeg_parser_destroy(native)
        self.native = nil
    }

    fileprivate func receive(_ pointer: UnsafePointer<VPFFParsedFrame>?) {
        guard callbackFailure == nil else { return }
        do {
            let frame = try Self.copy(pointer, codec: codec)
            try receiver(frame)
        } catch {
            callbackFailure = error
        }
    }

    private static func copy(
        _ pointer: UnsafePointer<VPFFParsedFrame>?,
        codec: MediaCodec
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
            channelLayout: channelLayout
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

    private static func error(for codec: MediaCodec, code: Int32) -> PlaybackCoreError {
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
