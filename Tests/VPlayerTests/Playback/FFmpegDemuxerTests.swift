// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Dispatch
import Foundation
import XCTest
@testable import VPlayerPlayback

final class FFmpegDemuxerTests: XCTestCase {
#if DEBUG
    func testBootstrapPacketLimitAccepts64AndRejects65WithoutLeaking() {
        let accepted = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_EXACT)
        XCTAssertEqual(accepted.status, 0)
        XCTAssertEqual(accepted.details.peak_packet_count, 64)
        XCTAssertEqual(accepted.details.live_resource_count, 0)

        let rejected = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_OVERFLOW)
        XCTAssertLessThan(rejected.status, 0)
        XCTAssertEqual(rejected.details.peak_packet_count, 64)
        XCTAssertEqual(rejected.details.live_resource_count, 0)
    }

    func testBootstrapByteLimitAcceptsExactBoundAndRejectsOneByteOverWithoutLeaking() {
        let accepted = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_EXACT)
        XCTAssertEqual(accepted.status, 0)
        XCTAssertEqual(accepted.details.peak_accounted_bytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(accepted.details.live_resource_count, 0)

        let rejected = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_OVERFLOW)
        XCTAssertLessThan(rejected.status, 0)
        XCTAssertLessThan(rejected.details.peak_accounted_bytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(rejected.details.live_resource_count, 0)
    }

    func testBootstrapRejectsEOFAndBothParserZeroProgressFormsWithoutLeaking() {
        let eof = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_EOF_BEFORE_DIMENSIONS)
        XCTAssertLessThan(eof.status, 0)
        XCTAssertEqual(eof.details.live_resource_count, 0)

        let noOutput = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_NO_OUTPUT)
        XCTAssertLessThan(noOutput.status, 0)
        XCTAssertEqual(noOutput.details.parser_call_count, 1)
        XCTAssertEqual(noOutput.details.live_resource_count, 0)

        let retry = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_WITH_OUTPUT)
        XCTAssertEqual(retry.status, 0)
        XCTAssertEqual(retry.details.parser_call_count, 2)
        XCTAssertEqual(retry.details.retried_same_input, 1)
        XCTAssertEqual(retry.details.live_resource_count, 0)

        let repeated = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_REPEATED_ZERO_CONSUMED)
        XCTAssertLessThan(repeated.status, 0)
        XCTAssertEqual(repeated.details.parser_call_count, 2)
        XCTAssertEqual(repeated.details.retried_same_input, 1)
        XCTAssertEqual(repeated.details.live_resource_count, 0)
    }

    func testBootstrapRestoresInitialAndPacketLocalStreamStateInReplayOrder() {
        let result = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_SNAPSHOT_REPLAY)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.details.initial_width, 1_280)
        XCTAssertEqual(result.details.initial_height, 720)
        XCTAssertEqual(result.details.replayed_packet_count, 3)
        XCTAssertEqual(result.details.first_replay_width, 1_280)
        XCTAssertEqual(result.details.first_replay_time_base_num, 1)
        XCTAssertEqual(result.details.first_replay_time_base_den, 90_000)
        XCTAssertEqual(result.details.second_replay_sample_rate, 48_000)
        XCTAssertEqual(result.details.second_replay_time_base_num, 1)
        XCTAssertEqual(result.details.second_replay_time_base_den, 48_000)
        XCTAssertEqual(result.details.third_replay_width, 1_920)
        XCTAssertEqual(result.details.third_replay_height, 1_080)
        XCTAssertEqual(result.details.third_replay_time_base_num, 1)
        XCTAssertEqual(result.details.third_replay_time_base_den, 45_000)
        XCTAssertEqual(result.details.live_resource_count, 0)
    }
#endif

    func testAcceptsHTTPAndHTTPSAndPreservesExactUTF8BytesAndLength() throws {
        for rawURL in ["http://example.invalid/live.ts", "https://example.invalid/频道.m3u8"] {
            let bridge = FakeFFmpegDemuxBridge()
            let recorder = DemuxEventRecorder()
            let subject = FFmpegDemuxer(bridge: bridge)
            let url = try XCTUnwrap(URL(string: rawURL))

            try subject.start(url: url, sink: recorder.record)

            XCTAssertEqual(recorder.waitForTerminal().last, .endOfStream)
            XCTAssertEqual(bridge.createCount, 1)
            XCTAssertEqual(bridge.urlBytes, Data(url.absoluteString.utf8))
            XCTAssertEqual(bridge.timeoutUS, 10_000_000)
        }
    }

    func testRejectsEveryNonHTTPTopLevelSchemeBeforeCreatingBridge() throws {
        for rawURL in [
            "udp://239.1.1.1:1234",
            "rtp://239.1.1.1:1234",
            "file:///tmp/video.ts",
            "tcp://example.invalid:80",
            "data:text/plain,hello",
            "crypto+http://example.invalid/live.ts",
            "relative/path",
        ] {
            let bridge = FakeFFmpegDemuxBridge()
            let subject = FFmpegDemuxer(bridge: bridge)
            let url = try XCTUnwrap(URL(string: rawURL))
            let expectedScheme = url.scheme?.lowercased() ?? ""

            XCTAssertThrowsError(try subject.start(url: url, sink: { _ in })) { error in
                XCTAssertEqual(error as? PlaybackCoreError, .unsupportedProtocol(expectedScheme))
            }
            XCTAssertEqual(bridge.createCount, 0)
        }
    }

    func testRawBorrowedTrackAndPacketBytesAreCopiedBeforeCallbackReturns() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(
                programID: 42,
                video: .h264(extradata: Data([1, 2, 3])),
                audio: .aac(extradata: Data([0x12, 0x10])),
                mutateBorrowedBytesAfterCallback: true
            )
            handle.emitPacket(
                .init(
                    streamIndex: 7,
                    codec: VPFF_CODEC_H264,
                    data: Data([0, 0, 1, 9, 0xF0]),
                    pts: 90_000,
                    dts: 87_000,
                    duration: 3_003,
                    isKey: true,
                    isCorrupt: true
                ),
                mutateBorrowedBytesAfterCallback: true
            )
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge)

        try subject.start(url: try httpURL(), sink: recorder.record)
        let events = recorder.waitForTerminal()

        guard case let .tracks(tracks) = events.first else {
            return XCTFail("tracks must be first")
        }
        XCTAssertEqual(tracks.selectedProgramID, 42)
        XCTAssertEqual(tracks.video?.extradata, Data([1, 2, 3]))
        XCTAssertEqual(tracks.audio?.extradata, Data([0x12, 0x10]))
        guard case let .packet(packet) = events.dropFirst().first else {
            return XCTFail("packet must follow tracks")
        }
        XCTAssertEqual(packet.data, Data([0, 0, 1, 9, 0xF0]))
        XCTAssertEqual(packet.presentationTimeStamp, CMTime(value: 1, timescale: 1))
        XCTAssertEqual(packet.decodeTimeStamp, CMTime(value: 29, timescale: 30))
        XCTAssertEqual(packet.duration, CMTime(value: 1_001, timescale: 30_000))
        XCTAssertTrue(packet.isKey)
        XCTAssertTrue(packet.isCorrupt)
        XCTAssertEqual(events.last, .endOfStream)
    }

    func testCopiesProgramPresenceAndUnspecifiedAndNativeChannelLayouts() throws {
        let unspecified = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(audio: .aac(
                channelOrder: VPFF_CHANNEL_ORDER_UNSPECIFIED,
                hasMask: false
            ))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let native = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(
                programID: 0,
                audio: .aac(
                    channelOrder: VPFF_CHANNEL_ORDER_NATIVE,
                    hasMask: true,
                    mask: 3
                )
            )
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let unspecifiedEvents = try run(bridge: unspecified)
        let nativeEvents = try run(bridge: native)
        guard case let .tracks(first) = unspecifiedEvents.first,
              case let .tracks(second) = nativeEvents.first else {
            return XCTFail("missing track events")
        }
        XCTAssertNil(first.selectedProgramID)
        XCTAssertNil(first.audio?.channelLayout.nativeMask)
        XCTAssertEqual(second.selectedProgramID, 0)
        XCTAssertEqual(second.audio?.channelLayout.nativeMask, 3)
    }

    func testCopiesEveryNonnegativeVideoDelayExactly() throws {
        for expected in [Int32(0), 1, 3] {
            let bridge = FakeFFmpegDemuxBridge { handle in
                handle.emitTracks(video: .h264(videoDelay: expected))
                handle.emitTerminal(VPFF_EVENT_END)
                return 0
            }

            let events = try run(bridge: bridge)

            guard case let .tracks(tracks) = events.first else {
                return XCTFail("missing tracks for video delay \(expected)")
            }
            XCTAssertEqual(tracks.video?.videoDelay, expected)
            XCTAssertEqual(events.last, .endOfStream)
        }
    }

    func testMapsEverySupportedCodecAndPreservesNegativeAndInvalidTimes() throws {
        let specs: [(VPFFCodec, MediaCodec)] = [
            (VPFF_CODEC_H264, .video(.h264)),
            (VPFF_CODEC_HEVC, .video(.hevc)),
            (VPFF_CODEC_AAC, .audio(.aac)),
            (VPFF_CODEC_AC3, .audio(.ac3)),
            (VPFF_CODEC_EAC3, .audio(.eac3)),
            (VPFF_CODEC_MP2, .audio(.mp2)),
        ]
        let bridge = FakeFFmpegDemuxBridge { handle in
            for (index, entry) in specs.enumerated() {
                handle.emitPacket(.init(
                    streamIndex: Int32(index),
                    codec: entry.0,
                    data: Data([UInt8(index)]),
                    pts: -3_003,
                    dts: Int64.min,
                    duration: -1
                ))
            }
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let events = try run(bridge: bridge)
        let packets = events.compactMap(\.packet)
        XCTAssertEqual(packets.map(\.codec), specs.map { $0.1 })
        XCTAssertTrue(packets.allSatisfy { $0.presentationTimeStamp == CMTime(value: -1_001, timescale: 30_000) })
        XCTAssertTrue(packets.allSatisfy { !$0.decodeTimeStamp.isValid })
        XCTAssertTrue(packets.allSatisfy { !$0.duration.isValid })
    }

    func testUnsupportedCodecCustomAndAmbisonicLayoutsBecomePreciseTerminalFailures() throws {
        for order in [VPFF_CHANNEL_ORDER_CUSTOM, VPFF_CHANNEL_ORDER_AMBISONIC] {
            let bridge = FakeFFmpegDemuxBridge { handle in
                handle.emitTracks(audio: .aac(channelOrder: order))
                return 0
            }
            XCTAssertEqual(try run(bridge: bridge).last, .failure(.unsupportedAudioCodec))
        }

        let unsupportedAudio = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(audio: .unsupportedAudio)
            return 0
        }
        let unsupportedVideo = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(video: .unsupportedVideo)
            return 0
        }
        XCTAssertEqual(try run(bridge: unsupportedAudio).last, .failure(.unsupportedAudioCodec))
        XCTAssertEqual(try run(bridge: unsupportedVideo).last, .failure(.unsupportedVideoCodec))
    }

    func testCErrorKindsMapOnlyToInternalPlaybackCoreErrors() throws {
        let cases: [(VPFFDemuxErrorKind, Int32, PlaybackCoreError)] = [
            (VPFF_DEMUX_ERROR_OPEN, -10, .demuxOpen(-10)),
            (VPFF_DEMUX_ERROR_READ, -11, .demuxRead(-11)),
            (VPFF_DEMUX_ERROR_TIMEOUT, -12, .networkTimeout),
            (VPFF_DEMUX_ERROR_UNSUPPORTED_VIDEO, -13, .unsupportedVideoCodec),
            (VPFF_DEMUX_ERROR_UNSUPPORTED_AUDIO, -14, .unsupportedAudioCodec),
        ]
        for entry in cases {
            let bridge = FakeFFmpegDemuxBridge { handle in
                handle.emitTerminal(VPFF_EVENT_ERROR, errorKind: entry.0, ffmpegError: entry.1)
                return entry.1
            }
            XCTAssertEqual(try run(bridge: bridge).last, .failure(entry.2))
        }
    }

    func testMalformedEnumPointerSizeAndTimeBaseAreRejectedWithoutDereference() throws {
        let invalidTimeBase = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1]), timeBaseDen: 0))
            return 0
        }
        XCTAssertEqual(
            try run(bridge: invalidTimeBase).last,
            .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode))
        )

        let invalidEnum = FakeFFmpegDemuxBridge { handle in
            handle.emitTerminal(VPFFDemuxEventKind(rawValue: 99))
            return 0
        }
        XCTAssertEqual(
            try run(bridge: invalidEnum).last,
            .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode))
        )

        let invalidSize = FakeFFmpegDemuxBridge { handle in
            handle.emitMalformedPacketPointerSize()
            return 0
        }
        XCTAssertEqual(
            try run(bridge: invalidSize).last,
            .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode))
        )
    }

    func testRejectsUnknownCodecStageAndFlagValuesAndCancelsNativeRun() throws {
        let unknownCodec = VPFFCodec(rawValue: 99)
        let unknownChannelOrder = VPFFChannelOrder(rawValue: 99)
        let unknownStage = VPFFDemuxErrorStage(rawValue: 99)
        let unknownError = VPFFDemuxErrorKind(rawValue: 99)
        let scripts: [(String, FakeFFmpegDemuxBridge.RunScript)] = [
            ("unknown video codec", { handle in
                var track = RawTrackSpec.h264()
                track.codec = unknownCodec
                handle.emitTracks(video: track)
                return 0
            }),
            ("unknown audio codec", { handle in
                var track = RawTrackSpec.aac()
                track.codec = unknownCodec
                handle.emitTracks(audio: track)
                return 0
            }),
            ("unknown packet codec", { handle in
                handle.emitPacket(.init(codec: unknownCodec, data: Data([1])))
                return 0
            }),
            ("unknown channel order", { handle in
                var track = RawTrackSpec.aac()
                track.channelOrder = unknownChannelOrder
                handle.emitTracks(audio: track)
                return 0
            }),
            ("unknown error stage", { handle in
                handle.emitTerminal(
                    VPFF_EVENT_ERROR,
                    errorKind: VPFF_DEMUX_ERROR_READ,
                    ffmpegError: -1,
                    errorStage: unknownStage
                )
                return 0
            }),
            ("missing error stage", { handle in
                handle.emitTerminal(
                    VPFF_EVENT_ERROR,
                    errorKind: VPFF_DEMUX_ERROR_READ,
                    ffmpegError: -1,
                    errorStage: VPFF_DEMUX_STAGE_NONE
                )
                return 0
            }),
            ("stage on non-error", { handle in
                handle.emitTerminal(VPFF_EVENT_END, errorStage: VPFF_DEMUX_STAGE_READ)
                return 0
            }),
            ("unknown error kind", { handle in
                handle.emitTerminal(
                    VPFF_EVENT_ERROR,
                    errorKind: unknownError,
                    ffmpegError: -1,
                    errorStage: VPFF_DEMUX_STAGE_READ
                )
                return 0
            }),
            ("non-boolean program presence", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_END
                    event.has_program_id = 2
                }
                return 0
            }),
            ("non-boolean track presence", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_TRACKS
                    event.video.present = 2
                }
                return 0
            }),
            ("non-boolean channel-mask presence", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_TRACKS
                    event.audio.present = 1
                    event.audio.has_channel_layout_mask = 2
                }
                return 0
            }),
            ("non-boolean packet flag", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_PACKET
                    event.packet.stream_index = 0
                    event.packet.codec = VPFF_CODEC_H264
                    event.packet.time_base_num = 1
                    event.packet.time_base_den = 90_000
                    event.packet.is_key = 2
                }
                return 0
            }),
        ]

        for (label, script) in scripts {
            let bridge = FakeFFmpegDemuxBridge(runScript: script)
            XCTAssertEqual(
                try run(bridge: bridge).last,
                .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode)),
                label
            )
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, label)
            XCTAssertEqual(bridge.handle?.cancelCount, 1, label)
        }
    }

    func testRejectsInvalidRequiredFieldsAndOversizedBorrowedBuffersBeforeCopying() throws {
        let scripts: [(String, FakeFFmpegDemuxBridge.RunScript)] = [
            ("no present tracks", { handle in
                handle.emitTracks()
                return 0
            }),
            ("negative track index", { handle in
                var track = RawTrackSpec.h264()
                track.streamIndex = -1
                handle.emitTracks(video: track)
                return 0
            }),
            ("zero video width", { handle in
                handle.emitTracks(video: .h264(width: 0))
                return 0
            }),
            ("zero video height", { handle in
                var track = RawTrackSpec.h264()
                track.height = 0
                handle.emitTracks(video: track)
                return 0
            }),
            ("negative video delay", { handle in
                var track = RawTrackSpec.h264()
                track.videoDelay = -1
                handle.emitTracks(video: track)
                return 0
            }),
            ("zero sample rate", { handle in
                var track = RawTrackSpec.aac()
                track.sampleRate = 0
                handle.emitTracks(audio: track)
                return 0
            }),
            ("zero channel count", { handle in
                var track = RawTrackSpec.aac()
                track.channelCount = 0
                handle.emitTracks(audio: track)
                return 0
            }),
            ("zero native channel mask", { handle in
                handle.emitTracks(audio: .aac(mask: 0))
                return 0
            }),
            ("native mask channel-count mismatch", { handle in
                handle.emitTracks(audio: .aac(mask: 1))
                return 0
            }),
            ("negative packet index", { handle in
                handle.emitPacket(.init(streamIndex: -1, codec: VPFF_CODEC_H264))
                return 0
            }),
            ("oversized packet", { handle in
                handle.emitOversizedPacketSize()
                return 0
            }),
            ("oversized extradata", { handle in
                handle.emitOversizedTrackExtradata()
                return 0
            }),
        ]

        for (label, script) in scripts {
            let bridge = FakeFFmpegDemuxBridge(runScript: script)
            XCTAssertEqual(
                try run(bridge: bridge).last,
                .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode)),
                label
            )
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, label)
            XCTAssertEqual(bridge.handle?.cancelCount, 1, label)
        }
    }

    func testRejectsOversizedURLBeforeCreatingBridge() throws {
        let bridge = FakeFFmpegDemuxBridge()
        let subject = FFmpegDemuxer(bridge: bridge)
        let rawURL = "https://example.invalid/" + String(repeating: "a", count: 64 * 1_024)
        let url = try XCTUnwrap(URL(string: rawURL))

        XCTAssertThrowsError(try subject.start(url: url, sink: { _ in })) { error in
            XCTAssertEqual(error as? PlaybackCoreError, .demuxOpen(FFmpegDemuxer.oversizedValueErrorCode))
        }
        XCTAssertEqual(bridge.createCount, 0)
    }

    func testChangedDiscontinuityPrecedesPacketAndIdenticalSignatureIsIgnored() throws {
        let first = RawTrackSpec.h264(width: 1_920, extradata: Data([1]))
        let changed = RawTrackSpec.h264(width: 1_280, extradata: Data([2]))
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(video: first)
            handle.emitTracks(video: first, kind: VPFF_EVENT_DISCONTINUITY)
            handle.emitTracks(video: changed, kind: VPFF_EVENT_DISCONTINUITY)
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([9])))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let events = try run(bridge: bridge)
        XCTAssertEqual(events.count, 4)
        guard case .tracks = events[0], case .discontinuity = events[1], case .packet = events[2] else {
            return XCTFail("expected tracks, changed discontinuity, packet")
        }
        XCTAssertEqual(events[3], .endOfStream)
    }

    func testCapacityFourBlocksFifthProducerUntilOneEventIsConsumed() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.blocked-drain")
        let unblockDrain = DispatchSemaphore(value: 0)
        let drainBlocked = expectation(description: "executor blocked")
        executor.submit {
            drainBlocked.fulfill()
            unblockDrain.wait()
        }
        wait(for: [drainBlocked], timeout: 2)

        let fifthAttempted = DispatchSemaphore(value: 0)
        let fifthCompleted = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            for index in 0..<4 {
                handle.emitPacket(.init(streamIndex: Int32(index), codec: VPFF_CODEC_H264, data: Data([UInt8(index)])))
            }
            fifthAttempted.signal()
            handle.emitPacket(.init(streamIndex: 4, codec: VPFF_CODEC_H264, data: Data([4])))
            fifthCompleted.signal()
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, executor: executor, capacity: 4)
        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertEqual(fifthAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fifthCompleted.wait(timeout: .now() + 0.05), .timedOut)
        unblockDrain.signal()
        XCTAssertEqual(fifthCompleted.wait(timeout: .now() + 2), .success)
        let events = recorder.waitForTerminal()
        XCTAssertEqual(events.compactMap(\.packet).count, 5)
        XCTAssertEqual(events.last, .endOfStream)
    }

    func testAggregateByteBudgetBlocksProducerBeforeEventCapacityIsReached() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.byte-budget")
        let unblockDrain = DispatchSemaphore(value: 0)
        let drainBlocked = expectation(description: "byte-budget drain blocked")
        executor.submit {
            drainBlocked.fulfill()
            unblockDrain.wait()
        }
        wait(for: [drainBlocked], timeout: 2)

        let secondAttempted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1, 2])))
            secondAttempted.signal()
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([3, 4])))
            secondCompleted.signal()
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(
            bridge: bridge,
            executor: executor,
            capacity: 4,
            maximumQueuedBytes: 3
        )
        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertEqual(secondAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 0.05), .timedOut)
        unblockDrain.signal()
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 2), .success)
        let events = recorder.waitForTerminal()
        XCTAssertEqual(events.compactMap(\.packet).map(\.data), [Data([1, 2]), Data([3, 4])])
        XCTAssertEqual(events.last, .endOfStream)
    }

    func testSingleEventLargerThanInjectedByteBudgetFailsInsteadOfWaitingForever() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1, 2, 3, 4])))
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(
            bridge: bridge,
            capacity: 4,
            maximumQueuedBytes: 3
        )

        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertEqual(
            recorder.waitForTerminal().last,
            .failure(.demuxRead(FFmpegDemuxer.oversizedValueErrorCode))
        )
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
        XCTAssertEqual(bridge.handle?.cancelCount, 1)
    }

    func testCancelWhileProducerIsBlockedClearsQueueAndEmitsExactlyOneCancelled() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.cancel-full")
        let unblockDrain = DispatchSemaphore(value: 0)
        executor.submit { unblockDrain.wait() }
        let fifthAttempted = DispatchSemaphore(value: 0)
        let producerReleased = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            for index in 0..<4 {
                handle.emitPacket(.init(streamIndex: Int32(index), codec: VPFF_CODEC_H264, data: Data([UInt8(index)])))
            }
            fifthAttempted.signal()
            handle.emitPacket(.init(streamIndex: 4, codec: VPFF_CODEC_H264, data: Data([4])))
            producerReleased.signal()
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, executor: executor, capacity: 4)
        try subject.start(url: try httpURL(), sink: recorder.record)
        XCTAssertEqual(fifthAttempted.wait(timeout: .now() + 2), .success)

        subject.cancel()
        XCTAssertEqual(producerReleased.wait(timeout: .now() + 2), .success)
        unblockDrain.signal()
        let events = recorder.waitForTerminal()
        XCTAssertEqual(events, [.cancelled])
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
    }

    func testCancelBeforeRunRepeatedCancelAndDoubleStartAreSafe() throws {
        let ioQueue = DispatchQueue(label: "org.vplayer.tests.demux.io-gated")
        let ioGate = DispatchSemaphore(value: 0)
        ioQueue.async { ioGate.wait() }
        let bridge = FakeFFmpegDemuxBridge { handle in
            XCTAssertTrue(handle.isCancelled)
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, ioQueue: ioQueue)
        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertThrowsError(try subject.start(url: try httpURL(), sink: recorder.record)) { error in
            XCTAssertEqual(error as? PlaybackCoreError, .demuxOpen(FFmpegDemuxer.doubleStartErrorCode))
        }
        subject.cancel()
        subject.cancel()
        ioGate.signal()

        XCTAssertEqual(recorder.waitForTerminal(), [.cancelled])
        XCTAssertGreaterThanOrEqual(bridge.handle?.cancelCount ?? 0, 1)
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testCancelAfterEndHasWonDoesNotCancelLiveNativeHandle() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.end-wins")
        let unblockDrain = DispatchSemaphore(value: 0)
        executor.submit { unblockDrain.wait() }
        let endEmitted = DispatchSemaphore(value: 0)
        let allowRunReturn = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTerminal(VPFF_EVENT_END)
            endEmitted.signal()
            allowRunReturn.wait()
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, executor: executor)
        try subject.start(url: try httpURL(), sink: recorder.record)
        XCTAssertEqual(endEmitted.wait(timeout: .now() + 2), .success)

        subject.cancel()

        XCTAssertEqual(bridge.handle?.cancelCount, 0)
        unblockDrain.signal()
        XCTAssertEqual(recorder.waitForTerminal(), [.endOfStream])
        subject.cancel()
        XCTAssertEqual(bridge.handle?.cancelCount, 0)
        allowRunReturn.signal()
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testDuplicateAndPostTerminalCallbacksAreIgnored() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1])))
            handle.emitTerminal(VPFF_EVENT_END)
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([2])))
            handle.emitTerminal(
                VPFF_EVENT_ERROR,
                errorKind: VPFF_DEMUX_ERROR_READ,
                ffmpegError: -1
            )
            return 0
        }

        let events = try run(bridge: bridge)

        XCTAssertEqual(events.compactMap(\.packet).map(\.data), [Data([1])])
        XCTAssertEqual(events.filter(\.isTerminal), [.endOfStream])
        XCTAssertEqual(events.last, .endOfStream)
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testSinkReentrantCancelAndDeinitDoNotDeadlockOrUseFreedHandle() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1])))
            XCTAssertTrue(handle.waitUntilCancelled())
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        let terminal = expectation(description: "reentrant cancel terminal")
        let events = LockedEventList()
        var subject: FFmpegDemuxer? = FFmpegDemuxer(bridge: bridge)
        let weakSubject = WeakDemuxerBox(subject)
        try subject?.start(url: try httpURL()) { event in
            events.append(event)
            if case .packet = event { weakSubject.value?.cancel() }
            if event.isTerminal { terminal.fulfill() }
        }
        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(events.snapshot.filter(\.isTerminal).count, 1)
        subject = nil
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)

        let deinitBridge = FakeFFmpegDemuxBridge { handle in
            XCTAssertTrue(handle.waitUntilCancelled())
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        var deinitSubject: FFmpegDemuxer? = FFmpegDemuxer(bridge: deinitBridge)
        try deinitSubject?.start(url: try httpURL(), sink: { _ in })
        deinitSubject = nil
        XCTAssertEqual(waitForDestroy(deinitBridge.handle), 1)
    }

    func testOneThousandDeterministicLifecycleInterleavingsHaveOneTerminalAndOneDestroy() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.race.executor")
        let ioQueue = DispatchQueue(label: "org.vplayer.tests.demux.race.io")
        for iteration in 0..<1_000 {
            let bridge = FakeFFmpegDemuxBridge { handle in
                if handle.isCancelled {
                    handle.emitTerminal(VPFF_EVENT_CANCELLED)
                } else {
                    handle.emitTerminal(VPFF_EVENT_END)
                }
                return 0
            }
            let recorder = DemuxEventRecorder()
            let subject = FFmpegDemuxer(
                bridge: bridge,
                executor: executor,
                capacity: 4,
                ioQueue: ioQueue
            )
            try subject.start(url: try httpURL(), sink: recorder.record)
            if iteration.isMultiple(of: 2) { subject.cancel() }
            if iteration.isMultiple(of: 3) { subject.cancel() }
            let events = recorder.waitForTerminal()
            XCTAssertEqual(events.filter(\.isTerminal).count, 1, "iteration \(iteration)")
            if let terminalIndex = events.firstIndex(where: \.isTerminal) {
                XCTAssertEqual(terminalIndex, events.index(before: events.endIndex))
            }
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, "iteration \(iteration)")
        }
    }

    func testLiveCCreateRejectsEmbeddedNULAndNonHTTPAndCancelBeforeRunAvoidsNetwork() {
        var handle: OpaquePointer?
        let invalidURLs: [[UInt8]] = [
            Array("file:///tmp/a.ts".utf8),
            Array("http://example.invalid/a".utf8) + [0] + Array(".ts".utf8),
        ]
        for bytes in invalidURLs {
            handle = nil
            let result = bytes.withUnsafeBufferPointer { buffer in
                vp_ffmpeg_demuxer_create(
                    buffer.baseAddress,
                    buffer.count,
                    10_000_000,
                    cDemuxSmokeCallback,
                    nil,
                    &handle
                )
            }
            XCTAssertLessThan(result, 0)
            XCTAssertNil(handle)
        }

        let recorder = CSmokeRecorder()
        let context = Unmanaged.passUnretained(recorder).toOpaque()
        let bytes = Array("http://127.0.0.1:1/never-opened.ts".utf8)
        handle = nil
        let createResult = bytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                context,
                &handle
            )
        }
        XCTAssertEqual(createResult, 0)
        guard let lowercaseHandle = handle else { return XCTFail("missing live C handle") }
        vp_ffmpeg_demuxer_cancel(lowercaseHandle)
        XCTAssertEqual(vp_ffmpeg_demuxer_run(lowercaseHandle), 0)
        vp_ffmpeg_demuxer_destroy(lowercaseHandle)
        XCTAssertEqual(recorder.kinds, [Int(VPFF_EVENT_CANCELLED.rawValue)])

        let uppercaseBytes = Array("HTTPS://127.0.0.1:1/never-opened.ts".utf8)
        handle = nil
        let uppercaseResult = uppercaseBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                context,
                &handle
            )
        }
        XCTAssertEqual(uppercaseResult, 0)
        guard let uppercaseHandle = handle else { return XCTFail("missing uppercase live C handle") }
        vp_ffmpeg_demuxer_cancel(uppercaseHandle)
        XCTAssertEqual(vp_ffmpeg_demuxer_run(uppercaseHandle), 0)
        vp_ffmpeg_demuxer_destroy(uppercaseHandle)
        XCTAssertEqual(
            recorder.kinds,
            [Int(VPFF_EVENT_CANCELLED.rawValue), Int(VPFF_EVENT_CANCELLED.rawValue)]
        )
    }

    func testLiveCCreateRejectsNullEmptyInvalidUTF8OversizedAndNonpositiveTimeout() {
        var handle: OpaquePointer?
        let validBytes = Array("https://example.invalid/live.ts".utf8)

        XCTAssertLessThan(
            vp_ffmpeg_demuxer_create(
                nil,
                1,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            ),
            0
        )
        let emptyResult = [UInt8]().withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                0,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(emptyResult, 0)
        let invalidUTF8Result = [UInt8(0xC0), UInt8(0xAF)].withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(invalidUTF8Result, 0)
        let oversizedBytes = Array("https://".utf8) + Array(repeating: UInt8(ascii: "a"), count: 64 * 1_024)
        let oversizedResult = oversizedBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(oversizedResult, 0)
        let timeoutResult = validBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                0,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(timeoutResult, 0)
        let nilCallbackResult = validBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                nil,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(nilCallbackResult, 0)
        let nilOutputResult = validBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                nil
            )
        }
        XCTAssertLessThan(nilOutputResult, 0)
        XCTAssertNil(handle)
    }

    private func run(bridge: FakeFFmpegDemuxBridge) throws -> [DemuxEvent] {
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge)
        try subject.start(url: try httpURL(), sink: recorder.record)
        return recorder.waitForTerminal()
    }

    private func httpURL() throws -> URL {
        try XCTUnwrap(URL(string: "https://example.invalid/live.ts"))
    }

    private func waitForDestroy(_ handle: FakeFFmpegDemuxHandle?, timeout: TimeInterval = 5) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, handle?.destroyCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        return handle?.destroyCount ?? 0
    }
}

#if DEBUG
private func runBootstrapDebugScenario(
    _ scenario: VPFFBootstrapDebugScenario
) -> (status: Int32, details: VPFFBootstrapDebugResult) {
    var details = VPFFBootstrapDebugResult()
    let status = vp_ffmpeg_demuxer_debug_run_bootstrap(scenario, &details)
    return (status, details)
}
#endif

private final class WeakDemuxerBox: @unchecked Sendable {
    weak var value: FFmpegDemuxer?

    init(_ value: FFmpegDemuxer?) {
        self.value = value
    }
}

private final class LockedEventList: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DemuxEvent] = []

    func append(_ event: DemuxEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [DemuxEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class CSmokeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedKinds: [Int] = []

    func append(_ kind: Int) {
        lock.lock()
        storedKinds.append(kind)
        lock.unlock()
    }

    var kinds: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedKinds
    }
}

private func cDemuxSmokeCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?
) {
    guard let context, let event else { return }
    Unmanaged<CSmokeRecorder>.fromOpaque(context).takeUnretainedValue().append(Int(event.pointee.kind.rawValue))
}

private extension RawTrackSpec {
    static func h264(
        width: Int32 = 1_920,
        videoDelay: Int32 = 1,
        extradata: Data = Data([1, 2, 3])
    ) -> Self {
        .init(
            streamIndex: 7,
            codec: VPFF_CODEC_H264,
            width: width,
            height: 1_080,
            videoDelay: videoDelay,
            extradata: extradata
        )
    }

    static func aac(
        channelOrder: VPFFChannelOrder = VPFF_CHANNEL_ORDER_NATIVE,
        hasMask: Bool = true,
        mask: UInt64 = 3,
        extradata: Data = Data([0x12, 0x10])
    ) -> Self {
        .init(
            streamIndex: 8,
            codec: VPFF_CODEC_AAC,
            sampleRate: 48_000,
            channelCount: 2,
            channelOrder: channelOrder,
            hasChannelLayoutMask: hasMask,
            channelLayoutMask: mask,
            extradata: extradata
        )
    }

    static var unsupportedAudio: Self {
        .init(
            streamIndex: 8,
            codec: VPFF_CODEC_UNSUPPORTED,
            sampleRate: 48_000,
            channelCount: 2
        )
    }

    static var unsupportedVideo: Self {
        .init(
            streamIndex: 7,
            codec: VPFF_CODEC_UNSUPPORTED,
            width: 1_920,
            height: 1_080
        )
    }
}

private extension DemuxEvent {
    var packet: DemuxPacket? {
        guard case let .packet(packet) = self else { return nil }
        return packet
    }

    var isTerminal: Bool {
        switch self {
        case .endOfStream, .cancelled, .failure:
            true
        case .tracks, .packet, .discontinuity:
            false
        }
    }
}
