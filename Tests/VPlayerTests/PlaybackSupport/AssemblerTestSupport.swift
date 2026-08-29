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

    static func syntheticAC3Frame(
        fscod: UInt8 = 0,
        frmsizecod: UInt8 = 20,
        bsid: UInt8 = 8,
        bsmod: UInt8 = 0,
        acmod: UInt8 = 2,
        lfeon: Bool = false
    ) -> Data {
        precondition(fscod < 3)
        precondition(frmsizecod < 38)
        precondition(bsid < 32)
        precondition(bsmod < 8)
        precondition(acmod < 8)

        let frameSizeWords: [[Int]] = [
            [64, 69, 96], [64, 70, 96], [80, 87, 120], [80, 88, 120],
            [96, 104, 144], [96, 105, 144], [112, 121, 168], [112, 122, 168],
            [128, 139, 192], [128, 140, 192], [160, 174, 240], [160, 175, 240],
            [192, 208, 288], [192, 209, 288], [224, 243, 336], [224, 244, 336],
            [256, 278, 384], [256, 279, 384], [320, 348, 480], [320, 349, 480],
            [384, 417, 576], [384, 418, 576], [448, 487, 672], [448, 488, 672],
            [512, 557, 768], [512, 558, 768], [640, 696, 960], [640, 697, 960],
            [768, 835, 1_152], [768, 836, 1_152], [896, 975, 1_344],
            [896, 976, 1_344], [1_024, 1_114, 1_536], [1_024, 1_115, 1_536],
            [1_152, 1_253, 1_728], [1_152, 1_254, 1_728], [1_280, 1_393, 1_920],
            [1_280, 1_394, 1_920],
        ]
        var writer = SyntheticAC3BitWriter(
            byteCount: frameSizeWords[Int(frmsizecod)][Int(fscod)] * 2
        )
        writer.write(0x0B77, bitCount: 16)
        writer.write(0, bitCount: 16) // CRC field; the full-frame patch is written below.
        writer.write(UInt32(fscod), bitCount: 2)
        writer.write(UInt32(frmsizecod), bitCount: 6)
        writer.write(UInt32(bsid), bitCount: 5)
        writer.write(UInt32(bsmod), bitCount: 3)
        writer.write(UInt32(acmod), bitCount: 3)
        if acmod & 1 != 0, acmod != 1 {
            writer.write(0b10, bitCount: 2) // cmixlev
        }
        if acmod & 4 != 0 {
            writer.write(0b01, bitCount: 2) // surmixlev
        }
        if acmod == 2 {
            writer.write(0b10, bitCount: 2) // dsurmod
        }
        writer.write(lfeon ? 1 : 0, bitCount: 1)
        return writer.dataPatchingANSI16Remainder()
    }

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
        duration: CMTime = .invalid,
        isCorrupt: Bool = false
    ) -> DemuxPacket {
        DemuxPacket(
            streamIndex: streamIndex,
            codec: .audio(codec),
            data: data,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid,
            duration: duration,
            isKey: false,
            isCorrupt: isCorrupt
        )
    }

    static func syntheticMPEGFrame(codec: AudioCodec) -> Data {
        let facts: (version: UInt32, layer: UInt32, bitrateIndex: UInt32,
                    sampleRateIndex: UInt32, frameLength: Int)
        switch codec {
        case .mp1:
            facts = (3, 3, 9, 1, 288)
        case .mp2:
            facts = (3, 2, 9, 1, 480)
        case .mp3:
            facts = (3, 1, 9, 1, 384)
        default:
            preconditionFailure("synthetic MPEG fixture requires MP1, MP2, or MP3")
        }
        let header = UInt32(0x7FF) << 21
            | facts.version << 19
            | facts.layer << 17
            | 1 << 16
            | facts.bitrateIndex << 12
            | facts.sampleRateIndex << 10
        var result = Data([
            UInt8((header >> 24) & 0xFF),
            UInt8((header >> 16) & 0xFF),
            UInt8((header >> 8) & 0xFF),
            UInt8(header & 0xFF),
        ])
        result.append(Data(repeating: 0xA5, count: facts.frameLength - 4))
        return result
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

private struct SyntheticAC3BitWriter {
    private(set) var data: Data
    private var bitOffset = 0

    init(byteCount: Int) {
        data = Data(repeating: 0, count: byteCount)
    }

    mutating func write(_ value: UInt32, bitCount: Int) {
        precondition((0...32).contains(bitCount))
        for shift in stride(from: bitCount - 1, through: 0, by: -1) {
            let bit = UInt8((value >> UInt32(shift)) & 1)
            let byteIndex = bitOffset / 8
            let bitIndex = 7 - bitOffset % 8
            data[byteIndex] |= bit << UInt8(bitIndex)
            bitOffset += 1
        }
    }

    func dataPatchingANSI16Remainder() -> Data {
        precondition(data.count >= 4)
        var result = data
        let patchIndex = result.count - 2
        let prefixCRC = result[2..<patchIndex].reduce(UInt16(0)) {
            Self.updateANSI16($0, byte: $1)
        }
        for patch in UInt32(0)...UInt32(UInt16.max) {
            let high = UInt8((patch >> 8) & 0xFF)
            let low = UInt8(patch & 0xFF)
            let afterHigh = Self.updateANSI16(prefixCRC, byte: high)
            if Self.updateANSI16(afterHigh, byte: low) == 0 {
                result[patchIndex] = high
                result[patchIndex + 1] = low
                return result
            }
        }
        preconditionFailure("ANSI-16 patch was not found")
    }

    private static func updateANSI16(_ crc: UInt16, byte: UInt8) -> UInt16 {
        var result = crc ^ (UInt16(byte) << 8)
        for _ in 0..<8 {
            result = result & 0x8000 != 0 ? (result << 1) ^ 0x8005 : result << 1
        }
        return result
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
