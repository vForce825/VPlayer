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

final class CompressedVideoAssembler {
    static let invalidInputErrorCode: Int32 = -1_448_143_364
    static let idExhaustedErrorCode: Int32 = -1_448_143_365

    private let generationProvider: () -> MediaGeneration
    private let eventSink: (VideoAssemblerEvent) -> Void
    private let parserFactory: any FFmpegParserFactory
    private let formatState: AssemblyFormatState
    private var tracks: DemuxTrackSet
    private var descriptor: VideoTrackDescriptor
    private var parser: (any FFmpegParserHandle)?
    private var nextID: UInt64?
    private var parameterSets: [Data] = []
    private var formatDescription: CMVideoFormatDescription?
    private var emittedFingerprint: MediaFormatFingerprint?

    init(
        trackSet: DemuxTrackSet,
        generationProvider: @escaping () -> MediaGeneration,
        eventSink: @escaping (VideoAssemblerEvent) -> Void,
        parserFactory: any FFmpegParserFactory = LiveFFmpegParserFactory(),
        formatState: AssemblyFormatState,
        startingID: UInt64 = 1
    ) throws {
        guard let descriptor = trackSet.video else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        self.tracks = trackSet
        self.descriptor = descriptor
        self.generationProvider = generationProvider
        self.eventSink = eventSink
        self.parserFactory = parserFactory
        self.formatState = formatState
        nextID = startingID
        parser = try makeParser(for: descriptor)
        try prepareExtradata(descriptor.extradata)
    }

    deinit {
        parser?.destroy()
    }

    func push(_ packet: DemuxPacket) throws {
        guard packet.streamIndex == descriptor.streamIndex,
              packet.codec == .video(descriptor.codec),
              !packet.data.isEmpty else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        let pts = try exactTicks(packet.presentationTimeStamp, timeBase: descriptor.timeBase)
        let dts = try exactTicks(packet.decodeTimeStamp, timeBase: descriptor.timeBase)
        let duration = try exactDurationTicks(packet.duration, timeBase: descriptor.timeBase)
        try parser?.push(packet.data, pts: pts, dts: dts, duration: duration)
    }

    func drain() throws {
        try parser?.drain()
    }

    func reset(for trackSet: DemuxTrackSet) throws {
        guard let descriptor = trackSet.video else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        parser?.destroy()
        parser = nil
        tracks = trackSet
        self.descriptor = descriptor
        formatState.resetVideo(for: trackSet)
        parser = try makeParser(for: descriptor)
        parameterSets = []
        formatDescription = nil
        emittedFingerprint = nil
        try prepareExtradata(descriptor.extradata)
    }

    private func makeParser(
        for descriptor: VideoTrackDescriptor
    ) throws -> any FFmpegParserHandle {
        try parserFactory.makeParser(configuration: FFmpegParserConfiguration(video: descriptor)) {
            [weak self] frame in
            guard let self else { return }
            try receive(frame)
        }
    }

    private func receive(_ frame: FFmpegParsedFrame) throws {
        let scan = try AnnexBScanner.scan(frame.bytes, codec: descriptor.codec)
        try updateFormatIfNeeded(with: scan.parameterSets)
        guard let formatDescription else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }

        let fingerprint: MediaFormatFingerprint
        do {
            fingerprint = try formatState.fingerprint()
        } catch {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        if fingerprint != emittedFingerprint {
            eventSink(.format(formatDescription, fingerprint))
            emittedFingerprint = fingerprint
        }
        let generation = generationProvider()
        let id = try takeNextID()
        let presentationTimeStamp = frame.pts.map(descriptor.timeBase.cmTime) ?? .invalid
        let decodeTimeStamp = frame.dts.map(descriptor.timeBase.cmTime) ?? .invalid
        let isRandomAccess = frame.keyFrame == true
        let sampleBuffer = try SampleBufferBuilder.makeVideo(
            data: scan.lengthPrefixedData,
            formatDescription: formatDescription,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp,
            duration: frame.duration,
            isRandomAccess: isRandomAccess
        )
        let metadata = try makeMetadata(frame, presentationTimeStamp: presentationTimeStamp)
        eventSink(.accessUnit(CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: generation,
            isRandomAccess: isRandomAccess,
            parserMetadata: metadata
        )))
    }

    private func prepareExtradata(_ extradata: Data) throws {
        guard !extradata.isEmpty else { return }
        let scan = try AnnexBScanner.scan(extradata, codec: descriptor.codec)
        try updateFormatIfNeeded(with: scan.parameterSets)
    }

    private func updateFormatIfNeeded(with incoming: [Data]) throws {
        let candidate = mergedParameterSets(incoming)
        guard candidate != parameterSets || formatDescription == nil else { return }
        guard hasRequiredParameterSets(candidate) else {
            if formatDescription == nil {
                throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
            }
            return
        }
        let candidateDescription = try VideoFormatDescriptionBuilder.make(
            codec: descriptor.codec,
            parameterSets: candidate
        )
        parameterSets = candidate
        formatDescription = candidateDescription
        formatState.commitVideoParameterSets(candidate)
    }

    private func mergedParameterSets(_ incoming: [Data]) -> [Data] {
        guard !incoming.isEmpty else { return parameterSets }
        var groups = Dictionary(grouping: parameterSets) { parameterSetType($0) }
            .mapValues(exactUniqueParameterSets)
        for (type, values) in Dictionary(grouping: incoming, by: { parameterSetType($0) }) {
            groups[type] = exactUniqueParameterSets(values)
        }
        return parameterSetOrder().flatMap { groups[$0] ?? [] }
    }

    private func exactUniqueParameterSets(_ values: [Data]) -> [Data] {
        var seen = Set<Data>()
        var result: [Data] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func hasRequiredParameterSets(_ values: [Data]) -> Bool {
        let types = Set(values.map(parameterSetType))
        switch descriptor.codec {
        case .h264:
            return types.contains(7) && types.contains(8)
        case .hevc:
            return types.contains(32) && types.contains(33) && types.contains(34)
        }
    }

    private func parameterSetOrder() -> [UInt8] {
        switch descriptor.codec {
        case .h264: return [7, 8, 13]
        case .hevc: return [32, 33, 34]
        }
    }

    private func parameterSetType(_ data: Data) -> UInt8 {
        guard let first = data.first else { return UInt8.max }
        switch descriptor.codec {
        case .h264: return first & 0x1F
        case .hevc: return (first >> 1) & 0x3F
        }
    }

    private func takeNextID() throws -> UInt64 {
        guard let id = nextID else {
            throw PlaybackCoreError.videoDecode(Self.idExhaustedErrorCode)
        }
        nextID = id == UInt64.max ? nil : id + 1
        return id
    }

    private func makeMetadata(
        _ frame: FFmpegParsedFrame,
        presentationTimeStamp: CMTime
    ) throws -> VideoParserMetadata {
        guard let rawFieldOrder = UInt8(exactly: frame.fieldOrder),
              let rawPictureStructure = UInt8(exactly: frame.pictureStructure),
              let fieldOrder = CodedFieldOrder(rawValue: rawFieldOrder),
              let pictureStructure = PictureStructure(rawValue: rawPictureStructure) else {
            throw PlaybackCoreError.videoDecode(Self.invalidInputErrorCode)
        }
        return VideoParserMetadata(
            fieldOrder: fieldOrder,
            pictureStructure: pictureStructure,
            isInterlaced: frame.interlaced,
            repeatFirstField: frame.repeatPicture,
            topFieldFirst: frame.topFieldFirst,
            sourcePTS90k: exactNonnegative90k(presentationTimeStamp)
        )
    }

    private func exactNonnegative90k(_ time: CMTime) -> UInt64? {
        guard time.isNumeric, time.epoch == 0, time.value >= 0, time.timescale > 0 else {
            return nil
        }
        var value = UInt64(time.value)
        var multiplier: UInt64 = 90_000
        var denominator = UInt64(time.timescale)
        let firstGCD = greatestCommonDivisorForAssembly(value, denominator)
        value /= firstGCD
        denominator /= firstGCD
        let secondGCD = greatestCommonDivisorForAssembly(multiplier, denominator)
        multiplier /= secondGCD
        denominator /= secondGCD
        guard denominator == 1 else { return nil }
        let (result, overflowed) = value.multipliedReportingOverflow(by: multiplier)
        return overflowed ? nil : result
    }
}

func exactTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64? {
    guard time.isValid else { return nil }
    guard time.isNumeric, time.epoch == 0, time.timescale > 0 else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    let negative = time.value < 0
    var valueMagnitude = time.value.magnitude
    var multiplier = UInt64(timeBase.den)
    var denominator = UInt64(time.timescale) * UInt64(timeBase.num)

    let firstGCD = greatestCommonDivisorForAssembly(valueMagnitude, denominator)
    valueMagnitude /= firstGCD
    denominator /= firstGCD
    let secondGCD = greatestCommonDivisorForAssembly(multiplier, denominator)
    multiplier /= secondGCD
    denominator /= secondGCD
    guard denominator == 1 else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    let (magnitude, overflowed) = valueMagnitude.multipliedReportingOverflow(by: multiplier)
    let limit = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
    guard !overflowed, magnitude <= limit else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    if negative {
        if magnitude == UInt64(Int64.max) + 1 {
            throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
        }
        return -Int64(magnitude)
    }
    return Int64(magnitude)
}

func exactDurationTicks(_ time: CMTime, timeBase: MediaRational) throws -> Int64? {
    guard let value = try exactTicks(time, timeBase: timeBase) else { return nil }
    guard value >= 0 else {
        throw PlaybackCoreError.videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
    }
    return value
}

func greatestCommonDivisorForAssembly(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var first = lhs
    var second = rhs
    while second != 0 {
        let remainder = first % second
        first = second
        second = remainder
    }
    return first
}
