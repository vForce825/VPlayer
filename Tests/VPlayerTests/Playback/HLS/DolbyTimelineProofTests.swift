// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class DolbyTimelineProofTests: XCTestCase {
    func testPublishedLongGOPMetadataPreservesSixtyPAndRejectsLargerBeforeClaim() throws {
        XCTAssertTrue(WriterDecodeCoveragePolicy.accepts(trackKind: .video,
            samplesPerSecond: 50, samplesPerAccessUnit: 1, segmentInputCount: 300))
        XCTAssertTrue(WriterDecodeCoveragePolicy.accepts(trackKind: .video,
            samplesPerSecond: 60, samplesPerAccessUnit: 1, segmentInputCount: 360))
        XCTAssertFalse(WriterDecodeCoveragePolicy.accepts(trackKind: .video,
            samplesPerSecond: 120, samplesPerAccessUnit: 1, segmentInputCount: 720))
        XCTAssertFalse(WriterDecodeCoveragePolicy.accepts(trackKind: .video,
            samplesPerSecond: 60, samplesPerAccessUnit: 1, segmentInputCount: 385))
        XCTAssertTrue(WriterDecodeCoveragePolicy.accepts(trackKind: .video,
            samplesPerSecond: 60, samplesPerAccessUnit: 1, segmentInputCount: 120))
        XCTAssertTrue(WriterDecodeCoveragePolicy.accepts(trackKind: .aac,
            samplesPerSecond: 48_000, samplesPerAccessUnit: 1_024, segmentInputCount: 282))
        XCTAssertFalse(WriterDecodeCoveragePolicy.accepts(trackKind: .aac,
            samplesPerSecond: 48_000, samplesPerAccessUnit: 1_024, segmentInputCount: 321))
    }

    func testPaidProducerMappingSurvivesDrainUntilExplicitRetirement() throws {
        let harness = try DolbyProducerTestHarness()
        let timeline = makeTimeline(harness)
        _ = try timeline.consume(.tracks(tracks(harness)))
        var frames: [HLSTimedAudioAccessUnit] = []
        for index in 0..<64 {
            frames += try timeline.consume(.packet(packet(index))).compactMap {
                if case let .audioSample(frame) = $0 { return frame }; return nil
            }
        }
        XCTAssertEqual(frames.count, 64)
        XCTAssertEqual(harness.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
        let first = try XCTUnwrap(frames.first)
        XCTAssertTrue(first.validatesSourceMapping())
        XCTAssertEqual(first.timing.presentationTimeStamp, ExactMediaTime(value: 10, timescale: 1))
        XCTAssertEqual(first.source.presentationTimeStamp, CMTime(value: 900_000, timescale: 48_000))
        _ = try timeline.consume(.endOfStream)
        XCTAssertNoThrow(try harness.producer.requireSourceDrained(throughFrameID: 64))
        // EOF can arrive in the same bounded demux batch as queued output. It is
        // not graph retirement and cannot revoke those already-issued proofs.
        let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan(for: first))
        XCTAssertTrue(plan.isCurrent)
        XCTAssertEqual(plan.firstAuthorizedAccessUnitStart, first.source.presentationTimeStamp)
        XCTAssertNotNil(harness.producer.coordinator.authorizeCompressedCandidate(plan))
        timeline.retireCompressedGeneration()
        XCTAssertFalse(first.validatesSourceMapping())
        XCTAssertFalse(plan.isCurrent)
    }

    func testCopiedTimingCannotMintDolbyMappingAndFallbackKeepsFramerClock() throws {
        let harness = try DolbyProducerTestHarness()
        let timeline = makeTimeline(harness)
        _ = try timeline.consume(.tracks(tracks(harness)))
        let first = try XCTUnwrap(try timeline.consume(.packet(packet(0))).compactMap {
            if case let .audioSample(frame) = $0 { return frame }; return nil
        }.first)
        let copied = HLSTimedAudioAccessUnit(source: first.source, generation: first.generation,
            timing: first.timing, boundaryDecision: first.boundaryDecision)
        XCTAssertFalse(copied.validatesSourceMapping())
        XCTAssertNil(timeline.makeCompressedAudioCandidatePlan(for: copied))
        try timeline.useCompatibleAudioBeforeSourceAppend()
        let second = try XCTUnwrap(try timeline.consume(.packet(packet(1))).compactMap {
            if case let .audioSample(frame) = $0 { return frame }; return nil
        }.first)
        XCTAssertNil(second.source.dolbyProof)
        XCTAssertFalse(first.validatesSourceMapping())
        XCTAssertEqual(second.source.id, 2)
        XCTAssertEqual(second.source.presentationTimeStamp, packet(1).presentationTimeStamp)
    }

    func testRejectedFinalServiceCannotTurnAcceptedPrefixIntoNaturalEOF() throws {
        let harness = try DolbyProducerTestHarness()
        let timeline = makeTimeline(harness)
        _ = try timeline.consume(.tracks(tracks(harness)))
        _ = try timeline.consume(.packet(packet(0)))
        let rejected = Task16EAC3Fixture.make(blockCount: 6, streamType: 0, substreamID: 0,
            bsid: 16, bsmod: 2, convsync: nil, hasJOC: false)
        XCTAssertThrowsError(try timeline.consume(.packet(packet(1, bytes: rejected))))
        XCTAssertThrowsError(try harness.producer.requireSourceDrained(throughFrameID: 1))
        XCTAssertThrowsError(try timeline.consume(.endOfStream))
    }

    private func makeTimeline(_ harness: DolbyProducerTestHarness) -> HLSTimelineCoordinator {
        let parser = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(bytes: bytes, pts: pts,
                sampleRate: 48_000, channels: 2, frameSamples: 1_536, nativeMask: 3))
        }
        return HLSTimelineCoordinator(parserFactory: parser, hlsAudioCopyOwnership: harness.copies,
            sharedControlExecutor: harness.producer.sharedControlExecutor, dolbyProducer: harness.producer)
    }
    private func tracks(_ harness: DolbyProducerTestHarness) -> DemuxTrackSet {
        .init(selectedProgramID: 7, video: nil, audio: harness.source)
    }
    private func packet(_ index: Int, bytes: Data? = nil) -> DemuxPacket {
        .init(streamIndex: 1, codec: .audio(.eac3), data: bytes ?? Task16EAC3Fixture.make(
            blockCount: 6, streamType: 0, substreamID: 0, bsid: 16, bsmod: 0, convsync: nil, hasJOC: false),
            presentationTimeStamp: CMTime(value: 900_000 + Int64(index) * 1_536, timescale: 48_000),
            decodeTimeStamp: .invalid, duration: .invalid, isKey: false, isCorrupt: false)
    }
}
