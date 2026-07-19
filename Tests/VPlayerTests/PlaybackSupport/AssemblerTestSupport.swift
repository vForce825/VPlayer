// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class ScriptedFFmpegParserFactory: FFmpegParserFactory {
    typealias PushScript = (
        ScriptedFFmpegParserHandle,
        Int,
        Data,
        Int64?,
        Int64?,
        Int64?
    ) throws -> Void
    typealias DrainScript = (ScriptedFFmpegParserHandle, Int) throws -> Void

    let pushScript: PushScript
    let drainScript: DrainScript
    private(set) var configurations: [FFmpegParserConfiguration] = []
    private(set) var handles: [ScriptedFFmpegParserHandle] = []

    init(
        pushScript: @escaping PushScript = { _, _, _, _, _, _ in },
        drainScript: @escaping DrainScript = { _, _ in }
    ) {
        self.pushScript = pushScript
        self.drainScript = drainScript
    }

    func makeParser(
        configuration: FFmpegParserConfiguration,
        receiver: @escaping (FFmpegParsedFrame) throws -> Void
    ) throws -> any FFmpegParserHandle {
        configurations.append(configuration)
        let handle = ScriptedFFmpegParserHandle(
            factory: self,
            handleIndex: handles.count,
            receiver: receiver
        )
        handles.append(handle)
        return handle
    }
}

final class ScriptedFFmpegParserHandle: FFmpegParserHandle {
    private let factory: ScriptedFFmpegParserFactory
    private let receiver: (FFmpegParsedFrame) throws -> Void
    let handleIndex: Int
    private(set) var pushCount = 0
    private(set) var drainCount = 0
    private(set) var destroyCount = 0

    init(
        factory: ScriptedFFmpegParserFactory,
        handleIndex: Int,
        receiver: @escaping (FFmpegParsedFrame) throws -> Void
    ) {
        self.factory = factory
        self.handleIndex = handleIndex
        self.receiver = receiver
    }

    func push(_ bytes: Data, pts: Int64?, dts: Int64?, duration: Int64?) throws {
        let index = pushCount
        pushCount += 1
        try factory.pushScript(self, index, bytes, pts, dts, duration)
    }

    func drain() throws {
        let index = drainCount
        drainCount += 1
        try factory.drainScript(self, index)
    }

    func destroy() {
        destroyCount += 1
    }

    func emit(_ frame: FFmpegParsedFrame) throws {
        try receiver(frame)
    }
}

enum AssemblerTestFixtures {
    static let h264SPS = Data([0x67, 0x42, 0x00, 0x1F, 0x95, 0xA8, 0x14, 0x01, 0x6E, 0x40])
    static let h264PPS = Data([0x68, 0xCE, 0x06, 0xE2])
    static let hevcVPS = Data([
        0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x03, 0x00, 0x5D, 0xAC, 0x59,
    ])
    static let hevcSPS = Data([
        0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03,
        0x00, 0xB0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
        0x00, 0x5D, 0xA0, 0x02, 0x80, 0x80, 0x2D, 0x16,
        0x59, 0x59, 0xA4, 0x93, 0x2B, 0xC0, 0x5A, 0x80,
        0x80, 0x80, 0xA0,
    ])
    static let hevcPPS = Data([0x44, 0x01, 0xC0, 0xF1, 0x83, 0x24])

    static func h264AccessUnit(
        sps: Data? = h264SPS,
        pps: Data? = h264PPS,
        nal: Data = Data([0x65, 0x88, 0x84])
    ) -> Data {
        var result = Data()
        if let sps {
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(sps)
        }
        if let pps {
            result.append(contentsOf: [0, 0, 1])
            result.append(pps)
        }
        result.append(contentsOf: [0, 0, 1])
        result.append(nal)
        return result
    }

    static func h264ParserAccessUnit(
        includeParameterSets: Bool,
        nal: Data
    ) -> Data {
        var result = Data([0, 0, 0, 1, 0x09, 0xF0])
        if includeParameterSets {
            result.append(annexBParameterSets([h264SPS, h264PPS]))
        }
        result.append(contentsOf: [0, 0, 0, 1])
        result.append(nal)
        return result
    }

    static func annexBParameterSets(_ parameterSets: [Data]) -> Data {
        var result = Data()
        for parameterSet in parameterSets {
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(parameterSet)
        }
        return result
    }

    static func hevcAccessUnit(
        includeParameterSets: Bool = true,
        nal: Data = Data([0x26, 0x01, 0x80])
    ) -> Data {
        var result = includeParameterSets
            ? annexBParameterSets([hevcVPS, hevcSPS, hevcPPS])
            : Data()
        result.append(contentsOf: [0, 0, 0, 1])
        result.append(nal)
        return result
    }

    static func videoTracks(
        codec: VideoCodec = .h264,
        streamIndex: Int32 = 0,
        audio: AudioTrackDescriptor? = nil,
        extradata: Data = Data()
    ) throws -> DemuxTrackSet {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        return DemuxTrackSet(
            selectedProgramID: 7,
            video: VideoTrackDescriptor(
                streamIndex: streamIndex,
                codec: codec,
                timeBase: timeBase,
                width: 1_920,
                height: 1_080,
                videoDelay: 1,
                extradata: extradata
            ),
            audio: audio
        )
    }

    static func audioTracks(
        codec: AudioCodec = .aac,
        streamIndex: Int32 = 1,
        sampleRate: Int32 = 48_000,
        channelCount: Int32 = 2,
        nativeMask: UInt64? = 3,
        extradata: Data = Data([0x11, 0x90]),
        video: VideoTrackDescriptor? = nil
    ) throws -> DemuxTrackSet {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        return DemuxTrackSet(
            selectedProgramID: 7,
            video: video,
            audio: AudioTrackDescriptor(
                streamIndex: streamIndex,
                codec: codec,
                timeBase: timeBase,
                sampleRate: sampleRate,
                channelLayout: AudioChannelLayout(
                    channelCount: channelCount,
                    nativeMask: nativeMask
                ),
                extradata: extradata
            )
        )
    }

    static func videoPacket(
        data: Data = Data([1]),
        streamIndex: Int32 = 0,
        codec: VideoCodec = .h264,
        pts: CMTime = CMTime(value: 90_000, timescale: 90_000),
        dts: CMTime = CMTime(value: 87_000, timescale: 90_000),
        duration: CMTime = .invalid
    ) -> DemuxPacket {
        DemuxPacket(
            streamIndex: streamIndex,
            codec: .video(codec),
            data: data,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts,
            duration: duration,
            isKey: false,
            isCorrupt: false
        )
    }

    static func audioPacket(
        data: Data,
        streamIndex: Int32 = 1,
        codec: AudioCodec,
        pts: CMTime = CMTime(value: 90_000, timescale: 90_000),
        duration: CMTime = .invalid
    ) -> DemuxPacket {
        DemuxPacket(
            streamIndex: streamIndex,
            codec: .audio(codec),
            data: data,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid,
            duration: duration,
            isKey: false,
            isCorrupt: false
        )
    }

    static func parsedVideoFrame(
        bytes: Data,
        pts: Int64? = 90_000,
        dts: Int64? = 87_000,
        duration: CMTime = .invalid,
        keyFrame: Bool? = true,
        fieldOrder: Int32 = 2,
        pictureStructure: Int32 = 1,
        repeatPicture: Bool = false,
        topFieldFirst: Bool? = true,
        interlaced: Bool? = true
    ) -> FFmpegParsedFrame {
        FFmpegParsedFrame(
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
            sampleRate: 0,
            channels: 0,
            frameSamples: 0,
            channelLayout: nil
        )
    }

    static func parsedAudioFrame(
        bytes: Data,
        pts: Int64? = 90_000,
        sampleRate: Int32 = 48_000,
        channels: Int32 = 2,
        frameSamples: Int32,
        nativeMask: UInt64? = 3
    ) -> FFmpegParsedFrame {
        FFmpegParsedFrame(
            bytes: bytes,
            pts: pts,
            dts: nil,
            duration: CMTime(value: Int64(frameSamples), timescale: sampleRate),
            fieldOrder: 0,
            pictureStructure: 0,
            keyFrame: nil,
            repeatPicture: false,
            topFieldFirst: nil,
            interlaced: nil,
            sampleRate: sampleRate,
            channels: channels,
            frameSamples: frameSamples,
            channelLayout: AudioChannelLayout(channelCount: channels, nativeMask: nativeMask)
        )
    }
}

func copiedSampleData(_ sampleBuffer: CMSampleBuffer) throws -> Data {
    let blockBuffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))
    let length = CMBlockBufferGetDataLength(blockBuffer)
    var result = Data(count: length)
    let status = result.withUnsafeMutableBytes { rawBuffer in
        guard let destination = rawBuffer.baseAddress else {
            return kCMBlockBufferBadPointerParameterErr
        }
        return CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: length,
            destination: destination
        )
    }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    return result
}
