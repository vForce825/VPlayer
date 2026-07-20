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

    func testDecodedCompatibilityRejectsInvalidTimingWithOneStableFailureAndNoGPUWork() throws {
        let invalidFrames = try [
            decoded(id: 1, pts: .invalid),
            decoded(id: 2, pts: .indefinite),
            decoded(id: 3, duration: .zero),
            decoded(id: 4, duration: CMTime(value: -1, timescale: 25)),
            decoded(id: 5, duration: .indefinite),
        ]
        var failures: [PlaybackFailure] = []

        for frame in invalidFrames {
            let harness = try makeHarness()
            harness.processor.submit(frame) { harness.results.record(id: frame.accessUnitID, result: $0) }
            let result = try XCTUnwrap(harness.results.results(for: frame.accessUnitID).first)
            guard case let .failure(failure) = result else {
                return XCTFail("invalid timing must fail")
            }
            failures.append(failure)
            XCTAssertEqual(harness.queue.committedCount, 0)
            XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 0)
        }

        XCTAssertEqual(Set(failures.map(\.code)).count, 1)
        XCTAssertEqual(Set(failures.map(\.userMessage)).count, 1)
        XCTAssertFalse(failures[0].code.isEmpty)
        XCTAssertFalse(failures[0].userMessage.isEmpty)
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

        let sourceTwo = try success(harness.results.singleResult(for: 2))
        let sourceOne = try success(harness.results.singleResult(for: 1))
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
        XCTAssertTrue(try success(harness.results.singleResult(for: 4)).isEmpty)
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
            XCTAssertEqual(try? success(results.singleResult(for: id)).count, 0)
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

        XCTAssertTrue(try success(harness.results.singleResult(for: 2)).isEmpty)
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

        XCTAssertTrue(try success(harness.results.singleResult(for: 1)).isEmpty)
        XCTAssertEqual(harness.results.results(for: 1).count, 1)
        XCTAssertNil(retainedToken)

        submit(try normalized(id: 3, generation: nextGeneration), to: harness)
        submit(try normalized(id: 4, generation: nextGeneration), to: harness)
        let newIdentifier = try XCTUnwrap(harness.queue.submissionIdentifiers.last)
        harness.queue.complete(identifier: newIdentifier, result: .completed)
        XCTAssertEqual(
            try success(harness.results.singleResult(for: 3)).map(\.sequenceNumber),
            [1, 2]
        )
    }

    func testSameGenerationResetMakesInflightWorkStaleAndRestartsSequenceAndMetrics() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        submit(try normalized(id: 1), to: harness)
        submit(try normalized(id: 2), to: harness)
        let staleIdentifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)

        harness.processor.reset(to: generation)

        XCTAssertTrue(try success(harness.results.singleResult(for: 2)).isEmpty)
        XCTAssertTrue(harness.results.results(for: 1).isEmpty)
        XCTAssertEqual(harness.processor.metricsSnapshot.submittedJobCount, 0)
        submit(try normalized(id: 3), to: harness)
        submit(try normalized(id: 4), to: harness)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1])

        harness.queue.complete(identifier: staleIdentifier, result: .completed)

        XCTAssertTrue(try success(harness.results.singleResult(for: 1)).isEmpty)
        XCTAssertEqual(harness.results.results(for: 1).count, 1)
        XCTAssertEqual(harness.processor.metricsSnapshot.completedJobCount, 0)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1, 3])
        let currentIdentifier = try XCTUnwrap(harness.queue.submissionIdentifiers.last)
        harness.queue.complete(identifier: currentIdentifier, result: .completed)
        XCTAssertEqual(
            try success(harness.results.singleResult(for: 3)).map(\.sequenceNumber),
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

        XCTAssertEqual(try success(results.singleResult(for: 1)).count, 2)
        XCTAssertNil(retainedProcessor)
    }

    func testSynchronousSubmissionFailuresRollbackSlotCloseOnceAndContinueScheduling() throws {
        for (failure, expectedCode) in [
            (YADIFFailure.commandBufferAllocationFailed, "metal.command"),
            (.metalTextureMappingFailed(plane: 0, status: -61), "video.texture"),
            (.commandEncoderAllocationFailed, "video.texture"),
        ] {
            let harness = try makeHarness(maximumInFlight: 1)
            harness.queue.failNextSubmission(with: failure)
            submit(try normalized(id: 1), to: harness)
            submit(try normalized(id: 2), to: harness)

            let failed = harness.results.singleResult(for: 1)
            guard case let .failure(playbackFailure) = failed else {
                return XCTFail("synchronous submission failure must fail the current input")
            }
            XCTAssertEqual(playbackFailure.code, expectedCode)
            XCTAssertEqual(harness.results.results(for: 1).count, 1)
            XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 0)

            submit(try normalized(id: 3), to: harness)
            XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [2])
            XCTAssertEqual(harness.processor.metricsSnapshot.inFlightCount, 1)
        }
    }

    func testTerminalCommandFailureReturnsStableFailureAndReleasesSlot() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        submit(try normalized(id: 1), to: harness)
        submit(try normalized(id: 2), to: harness)
        let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)

        harness.queue.complete(identifier: identifier, result: .failed)

        guard case let .failure(failure) = harness.results.singleResult(for: 1) else {
            return XCTFail("terminal command failure must not be a blank success")
        }
        XCTAssertEqual(failure.code, "metal.command")
        XCTAssertFalse(failure.userMessage.isEmpty)
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

        let outputs = try success(results.singleResult(for: 1))
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
        submit(try normalized(id: 1), to: harness)
        harness.processor.drain { harness.results.record(id: 100, result: $0) }

        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1])
        XCTAssertTrue(harness.results.results(for: 1).isEmpty)
        XCTAssertTrue(harness.results.results(for: 100).isEmpty)

        submit(try normalized(id: 2), to: harness)
        XCTAssertTrue(try success(harness.results.singleResult(for: 2)).isEmpty)
        let identifier = try XCTUnwrap(harness.queue.submissionIdentifiers.first)
        harness.queue.complete(identifier: identifier, result: .completed)

        let tail = try success(harness.results.singleResult(for: 1))
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(tail.map(\.sourceAccessUnitID), [1, 1])
        XCTAssertTrue(try success(harness.results.singleResult(for: 100)).isEmpty)
        XCTAssertEqual(harness.results.results(for: 100).count, 1)

        harness.processor.drain { harness.results.record(id: 101, result: $0) }
        XCTAssertTrue(try success(harness.results.singleResult(for: 101)).isEmpty)

        let nextGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        harness.processor.reset(to: nextGeneration)
        submit(try normalized(id: 3, generation: nextGeneration), to: harness)
        XCTAssertTrue(harness.results.results(for: 3).isEmpty)
    }

    func testDuplicateNormalizedInstanceOwnsBothCompletionsExactlyOnceThroughDrain() throws {
        let harness = try makeHarness(maximumInFlight: 1)
        let frame = try normalized(id: 1)
        harness.processor.submit(normalized: frame, order: top) {
            harness.results.record(id: 101, result: $0)
        }
        harness.processor.submit(normalized: frame, order: top) {
            harness.results.record(id: 102, result: $0)
        }

        let firstResultBeforeDrain = harness.results.results(for: 101).first
        let secondResultCountBeforeDrain = harness.results.results(for: 102).count
        harness.processor.drain { harness.results.record(id: 103, result: $0) }
        harness.queue.completeNext(.completed)

        XCTAssertEqual(try? firstResultBeforeDrain?.get().count, 0)
        XCTAssertEqual(secondResultCountBeforeDrain, 0)
        XCTAssertEqual(harness.queue.submittedSourceAccessUnitIDs, [1])
        XCTAssertEqual(try? success(harness.results.singleResult(for: 102)).count, 2)
        XCTAssertEqual(try? success(harness.results.singleResult(for: 103)).count, 0)
        for id in UInt64(101)...103 {
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

        XCTAssertEqual(try? success(harness.results.singleResult(for: 101)).count, 0)
        XCTAssertEqual(try? success(harness.results.singleResult(for: 102)).count, 0)
        XCTAssertEqual(harness.results.results(for: 101).count, 1)
        XCTAssertEqual(harness.results.results(for: 102).count, 1)
        XCTAssertEqual(harness.queue.committedCount, 0)
    }

    func testSameInputKeyIncreasingTimestampsPopCompletionsInSubmissionOrder() throws {
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
        processor.drain { results.record(id: 103, result: $0) }

        XCTAssertEqual(
            try? success(results.singleResult(for: 101)).first?.presentationTimeStamp,
            first.presentationTimeStamp
        )
        XCTAssertEqual(
            try? success(results.singleResult(for: 102)).first?.presentationTimeStamp,
            laterTimestamp
        )
        XCTAssertEqual(try? success(results.singleResult(for: 103)).count, 0)
        for id in UInt64(101)...103 {
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

        XCTAssertEqual(try? success(harness.results.singleResult(for: 101)).count, 0)
        XCTAssertEqual(try? success(harness.results.singleResult(for: 102)).count, 0)
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

        XCTAssertTrue(try success(results.singleResult(for: 1)).isEmpty)
        XCTAssertTrue(try success(results.singleResult(for: 2)).isEmpty)
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
            processor.drain { results.record(id: 100, result: $0) }
            drainReturned.fulfill()
        }
        XCTAssertTrue(allocator.waitUntilBlocked())
        XCTAssertTrue(results.results(for: 1).isEmpty)
        XCTAssertTrue(results.results(for: 100).isEmpty)

        allocator.unblock()
        wait(for: [drainReturned], timeout: 5)
        XCTAssertEqual(queue.committedCount, 1)
        XCTAssertTrue(results.results(for: 100).isEmpty)

        queue.completeNext(.completed)
        XCTAssertEqual(try success(results.singleResult(for: 1)).count, 2)
        XCTAssertTrue(try success(results.singleResult(for: 100)).isEmpty)
        XCTAssertEqual(results.results(for: 100).count, 1)
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
        XCTAssertTrue(try success(harness.results.singleResult(for: 1)).isEmpty)

        submit(
            try normalized(id: 3, pts: CMTime(value: 2, timescale: 25)),
            order: bottom,
            to: harness
        )
        XCTAssertTrue(try success(harness.results.singleResult(for: 2)).isEmpty)

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
        XCTAssertTrue(try success(harness.results.singleResult(for: 4)).isEmpty)

        let staleGeneration = MediaGeneration(rawValue: generation.rawValue - 1)
        submit(try normalized(id: 6, generation: staleGeneration), to: harness)
        XCTAssertTrue(try success(harness.results.singleResult(for: 6)).isEmpty)
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
        XCTAssertEqual(result.snapshot, [.completed])
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

    private func success(
        _ result: Result<[VideoPresentationFrame], PlaybackFailure>
    ) throws -> [VideoPresentationFrame] {
        try result.get()
    }

    private func pixelBuffer(from frame: VideoPresentationFrame) throws -> CVPixelBuffer {
        guard case let .pixelBuffer(pixelBuffer) = frame.storage else {
            throw PlaybackFailure(
                code: "unexpected-storage",
                userMessage: "Expected a pixel-buffer YADIF output"
            )
        }
        return pixelBuffer
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
    func mediaTime(forHostTime hostTime: CMTime) -> CMTime { hostTime }
    func pause() {}
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        set(mediaTime)
    }
    func set(_ time: CMTime) { lock.withLock { storedTime = time } }
}

private final class YADIFProcessorResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt64: [Result<[VideoPresentationFrame], PlaybackFailure>]] = [:]

    func record(
        id: UInt64,
        result: Result<[VideoPresentationFrame], PlaybackFailure>
    ) {
        lock.withLock { stored[id, default: []].append(result) }
    }

    func results(
        for id: UInt64
    ) -> [Result<[VideoPresentationFrame], PlaybackFailure>] {
        lock.withLock { stored[id] ?? [] }
    }

    func singleResult(
        for id: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<[VideoPresentationFrame], PlaybackFailure> {
        let values = results(for: id)
        XCTAssertEqual(values.count, 1, file: file, line: line)
        return values.first ?? .failure(PlaybackFailure(
            code: "missing-test-result",
            userMessage: "The expected processor callback did not fire"
        ))
    }
}

private final class YADIFDropRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [YADIFDropEvent] = []
    var snapshot: [YADIFDropEvent] { lock.withLock { events } }
    func record(_ event: YADIFDropEvent) { lock.withLock { events.append(event) } }
}

private final class YADIFCommandResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [YADIFCommandResult] = []
    var snapshot: [YADIFCommandResult] { lock.withLock { results } }
    func record(_ result: YADIFCommandResult) { lock.withLock { results.append(result) } }
}

private final class ImmediateYADIFCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSubmitCount = 0
    var submitCount: Int { lock.withLock { storedSubmitCount } }

    func submit(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion: @escaping @Sendable (YADIFCommandResult) -> Void
    ) throws(YADIFFailure) {
        lock.withLock { storedSubmitCount += 1 }
        completion(.completed)
    }
}

private final class BlockingYADIFCommandSubmitter: YADIFCommandSubmitting, @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let completion: @Sendable (YADIFCommandResult) -> Void
    }

    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var pending: [Pending] = []

    func submit(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion: @escaping @Sendable (YADIFCommandResult) -> Void
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
        completion?(result)
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
