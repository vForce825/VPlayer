// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest
@testable import VPlayerPlayback

final class YADIFAsyncLifetimeTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 41)
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

    func testEveryYADIFFailureHasAnExhaustiveTypedProcessingClassification() {
        let cases: [(YADIFFailure, YADIFProcessingFailureClassification)] = [
            (.invalidDimensions, .structural(.invalidSurface)),
            (.unsupportedPixelFormat(0x1234), .structural(.invalidSurface)),
            (.poolCreationFailed(-1), .structural(.surfacePool)),
            (.poolAllocationFailed(-2), .transient(.resourcePressure)),
            (.incompatibleRendererAttributes, .structural(.rendererAttributes)),
            (.nonIOSurfaceOutput, .structural(.invalidSurface)),
            (.invalidPlaneLayout, .structural(.invalidSurface)),
            (.metalTextureCacheCreationFailed(-3), .structural(.textureMapping)),
            (
                .metalTextureMappingFailed(plane: 1, status: -4),
                .structural(.textureMapping)
            ),
            (.shaderLibraryUnavailable, .structural(.shaderPipeline)),
            (.shaderFunctionUnavailable("field"), .structural(.shaderPipeline)),
            (.pipelineCreationFailed, .structural(.shaderPipeline)),
            (.commandBufferAllocationFailed, .transient(.resourcePressure)),
            (.commandEncoderAllocationFailed, .transient(.resourcePressure)),
            (.commandFailed, .structural(.commandExecution)),
        ]

        for (failure, expected) in cases {
            XCTAssertEqual(failure.processingClassification, expected, "\(failure)")
        }
    }

    func testPublicContractsAreSendableAndQueueLimitsAreValidated() throws {
        assertSendable(YADIFDropReason.self)
        assertSendable(YADIFDropEvent.self)
        assertSendable(YADIFProcessorMetrics.self)
        assertSendable(YADIFCommandResult.self)
        assertSendable(YADIFProcessor.self)

        let harness = try makeHarness()
        XCTAssertEqual(harness.processor.requiredInputFrameCount, 3)
        XCTAssertEqual(harness.processor.metricsSnapshot, YADIFProcessorMetrics(
            inFlightCount: 0,
            pendingFrameCount: 0,
            submittedJobCount: 0,
            completedJobCount: 0,
            gpuQueueFullDropCount: 0,
            staleGenerationDropCount: 0
        ))

        for invalidInFlight in [0, 4] {
            XCTAssertThrowsError(try YADIFProcessor(
                commandSubmitter: FakeMetalCommandQueue(),
                surfacePool: ProgressiveSurfacePool(),
                clock: TestYADIFClock(),
                maximumInFlight: invalidInFlight,
                maximumPendingFrames: 4
            ))
        }
        XCTAssertThrowsError(try YADIFProcessor(
            commandSubmitter: FakeMetalCommandQueue(),
            surfacePool: ProgressiveSurfacePool(),
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 0
        ))
    }

    func testDecodedCompatibilityValidatesTimingAndResolvesCodedOrderBeforeFallbacks() throws {
        for (coded, topFieldFirst, expectedParity) in [
            (CodedFieldOrder.bb, true, FieldParity.bottom),
            (.unknown, false, .bottom),
            (.unknown, nil, .top),
        ] {
            let harness = try makeHarness(maximumInFlight: 1)
            harness.processor.submit(try decoded(
                id: 1,
                codedOrder: coded,
                topFieldFirst: topFieldFirst
            )) { harness.results.record(id: 1, result: $0) }
            harness.processor.submit(try decoded(
                id: 2,
                codedOrder: coded,
                topFieldFirst: topFieldFirst
            )) { harness.results.record(id: 2, result: $0) }

            let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)
            let job = try XCTUnwrap(harness.queue.submission(identifier: identifier)).job
            XCTAssertEqual(job.order.parity, expectedParity)
            XCTAssertEqual(job.current.fieldDuration, CMTime(value: 1, timescale: 50))
            XCTAssertEqual(job.current.frameDuration, CMTime(value: 1, timescale: 25))
        }
    }

    func testDecodedCompatibilityDropsInvalidTimingAsTypedTransientWithoutGPUWork() throws {
        let invalidFrames = try [
            decoded(id: 1, pts: .invalid),
            decoded(id: 2, pts: .indefinite),
            decoded(id: 3, duration: .zero),
            decoded(id: 4, duration: CMTime(value: -1, timescale: 25)),
            decoded(id: 5, duration: .indefinite),
        ]
        for frame in invalidFrames {
            let harness = try makeHarness()
            harness.processor.submit(frame) { harness.results.record(id: frame.accessUnitID, result: $0) }
            let result = try XCTUnwrap(harness.results.results(for: frame.accessUnitID).first)
            assertTransientDrop(result, reason: .invalidTiming)
            XCTAssertEqual(harness.queue.committedCount, 0)
            XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 0)
        }
    }

    func testOutputsReserveExactTimingMetadataAndSequenceBeforeArbitraryGPUCompletion() throws {
        let harness = try makeHarness(maximumInFlight: 2)
        let first = try normalized(id: 1, pts: CMTime(value: 10, timescale: 25))
        let second = try normalized(id: 2, pts: CMTime(value: 11, timescale: 25))
        let third = try normalized(id: 3, pts: CMTime(value: 12, timescale: 25))
        submit(first, to: harness)
        submit(second, to: harness)
        submit(third, to: harness)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 2])
        let identifiers = harness.queue.submissionIdentifiers
        let firstSubmission = try XCTUnwrap(harness.queue.submission(identifier: identifiers[0]))
        let secondSubmission = try XCTUnwrap(harness.queue.submission(identifier: identifiers[1]))

        harness.queue.complete(identifier: identifiers[1], result: .completed)
        harness.queue.complete(identifier: identifiers[0], result: .completed)

        let sourceTwo = try producedFrames(harness.results.singleResult(for: 2))
        let sourceOne = try producedFrames(harness.results.singleResult(for: 1))
        XCTAssertEqual(sourceOne.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(sourceTwo.map(\.sequenceNumber), [3, 4])
        XCTAssertEqual(sourceOne.map(\.presentationTimeStamp), [
            first.presentationTimeStamp,
            CMTimeAdd(first.presentationTimeStamp, first.fieldDuration),
        ])
        XCTAssertEqual(sourceTwo.map(\.presentationTimeStamp), [
            second.presentationTimeStamp,
            CMTimeAdd(second.presentationTimeStamp, second.fieldDuration),
        ])
        XCTAssertEqual(sourceOne.map(\.duration), [first.fieldDuration, first.fieldDuration])
        XCTAssertEqual(sourceTwo.map(\.duration), [second.fieldDuration, second.fieldDuration])
        XCTAssertEqual(sourceOne.map(\.sourceAccessUnitID), [1, 1])
        XCTAssertEqual(sourceTwo.map(\.sourceAccessUnitID), [2, 2])
        XCTAssertEqual(sourceOne.map(\.generation), [generation, generation])
        XCTAssertEqual(sourceTwo.map(\.generation), [generation, generation])
        XCTAssertEqual(sourceOne.map(\.formatMetadata), [
            first.frame.formatMetadata,
            first.frame.formatMetadata,
        ])
        XCTAssertTrue(try pixelBuffer(from: sourceOne[0]) === firstSubmission.outputs.first)
        XCTAssertTrue(try pixelBuffer(from: sourceOne[1]) === firstSubmission.outputs.second)
        XCTAssertTrue(try pixelBuffer(from: sourceTwo[0]) === secondSubmission.outputs.first)
        XCTAssertTrue(try pixelBuffer(from: sourceTwo[1]) === secondSubmission.outputs.second)
        XCTAssertEqual(harness.results.results(for: 1).count, 1)
        XCTAssertEqual(harness.results.results(for: 2).count, 1)
        XCTAssertEqual(harness.processor.metricsSnapshot.submittedJobCount, 2)
        XCTAssertEqual(harness.processor.metricsSnapshot.completedJobCount, 2)
        XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 0)
    }

    func testCommandOutputsBecomeTheExactPixelBufferPresentationFrames() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        submit(try normalized(id: 1), to: harness)
        submit(try normalized(id: 2), to: harness)
        let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)
        let submission = try XCTUnwrap(harness.queue.submission(identifier: identifier))

        harness.queue.complete(
            identifier: identifier,
            completion: YADIFCommandCompletion(result: .completed)
        )

        let frames = try producedFrames(harness.results.singleResult(for: 1))
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(try pixelBuffer(from: frames[0]) === submission.outputs.first)
        XCTAssertTrue(try pixelBuffer(from: frames[1]) === submission.outputs.second)
    }

    func testMaximumThreeInflightJobsAndArbitraryCompletionResumeFIFOReadyWorkWithoutWait() throws {
        let harness = try makeHarness(
            maximumInFlight: 3,
            maximumPendingFrames: 4
        )
        for id in 1...6 {
            submit(try normalized(id: UInt64(id)), to: harness)
        }

        XCTAssertEqual(harness.queue.committedCount, 3)
        XCTAssertEqual(harness.queue.pendingSubmissionCount, 3)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 2, 3])
        XCTAssertEqual(harness.queue.waitUntilCompletedCallCount, 0)
        XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 3)
        XCTAssertEqual(harness.processor.metricsSnapshot.pendingFrameCount, 3)

        let identifiers = harness.queue.submissionIdentifiers
        harness.queue.complete(identifier: identifiers[1], result: .completed)

        XCTAssertEqual(harness.queue.committedCount, 4)
        XCTAssertEqual(harness.queue.pendingSubmissionCount, 3)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 2, 3, 4])
        XCTAssertEqual(harness.queue.waitUntilCompletedCallCount, 0)
        XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 3)

        harness.queue.complete(identifier: identifiers[0], result: .completed)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 2, 3, 4, 5])
    }

    func testPendingOverflowDropsOldestEligibleUnsubmittedJobAndNeverInflightWork() throws {
        let clock = TestYADIFClock()
        clock.set(CMTime(value: 4, timescale: 25))
        let harness = try makeHarness(
            clock: clock,
            maximumInFlight: 3,
            maximumPendingFrames: 2
        )
        for id in 1...6 {
            submit(try normalized(id: UInt64(id)), to: harness)
        }

        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 2, 3])
        XCTAssertEqual(harness.drops.snapshot, [YADIFDropEvent(
            reason: .gpuQueueFull,
            sourceAccessUnitID: 4,
            presentationTimeStamp: CMTime(value: 3, timescale: 25)
        )])
        assertTransientDrop(
            harness.results.singleResult(for: 4),
            reason: .queuePressure
        )
        XCTAssertEqual(harness.results.results(for: 4).count, 1)
        XCTAssertEqual(harness.processor.metricsSnapshot.gpuQueueFullDropCount, 1)
        XCTAssertEqual(harness.processor.metricsSnapshot.pendingFrameCount, 2)
        XCTAssertEqual(harness.queue.waitUntilCompletedCallCount, 0)

        harness.queue.complete(
            identifier: try XCTUnwrap(harness.queue.submissionIdentifiers.last),
            result: .completed
        )
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 2, 3, 5])
        XCTAssertFalse(harness.queue.submittedSourceAccessUnitIDs.contains(4))
    }

    // Raising the bound from the settings sheet has to help the stream already
    // playing, and lowering it has to shed down to the new bound rather than wait
    // for the next arrival to notice.
    func testPendingBoundChangesApplyToAProcessorThatIsAlreadyRunning() throws {
        let clock = TestYADIFClock()
        clock.set(CMTime(value: 4, timescale: 25))
        let harness = try makeHarness(
            clock: clock,
            maximumInFlight: 3,
            maximumPendingFrames: 2
        )
        harness.processor.setMaximumPendingFrames(6)
        for id in 1...8 {
            submit(try normalized(id: UInt64(id)), to: harness)
        }
        XCTAssertTrue(harness.drops.snapshot.isEmpty)
        XCTAssertEqual(harness.processor.metricsSnapshot.gpuQueueFullDropCount, 0)
        XCTAssertEqual(harness.processor.metricsSnapshot.pendingFrameCount, 5)

        harness.processor.setMaximumPendingFrames(2)
        XCTAssertEqual(harness.processor.metricsSnapshot.pendingFrameCount, 2)
        XCTAssertEqual(harness.processor.metricsSnapshot.gpuQueueFullDropCount, 3)

        // A bound below one would stall the deinterlacer outright.
        harness.processor.setMaximumPendingFrames(0)
        XCTAssertEqual(harness.processor.metricsSnapshot.pendingFrameCount, 2)
    }

    func testLateReadyJobsAreNotDroppedWithoutPendingPressure() throws {
        let clock = TestYADIFClock()
        clock.set(CMTime(value: 1_000, timescale: 1))
        let harness = try makeHarness(
            clock: clock,
            maximumInFlight: 3,
            maximumPendingFrames: 4
        )
        for id in 1...6 {
            submit(try normalized(id: UInt64(id)), to: harness)
        }

        XCTAssertTrue(harness.drops.snapshot.isEmpty)
        XCTAssertEqual(harness.processor.metricsSnapshot.gpuQueueFullDropCount, 0)
        XCTAssertEqual(harness.processor.metricsSnapshot.pendingFrameCount, 3)
    }

    func testPendingBoundIsImmediateWhileCommandSubmissionIsBlockedOutsideLock() throws {
        let submitter = BlockingYADIFCommandSubmitter()
        let results = YADIFProcessorResultRecorder()
        let drops = YADIFDropRecorder()
        let processor = try YADIFProcessor(
            commandSubmitter: submitter,
            surfacePool: ProgressiveSurfacePool(),
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 1,
            dropSink: { drops.record($0) }
        )
        processor.reset(to: generation)
        let frames = try (1...9).map { try normalized(id: UInt64($0)) }
        processor.submit(normalized: frames[0], order: top) {
            results.record(id: 1, result: $0)
        }

        let blockedSubmitReturned = expectation(description: "blocked command submit returned")
        let order = top
        DispatchQueue.global().async {
            processor.submit(normalized: frames[1], order: order) {
                results.record(id: 2, result: $0)
            }
            blockedSubmitReturned.fulfill()
        }
        XCTAssertTrue(submitter.waitUntilBlocked())

        for (index, frame) in frames[2...].enumerated() {
            processor.submit(normalized: frame, order: top) {
                results.record(id: UInt64(index + 3), result: $0)
            }
        }

        let pendingFrameCountWhileBlocked = processor.metricsSnapshot.pendingFrameCount
        let dropIDsWhileBlocked = drops.snapshot.map(\.sourceAccessUnitID)
        let resultCountsWhileBlocked = (UInt64(2)...8).map {
            results.results(for: $0).count
        }

        submitter.unblock()
        wait(for: [blockedSubmitReturned], timeout: 5)
        processor.reset(to: generation)
        submitter.completeNext(.completed)

        XCTAssertEqual(pendingFrameCountWhileBlocked, 1)
        XCTAssertEqual(dropIDsWhileBlocked, Array(UInt64(2)...8))
        XCTAssertEqual(resultCountsWhileBlocked, Array(repeating: 1, count: 7))
        for id in UInt64(2)...8 {
            assertTransientDrop(results.singleResult(for: id), reason: .queuePressure)
        }
        XCTAssertEqual(results.results(for: 1).count, 1)
        XCTAssertEqual(results.results(for: 9).count, 1)
    }

    func testPendingBoundCountsReservedAttemptBeforeAndAfterResetWhileAllocationIsBlocked() throws {
        let queue = FakeMetalCommandQueue()
        let allocator = BlockingYADIFOutputAllocator()
        let results = YADIFProcessorResultRecorder()
        let drops = YADIFDropRecorder()
        let outputAllocator: YADIFOutputAllocator = { source in
            try allocator.allocate(matching: source)
        }
        let processor = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            outputAllocator: outputAllocator,
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 1,
            dropSink: { drops.record($0) }
        )
        processor.reset(to: generation)
        let frames = try (1...9).map { try normalized(id: UInt64($0)) }
        processor.submit(normalized: frames[0], order: top) {
            results.record(id: 1, result: $0)
        }

        let blockedSubmitReturned = expectation(description: "blocked allocation submit returned")
        let order = top
        DispatchQueue.global().async {
            processor.submit(normalized: frames[1], order: order) {
                results.record(id: 2, result: $0)
            }
            blockedSubmitReturned.fulfill()
        }
        XCTAssertTrue(allocator.waitUntilBlocked())

        for (index, frame) in frames[2...4].enumerated() {
            processor.submit(normalized: frame, order: top) {
                results.record(id: UInt64(index + 3), result: $0)
            }
        }

        XCTAssertEqual(processor.metricsSnapshot.pendingFrameCount, 1)
        XCTAssertEqual(drops.snapshot.map(\.sourceAccessUnitID), [2, 3, 4])
        processor.reset(to: generation)
        XCTAssertEqual(results.results(for: 1).count, 1)
        XCTAssertEqual(results.results(for: 5).count, 1)

        for (index, frame) in frames[5...8].enumerated() {
            processor.submit(normalized: frame, order: top) {
                results.record(id: UInt64(index + 6), result: $0)
            }
        }
        XCTAssertEqual(processor.metricsSnapshot.pendingFrameCount, 1)
        XCTAssertEqual(drops.snapshot.map(\.sourceAccessUnitID), [2, 3, 4, 6, 7, 8])
        processor.reset(to: generation)
        XCTAssertEqual(results.results(for: 9).count, 1)

        allocator.unblock()
        wait(for: [blockedSubmitReturned], timeout: 5)
        XCTAssertEqual(queue.committedCount, 0)
        for id in UInt64(1)...9 {
            XCTAssertEqual(results.results(for: id).count, 1)
        }
    }

    func testResetClosesQueuedTailImmediatelyAndInflightCompletionOnlyAfterResourceRelease() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        submit(try normalized(id: 1), to: harness)
        submit(try normalized(id: 2), to: harness)
        let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)
        weak var retainedToken: FakeYADIFSubmissionToken?
        autoreleasepool {
            retainedToken = harness.queue.submissionToken(identifier: identifier)
        }
        XCTAssertNotNil(retainedToken)
        XCTAssertTrue(harness.results.results(for: 1).isEmpty)
        XCTAssertTrue(harness.results.results(for: 2).isEmpty)

        let nextGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        harness.processor.reset(to: nextGeneration)

        assertCancelled(harness.results.singleResult(for: 2), reason: .reset)
        XCTAssertTrue(harness.results.results(for: 1).isEmpty)
        XCTAssertNotNil(retainedToken)
        XCTAssertEqual(harness.processor.metricsSnapshot, YADIFProcessorMetrics(
            inFlightCount: 0,
            pendingFrameCount: 0,
            submittedJobCount: 0,
            completedJobCount: 0,
            gpuQueueFullDropCount: 0,
            staleGenerationDropCount: 0
        ))

        harness.queue.complete(identifier: identifier, result: .completed)

        assertCancelled(harness.results.singleResult(for: 1), reason: .reset)
        XCTAssertEqual(harness.results.results(for: 1).count, 1)
        XCTAssertNil(retainedToken)

        submit(try normalized(id: 3, generation: nextGeneration), to: harness)
        submit(try normalized(id: 4, generation: nextGeneration), to: harness)
        let newIdentifier = try XCTUnwrap(harness.queue.submissionIdentifiers.last)
        harness.queue.complete(identifier: newIdentifier, result: .completed)
        XCTAssertEqual(
            try producedFrames(harness.results.singleResult(for: 3)).map(\.sequenceNumber),
            [1, 2]
        )
    }

    func testSameGenerationResetMakesInflightWorkStaleAndRestartsSequenceAndMetrics() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        submit(try normalized(id: 1), to: harness)
        submit(try normalized(id: 2), to: harness)
        let staleIdentifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)

        harness.processor.reset(to: generation)

        assertCancelled(harness.results.singleResult(for: 2), reason: .reset)
        XCTAssertTrue(harness.results.results(for: 1).isEmpty)
        XCTAssertEqual(harness.processor.metricsSnapshot.submittedJobCount, 0)
        submit(try normalized(id: 3), to: harness)
        submit(try normalized(id: 4), to: harness)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1])

        harness.queue.complete(identifier: staleIdentifier, result: .completed)

        assertCancelled(harness.results.singleResult(for: 1), reason: .reset)
        XCTAssertEqual(harness.results.results(for: 1).count, 1)
        XCTAssertEqual(harness.processor.metricsSnapshot.completedJobCount, 0)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 3])
        let currentIdentifier = try XCTUnwrap(harness.queue.submissionIdentifiers.last)
        harness.queue.complete(identifier: currentIdentifier, result: .completed)
        XCTAssertEqual(
            try producedFrames(harness.results.singleResult(for: 3)).map(\.sequenceNumber),
            [1, 2]
        )
        XCTAssertEqual(harness.processor.metricsSnapshot.submittedJobCount, 1)
        XCTAssertEqual(harness.processor.metricsSnapshot.completedJobCount, 1)
    }

    func testTerminalCommandCallbackOwnsProcessorAndUserCompletionUntilItFires() throws {
        let queue = FakeMetalCommandQueue()
        let results = YADIFProcessorResultRecorder()
        var processor: YADIFProcessor? = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 2
        )
        processor?.reset(to: generation)
        processor?.submit(normalized: try normalized(id: 1), order: top) {
            results.record(id: 1, result: $0)
        }
        processor?.submit(normalized: try normalized(id: 2), order: top) {
            results.record(id: 2, result: $0)
        }
        let identifier = try XCTUnwrap(queue.submissionIdentifiers.first)
        weak var retainedProcessor: YADIFProcessor?
        retainedProcessor = processor

        processor = nil

        XCTAssertNotNil(retainedProcessor)
        XCTAssertTrue(results.results(for: 1).isEmpty)
        queue.complete(identifier: identifier, result: .completed)

        XCTAssertEqual(try producedFrames(results.singleResult(for: 1)).count, 2)
        XCTAssertNil(retainedProcessor)
    }

    func testSynchronousSubmissionFailuresRollbackSlotCloseOnceAndContinueScheduling() throws {
        for (failure, expected) in [
            (
                YADIFFailure.commandBufferAllocationFailed,
                YADIFProcessingFailureClassification.transient(.resourcePressure)
            ),
            (
                .metalTextureMappingFailed(plane: 0, status: -61),
                .structural(.textureMapping)
            ),
            (
                .commandEncoderAllocationFailed,
                .transient(.resourcePressure)
            ),
        ] {
            let harness = try makeHarness(maximumInFlight: 1)
            harness.queue.failNextSubmission(with: failure)
            submit(try normalized(id: 1), to: harness)
            submit(try normalized(id: 2), to: harness)

            let result = harness.results.singleResult(for: 1)
            switch expected {
            case let .transient(reason):
                assertTransientDrop(result, reason: reason)
            case let .structural(failure):
                assertStructuralFailure(result, failure: failure)
            }
            XCTAssertEqual(harness.results.results(for: 1).count, 1)
            XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 0)

            submit(try normalized(id: 3), to: harness)
            XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [2])
            XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 1)
        }
    }

    func testTerminalCommandFailureReturnsTypedStructuralFailureAndReleasesSlot() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        submit(try normalized(id: 1), to: harness)
        submit(try normalized(id: 2), to: harness)
        let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)

        harness.queue.complete(identifier: identifier, result: .failed)

        assertStructuralFailure(
            harness.results.singleResult(for: 1),
            failure: .commandExecution
        )
        XCTAssertEqual(harness.results.results(for: 1).count, 1)
        XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 0)
        XCTAssertEqual(harness.processor.metricsSnapshot.completedJobCount, 1)
    }

    func testSubmitterMayCompleteSynchronouslyWithoutLockReentryOrDuplicateCallback() throws {
        let submitter = ImmediateYADIFCommandSubmitter()
        let results = YADIFProcessorResultRecorder()
        let processor = try YADIFProcessor(
            commandSubmitter: submitter,
            surfacePool: ProgressiveSurfacePool(),
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 2
        )
        processor.reset(to: generation)
        let first = try normalized(id: 1)
        let second = try normalized(id: 2)

        processor.submit(normalized: first, order: top) {
            results.record(id: 1, result: $0)
        }
        processor.submit(normalized: second, order: top) {
            results.record(id: 2, result: $0)
        }

        let outputs = try producedFrames(results.singleResult(for: 1))
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(results.results(for: 1).count, 1)
        XCTAssertEqual(submitter.submitCount, 1)
        XCTAssertEqual(processor.metricsSnapshot.inFlightCount, 0)
        XCTAssertEqual(processor.metricsSnapshot.submittedJobCount, 1)
        XCTAssertEqual(processor.metricsSnapshot.completedJobCount, 1)
    }

    func testDrainProcessesOneFrameTailActsAsBarrierAndRejectsSubmitsUntilReset() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        let barriers = YADIFDrainBarrierRecorder()
        submit(try normalized(id: 1), to: harness)
        harness.processor.drain { barriers.record(id: 100) }

        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1])
        XCTAssertTrue(harness.results.results(for: 1).isEmpty)
        XCTAssertEqual(barriers.count(for: 100), 0)

        submit(try normalized(id: 2), to: harness)
        assertCancelled(harness.results.singleResult(for: 2), reason: .draining)
        let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)
        harness.queue.complete(identifier: identifier, result: .completed)

        let tail = try producedFrames(harness.results.singleResult(for: 1))
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(tail.map(\.sourceAccessUnitID), [1, 1])
        XCTAssertEqual(barriers.count(for: 100), 1)

        harness.processor.drain { barriers.record(id: 101) }
        XCTAssertEqual(barriers.count(for: 101), 1)

        let nextGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        harness.processor.reset(to: nextGeneration)
        submit(try normalized(id: 3, generation: nextGeneration), to: harness)
        XCTAssertTrue(harness.results.results(for: 3).isEmpty)
    }

    func testDuplicateNormalizedInstanceOwnsBothCompletionsExactlyOnceThroughDrain() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        let barriers = YADIFDrainBarrierRecorder()
        let frame = try normalized(id: 1)
        harness.processor.submit(normalized: frame, order: top) {
            harness.results.record(id: 101, result: $0)
        }
        harness.processor.submit(normalized: frame, order: top) {
            harness.results.record(id: 102, result: $0)
        }

        let firstResultBeforeDrain = harness.results.results(for: 101).first
        let secondResultCountBeforeDrain = harness.results.results(for: 102).count
        harness.processor.drain { barriers.record(id: 103) }
        harness.queue.completeNext(.completed)

        if let firstResultBeforeDrain {
            assertCancelled(firstResultBeforeDrain, reason: .referenceWindowDiscard)
        } else {
            XCTFail("first duplicate completion must close before drain")
        }
        XCTAssertEqual(secondResultCountBeforeDrain, 0)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1])
        XCTAssertEqual(try? producedFrames(harness.results.singleResult(for: 102)).count, 2)
        XCTAssertEqual(barriers.count(for: 103), 1)
        for id in UInt64(101)...102 {
            XCTAssertEqual(harness.results.results(for: id).count, 1)
        }
    }

    func testDuplicateNormalizedInstanceOwnsBothCompletionsExactlyOnceThroughReset() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        let frame = try normalized(id: 1)
        harness.processor.submit(normalized: frame, order: top) {
            harness.results.record(id: 101, result: $0)
        }
        harness.processor.submit(normalized: frame, order: top) {
            harness.results.record(id: 102, result: $0)
        }

        harness.processor.reset(to: generation)

        assertCancelled(
            harness.results.singleResult(for: 101),
            reason: .referenceWindowDiscard
        )
        assertCancelled(harness.results.singleResult(for: 102), reason: .reset)
        XCTAssertEqual(harness.results.results(for: 101).count, 1)
        XCTAssertEqual(harness.results.results(for: 102).count, 1)
        XCTAssertEqual(harness.queue.committedCount, 0)
    }

    func testSameInputKeyIncreasingTimestampsPopCompletionsInSubmissionOrder() throws {
        let submitter = ImmediateYADIFCommandSubmitter()
        let results = YADIFProcessorResultRecorder()
        let barriers = YADIFDrainBarrierRecorder()
        let processor = try YADIFProcessor(
            commandSubmitter: submitter,
            surfacePool: ProgressiveSurfacePool(),
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 2
        )
        processor.reset(to: generation)
        let first = try normalized(id: 1, pts: .zero)
        let laterTimestamp = CMTime(value: 1, timescale: 25)
        let later = NormalizedDecodedFrame(
            frame: first.frame,
            presentationTimeStamp: laterTimestamp,
            frameDuration: first.frameDuration,
            fieldDuration: first.fieldDuration,
            timingWasSynthesized: first.timingWasSynthesized,
            provenance: first.provenance
        )
        processor.submit(normalized: first, order: top) {
            results.record(id: 101, result: $0)
        }
        processor.submit(normalized: later, order: top) {
            results.record(id: 102, result: $0)
        }
        processor.drain { barriers.record(id: 103) }

        XCTAssertEqual(
            try? producedFrames(results.singleResult(for: 101)).first?.presentationTimeStamp,
            first.presentationTimeStamp
        )
        XCTAssertEqual(
            try? producedFrames(results.singleResult(for: 102)).first?.presentationTimeStamp,
            laterTimestamp
        )
        XCTAssertEqual(barriers.count(for: 103), 1)
        for id in UInt64(101)...102 {
            XCTAssertEqual(results.results(for: id).count, 1)
        }
    }

    func testSameInputKeyInvalidTimestampDiscardsBothCompletionsInSubmissionOrder() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        let valid = try normalized(id: 1)
        let invalid = NormalizedDecodedFrame(
            frame: valid.frame,
            presentationTimeStamp: .invalid,
            frameDuration: valid.frameDuration,
            fieldDuration: valid.fieldDuration,
            timingWasSynthesized: valid.timingWasSynthesized,
            provenance: valid.provenance
        )
        harness.processor.submit(normalized: valid, order: top) {
            harness.results.record(id: 101, result: $0)
        }
        harness.processor.submit(normalized: invalid, order: top) {
            harness.results.record(id: 102, result: $0)
        }

        assertCancelled(
            harness.results.singleResult(for: 101),
            reason: .referenceWindowDiscard
        )
        assertCancelled(
            harness.results.singleResult(for: 102),
            reason: .referenceWindowDiscard
        )
        XCTAssertEqual(harness.results.results(for: 101).count, 1)
        XCTAssertEqual(harness.results.results(for: 102).count, 1)
        XCTAssertEqual(harness.queue.committedCount, 0)
    }

    func testResetClosesReservedAttemptWhileAllocationIsBlockedAndFinalizeDoesNotResubmit() throws {
        let queue = FakeMetalCommandQueue()
        let allocator = BlockingYADIFOutputAllocator()
        let outputAllocator: YADIFOutputAllocator = { source in
            try allocator.allocate(matching: source)
        }
        let results = YADIFProcessorResultRecorder()
        let processor = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            outputAllocator: outputAllocator,
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 2
        )
        processor.reset(to: generation)
        let first = try normalized(id: 1)
        let second = try normalized(id: 2)
        processor.submit(normalized: first, order: top) {
            results.record(id: 1, result: $0)
        }
        let order = top
        let submitReturned = expectation(description: "blocked submit returned")
        DispatchQueue.global().async {
            processor.submit(normalized: second, order: order) {
                results.record(id: 2, result: $0)
            }
            submitReturned.fulfill()
        }
        XCTAssertTrue(allocator.waitUntilBlocked())

        processor.reset(to: generation)

        assertCancelled(results.singleResult(for: 1), reason: .reset)
        assertCancelled(results.singleResult(for: 2), reason: .reset)
        XCTAssertEqual(results.results(for: 1).count, 1)
        XCTAssertEqual(results.results(for: 2).count, 1)
        XCTAssertEqual(processor.metricsSnapshot.submittedJobCount, 0)
        allocator.unblock()
        wait(for: [submitReturned], timeout: 5)
        XCTAssertEqual(queue.committedCount, 0)
        XCTAssertEqual(results.results(for: 1).count, 1)
        XCTAssertEqual(results.results(for: 2).count, 1)
    }

    func testDrainBarrierWaitsAcrossReservedAttemptAndCommittedCompletion() throws {
        let queue = FakeMetalCommandQueue()
        let allocator = BlockingYADIFOutputAllocator()
        let outputAllocator: YADIFOutputAllocator = { source in
            try allocator.allocate(matching: source)
        }
        let results = YADIFProcessorResultRecorder()
        let barriers = YADIFDrainBarrierRecorder()
        let processor = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            outputAllocator: outputAllocator,
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 2
        )
        processor.reset(to: generation)
        let first = try normalized(id: 1)
        processor.submit(normalized: first, order: top) {
            results.record(id: 1, result: $0)
        }
        let drainReturned = expectation(description: "blocked drain returned")
        DispatchQueue.global().async {
            processor.drain { barriers.record(id: 100) }
            drainReturned.fulfill()
        }
        XCTAssertTrue(allocator.waitUntilBlocked())
        XCTAssertTrue(results.results(for: 1).isEmpty)
        XCTAssertEqual(barriers.count(for: 100), 0)

        allocator.unblock()
        wait(for: [drainReturned], timeout: 5)
        XCTAssertEqual(queue.committedCount, 1)
        XCTAssertEqual(barriers.count(for: 100), 0)

        queue.completeNext(.completed)
        XCTAssertEqual(try producedFrames(results.singleResult(for: 1)).count, 2)
        XCTAssertEqual(barriers.count(for: 100), 1)
    }

    func testResetDuringDrainWaitsForOldGPUCompletionAndOrdersSubmitBeforeBarrier() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        let events = YADIFLifecycleEventRecorder()
        let frame = try normalized(id: 1)
        harness.processor.submit(normalized: frame, order: top) { result in
            harness.results.record(id: 1, result: result)
            events.record("submit")
        }
        harness.processor.drain { events.record("drain") }
        let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)
        XCTAssertEqual(events.snapshot, [])

        harness.processor.reset(to: MediaGeneration(rawValue: generation.rawValue + 1))

        XCTAssertEqual(events.snapshot, [])
        harness.queue.complete(identifier: identifier, result: .completed)
        XCTAssertEqual(events.snapshot, ["submit", "drain"])
        assertCancelled(harness.results.singleResult(for: 1), reason: .reset)
    }

    func testResetDuringDrainWaitsUntilBlockedAllocatorRetiresBeforeBarrier() throws {
        let queue = FakeMetalCommandQueue()
        let allocator = BlockingYADIFOutputAllocator()
        let events = YADIFLifecycleEventRecorder()
        let results = YADIFProcessorResultRecorder()
        let outputAllocator: YADIFOutputAllocator = { source in
            try allocator.allocate(matching: source)
        }
        let processor = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            outputAllocator: outputAllocator,
            clock: TestYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 2
        )
        processor.reset(to: generation)
        let frame = try normalized(id: 1)
        processor.submit(normalized: frame, order: top) { result in
            results.record(id: 1, result: result)
            events.record("submit")
        }
        let drainReturned = expectation(description: "drain returned after allocator")
        DispatchQueue.global().async {
            processor.drain { events.record("drain") }
            drainReturned.fulfill()
        }
        XCTAssertTrue(allocator.waitUntilBlocked())

        processor.reset(to: MediaGeneration(rawValue: generation.rawValue + 1))

        XCTAssertEqual(events.snapshot, ["submit"])
        allocator.unblock()
        wait(for: [drainReturned], timeout: 5)
        XCTAssertEqual(events.snapshot, ["submit", "drain"])
        XCTAssertEqual(queue.committedCount, 0)
        assertCancelled(results.singleResult(for: 1), reason: .reset)
    }

    func testOldDrainCutoffDoesNotWaitForNewGenerationWork() throws {
        let harness = try makeHarness(maximumInFlight: 2)
        let events = YADIFLifecycleEventRecorder()
        let oldFrame = try normalized(id: 1)
        harness.processor.submit(normalized: oldFrame, order: top) { result in
            harness.results.record(id: 1, result: result)
            events.record("old-submit")
        }
        harness.processor.drain { events.record("old-drain") }
        let oldIdentifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)

        let nextGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        harness.processor.reset(to: nextGeneration)
        for id in UInt64(2)...4 {
            submit(try normalized(id: id, generation: nextGeneration), to: harness)
        }
        XCTAssertEqual(harness.queue.pendingSubmissionCount, 2)

        harness.queue.complete(identifier: oldIdentifier, result: .completed)

        XCTAssertEqual(events.snapshot, ["old-submit", "old-drain"])
        assertCancelled(harness.results.singleResult(for: 1), reason: .reset)
        XCTAssertGreaterThan(harness.queue.pendingSubmissionCount, 0)
        XCTAssertTrue(harness.results.results(for: 2).isEmpty)
    }

    func testDrainBarrierCallbackMayReenterResetAndSubmitWithoutDeadlock() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        let nextGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        let reentered = expectation(description: "drain callback reentered processor")
        let oldFrame = try normalized(id: 1)
        let newFrame = try normalized(id: 2, generation: nextGeneration)
        let order = top
        harness.processor.submit(normalized: oldFrame, order: top) {
            harness.results.record(id: 1, result: $0)
        }
        harness.processor.drain {
            harness.processor.reset(to: nextGeneration)
            harness.processor.submit(normalized: newFrame, order: order) {
                harness.results.record(id: 2, result: $0)
            }
            reentered.fulfill()
        }

        harness.queue.completeNext(.completed)

        wait(for: [reentered], timeout: 1)
        XCTAssertEqual(try producedFrames(harness.results.singleResult(for: 1)).count, 2)
        XCTAssertTrue(harness.results.results(for: 2).isEmpty)
    }

    func testDiscontinuityOrderChangeGapAndStaleGenerationCloseEachAffectedInputExactlyOnce() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        submit(try normalized(id: 1, pts: .zero), to: harness)
        submit(
            try normalized(id: 2, pts: CMTime(value: 1, timescale: 25)),
            order: top,
            discontinuity: true,
            to: harness
        )
        assertCancelled(
            harness.results.singleResult(for: 1),
            reason: .referenceWindowDiscard
        )

        submit(
            try normalized(id: 3, pts: CMTime(value: 2, timescale: 25)),
            order: bottom,
            to: harness
        )
        assertCancelled(
            harness.results.singleResult(for: 2),
            reason: .referenceWindowDiscard
        )

        submit(
            try normalized(id: 4, pts: CMTime(value: 3, timescale: 25)),
            order: bottom,
            to: harness
        )
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [3])

        submit(
            try normalized(id: 5, pts: CMTime(value: 100, timescale: 25)),
            order: bottom,
            to: harness
        )
        assertCancelled(
            harness.results.singleResult(for: 4),
            reason: .referenceWindowDiscard
        )

        let staleGeneration = MediaGeneration(rawValue: generation.rawValue - 1)
        submit(try normalized(id: 6, generation: staleGeneration), to: harness)
        assertCancelled(harness.results.singleResult(for: 6), reason: .staleGeneration)
        XCTAssertEqual(harness.processor.metricsSnapshot.staleGenerationDropCount, 1)
        for id in [1, 2, 4, 6] {
            XCTAssertEqual(harness.results.results(for: UInt64(id)).count, 1)
        }
        XCTAssertEqual(harness.queue.committedCount, 1)
    }

    func testSystemSubmitterCommitsRealMetalWorkAndCompletesWithoutWaiting() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        var cache: CVMetalTextureCache?
        XCTAssertEqual(
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache),
            kCVReturnSuccess
        )
        let submitter = try YADIFSystemCommandSubmitter(
            device: device,
            commandQueue: commandQueue,
            textureCache: try XCTUnwrap(cache)
        )
        let current = try normalized(id: 2)
        let outputs = try ProgressiveSurfacePool().allocatePair(
            matching: current.frame.pixelBuffer
        )
        let completed = expectation(description: "real YADIF command completed")
        let result = YADIFCommandResultRecorder()

        try submitter.submit(
            job: YADIFJob(
                previous: try normalized(id: 1),
                current: current,
                next: try normalized(id: 3),
                order: top,
                spatialOnly: false
            ),
            outputs: outputs
        ) {
            result.record($0)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
        let completion = try XCTUnwrap(result.snapshot.first)
        guard case let .completedWithGPUInterval(interval) = completion.result else {
            return XCTFail("expected completed Metal GPU interval")
        }
        XCTAssertNotNil(CVPixelBufferGetIOSurface(outputs.first))
        XCTAssertNotNil(CVPixelBufferGetIOSurface(outputs.second))
        XCTAssertGreaterThanOrEqual(interval.gpuStartTime, 0)
        XCTAssertGreaterThanOrEqual(interval.gpuEndTime, interval.gpuStartTime)
    }

    func testMetricsUseCompletedCommandBufferGPUIntervalInsteadOfWallClock() throws {
        let queue = FakeMetalCommandQueue()
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { 120 },
            residentMemoryProvider: { 1 }
        )
        let processor = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            clock: TestYADIFClock(),
            metrics: metrics
        )
        processor.reset(to: generation)
        let harness = YADIFProcessorHarness(
            processor: processor,
            queue: queue,
            clock: TestYADIFClock(),
            results: YADIFProcessorResultRecorder(),
            drops: YADIFDropRecorder()
        )
        for id in 1...3 {
            submit(try normalized(id: UInt64(id)), to: harness)
        }

        queue.completeNext(.completedWithGPUInterval(.init(
            gpuStartTime: 40,
            gpuEndTime: 40.004
        )))

        XCTAssertEqual(
            metrics.snapshot(window: .seconds(60)).gpuDurationP95Milliseconds,
            4,
            accuracy: 0.000_001
        )
    }

    private func makeHarness(
        clock: TestYADIFClock = TestYADIFClock(),
        maximumInFlight: Int = 3,
        maximumPendingFrames: Int = 4
    ) throws -> YADIFProcessorHarness {
        let queue = FakeMetalCommandQueue()
        let results = YADIFProcessorResultRecorder()
        let drops = YADIFDropRecorder()
        let processor = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            clock: clock,
            maximumInFlight: maximumInFlight,
            maximumPendingFrames: maximumPendingFrames,
            dropSink: { drops.record($0) }
        )
        processor.reset(to: generation)
        return YADIFProcessorHarness(
            processor: processor,
            queue: queue,
            clock: clock,
            results: results,
            drops: drops
        )
    }

    private func submit(
        _ frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder? = nil,
        discontinuity: Bool = false,
        to harness: YADIFProcessorHarness
    ) {
        harness.processor.submit(
            normalized: frame,
            order: order ?? top,
            discontinuity: discontinuity
        ) { harness.results.record(id: frame.frame.accessUnitID, result: $0) }
    }

    private func normalized(
        id: UInt64,
        generation: MediaGeneration? = nil,
        pts: CMTime? = nil
    ) throws -> NormalizedDecodedFrame {
        let duration = CMTime(value: 1, timescale: 25)
        let timestamp = pts ?? CMTime(value: Int64(id - 1), timescale: 25)
        let frame = try decoded(
            id: id,
            pts: timestamp,
            duration: duration,
            generation: generation
        )
        return NormalizedDecodedFrame(
            frame: frame,
            presentationTimeStamp: timestamp,
            frameDuration: duration,
            fieldDuration: CMTime(value: 1, timescale: 50),
            timingWasSynthesized: false,
            provenance: .trustedPresentationCadence
        )
    }

    private func decoded(
        id: UInt64,
        pts: CMTime? = nil,
        duration: CMTime = CMTime(value: 1, timescale: 25),
        generation: MediaGeneration? = nil,
        codedOrder: CodedFieldOrder = .tt,
        topFieldFirst: Bool? = true
    ) throws -> DecodedVideoFrame {
        let pixelBuffer = try makePixelBuffer()
        return DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: pts ?? CMTime(value: Int64(id - 1), timescale: 25),
            duration: duration,
            generation: generation ?? self.generation,
            parserMetadata: VideoParserMetadata(
                fieldOrder: codedOrder,
                pictureStructure: .frame,
                isInterlaced: true,
                repeatFirstField: false,
                topFieldFirst: topFieldFirst,
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
        )
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
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
        return try XCTUnwrap(pixelBuffer)
    }

    private func producedFrames(
        _ result: VideoProcessingResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [VideoPresentationFrame] {
        guard case let .produced(batch) = result else {
            XCTFail("expected a produced frame batch, got \(result)", file: file, line: line)
            throw PlaybackFailure(
                code: "unexpected-processing-result",
                userMessage: "expected produced frames"
            )
        }
        return batch.frames
    }

    private func assertCancelled(
        _ result: VideoProcessingResult,
        reason: VideoProcessingCancellationReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .cancelled(actual) = result else {
            return XCTFail("expected cancellation, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }

    private func assertTransientDrop(
        _ result: VideoProcessingResult,
        reason: VideoProcessingTransientDropReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .transientDrop(actual) = result else {
            return XCTFail("expected transient drop, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }

    private func assertStructuralFailure(
        _ result: VideoProcessingResult,
        failure: VideoProcessingStructuralFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .structuralFailure(actual) = result else {
            return XCTFail("expected structural failure, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(actual, failure, file: file, line: line)
    }

    private func pixelBuffer(from frame: VideoPresentationFrame) throws -> CVPixelBuffer {
        frame.pixelBuffer
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}

private struct YADIFProcessorHarness: @unchecked Sendable {
    let processor: YADIFProcessor
    let queue: FakeMetalCommandQueue
    let clock: TestYADIFClock
    let results: YADIFProcessorResultRecorder
    let drops: YADIFDropRecorder
}

private final class TestYADIFClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTime = CMTime.zero

    var currentTime: CMTime { lock.withLock { storedTime } }
    func pause() {}
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        set(mediaTime)
    }
    func set(_ time: CMTime) { lock.withLock { storedTime = time } }
}

private final class YADIFProcessorResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt64: [VideoProcessingResult]] = [:]

    func record(
        id: UInt64,
        result: VideoProcessingResult
    ) {
        lock.withLock { stored[id, default: []].append(result) }
    }

    func results(
        for id: UInt64
    ) -> [VideoProcessingResult] {
        lock.withLock { stored[id] ?? [] }
    }

    func singleResult(
        for id: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> VideoProcessingResult {
        let values = results(for: id)
        XCTAssertEqual(values.count, 1, file: file, line: line)
        return values.first ?? .cancelled(.reset)
    }
}

private final class YADIFDrainBarrierRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UInt64: Int] = [:]

    func record(id: UInt64) {
        lock.withLock { counts[id, default: 0] += 1 }
    }

    func count(for id: UInt64) -> Int {
        lock.withLock { counts[id, default: 0] }
    }
}

private final class YADIFLifecycleEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var snapshot: [String] { lock.withLock { events } }
    func record(_ event: String) { lock.withLock { events.append(event) } }
}

private final class YADIFDropRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [YADIFDropEvent] = []
    var snapshot: [YADIFDropEvent] { lock.withLock { events } }
    func record(_ event: YADIFDropEvent) { lock.withLock { events.append(event) } }
}

private final class YADIFCommandResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [YADIFCommandCompletion] = []
    var snapshot: [YADIFCommandCompletion] { lock.withLock { results } }
    func record(_ result: YADIFCommandCompletion) { lock.withLock { results.append(result) } }
}

private final class ImmediateYADIFCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSubmitCount = 0
    var submitCount: Int { lock.withLock { storedSubmitCount } }

    func submit(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion: @escaping @Sendable (YADIFCommandCompletion) -> Void
    ) throws(YADIFFailure) {
        lock.withLock { storedSubmitCount += 1 }
        completion(YADIFCommandCompletion(result: .completed))
    }
}

private final class BlockingYADIFCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let completion: @Sendable (YADIFCommandCompletion) -> Void
    }

    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var pending: [Pending] = []

    func submit(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion: @escaping @Sendable (YADIFCommandCompletion) -> Void
    ) throws(YADIFFailure) {
        lock.withLock { pending.append(Pending(completion: completion)) }
        entered.signal()
        release.wait()
    }

    func waitUntilBlocked() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func unblock() { release.signal() }

    func completeNext(_ result: YADIFCommandResult) {
        let completion = lock.withLock {
            pending.isEmpty ? nil : pending.removeFirst().completion
        }
        completion?(YADIFCommandCompletion(result: result))
    }
}

private final class BlockingYADIFOutputAllocator: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let pool = ProgressiveSurfacePool()

    func allocate(
        matching source: CVPixelBuffer
    ) throws(YADIFFailure) -> (first: CVPixelBuffer, second: CVPixelBuffer) {
        entered.signal()
        release.wait()
        return try pool.allocatePair(matching: source)
    }

    func waitUntilBlocked() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func unblock() { release.signal() }
}
