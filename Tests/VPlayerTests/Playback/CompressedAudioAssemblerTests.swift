// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class CompressedAudioAssemblerTests: XCTestCase {
    func testCanInitializeAndDrainWithoutFrames() throws {
        let subject = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(),
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { _ in }
        )

        try subject.drain()
    }

    func testSplitSevenByteADTSBuildsStrippedCopiedAACSampleAndExactFormat() throws {
        let payload = Data([0x21, 0x10, 0x56, 0xE5])
        let frame = makeADTSFrame(payload: payload, hasCRC: false)
        var timeline: [String] = []
        var events: [AudioAssemblerEvent] = []
        var generation = MediaGeneration(rawValue: 10)
        let subject = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(extradata: Data()),
            generationProvider: {
                timeline.append("generation-\(generation.rawValue)")
                return generation
            },
            eventSink: { event in
                events.append(event)
                if case .format = event {
                    generation = MediaGeneration(rawValue: generation.rawValue + 1)
                    timeline.append("format-\(generation.rawValue)")
                }
            }
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data(frame.prefix(5)),
            codec: .aac,
            pts: CMTime(value: 1, timescale: 2)
        ))
        XCTAssertTrue(events.isEmpty)
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data(frame.dropFirst(5)),
            codec: .aac,
            pts: CMTime(value: 3, timescale: 2)
        ))

        XCTAssertEqual(events.count, 2)
        guard events.count == 2 else { return }
        let format = try XCTUnwrap(events[0].formatDescription)
        let sample = try XCTUnwrap(events[1].sample)
        XCTAssertEqual(sample.id, 1)
        XCTAssertEqual(sample.codec, .aac)
        XCTAssertEqual(sample.generation, MediaGeneration(rawValue: 11))
        XCTAssertEqual(sample.presentationTimeStamp, CMTime(value: 1, timescale: 2))
        XCTAssertEqual(sample.duration, CMTime(value: 1_024, timescale: 48_000))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer), sample.presentationTimeStamp)
        XCTAssertEqual(CMSampleBufferGetDuration(sample.sampleBuffer), sample.duration)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample.sampleBuffer), 1)
        XCTAssertTrue(CMSampleBufferDataIsReady(sample.sampleBuffer))
        XCTAssertEqual(try copiedSampleData(sample.sampleBuffer), payload)
        try assertAudioFormat(
            format,
            formatID: kAudioFormatMPEG4AAC,
            framesPerPacket: 1_024,
            cookie: Data([0x11, 0x90])
        )
        try assertPacketDescription(sample.sampleBuffer, byteSize: payload.count, frames: 0)
        XCTAssertEqual(timeline, ["format-11", "generation-11"])
    }

    func testNineByteADTSAndContainerASCPathsUseExactCookie() throws {
        let crcPayload = Data([0x44, 0x55, 0x66])
        let crcFrame = makeADTSFrame(payload: crcPayload, hasCRC: true)
        var adtsEvents: [AudioAssemblerEvent] = []
        let adts = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(extradata: Data()),
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { adtsEvents.append($0) }
        )
        try adts.push(AssemblerTestFixtures.audioPacket(
            data: Data(crcFrame.prefix(8)),
            codec: .aac
        ))
        try adts.push(AssemblerTestFixtures.audioPacket(
            data: Data(crcFrame.dropFirst(8)),
            codec: .aac
        ))

        let adtsSample = try XCTUnwrap(adtsEvents.compactMap(\.sample).first)
        XCTAssertEqual(try copiedSampleData(adtsSample.sampleBuffer), crcPayload)
        let adtsFormat = try XCTUnwrap(adtsEvents.compactMap(\.formatDescription).first)
        XCTAssertEqual(try copiedMagicCookie(adtsFormat), Data([0x11, 0x90]))

        let rawPayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var rawEvents: [AudioAssemblerEvent] = []
        let raw = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(extradata: Data([0x11, 0x90])),
            generationProvider: { MediaGeneration(rawValue: 4) },
            eventSink: { rawEvents.append($0) }
        )
        try raw.push(AssemblerTestFixtures.audioPacket(
            data: rawPayload,
            codec: .aac,
            pts: CMTime(value: -1, timescale: 2)
        ))

        XCTAssertEqual(rawEvents.count, 2)
        let rawSample = try XCTUnwrap(rawEvents.compactMap(\.sample).first)
        XCTAssertEqual(rawSample.presentationTimeStamp, CMTime(value: -1, timescale: 2))
        XCTAssertEqual(try copiedSampleData(rawSample.sampleBuffer), rawPayload)
        let rawFormat = try XCTUnwrap(rawEvents.compactMap(\.formatDescription).first)
        XCTAssertEqual(try copiedMagicCookie(rawFormat), Data([0x11, 0x90]))
    }

    func testInjectedMP2ProducesTwoFramesFromOnePushWithExactASBDAndDurations() throws {
        let frames = [Data([0xFF, 0xFD, 1]), Data([0xFF, 0xFD, 2, 3])]
        let factory = ScriptedFFmpegParserFactory { handle, _, _, _, _, _ in
            for (index, bytes) in frames.enumerated() {
                try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                    bytes: bytes,
                    pts: Int64(90_000 + index * 2_160),
                    frameSamples: 1_152
                ))
            }
        }
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data()),
            generationProvider: { MediaGeneration(rawValue: 3) },
            eventSink: { events.append($0) },
            parserFactory: factory
        )

        try subject.push(AssemblerTestFixtures.audioPacket(data: Data([1]), codec: .mp2))

        XCTAssertEqual(events.count, 3)
        guard events.count == 3 else { return }
        let format = try XCTUnwrap(events[0].formatDescription)
        try assertAudioFormat(
            format,
            formatID: kAudioFormatMPEGLayer2,
            framesPerPacket: 1_152,
            cookie: nil
        )
        let samples = events.compactMap(\.sample)
        XCTAssertEqual(samples.map(\.id), [1, 2])
        XCTAssertEqual(samples.map(\.duration), [
            CMTime(value: 1_152, timescale: 48_000),
            CMTime(value: 1_152, timescale: 48_000),
        ])
        XCTAssertEqual(try samples.map { try copiedSampleData($0.sampleBuffer) }, frames)
        try assertPacketDescription(samples[0].sampleBuffer, byteSize: frames[0].count, frames: 0)
    }

    func testAC3AndEAC3HonorCodecSpecificActualFrameSamples() throws {
        try assertParsedAudioCodec(
            .ac3,
            frameSamples: [1_536],
            expectedFormatID: kAudioFormatAC3,
            expectedFramesPerPacket: 1_536
        )
        try assertParsedAudioCodec(
            .eac3,
            frameSamples: [1_536, 256],
            expectedFormatID: kAudioFormatEnhancedAC3,
            expectedFramesPerPacket: 0
        )
    }

    func testMalformedADTSASCLayoutPTSAndFrameSamplesFailDeterministically() throws {
        var profileNotLC = makeADTSFrame(payload: Data([1]), hasCRC: false)
        profileNotLC[2] = (profileNotLC[2] & 0x3F) | 0x80
        var pce = makeADTSFrame(payload: Data([1]), hasCRC: false)
        pce[2] &= 0xFE
        pce[3] &= 0x3F
        var multipleRawBlocks = makeADTSFrame(payload: Data([1]), hasCRC: false)
        multipleRawBlocks[6] |= 1
        let malformedFrames = [profileNotLC, pce, multipleRawBlocks]
        for malformed in malformedFrames {
            let subject = try CompressedAudioAssembler(
                trackSet: AssemblerTestFixtures.audioTracks(extradata: Data()),
                generationProvider: { MediaGeneration(rawValue: 0) },
                eventSink: { _ in }
            )
            XCTAssertThrowsError(try subject.push(
                AssemblerTestFixtures.audioPacket(data: malformed, codec: .aac)
            ))
        }

        let incomplete = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(extradata: Data()),
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in }
        )
        try incomplete.push(AssemblerTestFixtures.audioPacket(
            data: Data([0xFF, 0xF1, 0x4C]),
            codec: .aac
        ))
        XCTAssertThrowsError(try incomplete.drain())

        XCTAssertThrowsError(try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(extradata: Data([0x2B, 0x92])),
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in }
        ))

        let invalidPTS = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(),
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in }
        )
        XCTAssertThrowsError(try invalidPTS.push(AssemblerTestFixtures.audioPacket(
            data: Data([1]),
            codec: .aac,
            pts: .invalid
        )))

        let mismatchFactory = ScriptedFFmpegParserFactory { handle, _, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: Data([1]),
                sampleRate: 44_100,
                channels: 1,
                frameSamples: 1_152,
                nativeMask: 1
            ))
        }
        let mismatch = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data()),
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            parserFactory: mismatchFactory
        )
        XCTAssertThrowsError(try mismatch.push(
            AssemblerTestFixtures.audioPacket(data: Data([1]), codec: .mp2)
        ))

        let badCountFactory = ScriptedFFmpegParserFactory { handle, _, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: Data([1]),
                frameSamples: 1_024
            ))
        }
        let badCount = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data()),
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            parserFactory: badCountFactory
        )
        XCTAssertThrowsError(try badCount.push(
            AssemblerTestFixtures.audioPacket(data: Data([1]), codec: .mp2)
        ))
    }

    func testFormatOrderingResetDrainAndIDContinuityIncludingExhaustion() throws {
        let delayedFrame = AssemblerTestFixtures.parsedAudioFrame(
            bytes: Data([0xFF, 0xFD, 1]),
            frameSamples: 1_152
        )
        let factory = ScriptedFFmpegParserFactory(
            pushScript: { handle, _, _, _, _, _ in try handle.emit(delayedFrame) },
            drainScript: { handle, index in
                if index == 0 { try handle.emit(delayedFrame) }
            }
        )
        var timeline: [String] = []
        var generation = MediaGeneration(rawValue: 0)
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data()),
            generationProvider: {
                timeline.append("generation-\(generation.rawValue)")
                return generation
            },
            eventSink: { event in
                events.append(event)
                if case .format = event {
                    generation = MediaGeneration(rawValue: generation.rawValue + 1)
                    timeline.append("format-\(generation.rawValue)")
                }
            },
            parserFactory: factory,
            startingID: UInt64.max - 2
        )

        try subject.push(AssemblerTestFixtures.audioPacket(data: Data([1]), codec: .mp2))
        try subject.drain()
        try subject.drain()
        try subject.reset(for: AssemblerTestFixtures.audioTracks(
            codec: .mp2,
            streamIndex: 2,
            extradata: Data()
        ))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data([1]),
            streamIndex: 2,
            codec: .mp2
        ))

        XCTAssertEqual(factory.handles[0].drainCount, 2)
        XCTAssertEqual(factory.handles[0].destroyCount, 1)
        XCTAssertEqual(events.compactMap(\.sample).map(\.id), [
            UInt64.max - 2, UInt64.max - 1, UInt64.max,
        ])
        XCTAssertEqual(timeline, [
            "format-1", "generation-1", "generation-1",
            "format-2", "generation-2",
        ])
        XCTAssertThrowsError(try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data([1]),
            streamIndex: 2,
            codec: .mp2
        ))) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .audioFallbackDecode(CompressedAudioAssembler.idExhaustedErrorCode)
            )
        }
    }

    func testResetDiscardsPartialADTSCarryAndDrainRejectsIncompleteFrame() throws {
        let payload = Data([0x10, 0x20])
        let frame = makeADTSFrame(payload: payload, hasCRC: false)
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(extradata: Data()),
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { events.append($0) }
        )
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data(frame.prefix(6)),
            codec: .aac
        ))
        XCTAssertThrowsError(try subject.drain())

        try subject.reset(for: AssemblerTestFixtures.audioTracks(
            streamIndex: 2,
            extradata: Data()
        ))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: frame,
            streamIndex: 2,
            codec: .aac
        ))
        XCTAssertEqual(events.compactMap(\.sample).count, 1)
        XCTAssertEqual(try copiedSampleData(try XCTUnwrap(events.compactMap(\.sample).first).sampleBuffer), payload)
    }

    func testVersionedCABIRejectsBadConfigAndEnforcesDrainLifecycle() throws {
        var bad = VPFFParserConfigV1()
        bad.abi_version = 2
        bad.struct_size = UInt32(MemoryLayout<VPFFParserConfigV1>.stride)
        bad.codec = VPFF_CODEC_MP2
        bad.time_base_num = 1
        bad.time_base_den = 90_000
        var native: OpaquePointer?
        XCTAssertLessThan(vp_ffmpeg_parser_create_v1(
            &bad,
            { _, _ in },
            nil,
            &native
        ), 0)
        XCTAssertNil(native)

        var valid = bad
        valid.abi_version = 1
        valid.sample_rate = 48_000
        valid.channel_count = 2
        valid.channel_order = VPFF_CHANNEL_ORDER_NATIVE
        valid.has_channel_layout_mask = 1
        valid.channel_layout_mask = 3
        XCTAssertEqual(vp_ffmpeg_parser_create_v1(
            &valid,
            { _, _ in },
            nil,
            &native
        ), 0)
        let parser = try XCTUnwrap(native)
        XCTAssertEqual(vp_ffmpeg_parser_drain(parser), 0)
        XCTAssertEqual(vp_ffmpeg_parser_drain(parser), 0)
        var byte: UInt8 = 0
        XCTAssertLessThan(vp_ffmpeg_parser_push(
            parser,
            &byte,
            1,
            Int64.min,
            Int64.min,
            Int64.min
        ), 0)
        vp_ffmpeg_parser_destroy(parser)
    }

    func testLiveAudioParserMapsPostDrainPushFailureToAudioError() throws {
        let descriptor = try XCTUnwrap(AssemblerTestFixtures.audioTracks(
            codec: .mp2,
            extradata: Data()
        ).audio)
        let handle = try LiveFFmpegParserHandle(
            configuration: FFmpegParserConfiguration(audio: descriptor),
            receiver: { _ in }
        )
        try handle.drain()

        XCTAssertThrowsError(try handle.push(
            Data([0]),
            pts: nil,
            dts: nil,
            duration: nil
        )) { error in
            guard let coreError = error as? PlaybackCoreError,
                  case .audioFallbackDecode = coreError else {
                return XCTFail("expected audio parser error, received \(error)")
            }
        }
    }

    private func assertParsedAudioCodec(
        _ codec: VPlayerPlayback.AudioCodec,
        frameSamples: [Int32],
        expectedFormatID: AudioFormatID,
        expectedFramesPerPacket: UInt32
    ) throws {
        let payloads = frameSamples.indices.map { Data([UInt8($0 + 1), 0xA5]) }
        let factory = ScriptedFFmpegParserFactory { handle, _, _, _, _, _ in
            for index in frameSamples.indices {
                try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                    bytes: payloads[index],
                    pts: Int64(90_000 + index * 2_880),
                    frameSamples: frameSamples[index]
                ))
            }
        }
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: AssemblerTestFixtures.audioTracks(codec: codec, extradata: Data()),
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            parserFactory: factory
        )
        try subject.push(AssemblerTestFixtures.audioPacket(data: Data([1]), codec: codec))

        let format = try XCTUnwrap(events.compactMap(\.formatDescription).first)
        try assertAudioFormat(
            format,
            formatID: expectedFormatID,
            framesPerPacket: expectedFramesPerPacket,
            cookie: nil
        )
        let samples = events.compactMap(\.sample)
        XCTAssertEqual(samples.map(\.duration), frameSamples.map {
            CMTime(value: Int64($0), timescale: 48_000)
        })
        XCTAssertEqual(try samples.map { try copiedSampleData($0.sampleBuffer) }, payloads)
        for (sample, count) in zip(samples, frameSamples) {
            try assertPacketDescription(
                sample.sampleBuffer,
                byteSize: try copiedSampleData(sample.sampleBuffer).count,
                frames: codec == .eac3 ? UInt32(count) : 0
            )
        }
    }

    private func assertAudioFormat(
        _ format: CMAudioFormatDescription,
        formatID: AudioFormatID,
        framesPerPacket: UInt32,
        cookie: Data?
    ) throws {
        let stream = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        XCTAssertEqual(stream.mSampleRate, 48_000)
        XCTAssertEqual(stream.mFormatID, formatID)
        XCTAssertEqual(stream.mFormatFlags, 0)
        XCTAssertEqual(stream.mBytesPerPacket, 0)
        XCTAssertEqual(stream.mFramesPerPacket, framesPerPacket)
        XCTAssertEqual(stream.mBytesPerFrame, 0)
        XCTAssertEqual(stream.mChannelsPerFrame, 2)
        XCTAssertEqual(stream.mBitsPerChannel, 0)
        XCTAssertEqual(stream.mReserved, 0)
        XCTAssertEqual(try copiedMagicCookie(format), cookie)

        var layoutSize = 0
        let layout = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(
            format,
            sizeOut: &layoutSize
        ))
        XCTAssertGreaterThanOrEqual(layoutSize, MemoryLayout<AudioToolbox.AudioChannelLayout>.size)
        XCTAssertEqual(layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelBitmap)
        XCTAssertEqual(layout.pointee.mChannelBitmap.rawValue, 3)
    }

    private func copiedMagicCookie(_ format: CMAudioFormatDescription) throws -> Data? {
        var size = 0
        guard let pointer = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size) else {
            XCTAssertEqual(size, 0)
            return nil
        }
        XCTAssertGreaterThan(size, 0)
        return Data(bytes: pointer, count: size)
    }

    private func assertPacketDescription(
        _ sampleBuffer: CMSampleBuffer,
        byteSize: Int,
        frames: UInt32
    ) throws {
        var pointer: UnsafePointer<AudioStreamPacketDescription>?
        var size = 0
        XCTAssertEqual(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
            sampleBuffer,
            packetDescriptionsPointerOut: &pointer,
            sizeOut: &size
        ), noErr)
        let description = try XCTUnwrap(pointer?.pointee)
        XCTAssertEqual(size, MemoryLayout<AudioStreamPacketDescription>.size)
        XCTAssertEqual(description.mStartOffset, 0)
        XCTAssertEqual(description.mVariableFramesInPacket, frames)
        XCTAssertEqual(description.mDataByteSize, UInt32(byteSize))
    }

    private func makeADTSFrame(payload: Data, hasCRC: Bool) -> Data {
        let headerLength = hasCRC ? 9 : 7
        let frameLength = headerLength + payload.count
        var bytes = Data([
            0xFF,
            hasCRC ? 0xF0 : 0xF1,
            0x4C,
            UInt8(0x80 | ((frameLength >> 11) & 0x03)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x07) << 5) | 0x1F),
            0xFC,
        ])
        if hasCRC {
            bytes.append(contentsOf: [0x12, 0x34])
        }
        bytes.append(payload)
        return bytes
    }
}

private extension AudioAssemblerEvent {
    var formatDescription: CMAudioFormatDescription? {
        guard case let .format(description, _, _) = self else { return nil }
        return description
    }

    var sample: CompressedAudioSample? {
        guard case let .sample(sample) = self else { return nil }
        return sample
    }
}
