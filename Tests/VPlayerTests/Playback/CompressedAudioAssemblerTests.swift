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
        let tracks = try AssemblerTestFixtures.audioTracks()
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { _ in },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.drain()
    }

    func testSplitSevenByteADTSBuildsStrippedCopiedAACSampleAndExactFormat() throws {
        let payload = Data([0x21, 0x10, 0x56, 0xE5])
        let frame = makeADTSFrame(payload: payload, hasCRC: false)
        var timeline: [String] = []
        var events: [AudioAssemblerEvent] = []
        var generation = MediaGeneration(rawValue: 10)
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
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
            formatState: AssemblyFormatState(trackSet: tracks)
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
        let adtsTracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let adts = try CompressedAudioAssembler(
            trackSet: adtsTracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { adtsEvents.append($0) },
            formatState: AssemblyFormatState(trackSet: adtsTracks)
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
        let rawTracks = try AssemblerTestFixtures.audioTracks(extradata: Data([0x11, 0x90]))
        let raw = try CompressedAudioAssembler(
            trackSet: rawTracks,
            generationProvider: { MediaGeneration(rawValue: 4) },
            eventSink: { rawEvents.append($0) },
            formatState: AssemblyFormatState(trackSet: rawTracks)
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

    func testMultipleADTSFramesInOnePacketDeriveExactAACCadence() throws {
        let firstPayload = Data([0x10, 0x11])
        let secondPayload = Data([0x20, 0x21, 0x22])
        let firstPTS = CMTime(value: 1, timescale: 1)
        var packetData = makeADTSFrame(payload: firstPayload, hasCRC: false)
        packetData.append(makeADTSFrame(payload: secondPayload, hasCRC: false))
        var events: [AudioAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: packetData,
            codec: .aac,
            pts: firstPTS
        ))

        let samples = events.compactMap(\.sample)
        XCTAssertEqual(try samples.map { try copiedSampleData($0.sampleBuffer) }, [
            firstPayload,
            secondPayload,
        ])
        XCTAssertEqual(samples.map(\.presentationTimeStamp), [
            firstPTS,
            CMTimeAdd(firstPTS, CMTime(value: 1_024, timescale: 48_000)),
        ])
    }

    func testSplitADTSFrameUsesDiscontinuousPTSForNextPacketFrameBoundary() throws {
        let firstPayload = Data([0x30, 0x31, 0x32])
        let secondPayload = Data([0x40, 0x41])
        let firstFrame = makeADTSFrame(payload: firstPayload, hasCRC: false)
        let secondFrame = makeADTSFrame(payload: secondPayload, hasCRC: false)
        let firstPTS = CMTime(value: 1, timescale: 1)
        let discontinuousPTS = CMTime(value: 10, timescale: 1)
        var events: [AudioAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data(firstFrame.prefix(5)),
            codec: .aac,
            pts: firstPTS
        ))
        var secondPacket = Data(firstFrame.dropFirst(5))
        secondPacket.append(secondFrame)
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: secondPacket,
            codec: .aac,
            pts: discontinuousPTS
        ))

        let samples = events.compactMap(\.sample)
        XCTAssertEqual(try samples.map { try copiedSampleData($0.sampleBuffer) }, [
            firstPayload,
            secondPayload,
        ])
        XCTAssertEqual(samples.map(\.presentationTimeStamp), [firstPTS, discontinuousPTS])
    }

    func testResetClearsADTSTimestampProvenanceAndInvalidPTSIsRejected() throws {
        let frame = makeADTSFrame(payload: Data([0x50, 0x51]), hasCRC: false)
        var events: [AudioAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data(frame.prefix(4)),
            codec: .aac,
            pts: CMTime(value: 2, timescale: 1)
        ))

        try subject.reset(for: AssemblerTestFixtures.audioTracks(
            streamIndex: 2,
            extradata: Data()
        ))
        let resetPTS = CMTime(value: 20, timescale: 1)
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: frame,
            streamIndex: 2,
            codec: .aac,
            pts: resetPTS
        ))
        XCTAssertEqual(events.compactMap(\.sample).map(\.presentationTimeStamp), [resetPTS])

        XCTAssertThrowsError(try subject.push(AssemblerTestFixtures.audioPacket(
            data: frame,
            streamIndex: 2,
            codec: .aac,
            pts: .invalid
        )))
        XCTAssertEqual(events.compactMap(\.sample).count, 1)
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
        let tracks = try AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 3) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
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

    func testMP2ParserExtradataIsForwardedWithoutBecomingMagicCookie() throws {
        try assertNonAACParserExtradata(
            codec: .mp2,
            frameSamples: 1_152,
            expectedFormatID: kAudioFormatMPEGLayer2,
            expectedFramesPerPacket: 1_152
        )
    }

    func testAC3ParserExtradataIsForwardedWithoutBecomingMagicCookie() throws {
        try assertNonAACParserExtradata(
            codec: .ac3,
            frameSamples: 1_536,
            expectedFormatID: kAudioFormatAC3,
            expectedFramesPerPacket: 1_536
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
            let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
            let subject = try CompressedAudioAssembler(
                trackSet: tracks,
                generationProvider: { MediaGeneration(rawValue: 0) },
                eventSink: { _ in },
                formatState: AssemblyFormatState(trackSet: tracks)
            )
            XCTAssertThrowsError(try subject.push(
                AssemblerTestFixtures.audioPacket(data: malformed, codec: .aac)
            ))
        }

        let incompleteTracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let incomplete = try CompressedAudioAssembler(
            trackSet: incompleteTracks,
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            formatState: AssemblyFormatState(trackSet: incompleteTracks)
        )
        try incomplete.push(AssemblerTestFixtures.audioPacket(
            data: Data([0xFF, 0xF1, 0x4C]),
            codec: .aac
        ))
        XCTAssertThrowsError(try incomplete.drain())

        let invalidASCTracks = try AssemblerTestFixtures.audioTracks(extradata: Data([0x2B, 0x92]))
        XCTAssertThrowsError(try CompressedAudioAssembler(
            trackSet: invalidASCTracks,
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            formatState: AssemblyFormatState(trackSet: invalidASCTracks)
        ))

        let invalidPTSTracks = try AssemblerTestFixtures.audioTracks()
        let invalidPTS = try CompressedAudioAssembler(
            trackSet: invalidPTSTracks,
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            formatState: AssemblyFormatState(trackSet: invalidPTSTracks)
        )
        XCTAssertThrowsError(try invalidPTS.push(AssemblerTestFixtures.audioPacket(
            data: Data([1]),
            codec: .aac,
            pts: .invalid
        )))

        let collisionFactory = ScriptedFFmpegParserFactory()
        let collisionTracks = try AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data())
        let timestampCollision = try CompressedAudioAssembler(
            trackSet: collisionTracks,
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            parserFactory: collisionFactory,
            formatState: AssemblyFormatState(trackSet: collisionTracks)
        )
        XCTAssertThrowsError(try timestampCollision.push(AssemblerTestFixtures.audioPacket(
            data: Data([0xFF]),
            codec: .mp2,
            pts: CMTime(value: Int64.min, timescale: 90_000)
        ))) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .audioFallbackDecode(CompressedAudioAssembler.invalidInputErrorCode)
            )
        }
        XCTAssertEqual(collisionFactory.handles[0].pushCount, 0)

        let mismatchFactory = ScriptedFFmpegParserFactory { handle, _, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: Data([1]),
                sampleRate: 44_100,
                channels: 1,
                frameSamples: 1_152,
                nativeMask: 1
            ))
        }
        let mismatchTracks = try AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data())
        let mismatch = try CompressedAudioAssembler(
            trackSet: mismatchTracks,
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            parserFactory: mismatchFactory,
            formatState: AssemblyFormatState(trackSet: mismatchTracks)
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
        let badCountTracks = try AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data())
        let badCount = try CompressedAudioAssembler(
            trackSet: badCountTracks,
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { _ in },
            parserFactory: badCountFactory,
            formatState: AssemblyFormatState(trackSet: badCountTracks)
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
        let tracks = try AssemblerTestFixtures.audioTracks(codec: .mp2, extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
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
            formatState: AssemblyFormatState(trackSet: tracks),
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
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 0) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
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

    func testVersionedCABIValidatesEveryConfigAndPointerBoundary() throws {
        XCTAssertEqual(VPFF_PARSER_ABI_VERSION, 1)
        XCTAssertEqual(
            MemoryLayout<VPFFParserConfigV1>.stride,
            Int(UInt32(MemoryLayout<VPFFParserConfigV1>.stride))
        )
        assertParserConfigRejected { $0.abi_version = 2 }
        assertParserConfigRejected { $0.struct_size -= 1 }
        assertParserConfigRejected { $0.codec = VPFFCodec(rawValue: 99) }
        assertParserConfigRejected { $0.time_base_num = 0 }
        assertParserConfigRejected { $0.time_base_den = -1 }
        assertParserConfigRejected { $0.sample_rate = 0 }
        assertParserConfigRejected { $0.channel_count = 0 }
        assertParserConfigRejected { $0.channel_order = VPFFChannelOrder(rawValue: 99) }
        assertParserConfigRejected { $0.has_channel_layout_mask = 2 }
        assertParserConfigRejected { $0.channel_layout_mask = 0 }
        assertParserConfigRejected { $0.channel_layout_mask = 1 }
        assertParserConfigRejected {
            $0.channel_order = VPFF_CHANNEL_ORDER_UNSPECIFIED
            $0.has_channel_layout_mask = 0
        }

        var extradataByte: UInt8 = 0xAA
        withUnsafePointer(to: &extradataByte) { pointer in
            assertParserConfigRejected {
                $0.extradata = pointer
                $0.extradata_size = 0
            }
        }
        assertParserConfigRejected { $0.extradata_size = 1 }

        var valid = validParserConfiguration()
        var native: OpaquePointer?
        XCTAssertLessThan(vp_ffmpeg_parser_create_v1(
            &valid,
            nil,
            nil,
            &native
        ), 0)
        XCTAssertNil(native)
        XCTAssertLessThan(vp_ffmpeg_parser_create_v1(
            &valid,
            { _, _ in },
            nil,
            nil
        ), 0)
        XCTAssertLessThan(vp_ffmpeg_parser_create(
            VPFF_CODEC_MP2,
            nil,
            0,
            { _, _ in },
            nil,
            &native
        ), 0)
        XCTAssertNil(native)

        XCTAssertEqual(vp_ffmpeg_parser_create_v1(
            &valid,
            { _, _ in },
            nil,
            &native
        ), 0)
        let parser = try XCTUnwrap(native)
        // Empty input cannot advance parser state and must fail without entering a spin.
        XCTAssertLessThan(vp_ffmpeg_parser_push(
            parser,
            nil,
            0,
            Int64.min,
            Int64.min,
            Int64.min
        ), 0)
        var byte: UInt8 = 0
        XCTAssertLessThan(vp_ffmpeg_parser_push(
            parser,
            &byte,
            0,
            Int64.min,
            Int64.min,
            Int64.min
        ), 0)
        XCTAssertLessThan(vp_ffmpeg_parser_push(
            parser,
            nil,
            1,
            Int64.min,
            Int64.min,
            Int64.min
        ), 0)
        XCTAssertEqual(vp_ffmpeg_parser_drain(parser), 0)
        XCTAssertEqual(vp_ffmpeg_parser_drain(parser), 0)
        XCTAssertLessThan(vp_ffmpeg_parser_push(
            parser,
            &byte,
            1,
            Int64.min,
            Int64.min,
            Int64.min
        ), 0)
        vp_ffmpeg_parser_destroy(parser)
        XCTAssertLessThan(vp_ffmpeg_parser_drain(nil), 0)
        vp_ffmpeg_parser_destroy(nil)

        var unspecified = validParserConfiguration()
        unspecified.channel_order = VPFF_CHANNEL_ORDER_UNSPECIFIED
        unspecified.has_channel_layout_mask = 0
        unspecified.channel_layout_mask = 0
        native = nil
        XCTAssertEqual(vp_ffmpeg_parser_create_v1(
            &unspecified,
            { _, _ in },
            nil,
            &native
        ), 0)
        vp_ffmpeg_parser_destroy(try XCTUnwrap(native))
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
        let tracks = try AssemblerTestFixtures.audioTracks(codec: codec, extradata: Data())
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
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

    private func assertNonAACParserExtradata(
        codec: VPlayerPlayback.AudioCodec,
        frameSamples: Int32,
        expectedFormatID: AudioFormatID,
        expectedFramesPerPacket: UInt32
    ) throws {
        let expectedExtradata = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var sourceExtradata = expectedExtradata
        let payload = Data([0xFF, 0xFD, 0xA5])
        let factory = ScriptedFFmpegParserFactory { handle, _, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: payload,
                frameSamples: frameSamples
            ))
        }
        var events: [AudioAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.audioTracks(
            codec: codec,
            extradata: sourceExtradata
        )
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 2) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        XCTAssertEqual(factory.configurations.map(\.extradata), [expectedExtradata])
        sourceExtradata.resetBytes(in: sourceExtradata.indices)
        XCTAssertEqual(factory.configurations.map(\.extradata), [expectedExtradata])

        try subject.push(AssemblerTestFixtures.audioPacket(data: Data([1]), codec: codec))

        guard let firstEvent = events.first,
              case let .format(format, eventCodec, fingerprint) = firstEvent else {
            return XCTFail("format must be first")
        }
        XCTAssertEqual(eventCodec, codec)
        XCTAssertEqual(
            fingerprint,
            try MediaFormatFingerprint(
                trackSet: tracks,
                videoParameterSets: [],
                audioCookie: nil
            )
        )
        try assertAudioFormat(
            format,
            formatID: expectedFormatID,
            framesPerPacket: expectedFramesPerPacket,
            cookie: nil
        )
        let sample = try XCTUnwrap(events.compactMap(\.sample).first)
        XCTAssertTrue(CMSampleBufferDataIsReady(sample.sampleBuffer))
        XCTAssertEqual(try copiedSampleData(sample.sampleBuffer), payload)
    }

    private func validParserConfiguration() -> VPFFParserConfigV1 {
        var configuration = VPFFParserConfigV1()
        configuration.abi_version = VPFF_PARSER_ABI_VERSION
        configuration.struct_size = UInt32(MemoryLayout<VPFFParserConfigV1>.stride)
        configuration.codec = VPFF_CODEC_MP2
        configuration.time_base_num = 1
        configuration.time_base_den = 90_000
        configuration.sample_rate = 48_000
        configuration.channel_count = 2
        configuration.channel_order = VPFF_CHANNEL_ORDER_NATIVE
        configuration.has_channel_layout_mask = 1
        configuration.channel_layout_mask = 3
        return configuration
    }

    private func assertParserConfigRejected(
        _ mutate: (inout VPFFParserConfigV1) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var configuration = validParserConfiguration()
        mutate(&configuration)
        var native: OpaquePointer?
        XCTAssertLessThan(vp_ffmpeg_parser_create_v1(
            &configuration,
            { _, _ in },
            nil,
            &native
        ), 0, file: file, line: line)
        XCTAssertNil(native, file: file, line: line)
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
