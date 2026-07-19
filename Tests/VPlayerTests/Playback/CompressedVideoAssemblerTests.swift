// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class CompressedVideoAssemblerTests: XCTestCase {
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
            eventSink: { _ in }
        )

        try subject.drain()
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
        let subject = try CompressedVideoAssembler(
            trackSet: AssemblerTestFixtures.videoTracks(),
            generationProvider: { MediaGeneration(rawValue: 4) },
            eventSink: { events.append($0) },
            parserFactory: factory
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
        let subject = try CompressedVideoAssembler(
            trackSet: AssemblerTestFixtures.videoTracks(),
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
            parserFactory: factory
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

    func testExactTimestampConversionPreservesNegativeAndAbsentAndRejectsNonIntegral() throws {
        let timeBase = try XCTUnwrap(MediaRational(num: 1, den: 90_000))
        XCTAssertEqual(
            try exactTicks(
                CMTime(value: Int64.min, timescale: 90_000),
                timeBase: timeBase
            ),
            Int64.min
        )
        let factory = ScriptedFFmpegParserFactory()
        let subject = try CompressedVideoAssembler(
            trackSet: AssemblerTestFixtures.videoTracks(),
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { _ in },
            parserFactory: factory
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
    }

    func testDrainResetDiscardOldStateAndIDsContinueUntilDeterministicExhaustion() throws {
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
        let subject = try CompressedVideoAssembler(
            trackSet: AssemblerTestFixtures.videoTracks(),
            generationProvider: { MediaGeneration(rawValue: 8) },
            eventSink: { events.append($0) },
            parserFactory: factory,
            startingID: UInt64.max - 1
        )

        try subject.push(AssemblerTestFixtures.videoPacket())
        try subject.drain()
        try subject.drain()
        try subject.reset(for: AssemblerTestFixtures.videoTracks(streamIndex: 2))
        XCTAssertEqual(factory.handles[0].destroyCount, 1)
        XCTAssertEqual(factory.handles.count, 2)
        XCTAssertEqual(events.compactMap(\.accessUnit).map(\.id), [UInt64.max - 1, UInt64.max])

        XCTAssertThrowsError(try subject.push(AssemblerTestFixtures.videoPacket(streamIndex: 2))) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .videoDecode(CompressedVideoAssembler.idExhaustedErrorCode)
            )
        }
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
