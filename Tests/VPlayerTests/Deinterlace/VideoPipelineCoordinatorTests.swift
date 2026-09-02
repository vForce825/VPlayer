// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class VideoPipelineCoordinatorTests: XCTestCase {
    func testVideoRecoveryBudgetSharesFourTotalRecoveriesAndTwoStructuralRecoveries() {
        var budget = VideoRecoveryBudget(
            maximumRecoveriesPerMediaEpoch: 4,
            maximumStructuralRecoveriesPerMediaEpoch: 2
        )

        XCTAssertEqual(budget.requestRecovery(for: .stall), .recover(.stall))
        budget.beginDecoderAttempt()
        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .recover(.processingStructural)
        )
        budget.beginDecoderAttempt()
        XCTAssertEqual(
            budget.requestRecovery(for: .sessionFailure),
            .recover(.sessionFailure)
        )
        budget.beginDecoderAttempt()
        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .recover(.processingStructural)
        )
        budget.beginDecoderAttempt()

        XCTAssertEqual(
            budget.requestRecovery(for: .noFrame),
            .exhausted(.noFrame)
        )
        XCTAssertEqual(budget.recoveriesConsumed, 4)
        XCTAssertEqual(budget.structuralRecoveriesConsumed, 2)
    }

    func testVideoRecoveryBudgetStructuralBucketExhaustsBeforeSharedTotal() {
        var budget = VideoRecoveryBudget(
            maximumRecoveriesPerMediaEpoch: 4,
            maximumStructuralRecoveriesPerMediaEpoch: 2
        )

        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .recover(.processingStructural)
        )
        budget.beginDecoderAttempt()
        XCTAssertEqual(budget.observe(.produced), .none)
        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .recover(.processingStructural)
        )
        budget.beginDecoderAttempt()
        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .exhausted(.processingStructural)
        )
        XCTAssertEqual(budget.recoveriesConsumed, 2)
        XCTAssertEqual(budget.structuralRecoveriesConsumed, 2)
    }

    func testVideoRecoveryBudgetDoesNotDoubleChargeAnInflightStructuralRecovery() {
        var budget = VideoRecoveryBudget(
            maximumRecoveriesPerMediaEpoch: 4,
            maximumStructuralRecoveriesPerMediaEpoch: 2
        )

        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .recover(.processingStructural)
        )
        for _ in 0..<8 {
            XCTAssertEqual(
                budget.requestRecovery(for: .processingStructural),
                .none
            )
        }
        XCTAssertEqual(budget.recoveriesConsumed, 1)
        XCTAssertEqual(budget.structuralRecoveriesConsumed, 1)
    }

    func testVideoRecoveryBudgetTriggersOneRecoveryPerDecoderAttemptAtTwelveNoFrames() {
        var budget = VideoRecoveryBudget(maximumRecoveriesPerMediaEpoch: 3)

        for _ in 0..<11 {
            XCTAssertEqual(budget.observe(.noFrame), .none)
        }
        XCTAssertEqual(budget.observe(.noFrame), .recover(.noFrame))

        // One decoder attempt is one incident. Late completions from that
        // attempt cannot consume another recovery while its transition is in
        // flight.
        for _ in 0..<24 {
            XCTAssertEqual(budget.observe(.noFrame), .none)
        }
        XCTAssertEqual(budget.observe(.cancelled), .none)
        XCTAssertEqual(budget.recoveriesConsumed, 1)

        budget.beginDecoderAttempt()
        for _ in 0..<11 {
            XCTAssertEqual(budget.observe(.noFrame), .none)
        }
        XCTAssertEqual(budget.observe(.noFrame), .recover(.noFrame))
        XCTAssertEqual(budget.recoveriesConsumed, 2)

        // A real output also resets a partial streak within the current
        // decoder attempt, but never replenishes the media-epoch total.
        budget.beginDecoderAttempt()
        for _ in 0..<8 {
            XCTAssertEqual(budget.observe(.noFrame), .none)
        }
        XCTAssertEqual(budget.observe(.produced), .none)
        for _ in 0..<11 {
            XCTAssertEqual(budget.observe(.noFrame), .none)
        }
        XCTAssertEqual(budget.observe(.noFrame), .recover(.noFrame))
        XCTAssertEqual(budget.recoveriesConsumed, 3)
    }

    func testVideoRecoveryBudgetIsSharedAcrossNoFrameStallAndSessionFailurePerMediaEpoch() {
        var budget = VideoRecoveryBudget(maximumRecoveriesPerMediaEpoch: 3)

        XCTAssertEqual(budget.requestRecovery(for: .stall), .recover(.stall))
        budget.beginDecoderAttempt()
        XCTAssertEqual(budget.observe(.produced), .none)
        XCTAssertEqual(
            budget.requestRecovery(for: .sessionFailure),
            .recover(.sessionFailure)
        )
        budget.beginDecoderAttempt()
        for _ in 0..<11 {
            XCTAssertEqual(budget.observe(.noFrame), .none)
        }
        XCTAssertEqual(budget.observe(.noFrame), .recover(.noFrame))
        XCTAssertEqual(budget.recoveriesConsumed, 3)

        budget.beginDecoderAttempt()
        XCTAssertEqual(
            budget.requestRecovery(for: .stall),
            .exhausted(.stall)
        )
        XCTAssertEqual(budget.observe(.produced), .none)
        XCTAssertEqual(budget.recoveriesConsumed, 3)

        budget.beginMediaEpoch()
        XCTAssertEqual(budget.recoveriesConsumed, 0)
        XCTAssertEqual(budget.structuralRecoveriesConsumed, 0)
        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .recover(.processingStructural)
        )
        budget.beginDecoderAttempt()
        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .recover(.processingStructural)
        )
        XCTAssertEqual(budget.structuralRecoveriesConsumed, 2)
        budget.beginDecoderAttempt()
        XCTAssertEqual(
            budget.requestRecovery(for: .processingStructural),
            .exhausted(.processingStructural)
        )

        budget.beginMediaEpoch()
        XCTAssertEqual(
            budget.requestRecovery(for: .sessionFailure),
            .recover(.sessionFailure)
        )
    }

    func testRouteTableIsCompleteAndNeverDeinterlacesProgressiveOrPsF() {
        let top = ResolvedFieldOrder(
            parity: .top,
            confidence: .signaled,
            source: .parser
        )

        XCTAssertEqual(DeinterlaceRoute.resolve(scan: .unknown), .rawWhileClassifying)
        XCTAssertEqual(DeinterlaceRoute.resolve(scan: .progressive), .bypass)
        XCTAssertEqual(
            DeinterlaceRoute.resolve(scan: .progressiveSegmentedFrame(top)),
            .bypass
        )
        XCTAssertEqual(
            DeinterlaceRoute.resolve(scan: .interlaced(top)),
            .metalYADIF2x
        )
    }

    func testInitialFormatWaitsForIDRAndUnknownRawPresentationDoesNotWaitForProbe() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: false
        ))
        XCTAssertFalse(harness.decoder.snapshot().contains { operation in
            if case .decode = operation { return true }
            return false
        })

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        let startupOperations = harness.decoder.snapshot().suffix(2)
        XCTAssertTrue(startupOperations.contains { operation in
            guard case let .transitionConfigure(_, configuredGeneration) = operation else {
                return false
            }
            return configuredGeneration == generation
        })
        XCTAssertTrue(startupOperations.contains(
            .decode(2, generation, ._EnableAsynchronousDecompression)
        ))

        for id in 10...12 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        XCTAssertFalse(harness.coordinator.isClassificationResolved)
        XCTAssertEqual(harness.coordinator.requiredVideoFrameCount, 1)
        XCTAssertEqual(harness.probe.pendingCount, 1)
        XCTAssertEqual(harness.host.deliveredFrames.count, 1)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testConfigureTransitionRetainsTriggeringRandomAccessUntilMatchingCompletion() throws {
        let harness = makeHarness(automaticallyCompletesTransitions: false)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        let initialInvalidation = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionInvalidate(token) = operation else { return nil }
            return token
        }.last)
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: initialInvalidation,
            outcome: .completed
        ))
        let baselineCloseCount = harness.host.operations.filter { $0 == "close" }.count
        let baselineOpenCount = harness.host.operations.filter { $0 == "open" }.count

        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 41,
            generation: generation,
            randomAccess: true
        )))

        let token = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionConfigure(token, configuredGeneration) = operation,
                  configuredGeneration == generation else { return nil }
            return token
        }.last)
        XCTAssertFalse(harness.decoder.snapshot().contains { operation in
            guard case let .decode(id, _, _) = operation else { return false }
            return id == 41
        })
        XCTAssertEqual(
            harness.host.operations.filter { $0 == "close" }.count,
            baselineCloseCount + 1
        )

        harness.coordinator.handle(decoder: .transitionCompleted(
            token: VideoDecoderTransitionToken(),
            outcome: .completed
        ))
        XCTAssertFalse(harness.decoder.snapshot().contains { operation in
            guard case let .decode(id, _, _) = operation else { return false }
            return id == 41
        })
        XCTAssertEqual(
            harness.host.operations.filter { $0 == "open" }.count,
            baselineOpenCount
        )

        harness.coordinator.handle(decoder: .transitionCompleted(
            token: token,
            outcome: .completed
        ))
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: token,
            outcome: .completed
        ))

        XCTAssertEqual(harness.decoder.snapshot().filter { operation in
            guard case let .decode(id, decodedGeneration, _) = operation else {
                return false
            }
            return id == 41 && decodedGeneration == generation
        }.count, 1)
        XCTAssertEqual(
            harness.host.operations.filter { $0 == "open" }.count,
            baselineOpenCount + 1
        )
    }

    func testWithheldConfigureTransitionTimesOutOnceRejectsRetainedRandomAccessAndFencesLateCompletion() throws {
        let scheduler = ManualCoordinatorTransitionDeadlineScheduler()
        let harness = makeHarness(
            automaticallyCompletesTransitions: false,
            transitionDeadlineScheduler: scheduler.schedule
        )
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        let invalidationToken = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionInvalidate(token) = operation else { return nil }
            return token
        }.last)
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: invalidationToken,
            outcome: .completed
        ))
        XCTAssertTrue(scheduler.fireNext(), "cancelled invalidation deadline remains a fenced ticket")
        XCTAssertTrue(harness.host.failures.isEmpty)

        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 42,
            generation: generation,
            randomAccess: true
        )))
        let configureToken = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionConfigure(token, configuredGeneration) = operation,
                  configuredGeneration == generation else { return nil }
            return token
        }.last)
        let openCount = harness.host.operations.filter { $0 == "open" }.count

        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(harness.host.failures.map(\.0), [.videoDecoderTransitionTimeout])
        XCTAssertEqual(harness.host.failures.map(\.1), [generation])
        XCTAssertEqual(harness.host.submissionRejections.map(\.0), [42])
        XCTAssertFalse(harness.coordinator.isDecoderTransitionPending)

        harness.coordinator.handle(decoder: .transitionCompleted(
            token: configureToken,
            outcome: .completed
        ))
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: configureToken,
            outcome: .completed
        ))
        XCTAssertEqual(harness.host.failures.count, 1)
        XCTAssertEqual(harness.host.submissionRejections.count, 1)
        XCTAssertEqual(harness.host.operations.filter { $0 == "open" }.count, openCount)
    }

    func testWithheldInvalidationTimesOutOnceAndStopCancelsItsDeadline() throws {
        let scheduler = ManualCoordinatorTransitionDeadlineScheduler()
        let harness = makeHarness(
            automaticallyCompletesTransitions: false,
            transitionDeadlineScheduler: scheduler.schedule
        )
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let token = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionInvalidate(token) = operation else { return nil }
            return token
        }.last)

        XCTAssertTrue(scheduler.fireNext())
        XCTAssertEqual(harness.host.failures.map(\.0), [.videoDecoderTransitionTimeout])
        XCTAssertFalse(harness.coordinator.isDecoderTransitionPending)
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: token,
            outcome: .completed
        ))
        XCTAssertEqual(harness.host.failures.count, 1)
        XCTAssertFalse(harness.host.operations.contains("open"))

        let stoppedScheduler = ManualCoordinatorTransitionDeadlineScheduler()
        let stopped = makeHarness(
            automaticallyCompletesTransitions: false,
            transitionDeadlineScheduler: stoppedScheduler.schedule
        )
        stopped.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        stopped.coordinator.stop(emergency: true)
        XCTAssertTrue(stoppedScheduler.fireNext())
        XCTAssertTrue(stopped.host.failures.isEmpty)
    }

    func testTrueFormatAndRecoveryInvalidationWaitForMatchingCompletionBeforeAdmission() throws {
        let harness = makeHarness(automaticallyCompletesTransitions: false)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let firstGeneration = harness.host.generation
        let firstInvalidation = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionInvalidate(token) = operation else { return nil }
            return token
        }.last)
        XCTAssertFalse(harness.host.operations.contains("open"))
        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 50,
            generation: firstGeneration,
            randomAccess: true
        )))

        harness.coordinator.handle(decoder: .transitionCompleted(
            token: VideoDecoderTransitionToken(),
            outcome: .completed
        ))
        XCTAssertFalse(harness.host.operations.contains("open"))
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: firstInvalidation,
            outcome: .completed
        ))
        XCTAssertEqual(harness.host.operations.filter { $0 == "open" }.count, 1)

        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 51,
            generation: firstGeneration,
            randomAccess: true
        )))
        let configurationToken = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionConfigure(token, generation) = operation,
                  generation == firstGeneration else { return nil }
            return token
        }.last)
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: configurationToken,
            outcome: .completed
        ))
        XCTAssertEqual(harness.decoder.snapshot().filter {
            guard case let .decode(id, _, _) = $0 else { return false }
            return id == 51
        }.count, 1)

        harness.decoder.decodeFailures = [.backpressureTimeout]
        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 52,
            generation: firstGeneration,
            randomAccess: false
        )))
        let recoveryGeneration = harness.host.generation
        XCTAssertGreaterThan(recoveryGeneration, firstGeneration)
        let recoveryInvalidation = try XCTUnwrap(harness.decoder.snapshot().compactMap {
            operation -> VideoDecoderTransitionToken? in
            guard case let .transitionInvalidate(token) = operation else { return nil }
            return token
        }.last)
        let opensBeforeRecoveryCompletion = harness.host.operations.filter { $0 == "open" }.count
        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 53,
            generation: recoveryGeneration,
            randomAccess: true
        )))
        harness.coordinator.handle(decoder: .transitionCompleted(
            token: recoveryInvalidation,
            outcome: .completed
        ))
        XCTAssertEqual(
            harness.host.operations.filter { $0 == "open" }.count,
            opensBeforeRecoveryCompletion + 1
        )
    }

    func testHandleReturnsTrueOnlyWhenAccessUnitReachesDecoder() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation

        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: false
        )))
        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: MediaGeneration(rawValue: generation.rawValue - 1),
            randomAccess: true
        )))
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: true
        )))

        harness.decoder.decodeFailures = [.badData(kVTVideoDecoderBadDataErr)]
        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 4,
            generation: generation,
            randomAccess: false
        )))
    }

    func testSubmissionCompletionDoesNotChangeCoordinatorState() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        let operations = harness.decoder.snapshot()
        let hostOperations = harness.host.operations

        harness.coordinator.handle(decoder: .submissionCompleted(
            accessUnitID: 9,
            generation: generation
        ))

        XCTAssertEqual(harness.decoder.snapshot(), operations)
        XCTAssertEqual(harness.host.operations, hostOperations)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testSupplementalProbeDoesNotDoubleCountProgressiveFrame() throws {
        let harness = makeHarness(classifierConfiguration: ScanClassifierConfiguration(
            progressiveConfirmationFrames: 3,
            psfConfirmationFrames: 3,
            exitInterlacedConfirmationFrames: 3
        ))
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
            id: 10,
            generation: generation,
            parser: progressiveParser(sourcePTS90k: 36_000)
        )))
        harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
            id: 11,
            generation: generation,
            parser: progressiveParser(sourcePTS90k: 39_600)
        )))
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        harness.probe.completeFirst(.success(ContentProbeSample(
            combRatio: 0,
            motionRatio: 0,
            sampleCount: 2_304
        )))
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)

        harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
            id: 12,
            generation: generation,
            parser: progressiveParser(sourcePTS90k: 43_200)
        )))
        XCTAssertEqual(harness.coordinator.route, .bypass)
        XCTAssertTrue(harness.coordinator.isClassificationResolved)
    }

    func testPsFProbeEvidenceBypassesBothDeinterlacers() throws {
        let harness = makeHarness(classifierConfiguration: ScanClassifierConfiguration(
            progressiveConfirmationFrames: 3,
            psfConfirmationFrames: 2,
            exitInterlacedConfirmationFrames: 3
        ))
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        for id in 10...12 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: fieldSignalledParser(sourcePTS90k: UInt64(id * 3_600))
            )))
            if id > 10 {
                harness.probe.completeFirst(.success(ContentProbeSample(
                    combRatio: 0.01,
                    motionRatio: 0.02,
                    sampleCount: 2_304
                )))
            }
        }

        XCTAssertEqual(harness.coordinator.route, .bypass)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testFailedProbeConservativelyRoutesFieldSignalledFramesToSelectedDeinterlacer() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        for id in 10...11 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: fieldSignalledParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        harness.probe.completeFirst(.failure(.nonIOSurfaceInput))

        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testThreeUnresolvedProbesConservativelyRouteFieldSignalledFrames() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        for id in 10...13 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: fieldSignalledParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        XCTAssertEqual(harness.probe.pendingCount, 1)
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testThreeInconclusiveProbeAttemptsReleaseUnknownSourceThroughBypass() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        for id in 10...13 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        XCTAssertEqual(harness.probe.pendingCount, 1)
        XCTAssertEqual(harness.coordinator.route, .bypass)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testNormalAndEmergencyStopOnlyEnqueueNonblockingDecoderTransitions() throws {
        let normal = makeHarness()
        normal.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let normalGeneration = normal.host.generation
        normal.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: normalGeneration,
            randomAccess: true
        ))
        normal.trace.removeAll()
        normal.coordinator.stop(emergency: false)
        normal.coordinator.stop(emergency: false)
        XCTAssertEqual(normal.trace.values, [
            "host.close",
            "decoder.transition.drainAndInvalidate",
        ])
        XCTAssertEqual(normal.host.generation, normalGeneration)

        let emergency = makeHarness()
        emergency.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let oldGeneration = emergency.host.generation
        emergency.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: oldGeneration,
            randomAccess: true
        ))
        emergency.trace.removeAll()
        emergency.coordinator.stop(emergency: true)
        let newGeneration = emergency.host.generation
        XCTAssertEqual(newGeneration.rawValue, oldGeneration.rawValue + 1)
        XCTAssertEqual(emergency.trace.values, [
            "host.close",
            "host.advance:\(newGeneration.rawValue)",
            "host.reset:\(newGeneration.rawValue):1",
            "decoder.transition.invalidate",
        ])
    }

    func testNormalStopDropsPendingProcessorAndProbeCompletions() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.passthrough.setAutomaticallyCompletes(false)
        for id in 10...12 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertEqual(harness.probe.pendingCount, 1)

        harness.coordinator.stop(emergency: false)
        harness.passthrough.completePending()
        harness.probe.completeFirst(.success(ContentProbeSample(
            combRatio: 0.2,
            motionRatio: 0.2,
            sampleCount: 2_304
        )))

        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testConfirmedBottomOrderReachesNormalizedYADIFAndSameGenerationStaleWorkDrops() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.passthrough.setAutomaticallyCompletes(false)

        for id in 10...12 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)

        for id in 13...16 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: interlacedParser(
                    parity: .bottom,
                    sourcePTS90k: UInt64(id * 3_600)
                )
            )))
        }
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertFalse(harness.yadif.submissions.isEmpty)
        XCTAssertTrue(harness.yadif.submissions.allSatisfy {
            $0.order.parity == .bottom
                && $0.order.confidence == .signaled
                && $0.order.source == .parser
        })

        harness.passthrough.completePending()
        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
        harness.probe.completeFirst(.success(ContentProbeSample(
            combRatio: 0,
            motionRatio: 0,
            sampleCount: 2_304
        )))
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testFormatLevelFieldOrderFeedsYADIFWhenPixelAttachmentsAreAbsent() throws {
        let harness = makeHarness()
        let format = try VideoTestFactories.formatDescription(
            fieldCount: number(2),
            detail: kCVImageBufferFieldDetailTemporalBottomFirst
        )
        harness.coordinator.replaceFormat(format)
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        for id in 10...14 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
            if id == 11 {
                harness.probe.completeFirst(.success(ContentProbeSample(
                    combRatio: 0.2,
                    motionRatio: 0.2,
                    sampleCount: 2_304
                )))
            }
        }

        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertFalse(harness.yadif.submissions.isEmpty)
        XCTAssertTrue(harness.yadif.submissions.allSatisfy {
            $0.order.parity == .bottom
                && $0.order.source == .formatDescription
        })
    }

    func testFatalDecoderFailureIsTerminal() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        harness.coordinator.handle(decoder: harness.fatalFailureEvent(
            .sessionCreate(-81),
            generation: generation
        ))

        XCTAssertEqual(harness.host.failures.map(\.0), [.videoDecode(-81)])
        XCTAssertEqual(harness.host.failures.map(\.1), [generation])
    }

    func testRecoverableDecoderFailureDropsOnlyThatFrame() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        harness.coordinator.handle(decoder: harness.recoverableFailureEvent(
            .badData(kVTVideoDecoderBadDataErr),
            generation: generation
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(2, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testRecoverableSynchronousDecodeFailureDropsOnlyThatAccessUnit() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [
            .badData(kVTVideoDecoderReferenceMissingErr),
        ]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(3, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testSessionMalfunctionRebuildsTheDecoderInsteadOfDroppingEveryFrame() throws {
        for status in [
            kVTVideoDecoderMalfunctionErr,
            kVTSessionMalfunctionErr,
            kVTVideoDecoderNotAvailableNowErr,
            kVTVideoDecoderRemovedErr,
        ] {
            let harness = makeHarness()
            harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
            let oldGeneration = harness.host.generation
            harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
                id: 1,
                generation: oldGeneration,
                randomAccess: true
            ))
            harness.decoder.decodeFailures = [.malfunction(status)]

            harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
                id: 2,
                generation: oldGeneration,
                randomAccess: false
            ))

            // A malfunctioning session fails every later submission the same way,
            // so counting this as one more dropped frame froze video for good
            // while access units kept arriving.
            XCTAssertGreaterThan(harness.host.generation, oldGeneration)
            XCTAssertTrue(harness.host.failures.isEmpty)
            XCTAssertTrue(harness.decoder.snapshot().last.map { operation in
                if case .transitionInvalidate = operation { return true }
                return false
            } ?? false)
        }
    }

    func testUnrecoverableSessionMalfunctionIsReportedRatherThanRestartedForever() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var identifier: UInt64 = 1
        for _ in 0...8 where harness.host.failures.isEmpty {
            harness.decoder.decodeFailures = [.malfunction(kVTVideoDecoderMalfunctionErr)]
            harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
                id: identifier,
                generation: harness.host.generation,
                randomAccess: true
            ))
            identifier += 1
        }

        // Restarting is bounded: a session that never comes back has to surface
        // as a real failure instead of silently discarding every frame.
        XCTAssertFalse(harness.host.failures.isEmpty)
    }

    func testDecodeBackpressureTimeoutRebuildsAtNextRandomAccessWithoutDrainingStalledSession() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let oldGeneration = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: oldGeneration,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [.backpressureTimeout]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: oldGeneration,
            randomAccess: false
        ))

        let newGeneration = harness.host.generation
        XCTAssertGreaterThan(newGeneration, oldGeneration)
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.operations.suffix(4), [
            "close",
            "advance:\(newGeneration.rawValue)",
            "reset:\(newGeneration.rawValue):1",
            "open",
        ])
        let recoveryOperations = harness.decoder.snapshot().suffix(2)
        XCTAssertTrue(recoveryOperations.contains(
            .decode(2, oldGeneration, ._EnableAsynchronousDecompression)
        ))
        XCTAssertTrue(recoveryOperations.contains { operation in
            if case .transitionInvalidate = operation { return true }
            return false
        })

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: newGeneration,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 4,
            generation: newGeneration,
            randomAccess: true
        ))

        let replacementOperations = harness.decoder.snapshot().suffix(2)
        XCTAssertTrue(replacementOperations.contains { operation in
            guard case let .transitionConfigure(_, configuredGeneration) = operation else {
                return false
            }
            return configuredGeneration == newGeneration
        })
        XCTAssertTrue(replacementOperations.contains(
            .decode(4, newGeneration, ._EnableAsynchronousDecompression)
        ))
    }

    func testLegacyCodecBadDataSynchronousFailureDropsOnlyThatAccessUnit() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [.badData(-8_969)]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(3, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testObservedPositiveStatusSynchronousFailureDropsOnlyThatAccessUnit() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [.badData(1)]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(3, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testLegacyCodecBadDataDrainFailureDoesNotBlockADiscontinuityReset() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
            id: 10,
            generation: generation,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        harness.decoder.nextDrainOutcome = .failed(.badData(-8_969))
        let oldGeneration = generation

        harness.coordinator.beginDiscontinuity()

        generation = harness.host.generation
        XCTAssertEqual(generation.rawValue, oldGeneration.rawValue + 1)
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testLateAsynchronousYADIFCompletionDropsAfterAGenerationSwitch() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let oldGeneration = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: oldGeneration,
            randomAccess: true
        ))
        for id in 10...14 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: oldGeneration,
                parser: interlacedParser(
                    parity: .top,
                    sourcePTS90k: UInt64(id * 3_600)
                )
            )))
        }
        XCTAssertGreaterThan(harness.yadif.pendingCompletionCount, 0)
        let staleCompletionCount = harness.yadif.pendingCompletionCount

        harness.coordinator.beginDiscontinuity()
        XCTAssertGreaterThan(harness.host.generation, oldGeneration)
        harness.yadif.completeAll()

        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(
            harness.metrics.snapshot(window: .seconds(60)).staleGenerationDropCount,
            UInt64(staleCompletionCount)
        )
    }

    func testProcessingAdmissionFloorRejectsWholeOldSuccessAndFailureBeforeEffects()
        throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        )))
        harness.passthrough.setAutomaticallyCompletes(false)
        for id in 10...13 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertTrue(harness.passthrough.pendingAccessUnitIDs.contains(10))
        XCTAssertTrue(harness.passthrough.pendingAccessUnitIDs.contains(11))

        harness.coordinator.installProcessingAdmissionFloor(
            generation: generation,
            minimumAccessUnitID: 20,
            minimumOutputPTS: CMTime(value: 20, timescale: 25)
        )
        let failureIndex = VideoDropSource.deinterlaceFailure.rawValue
        let failuresBefore = harness.metrics.snapshot(window: .seconds(60))
            .videoDropCountsBySource[failureIndex]
        harness.passthrough.completePending(
            accessUnitID: 10,
            with: .structuralFailure(.commandExecution)
        )
        harness.passthrough.completePending(accessUnitIDs: [11])

        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
        XCTAssertEqual(
            harness.metrics.snapshot(window: .seconds(60))
                .videoDropCountsBySource[failureIndex],
            failuresBefore
        )
    }

    func testProcessingAdmissionFloorFiltersMixedLegalCompletionFrameByFrame() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        )))
        harness.passthrough.setAutomaticallyCompletes(false)
        harness.coordinator.installProcessingAdmissionFloor(
            generation: generation,
            minimumAccessUnitID: 20,
            minimumOutputPTS: CMTime(value: 20, timescale: 25)
        )
        for id in 20...22 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertTrue(harness.passthrough.pendingAccessUnitIDs.contains(20))
        let source = try decodedFrame(
            id: 20,
            generation: generation,
            parser: unknownParser(sourcePTS90k: 72_000)
        )
        let mixed = [
            presentationFrame(
                from: source,
                sourceAccessUnitID: 19,
                presentationTimeStamp: CMTime(value: 21, timescale: 25)
            ),
            presentationFrame(
                from: source,
                sourceAccessUnitID: 20,
                presentationTimeStamp: CMTime(value: 20, timescale: 25)
            ),
            presentationFrame(
                from: source,
                sourceAccessUnitID: 21,
                presentationTimeStamp: CMTime(value: 19, timescale: 25)
            ),
            presentationFrame(
                from: source,
                sourceAccessUnitID: 22,
                presentationTimeStamp: CMTime(value: 22, timescale: 25),
                generation: MediaGeneration(rawValue: generation.rawValue + 1)
            ),
        ]
        harness.passthrough.completePending(
            accessUnitID: 20,
            with: .produced(VideoProcessingFrameBatch(
                first: mixed[0],
                remaining: Array(mixed.dropFirst())
            ))
        )

        XCTAssertEqual(harness.host.deliveredFrames.map(\.sourceAccessUnitID), [20])
    }

    func testProcessingAdmissionFloorPreservesSecondFieldThatCrossesFloor() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        )))
        harness.passthrough.setAutomaticallyCompletes(false)
        let floorPTS = CMTime(value: 41, timescale: 50)
        harness.coordinator.installProcessingAdmissionFloor(
            generation: generation,
            minimumAccessUnitID: 20,
            minimumOutputPTS: floorPTS
        )
        for id in 20...22 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        let source = try decodedFrame(
            id: 20,
            generation: generation,
            parser: unknownParser(sourcePTS90k: 72_000)
        )
        let firstField = presentationFrame(
            from: source,
            sourceAccessUnitID: 20,
            presentationTimeStamp: CMTime(value: 40, timescale: 50)
        )
        let secondField = presentationFrame(
            from: source,
            sourceAccessUnitID: 20,
            presentationTimeStamp: CMTime(value: 42, timescale: 50)
        )

        harness.passthrough.completePending(
            accessUnitID: 20,
            with: .produced(VideoProcessingFrameBatch(
                first: firstField,
                remaining: [secondField]
            ))
        )

        XCTAssertEqual(harness.host.deliveredFrames.map(\.presentationTimeStamp), [
            secondField.presentationTimeStamp,
        ])
    }

    func testProcessingAdmissionFloorSurvivesRouteChangeIsReplacedAndClearsOnGeneration()
        throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        )))
        harness.passthrough.setAutomaticallyCompletes(false)
        harness.coordinator.installProcessingAdmissionFloor(
            generation: generation,
            minimumAccessUnitID: 20,
            minimumOutputPTS: .zero
        )
        for id in 10...12 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: progressiveParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertEqual(harness.coordinator.route, .bypass)
        harness.passthrough.completePending(accessUnitIDs: [10])
        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)

        harness.coordinator.installProcessingAdmissionFloor(
            generation: generation,
            minimumAccessUnitID: 13,
            minimumOutputPTS: .zero
        )
        for id in 13...15 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: progressiveParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        harness.passthrough.completePending(accessUnitIDs: [13])
        XCTAssertEqual(harness.host.deliveredFrames.map(\.sourceAccessUnitID), [13])

        let deliveredBeforeGenerationChange = harness.host.deliveredFrames.count
        harness.coordinator.beginDiscontinuity()
        generation = harness.host.generation
        harness.coordinator.installFormatForCurrentGeneration(
            try PlaybackFakeMedia.videoFormat()
        )
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        )))
        for id in 5...7 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        harness.passthrough.completePending(accessUnitIDs: [5])
        XCTAssertEqual(
            harness.host.deliveredFrames.dropFirst(deliveredBeforeGenerationChange)
                .map(\.sourceAccessUnitID),
            [5]
        )
    }

    func testCurrentStructuralFailurePreservesMetalRouteRebuildsOnceAndWaitsForRandomAccess()
        throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let oldGeneration = harness.host.generation
        try startMetalAttempt(
            harness,
            generation: oldGeneration,
            randomAccessUnitID: 1,
            firstFrameID: 10
        )
        let resetsBefore = harness.yadif.resets.count
        let invalidationsBefore = decoderInvalidationCount(harness.decoder.snapshot())

        XCTAssertTrue(harness.yadif.completeFirst(
            generation: oldGeneration,
            with: .structuralFailure(.commandExecution)
        ))

        let recoveryGeneration = harness.host.generation
        XCTAssertEqual(recoveryGeneration.rawValue, oldGeneration.rawValue + 1)
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertEqual(harness.coordinator.requiredVideoFrameCount, 2)
        XCTAssertEqual(harness.yadif.resets.count, resetsBefore + 1)
        XCTAssertEqual(
            decoderInvalidationCount(harness.decoder.snapshot()),
            invalidationsBefore + 1
        )
        XCTAssertTrue(harness.host.operations.contains(
            "reset:\(recoveryGeneration.rawValue):2"
        ))

        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: recoveryGeneration,
            randomAccess: false
        )))
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: recoveryGeneration,
            randomAccess: true
        )))

        let failuresBeforeLateCompletion = harness.host.failures.count
        XCTAssertTrue(harness.yadif.completeFirst(
            generation: oldGeneration,
            with: .structuralFailure(.textureMapping)
        ))
        XCTAssertEqual(harness.host.generation, recoveryGeneration)
        XCTAssertEqual(harness.host.failures.count, failuresBeforeLateCompletion)
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
    }

    func testTwoStructuralRecoveriesThenThirdFailureIsTerminalExactlyOnce() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        try startMetalAttempt(
            harness,
            generation: generation,
            randomAccessUnitID: 1,
            firstFrameID: 10
        )

        for attempt in 0..<2 {
            XCTAssertTrue(harness.yadif.completeFirst(
                generation: generation,
                with: .structuralFailure(.commandExecution)
            ))
            let nextGeneration = harness.host.generation
            XCTAssertEqual(nextGeneration.rawValue, generation.rawValue + 1)
            generation = nextGeneration
            try startMetalAttempt(
                harness,
                generation: generation,
                randomAccessUnitID: UInt64(100 + attempt),
                firstFrameID: UInt64(200 + attempt * 10)
            )
        }

        let invalidationsBeforeTerminal = decoderInvalidationCount(harness.decoder.snapshot())
        XCTAssertGreaterThanOrEqual(harness.yadif.pendingCompletionCount(for: generation), 2)
        XCTAssertTrue(harness.yadif.completeFirst(
            generation: generation,
            with: .structuralFailure(.commandExecution)
        ))
        XCTAssertEqual(harness.host.failures.count, 1)
        XCTAssertEqual(harness.host.failures.first?.0, .metalCommand("yadif.command.execution"))
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(
            decoderInvalidationCount(harness.decoder.snapshot()),
            invalidationsBeforeTerminal
        )
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)

        XCTAssertTrue(harness.yadif.completeFirst(
            generation: generation,
            with: .structuralFailure(.invalidSurface)
        ))
        XCTAssertEqual(harness.host.failures.count, 1)
        XCTAssertEqual(harness.host.generation, generation)
    }

    func testStaleGenerationStructuralCompletionHasNoRecoveryOrTerminalSideEffect() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let staleGeneration = harness.host.generation
        try startMetalAttempt(
            harness,
            generation: staleGeneration,
            randomAccessUnitID: 1,
            firstFrameID: 10
        )
        harness.coordinator.beginDiscontinuity()
        let currentGeneration = harness.host.generation
        let invalidationsBeforeCompletion = decoderInvalidationCount(harness.decoder.snapshot())
        let failuresBefore = videoDropCount(.deinterlaceFailure, metrics: harness.metrics)

        XCTAssertTrue(harness.yadif.completeFirst(
            generation: staleGeneration,
            with: .structuralFailure(.textureMapping)
        ))

        XCTAssertEqual(harness.host.generation, currentGeneration)
        XCTAssertEqual(
            decoderInvalidationCount(harness.decoder.snapshot()),
            invalidationsBeforeCompletion
        )
        XCTAssertEqual(
            videoDropCount(.deinterlaceFailure, metrics: harness.metrics),
            failuresBefore
        )
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testStaleRouteStructuralCompletionHasNoRecoveryOrTerminalSideEffect() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        try startMetalAttempt(
            harness,
            generation: generation,
            randomAccessUnitID: 1,
            firstFrameID: 10
        )
        for id in 30...34 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: progressiveParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertEqual(harness.coordinator.route, .bypass)
        let invalidationsBeforeCompletion = decoderInvalidationCount(harness.decoder.snapshot())
        let failuresBefore = videoDropCount(.deinterlaceFailure, metrics: harness.metrics)

        XCTAssertTrue(harness.yadif.completeFirst(
            generation: generation,
            with: .structuralFailure(.shaderPipeline)
        ))

        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(
            decoderInvalidationCount(harness.decoder.snapshot()),
            invalidationsBeforeCompletion
        )
        XCTAssertEqual(
            videoDropCount(.deinterlaceFailure, metrics: harness.metrics),
            failuresBefore
        )
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testProcessingFloorRejectsStructuralCompletionByPTSWithoutConsumingRecovery()
        throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        try startMetalAttempt(
            harness,
            generation: generation,
            randomAccessUnitID: 1,
            firstFrameID: 10
        )
        harness.coordinator.installProcessingAdmissionFloor(
            generation: generation,
            minimumAccessUnitID: 0,
            minimumOutputPTS: CMTime(value: 100, timescale: 25)
        )
        let dropsBefore = videoDropCount(.deinterlaceFailure, metrics: harness.metrics)

        XCTAssertTrue(harness.yadif.completeFirst(
            generation: generation,
            with: .structuralFailure(.commandExecution)
        ))

        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(harness.host.failures.count, 0)
        XCTAssertEqual(
            videoDropCount(.deinterlaceFailure, metrics: harness.metrics),
            dropsBefore
        )

        // A completion fenced by the PTS floor must not secretly consume the
        // structural bucket: two later admitted failures still recover, and
        // only the third admitted failure is terminal.
        for id in 101...105 {
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: interlacedParser(
                    parity: .top,
                    sourcePTS90k: UInt64(id * 3_600)
                )
            )))
        }
        XCTAssertTrue(harness.yadif.completeFirst(
            generation: generation,
            minimumAccessUnitID: 101,
            with: .structuralFailure(.commandExecution)
        ))
        var recoveryGeneration = harness.host.generation
        XCTAssertEqual(recoveryGeneration.rawValue, generation.rawValue + 1)

        for attempt in 0..<2 {
            try startMetalAttempt(
                harness,
                generation: recoveryGeneration,
                randomAccessUnitID: UInt64(200 + attempt),
                firstFrameID: UInt64(300 + attempt * 10)
            )
            XCTAssertTrue(harness.yadif.completeFirst(
                generation: recoveryGeneration,
                with: .structuralFailure(.commandExecution)
            ))
            if attempt == 0 {
                let nextGeneration = harness.host.generation
                XCTAssertEqual(
                    nextGeneration.rawValue,
                    recoveryGeneration.rawValue + 1
                )
                recoveryGeneration = nextGeneration
                XCTAssertTrue(harness.host.failures.isEmpty)
            } else {
                XCTAssertEqual(harness.host.generation, recoveryGeneration)
                XCTAssertEqual(harness.host.failures.count, 1)
            }
        }
    }

    func testTransientDropMetricsDoNotDoubleCountQueuePressure() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        try startMetalAttempt(
            harness,
            generation: generation,
            randomAccessUnitID: 1,
            firstFrameID: 10
        )
        let queueBefore = videoDropCount(.deinterlaceQueueFull, metrics: harness.metrics)
        let failureBefore = videoDropCount(.deinterlaceFailure, metrics: harness.metrics)

        XCTAssertTrue(harness.yadif.completeFirst(
            generation: generation,
            with: .transientDrop(.queuePressure)
        ))
        XCTAssertEqual(
            videoDropCount(.deinterlaceQueueFull, metrics: harness.metrics),
            queueBefore
        )
        XCTAssertEqual(
            videoDropCount(.deinterlaceFailure, metrics: harness.metrics),
            failureBefore
        )

        XCTAssertTrue(harness.yadif.completeFirst(
            generation: generation,
            with: .transientDrop(.resourcePressure)
        ))
        XCTAssertEqual(
            videoDropCount(.deinterlaceFailure, metrics: harness.metrics),
            failureBefore + 1
        )
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    private func startMetalAttempt(
        _ harness: CoordinatorHarness,
        generation: MediaGeneration,
        randomAccessUnitID: UInt64,
        firstFrameID: UInt64
    ) throws {
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: randomAccessUnitID,
            generation: generation,
            randomAccess: true
        )))
        for offset in UInt64(0)..<5 {
            let id = firstFrameID + offset
            harness.coordinator.handle(decoder: harness.frameEvent(try decodedFrame(
                id: id,
                generation: generation,
                parser: interlacedParser(
                    parity: .top,
                    sourcePTS90k: id * 3_600
                )
            )))
        }
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertEqual(harness.coordinator.requiredVideoFrameCount, 2)
        XCTAssertGreaterThan(harness.yadif.pendingCompletionCount(for: generation), 0)
    }

    private func decoderInvalidationCount(
        _ operations: [RecordingCoordinatorDecoder.Operation]
    ) -> Int {
        operations.count { operation in
            switch operation {
            case .transitionDrainAndInvalidate, .transitionInvalidate:
                true
            case .transitionConfigure, .decode:
                false
            }
        }
    }

    private func videoDropCount(
        _ source: VideoDropSource,
        metrics: PlaybackMetrics
    ) -> UInt64 {
        metrics.snapshot(window: .seconds(60)).videoDropCountsBySource[source.rawValue]
    }

    private func makeHarness(
        classifierConfiguration: ScanClassifierConfiguration = ScanClassifierConfiguration(
            progressiveConfirmationFrames: 1,
            psfConfirmationFrames: 1,
            exitInterlacedConfirmationFrames: 1
        ),
        automaticallyCompletesTransitions: Bool = true,
        transitionDeadlineScheduler: VideoPipelineCoordinator.DecoderTransitionDeadlineScheduler? = nil
    ) -> CoordinatorHarness {
        let trace = CoordinatorTrace()
        let decoder = RecordingCoordinatorDecoder(
            trace: trace,
            automaticallyCompletesTransitions: automaticallyCompletesTransitions
        )
        let passthrough = FakePipelineVideoProcessor()
        let yadif = FakeCoordinatorYADIFProcessor()
        let probe = FakeCoordinatorProbe()
        let host = CoordinatorHost(trace: trace)
        let metrics = PlaybackMetrics(
            channelID: "channel",
            now: { 60 },
            residentMemoryProvider: { 1 }
        )
        let coordinator = VideoPipelineCoordinator(
            decoder: decoder,
            passthrough: passthrough,
            yadif: yadif,
            probe: probe,
            initialGeneration: host.generation,
            classifierConfiguration: classifierConfiguration,
            decoderTransitionDeadlineScheduler: transitionDeadlineScheduler,
            metrics: metrics,
            hooks: host.hooks
        )
        decoder.installTransitionEventSink { [weak coordinator] event in
            coordinator?.handle(decoder: event)
        }
        return CoordinatorHarness(
            coordinator: coordinator,
            decoder: decoder,
            passthrough: passthrough,
            yadif: yadif,
            probe: probe,
            host: host,
            metrics: metrics,
            trace: trace
        )
    }

    private func decodedFrame(
        id: UInt64,
        generation: MediaGeneration,
        parser: VideoParserMetadata
    ) throws -> DecodedVideoFrame {
        let base = try PlaybackFakeMedia.decodedFrame(
            id: id,
            generation: generation,
            pts: CMTime(value: Int64(id), timescale: 25),
            interlaced: false
        )
        return DecodedVideoFrame(
            accessUnitID: base.accessUnitID,
            pixelBuffer: base.pixelBuffer,
            presentationTimeStamp: base.presentationTimeStamp,
            duration: base.duration,
            generation: base.generation,
            parserMetadata: parser,
            formatMetadata: base.formatMetadata
        )
    }

    private func presentationFrame(
        from source: DecodedVideoFrame,
        sourceAccessUnitID: UInt64,
        presentationTimeStamp: CMTime,
        generation: MediaGeneration? = nil
    ) -> VideoPresentationFrame {
        VideoPresentationFrame(
            pixelBuffer: source.pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: source.duration,
            generation: generation ?? source.generation,
            sequenceNumber: sourceAccessUnitID,
            sourceAccessUnitID: sourceAccessUnitID,
            formatMetadata: source.formatMetadata
        )
    }

    private func unknownParser(sourcePTS90k: UInt64?) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: nil,
            pictureStructure: .frame,
            isInterlaced: nil,
            repeatFirstField: false,
            topFieldFirst: nil,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func progressiveParser(sourcePTS90k: UInt64?) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: .progressive,
            pictureStructure: .frame,
            isInterlaced: false,
            repeatFirstField: false,
            topFieldFirst: nil,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func interlacedParser(
        parity: FieldParity,
        sourcePTS90k: UInt64?
    ) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: parity == .top ? .tt : .bb,
            pictureStructure: parity == .top ? .topField : .bottomField,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: parity == .top,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func fieldSignalledParser(sourcePTS90k: UInt64?) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: .tt,
            pictureStructure: .frame,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: true,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func number(_ value: Int32) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value)
    }
}

private struct CoordinatorHarness {
    let coordinator: VideoPipelineCoordinator
    let decoder: RecordingCoordinatorDecoder
    let passthrough: FakePipelineVideoProcessor
    let yadif: FakeCoordinatorYADIFProcessor
    let probe: FakeCoordinatorProbe
    let host: CoordinatorHost
    let metrics: PlaybackMetrics
    let trace: CoordinatorTrace

    func frameEvent(_ frame: DecodedVideoFrame) -> VideoDecoderEvent {
        .frame(frame, identity: decoder.identity(for: frame.generation))
    }

    func fatalFailureEvent(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) -> VideoDecoderEvent {
        .fatalFailure(failure, identity: decoder.identity(for: generation))
    }

    func recoverableFailureEvent(
        _ failure: VideoDecoderFailure,
        generation: MediaGeneration
    ) -> VideoDecoderEvent {
        .recoverableFailure(failure, identity: decoder.identity(for: generation))
    }
}

private final class CoordinatorHost: @unchecked Sendable {
    private let trace: CoordinatorTrace
    private(set) var generation = MediaGeneration(rawValue: 0)
    private(set) var deliveredFrames: [VideoPresentationFrame] = []
    private(set) var failures: [(PlaybackCoreError, MediaGeneration)] = []
    private(set) var submissionRejections: [(UInt64, VideoDecoderEventIdentity)] = []
    private(set) var requiredVideoFrameCounts: [Int] = []
    private(set) var operations: [String] = []

    init(trace: CoordinatorTrace) {
        self.trace = trace
    }

    var hooks: VideoPipelineCoordinatorHooks {
        VideoPipelineCoordinatorHooks(
            closeAdmission: { [weak self] in
                self?.operations.append("close")
                self?.trace.append("host.close")
            },
            advanceGeneration: { [weak self] in
                guard let self else { return MediaGeneration(rawValue: 0) }
                generation = MediaGeneration(rawValue: generation.rawValue + 1)
                operations.append("advance:\(generation.rawValue)")
                trace.append("host.advance:\(generation.rawValue)")
                return generation
            },
            resetPlayback: { [weak self] generation, requiredCount, _ in
                self?.operations.append("reset:\(generation.rawValue):\(requiredCount)")
                self?.trace.append("host.reset:\(generation.rawValue):\(requiredCount)")
            },
            submissionRejected: { [weak self] accessUnitID, identity in
                self?.submissionRejections.append((accessUnitID, identity))
            },
            decoderInvalidationBegan: { _ in },
            decoderInvalidationFinished: { _, _ in },
            reopenAdmission: { [weak self] in
                self?.operations.append("open")
                self?.trace.append("host.open")
            },
            routeDidChange: { [weak self] requiredCount in
                self?.requiredVideoFrameCounts.append(requiredCount)
            },
            deliver: { [weak self] frames, _ in
                self?.deliveredFrames.append(contentsOf: frames)
            },
            fail: { [weak self] failure, generation in
                self?.failures.append((failure, generation))
            },
            schedule: { operation in operation() }
        )
    }
}

private final class CoordinatorTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    func removeAll() { lock.withLock { storage.removeAll(keepingCapacity: true) } }
}

private final class ManualCoordinatorTransitionDeadlineScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    func schedule(
        after _: DispatchTimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) {
        lock.withLock { operations.append(operation) }
    }

    @discardableResult
    func fireNext() -> Bool {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !operations.isEmpty else { return nil }
            return operations.removeFirst()
        }
        guard let operation else { return false }
        operation()
        return true
    }
}

private final class RecordingCoordinatorDecoder: VideoDecoding, @unchecked Sendable {
    enum Operation: Equatable {
        case transitionConfigure(VideoDecoderTransitionToken, MediaGeneration)
        case transitionDrainAndInvalidate(VideoDecoderTransitionToken)
        case transitionInvalidate(VideoDecoderTransitionToken)
        case decode(UInt64, MediaGeneration, VTDecodeFrameFlags)
    }

    private let lock = NSLock()
    private let trace: CoordinatorTrace
    private let automaticallyCompletesTransitions: Bool
    private var operations: [Operation] = []
    private var transitionEventSink: (@Sendable (VideoDecoderEvent) -> Void)?
    var decodeFailures: [VideoDecoderFailure] = []
    var nextDrainOutcome: VideoDecoderTransitionOutcome = .completed

    init(trace: CoordinatorTrace, automaticallyCompletesTransitions: Bool) {
        self.trace = trace
        self.automaticallyCompletesTransitions = automaticallyCompletesTransitions
    }

    func installTransitionEventSink(
        _ sink: @escaping @Sendable (VideoDecoderEvent) -> Void
    ) {
        transitionEventSink = sink
    }

    func transition(_ transition: VideoDecoderTransition) {
        let completion: (VideoDecoderTransitionToken, VideoDecoderTransitionOutcome)
        switch transition {
        case let .configure(transitionToken, _, generation):
            lock.withLock {
                operations.append(.transitionConfigure(transitionToken, generation))
            }
            trace.append("decoder.transition.configure:\(generation.rawValue)")
            completion = (transitionToken, .completed)
        case let .drainAndInvalidate(transitionToken):
            lock.withLock {
                operations.append(.transitionDrainAndInvalidate(transitionToken))
            }
            trace.append("decoder.transition.drainAndInvalidate")
            completion = (transitionToken, nextDrainOutcome)
            nextDrainOutcome = .completed
        case let .invalidate(transitionToken):
            lock.withLock { operations.append(.transitionInvalidate(transitionToken)) }
            trace.append("decoder.transition.invalidate")
            completion = (transitionToken, .completed)
        }
        if automaticallyCompletesTransitions {
            transitionEventSink?(.transitionCompleted(
                token: completion.0,
                outcome: completion.1
            ))
        }
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        lock.withLock {
            operations.append(.decode(accessUnit.id, accessUnit.generation, flags))
        }
        trace.append("decoder.decode:\(accessUnit.id):\(accessUnit.generation.rawValue)")
        if !decodeFailures.isEmpty { throw decodeFailures.removeFirst() }
    }

    func snapshot() -> [Operation] { lock.withLock { operations } }

    func identity(for generation: MediaGeneration) -> VideoDecoderEventIdentity {
        lock.withLock {
            for operation in operations.reversed() {
                guard case let .transitionConfigure(token, configuredGeneration) = operation,
                      configuredGeneration == generation else { continue }
                return VideoDecoderEventIdentity(
                    generation: generation,
                    transitionToken: token
                )
            }
            preconditionFailure("missing configured decoder identity for generation")
        }
    }
}

private final class FakeCoordinatorProbe: LumaScanProbing, @unchecked Sendable {
    struct Pending: @unchecked Sendable {
        let generation: MediaGeneration
        let completion: @Sendable (Result<ContentProbeSample, LumaScanProbeFailure>) -> Void
    }

    private(set) var pending: [Pending] = []
    private(set) var stopped: [MediaGeneration] = []
    var pendingCount: Int { pending.count }

    func submit(
        current _: CVPixelBuffer,
        previous _: CVPixelBuffer,
        generation: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) {
        pending.append(Pending(generation: generation, completion: completion))
    }

    func stop(generation: MediaGeneration) {
        stopped.append(generation)
    }


    func completeFirst(
        _ result: Result<ContentProbeSample, LumaScanProbeFailure>
    ) {
        let item = pending.removeFirst()
        item.completion(result)
    }
}

private final class FakeCoordinatorYADIFProcessor: YADIFFrameProcessing, @unchecked Sendable {
    struct Submission: @unchecked Sendable {
        let frame: NormalizedDecodedFrame
        let order: ResolvedFieldOrder
    }

    private struct Pending: @unchecked Sendable {
        let frame: NormalizedDecodedFrame
        let completion: @Sendable (VideoProcessingResult) -> Void
    }

    private(set) var resets: [MediaGeneration] = []
    private(set) var submissions: [Submission] = []
    private var pendingCompletions: [Pending] = []
    var pendingCompletionCount: Int { pendingCompletions.count }
    func pendingCompletionCount(for generation: MediaGeneration) -> Int {
        pendingCompletions.count { $0.frame.frame.generation == generation }
    }

    func reset(to generation: MediaGeneration) {
        resets.append(generation)
    }

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity _: Bool,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    ) {
        submissions.append(Submission(frame: frame, order: order))
        pendingCompletions.append(Pending(frame: frame, completion: completion))
    }

    func drain(completion: @escaping @Sendable () -> Void) { completion() }

    func completeFirst(with result: VideoProcessingResult) {
        pendingCompletions.removeFirst().completion(result)
    }

    @discardableResult
    func completeFirst(
        generation: MediaGeneration,
        minimumAccessUnitID: UInt64 = 0,
        with result: VideoProcessingResult
    ) -> Bool {
        guard let index = pendingCompletions.firstIndex(where: {
            $0.frame.frame.generation == generation
                && $0.frame.frame.accessUnitID >= minimumAccessUnitID
        }) else { return false }
        pendingCompletions.remove(at: index).completion(result)
        return true
    }

    func completeAll() {
        let pending = pendingCompletions
        let frames = pending.enumerated().map { offset, item in
            VideoPresentationFrame(
                pixelBuffer: item.frame.frame.pixelBuffer,
                presentationTimeStamp: item.frame.presentationTimeStamp,
                duration: item.frame.fieldDuration,
                generation: item.frame.frame.generation,
                sequenceNumber: UInt64(offset + 1),
                sourceAccessUnitID: item.frame.frame.accessUnitID,
                formatMetadata: item.frame.frame.formatMetadata
            )
        }
        pendingCompletions.removeAll(keepingCapacity: true)
        for (pending, frame) in zip(pending, frames) {
            pending.completion(.produced(VideoProcessingFrameBatch(first: frame)))
        }
    }
}
