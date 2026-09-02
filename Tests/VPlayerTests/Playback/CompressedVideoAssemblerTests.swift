// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class CompressedVideoAssemblerTests: XCTestCase {
    func testGenerationRebindDropsLateParserCallbackAndRebuildsAtNextPush() throws {
        let factory = ScriptedFFmpegParserFactory()
        let tracks = try AssemblerTestFixtures.videoTracks()
        let binding = AssemblyEpochBinding(epochID: AssemblyEpochID(
            timelineEpoch: TimelineEpochID(rawValue: 1),
            instanceToken: 1
        ))
        var events: [VideoAssemblerEvent] = []
        let subject = try CompressedVideoAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks),
            binding: binding
        )
        let oldHandle = try XCTUnwrap(factory.handles.first)

        _ = binding.rebind()
        try oldHandle.emit(AssemblerTestFixtures.parsedVideoFrame(
            bytes: AssemblerTestFixtures.h264AccessUnit()
        ))
        XCTAssertTrue(events.isEmpty)

        try subject.push(AssemblerTestFixtures.videoPacket())
        XCTAssertEqual(oldHandle.destroyCount, 1)
        XCTAssertEqual(factory.handles.count, 2)
        try XCTUnwrap(factory.handles.last).emit(AssemblerTestFixtures.parsedVideoFrame(
            bytes: AssemblerTestFixtures.h264AccessUnit()
        ))
        XCTAssertEqual(events.compactMap(\.accessUnit).count, 1)
    }

    func testCanInitializeAndDrainWithoutFrames() throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        let tracks = DemuxTrackSet(
            selectedProgramID: 1,
            video: VideoTrackDescriptor(
                streamIndex: 0,
                codec: .h264,
                timeBase: timeBase,
                width: 1_920,
                height: 1_080,
                videoDelay: 0,
                extradata: Data()
            ),
            audio: nil
        )
        let subject = try CompressedVideoAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { _ in },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.drain()
    }

    func testDropsParsedFramesUntilRequiredParameterSetsArrive() throws {
        let earlyFrame = AssemblerTestFixtures.h264AccessUnit(
            sps: nil,
            pps: nil,
            nal: Data([0x41, 0x9A, 0x22])
        )
        let decodableFrame = AssemblerTestFixtures.h264AccessUnit()
        let factory = ScriptedFFmpegParserFactory { handle, index, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                bytes: index == 0 ? earlyFrame : decodableFrame,
                pts: Int64(90_000 + index * 3_600),
                dts: Int64(86_400 + index * 3_600),
                keyFrame: index != 0
            ))
        }
        let tracks = try AssemblerTestFixtures.videoTracks(extradata: Data())
        var events: [VideoAssemblerEvent] = []
        let subject = try CompressedVideoAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        XCTAssertNoThrow(try subject.push(AssemblerTestFixtures.videoPacket()))
        XCTAssertTrue(events.isEmpty)
        try subject.push(AssemblerTestFixtures.videoPacket())

        XCTAssertEqual(events.compactMap(\.formatFingerprint).count, 1)
        XCTAssertEqual(events.compactMap(\.accessUnit).count, 1)
        XCTAssertTrue(events.compactMap(\.accessUnit)[0].isRandomAccess)
    }

    func testInjectedFramingBuildsThreeCopiedReadyAccessUnitsWithExactMetadata() throws {
        let firstAU = AssemblerTestFixtures.h264AccessUnit()
        let secondAU = AssemblerTestFixtures.h264AccessUnit(
            sps: nil,
            pps: nil,
            nal: Data([0x41, 0x9A, 0x22])
        )
        let thirdAU = AssemblerTestFixtures.h264AccessUnit(
            sps: nil,
            pps: nil,
            nal: Data([0x41, 0x9B, 0x23])
        )
        let factory = ScriptedFFmpegParserFactory { handle, pushIndex, _, _, _, _ in
            switch pushIndex {
            case 0:
                break
            case 1:
                var callbackStorage = firstAU
                try handle.emit(AssemblerTestFixtures.parsedVideoFrame(bytes: callbackStorage))
                callbackStorage.resetBytes(in: callbackStorage.indices)
            default:
                try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                    bytes: secondAU,
                    pts: 93_000,
                    dts: 90_000,
                    keyFrame: false,
                    fieldOrder: 1,
                    pictureStructure: 1,
                    topFieldFirst: nil,
                    interlaced: false
                ))
                try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                    bytes: thirdAU,
                    pts: 96_000,
                    dts: 93_000,
                    keyFrame: false
                ))
            }
        }
        var events: [VideoAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.videoTracks()
        let subject = try CompressedVideoAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 4) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.videoPacket(data: Data([0, 0, 0, 1, 0x65])))
        XCTAssertTrue(events.isEmpty)
        try subject.push(AssemblerTestFixtures.videoPacket(data: Data([0x88, 0x84])))
        try subject.push(AssemblerTestFixtures.videoPacket(data: Data([9, 9, 9])))

        XCTAssertEqual(events.count, 4)
        guard events.count == 4 else { return }
        guard case .format = events[0] else { return XCTFail("format must be first") }
        let accessUnits = events.compactMap(\.accessUnit)
        XCTAssertEqual(accessUnits.map(\.id), [1, 2, 3])
        guard accessUnits.count == 3 else { return }
        XCTAssertTrue(accessUnits.allSatisfy { CMSampleBufferDataIsReady($0.sampleBuffer) })
        XCTAssertEqual(try accessUnits.map { try copiedSampleData($0.sampleBuffer) }, [
            try AnnexBScanner.scan(firstAU, codec: .h264).lengthPrefixedData,
            try AnnexBScanner.scan(secondAU, codec: .h264).lengthPrefixedData,
            try AnnexBScanner.scan(thirdAU, codec: .h264).lengthPrefixedData,
        ])
        XCTAssertEqual(accessUnits.map(\.generation), Array(repeating: MediaGeneration(rawValue: 4), count: 3))
        XCTAssertEqual(accessUnits.map(\.isRandomAccess), [true, false, false])
        XCTAssertEqual(accessUnits[0].parserMetadata, VideoParserMetadata(
            fieldOrder: .tt,
            pictureStructure: .frame,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: true,
            sourcePTS90k: 90_000
        ))
        XCTAssertEqual(accessUnits[1].parserMetadata.fieldOrder, .progressive)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(accessUnits[0].sampleBuffer), CMTime(value: 1, timescale: 1))
        XCTAssertEqual(CMSampleBufferGetDecodeTimeStamp(accessUnits[0].sampleBuffer), CMTime(value: 29, timescale: 30))
        XCTAssertFalse(CMSampleBufferGetDuration(accessUnits[0].sampleBuffer).isValid)
        XCTAssertFalse(try notSyncAttachment(accessUnits[0].sampleBuffer))
        XCTAssertTrue(try notSyncAttachment(accessUnits[1].sampleBuffer))
    }

    func testChangedSPSCommitsFormatBeforeGenerationProviderAndSuppressesIdenticalSets() throws {
        var changedSPS = AssemblerTestFixtures.h264SPS
        changedSPS[3] = 0x20
        let frames = [
            AssemblerTestFixtures.h264AccessUnit(),
            AssemblerTestFixtures.h264AccessUnit(),
            AssemblerTestFixtures.h264AccessUnit(sps: changedSPS),
        ]
        let factory = ScriptedFFmpegParserFactory { handle, index, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                bytes: frames[index],
                pts: Int64(90_000 + index * 3_000),
                dts: Int64(87_000 + index * 3_000)
            ))
        }
        var generation = MediaGeneration(rawValue: 0)
        var timeline: [String] = []
        var events: [VideoAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.videoTracks()
        let subject = try CompressedVideoAssembler(
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
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        for _ in frames {
            try subject.push(AssemblerTestFixtures.videoPacket())
        }

        let fingerprints = events.compactMap(\.formatFingerprint)
        XCTAssertEqual(fingerprints.count, 2)
        guard fingerprints.count == 2 else { return }
        XCTAssertNotEqual(fingerprints[0], fingerprints[1])
        XCTAssertEqual(events.compactMap(\.accessUnit).map(\.generation), [
            MediaGeneration(rawValue: 1),
            MediaGeneration(rawValue: 1),
            MediaGeneration(rawValue: 2),
        ])
        XCTAssertEqual(timeline, [
            "format-1", "generation-1", "generation-1", "format-2", "generation-2",
        ])
    }

    func testExactDuplicateParameterSetsDoNotReemitFormatOrAdvanceGeneration() throws {
        let firstFrame = AssemblerTestFixtures.h264AccessUnit()
        var duplicateFrame = AssemblerTestFixtures.annexBParameterSets([
            AssemblerTestFixtures.h264SPS,
            AssemblerTestFixtures.h264SPS,
            AssemblerTestFixtures.h264PPS,
        ])
        duplicateFrame.append(contentsOf: [0, 0, 0, 1, 0x41, 0x9A, 0x22])
        let frames = [firstFrame, duplicateFrame]
        let factory = ScriptedFFmpegParserFactory { handle, index, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                bytes: frames[index],
                pts: Int64(90_000 + index * 3_000),
                dts: Int64(87_000 + index * 3_000),
                keyFrame: index == 0
            ))
        }
        var generation = MediaGeneration(rawValue: 0)
        var timeline: [String] = []
        var events: [VideoAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.videoTracks()
        let subject = try CompressedVideoAssembler(
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
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.videoPacket())
        try subject.push(AssemblerTestFixtures.videoPacket())

        XCTAssertEqual(events.compactMap(\.formatFingerprint).count, 1)
        let accessUnits = events.compactMap(\.accessUnit)
        XCTAssertEqual(accessUnits.map(\.generation), [
            MediaGeneration(rawValue: 1),
            MediaGeneration(rawValue: 1),
        ])
        XCTAssertTrue(accessUnits.allSatisfy { CMSampleBufferDataIsReady($0.sampleBuffer) })
        XCTAssertEqual(timeline, ["format-1", "generation-1", "generation-1"])
    }

    func testSharedAVFingerprintsRemainCompleteAfterVideoThenAudioReset() throws {
        try assertSharedAVFingerprintsRemainComplete(resetVideoFirst: true)
    }

    func testSharedAVFingerprintsRemainCompleteAfterAudioThenVideoReset() throws {
        try assertSharedAVFingerprintsRemainComplete(resetVideoFirst: false)
    }

    func testScannerHandlesH264HEVCZerosAndRejectsMalformedAndOversizedUnits() throws {
        let h264 = Data([0, 0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xCE, 0, 0])
        let h264Result = try AnnexBScanner.scan(h264, codec: .h264)
        XCTAssertEqual(h264Result.parameterSets, [Data([0x67, 0x42]), Data([0x68, 0xCE])])
        XCTAssertEqual(h264Result.lengthPrefixedData, Data([
            0, 0, 0, 2, 0x67, 0x42,
            0, 0, 0, 2, 0x68, 0xCE,
        ]))

        let hevc = Data([
            0, 0, 0, 1, 32 << 1, 1,
            0, 0, 1, 33 << 1, 1,
            0, 0, 0, 1, 34 << 1, 1,
        ])
        XCTAssertEqual(
            try AnnexBScanner.scan(hevc, codec: .hevc).parameterSets.count,
            3
        )

        for malformed in [
            Data([0x65, 1]),
            Data([0, 0, 1]),
            Data([0, 0, 1, 0, 0, 1, 0x65]),
        ] {
            XCTAssertThrowsError(try AnnexBScanner.scan(malformed, codec: .h264)) { error in
                XCTAssertEqual(error as? PlaybackCoreError, .videoDecode(AnnexBScanner.invalidDataErrorCode))
            }
        }
        XCTAssertThrowsError(
            try AnnexBScanner.scan(
                Data(count: AnnexBScanner.maximumAccessUnitBytes + 1),
                codec: .h264
            )
        )
    }

    func testScannerRejectsOneByteHEVCNALHeader() throws {
        XCTAssertThrowsError(
            try AnnexBScanner.scan(Data([0, 0, 0, 1, 0x40]), codec: .hevc)
        ) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .videoDecode(AnnexBScanner.invalidDataErrorCode)
            )
        }
    }

    func testHEVCBuilderCreatesRealFormatAndReadySample() throws {
        let description = try VideoFormatDescriptionBuilder.make(
            codec: .hevc,
            parameterSets: [
                AssemblerTestFixtures.hevcVPS,
                AssemblerTestFixtures.hevcSPS,
                AssemblerTestFixtures.hevcPPS,
            ]
        )
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(description),
            kCMVideoCodecType_HEVC
        )
        let scan = try AnnexBScanner.scan(
            AssemblerTestFixtures.hevcAccessUnit(includeParameterSets: false),
            codec: .hevc
        )
        let sample = try SampleBufferBuilder.makeVideo(
            data: scan.lengthPrefixedData,
            formatDescription: description,
            presentationTimeStamp: CMTime(value: 1, timescale: 1),
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isRandomAccess: true
        )
        XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        XCTAssertEqual(try copiedSampleData(sample), scan.lengthPrefixedData)
        XCTAssertEqual(CMSampleBufferGetFormatDescription(sample), description)
    }

    func testExactTimestampConversionPreservesNegativeAndAbsentAndRejectsNonIntegral() throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        XCTAssertThrowsError(
            try exactTicks(
                CMTime(value: Int64.min, timescale: 90_000),
                timeBase: timeBase
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
            )
        }
        let factory = ScriptedFFmpegParserFactory()
        let tracks = try AssemblerTestFixtures.videoTracks()
        let subject = try CompressedVideoAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { _ in },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.videoPacket(
            pts: CMTime(value: -1, timescale: 30),
            dts: .invalid
        ))
        XCTAssertEqual(factory.handles[0].pushCount, 1)
        XCTAssertThrowsError(try subject.push(AssemblerTestFixtures.videoPacket(
            pts: CMTime(value: 1, timescale: 60_000),
            dts: .invalid
        ))) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
            )
        }
        XCTAssertThrowsError(try subject.push(AssemblerTestFixtures.videoPacket(
            pts: CMTime(value: Int64.min, timescale: 90_000),
            dts: .invalid
        ))) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .videoDecode(CompressedVideoAssembler.invalidInputErrorCode)
            )
        }
        XCTAssertEqual(factory.handles[0].pushCount, 1)
    }

    func testLiveNativeParserCopiesSynchronousCallbacksAndRoundTripsTimestampPresence() throws {
        let descriptor = try XCTUnwrap(AssemblerTestFixtures.videoTracks().video)
        var received: [FFmpegParsedFrame] = []
        let handle = try LiveFFmpegParserHandle(
            configuration: FFmpegParserConfiguration(video: descriptor),
            receiver: { received.append($0) }
        )
        var firstInput = AssemblerTestFixtures.h264ParserAccessUnit(
            includeParameterSets: true,
            nal: Data([0x65, 0x88, 0x84])
        )
        var secondInput = AssemblerTestFixtures.h264ParserAccessUnit(
            includeParameterSets: false,
            nal: Data([0x41, 0x9A, 0x22])
        )

        try handle.push(firstInput, pts: -90_000, dts: nil, duration: nil)
        firstInput.resetBytes(in: firstInput.indices)
        try handle.push(secondInput, pts: nil, dts: nil, duration: nil)
        XCTAssertEqual(received.count, 1, "the second push must synchronously emit the first AU")
        let copiedBeforeNativeReuse = try XCTUnwrap(received.first?.bytes)
        secondInput.resetBytes(in: secondInput.indices)
        try handle.drain()

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.map(\.pts), [-90_000, nil])
        XCTAssertEqual(received.map(\.dts), [nil, nil])
        XCTAssertEqual(received[0].bytes, copiedBeforeNativeReuse)
        XCTAssertFalse(received[0].bytes.allSatisfy { $0 == 0 })

        let collisionHandle = try LiveFFmpegParserHandle(
            configuration: FFmpegParserConfiguration(video: descriptor),
            receiver: { _ in }
        )
        XCTAssertThrowsError(try collisionHandle.push(
            AssemblerTestFixtures.h264ParserAccessUnit(
                includeParameterSets: false,
                nal: Data([0x41, 0x9B, 0x23])
            ),
            pts: Int64.min,
            dts: nil,
            duration: nil
        )) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .videoDecode(LiveFFmpegParserHandle.malformedFrameErrorCode)
            )
        }
    }

    #if DEBUG
    func testNativeParserTopFieldFirstUsesDisplayedFieldOrder() {
        let frame = Int32(VPFF_PICTURE_STRUCTURE_FRAME.rawValue)

        XCTAssertEqual(vp_ffmpeg_parser_debug_top_field_first(
            Int32(VPFF_FIELD_ORDER_TT.rawValue),
            frame
        ), 1)
        XCTAssertEqual(vp_ffmpeg_parser_debug_top_field_first(
            Int32(VPFF_FIELD_ORDER_BB.rawValue),
            frame
        ), 0)
        XCTAssertEqual(vp_ffmpeg_parser_debug_top_field_first(
            Int32(VPFF_FIELD_ORDER_TB.rawValue),
            frame
        ), 0)
        XCTAssertEqual(vp_ffmpeg_parser_debug_top_field_first(
            Int32(VPFF_FIELD_ORDER_BT.rawValue),
            frame
        ), 1)
    }
    #endif

    func testDrainRebindDiscardsOldStateAndIDsContinueUntilDeterministicExhaustion() throws {
        let delayedAU = AssemblerTestFixtures.h264AccessUnit()
        let factory = ScriptedFFmpegParserFactory(
            pushScript: { handle, _, _, _, _, _ in
                try handle.emit(AssemblerTestFixtures.parsedVideoFrame(bytes: delayedAU))
            },
            drainScript: { handle, drainIndex in
                if handle.handleIndex == 0, drainIndex == 0 {
                    try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                        bytes: delayedAU,
                        pts: 93_000,
                        dts: 90_000
                    ))
                }
            }
        )
        var events: [VideoAssemblerEvent] = []
        let tracks = try AssemblerTestFixtures.videoTracks()
        let binding = AssemblyEpochBinding(epochID: AssemblyEpochID(
            timelineEpoch: TimelineEpochID(rawValue: 8),
            instanceToken: 1
        ))
        let subject = try CompressedVideoAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 8) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            formatState: AssemblyFormatState(trackSet: tracks),
            binding: binding,
            startingID: UInt64.max - 1
        )

        try subject.push(AssemblerTestFixtures.videoPacket())
        try subject.drain()
        try subject.drain()
        _ = binding.rebind()
        XCTAssertEqual(events.compactMap(\.accessUnit).map(\.id), [UInt64.max - 1, UInt64.max])

        XCTAssertThrowsError(try subject.push(AssemblerTestFixtures.videoPacket())) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .videoDecode(CompressedVideoAssembler.idExhaustedErrorCode)
            )
        }
        XCTAssertEqual(factory.handles[0].destroyCount, 1)
        XCTAssertEqual(factory.handles.count, 2)
    }

    private func assertSharedAVFingerprintsRemainComplete(resetVideoFirst: Bool) throws {
        let initialASC = Data([0x11, 0x90])
        let initialAudio = try XCTUnwrap(AssemblerTestFixtures.audioTracks(
            extradata: initialASC
        ).audio)
        let initialParameterSets = [
            AssemblerTestFixtures.h264SPS,
            AssemblerTestFixtures.h264PPS,
        ]
        let initialTracks = try AssemblerTestFixtures.videoTracks(
            audio: initialAudio,
            extradata: AssemblerTestFixtures.annexBParameterSets(initialParameterSets)
        )
        let formatState = AssemblyFormatState(trackSet: initialTracks)
        let videoFactory = ScriptedFFmpegParserFactory { handle, _, _, _, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                bytes: AssemblerTestFixtures.h264AccessUnit(sps: nil, pps: nil)
            ))
        }
        var videoEvents: [VideoAssemblerEvent] = []
        var audioEvents: [AudioAssemblerEvent] = []
        let video = try CompressedVideoAssembler(
            trackSet: initialTracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { videoEvents.append($0) },
            parserFactory: videoFactory,
            formatState: formatState
        )
        let audio = try CompressedAudioAssembler(
            trackSet: initialTracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { audioEvents.append($0) },
            formatState: formatState
        )

        try video.push(AssemblerTestFixtures.videoPacket())
        try audio.push(AssemblerTestFixtures.audioPacket(
            data: Data([0x21, 0x10]),
            codec: .aac
        ))

        let initialExpected = try MediaFormatFingerprint(
            trackSet: initialTracks,
            videoParameterSets: initialParameterSets,
            audioSystemFormat: audioSystemFingerprintComponent(
                descriptor: initialAudio,
                magicCookie: try AudioSpecificConfig.parse(initialASC).coreAudioMagicCookie
            )
        )
        XCTAssertEqual(videoEvents.compactMap(\.formatFingerprint).last, initialExpected)
        XCTAssertEqual(audioEvents.compactMap(\.formatFingerprint).last, initialExpected)

        var changedSPS = AssemblerTestFixtures.h264SPS
        changedSPS[3] = 0x20
        let resetASC = Data([0x12, 0x10])
        let resetAudio = try XCTUnwrap(AssemblerTestFixtures.audioTracks(
            streamIndex: 3,
            sampleRate: 44_100,
            extradata: resetASC
        ).audio)
        let resetParameterSets = [changedSPS, AssemblerTestFixtures.h264PPS]
        let resetTracks = try AssemblerTestFixtures.videoTracks(
            streamIndex: 2,
            audio: resetAudio,
            extradata: AssemblerTestFixtures.annexBParameterSets(resetParameterSets)
        )
        let resetState = AssemblyFormatState(trackSet: resetTracks)
        let resetVideo: CompressedVideoAssembler
        let resetAudioAssembler: CompressedAudioAssembler
        if resetVideoFirst {
            resetVideo = try CompressedVideoAssembler(
                trackSet: resetTracks,
                generationProvider: { MediaGeneration(rawValue: 2) },
                eventSink: { videoEvents.append($0) },
                parserFactory: videoFactory,
                formatState: resetState
            )
            resetAudioAssembler = try CompressedAudioAssembler(
                trackSet: resetTracks,
                generationProvider: { MediaGeneration(rawValue: 2) },
                eventSink: { audioEvents.append($0) },
                formatState: resetState
            )
        } else {
            resetAudioAssembler = try CompressedAudioAssembler(
                trackSet: resetTracks,
                generationProvider: { MediaGeneration(rawValue: 2) },
                eventSink: { audioEvents.append($0) },
                formatState: resetState
            )
            resetVideo = try CompressedVideoAssembler(
                trackSet: resetTracks,
                generationProvider: { MediaGeneration(rawValue: 2) },
                eventSink: { videoEvents.append($0) },
                parserFactory: videoFactory,
                formatState: resetState
            )
        }

        try resetVideo.push(AssemblerTestFixtures.videoPacket(streamIndex: 2))
        try resetAudioAssembler.push(AssemblerTestFixtures.audioPacket(
            data: Data([0x22, 0x11]),
            streamIndex: 3,
            codec: .aac,
            pts: CMTime(value: 180_000, timescale: 90_000)
        ))

        let resetExpected = try MediaFormatFingerprint(
            trackSet: resetTracks,
            videoParameterSets: resetParameterSets,
            audioSystemFormat: audioSystemFingerprintComponent(
                descriptor: resetAudio,
                magicCookie: try AudioSpecificConfig.parse(resetASC).coreAudioMagicCookie
            )
        )
        XCTAssertEqual(videoEvents.compactMap(\.formatFingerprint).last, resetExpected)
        XCTAssertEqual(audioEvents.compactMap(\.formatFingerprint).last, resetExpected)
        XCTAssertEqual(
            videoEvents.compactMap(\.formatFingerprint).last,
            audioEvents.compactMap(\.formatFingerprint).last
        )
    }

    private func notSyncAttachment(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) else {
            return false
        }
        let attachments = rawAttachments as NSArray
        let first = try XCTUnwrap(attachments.firstObject as? NSDictionary)
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    }

    private func audioSystemFingerprintComponent(
        descriptor: AudioTrackDescriptor,
        magicCookie: Data
    ) -> AudioSystemFormatFingerprintComponent {
        let layout: CoreAudioLayoutSpec
        if let nativeMask = descriptor.channelLayout.nativeMask {
            layout = .bitmap(AudioChannelBitmap(rawValue: UInt32(nativeMask)))
        } else {
            layout = .discrete(UInt32(descriptor.channelLayout.channelCount))
        }
        return AudioSystemFormatFingerprintComponent(
            profileID: .aacLC,
            formatID: kAudioFormatMPEG4AAC,
            sampleRate: descriptor.sampleRate,
            channelCount: descriptor.channelLayout.channelCount,
            framesPerPacket: 1_024,
            layout: layout,
            magicCookie: magicCookie
        )
    }
}

private extension VideoAssemblerEvent {
    var accessUnit: CompressedVideoAccessUnit? {
        guard case let .accessUnit(value) = self else { return nil }
        return value
    }

    var formatFingerprint: MediaFormatFingerprint? {
        guard case let .format(_, value) = self else { return nil }
        return value
    }
}

private extension AudioAssemblerEvent {
    var formatFingerprint: MediaFormatFingerprint? {
        guard case let .format(configuration) = self else { return nil }
        return configuration.fingerprint
    }
}
