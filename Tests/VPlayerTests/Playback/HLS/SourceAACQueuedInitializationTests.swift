// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class SourceAACQueuedInitializationTests: XCTestCase {
    func testGenuineQueuedInitializationCannotInstallAfterSourceRetirement() async throws {
        let fixture = try await SourceAACPublicationFixture.make()
        defer { fixture.close() }
        let packet = try XCTUnwrap(fixture.packets.first)
        let inspected = try FMP4CompressedAudioInspection.sourceAACFragment(
            initialization: fixture.initialization.bytes, media: packet.object.bytes,
            configuration: fixture.root.configuration, expectedDuration: packet.receipt.presentationRange.duration)
        let span = try XCTUnwrap(inspected.sample(at: 0)).byteSpan
        let sourceCharge = try HLSCompressedAudioApplicationReservation.reserve(bytes: span.count + 1_024, ledger: .shared)
        defer { withExtendedLifetime(sourceCharge) {} }
        let payload = packet.object.bytes.subdata(in: span)
        // A persistent native writer need not emit initialization for one AU.
        // Include the first AU across the normal one-second audio boundary so
        // the real writer flushes a segment without finishing the source/window.
        let sourceUnitCount = (48_000 + 1_023) / 1_024 + 1
        let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 1_048_576,
            maximumPCMBytes: 1_024, capacity: sourceUnitCount + 1)
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline.consume(.tracks(.init(selectedProgramID: nil, video: nil,
            audio: .init(streamIndex: 1, codec: .aac, timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000, channelLayout: .init(channelCount: 2, nativeMask: 3),
                extradata: fixture.root.configuration.audioSpecificConfig))))
        // Finish all timeline mutation before a publication callback may retire
        // it. Each prepared AU still carries its genuine paid source proof.
        let sourceUnits = try (0..<sourceUnitCount).map { index in
            let events = try timeline.consume(.packet(.init(streamIndex: 1, codec: .audio(.aac), data: payload,
                presentationTimeStamp: CMTime(value: 480_000 + Int64(index) * 1_024, timescale: 48_000),
                decodeTimeStamp: .invalid, duration: .invalid, isKey: true, isCorrupt: false)))
            return try XCTUnwrap(events.compactMap {
                if case let .audioSample(value) = $0 { return value }; return nil
            }.first)
        }
        let first = try XCTUnwrap(sourceUnits.first)
        let binding = Task19.binding(id: 2, writer: 989_303)
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: .init(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2, channelMask: 3,
                decoderConfiguration: fixture.root.configuration.audioSpecificConfig,
                priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true),
            binding: binding)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: first.timing.presentationTimeStamp.cmTime))
        try boundary.registerAudioRendition(binding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000),
            firstPhysicalStart: first.timing.presentationTimeStamp.cmTime,
            firstEffectiveStart: first.timing.presentationTimeStamp.cmTime)
        let graph = try SystemHLSPublicationGraph(itemGeneration: 19)
        try graph.configureAudioOnly()
        let writer = try graph.makeRelay(binding: binding, mediaType: .audio, limits: .audio) { relay in
            try SegmentedFMP4Writer(binding: binding, trackKind: .aac,
                sourceFormatHint: configuration.sourceFormatHint, boundarySession: boundary.session,
                compressedFormatConfiguration: nil, relay: relay,
                systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(), sourceAACConfiguration: configuration)
        }
        let root = try XCTUnwrap(writer.sourceAACTerminalBinding)
        let queued = expectation(description: "Actual source initialization reached publication queue")
        let timelineOwner = SourceAACQueuedTimelineOwner(timeline)
        graph.installBeforeReceiveForTesting { object in
            guard object.kind == .initialization else { return }
            // Let the native flush finish sealing both real callbacks before
            // retirement. Otherwise its media callback could fail the writer
            // and make this accidentally test failure instead of freshness.
            guard timelineOwner.allowRetirement.wait(timeout: .now() + 3) == .success else {
                XCTFail("The real native flush must release the queued initialization within its existing bound")
                return
            }
            XCTAssertTrue(object.publicationEvidence?.sourceAAC?.matches(object) == true)
            XCTAssertTrue(root.isCurrent)
            timelineOwner.retire()
            XCTAssertFalse(root.isCurrent)
            XCTAssertTrue(root.accepts(object.publicationEvidence!.sourceAAC!),
                "Original immutable evidence remains exact, so freshness is an independent mandatory gate")
            queued.fulfill()
        }
        defer {
            timelineOwner.allowRetirement.signal()
            graph.close(); _ = writer.cancel(); timelineOwner.retire()
        }
        try writer.start(at: first.timing.presentationTimeStamp.cmTime)
        for unit in sourceUnits {
            try await writer.appendSourceAACAwaitingReadiness(.init(timed: unit,
                configuration: configuration, binding: binding), boundary: boundary)
        }
        let flushDeadline = Date().addingTimeInterval(3)
        while writer.usage.mediaCallbackCount == 0 && Date() < flushDeadline { await Task.yield() }
        XCTAssertEqual(writer.usage.initializationCount, 1)
        XCTAssertEqual(writer.usage.mediaCallbackCount, 1, "A real normal segment flush must precede retirement")
        XCTAssertEqual(writer.usage.inputAllocationCount, UInt64(sourceUnitCount))
        XCTAssertNil(writer.terminalReceipt, "A physical finish must not substitute for normal segment flushing")
        XCTAssertNil(root.finalSeal)
        timelineOwner.allowRetirement.signal()
        await fulfillment(of: [queued], timeout: 3)
        XCTAssertThrowsError(try graph.waitForVisible(until: Date().addingTimeInterval(1))) {
            XCTAssertEqual(PlaybackErrorDiagnostics.snapshot($0),
                           PlaybackErrorDiagnostics.snapshot(HLSPublicationFailure.identityMismatch))
        }
        XCTAssertEqual(graph.initialStoreCreationCountForTesting, 0,
            "The stale queued init must be rejected before even constructing a publication store")
        let terminal = await writer.cancelAwaitingCompletion()
        XCTAssertEqual(terminal.inputCount, sourceUnitCount)
        XCTAssertEqual(terminal.initializationCallbackCount, 1)
        XCTAssertEqual(terminal.mediaCallbackCount, 1)
    }
}

/// The test finishes all parsing before handing retirement to the publication
/// callback; subsequent assertions run only after that callback has joined.
private final class SourceAACQueuedTimelineOwner: @unchecked Sendable {
    private let timeline: HLSTimelineCoordinator
    private let lock = NSLock()
    let allowRetirement = DispatchSemaphore(value: 0)
    init(_ timeline: HLSTimelineCoordinator) { self.timeline = timeline }
    func retire() { lock.withLock { timeline.retireCompressedGeneration() } }
}
