// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import VPlayerPlayback

final class YADIFReferenceWindowTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 7)
    private let top = ResolvedFieldOrder(
        parity: .top,
        confidence: .signaled,
        source: .parser
    )
    private let bottom = ResolvedFieldOrder(
        parity: .bottom,
        confidence: .signaled,
        source: .parser
    )

    func testHeadMiddleTailAndDrainIdempotenceUseExactThreeFrameReferences() throws {
        var subject = YADIFReferenceWindow(generation: generation)

        let first = subject.push(try frame(id: 1, pts: 0), order: top)
        XCTAssertNil(first.job)
        XCTAssertTrue(first.discarded.isEmpty)
        XCTAssertEqual(subject.bufferedCount, 1)
        XCTAssertEqual(subject.unemittedCount, 1)

        let head = try XCTUnwrap(subject.push(try frame(id: 2, pts: 10), order: top).job)
        XCTAssertEqual(ids(in: head), [1, 1, 2])
        XCTAssertEqual(head.order, top)
        XCTAssertTrue(head.spatialOnly)
        XCTAssertEqual(subject.bufferedCount, 2)
        XCTAssertEqual(subject.unemittedCount, 1)

        let middle = try XCTUnwrap(subject.push(try frame(id: 3, pts: 20), order: top).job)
        XCTAssertEqual(ids(in: middle), [1, 2, 3])
        XCTAssertEqual(middle.order, top)
        XCTAssertFalse(middle.spatialOnly)
        XCTAssertEqual(subject.bufferedCount, 2)
        XCTAssertEqual(subject.unemittedCount, 1)

        let tail = try XCTUnwrap(subject.drain().job)
        XCTAssertEqual(ids(in: tail), [2, 3, 3])
        XCTAssertEqual(tail.order, top)
        XCTAssertTrue(tail.spatialOnly)
        XCTAssertEqual(subject.bufferedCount, 0)
        XCTAssertEqual(subject.unemittedCount, 0)

        let secondDrain = subject.drain()
        XCTAssertNil(secondDrain.job)
        XCTAssertTrue(secondDrain.discarded.isEmpty)
    }

    func testOneFrameDrainUsesCurrentForAllReferences() throws {
        var subject = YADIFReferenceWindow(generation: generation)
        XCTAssertNil(subject.push(try frame(id: 4, pts: 40), order: bottom).job)

        let tail = try XCTUnwrap(subject.drain().job)

        XCTAssertEqual(ids(in: tail), [4, 4, 4])
        XCTAssertEqual(tail.order, bottom)
        XCTAssertTrue(tail.spatialOnly)
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testStaleInputIsDiscardedWithoutMutatingCurrentState() throws {
        var subject = YADIFReferenceWindow(generation: generation)
        XCTAssertNil(subject.push(try frame(id: 1, pts: 10), order: top).job)

        let stale = try frame(
            id: 2,
            pts: 20,
            generation: MediaGeneration(rawValue: generation.rawValue - 1)
        )
        let transition = subject.push(stale, order: bottom)

        XCTAssertNil(transition.job)
        XCTAssertEqual(transition.discarded.map(\.frame.accessUnitID), [2])
        XCTAssertEqual(subject.generation, generation)
        XCTAssertEqual(subject.bufferedCount, 1)
        XCTAssertEqual(subject.unemittedCount, 1)
        let head = try XCTUnwrap(subject.push(try frame(id: 3, pts: 20), order: top).job)
        XCTAssertEqual(ids(in: head), [1, 1, 3])
        XCTAssertEqual(head.order, top)
    }

    func testNewGenerationDiscardsUnemittedTailAndSeedsFreshHead() throws {
        var subject = YADIFReferenceWindow(generation: generation)
        XCTAssertNil(subject.push(try frame(id: 1, pts: 10), order: top).job)
        let newerGeneration = MediaGeneration(rawValue: generation.rawValue + 1)

        let transition = subject.push(
            try frame(id: 2, pts: 5, generation: newerGeneration),
            order: bottom
        )

        XCTAssertNil(transition.job)
        XCTAssertEqual(transition.discarded.map(\.frame.accessUnitID), [1])
        XCTAssertEqual(subject.generation, newerGeneration)
        XCTAssertEqual(subject.bufferedCount, 1)
        XCTAssertEqual(subject.unemittedCount, 1)
        let head = try XCTUnwrap(subject.push(
            try frame(id: 3, pts: 15, generation: newerGeneration),
            order: bottom
        ).job)
        XCTAssertEqual(ids(in: head), [2, 2, 3])
    }

    func testExplicitDiscontinuityDiscardsTailClearsCadenceAndSeedsIncomingFrame() throws {
        var subject = YADIFReferenceWindow(generation: generation)
        _ = subject.push(try frame(id: 1, pts: 0), order: top)
        _ = subject.push(try frame(id: 2, pts: 10), order: top)

        let transition = subject.push(
            try frame(id: 3, pts: 1_000),
            order: top,
            discontinuity: true
        )

        XCTAssertNil(transition.job)
        XCTAssertEqual(transition.discarded.map(\.frame.accessUnitID), [2])
        XCTAssertEqual(subject.bufferedCount, 1)
        let head = try XCTUnwrap(subject.push(try frame(id: 4, pts: 1_010), order: top).job)
        XCTAssertEqual(ids(in: head), [3, 3, 4])
        XCTAssertTrue(head.spatialOnly)
    }

    func testInvalidTimestampClearsTailAndDiscardsIncomingFrame() throws {
        for invalidPTS in [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity] {
            var subject = YADIFReferenceWindow(generation: generation)
            _ = subject.push(try frame(id: 1, pts: 10), order: top)

            let transition = subject.push(
                try frame(id: 2, presentationTimeStamp: invalidPTS),
                order: top
            )

            XCTAssertNil(transition.job)
            XCTAssertEqual(transition.discarded.map(\.frame.accessUnitID), [1, 2])
            XCTAssertEqual(subject.bufferedCount, 0)
            XCTAssertEqual(subject.unemittedCount, 0)
        }
    }

    func testDuplicateAndBackwardTimestampDiscardTailAndStartFreshHead() throws {
        for restartedPTS in [10, 9] {
            var subject = YADIFReferenceWindow(generation: generation)
            _ = subject.push(try frame(id: 1, pts: 10), order: top)

            let transition = subject.push(
                try frame(id: 2, pts: Int64(restartedPTS)),
                order: top
            )

            XCTAssertNil(transition.job)
            XCTAssertEqual(transition.discarded.map(\.frame.accessUnitID), [1])
            XCTAssertEqual(subject.bufferedCount, 1)
            let head = try XCTUnwrap(subject.push(
                try frame(id: 3, pts: Int64(restartedPTS + 10)),
                order: top
            ).job)
            XCTAssertEqual(ids(in: head), [2, 2, 3])
        }
    }

    func testGapThresholdAcceptsExactThreeHalvesAndRejectsStrictlyGreaterDelta() throws {
        var exactBoundary = YADIFReferenceWindow(generation: generation)
        _ = exactBoundary.push(try frame(id: 1, pts: 0), order: top)
        _ = exactBoundary.push(try frame(id: 2, pts: 10), order: top)

        let accepted = exactBoundary.push(try frame(id: 3, pts: 25), order: top)

        XCTAssertEqual(accepted.job?.current.frame.accessUnitID, 2)
        XCTAssertTrue(accepted.discarded.isEmpty)

        var overBoundary = YADIFReferenceWindow(generation: generation)
        _ = overBoundary.push(try frame(id: 1, pts: 0), order: top)
        _ = overBoundary.push(try frame(id: 2, pts: 10), order: top)

        let gap = overBoundary.push(try frame(id: 3, pts: 26), order: top)

        XCTAssertNil(gap.job)
        XCTAssertEqual(gap.discarded.map(\.frame.accessUnitID), [2])
        XCTAssertEqual(overBoundary.unemittedCount, 1)
        let newHead = try XCTUnwrap(overBoundary.push(try frame(id: 4, pts: 36), order: top).job)
        XCTAssertEqual(ids(in: newHead), [3, 3, 4])
    }

    func testGapThresholdUsesExactCMTimeAcrossDifferentTimescales() throws {
        var exactBoundary = YADIFReferenceWindow(generation: generation)
        _ = exactBoundary.push(
            try frame(id: 1, presentationTimeStamp: CMTime(value: 0, timescale: 90_000)),
            order: top
        )
        _ = exactBoundary.push(
            try frame(id: 2, presentationTimeStamp: CMTime(value: 1, timescale: 10)),
            order: top
        )
        let accepted = exactBoundary.push(
            try frame(id: 3, presentationTimeStamp: CMTime(value: 1, timescale: 4)),
            order: top
        )
        XCTAssertEqual(accepted.job?.current.frame.accessUnitID, 2)
        XCTAssertTrue(accepted.discarded.isEmpty)

        var overBoundary = YADIFReferenceWindow(generation: generation)
        _ = overBoundary.push(
            try frame(id: 1, presentationTimeStamp: CMTime(value: 0, timescale: 90_000)),
            order: top
        )
        _ = overBoundary.push(
            try frame(id: 2, presentationTimeStamp: CMTime(value: 1, timescale: 10)),
            order: top
        )
        let rejected = overBoundary.push(
            try frame(id: 3, presentationTimeStamp: CMTime(value: 251, timescale: 1_000)),
            order: top
        )
        XCTAssertNil(rejected.job)
        XCTAssertEqual(rejected.discarded.map(\.frame.accessUnitID), [2])
    }

    func testGapUsesMedianOfLatestSevenAcceptedPositiveDeltas() throws {
        var accepted = YADIFReferenceWindow(generation: generation)
        var pts: Int64 = 0
        var id: UInt64 = 1
        _ = accepted.push(try frame(id: id, pts: pts), order: top)
        for delta in Array(repeating: Int64(10), count: 7)
            + Array(repeating: Int64(15), count: 7) {
            pts += delta
            id += 1
            _ = accepted.push(try frame(id: id, pts: pts), order: top)
        }

        pts += 22
        id += 1
        let atLatestMedianBoundary = accepted.push(try frame(id: id, pts: pts), order: top)
        XCTAssertNotNil(atLatestMedianBoundary.job)
        XCTAssertTrue(atLatestMedianBoundary.discarded.isEmpty)

        var rejected = YADIFReferenceWindow(generation: generation)
        pts = 0
        id = 1
        _ = rejected.push(try frame(id: id, pts: pts), order: top)
        for delta in Array(repeating: Int64(10), count: 7)
            + Array(repeating: Int64(15), count: 7) {
            pts += delta
            id += 1
            _ = rejected.push(try frame(id: id, pts: pts), order: top)
        }
        pts += 23
        id += 1

        let overLatestMedianBoundary = rejected.push(try frame(id: id, pts: pts), order: top)
        XCTAssertNil(overLatestMedianBoundary.job)
        XCTAssertEqual(overLatestMedianBoundary.discarded.count, 1)
    }

    func testFieldOrderChangeDiscardsTailAndJobUsesOrderStoredWithCurrent() throws {
        var subject = YADIFReferenceWindow(generation: generation)
        _ = subject.push(try frame(id: 1, pts: 0), order: top)

        let changed = subject.push(try frame(id: 2, pts: 10), order: bottom)

        XCTAssertNil(changed.job)
        XCTAssertEqual(changed.discarded.map(\.frame.accessUnitID), [1])
        let head = try XCTUnwrap(subject.push(try frame(id: 3, pts: 20), order: bottom).job)
        XCTAssertEqual(ids(in: head), [2, 2, 3])
        XCTAssertEqual(head.order, bottom)
    }

    func testResetReturnsOnlyUnemittedFrameAndReleasesEmittedReference() throws {
        weak var weakProbe: WindowLifetimeProbe?
        var subject = YADIFReferenceWindow(generation: generation)
        autoreleasepool {
            var probe: WindowLifetimeProbe? = WindowLifetimeProbe()
            weakProbe = probe
            var first: NormalizedDecodedFrame? = try? frame(
                id: 1,
                pts: 0,
                attachment: probe
            )
            _ = subject.push(try! XCTUnwrap(first), order: top)
            first = nil
            probe = nil
            XCTAssertNotNil(weakProbe)

            _ = subject.push(try! frame(id: 2, pts: 10), order: top)
            XCTAssertNotNil(weakProbe, "the window keeps the emitted previous reference")

            let discarded = subject.reset(
                generation: MediaGeneration(rawValue: generation.rawValue + 1)
            )
            XCTAssertEqual(discarded.map(\.frame.accessUnitID), [2])
            XCTAssertEqual(subject.bufferedCount, 0)
            XCTAssertEqual(subject.unemittedCount, 0)
        }
        XCTAssertNil(weakProbe, "reset must release references that were already emitted")
    }

    private func ids(in job: YADIFJob) -> [UInt64] {
        [
            job.previous.frame.accessUnitID,
            job.current.frame.accessUnitID,
            job.next.frame.accessUnitID,
        ]
    }

    private func frame(
        id: UInt64,
        pts: Int64,
        generation: MediaGeneration? = nil,
        attachment: WindowLifetimeProbe? = nil
    ) throws -> NormalizedDecodedFrame {
        try frame(
            id: id,
            presentationTimeStamp: CMTime(value: pts, timescale: 1),
            generation: generation,
            attachment: attachment
        )
    }

    private func frame(
        id: UInt64,
        presentationTimeStamp: CMTime,
        generation: MediaGeneration? = nil,
        attachment: WindowLifetimeProbe? = nil
    ) throws -> NormalizedDecodedFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            64,
            36,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        if let attachment {
            CVBufferSetAttachment(
                buffer,
                "org.vplayer.tests.yadif-window-lifetime" as CFString,
                attachment,
                .shouldNotPropagate
            )
        }
        let duration = CMTime(value: 1, timescale: 25)
        let actualGeneration = generation ?? self.generation
        return NormalizedDecodedFrame(
            frame: DecodedVideoFrame(
                accessUnitID: id,
                pixelBuffer: buffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                generation: actualGeneration,
                parserMetadata: VideoParserMetadata(
                    fieldOrder: .tt,
                    pictureStructure: .frame,
                    isInterlaced: true,
                    repeatFirstField: false,
                    topFieldFirst: true,
                    sourcePTS90k: nil
                ),
                formatMetadata: VideoFormatMetadata(
                    dimensions: .init(width: 64, height: 36),
                    bitDepth: 8,
                    range: .video,
                    matrix: .bt709,
                    transfer: .bt709,
                    primaries: .bt709,
                    cleanAperture: nil,
                    chromaLocation: .init(topField: nil, bottomField: nil),
                    hdrStaticMetadata: .init(
                        masteringDisplayColorVolume: nil,
                        contentLightLevelInfo: nil
                    )
                )
            ),
            presentationTimeStamp: presentationTimeStamp,
            frameDuration: duration,
            fieldDuration: CMTime(value: 1, timescale: 50),
            timingWasSynthesized: false,
            provenance: .trustedPresentationCadence
        )
    }
}

private final class WindowLifetimeProbe: NSObject {}
