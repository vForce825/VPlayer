// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import Network
import XCTest
@testable import VPlayerPlayback

final class HLSTimelineTests: XCTestCase {
    func testRetirementDestroysVideoParserWhileTimelineRemainsAlive() throws {
        let factory = ScriptedFFmpegParserFactory()
        let subject = HLSTimelineCoordinator(parserFactory: factory)
        _ = try subject.consume(.tracks(audioVideoTracks()))
        let parser = try XCTUnwrap(factory.handles.first)
        XCTAssertEqual(factory.handles.count, 1)
        XCTAssertEqual(parser.destroyCount, 0)

        subject.retireCompressedGeneration()

        withExtendedLifetime(subject) {
            XCTAssertEqual(parser.destroyCount, 1,
                "The video generation provider must not keep its owning assembler alive")
        }
        subject.retireCompressedGeneration()
        XCTAssertEqual(parser.destroyCount, 1)
    }

    func testHEVCEOSSurvivesFormatReplayAndFollowingCRAChanges() throws {
        let factory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            try handle.emit(FFmpegParsedFrame(bytes: bytes, pts: pts, dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                fieldOrder: Int32(CodedFieldOrder.progressive.rawValue),
                pictureStructure: Int32(PictureStructure.frame.rawValue), keyFrame: true,
                repeatPicture: false, topFieldFirst: nil, interlaced: false,
                sampleRate: 0, channels: 0, frameSamples: 0, channelLayout: nil))
        }
        let subject = HLSTimelineCoordinator(parserFactory: factory)
        let tracks = DemuxTrackSet(selectedProgramID: 1, video: audioVideoTracks().video,
            audio: audioTracks(extradata: Data()).audio)
        _ = try subject.consume(.tracks(tracks))
        let audio = makeADTSFrame(payload: Data([0x21, 0x10, 0x56, 0xE5]))
        _ = try subject.consume(.packet(audioPacket(data: audio, pts: .zero)))
        let sei = Data([0, 0, 1, 0x4E, 1, 147, 1, 18, 0x80])
        for index in 0...8 {
            let video = sei + AssemblerTestFixtures.hevcAccessUnit(
                includeParameterSets: index == 0,
                nal: Data([index == 8 ? 0x26 : 0x02, 1, 0x80]))
            _ = try subject.consume(.packet(videoPacket(data: video,
                pts: CMTime(value: Int64(index + 1) * 3_000, timescale: 90_000))))
        }
        // 先让音频接收当前 HLG 指纹，随后 EOS 不应再触发音频格式事件。
        _ = try subject.consume(.packet(audioPacket(data: audio,
            pts: CMTime(value: 27_500, timescale: 90_000))))
        _ = try subject.consume(.packet(videoPacket(data: annexB([
            Data([0x02, 1, 0x80]), Data([0x48, 1, 0x80])]),
            pts: CMTime(value: 30_000, timescale: 90_000))))
        let unchangedAudio = try subject.consume(.packet(audioPacket(data: audio,
            pts: CMTime(value: 31_000, timescale: 90_000))))
        XCTAssertTrue(unchangedAudio.endedGenerations.isEmpty)
        let afterEOS = try subject.consume(.packet(videoPacket(data: annexB([Data([0x2A, 1, 0x80])]),
            pts: CMTime(value: 33_000, timescale: 90_000))))
        XCTAssertEqual(afterEOS.endedGenerations.count, 1,
            "EOS 后无 ATC 的 CRA 应回到 SPS 曲线，格式重放不能恢复旧 HLG")
        let returnedHLG = try subject.consume(.packet(videoPacket(data:
            sei + annexB([Data([0x2A, 1, 0x80])]),
            pts: CMTime(value: 36_000, timescale: 90_000))))
        XCTAssertEqual(returnedHLG.endedGenerations.count, 1,
            "重放必须正确打开格式 gate，后续 ATC 变化不能被旧 replay target 吞掉")
    }

    func testAudioOnlyUsesFirstValidatedCompleteAUWithoutCreatingOrWaitingForVideo() throws {
        let parserFactory = ScriptedFFmpegParserFactory()
        let subject = HLSTimelineCoordinator(parserFactory: parserFactory)
        let tracks = audioTracks(extradata: Data())
        let adts = makeADTSFrame(payload: Data([0x21, 0x10, 0x56, 0xE5]))

        _ = try subject.consume(.tracks(tracks))
        let partial = try subject.consume(.packet(audioPacket(
            data: Data(adts.prefix(5)),
            pts: CMTime(value: 90_000, timescale: 90_000)
        )))
        XCTAssertTrue(partial.origins.isEmpty, "残包不能建立媒体起点")

        let completed = try subject.consume(.packet(audioPacket(
            data: Data(adts.dropFirst(5)),
            pts: CMTime(value: 180_000, timescale: 90_000)
        )))
        let origin = try XCTUnwrap(completed.origins.first)
        XCTAssertEqual(origin.source, .completeAudioAccessUnit)
        XCTAssertEqual(origin.sourceTime, ExactMediaTime(value: 1, timescale: 1))
        XCTAssertEqual(origin.effectiveStart, ExactMediaTime(value: 10, timescale: 1))
        XCTAssertEqual(completed.audioSamples.first?.timing.presentationTimeStamp,
                       ExactMediaTime(value: 10, timescale: 1))
        XCTAssertTrue(parserFactory.handles.isEmpty, "AAC ADTS 不应创建不存在的视频 parser")

        let incomplete = HLSTimelineCoordinator(parserFactory: parserFactory)
        _ = try incomplete.consume(.tracks(tracks))
        _ = try incomplete.consume(.packet(audioPacket(
            data: Data(adts.prefix(5)),
            pts: CMTime(value: 1, timescale: 1)
        )))
        let terminal = try incomplete.consume(.endOfStream)
        XCTAssertEqual(terminal.terminals, [.noEligibleOrigin])
    }

    func testAudioVideoWaitsForKnownFormatAndRealIDRWhileCRAAndUnclassifiedFramesCannotOpenOrigin() throws {
        let parserFactory = ScriptedFFmpegParserFactory { handle, index, bytes, pts, dts, _ in
            try handle.emit(FFmpegParsedFrame(
                bytes: bytes,
                pts: pts,
                dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                fieldOrder: index == 0 ? Int32(CodedFieldOrder.unknown.rawValue) : Int32(CodedFieldOrder.progressive.rawValue),
                pictureStructure: Int32(PictureStructure.frame.rawValue),
                keyFrame: true,
                repeatPicture: false,
                topFieldFirst: nil,
                interlaced: index == 0 ? nil : false,
                sampleRate: 0,
                channels: 0,
                frameSamples: 0,
                channelLayout: nil
            ))
        }
        let subject = HLSTimelineCoordinator(parserFactory: parserFactory)
        let tracks = audioVideoTracks()
        _ = try subject.consume(.tracks(tracks))
        XCTAssertTrue(try subject.consume(.packet(audioPacket(
            data: Data([0x11, 0x22]),
            pts: CMTime(value: 45_000, timescale: 90_000)
        ))).origins.isEmpty)

        let unclassifiedIDR = annexB([
            AssemblerTestFixtures.hevcVPS,
            AssemblerTestFixtures.hevcSPS,
            AssemblerTestFixtures.hevcPPS,
            Data([0x26, 0x01, 0x80]),
        ])
        XCTAssertTrue(try subject.consume(.packet(videoPacket(
            data: unclassifiedIDR,
            pts: CMTime(value: 90_000, timescale: 90_000)
        ))).origins.isEmpty, "rawWhileClassifying 的 IDR 仍不能建起点")

        let cra = annexB([
            AssemblerTestFixtures.hevcVPS,
            AssemblerTestFixtures.hevcSPS,
            AssemblerTestFixtures.hevcPPS,
            Data([0x2A, 0x01, 0x80]),
        ])
        XCTAssertTrue(try subject.consume(.packet(videoPacket(
            data: cra,
            pts: CMTime(value: 180_000, timescale: 90_000)
        ))).origins.isEmpty, "HEVC CRA 即使带 key 标记也不能建 HLS 起点")

        let nonIDR = annexB([Data([0x02, 0x01, 0x80])])
        for second in 3...8 {
            XCTAssertTrue(try subject.consume(.packet(videoPacket(
                data: nonIDR,
                pts: CMTime(value: Int64(second) * 90_000, timescale: 90_000)
            ))).origins.isEmpty, "累计不足八帧时 progressive 仍不能建起点")
        }

        let idr = annexB([
            AssemblerTestFixtures.hevcVPS,
            AssemblerTestFixtures.hevcSPS,
            AssemblerTestFixtures.hevcPPS,
            Data([0x26, 0x01, 0x80]),
        ])
        let opened = try subject.consume(.packet(videoPacket(
            data: idr,
            pts: CMTime(value: 810_000, timescale: 90_000),
            dts: CMTime(value: 807_000, timescale: 90_000)
        )))
        let origin = try XCTUnwrap(opened.origins.first)
        XCTAssertEqual(origin.source, .videoIDR)
        XCTAssertEqual(origin.sourceTime, ExactMediaTime(value: 9, timescale: 1))
        XCTAssertEqual(opened.videoSamples.first?.timing.presentationTimeStamp,
                       ExactMediaTime(value: 10, timescale: 1))
        XCTAssertEqual(opened.videoSamples.first?.timing.decodeTimeStamp,
                       ExactMediaTime(value: 897_000, timescale: 90_000),
                       "IDR 的 DTS 可早于媒体起点，并须保留 composition offset")
        XCTAssertTrue(opened.audioSamples.isEmpty, "起点之前的完整音频 AU 不得写入")

        let videoOnlyFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            try handle.emit(FFmpegParsedFrame(
                bytes: bytes, pts: pts, dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                fieldOrder: Int32(CodedFieldOrder.progressive.rawValue),
                pictureStructure: Int32(PictureStructure.frame.rawValue),
                keyFrame: true, repeatPicture: false, topFieldFirst: nil,
                interlaced: false, sampleRate: 0, channels: 0, frameSamples: 0,
                channelLayout: nil
            ))
        }
        let videoOnly = HLSTimelineCoordinator(parserFactory: videoOnlyFactory)
        _ = try videoOnly.consume(.tracks(DemuxTrackSet(
            selectedProgramID: tracks.selectedProgramID,
            video: tracks.video,
            audio: nil
        )))
        XCTAssertTrue(try videoOnly.consume(.packet(videoPacket(
            data: idr, pts: CMTime(value: 1, timescale: 1)
        ))).origins.isEmpty, "单帧 progressive 证据不能直接结束分类")
        for second in 2...7 {
            XCTAssertTrue(try videoOnly.consume(.packet(videoPacket(
                data: nonIDR, pts: CMTime(value: Int64(second), timescale: 1)
            ))).origins.isEmpty)
        }
        XCTAssertEqual(try videoOnly.consume(.packet(videoPacket(
            data: idr, pts: CMTime(value: 8, timescale: 1)
        ))).origins.first?.source, .videoIDR)
    }

    func testAudioBeforeVideoOriginUsesHalfOpenBoundaryAndBoundedRetention() throws {
        let parserFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            try handle.emit(FFmpegParsedFrame(
                bytes: bytes,
                pts: pts,
                dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                fieldOrder: Int32(CodedFieldOrder.tt.rawValue),
                pictureStructure: Int32(PictureStructure.frame.rawValue),
                keyFrame: true,
                repeatPicture: false,
                topFieldFirst: true,
                interlaced: true,
                sampleRate: 0,
                channels: 0,
                frameSamples: 0,
                channelLayout: nil
            ))
        }
        let subject = HLSTimelineCoordinator(parserFactory: parserFactory)
        _ = try subject.consume(.tracks(audioVideoTracks()))

        _ = try subject.consume(.packet(audioPacket(
            data: Data([1, 1]), pts: CMTime(value: 0, timescale: 48_000)
        )))
        _ = try subject.consume(.packet(audioPacket(
            data: Data([2, 2]), pts: CMTime(value: 512, timescale: 48_000)
        )))
        _ = try subject.consume(.packet(audioPacket(
            data: Data([3, 3]), pts: CMTime(value: 2_048, timescale: 48_000)
        )))

        let idr = AssemblerTestFixtures.hevcAccessUnit()
        let opened = try subject.consume(.packet(videoPacket(
            data: idr, pts: CMTime(value: 1_920, timescale: 90_000)
        )))
        XCTAssertEqual(opened.audioSamples.map(\.source.id), [2, 3],
                       "[start,end) 恰好在起点结束的 AU 必须丢弃，跨界与起点后 AU 必须保留")
        let crossing = try XCTUnwrap(opened.audioSamples.first)
        XCTAssertEqual(crossing.source.duration, CMTime(value: 1_024, timescale: 48_000))
        XCTAssertEqual(crossing.timing.presentationTimeStamp, ExactMediaTime(value: 10, timescale: 1))
        XCTAssertEqual(crossing.timing.duration, ExactMediaTime(value: 512, timescale: 48_000),
                       "源 AU 保持完整，缩短后的输出 duration 是后续 converter 的 trim 证据")
        XCTAssertEqual(
            crossing.boundaryDecision,
            .trimLeading(ExactMediaTime(value: 512, timescale: 48_000))
        )
        let afterWithGap = try XCTUnwrap(opened.audioSamples.last)
        XCTAssertEqual(afterWithGap.boundaryDecision, .unchanged)
        XCTAssertEqual(
            afterWithGap.timing.presentationTimeStamp,
            ExactMediaTime(value: 481_024, timescale: 48_000),
            "起点后的天然 gap 必须保留，不能擅自补零或贴到有效起点"
        )

        XCTAssertTrue(try subject.consume(.packet(audioPacket(
            data: Data([4, 4]), pts: CMTime(value: 0, timescale: 48_000)
        ))).audioSamples.isEmpty, "迟到但整体早于起点的 AU 仍须丢弃")
        let later = try subject.consume(.packet(audioPacket(
            data: Data([5, 5]), pts: CMTime(value: 4_096, timescale: 48_000)
        )))
        XCTAssertEqual(
            later.audioSamples.first?.timing.presentationTimeStamp,
            ExactMediaTime(value: 483_072, timescale: 48_000)
        )

        let retainedPastOldBoundary = HLSTimelineCoordinator(parserFactory: parserFactory)
        _ = try retainedPastOldBoundary.consume(.tracks(audioVideoTracks()))
        for index in 0..<65 {
            _ = try retainedPastOldBoundary.consume(.packet(audioPacket(
                data: Data([UInt8(truncatingIfNeeded: index), 0x55]),
                pts: CMTime(value: Int64(index + 1) * 1_024, timescale: 48_000)
            )))
        }
        let retainedOpen = try retainedPastOldBoundary.consume(.packet(videoPacket(
            data: idr,
            pts: .zero
        )))
        XCTAssertEqual(retainedOpen.audioSamples.count, 65)
        XCTAssertEqual(retainedOpen.audioSamples.first?.source.id, 1,
                       "origin 未知时不能静默淘汰后来证明有效的早期 AU")
        XCTAssertEqual(retainedOpen.audioSamples.last?.source.id, 65)

        let overflow = HLSTimelineCoordinator(parserFactory: parserFactory)
        _ = try overflow.consume(.tracks(audioVideoTracks()))
        let maximumSizedAU = Data(repeating: 0xA5, count: 1 * 1_024 * 1_024)
        for _ in 0..<4 {
            _ = try overflow.consume(.packet(audioPacket(
                data: maximumSizedAU,
                pts: .zero
            )))
        }
        XCTAssertThrowsError(try overflow.consume(.packet(audioPacket(
            data: maximumSizedAU,
            pts: .zero
        )))) { error in
            XCTAssertEqual(
                error as? HLSTimelineError,
                .pendingAudioColdStartByteBudgetExceeded
            )
        }

        let spanOverflow = HLSTimelineCoordinator(parserFactory: parserFactory)
        _ = try spanOverflow.consume(.tracks(audioVideoTracks()))
        _ = try spanOverflow.consume(.packet(audioPacket(
            data: Data([0x01, 0x02]),
            pts: .zero
        )))
        XCTAssertThrowsError(try spanOverflow.consume(.packet(audioPacket(
            data: Data([0x03, 0x04]),
            pts: CMTime(value: 15, timescale: 1)
        )))) { error in
            XCTAssertEqual(
                error as? HLSTimelineError,
                .pendingAudioColdStartSpanExceeded
            )
        }
    }

    func testAssemblerFingerprintDriftEndsOldGenerationBeforeChangedAUAndReopensFresh() throws {
        let initialAU = AssemblerTestFixtures.h264AccessUnit(sps: nil, pps: nil)
        var changedSPS = AssemblerTestFixtures.h264SPS
        changedSPS[3] = 0x20
        let changedAU = AssemblerTestFixtures.h264AccessUnit(sps: changedSPS)
        let parserFactory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            if bytes == changedAU {
                try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                    bytes: initialAU,
                    pts: 150_000,
                    dts: 147_000,
                    duration: CMTime(value: 3_000, timescale: 90_000),
                    keyFrame: true,
                    fieldOrder: Int32(CodedFieldOrder.tt.rawValue),
                    pictureStructure: Int32(PictureStructure.frame.rawValue),
                    topFieldFirst: true,
                    interlaced: true
                ))
            }
            try handle.emit(AssemblerTestFixtures.parsedVideoFrame(
                bytes: bytes,
                pts: pts,
                dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                keyFrame: true,
                fieldOrder: Int32(CodedFieldOrder.tt.rawValue),
                pictureStructure: Int32(PictureStructure.frame.rawValue),
                topFieldFirst: true,
                interlaced: true
            ))
        }
        let tracks = h264AudioVideoTracks()
        let subject = HLSTimelineCoordinator(parserFactory: parserFactory)
        _ = try subject.consume(.tracks(tracks))
        _ = try subject.consume(.packet(audioPacket(
            data: Data([0x21, 0x10]),
            pts: .zero
        )))

        let initial = try subject.consume(.packet(h264VideoPacket(
            data: initialAU, pts: CMTime(value: 90_000, timescale: 90_000)
        )))
        XCTAssertEqual(initial.origins.first?.generation.rawValue, 0)

        let changed = try subject.consume(.packet(h264VideoPacket(
            data: changedAU, pts: CMTime(value: 180_000, timescale: 90_000)
        )))
        XCTAssertEqual(changed.endedGenerations.count, 1)
        XCTAssertEqual(changed.endedGenerations.first?.0, 0)
        XCTAssertEqual(changed.endedGenerations.first?.1, .formatChange)
        XCTAssertEqual(changed.origins.map(\.generation.rawValue), [1],
                       "单次变化 packet 必须在新 generation 立即重建起点")
        let oldSamples = changed.videoSamples.filter { $0.generation.rawValue == 0 }
        let newSamples = changed.videoSamples.filter { $0.generation.rawValue == 1 }
        XCTAssertEqual(oldSamples.count, 1, "漂移前已完成的旧 AU 仍属于旧 generation")
        XCTAssertEqual(newSamples.count, 1, "变化 AU 必须且只能在新 generation 输出一次")
        XCTAssertEqual(
            newSamples.first.map { CMSampleBufferGetPresentationTimeStamp($0.source.sampleBuffer) },
            CMTime(value: 180_000, timescale: 90_000),
            "重放 gate 不能把同 packet 中先出现的旧格式 AU 错发到新 generation"
        )
        XCTAssertEqual(parserFactory.handles.count, 2, "漂移后必须重建 assembler/parser")
    }

    func testCancelledAndFailedEndReasonsAreDistinctPreserveErrorAndEmitExactlyOnce() throws {
        let tracks = audioTracks(extradata: Data([0x11, 0x90]))
        let cancelled = HLSTimelineCoordinator()
        _ = try cancelled.consume(.tracks(tracks))
        _ = try cancelled.consume(.packet(audioPacket(
            data: Data([1]), pts: CMTime(value: 1, timescale: 1)
        )))
        let cancelledEvents = try cancelled.consume(.cancelled)
        let cancelledReason = try XCTUnwrap(cancelledEvents.generationEndReasons.first)
        XCTAssertEqual(cancelledReason, .cancelled)
        XCTAssertEqual(cancelledEvents.terminals, [.cancelled])
        XCTAssertTrue(try cancelled.consume(.cancelled).isEmpty)
        XCTAssertTrue(try cancelled.consume(.endOfStream).isEmpty)

        let failed = HLSTimelineCoordinator()
        _ = try failed.consume(.tracks(tracks))
        _ = try failed.consume(.packet(audioPacket(
            data: Data([2]), pts: CMTime(value: 2, timescale: 1)
        )))
        let expected = PlaybackCoreError.demuxRead(-12_345)
        let failedEvents = try failed.consume(.failure(expected))
        let failedReason = try XCTUnwrap(failedEvents.generationEndReasons.first)
        XCTAssertEqual(failedReason, .failed(expected))
        XCTAssertNotEqual(failedReason, cancelledReason)
        XCTAssertEqual(failedEvents.terminals, [.failed(expected)],
                       "终态必须保留原始 PlaybackCoreError")
        XCTAssertTrue(try failed.consume(.failure(.networkTimeout)).isEmpty)
        XCTAssertThrowsError(try failed.consume(.packet(audioPacket(
            data: Data([3]), pts: CMTime(value: 3, timescale: 1)
        ))))
    }

    func testAnnexBRejectsInvalidHeadersAndEmptyVCLPayloadBeforeRandomAccessClassification() throws {
        XCTAssertEqual(
            try AnnexBScanner.scan(annexB([Data([0x65, 0x80])]), codec: .h264)
                .randomAccessKind,
            .h264IDR
        )
        XCTAssertEqual(
            try AnnexBScanner.scan(annexB([Data([0x26, 0x01, 0x80])]), codec: .hevc)
                .randomAccessKind,
            .hevcIDR
        )

        let invalid: [(String, VideoCodec, Data)] = [
            ("H264 forbidden_zero_bit", .h264, Data([0xE5, 0x80])),
            ("H264 空 VCL", .h264, Data([0x65])),
            ("HEVC forbidden_zero_bit", .hevc, Data([0xA6, 0x01, 0x80])),
            ("HEVC temporal_id_plus1 为零", .hevc, Data([0x26, 0x00, 0x80])),
            ("HEVC 空 VCL", .hevc, Data([0x26, 0x01])),
        ]
        for entry in invalid {
            XCTAssertThrowsError(try AnnexBScanner.scan(
                annexB([entry.2]), codec: entry.1
            ), entry.0)
        }
    }

    func testExactRationalPTSAndDTSPreserveCompositionOffsetAndRejectInvalidOrOverflowingInput() throws {
        let subject = HLSTimelineCoordinator()
        let largeBoundaries = [
            ("2^30-1", (Int64(1) << 30) - 1),
            ("2^30", Int64(1) << 30),
            ("2^30+1", (Int64(1) << 30) + 1),
            ("2^33-1", (Int64(1) << 33) - 1),
            ("2^33", Int64(1) << 33),
            ("2^33+1", (Int64(1) << 33) + 1),
        ]
        let cases: [(String, CMTime, CMTime, CMTime, ExactMediaTime, ExactMediaTime?)] = [
            ("负起点", CMTime(value: -1, timescale: 2), CMTime(value: 3, timescale: 2), CMTime(value: 1, timescale: 1),
             ExactMediaTime(value: 12, timescale: 1), ExactMediaTime(value: 23, timescale: 2)),
            ("DTS 缺失", .zero, CMTime(value: 90_000, timescale: 90_000), .invalid,
             ExactMediaTime(value: 990_000, timescale: 90_000), nil),
        ] + largeBoundaries.map { label, value in
            (label, .zero, CMTime(value: value, timescale: 90_000),
             CMTime(value: value - 3_003, timescale: 90_000),
             ExactMediaTime(value: value + 900_000, timescale: 90_000),
             ExactMediaTime(value: value - 3_003 + 900_000, timescale: 90_000))
        }
        for entry in cases {
            let receipt = MediaOriginReceipt(
                generation: HLSTimelineGeneration(rawValue: 0),
                sourceTime: try ExactMediaTime(entry.1),
                effectiveStart: ExactMediaTime(value: 10, timescale: 1),
                source: .videoIDR
            )
            let mapped = try subject.normalize(
                presentationTimeStamp: entry.2,
                decodeTimeStamp: entry.3,
                duration: CMTime(value: 3_003, timescale: 90_000),
                relativeTo: receipt
            )
            XCTAssertEqual(mapped.presentationTimeStamp, entry.4, entry.0)
            XCTAssertEqual(mapped.decodeTimeStamp, entry.5, entry.0)
            XCTAssertEqual(mapped.duration, ExactMediaTime(value: 3_003, timescale: 90_000), entry.0)
            if entry.3.isNumeric {
                let sourceOffset = CMTimeSubtract(entry.2, entry.3)
                let mappedOffset = CMTimeSubtract(mapped.presentationTimeStamp.cmTime,
                                                  try XCTUnwrap(mapped.decodeTimeStamp).cmTime)
                XCTAssertEqual(CMTimeCompare(sourceOffset, mappedOffset), 0, entry.0)
            }
        }

        let origin = MediaOriginReceipt(
            generation: HLSTimelineGeneration(rawValue: 0),
            sourceTime: ExactMediaTime(value: 20, timescale: 1),
            effectiveStart: ExactMediaTime(value: 10, timescale: 1),
            source: .videoIDR
        )
        let invalidCases: [(String, CMTime, CMTime)] = [
            ("无效 PTS", .invalid, .invalid),
            ("非零 epoch", CMTime(value: 1, timescale: 1, flags: .valid, epoch: 1), .invalid),
            ("起点前 PTS", CMTime(value: 9, timescale: 1), CMTime(value: 8, timescale: 1)),
        ]
        for entry in invalidCases {
            XCTAssertThrowsError(try subject.normalize(
                presentationTimeStamp: entry.1,
                decodeTimeStamp: entry.2,
                duration: .invalid,
                relativeTo: origin
            ), entry.0)
        }
        let overflowingOrigin = MediaOriginReceipt(
            generation: HLSTimelineGeneration(rawValue: 0),
            sourceTime: ExactMediaTime(value: -20, timescale: 1),
            effectiveStart: ExactMediaTime(value: 10, timescale: 1),
            source: .videoIDR
        )
        XCTAssertThrowsError(try subject.normalize(
            presentationTimeStamp: CMTime(value: Int64.max, timescale: 1),
            decodeTimeStamp: .invalid,
            duration: .invalid,
            relativeTo: overflowingOrigin
        ), "正溢出")

        let positive = WriterTimelineMapping(delta: ExactMediaTime(value: 1, timescale: 3))
        XCTAssertEqual(
            try positive.writtenTime(for: ExactMediaTime(value: 1, timescale: 6)),
            ExactMediaTime(value: 1, timescale: 2)
        )
        XCTAssertEqual(
            try positive.effectiveWrittenBase(inputEffectiveBase: ExactMediaTime(value: 10, timescale: 1)),
            ExactMediaTime(value: 31, timescale: 3)
        )
        let negative = WriterTimelineMapping(delta: ExactMediaTime(value: -1, timescale: 2))
        XCTAssertEqual(
            try negative.writtenTime(for: ExactMediaTime(value: 3, timescale: 2)),
            ExactMediaTime(value: 1, timescale: 1)
        )
        XCTAssertThrowsError(try negative.writtenTime(
            for: ExactMediaTime(value: 1, timescale: 4)
        ))
        XCTAssertThrowsError(try WriterTimelineMapping(
            delta: ExactMediaTime(value: 1, timescale: 1)
        ).writtenTime(for: ExactMediaTime(value: Int64.max, timescale: 1)))
    }

    func testFormatChangeTimelineResetAndEOSFenceGenerationsExactlyOnce() throws {
        let subject = HLSTimelineCoordinator()
        let tracks = audioTracks(extradata: Data([0x11, 0x90]))
        _ = try subject.consume(.tracks(tracks))
        _ = try subject.consume(.packet(audioPacket(data: Data([1]), pts: CMTime(value: 1, timescale: 1))))

        let reset = try subject.consume(.discontinuity(tracks, reason: .timelineReset))
        XCTAssertEqual(reset.endedGenerations.count, 1)
        XCTAssertEqual(reset.endedGenerations.first?.0, 0)
        XCTAssertEqual(reset.endedGenerations.first?.1, .timelineReset)
        let generationOne = try subject.consume(.packet(audioPacket(data: Data([2]), pts: CMTime(value: 2, timescale: 1))))
        XCTAssertEqual(generationOne.origins.first?.generation.rawValue, 1)

        let changed = try subject.consume(.discontinuity(tracks, reason: .formatChange))
        XCTAssertEqual(changed.endedGenerations.count, 1)
        XCTAssertEqual(changed.endedGenerations.first?.0, 1)
        XCTAssertEqual(changed.endedGenerations.first?.1, .formatChange)
        let generationTwo = try subject.consume(.packet(audioPacket(data: Data([3]), pts: CMTime(value: 3, timescale: 1))))
        XCTAssertEqual(generationTwo.origins.first?.generation.rawValue, 2)

        let eos = try subject.consume(.endOfStream)
        XCTAssertEqual(eos.endedGenerations.count, 1)
        XCTAssertEqual(eos.endedGenerations.first?.0, 2)
        XCTAssertEqual(eos.endedGenerations.first?.1, .endOfStream)
        XCTAssertEqual(eos.terminals, [.endOfStream])
        XCTAssertTrue(try subject.consume(.endOfStream).isEmpty)
        XCTAssertThrowsError(try subject.consume(.packet(audioPacket(
            data: Data([4]), pts: CMTime(value: 4, timescale: 1)
        ))))

        let split = HLSTimelineCoordinator()
        let adtsTracks = audioTracks(extradata: Data())
        let adts = makeADTSFrame(payload: Data([1, 2, 3, 4]))
        _ = try split.consume(.tracks(adtsTracks))
        _ = try split.consume(.packet(audioPacket(
            data: Data(adts.prefix(5)), pts: CMTime(value: 1, timescale: 1)
        )))
        _ = try split.consume(.discontinuity(adtsTracks, reason: .timelineReset))
        XCTAssertTrue(try split.consume(.packet(audioPacket(
            data: Data(adts.dropFirst(5)), pts: CMTime(value: 2, timescale: 1)
        ))).origins.isEmpty, "旧 generation 的 ADTS 残包不能跨 reset 拼接")
        let rebuilt = try split.consume(.packet(audioPacket(
            data: adts, pts: CMTime(value: 3, timescale: 1)
        )))
        XCTAssertEqual(rebuilt.origins.first?.generation.rawValue, 1)

        let splitAtFormatChange = HLSTimelineCoordinator()
        _ = try splitAtFormatChange.consume(.tracks(adtsTracks))
        _ = try splitAtFormatChange.consume(.packet(audioPacket(
            data: Data(adts.prefix(5)), pts: CMTime(value: 1, timescale: 1)
        )))
        _ = try splitAtFormatChange.consume(.discontinuity(
            adtsTracks, reason: .formatChange
        ))
        XCTAssertTrue(try splitAtFormatChange.consume(.packet(audioPacket(
            data: Data(adts.dropFirst(5)), pts: CMTime(value: 2, timescale: 1)
        ))).origins.isEmpty, "旧 generation 的 ADTS 残包不能跨 formatChange 拼接")
    }

    func testOutputFormatSignatureDetectsEveryFrozenFieldButIgnoresMeasurementAndRenditionOrder() throws {
        let base = makeSignature()
        let changes: [(String, OutputFormatSignature)] = [
            ("视频 rendition", makeSignature(videoRenditionIdentity: "video-alt")),
            ("sample entry", makeSignature(sampleEntry: .hev1)),
            ("codec", makeSignature(codec: .h264)),
            ("profile", makeSignature(profile: 2)),
            ("level", makeSignature(level: 153)),
            ("宽度", makeSignature(width: 3_840)),
            ("高度", makeSignature(height: 2_160)),
            ("精确帧率", makeSignature(frameRate: try XCTUnwrap(MediaRational(num: 60_000, den: 1_001)))),
            ("位深", makeSignature(bitDepth: 10)),
            ("动态范围", makeSignature(dynamicRange: .pq)),
            ("像素格式", makeSignature(pixelFormat: 0x78343230)),
            ("视频冻结码率包络", makeSignature(videoFrozenBitrateEnvelope: 45_000_000)),
            ("音频 rendition", makeSignature(audioRenditionIdentity: "aac-alt")),
            ("音频 codec", makeSignature(audioCodec: .eac3)),
            ("音频声道数", makeSignature(audioChannelCount: 6)),
            ("音频布局", makeSignature(audioChannelLayoutMask: 0x3F)),
            ("音频冻结码率包络", makeSignature(audioFrozenBitrateEnvelope: 768_000)),
            ("range", makeSignature(range: .full)),
            ("primaries", makeSignature(primaries: .bt2020)),
            ("transfer", makeSignature(transfer: .hlg)),
            ("matrix", makeSignature(matrix: .bt2020Nonconstant)),
            ("SAR", makeSignature(sampleAspectRatio: try XCTUnwrap(MediaRational(num: 4, den: 3)))),
            ("clean aperture", makeSignature(cleanAperture: HLSCleanApertureSignature(
                width: try XCTUnwrap(MediaRational(num: 1_880, den: 1)),
                height: try XCTUnwrap(MediaRational(num: 1_060, den: 1)),
                horizontalOffset: try XCTUnwrap(SignedMediaRational(num: -1, den: 2)),
                verticalOffset: try XCTUnwrap(SignedMediaRational(num: 1, den: 2))
            ))),
            ("chroma", makeSignature(chromaLocation: .topLeft)),
            ("MDCV", makeSignature(masteringDisplay: masteringDisplay())),
            ("CLLI", makeSignature(contentLightLevel: DemuxContentLightLevelMetadata(
                maximumContentLightLevel: 1_000,
                maximumFrameAverageLightLevel: 400
            )!)),
            ("codec config", makeSignature(codecConfigurationDigest: Data([9]))),
            ("audio cookie", makeSignature(audioCookieDigest: Data([8]))),
            ("role", makeSignature(trackMetadata: .init(role: .main))),
            ("language", makeSignature(trackMetadata: .init(language: "zho"))),
            ("service", makeSignature(trackMetadata: .init(service: .independentMain))),
            ("disposition", makeSignature(trackMetadata: .init(dispositions: [.default]))),
        ]
        for entry in changes {
            XCTAssertTrue(entry.1.requiresNewGeneration(comparedTo: base), entry.0)
        }
        XCTAssertFalse(makeSignature(measuredBitrate: 7_500_000).requiresNewGeneration(comparedTo: base))

        let mainAudio = makeAudioRendition(identity: "aac-main")
        let commentary = makeAudioRendition(
            identity: "aac-commentary",
            metadata: DemuxTrackMetadata(role: .commentary, language: "en")
        )
        let twoRenditions = makeSignature(audioRenditions: [mainAudio, commentary])
        let reordered = makeSignature(audioRenditions: [commentary, mainAudio])
        XCTAssertFalse(reordered.requiresNewGeneration(comparedTo: twoRenditions))
        let changedCommentary = makeAudioRendition(
            identity: "aac-commentary",
            cookieDigest: Data([9]),
            metadata: DemuxTrackMetadata(role: .commentary, language: "en")
        )
        XCTAssertTrue(makeSignature(audioRenditions: [mainAudio, changedCommentary])
            .requiresNewGeneration(comparedTo: twoRenditions))

        let audioOnly = makeSignature(includeVideo: false)
        XCTAssertNil(audioOnly.video)
        XCTAssertFalse(makeSignature(includeVideo: false, measuredBitrate: 99)
            .requiresNewGeneration(comparedTo: audioOnly))
        XCTAssertEqual(
            SignedMediaRational(num: -2, den: 4),
            SignedMediaRational(num: -1, den: 2)
        )
        XCTAssertEqual(
            makeSignature(frameRate: try XCTUnwrap(MediaRational(num: 60_000, den: 2_002))),
            base
        )
        XCTAssertThrowsError(try OutputFormatSignature(
            video: nil,
            audioRenditions: [],
            measuredBitrate: 0
        ))
        XCTAssertThrowsError(try OutputFormatSignature(
            video: nil,
            audioRenditions: [mainAudio, mainAudio],
            measuredBitrate: 0
        ))
    }

    func testConfigured4KFixtureUsesManagedLoopbackURL() throws {
        let raw = "http://127.0.0.1:49152/timeline-4k-15m.ts"
        XCTAssertEqual(try timelineFixtureURL(environment: [
            "VPLAYER_TIMELINE_FIXTURE_URL": raw,
        ]).absoluteString, raw)
    }

    func testConfiguredInvalid4KFixtureFailsRatherThanSkipping() {
        for raw in ["", "file:///tmp/test_4k_15m.ts", "https://example.com/fixture.ts",
                    "http://127.0.0.1/timeline-4k-15m.ts", "http://127.0.0.1:49152/other.ts"] {
            XCTAssertThrowsError(try timelineFixtureURL(environment: [
                "VPLAYER_TIMELINE_FIXTURE_URL": raw,
            ])) { error in
                XCTAssertEqual((error as NSError).domain, "HLSTimelineFixture")
            }
        }
    }

    private func timelineFixtureURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let raw = environment["VPLAYER_TIMELINE_FIXTURE_URL"] {
            guard let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1",
                  url.port != nil, url.path == "/timeline-4k-15m.ts",
                  url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else {
                throw NSError(domain: "HLSTimelineFixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Configured 4K fixture must use the managed loopback HTTP URL",
                ])
            }
            return url
        }
        let path = "/tmp/test_4k_15m.ts"
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw XCTSkip("Run Scripts/run-playback-integration-tests.sh with --timeline-fixture")
        }
        return URL(fileURLWithPath: path)
    }

    func testReal4KDemuxAndTimelineOrigin() throws {
        // Fail at the first bad AU instead of producing tens of thousands of diagnostics.
        func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            guard condition else {
                throw NSError(domain: "HLSTimeline4KAcceptance", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message(),
                ])
            }
        }
        let fixtureURL = try timelineFixtureURL()
        let server: LoopbackHTTPFixtureServer?
        if fixtureURL.isFileURL {
            server = try LoopbackHTTPFixtureServer(fileURL: fixtureURL)
        } else {
            server = nil
        }
        defer { server?.stop() }
        let recorder = DemuxEventRecorder()
        let demuxer = FFmpegDemuxer()
        try demuxer.start(url: server?.sourceURL ?? fixtureURL, sink: recorder.record)
        defer { demuxer.cancel() }
        let events = recorder.waitForTerminal(timeout: 10)
        try require(events.contains { if case .endOfStream = $0 { true } else { false } },
                    "The full 15-minute fixture must reach EOF, not merely yield a playable prefix")
        let tracks = try XCTUnwrap(events.compactMap { event -> DemuxTrackSet? in
            if case let .tracks(value) = event { return value }
            return nil
        }.first)
        let actualVideo = try XCTUnwrap(tracks.video)
        XCTAssertEqual(actualVideo.width, 3_840)
        XCTAssertEqual(actualVideo.height, 2_160)
        XCTAssertEqual(actualVideo.codec, .h264)
        XCTAssertEqual(actualVideo.frameRate, MediaRational(num: 25, den: 1))
        XCTAssertEqual(actualVideo.videoDelay, 0, "The synthetic fixture has no B-frames")
        let actualAudio = try XCTUnwrap(tracks.audio)
        XCTAssertEqual(actualAudio.codec, .aac)
        XCTAssertEqual(actualAudio.sampleRate, 48_000)
        XCTAssertEqual(actualAudio.channelLayout.channelCount, 2)
        let videoPackets = events.compactMap { event -> DemuxPacket? in
            if case let .packet(packet) = event, packet.streamIndex == actualVideo.streamIndex {
                return packet
            }
            return nil
        }
        let expectedPacketCount = 22_500
        let frameDuration = ExactMediaTime(value: 1, timescale: 25)
        try require(videoPackets.count == expectedPacketCount,
                    "Expected all \(expectedPacketCount) video packets, got \(videoPackets.count)")
        let firstPacket = try XCTUnwrap(videoPackets.first)
        let lastPacket = try XCTUnwrap(videoPackets.last)
        let firstSourcePTS = try ExactMediaTime(firstPacket.presentationTimeStamp)
        for (index, packet) in videoPackets.enumerated() {
            let expectedPTS = try firstSourcePTS.adding(ExactMediaTime(value: Int64(index), timescale: 25))
            let pts = try ExactMediaTime(packet.presentationTimeStamp)
            let dts = try ExactMediaTime(packet.decodeTimeStamp)
            let duration = try ExactMediaTime(packet.duration)
            try require(pts == expectedPTS && dts == expectedPTS && duration == frameDuration,
                        "Video packet \(index): expected PTS/DTS=\(expectedPTS), duration=\(frameDuration); "
                        + "got PTS=\(pts), DTS=\(dts), duration=\(duration)")
            try require(!packet.isCorrupt && packet.isKey == (index.isMultiple(of: 50)),
                        "Video packet \(index): fixture must have an uncorrupted closed 50-frame GOP")
        }
        let sourceEnd = try ExactMediaTime(lastPacket.presentationTimeStamp).adding(frameDuration)
        XCTAssertEqual(try sourceEnd.subtracting(firstSourcePTS), ExactMediaTime(value: 900, timescale: 1))

        // The real classifier needs eight progressive frames. The first eligible IDR
        // in this 50-frame-GOP fixture is packet 50, two seconds after the first PTS.
        // Fix this expectation independently of what the coordinator happens to emit.
        let expectedLeadingVideoPackets = 50
        let expectedVideoSampleCount = expectedPacketCount - expectedLeadingVideoPackets
        let expectedOriginPTS = try firstSourcePTS.adding(ExactMediaTime(value: 2, timescale: 1))
        let expectedEffectiveStart = ExactMediaTime(value: 10, timescale: 1)
        let expectedNormalizedEnd = try expectedEffectiveStart.adding(sourceEnd.subtracting(expectedOriginPTS))
        let coordinator = HLSTimelineCoordinator()
        var origins: [MediaOriginReceipt] = []
        var terminals: [HLSTimelineTerminal] = []
        var videoSampleCount = 0
        var videoSubmissionCount = 0
        var audioSampleCount = 0
        var lastSubmissionEnd: ExactMediaTime?
        var videoInspection: VideoAccessUnitInspectionSession?
        var videoEligibility: VideoRemuxEligibility?
        var videoBuilder: HLSVideoRemuxSubmissionBuilder?
        defer {
            // Audio is observed, not an all-packets claim: pre-origin AAC is dropped
            // and the boundary AU may be trimmed by the timeline coordinator.
            print("[TEST_4K] packets=\(videoPackets.count), leadingVideoPackets=\(expectedLeadingVideoPackets), "
                  + "expectedVideoSamples=\(expectedVideoSampleCount), videoSamples=\(videoSampleCount), "
                  + "videoSubmissions=\(videoSubmissionCount), observedAudioSamples=\(audioSampleCount), "
                  + "origins=\(origins.count), terminals=\(terminals)")
        }
        for (eventIndex, event) in events.enumerated() {
            var stage = "consume"
            do {
                let emissions = try coordinator.consume(event)
                for emission in emissions {
                    switch emission {
                    case .originEstablished(let receipt):
                        stage = "origin"
                        try require(origins.isEmpty && receipt.source == .videoIDR
                                    && receipt.sourceTime == expectedOriginPTS
                                    && receipt.effectiveStart == expectedEffectiveStart,
                                    "Expected one real video IDR origin at \(expectedOriginPTS), got \(receipt)")
                        origins.append(receipt)
                        print("[TEST_4K] origin=\(receipt), expectedVideoSpan=898 seconds")
                    case .videoSample(let timed):
                        stage = "video source/timing"
                        let packetIndex = expectedLeadingVideoPackets + videoSampleCount
                        videoSampleCount += 1
                        let origin = try XCTUnwrap(origins.first, "Video emission requires the validated real origin")
                        try require(packetIndex < videoPackets.count,
                                    "Unexpected extra video sample \(videoSampleCount)")
                        let expectedPacket = videoPackets[packetIndex]
                        let sourcePTS = try ExactMediaTime(
                            CMSampleBufferGetPresentationTimeStamp(timed.source.sampleBuffer))
                        let sourceDTS = try ExactMediaTime(
                            CMSampleBufferGetDecodeTimeStamp(timed.source.sampleBuffer))
                        let sourceDuration = try ExactMediaTime(CMSampleBufferGetDuration(timed.source.sampleBuffer))
                        let expectedPTS = try ExactMediaTime(expectedPacket.presentationTimeStamp)
                        let expectedTimingPTS = try expectedEffectiveStart.adding(expectedPTS.subtracting(expectedOriginPTS))
                        try require(sourcePTS == expectedPTS && sourceDTS == expectedPTS && sourceDuration == frameDuration
                                    && timed.generation == origin.generation
                                    && timed.timing.presentationTimeStamp == expectedTimingPTS
                                    && timed.timing.decodeTimeStamp == expectedTimingPTS
                                    && timed.timing.duration == frameDuration,
                                    "Video sample \(videoSampleCount), packet \(packetIndex): source or normalized timing mismatch; "
                                    + "sourcePTS=\(sourcePTS), sourceDTS=\(sourceDTS), duration=\(sourceDuration), "
                                    + "timing=\(timed.timing), expectedPTS=\(expectedPTS), normalizedPTS=\(expectedTimingPTS)")
                        let backing = try XCTUnwrap(timed.source.sourceBacking, "Missing real AU backing")
                        let byteRange = try XCTUnwrap(timed.source.sourceByteRange, "Missing real AU byte range")
                        let sourceSHA256 = try XCTUnwrap(timed.source.sourceSHA256, "Missing real AU digest")
                        if videoInspection == nil {
                            videoInspection = VideoAccessUnitInspectionSession(
                                generation: timed.source.generation, codec: actualVideo.codec)
                            videoEligibility = try VideoRemuxEligibility(
                                generation: timed.source.generation, track: actualVideo, sampleEntry: .avc3)
                        }
                        stage = "inspect/admit"
                        var inspection = try XCTUnwrap(videoInspection)
                        let eligibility = try XCTUnwrap(videoEligibility)
                        let proof = try inspection.inspect(.init(
                            backing: backing, byteRange: byteRange, sourceSHA256: sourceSHA256,
                            codec: actualVideo.codec, scanClassification: timed.source.scanClassification,
                            presentationTimeStamp: sourcePTS, decodeTimeStamp: sourceDTS,
                            duration: sourceDuration, expectedFormat: actualVideo))
                        videoInspection = inspection
                        let decision = try eligibility.evaluate(proof)
                        try require(decision.path == .remux && decision.transcodeReason == nil && !decision.requiresNewItem,
                                    "Video sample \(videoSampleCount): fixture must remux; path=\(decision.path), "
                                    + "reason=\(String(describing: decision.transcodeReason)), newItem=\(decision.requiresNewItem)")
                        let admission = try XCTUnwrap(decision.proof, "Remux requires a real inspector-issued admission")
                        if videoBuilder == nil {
                            stage = "construct remux builder"
                            let binding = FMP4WriterBinding(
                                outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 18),
                                itemGeneration: .init(rawValue: 20),
                                mediaEpoch: .init(rawValue: 21),
                                publicationParticipantID: .init(rawValue: 22),
                                renditionIdentity: .init(rawValue: 23),
                                writerIdentity: .init(rawValue: 24)
                            )
                            videoBuilder = try HLSVideoRemuxSubmissionBuilder(
                                reference: timed, admission: admission, writerBinding: binding)
                        }
                        stage = "make/validate remux submission"
                        let builder = try XCTUnwrap(videoBuilder)
                        let submission = try builder.makeSubmission(for: timed, admission: admission)
                        try require(submission.presentationTimeStamp == expectedTimingPTS
                                    && submission.decodeTimeStamp == expectedTimingPTS
                                    && submission.duration == frameDuration
                                    && submission.sourceBacking === backing
                                    && submission.sourceByteRange == byteRange
                                    && submission.sourceSHA256 == sourceSHA256
                                    && submission.isIDR == expectedPacket.isKey,
                                    "Video submission \(videoSampleCount): source binding or exact timing mismatch")
                        try require(try submission.validatesFrozenIdentity(),
                                    "Video submission \(videoSampleCount): frozen identity validation failed")
                        videoSubmissionCount += 1
                        lastSubmissionEnd = try submission.presentationTimeStamp.adding(submission.duration)
                    case .audioSample:
                        audioSampleCount += 1
                    case .terminal(let terminal):
                        terminals.append(terminal)
                    default:
                        break
                    }
                }
            } catch {
                print("[TEST_4K] FAILED event=\(eventIndex), sample=\(videoSampleCount), stage=\(stage): "
                      + String(String(reflecting: error).prefix(512)))
                throw error
            }
        }
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(terminals, [.endOfStream], "The timeline must drain the complete fixture")
        XCTAssertEqual(videoSampleCount, expectedVideoSampleCount,
                       "Every one of the 22,450 post-origin video packets must become a timed sample")
        XCTAssertEqual(videoSubmissionCount, expectedVideoSampleCount,
                       "Every one of the 22,450 post-origin video packets must produce a validated remux submission")
        XCTAssertEqual(lastSubmissionEnd, expectedNormalizedEnd,
                       "Remux submissions must cover all 898 seconds after the intentional 2-second origin wait")
        XCTAssertGreaterThan(audioSampleCount, 0, "Observed audio emission is required; complete AAC coverage is not asserted")
        XCTAssertNotNil(videoBuilder)
    }

    func testReal4KProductionMediaGraph() async throws {
        let fixtureURL = try timelineFixtureURL()
        let server: LoopbackHTTPFixtureServer?
        if fixtureURL.isFileURL {
            server = try LoopbackHTTPFixtureServer(fileURL: fixtureURL)
        } else {
            server = nil
        }
        defer { server?.stop() }
        let lifecycle = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 99_001)
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: lifecycle)
        let assembler = HLSMediaGraphAssembler(
            sourceURL: server?.sourceURL ?? fixtureURL,
            applicationLedger: HLSDeliveryApplicationChargeLedger(),
            graph: SystemHLSDeliveryGraph(authority: authority))
        do {
            let replacement = try await assembler.startUntilPlayablePrefix()
            print("[TEST_4K_GRAPH] Success! replacement=\(replacement.request.itemURL)")
        } catch {
            print("[TEST_4K_GRAPH] Error: \(error), failureDescription=\(authority.failureDescriptionForDiagnostics ?? "nil")")
            XCTFail("4K production graph failed: \(authority.failureDescriptionForDiagnostics ?? String(reflecting: error))")
        }
        _ = await assembler.retireAndAwaitReceipt()
    }
}

private final class LoopbackHTTPFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.vplayer.tests.timeline-loopback")
    private let payload: Data
    let sourceURL: URL

    init(fileURL: URL) throws {
        payload = try Data(contentsOf: fileURL)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: .any
        )
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        let bytes = payload
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                _, _, _, _ in
                let header = Data((
                    "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n" +
                    "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                ).utf8)
                connection.send(content: header, completion: .contentProcessed { error in
                    guard error == nil else {
                        connection.cancel()
                        return
                    }
                    connection.send(content: bytes, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.ts") else {
            listener.cancel()
            throw NSError(
                domain: "LoopbackHTTPFixtureServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP server failed to start"]
            )
        }
        sourceURL = url
    }

    func stop() {
        listener.cancel()
    }
}

private extension Array where Element == HLSTimelineEvent {
    var origins: [MediaOriginReceipt] {
        compactMap { if case let .originEstablished(value) = $0 { value } else { nil } }
    }

    var videoSamples: [HLSTimedVideoAccessUnit] {
        compactMap { if case let .videoSample(value) = $0 { value } else { nil } }
    }

    var audioSamples: [HLSTimedAudioAccessUnit] {
        compactMap { if case let .audioSample(value) = $0 { value } else { nil } }
    }

    var terminals: [HLSTimelineTerminal] {
        compactMap { if case let .terminal(value) = $0 { value } else { nil } }
    }

    var endedGenerations: [(UInt64, HLSGenerationEndReason)] {
        compactMap {
            if case let .generationEnded(generation, reason) = $0 {
                (generation.rawValue, reason)
            } else {
                nil
            }
        }
    }

    var generationEndReasons: [HLSGenerationEndReason] {
        endedGenerations.map(\.1)
    }
}

private func audioTracks(extradata: Data) -> DemuxTrackSet {
    DemuxTrackSet(
        selectedProgramID: 1,
        video: nil,
        audio: AudioTrackDescriptor(
            streamIndex: 8,
            codec: .aac,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            extradata: extradata
        )
    )
}

private func audioVideoTracks() -> DemuxTrackSet {
    DemuxTrackSet(
        selectedProgramID: 1,
        video: VideoTrackDescriptor(
            streamIndex: 7,
            codec: .hevc,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            width: 1_920,
            height: 1_080,
            videoDelay: 1,
            extradata: Data(),
            frameRate: MediaRational(num: 30_000, den: 1_001),
            fieldOrder: .unknown
        ),
        audio: AudioTrackDescriptor(
            streamIndex: 8,
            codec: .aac,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            extradata: Data([0x11, 0x90])
        )
    )
}

private func h264AudioVideoTracks() -> DemuxTrackSet {
    DemuxTrackSet(
        selectedProgramID: 2,
        video: VideoTrackDescriptor(
            streamIndex: 7,
            codec: .h264,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            width: 1_920,
            height: 1_080,
            videoDelay: 1,
            extradata: AssemblerTestFixtures.annexBParameterSets([
                AssemblerTestFixtures.h264SPS,
                AssemblerTestFixtures.h264PPS,
            ]),
            frameRate: MediaRational(num: 30_000, den: 1_001),
            fieldOrder: .unknown
        ),
        audio: AudioTrackDescriptor(
            streamIndex: 8,
            codec: .aac,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            extradata: Data([0x11, 0x90])
        )
    )
}

private func audioPacket(data: Data, pts: CMTime) -> DemuxPacket {
    DemuxPacket(streamIndex: 8, codec: .audio(.aac), data: data,
                presentationTimeStamp: pts, decodeTimeStamp: .invalid,
                duration: .invalid, isKey: false, isCorrupt: false)
}

private func videoPacket(data: Data, pts: CMTime, dts: CMTime = .invalid) -> DemuxPacket {
    DemuxPacket(streamIndex: 7, codec: .video(.hevc), data: data,
                presentationTimeStamp: pts, decodeTimeStamp: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                isKey: true, isCorrupt: false)
}

private func h264VideoPacket(
    data: Data,
    pts: CMTime,
    dts: CMTime = .invalid
) -> DemuxPacket {
    DemuxPacket(
        streamIndex: 7,
        codec: .video(.h264),
        data: data,
        presentationTimeStamp: pts,
        decodeTimeStamp: dts,
        duration: CMTime(value: 3_000, timescale: 90_000),
        isKey: true,
        isCorrupt: false
    )
}

private func makeADTSFrame(payload: Data) -> Data {
    let length = payload.count + 7
    var bytes = Data([
        0xFF, 0xF1, 0x4C,
        UInt8(0x80 | ((length >> 11) & 0x03)),
        UInt8((length >> 3) & 0xFF),
        UInt8((length & 0x07) << 5 | 0x1F),
        0xFC,
    ])
    bytes.append(payload)
    return bytes
}

private func annexB(_ nals: [Data]) -> Data {
    nals.reduce(into: Data()) { result, nal in
        result.append(contentsOf: [0, 0, 0, 1])
        result.append(nal)
    }
}

private func masteringDisplay() -> DemuxMasteringDisplayMetadata {
    DemuxMasteringDisplayMetadata(
        redX: DemuxHDRRational(num: 34, den: 50)!,
        redY: DemuxHDRRational(num: 8, den: 25)!,
        greenX: DemuxHDRRational(num: 13, den: 50)!,
        greenY: DemuxHDRRational(num: 69, den: 100)!,
        blueX: DemuxHDRRational(num: 3, den: 20)!,
        blueY: DemuxHDRRational(num: 3, den: 50)!,
        whitePointX: DemuxHDRRational(num: 15_635, den: 50_000)!,
        whitePointY: DemuxHDRRational(num: 16_450, den: 50_000)!,
        minimumLuminance: DemuxHDRRational(num: 1, den: 10_000)!,
        maximumLuminance: DemuxHDRRational(num: 1_000, den: 1)!
    )!
}

private func makeSignature(
    includeVideo: Bool = true,
    videoRenditionIdentity: String = "video-main",
    sampleEntry: HLSVideoSampleEntry = .hvc1,
    codec: VideoCodec = .hevc,
    profile: Int32 = 1,
    level: Int32 = 120,
    width: Int32 = 1_920,
    height: Int32 = 1_080,
    frameRate: MediaRational = MediaRational(num: 30_000, den: 1_001)!,
    pixelFormat: UInt32 = 0x34323076,
    bitDepth: UInt8 = 8,
    dynamicRange: HLSVideoDynamicRange = .sdr,
    videoFrozenBitrateEnvelope: UInt64 = 12_000_000,
    audioRenditionIdentity: String = "aac-2",
    audioCodec: AudioCodec = .aac,
    audioChannelCount: Int32 = 2,
    audioChannelLayoutMask: UInt64? = 3,
    audioFrozenBitrateEnvelope: UInt64 = 384_000,
    range: DemuxColorRange? = nil,
    primaries: DemuxColorPrimaries? = nil,
    transfer: DemuxColorTransfer? = nil,
    matrix: DemuxColorMatrix? = nil,
    cleanAperture: HLSCleanApertureSignature? = nil,
    sampleAspectRatio: MediaRational? = nil,
    chromaLocation: DemuxChromaLocation? = nil,
    masteringDisplay: DemuxMasteringDisplayMetadata? = nil,
    contentLightLevel: DemuxContentLightLevelMetadata? = nil,
    codecConfigurationDigest: Data = Data([1]),
    audioCookieDigest: Data = Data([2]),
    trackMetadata: DemuxTrackMetadata = DemuxTrackMetadata(),
    audioRenditions: [OutputAudioRenditionSignature]? = nil,
    measuredBitrate: UInt64 = 6_000_000
) -> OutputFormatSignature {
    let video = includeVideo ? OutputVideoSignature(
        renditionIdentity: videoRenditionIdentity,
        selection: OutputSelectionSignature(
            sampleEntry: sampleEntry,
            codec: codec,
            profile: profile,
            level: level,
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: pixelFormat,
            bitDepth: bitDepth,
            dynamicRange: dynamicRange,
            frozenBitrateEnvelope: videoFrozenBitrateEnvelope
        ),
        sampleDescription: OutputSampleDescriptionSignature(
            range: range,
            primaries: primaries,
            transfer: transfer,
            matrix: matrix,
            cleanAperture: cleanAperture,
            sampleAspectRatio: sampleAspectRatio,
            chromaLocation: chromaLocation,
            masteringDisplay: masteringDisplay,
            contentLightLevel: contentLightLevel,
            codecConfigurationDigest: codecConfigurationDigest
        )
    ) : nil
    let audio = audioRenditions ?? [makeAudioRendition(
        identity: audioRenditionIdentity,
        codec: audioCodec,
        channelCount: audioChannelCount,
        channelLayoutMask: audioChannelLayoutMask,
        frozenBitrateEnvelope: audioFrozenBitrateEnvelope,
        cookieDigest: audioCookieDigest,
        metadata: trackMetadata
    )]
    return try! OutputFormatSignature(
        video: video,
        audioRenditions: audio,
        measuredBitrate: measuredBitrate
    )
}

private func makeAudioRendition(
    identity: String,
    codec: AudioCodec = .aac,
    channelCount: Int32 = 2,
    channelLayoutMask: UInt64? = 3,
    frozenBitrateEnvelope: UInt64 = 384_000,
    cookieDigest: Data = Data([2]),
    metadata: DemuxTrackMetadata = DemuxTrackMetadata()
) -> OutputAudioRenditionSignature {
    OutputAudioRenditionSignature(
        renditionIdentity: identity,
        codec: codec,
        channelCount: channelCount,
        channelLayoutMask: channelLayoutMask,
        frozenBitrateEnvelope: frozenBitrateEnvelope,
        cookieDigest: cookieDigest,
        trackMetadata: metadata
    )
}
