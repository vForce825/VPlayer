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
        let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 1_048_576,
            maximumPCMBytes: 1_024, capacity: 16)
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline.consume(.tracks(.init(selectedProgramID: nil, video: nil,
            audio: .init(streamIndex: 1, codec: .aac, timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000, channelLayout: .init(channelCount: 2, nativeMask: 3),
                extradata: fixture.root.configuration.audioSpecificConfig))))
        let events = try timeline.consume(.packet(.init(streamIndex: 1, codec: .audio(.aac), data: payload,
            presentationTimeStamp: CMTime(value: 480_000, timescale: 48_000), decodeTimeStamp: .invalid,
            duration: .invalid, isKey: true, isCorrupt: false)))
        let first = try XCTUnwrap(events.compactMap {
            if case let .audioSample(value) = $0 { return value }; return nil
        }.first)
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
            XCTAssertTrue(object.publicationEvidence?.sourceAAC?.matches(object) == true)
            XCTAssertTrue(root.isCurrent)
            timelineOwner.timeline.retireCompressedGeneration()
            XCTAssertFalse(root.isCurrent)
            XCTAssertTrue(root.accepts(object.publicationEvidence!.sourceAAC!),
                "Original immutable evidence remains exact, so freshness is an independent mandatory gate")
            queued.fulfill()
        }
        defer { graph.close(); timeline.retireCompressedGeneration(); _ = writer.cancel() }
        try writer.start(at: first.timing.presentationTimeStamp.cmTime)
        do {
            try await writer.appendSourceAACAwaitingReadiness(.init(timed: first,
                configuration: configuration, binding: binding), boundary: boundary)
        } catch { /* Retirement may race the awaited native append's final source check. */ }
        await fulfillment(of: [queued], timeout: 3)
        XCTAssertThrowsError(try graph.waitForVisible(until: Date().addingTimeInterval(1)))
        XCTAssertEqual(graph.initialStoreCreationCountForTesting, 0,
            "The stale queued init must be rejected before even constructing a publication store")
        _ = await writer.cancelAwaitingCompletion()
    }
}

/// The test finishes all parsing before handing retirement to the publication
/// callback; subsequent assertions run only after that callback has joined.
private final class SourceAACQueuedTimelineOwner: @unchecked Sendable {
    let timeline: HLSTimelineCoordinator
    init(_ timeline: HLSTimelineCoordinator) { self.timeline = timeline }
}
