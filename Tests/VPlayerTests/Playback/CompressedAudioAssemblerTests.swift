// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class CompressedAudioAssemblerTests: XCTestCase {
    func testGenerationRebindDropsLateAudioParserCallbackAndRebuildsAtNextPush() throws {
        let codec = VPlayerPlayback.AudioCodec.mp3
        let payload = AssemblerTestFixtures.syntheticMPEGFrame(codec: codec)
        let factory = ScriptedFFmpegParserFactory()
        let tracks = try AssemblerTestFixtures.audioTracks(codec: codec, extradata: Data())
        let binding = AssemblyEpochBinding(epochID: AssemblyEpochID(
            timelineEpoch: TimelineEpochID(rawValue: 1),
            instanceToken: 1
        ))
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks),
            binding: binding
        )
        let oldHandle = try XCTUnwrap(factory.handles.first)

        _ = binding.rebind()
        try oldHandle.emit(AssemblerTestFixtures.parsedAudioFrame(
            bytes: payload,
            pts: 0,
            frameSamples: 1_152
        ))
        XCTAssertTrue(events.isEmpty)

        try subject.push(AssemblerTestFixtures.audioPacket(data: payload, codec: codec))
        XCTAssertEqual(oldHandle.destroyCount, 1)
        XCTAssertEqual(factory.handles.count, 2)
        try XCTUnwrap(factory.handles.last).emit(AssemblerTestFixtures.parsedAudioFrame(
            bytes: payload,
            pts: 0,
            frameSamples: 1_152
        ))
        XCTAssertEqual(events.compactMap(\.frame).count, 1)
    }

    func testOversizedRawAACEmitsDecodeBreakAndNextValidAURecovers() throws {
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data([0x11, 0x90]))
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data(repeating: 0xA5, count: 1 * 1_024 * 1_024 + 1),
            codec: .aac
        ))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data([0x21, 0x22]),
            codec: .aac,
            pts: CMTime(value: 2, timescale: 1)
        ))

        XCTAssertEqual(events.kinds, ["decodeBreak", "format", "frame"])
        XCTAssertEqual(events.decodeBreakReasons, [.framingReset])
        XCTAssertEqual(events.compactMap(\.frame).map(\.payload), [Data([0x21, 0x22])])
    }

    func testRawAndADTSAACLCRegression() throws {
        let rawPayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let rawTracks = try AssemblerTestFixtures.audioTracks(extradata: Data([0x11, 0x90]))
        let rawEvents = try assemble(
            tracks: rawTracks,
            packets: [AssemblerTestFixtures.audioPacket(
                data: rawPayload,
                codec: .aac,
                pts: CMTime(value: -1, timescale: 2)
            )]
        )
        let rawConfiguration = try XCTUnwrap(rawEvents.compactMap(\.configuration).first)
        let rawFrame = try XCTUnwrap(rawEvents.compactMap(\.frame).first)

        XCTAssertEqual(rawEvents.kinds, ["format", "frame"])
        XCTAssertEqual(rawFrame.payload, rawPayload)
        XCTAssertEqual(rawFrame.presentationTimeStamp, CMTime(value: -1, timescale: 2))
        XCTAssertEqual(rawFrame.duration, CMTime(value: 1_024, timescale: 48_000))
        XCTAssertEqual(rawFrame.frameSampleCount, 1_024)
        XCTAssertEqual(rawConfiguration.decoderExtradata, Data([0x11, 0x90]))
        try assertFormat(
            rawConfiguration.formatDescription,
            formatID: kAudioFormatMPEG4AAC,
            framesPerPacket: 1_024,
            cookie: coreAudioCookie(for: Data([0x11, 0x90]))
        )

        let adtsPayload = Data([0x21, 0x10, 0x56, 0xE5])
        let adts = makeADTSFrame(payload: adtsPayload, hasCRC: false)
        let adtsTracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let adtsEvents = try assemble(
            tracks: adtsTracks,
            packets: [
                AssemblerTestFixtures.audioPacket(
                    data: Data(adts.prefix(5)), codec: .aac,
                    pts: CMTime(value: 1, timescale: 2)
                ),
                AssemblerTestFixtures.audioPacket(
                    data: Data(adts.dropFirst(5)), codec: .aac,
                    pts: CMTime(value: 3, timescale: 2)
                ),
            ]
        )
        let adtsConfiguration = try XCTUnwrap(adtsEvents.compactMap(\.configuration).first)
        let adtsFrame = try XCTUnwrap(adtsEvents.compactMap(\.frame).first)

        XCTAssertEqual(adtsEvents.kinds, ["format", "frame"])
        XCTAssertEqual(adtsFrame.payload, adtsPayload)
        XCTAssertEqual(adtsFrame.presentationTimeStamp, CMTime(value: 1, timescale: 2))
        XCTAssertEqual(adtsFrame.frameSampleCount, 1_024)
        XCTAssertEqual(adtsConfiguration.decoderExtradata, Data([0x11, 0x90]))
        try assertFormat(
            adtsConfiguration.formatDescription,
            formatID: kAudioFormatMPEG4AAC,
            framesPerPacket: 1_024,
            cookie: coreAudioCookie(for: Data([0x11, 0x90]))
        )
    }

    func testExplicitHEAACV1AndV2Configurations() throws {
        let cases: [(Data, AudioFormatID)] = [
            (Data([0x2B, 0x11, 0x88, 0x00]), kAudioFormatMPEG4AAC_HE),
            (Data([0xEB, 0x09, 0x88, 0x00]), kAudioFormatMPEG4AAC_HE_V2),
        ]

        for (asc, formatID) in cases {
            let tracks = try AssemblerTestFixtures.audioTracks(extradata: asc)
            let events = try assemble(
                tracks: tracks,
                packets: [AssemblerTestFixtures.audioPacket(
                    data: Data([0x31, 0x32]), codec: .aac
                )]
            )
            let configuration = try XCTUnwrap(events.compactMap(\.configuration).first)
            let frame = try XCTUnwrap(events.compactMap(\.frame).first)

            XCTAssertEqual(events.kinds, ["format", "frame"])
            XCTAssertEqual(frame.frameSampleCount, 2_048)
            XCTAssertEqual(frame.duration, CMTime(value: 2_048, timescale: 48_000))
            XCTAssertEqual(configuration.decoderExtradata, asc)
            try assertFormat(
                configuration.formatDescription,
                formatID: formatID,
                framesPerPacket: 2_048,
                cookie: coreAudioCookie(for: asc)
            )
        }
    }

    func testSplitAndConcatenatedMP1MP2MP3ParserFrames() throws {
        let cases: [(VPlayerPlayback.AudioCodec, Int32)] = [
            (.mp1, 384), (.mp2, 1_152), (.mp3, 1_152),
        ]
        for (codec, frameSamples) in cases {
            let payload = AssemblerTestFixtures.syntheticMPEGFrame(codec: codec)
            let firstCount = payload.count / 2
            let factory = ScriptedFFmpegParserFactory { handle, index, bytes, _, _, _ in
                switch index {
                case 0:
                    XCTAssertEqual(bytes, Data(payload.prefix(firstCount)))
                case 1:
                    XCTAssertEqual(bytes, Data(payload.dropFirst(firstCount)))
                    try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                        bytes: payload, pts: 90_000, frameSamples: frameSamples
                    ))
                case 2:
                    XCTAssertEqual(bytes, payload + payload)
                    try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                        bytes: payload, pts: 180_000, frameSamples: frameSamples
                    ))
                    let tickOffset = Int64(frameSamples) * 90_000 / 48_000
                    try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                        bytes: payload,
                        pts: 180_000 + tickOffset,
                        frameSamples: frameSamples
                    ))
                default:
                    XCTFail("unexpected parser push")
                }
            }
            let tracks = try AssemblerTestFixtures.audioTracks(
                codec: codec,
                extradata: Data()
            )
            var events: [AudioAssemblerEvent] = []
            let subject = try CompressedAudioAssembler(
                trackSet: tracks,
                generationProvider: { MediaGeneration(rawValue: 3) },
                eventSink: { events.append($0) },
                parserFactory: factory,
                formatState: AssemblyFormatState(trackSet: tracks)
            )

            try subject.push(AssemblerTestFixtures.audioPacket(
                data: Data(payload.prefix(firstCount)), codec: codec
            ))
            XCTAssertTrue(events.isEmpty)
            try subject.push(AssemblerTestFixtures.audioPacket(
                data: Data(payload.dropFirst(firstCount)), codec: codec
            ))
            try subject.push(AssemblerTestFixtures.audioPacket(
                data: payload + payload,
                codec: codec,
                pts: CMTime(value: 2, timescale: 1)
            ))

            XCTAssertEqual(events.kinds, ["format", "frame", "frame", "frame"])
            XCTAssertEqual(events.compactMap(\.frame).map(\.payload), [payload, payload, payload])
            XCTAssertEqual(
                events.compactMap(\.frame).map(\.presentationTimeStamp),
                [
                    CMTime(value: 1, timescale: 1),
                    CMTime(value: 2, timescale: 1),
                    CMTime(value: 180_000 + Int64(frameSamples) * 90_000 / 48_000,
                           timescale: 90_000),
                ]
            )
            XCTAssertEqual(factory.configurations.map(\.codec), [.audio(codec)])
        }
    }

    func testParserResetsAfterCorruptMPEGInput() throws {
        let codec = VPlayerPlayback.AudioCodec.mp3
        let payload = AssemblerTestFixtures.syntheticMPEGFrame(codec: codec)
        let factory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                frameSamples: 1_152
            ))
        }
        let tracks = try AssemblerTestFixtures.audioTracks(codec: codec, extradata: Data())
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 5) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: payload, codec: codec, isCorrupt: true
        ))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: payload,
            codec: codec,
            pts: CMTime(value: 2, timescale: 1)
        ))

        XCTAssertEqual(events.kinds, ["decodeBreak", "format", "frame"])
        XCTAssertEqual(events.decodeBreakReasons, [.corruptPacket])
        XCTAssertEqual(factory.handles.count, 2)
        XCTAssertEqual(factory.handles[0].destroyCount, 1)
        XCTAssertEqual(factory.handles[1].pushCount, 1)
    }

    func testParserPreservesCorruptProvenanceAcrossBufferedPushAndDrain() throws {
        for releaseOnDrain in [false, true] {
            let codec = VPlayerPlayback.AudioCodec.mp3
            let payload = AssemblerTestFixtures.syntheticMPEGFrame(codec: codec)
            let splitIndex = payload.count / 2
            let factory = ScriptedFFmpegParserFactory(
                pushScript: { handle, pushIndex, _, pts, _, _ in
                    if handle.handleIndex == 0 {
                        guard !releaseOnDrain, pushIndex == 1 else { return }
                    }
                    try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                        bytes: payload,
                        pts: pts ?? 90_000,
                        frameSamples: 1_152
                    ))
                },
                drainScript: { handle, _ in
                    guard handle.handleIndex == 0, releaseOnDrain else { return }
                    try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                        bytes: payload,
                        pts: 90_000,
                        frameSamples: 1_152
                    ))
                }
            )
            let tracks = try AssemblerTestFixtures.audioTracks(codec: codec, extradata: Data())
            var events: [AudioAssemblerEvent] = []
            let subject = try CompressedAudioAssembler(
                trackSet: tracks,
                generationProvider: { MediaGeneration(rawValue: 6) },
                eventSink: { events.append($0) },
                parserFactory: factory,
                formatState: AssemblyFormatState(trackSet: tracks)
            )

            try subject.push(AssemblerTestFixtures.audioPacket(
                data: Data(payload.prefix(splitIndex)),
                codec: codec,
                isCorrupt: true
            ))
            XCTAssertTrue(events.isEmpty)
            try subject.push(AssemblerTestFixtures.audioPacket(
                data: Data(payload.dropFirst(splitIndex)),
                codec: codec
            ))
            if releaseOnDrain {
                XCTAssertTrue(events.isEmpty)
                try subject.drain()
            }
            try subject.push(AssemblerTestFixtures.audioPacket(
                data: payload,
                codec: codec,
                pts: CMTime(value: 2, timescale: 1)
            ))

            XCTAssertEqual(events.kinds, ["decodeBreak", "format", "frame"])
            XCTAssertEqual(events.decodeBreakReasons, [.corruptPacket])
            XCTAssertEqual(events.compactMap(\.frame).map(\.payload), [payload])
            XCTAssertEqual(factory.handles.count, 2)
            XCTAssertEqual(try XCTUnwrap(factory.handles.first).destroyCount, 1)
            XCTAssertEqual(try XCTUnwrap(factory.handles.last).pushCount, 1)
        }
    }

    func testAC3ValidCRCCorruptFlagSalvagesAndInvalidCRCEmitsDecodeBreak() throws {
        let valid = AssemblerTestFixtures.syntheticAC3Frame(acmod: 2, lfeon: false)
        var invalid = valid
        invalid[invalid.count - 1] ^= 1
        let factory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                frameSamples: 1_536
            ))
        }
        let tracks = try AssemblerTestFixtures.audioTracks(codec: .ac3, extradata: Data())
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 7) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: valid, codec: .ac3, isCorrupt: true
        ))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: invalid,
            codec: .ac3,
            pts: CMTime(value: 2, timescale: 1),
            isCorrupt: true
        ))

        XCTAssertEqual(events.kinds, ["format", "frame", "decodeBreak"])
        XCTAssertEqual(events.decodeBreakReasons, [.invalidFrame])
        XCTAssertEqual(events.compactMap(\.frame).map(\.payload), [valid])
        XCTAssertEqual(factory.handles.count, 2)
    }

    func testEAC3VariableSampleCountsRemainPerFrame() throws {
        let counts: [Int32] = [256, 512, 768, 1_536]
        let factory = ScriptedFFmpegParserFactory { handle, index, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                channels: 2,
                frameSamples: counts[index]
            ))
        }
        let tracks = try AssemblerTestFixtures.audioTracks(codec: .eac3, extradata: Data())
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 9) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        for (index, count) in counts.enumerated() {
            try subject.push(AssemblerTestFixtures.audioPacket(
                data: Data([0x0B, 0x77, 0x00, 0x03, UInt8(index), 0xA5, 0xA5, 0xA5]),
                codec: .eac3,
                pts: CMTime(value: Int64(index), timescale: 1)
            ))
            XCTAssertEqual(events.compactMap(\.frame).last?.frameSampleCount, count)
        }

        XCTAssertEqual(events.kinds, ["format", "frame", "frame", "frame", "frame"])
        XCTAssertEqual(events.compactMap(\.frame).map(\.frameSampleCount), counts)
        XCTAssertEqual(
            events.compactMap(\.frame).map(\.duration),
            counts.map { CMTime(value: Int64($0), timescale: 48_000) }
        )
    }

    func testFormatAlwaysPrecedesFirstFrameForFingerprint() throws {
        var generation = MediaGeneration(rawValue: 20)
        var timeline: [String] = []
        var events: [AudioAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data([0x11, 0x90]))
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
            data: Data([0x10]), codec: .aac
        ))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data([0x20]),
            codec: .aac,
            pts: CMTime(value: 2, timescale: 1)
        ))

        XCTAssertEqual(events.kinds, ["format", "frame", "frame"])
        XCTAssertEqual(events.compactMap(\.frame).map(\.generation.rawValue), [21, 21])
        XCTAssertEqual(timeline, ["format-21", "generation-21", "generation-21"])
    }

    func testSystemCookieAndSourceDecoderExtradataRemainDistinct() throws {
        let sourceExtradata = Data([0xDE, 0xC0, 0xDE])
        let payload = AssemblerTestFixtures.syntheticAC3Frame(acmod: 2, lfeon: false)
        let factory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes, pts: pts, frameSamples: 1_536
            ))
        }
        let tracks = try AssemblerTestFixtures.audioTracks(
            codec: .ac3,
            extradata: sourceExtradata
        )
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 4) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(data: payload, codec: .ac3))

        let configuration = try XCTUnwrap(events.compactMap(\.configuration).first)
        let cookie = try XCTUnwrap(copiedMagicCookie(configuration.formatDescription))
        XCTAssertEqual(configuration.decoderExtradata, sourceExtradata)
        XCTAssertEqual(factory.configurations.map(\.extradata), [sourceExtradata])
        XCTAssertNotEqual(cookie, sourceExtradata)
        XCTAssertEqual(cookie.count, 31)
    }

    func testRejectedFrameResetsFramerAndMarksDecodeBreakWithoutThrowing() throws {
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data([0x11, 0x90]))
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data([0xFF, 0xF1, 0x00]), codec: .aac
        ))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data([0x21, 0x22]),
            codec: .aac,
            pts: CMTime(value: 2, timescale: 1)
        ))

        XCTAssertEqual(events.kinds, ["decodeBreak", "format", "frame"])
        XCTAssertEqual(events.decodeBreakReasons, [.invalidFrame])
    }

    func testADTSImpossibleSyncAndPartialDrainAreFramingResets() throws {
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let valid = makeADTSFrame(payload: Data([0x21, 0x22]), hasCRC: false)

        var impossibleEvents: [AudioAssemblerEvent] = []
        let impossible = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { impossibleEvents.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )
        try impossible.push(AssemblerTestFixtures.audioPacket(
            data: Data([0x00]), codec: .aac
        ))
        try impossible.push(AssemblerTestFixtures.audioPacket(
            data: valid, codec: .aac, pts: CMTime(value: 2, timescale: 1)
        ))
        XCTAssertEqual(impossibleEvents.decodeBreakReasons, [.framingReset])
        XCTAssertEqual(impossibleEvents.kinds, ["decodeBreak", "format", "frame"])

        var drainEvents: [AudioAssemblerEvent] = []
        let partial = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { drainEvents.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )
        try partial.push(AssemblerTestFixtures.audioPacket(
            data: Data(valid.prefix(3)), codec: .aac
        ))
        try partial.drain()
        try partial.push(AssemblerTestFixtures.audioPacket(
            data: valid, codec: .aac, pts: CMTime(value: 2, timescale: 1)
        ))
        XCTAssertEqual(drainEvents.decodeBreakReasons, [.framingReset])
        XCTAssertEqual(drainEvents.kinds, ["decodeBreak", "format", "frame"])
    }

    func testADTSCorruptCompleteFrameKeepsTypedReasonAndRecoversInOrder() throws {
        let tracks = try AssemblerTestFixtures.audioTracks(extradata: Data())
        let valid = makeADTSFrame(payload: Data([0x21, 0x22]), hasCRC: false)
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: valid,
            codec: .aac,
            isCorrupt: true
        ))

        XCTAssertEqual(events.decodeBreakReasons, [.corruptPacket])
        XCTAssertEqual(events.kinds, ["decodeBreak"])
        XCTAssertTrue(events.compactMap(\.configuration).isEmpty)
        XCTAssertTrue(events.compactMap(\.frame).isEmpty)

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: valid,
            codec: .aac,
            pts: CMTime(value: 2, timescale: 1)
        ))

        XCTAssertEqual(events.decodeBreakReasons, [.corruptPacket])
        XCTAssertEqual(events.kinds, ["decodeBreak", "format", "frame"])
    }

    func testParserFailureAndCompleteInvalidFrameUseDifferentReasons() throws {
        let codec = VPlayerPlayback.AudioCodec.mp3
        let payload = AssemblerTestFixtures.syntheticMPEGFrame(codec: codec)
        let tracks = try AssemblerTestFixtures.audioTracks(codec: codec, extradata: Data())

        var parserFailureEvents: [AudioAssemblerEvent] = []
        let parserFailureFactory = ScriptedFFmpegParserFactory { _, _, _, _, _, _ in
            throw PlaybackCoreError.audioFallbackDecode(-7_001)
        }
        let parserFailure = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { parserFailureEvents.append($0) },
            parserFactory: parserFailureFactory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )
        try parserFailure.push(AssemblerTestFixtures.audioPacket(data: payload, codec: codec))
        XCTAssertEqual(parserFailureEvents.decodeBreakReasons, [.framingReset])

        var invalidFrameEvents: [AudioAssemblerEvent] = []
        let invalidFactsFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                frameSamples: 384
            ))
        }
        let invalidFrame = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { invalidFrameEvents.append($0) },
            parserFactory: invalidFactsFactory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )
        try invalidFrame.push(AssemblerTestFixtures.audioPacket(data: payload, codec: codec))
        XCTAssertEqual(invalidFrameEvents.decodeBreakReasons, [.invalidFrame])
    }

    func testIDExhaustionFromParserDrainRemainsTerminal() throws {
        let codec = VPlayerPlayback.AudioCodec.mp3
        let payload = AssemblerTestFixtures.syntheticMPEGFrame(codec: codec)
        let factory = ScriptedFFmpegParserFactory(
            pushScript: { handle, index, bytes, pts, _, _ in
                guard index == 0 else { return }
                try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                    bytes: bytes,
                    pts: pts,
                    frameSamples: 1_152
                ))
            },
            drainScript: { handle, _ in
                try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                    bytes: payload,
                    pts: 180_000,
                    frameSamples: 1_152
                ))
            }
        )
        let tracks = try AssemblerTestFixtures.audioTracks(codec: codec, extradata: Data())
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks),
            startingID: UInt64.max
        )

        try subject.push(AssemblerTestFixtures.audioPacket(data: payload, codec: codec))
        try subject.push(AssemblerTestFixtures.audioPacket(
            data: payload,
            codec: codec,
            pts: CMTime(value: 2, timescale: 1)
        ))
        XCTAssertThrowsError(try subject.drain()) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .audioFallbackDecode(CompressedAudioAssembler.idExhaustedErrorCode)
            )
        }
        XCTAssertTrue(events.decodeBreakReasons.isEmpty)
    }

    private func assemble(
        tracks: DemuxTrackSet,
        packets: [DemuxPacket]
    ) throws -> [AudioAssemblerEvent] {
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )
        for packet in packets { try subject.push(packet) }
        return events
    }

    private func assertFormat(
        _ format: CMAudioFormatDescription,
        formatID: AudioFormatID,
        framesPerPacket: UInt32,
        cookie: Data
    ) throws {
        let asbd = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        )
        XCTAssertEqual(asbd.mFormatID, formatID)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mFramesPerPacket, framesPerPacket)
        XCTAssertEqual(try copiedMagicCookie(format), cookie)
    }

    private func copiedMagicCookie(_ format: CMAudioFormatDescription) throws -> Data? {
        var size = 0
        guard let pointer = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size) else {
            XCTAssertEqual(size, 0)
            return nil
        }
        return Data(bytes: pointer, count: size)
    }

    private func makeADTSFrame(payload: Data, hasCRC: Bool) -> Data {
        let headerLength = hasCRC ? 9 : 7
        let frameLength = headerLength + payload.count
        var data = Data([
            0xFF,
            hasCRC ? 0xF0 : 0xF1,
            0x4C,
            UInt8(0x80 | ((frameLength >> 11) & 0x03)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x07) << 5) | 0x1F),
            0xFC,
        ])
        if hasCRC { data.append(contentsOf: [0x12, 0x34]) }
        data.append(payload)
        return data
    }

    private func coreAudioCookie(for asc: Data) -> Data {
        Data([
            0x03, UInt8(23 + asc.count), 0x00, 0x00, 0x00,
            0x04, UInt8(15 + asc.count), 0x40, 0x15,
            0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x05, UInt8(asc.count),
        ]) + asc + Data([0x06, 0x01, 0x02])
    }
}

private extension AudioAssemblerEvent {
    var configuration: CompressedAudioRenderConfiguration? {
        guard case let .format(value) = self else { return nil }
        return value
    }

    var frame: CompressedAudioFrame? {
        guard case let .frame(value) = self else { return nil }
        return value
    }

    var kind: String {
        switch self {
        case .format: "format"
        case .frame: "frame"
        case .decodeBreak: "decodeBreak"
        }
    }

    var decodeBreakReason: AudioDecodeBreakReason? {
        guard case let .decodeBreak(reason) = self else { return nil }
        return reason
    }
}

private extension Array where Element == AudioAssemblerEvent {
    var kinds: [String] { map(\.kind) }
    var decodeBreakReasons: [AudioDecodeBreakReason] { compactMap(\.decodeBreakReason) }
}
