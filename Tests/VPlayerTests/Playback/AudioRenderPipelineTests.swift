// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class AudioRenderPipelineTests: XCTestCase, @unchecked Sendable {
    func testAutomaticFlushOriginTrackerRetainsOnlyCurrentTicket() {
        var tracker = AudioAutomaticFlushProgressOriginTracker()
        let first = AudioRendererProgressTicket(rawValue: 1)
        let second = AudioRendererProgressTicket(rawValue: 2)

        tracker.markCurrent(first)
        tracker.markCurrent(second)
        XCTAssertEqual(tracker.retainedTicketCount, 1)
        XCTAssertFalse(tracker.consumeIfCurrent(first))
        XCTAssertEqual(tracker.retainedTicketCount, 1)
        XCTAssertTrue(tracker.consumeIfCurrent(second))
        XCTAssertEqual(tracker.retainedTicketCount, 0)
    }

    func testAutomaticFlushReplayDoesNotResetUniqueMediaProgressAge() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        harness.diagnosticsClock.set(10)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1)
            ))
        }

        harness.diagnosticsClock.set(20)
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)

        XCTAssertEqual(
            try XCTUnwrap(harness.pipeline.diagnostics.lastRendererProgressAgeSeconds),
            10,
            accuracy: 0.001
        )

        harness.diagnosticsClock.set(25)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1)
            ))
        }
        XCTAssertEqual(harness.pipeline.diagnostics.lastAcceptedPTSSeconds, 2)
        XCTAssertEqual(harness.pipeline.diagnostics.lastRendererProgressAgeSeconds, 0)
    }

    func testPCMRecoveryReplayDoesNotResetUniqueMediaProgressAge() throws {
        let harness = try makeHarness()
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        compressed.configureReadiness(ready: true)
        harness.diagnosticsClock.set(10)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1)
            ))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "unique-progress"
        )
        harness.synchronizer.completeRemoval(
            index: transition.removalIndex,
            didRemove: true
        )
        drain(harness.executor)
        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true)
        pcm.fireReady()
        drain(harness.executor)

        harness.diagnosticsClock.set(20)
        pcm.emit(.automaticFlush(.zero))
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(
            try XCTUnwrap(harness.pipeline.diagnostics.lastRendererProgressAgeSeconds),
            10,
            accuracy: 0.001
        )

        harness.diagnosticsClock.set(25)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1)
            ))
        }
        XCTAssertEqual(harness.pipeline.diagnostics.lastAcceptedPTSSeconds, 2)
        XCTAssertEqual(harness.pipeline.diagnostics.lastRendererProgressAgeSeconds, 0)
    }

    func testReplacementWindowPublishesPendingWorkBeforeRendererReattaches() throws {
        let harness = try makeHarness()
        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .ac3),
                codec: .ac3,
                generation: MediaGeneration(rawValue: 2),
                fingerprint: self.fingerprint(2)
            )
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 2),
                generation: MediaGeneration(rawValue: 2)
            )
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                codec: .ac3,
                pts: CMTime(value: 2, timescale: 1),
                generation: MediaGeneration(rawValue: 2),
                continuityIslandID: AudioContinuityIslandID(rawValue: 2)
            ))
        }

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.pendingSampleCount, 1)
        XCTAssertFalse(harness.pipeline.diagnostics.rendererRequestArmed)
    }

    func testPumpDiagnosticsExposePendingBackpressureRearmAndMonotonicProgress() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: false)
        harness.diagnosticsClock.set(10)

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 7, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }

        var diagnostics = harness.pipeline.diagnostics
        XCTAssertEqual(diagnostics.pendingSampleCount, 1)
        XCTAssertTrue(diagnostics.rendererRequestArmed)
        XCTAssertEqual(diagnostics.rendererBackpressureCount, 1)
        XCTAssertEqual(diagnostics.rendererRequestRearmCount, 0)
        XCTAssertNil(diagnostics.lastAcceptedPTSSeconds)
        XCTAssertNil(diagnostics.lastRendererProgressAgeSeconds)

        harness.diagnosticsClock.set(12)
        renderer.configureReadiness(ready: true)
        renderer.fireReady()
        drain(harness.executor)

        diagnostics = harness.pipeline.diagnostics
        XCTAssertEqual(diagnostics.pendingSampleCount, 0)
        XCTAssertFalse(diagnostics.rendererRequestArmed)
        XCTAssertEqual(diagnostics.lastAcceptedPTSSeconds, 7)
        XCTAssertEqual(diagnostics.lastRendererProgressAgeSeconds, 0)

        harness.diagnosticsClock.set(15.25)
        XCTAssertEqual(
            try XCTUnwrap(harness.pipeline.diagnostics.lastRendererProgressAgeSeconds),
            3.25,
            accuracy: 0.001
        )

        renderer.configureEnqueueResults([.backpressured, .accepted])
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 8, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }

        diagnostics = harness.pipeline.diagnostics
        XCTAssertEqual(diagnostics.pendingSampleCount, 1)
        XCTAssertTrue(diagnostics.rendererRequestArmed)
        XCTAssertEqual(diagnostics.rendererBackpressureCount, 2)
        XCTAssertEqual(diagnostics.rendererRequestRearmCount, 1)

        harness.diagnosticsClock.set(20)
        renderer.fireReady()
        drain(harness.executor)
        diagnostics = harness.pipeline.diagnostics
        XCTAssertEqual(diagnostics.pendingSampleCount, 0)
        XCTAssertFalse(diagnostics.rendererRequestArmed)
        XCTAssertEqual(diagnostics.lastAcceptedPTSSeconds, 8)
        XCTAssertEqual(diagnostics.lastRendererProgressAgeSeconds, 0)
    }

    func testDiagnosticsCountAcceptedRecoveryTriggersTransactionsAndSuppression() throws {
        let harness = try makeHarness(initialRouteCategory: .airPlay)
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)

        renderer.emit(.outputConfigurationChanged)
        drain(harness.executor)
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 1
        ))
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.diagnostics.outputConfigurationTriggerCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.routeChangeTriggerCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.recoveryTransactionCount, 0)

        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.diagnostics.recoveryTransactionCount, 1)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 2
        ))
        renderer.emit(.outputConfigurationChanged)
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.diagnostics.routeChangeTriggerCount, 2)
        XCTAssertEqual(harness.pipeline.diagnostics.outputConfigurationTriggerCount, 2)
        XCTAssertEqual(harness.pipeline.diagnostics.suppressedCorrelatedTriggerCount, 2)

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushTriggerCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.recoveryTransactionCount, 1)
        XCTAssertEqual(harness.pipeline.recoveryCount, 1)
    }

    func testDiagnosticsCountCompressedRetryAndRepeatedFailureFallback() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }

        first.emit(.failed("diagnostics:first"))
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.pcmFallbackCount, 0)
        XCTAssertNil(harness.pipeline.diagnostics.lastFallbackReason)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let retry = try XCTUnwrap(harness.renderers.snapshot.last)
        retry.emit(.failed("diagnostics:second"))
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.pcmFallbackCount, 1)
        XCTAssertEqual(
            harness.pipeline.diagnostics.lastFallbackReason,
            .repeatedCompressedRendererFailure
        )
    }

    func testDiagnosticsMeasureStartupWaitAndTrackCurrentRendererState() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true, sufficient: false)
        harness.diagnosticsClock.set(10)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }

        harness.diagnosticsClock.set(14.25)
        XCTAssertEqual(harness.pipeline.diagnostics.startupWaitingSeconds, 4.25, accuracy: 0.001)
        XCTAssertTrue(harness.pipeline.diagnostics.rendererReady)
        XCTAssertFalse(harness.pipeline.diagnostics.rendererSufficient)

        renderer.configureReadiness(ready: true, sufficient: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 2))
        }
        harness.diagnosticsClock.set(30)
        XCTAssertEqual(harness.pipeline.diagnostics.startupWaitingSeconds, 4.25, accuracy: 0.001)
        XCTAssertTrue(harness.pipeline.diagnostics.rendererReady)
        XCTAssertTrue(harness.pipeline.diagnostics.rendererSufficient)

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 2),
                fingerprint: self.fingerprint(2)
            )
        }
        XCTAssertEqual(harness.pipeline.diagnostics.startupWaitingSeconds, 0)
        XCTAssertFalse(harness.pipeline.diagnostics.rendererReady)
        XCTAssertFalse(harness.pipeline.diagnostics.rendererSufficient)
    }

    func testDiagnosticsPreserveSanitizedCompressedFailureAndBoundedContextThroughFallback() throws {
        let fingerprint = MediaFormatFingerprint(bytes: Data([0xD1, 0xA6]))
        let harness = try makeHarness(
            codec: .eac3,
            initialRouteCategory: .airPlay,
            fingerprint: fingerprint
        )
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        first.configureReadiness(ready: true, sufficient: false)
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .hdmi,
            reason: .routeConfigurationChange,
            revision: 42
        ))
        drain(harness.executor)
        for index in 0..<2 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(index + 1),
                    codec: .eac3,
                    pts: CMTime(value: Int64(index), timescale: 4),
                    duration: CMTime(value: 1, timescale: 4)
                ))
            }
        }

        var diagnostics = harness.pipeline.diagnostics
        XCTAssertEqual(diagnostics.activeCodec, .eac3)
        XCTAssertEqual(
            diagnostics.formatFingerprint?.value,
            "eea9bca7f67751f7ba2ceb32cb8527428fe406ce2d0f14485c9401c2da3e0388"
        )
        XCTAssertEqual(diagnostics.outputCategory, .hdmi)
        XCTAssertEqual(diagnostics.routeRevision, 42)
        XCTAssertEqual(diagnostics.mediaGeneration, MediaGeneration(rawValue: 1))
        XCTAssertEqual(diagnostics.acceptedCompressedMediaDurationSeconds, 0.5, accuracy: 0.001)
        XCTAssertNil(diagnostics.lastCompressedRendererFailure)

        first.emit(.failed("AVFoundationErrorDomain:-11819"))
        drain(harness.executor)
        diagnostics = harness.pipeline.diagnostics
        XCTAssertEqual(diagnostics.lastCompressedRendererFailure?.domain, "AVFoundationErrorDomain")
        XCTAssertEqual(diagnostics.lastCompressedRendererFailure?.code, -11819)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let retry = try XCTUnwrap(harness.renderers.snapshot.last)
        retry.emit(.failed("NSOSStatusErrorDomain:-12911"))
        drain(harness.executor)

        diagnostics = harness.pipeline.diagnostics
        XCTAssertEqual(diagnostics.lastCompressedRendererFailure?.domain, "NSOSStatusErrorDomain")
        XCTAssertEqual(diagnostics.lastCompressedRendererFailure?.code, -12911)
        XCTAssertEqual(diagnostics.activeCodec, .eac3)
        XCTAssertEqual(diagnostics.outputCategory, .hdmi)
        XCTAssertEqual(diagnostics.routeRevision, 42)
        XCTAssertEqual(diagnostics.mediaGeneration, MediaGeneration(rawValue: 1))
        XCTAssertEqual(diagnostics.acceptedCompressedMediaDurationSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(diagnostics.pcmFallbackCount, 1)
        XCTAssertEqual(diagnostics.lastFallbackReason, .repeatedCompressedRendererFailure)
    }

    func testFirstCompressedFailureRecreatesCompressedRendererAndReplaysWithoutPCMProbe() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        first.configureReadiness(ready: true)
        for id in 1...3 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    pts: CMTime(value: Int64(id), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1)
                ))
            }
        }
        first.configureReadiness(ready: false)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 4,
                pts: CMTime(value: 4, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }
        let stopsBeforeFailure = first.snapshot.stopRequestCount

        first.emit(.failed("compressed:first"))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(first.snapshot.stopRequestCount, stopsBeforeFailure + 1)
        XCTAssertEqual(first.snapshot.observationStopCount, 1)

        harness.synchronizer.setCurrentTime(CMTime(value: 2, timescale: 1))
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.configureReadiness(ready: true)
        replacement.fireReady()
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertEqual(replacement.snapshot.enqueuedPTS, [
            CMTime(value: 2, timescale: 1),
            CMTime(value: 3, timescale: 1),
            CMTime(value: 4, timescale: 1),
        ])
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testSecondCompressedFailureForSameAttemptFallsBackToPCMExactlyOnce() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        first.emit(.failed("compressed:first"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        let retry = try XCTUnwrap(harness.renderers.snapshot.last)
        retry.emit(.failed("compressed:second"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)

        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed, .compressed, .linearPCM,
        ])
        XCTAssertEqual(harness.decoderFactory.snapshot.count, 1)
        XCTAssertEqual(harness.support.formatIDSnapshot, [kAudioFormatLinearPCM])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testNewGenerationStartsFreshCompressedRetryAttempt() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        first.emit(.failed("generation:old"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        let retry = try XCTUnwrap(harness.renderers.snapshot.last)
        performWithoutThrow(on: harness.executor) {
            harness.pipeline.flush(to: MediaGeneration(rawValue: 2))
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 2)
            )
        }
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                generation: MediaGeneration(rawValue: 2)
            ))
        }
        retry.emit(.failed("generation:new"))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed, .compressed, .compressed,
        ])
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testNewFingerprintStartsFreshCompressedRetryAttemptForSameGeneration() throws {
        let harness = try makeHarness(fingerprint: fingerprint(1))
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        first.emit(.failed("fingerprint:old"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(2)
            )
        }
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)
        let reconfigured = try XCTUnwrap(harness.renderers.snapshot.last)
        try perform(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
            try harness.pipeline.enqueue(try self.makeSample(id: 2))
        }

        reconfigured.emit(.failed("fingerprint:new"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 3)
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
        harness.synchronizer.completeRemoval(index: 2, didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed, .compressed, .compressed, .compressed,
        ])
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testNewRouteRevisionStartsFreshCompressedRetryAttemptAndInvalidatesPendingRecovery() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        first.emit(.failed("route:old"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        let retry = try XCTUnwrap(harness.renderers.snapshot.last)
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 1
        ))
        drain(harness.executor)
        retry.emit(.failed("route:new"))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed, .compressed, .compressed,
        ])
        XCTAssertEqual(
            replacement.snapshot.operations.filter { $0 == "flush" }.count,
            1,
            "the replacement owns one replay independent of the invalidated route collection"
        )
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testStaleFailureCallbackFromRemovedCompressedRendererCannotConsumeRetryBudget() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let staleHandler = try XCTUnwrap(first.captureEventHandler())
        first.emit(.failed("current"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        staleHandler(.failed("stale"))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        let retry = try XCTUnwrap(harness.renderers.snapshot.last)
        retry.emit(.failed("current:second"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)

        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed, .compressed, .linearPCM,
        ])
        XCTAssertEqual(harness.decoderFactory.snapshot.count, 1)
        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testRunningCompressedRetryPreservesReadinessAndExternalClockOwnership() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.retry-running")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let readiness = LockedAudioReadinessChanges(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { _, _ in },
            rendererFactory: renderers,
            decoderFactory: FakePCMAudioDecoderFactory { _ in [] },
            routeMonitor: FakeAudioRouteMonitor(),
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            clockMode: .externallyManaged,
            readinessSink: { change, generation in
                readiness.append(change, generation: generation)
            }
        )
        synchronizer.setRate(1, time: CMTime(value: 7, timescale: 1))
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
            pipeline.setSharedTimelineOpened(true)
        }
        let first = try XCTUnwrap(renderers.snapshot.first)
        first.configureReadiness(ready: true, sufficient: true)
        try perform(on: executor) {
            try pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 7, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }
        XCTAssertTrue(pipeline.isReadyForPlayback)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        let rateSnapshot = synchronizer.rateSnapshot

        first.emit(.failed("running"))
        drain(executor)
        XCTAssertTrue(pipeline.isReadyForPlayback)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        XCTAssertEqual(synchronizer.rateSnapshot.map(\.0), rateSnapshot.map(\.0))

        synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(executor)
        XCTAssertTrue(pipeline.isReadyForPlayback)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        XCTAssertEqual(synchronizer.rateSnapshot.map(\.0), rateSnapshot.map(\.0))
        XCTAssertEqual(renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
    }

    func testRunningCompressedRetryPreservesLatchedReadinessAndStandaloneClockRate() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        first.configureReadiness(ready: true, sufficient: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 7, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
            harness.pipeline.setSharedTimelineOpened(true)
        }
        XCTAssertTrue(harness.pipeline.isReadyForPlayback)

        let runningTime = CMTime(value: 7, timescale: 1)
        harness.synchronizer.setRate(1, time: runningTime)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.count, 1)
        XCTAssertEqual(harness.synchronizer.rate, 1)

        first.emit(.failed("running:standalone"))
        drain(harness.executor)

        XCTAssertTrue(harness.pipeline.isReadyForPlayback)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.count, 1)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.0, 1)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.1, runningTime)
        XCTAssertEqual(harness.synchronizer.rate, 1)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        XCTAssertTrue(harness.pipeline.isReadyForPlayback)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.count, 1)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.0, 1)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.1, runningTime)
        XCTAssertEqual(harness.synchronizer.rate, 1)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testStartupCompressedRetryRequiresReplacementToEarnFreshPreroll() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        first.configureReadiness(ready: true, sufficient: false)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        XCTAssertFalse(harness.pipeline.isReadyForPlayback)

        first.emit(.failed("startup"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.configureReadiness(ready: true, sufficient: false)
        replacement.fireReady()
        drain(harness.executor)
        XCTAssertFalse(harness.pipeline.isReadyForPlayback)

        replacement.configureReadiness(ready: true, sufficient: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10)
            ))
        }
        XCTAssertTrue(harness.pipeline.isReadyForPlayback)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
    }

    func testCompressedRetryRemovalFailureIsTerminalButReplacementConstructionCanUsePCM() throws {
        do {
            let harness = try makeHarness()
            let first = try XCTUnwrap(harness.renderers.snapshot.first)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }
            first.emit(.failed("remove"))
            drain(harness.executor)
            harness.synchronizer.completeRemoval(index: 0, didRemove: false)
            drain(harness.executor)
            XCTAssertEqual(harness.failures.snapshot.map(\.error), [
                .audioRendererFailed(AudioRenderPipeline.removalFailedError),
            ])
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
            XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
        }

        do {
            let harness = try makeHarness()
            let first = try XCTUnwrap(harness.renderers.snapshot.first)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }
            harness.renderers.configureNextCreateError(
                .audioRendererFailed("retry.create"),
                for: .compressed
            )
            first.emit(.failed("create"))
            drain(harness.executor)
            harness.synchronizer.completeRemoval(index: 0, didRemove: true)
            drain(harness.executor)
            XCTAssertTrue(harness.failures.snapshot.isEmpty)
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
                .compressed, .linearPCM,
            ])
            XCTAssertEqual(harness.decoderFactory.snapshot.count, 1)
        }

        do {
            let harness = try makeHarness()
            let first = try XCTUnwrap(harness.renderers.snapshot.first)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }
            harness.synchronizer.configureNextAttachError(
                .audioRendererFailed("retry.attach")
            )
            first.emit(.failed("attach"))
            drain(harness.executor)
            harness.synchronizer.completeRemoval(index: 0, didRemove: true)
            drain(harness.executor)
            XCTAssertTrue(harness.failures.snapshot.isEmpty)
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
                .compressed, .compressed, .linearPCM,
            ])
            XCTAssertEqual(harness.decoderFactory.snapshot.count, 1)
        }
    }

    func testPCMRendererFailureRemainsTerminalAndNeverSwitchesBackToCompressed() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        first.emit(.failed("compressed:first"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let retry = try XCTUnwrap(harness.renderers.snapshot.last)
        retry.emit(.failed("compressed:second"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)

        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        let repeatedPCMHandler = try XCTUnwrap(pcm.captureEventHandler())
        pcm.emit(.failed("pcm:terminal"))
        drain(harness.executor)
        repeatedPCMHandler(.failed("pcm:repeated"))
        drain(harness.executor)

        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioRendererFailed("pcm:terminal"),
        ])
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed, .compressed, .linearPCM,
        ])
        XCTAssertEqual(harness.synchronizer.removalCount, 2)
    }

    func testAwaitedStopCompletesExactlyOnceAfterRemovalSuccessFailureAndRepeatedCalls() async throws {
        for didRemove in [true, false] {
            let harness = try makeHarness()
            let completions = LockedAudioCompletionCount()
            let first = Task {
                await harness.pipeline.stopAwaitingRendererRemoval()
                completions.increment()
            }
            let second = Task {
                await harness.pipeline.stopAwaitingRendererRemoval()
                completions.increment()
            }

            try await eventually { harness.synchronizer.removalCount == 1 }
            XCTAssertEqual(completions.value, 0)
            harness.synchronizer.completeRemoval(didRemove: didRemove)
            await first.value
            await second.value
            XCTAssertEqual(completions.value, 2)
            XCTAssertEqual(harness.synchronizer.removalCount, 1)

            harness.synchronizer.completeRemoval(didRemove: didRemove)
            drain(harness.executor)
            XCTAssertEqual(completions.value, 2)
            await harness.pipeline.stopAwaitingRendererRemoval()
            XCTAssertEqual(harness.synchronizer.removalCount, 1)
        }
    }

    func testAwaitedStopDeadlineCompletesWhenSynchronizerNeverCallsBack() async throws {
        let harness = try makeHarness()
        let completions = LockedAudioCompletionCount()
        let stop = Task {
            await harness.pipeline.stopAwaitingRendererRemoval()
            completions.increment()
        }
        try await eventually { harness.synchronizer.removalCount == 1 }

        harness.recoveryScheduler.advance(by: .seconds(2))
        drain(harness.executor)
        await stop.value
        XCTAssertEqual(completions.value, 1)

        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(completions.value, 1)
        XCTAssertFalse(harness.pipeline.isReadyForPlayback)
    }

    func testAwaitedStopHandlesNoRendererAndPendingConfigureRemovalWithoutCreatingReplacement() async throws {
        let unconfigured = try makeHarness(configure: false)
        await unconfigured.pipeline.stopAwaitingRendererRemoval()
        XCTAssertEqual(unconfigured.synchronizer.removalCount, 0)

        let pending = try makeHarness()
        try perform(on: pending.executor) {
            try pending.pipeline.configure(
                format: try self.makeFormat(codec: .ac3),
                codec: .ac3,
                generation: MediaGeneration(rawValue: 2),
                fingerprint: self.fingerprint(2)
            )
        }
        XCTAssertEqual(pending.synchronizer.removalCount, 1)
        let completion = LockedAudioCompletionCount()
        let stop = Task {
            await pending.pipeline.stopAwaitingRendererRemoval()
            completion.increment()
        }
        try await Task.sleep(for: .milliseconds(20))
        drain(pending.executor)
        XCTAssertEqual(completion.value, 0)

        pending.synchronizer.completeRemoval(didRemove: true)
        await stop.value
        XCTAssertEqual(completion.value, 1)
        XCTAssertEqual(pending.renderers.snapshot.count, 1)
    }

    func testSynchronousStopStronglyRetainsCleanupUntilAsynchronousRemovalCallback() async throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.stop-retention")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { _ in [] }
        let routeMonitor = FakeAudioRouteMonitor()
        let support = FakeAudioFormatSupportChecker()
        let failures = LockedAudioFailures(executor: executor)
        weak var weakPipeline: AudioRenderPipeline?

        do {
            let pipeline = AudioRenderPipeline(
                synchronizer: synchronizer,
                executor: executor,
                failureSink: { error, generation in failures.append(error, generation: generation) },
                rendererFactory: renderers,
                decoderFactory: decoderFactory,
                routeMonitor: routeMonitor,
                decodeCapabilityChecker: support,
                pcmOutputValidator: support
            )
            weakPipeline = pipeline
            try perform(on: executor) {
                try pipeline.configure(
                    format: try self.makeFormat(codec: .aac),
                    codec: .aac,
                    generation: MediaGeneration(rawValue: 1),
                    fingerprint: self.fingerprint(1)
                )
                pipeline.stop()
            }
        }

        XCTAssertNotNil(weakPipeline)
        XCTAssertEqual(synchronizer.removalCount, 1)
        synchronizer.completeRemoval(didRemove: true)
        drain(executor)
        synchronizer.releaseRemoval()
        try await eventually { weakPipeline == nil }
    }

    func testCompletionAwareProtocolRequirementDefaultsToLegacySynchronousStop() async {
        let legacy: any AudioRenderPipelineProtocol = LegacySynchronousAudioPipeline()
        await legacy.stopAwaitingRendererRemoval()
        XCTAssertEqual((legacy as? LegacySynchronousAudioPipeline)?.stopCount, 1)
        XCTAssertEqual(legacy.diagnostics, .zero)
    }

    func testAllSupportedCodecsStartCompressedAttachBeforeFirstEnqueue() throws {
        for codec in [VPlayerPlayback.AudioCodec.aac, .ac3, .eac3, .mp2] {
            let harness = try makeHarness(codec: codec)
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            compressed.configureReadiness(ready: true, sufficient: true)

            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1, codec: codec))
            }
            compressed.fireReady()
            drain(harness.executor)

            XCTAssertEqual(harness.pipeline.route, .systemCompressed)
            XCTAssertTrue(harness.pipeline.isReadyForPlayback)
            XCTAssertEqual(harness.synchronizer.attachedSnapshot, [compressed.identity])
            XCTAssertEqual(compressed.snapshot.enqueuedFormatIDs, [formatID(for: codec)])
            XCTAssertEqual(harness.synchronizer.operationSnapshot.first, "attach:1")
        }
    }

    func testCompressedRendererStaysCompressedForFiveSecondsWhilePrerollIsInsufficient() throws {
        for codec in [VPlayerPlayback.AudioCodec.aac, .ac3, .eac3, .mp2] {
            let harness = try makeHarness(codec: codec)
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            compressed.configureReadiness(ready: false, sufficient: false)

            for id in 0..<6 {
                try perform(on: harness.executor) {
                    try harness.pipeline.enqueue(try self.makeSample(
                        id: UInt64(id + 1),
                        codec: codec,
                        pts: CMTime(value: Int64(id), timescale: 1),
                        duration: CMTime(value: 1, timescale: 1)
                    ))
                }
            }
            harness.synchronizer.setCurrentTime(CMTime(value: 6, timescale: 1))
            drain(harness.executor)

            XCTAssertEqual(harness.pipeline.route, .systemCompressed, "\(codec)")
            XCTAssertFalse(harness.pipeline.isReadyForPlayback, "\(codec)")
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed], "\(codec)")
            XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty, "\(codec)")
            XCTAssertEqual(harness.synchronizer.removalCount, 0, "\(codec)")
            XCTAssertTrue(harness.failures.snapshot.isEmpty, "\(codec)")

            compressed.configureReadiness(ready: true, sufficient: true)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: 7,
                    codec: codec,
                    pts: CMTime(value: 6, timescale: 1),
                    duration: CMTime(value: 1, timescale: 1)
                ))
            }
            drain(harness.executor)

            XCTAssertTrue(harness.pipeline.isReadyForPlayback, "\(codec)")
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed], "\(codec)")
            XCTAssertEqual(harness.synchronizer.removalCount, 0, "\(codec)")
        }
    }

    func testNotReadyInputStaysPendingAndReadyCallbackDrainsOnlyCapacity() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: false)
        for id in 1...3 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: UInt64(id)))
            }
        }
        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)

        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 2)
        renderer.fireReady()
        drain(harness.executor)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS.count, 2)

        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        renderer.fireReady()
        drain(harness.executor)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS.count, 3)
    }

    func testCompressedEnqueueBackpressureRetainsUnsentHeadWithoutTerminalFailure() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        renderer.configureEnqueueResults([.backpressured, .accepted, .accepted])

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }

        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)
        XCTAssertEqual(harness.pipeline.diagnostics.acceptedCompressedMediaDurationSeconds, 0)
        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            CMTime(value: 1, timescale: 1),
            CMTime(value: 2, timescale: 1),
        ])
        XCTAssertEqual(harness.pipeline.diagnostics.acceptedCompressedMediaDurationSeconds, 2)
        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        XCTAssertEqual(renderer.snapshot.stopRequestCount, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testPCMEnqueueBackpressureRetainsPendingHeadWithoutDataLoss() throws {
        let harness = try makeHarness()
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        let samplePTS = CMTime(value: 3, timescale: 2)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1, pts: samplePTS))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "pcm-backpressure"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)

        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true)
        pcm.configureEnqueueResults([.backpressured, .accepted])
        pcm.fireReady()
        drain(harness.executor)

        XCTAssertTrue(pcm.snapshot.enqueuedPTS.isEmpty)
        XCTAssertEqual(pcm.snapshot.requestCount, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        pcm.fireReady()
        drain(harness.executor)

        XCTAssertEqual(pcm.snapshot.enqueuedPTS, [samplePTS])
        XCTAssertEqual(pcm.snapshot.requestCount, 1)
        XCTAssertEqual(pcm.snapshot.stopRequestCount, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testAutomaticFlushWhileBackpressuredRearmsRequestAndReplaysWhenReady() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        let samplePTS = CMTime(value: 7, timescale: 1)
        renderer.configureReadiness(ready: false)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: samplePTS,
                duration: CMTime(value: 1, timescale: 1)
            ))
        }
        XCTAssertEqual(renderer.snapshot.requestCount, 1)

        renderer.configureReadiness(ready: true)
        renderer.fireReady()
        drain(harness.executor)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [samplePTS])
        XCTAssertEqual(renderer.snapshot.stopRequestCount, 1)

        renderer.configureReadiness(ready: true)
        renderer.configureEnqueueResults([.backpressured, .accepted])
        renderer.emit(.automaticFlush(samplePTS))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.requestCount, 2)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [samplePTS])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        renderer.fireReady()
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [samplePTS, samplePTS])
        XCTAssertEqual(renderer.snapshot.requestCount, 2)
        XCTAssertEqual(renderer.snapshot.stopRequestCount, 2)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReadyCallbackAndNormalEnqueueShareOnePumpWithoutDoubleRegistration() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        renderer.configureEnqueueResults([
            .backpressured, .backpressured, .accepted, .accepted,
        ])

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1)
            ))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1)
            ))
        }

        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)

        renderer.fireReady()
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            CMTime(value: 1, timescale: 1),
            CMTime(value: 2, timescale: 1),
        ])
        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        XCTAssertEqual(renderer.snapshot.stopRequestCount, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testSystemRendererReportsNotReadyAsBackpressure() throws {
        let underlying = AlwaysBackpressuredAVSampleBufferAudioRenderer()
        let renderer = SystemAudioRenderer(
            identity: AudioRendererIdentity(rawValue: 99),
            mediaKind: .compressed,
            renderer: underlying
        )
        let sample = try makeSample(id: 1)

        XCTAssertEqual(try renderer.enqueue(sample.sampleBuffer), .backpressured)
        XCTAssertEqual(underlying.enqueueCount, 0)
    }

    func testSystemRendererDoesNotReregisterActiveMediaRequest() {
        let underlying = AlwaysBackpressuredAVSampleBufferAudioRenderer()
        let renderer = SystemAudioRenderer(
            identity: AudioRendererIdentity(rawValue: 100),
            mediaKind: .compressed,
            renderer: underlying
        )

        renderer.requestMediaDataWhenReady {}
        renderer.requestMediaDataWhenReady {}

        XCTAssertEqual(underlying.requestCount, 1)
        XCTAssertEqual(underlying.stopRequestCount, 0)

        renderer.stopRequestingMediaData()
        renderer.stopRequestingMediaData()

        XCTAssertEqual(underlying.stopRequestCount, 1)
    }

    func testSystemRendererForwardsDemandCallbackButEnqueueIsNotAcknowledgement() throws {
        let underlying = ControllableAVSampleBufferAudioRenderer()
        let renderer = SystemAudioRenderer(
            identity: AudioRendererIdentity(rawValue: 101),
            mediaKind: .compressed,
            renderer: underlying
        )
        let callbacks = LockedAudioCompletionCount()
        renderer.requestMediaDataWhenReady { callbacks.increment() }

        XCTAssertEqual(callbacks.value, 0)
        XCTAssertEqual(
            try renderer.enqueue(makeSample(id: 1).sampleBuffer),
            .accepted
        )
        XCTAssertEqual(underlying.enqueueCount, 1)
        XCTAssertEqual(
            callbacks.value,
            0,
            "enqueue acceptance is not a renderer-consumption acknowledgement"
        )

        underlying.fireReady()
        XCTAssertEqual(callbacks.value, 1)
    }

    func testSynchronizerRejectsNonSystemRendererInsteadOfSilentlyAttaching() {
        let synchronizer: any AudioRenderSynchronizing = SystemAudioSynchronizer(
            AVSampleBufferRenderSynchronizer()
        )
        let renderer = FakeAudioRenderer(identity: 101, mediaKind: .compressed)

        assertCoreError(.audioRendererFailed("audio.renderer.type-mismatch")) {
            try synchronizer.attach(renderer)
        }
    }

    func testActivateContinuityIslandFlushesAndCannotReplayPreviousIsland() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        renderer.configureEnqueueResults([.accepted, .backpressured])

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1)
            ))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1)
            ))
        }
        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        let operationsBeforeActivation = renderer.snapshot.operations.count

        let nextIsland = AudioContinuityIslandID(rawValue: 2)
        try perform(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                nextIsland,
                generation: MediaGeneration(rawValue: 1)
            )
            try harness.pipeline.enqueue(try self.makeSample(
                id: 3,
                pts: CMTime(value: 10, timescale: 1),
                continuityIslandID: nextIsland
            ))
        }

        XCTAssertEqual(renderer.snapshot.stopRequestCount, 1)
        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(
            Array(renderer.snapshot.operations.dropFirst(operationsBeforeActivation)),
            ["stopRequest", "flush", "enqueue"]
        )
        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            CMTime(value: 1, timescale: 1),
            CMTime(value: 10, timescale: 1),
        ])

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            CMTime(value: 1, timescale: 1),
            CMTime(value: 10, timescale: 1),
            CMTime(value: 10, timescale: 1),
        ])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testEnqueueRejectsSampleFromInactiveIsland() throws {
        let harness = try makeHarness()
        let activeIsland = AudioContinuityIslandID(rawValue: 7)
        try perform(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                activeIsland,
                generation: MediaGeneration(rawValue: 1)
            )
        }

        assertCoreError(.audioRendererFailed("audio.island.mismatch")) {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: 1,
                    continuityIslandID: AudioContinuityIslandID(rawValue: 8)
                ))
            }
        }
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testInactiveIslandMismatchPrecedesCodecMismatchForCurrentGeneration() throws {
        let harness = try makeHarness()
        let activeIsland = AudioContinuityIslandID(rawValue: 7)
        try perform(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                activeIsland,
                generation: MediaGeneration(rawValue: 1)
            )
        }

        assertCoreError(.audioRendererFailed("audio.island.mismatch")) {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: 1,
                    codec: .ac3,
                    continuityIslandID: AudioContinuityIslandID(rawValue: 8)
                ))
            }
        }
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testStaleGenerationSampleIsIgnoredBeforeIslandAndCodecValidation() throws {
        let harness = try makeHarness()
        try perform(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 7),
                generation: MediaGeneration(rawValue: 1)
            )
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                codec: .ac3,
                generation: MediaGeneration(rawValue: 2),
                continuityIslandID: AudioContinuityIslandID(rawValue: 8)
            ))
        }

        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testPrepareAnchorReplaysOnlyCurrentIslandAtOrAfterCommonPTS() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 1)
            ))
        }

        let currentIsland = AudioContinuityIslandID(rawValue: 11)
        try perform(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                currentIsland,
                generation: MediaGeneration(rawValue: 1)
            )
            for id in 2...4 {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    pts: CMTime(value: Int64(id - 1), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1),
                    continuityIslandID: currentIsland
                ))
            }
            try harness.pipeline.prepareAnchor(
                at: CMTime(value: 2, timescale: 1),
                in: currentIsland
            )
        }

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            .zero,
            CMTime(value: 1, timescale: 1),
            CMTime(value: 2, timescale: 1),
            CMTime(value: 3, timescale: 1),
            CMTime(value: 2, timescale: 1),
            CMTime(value: 3, timescale: 1),
        ])
        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 2)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testPrepareAnchorForcesResetOnlyOnFirstAcceptedReplayBuffer() throws {
        let harness = try makeResetAttachmentHarness()
        let first = try makeSample(
            id: 1,
            pts: CMTime(value: 1, timescale: 1)
        )
        let second = try makeSample(
            id: 2,
            pts: CMTime(value: 2, timescale: 1)
        )
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(first)
            try harness.pipeline.enqueue(second)
            try harness.pipeline.prepareAnchor(
                at: CMTime(value: 1, timescale: 1),
                in: AudioContinuityIslandID(rawValue: 1)
            )
        }

        XCTAssertEqual(harness.renderer.acceptedResetDecoderSnapshot, [
            false, false, true, false,
        ])
        XCTAssertNil(CMGetAttachment(
            first.sampleBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil
        ))
        XCTAssertNil(CMGetAttachment(
            second.sampleBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil
        ))
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testBackpressuredResetReplayPreservesResetUntilFirstAcceptance() throws {
        let harness = try makeResetAttachmentHarness()
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1)
            ))
        }
        harness.renderer.configureEnqueueResults([.backpressured, .accepted])

        harness.renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)
        XCTAssertEqual(harness.renderer.attemptedResetDecoderSnapshot, [false, true])
        XCTAssertEqual(harness.renderer.acceptedResetDecoderSnapshot, [false])

        harness.renderer.fireReady()
        drain(harness.executor)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1)
            ))
        }

        XCTAssertEqual(harness.renderer.attemptedResetDecoderSnapshot, [
            false, true, true, false,
        ])
        XCTAssertEqual(harness.renderer.acceptedResetDecoderSnapshot, [false, true, false])
        XCTAssertEqual(harness.renderer.requestCountSnapshot, 1)
        XCTAssertEqual(harness.renderer.stopRequestCountSnapshot, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testCompressedRendererRebuildResetsOnlyFirstAcceptedReplayBuffer() throws {
        let harness = try makeResetAttachmentHarness()
        let firstSample = try makeSample(
            id: 1,
            pts: CMTime(value: 1, timescale: 1)
        )
        let secondSample = try makeSample(
            id: 2,
            pts: CMTime(value: 2, timescale: 1)
        )
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(firstSample)
            try harness.pipeline.enqueue(secondSample)
        }

        harness.renderer.emit(.failed("compressed:first"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.renderers.snapshot.count, 1)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)

        XCTAssertEqual(harness.renderers.snapshot.count, 2)
        XCTAssertEqual(replacement.acceptedResetDecoderSnapshot, [true, false])
        XCTAssertNil(CMGetAttachment(
            firstSample.sampleBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil
        ))
        XCTAssertNil(CMGetAttachment(
            secondSample.sampleBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil
        ))
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testStaleGenerationIslandActivationIsIgnored() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1)
            ))
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 99),
                generation: MediaGeneration(rawValue: 2)
            )
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1)
            ))
        }

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            CMTime(value: 1, timescale: 1),
            CMTime(value: 2, timescale: 1),
        ])
        XCTAssertFalse(renderer.snapshot.operations.contains("flush"))
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReadyCallbackStormCoalescesAndStopsRequestingWhenThereIsNoWork() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: false)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1)
            ))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1)
            ))
        }

        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)

        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseExecutor = DispatchSemaphore(value: 0)
        harness.executor.submit {
            blockerEntered.signal()
            _ = releaseExecutor.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2), .success)

        for _ in 0..<100 { renderer.fireReady() }
        releaseExecutor.signal()
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [CMTime(value: 1, timescale: 1)])
        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        XCTAssertEqual(renderer.snapshot.stopRequestCount, 0)

        renderer.fireReady()
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            CMTime(value: 1, timescale: 1),
            CMTime(value: 2, timescale: 1),
        ])
        XCTAssertEqual(renderer.snapshot.requestCount, 1)
        XCTAssertEqual(renderer.snapshot.stopRequestCount, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReplayPreservesUnexpiredSamplesInsteadOfOverwritingThemAtNinetySixPackets() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        for id in 0..<96 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id + 1),
                    pts: CMTime(value: Int64(id), timescale: 10),
                    duration: CMTime(value: 1, timescale: 10)
                ))
            }
        }
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 97,
                pts: CMTime(value: 96, timescale: 10)
            ))
        }

        harness.synchronizer.setCurrentTime(CMTime(value: 15, timescale: 100))
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 98,
                pts: CMTime(value: 97, timescale: 10)
            ))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: renderer,
            in: harness,
            reason: "force-replay-inspection"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)
        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true, sufficient: true)
        pcm.fireReady()
        drain(harness.executor)
        let pushed = try XCTUnwrap(harness.decoderFactory.snapshot.first).pushedIDSnapshot
        XCTAssertEqual(pushed.count, 97)
        XCTAssertEqual(pushed.first, 2)
        XCTAssertEqual(pushed.suffix(2), [97, 98])
        XCTAssertFalse(pushed.contains(1))
        XCTAssertTrue(pushed.contains(2))
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReplayByteBudgetPrunesCompletedHistoryBeforeCountCap() throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 9,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = try makeHarness(
            replayRetentionLimits: limits,
            replayHardCount: 10
        )
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)

        try perform(on: harness.executor) {
            harness.pipeline.updateRecoveryFloor(CMTime(value: 1, timescale: 2))
            for id in 1...3 {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    pts: CMTime(value: Int64(id - 1), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1),
                    payloadBytes: 4
                ))
            }
            XCTAssertEqual(harness.pipeline.retainedReplaySampleIDs, [1, 3])
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 8)
        }

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.enqueuedPTS, [
            .zero,
            CMTime(value: 1, timescale: 1),
            CMTime(value: 2, timescale: 1),
            .zero,
            CMTime(value: 2, timescale: 1),
        ])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReplayBudgetNeverDropsBackpressuredUnsentHead() throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 9,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = try makeHarness(
            replayRetentionLimits: limits,
            replayHardCount: 10
        )
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: false)

        try perform(on: harness.executor) {
            for id in 1...3 {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    pts: CMTime(value: Int64(id - 1), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1),
                    payloadBytes: 4
                ))
            }
            XCTAssertEqual(harness.pipeline.retainedReplaySampleIDs, [1, 2])
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 8)
        }

        XCTAssertTrue(renderer.snapshot.enqueuedPTS.isEmpty)
        XCTAssertEqual(harness.failures.snapshot, [AudioFailureRecord(
            error: .audioRendererFailed(
                CompressedAudioRetentionPolicy.replayCapacityError
            ),
            generation: MediaGeneration(rawValue: 1)
        )])
    }

    func testReplaySoftCountAllowsMandatoryWorkOnlyUntilInjectedHardCount() throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 2,
            maximumOwnedBytes: 100,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = try makeHarness(
            replayRetentionLimits: limits,
            replayHardCount: 3
        )
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: false)

        try perform(on: harness.executor) {
            for id in 1...4 {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    pts: CMTime(value: Int64(id - 1), timescale: 10),
                    duration: CMTime(value: 1, timescale: 10)
                ))
            }
            XCTAssertEqual(harness.pipeline.retainedReplaySampleIDs, [1, 2, 3])
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 6)
        }
        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioRendererFailed(CompressedAudioRetentionPolicy.replayCapacityError),
        ])
    }

    func testReplayTimeHorizonKeepsLatestCompletedTailAndFloorProtector() throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 100,
            latestTailHorizon: CMTime(value: 2, timescale: 1)
        )
        let harness = try makeHarness(
            replayRetentionLimits: limits,
            replayHardCount: 10
        )
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)

        try perform(on: harness.executor) {
            harness.pipeline.updateRecoveryFloor(CMTime(value: 1, timescale: 2))
            for id in 1...4 {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    pts: CMTime(value: Int64(id - 1), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1),
                    payloadBytes: 2
                ))
            }
            XCTAssertEqual(harness.pipeline.retainedReplaySampleIDs, [1, 3, 4])
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 6)
        }
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReplayAccountingCountsCMSampleBufferCopyNotSourceDataSharingAssumption() throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 100,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        var continuity = AudioContinuityBuffer(retentionLimits: limits)
        let frame = CompressedAudioFrame(
            id: 1,
            payload: Data(repeating: 0xA5, count: 4),
            codec: .aac,
            generation: MediaGeneration(rawValue: 1),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 1),
            frameSampleCount: 1_024
        )
        let admitted: AdmittedAudioFrame
        switch try continuity.admit(frame) {
        case let .admitted(value): admitted = value
        case let .dropped(reason):
            return XCTFail("unexpected continuity drop: \(reason)")
        }
        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: admitted,
            formatDescription: makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        )
        let sample = CompressedAudioSample(
            id: 1,
            sampleBuffer: sampleBuffer,
            codec: .aac,
            generation: MediaGeneration(rawValue: 1),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 1),
            continuityIslandID: admitted.continuityIslandID,
            effectiveCoverageStartPTS: admitted.effectiveCoverageStartPTS
        )
        let continuityBytes = continuity.retainedPayloadBytes
        let harness = try makeHarness(replayRetentionLimits: limits)

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(sample)
            XCTAssertEqual(continuityBytes, 4)
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 4)
            XCTAssertEqual(
                continuityBytes + harness.pipeline.retainedReplayPayloadBytes,
                8
            )
        }
    }

    func testPrepareAnchorRejectsCommonPTSOutsideActualReplayCoverageBeforeFlush() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }
        let baselineFlushCount = renderer.snapshot.operations.filter { $0 == "flush" }.count

        assertCoreError(.audioRendererFailed(
            CompressedAudioRetentionPolicy.unretainedAnchorError
        )) {
            try perform(on: harness.executor) {
                try harness.pipeline.prepareAnchor(
                    at: CMTime(value: 2, timescale: 1),
                    in: AudioContinuityIslandID(rawValue: 1)
                )
            }
        }

        XCTAssertEqual(
            renderer.snapshot.operations.filter { $0 == "flush" }.count,
            baselineFlushCount
        )
    }

    func testReplayShortGapFillUsesEffectiveHalfOpenCoverage() throws {
        var continuity = AudioContinuityBuffer()
        let format = try makeFormat(codec: .aac)
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        let floor = CMTime(value: 11, timescale: 10)

        var samples: [CompressedAudioSample] = []
        for (id, pts) in [
            (UInt64(1), CMTime.zero),
            (UInt64(2), CMTime(value: 12, timescale: 10)),
        ] {
            let frame = CompressedAudioFrame(
                id: id,
                payload: Data(repeating: UInt8(id), count: 2),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: pts,
                duration: CMTime(value: 1, timescale: 1),
                frameSampleCount: 1_024
            )
            let admitted: AdmittedAudioFrame
            switch try continuity.admit(frame) {
            case let .admitted(value): admitted = value
            case let .dropped(reason):
                return XCTFail("unexpected continuity drop: \(reason)")
            }
            samples.append(CompressedAudioSample(
                id: id,
                sampleBuffer: try SampleBufferBuilder.makeAudio(
                    frame: admitted,
                    formatDescription: format,
                    forceResetDecoderBeforeDecoding: false
                ),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: admitted.normalizedPresentationTimeStamp,
                duration: admitted.duration,
                continuityIslandID: admitted.continuityIslandID,
                effectiveCoverageStartPTS: admitted.effectiveCoverageStartPTS
            ))
        }
        XCTAssertNotNil(continuity.anchorCandidate(at: floor))
        let replaySamples = samples

        try perform(on: harness.executor) {
            for sample in replaySamples { try harness.pipeline.enqueue(sample) }
            harness.pipeline.updateRecoveryFloor(floor)
            try harness.pipeline.prepareAnchor(
                at: floor,
                in: AudioContinuityIslandID(rawValue: 1)
            )
        }
        XCTAssertGreaterThan(
            renderer.snapshot.operations.filter { $0 == "flush" }.count,
            0
        )
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReplayShortGapKeepsEffectiveCoverageWhenPreviousFrameExpiresAtFloor() throws {
        var continuity = AudioContinuityBuffer()
        let format = try makeFormat(codec: .aac)
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        let floor = CMTime(value: 11, timescale: 10)

        var samples: [CompressedAudioSample] = []
        for (id, pts) in [
            (UInt64(1), CMTime.zero),
            (UInt64(2), CMTime(value: 12, timescale: 10)),
        ] {
            let frame = CompressedAudioFrame(
                id: id,
                payload: Data(repeating: UInt8(id), count: 2),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: pts,
                duration: CMTime(value: 1, timescale: 1),
                frameSampleCount: 1_024
            )
            let admitted: AdmittedAudioFrame
            switch try continuity.admit(frame) {
            case let .admitted(value): admitted = value
            case let .dropped(reason):
                return XCTFail("unexpected continuity drop: \(reason)")
            }
            samples.append(CompressedAudioSample(
                id: id,
                sampleBuffer: try SampleBufferBuilder.makeAudio(
                    frame: admitted,
                    formatDescription: format,
                    forceResetDecoderBeforeDecoding: false
                ),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: admitted.normalizedPresentationTimeStamp,
                duration: admitted.duration,
                continuityIslandID: admitted.continuityIslandID,
                effectiveCoverageStartPTS: admitted.effectiveCoverageStartPTS
            ))
        }
        XCTAssertNotNil(continuity.anchorCandidate(at: floor))
        let replaySamples = samples

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(replaySamples[0])
        }
        harness.synchronizer.setCurrentTime(floor)
        try perform(on: harness.executor) {
            harness.pipeline.updateRecoveryFloor(floor)
            try harness.pipeline.enqueue(replaySamples[1])
            try harness.pipeline.prepareAnchor(
                at: floor,
                in: AudioContinuityIslandID(rawValue: 1)
            )
        }

        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testShortGapCoverageSurvivesRecoveryPruningBeforeFollowingSampleArrives()
        throws {
        var continuity = AudioContinuityBuffer()
        let format = try makeFormat(codec: .aac)
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        let floorInsideGap = CMTime(value: 11, timescale: 10)

        func sample(
            id: UInt64,
            pts: CMTime
        ) throws -> CompressedAudioSample {
            let frame = CompressedAudioFrame(
                id: id,
                payload: Data(repeating: UInt8(id), count: 2),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: pts,
                duration: CMTime(value: 1, timescale: 1),
                frameSampleCount: 1_024
            )
            let admitted: AdmittedAudioFrame
            switch try continuity.admit(frame) {
            case let .admitted(value): admitted = value
            case let .dropped(reason):
                XCTFail("unexpected continuity drop: \(reason)")
                throw PlaybackCoreError.audioRendererFailed("test.continuity.drop")
            }
            return CompressedAudioSample(
                id: id,
                sampleBuffer: try SampleBufferBuilder.makeAudio(
                    frame: admitted,
                    formatDescription: format,
                    forceResetDecoderBeforeDecoding: false
                ),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                presentationTimeStamp: admitted.normalizedPresentationTimeStamp,
                duration: admitted.duration,
                continuityIslandID: admitted.continuityIslandID,
                effectiveCoverageStartPTS: admitted.effectiveCoverageStartPTS
            )
        }

        let firstSample = try sample(id: 1, pts: .zero)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(firstSample)
            XCTAssertEqual(harness.pipeline.retainedReplaySampleIDs, [1])
        }

        harness.synchronizer.setCurrentTime(floorInsideGap)
        renderer.emit(.automaticFlush(floorInsideGap))
        drain(harness.executor)
        try perform(on: harness.executor) {
            XCTAssertEqual(
                harness.pipeline.retainedReplaySampleIDs,
                [],
                "automatic recovery must remove A before B supplies its gap coverage"
            )
        }

        let secondSample = try sample(
            id: 2,
            pts: CMTime(value: 12, timescale: 10)
        )
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(secondSample)
            harness.pipeline.updateRecoveryFloor(floorInsideGap)
            try harness.pipeline.prepareAnchor(
                at: floorInsideGap,
                in: AudioContinuityIslandID(rawValue: 1)
            )
        }

        assertCoreError(.audioRendererFailed(
            CompressedAudioRetentionPolicy.unretainedAnchorError
        )) {
            try perform(on: harness.executor) {
                try harness.pipeline.prepareAnchor(
                    at: CMTime(value: 22, timescale: 10),
                    in: AudioContinuityIslandID(rawValue: 1)
                )
            }
        }
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testActivateContinuityIslandFlushesAndCannotReplayPreviousIslandAfterByteCap() throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 4,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = try makeHarness(
            replayRetentionLimits: limits,
            replayHardCount: 10
        )
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        let nextIsland = AudioContinuityIslandID(rawValue: 2)

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 1),
                payloadBytes: 4
            ))
            harness.pipeline.activateContinuityIsland(
                nextIsland,
                generation: MediaGeneration(rawValue: 1)
            )
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 0)
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 1, timescale: 1),
                continuityIslandID: nextIsland,
                payloadBytes: 4
            ))
            XCTAssertEqual(harness.pipeline.retainedReplaySampleIDs, [2])
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 4)
        }

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS.suffix(1), [
            CMTime(value: 1, timescale: 1),
        ])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReplayClearPathsResetByteCounter() throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 4,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = try makeHarness(replayRetentionLimits: limits)
        let firstRenderer = try XCTUnwrap(harness.renderers.snapshot.first)
        firstRenderer.configureReadiness(ready: true)

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1, payloadBytes: 4))
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 4)
            harness.pipeline.flush(to: MediaGeneration(rawValue: 2))
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 0)

            let secondIsland = AudioContinuityIslandID(rawValue: 2)
            harness.pipeline.activateContinuityIsland(
                secondIsland,
                generation: MediaGeneration(rawValue: 2)
            )
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                generation: MediaGeneration(rawValue: 2),
                continuityIslandID: secondIsland,
                payloadBytes: 4
            ))
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 3),
                generation: MediaGeneration(rawValue: 2)
            )
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 0)

            try harness.pipeline.enqueue(try self.makeSample(
                id: 3,
                generation: MediaGeneration(rawValue: 2),
                continuityIslandID: AudioContinuityIslandID(rawValue: 3),
                payloadBytes: 4
            ))
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 3),
                fingerprint: self.fingerprint(3)
            )
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 0)

            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 4),
                generation: MediaGeneration(rawValue: 3)
            )
            try harness.pipeline.enqueue(try self.makeSample(
                id: 4,
                generation: MediaGeneration(rawValue: 3),
                continuityIslandID: AudioContinuityIslandID(rawValue: 4),
                payloadBytes: 4
            ))
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 4)
            harness.pipeline.stop()
            XCTAssertEqual(harness.pipeline.retainedReplayPayloadBytes, 0)
        }
    }

    func testAsyncFailureWaitsForSuccessfulRemovalThenReplaysPCMAndAnchorsExactlyOnce() throws {
        let harness = try makeHarness()
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        compressed.configureReadiness(ready: true)
        let sample = try makeSample(
            id: 44,
            pts: CMTime(value: 1001, timescale: 30000),
            duration: CMTime(value: 1024, timescale: 48000)
        )
        try perform(on: harness.executor) { try harness.pipeline.enqueue(sample) }
        compressed.fireReady()
        drain(harness.executor)

        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "AVFoundationErrorDomain:-11800"
        )
        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertEqual(harness.renderers.snapshot.count, 2, "PCM replacement must wait for removal")
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.0, 0)
        XCTAssertEqual(transition.retryRenderer.snapshot.stopRequestCount, 1)
        XCTAssertEqual(transition.retryRenderer.snapshot.observationStopCount, 1)

        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)
        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true, sufficient: true)
        pcm.fireReady()
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.synchronizer.attachedSnapshot, [
            compressed.identity, transition.retryRenderer.identity, pcm.identity,
        ])
        XCTAssertEqual(compressed.snapshot.enqueuedFormatIDs, [kAudioFormatMPEG4AAC])
        XCTAssertEqual(
            pcm.snapshot.enqueuedFormatIDs,
            [kAudioFormatLinearPCM],
            "fallback renderer did not become ready"
        )
        XCTAssertEqual(harness.decoderFactory.snapshot.first?.pushedIDSnapshot, [44])
        XCTAssertEqual(pcm.snapshot.enqueuedPTS, [sample.presentationTimeStamp])
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.0, 1)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.1, sample.presentationTimeStamp)
    }

    func testPCMQuarterSecondPrerollBecomesReadyWhenRendererBackpressuresBeforeSufficientFlag() throws {
        let harness = try makeHarness()
        harness.decoderFactory.pushBody = { sample in
            [try self.makePCMBuffer(pts: sample.presentationTimeStamp, frameCount: 1_024)]
        }
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        let packetDuration = CMTime(value: 1_024, timescale: 48_000)
        for index in 0..<12 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(index + 1),
                    pts: CMTimeMultiply(packetDuration, multiplier: Int32(index)),
                    duration: packetDuration
                ))
            }
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-pcm-preroll"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)

        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(
            ready: true,
            sufficient: false,
            maximumEnqueuesPerCallback: 12
        )
        pcm.fireReady()
        drain(harness.executor)

        XCTAssertEqual(pcm.snapshot.enqueuedPTS.count, 12)
        XCTAssertTrue(
            harness.pipeline.isReadyForPlayback,
            "a contiguous 256 ms PCM preroll must break the paused-clock backpressure deadlock"
        )
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testPCMRouteDropsOneInvalidCompressedPacketAndContinuesDecoding() throws {
        let harness = try makeHarness()
        let invalidPacketError: Int32 = -1_094_995_529
        harness.decoderFactory.pushBody = { sample in
            if sample.id == 2 {
                throw PlaybackCoreError.audioFallbackDecode(invalidPacketError)
            }
            return [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
        }
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        for id in 1...3 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: UInt64(id)))
            }
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-pcm-invalid-packet"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)

        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.first)
        XCTAssertEqual(decoder.pushedIDSnapshot, [1, 2, 3])
        XCTAssertEqual(decoder.flushCountSnapshot, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
    }

    func testPCMRouteTerminatesOnNinthConsecutiveInvalidCompressedPacket() throws {
        let harness = try makeHarness()
        let invalidPacketError: Int32 = -1_094_995_529
        harness.decoderFactory.pushBody = { _ in
            throw PlaybackCoreError.audioFallbackDecode(invalidPacketError)
        }
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        for id in 1...9 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: UInt64(id)))
            }
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-pcm-invalid-packets"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)

        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.first)
        XCTAssertEqual(decoder.pushedIDSnapshot, Array(1...9))
        XCTAssertEqual(decoder.flushCountSnapshot, 8)
        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioFallbackDecode(invalidPacketError),
        ])
    }

    func testFalseRemovalAndDecoderAndSecondRendererFailuresEachEmitOneExactError() throws {
        do {
            let harness = try makeHarness()
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }
            let transition = try beginFallbackAfterCompressedRetry(
                initialRenderer: compressed,
                in: harness,
                reason: "renderer:-1"
            )
            XCTAssertEqual(harness.synchronizer.removalCount, 2)
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
                .compressed, .compressed,
            ])
            XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)

            harness.synchronizer.completeRemoval(
                index: transition.removalIndex,
                didRemove: false
            )
            drain(harness.executor)
            harness.synchronizer.completeRemoval(
                index: transition.removalIndex,
                didRemove: false
            )
            drain(harness.executor)

            XCTAssertEqual(harness.failures.snapshot.map(\.error), [
                .audioRendererFailed(AudioRenderPipeline.removalFailedError),
            ])
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
                .compressed, .compressed,
            ])
            XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
            XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        }

        do {
            let harness = try makeHarness()
            harness.decoderFactory.createError = .audioFallbackDecode(-12_345)
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }
            let transition = try beginFallbackAfterCompressedRetry(
                initialRenderer: compressed,
                in: harness,
                reason: "renderer:-1"
            )
            harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
            drain(harness.executor)
            XCTAssertEqual(harness.failures.snapshot.map(\.error), [.audioFallbackDecode(-12_345)])
        }

        do {
            let harness = try makeHarness()
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }
            let transition = try beginFallbackAfterCompressedRetry(
                initialRenderer: compressed,
                in: harness,
                reason: "renderer:-1"
            )
            harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
            drain(harness.executor)
            let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
            pcm.emit(.failed("PCMDomain:-9"))
            pcm.emit(.failed("PCMDomain:-9"))
            compressed.emit(.failed("stale"))
            drain(harness.executor)
            XCTAssertEqual(harness.failures.snapshot.map(\.error), [
                .audioRendererFailed("PCMDomain:-9"),
            ])
        }
    }

    func testAutomaticFlushOutputAndRouteSignalsRecoverExactlyOnceOnCompressedRenderer() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        for id in 1...3 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id), pts: CMTime(value: Int64(id), timescale: 1)
                ))
            }
        }
        renderer.fireReady()
        drain(harness.executor)

        renderer.emit(.outputConfigurationChanged)
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 1
        ))
        renderer.emit(.automaticFlush(CMTime(value: 2, timescale: 1)))
        drain(harness.executor)

        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(harness.pipeline.recoveryCount, 1)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testSecondAutomaticFlushBeforeDeadlineDoesNotReplayOrRebuild() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let initialEnqueueCount = renderer.snapshot.enqueuedPTS.count

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        let firstReplayCount = renderer.snapshot.enqueuedPTS.count
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)

        XCTAssertEqual(firstReplayCount, initialEnqueueCount + 1)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS.count, firstReplayCount)
        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
    }

    func testOutputConfigurationCorrelatedWithAutomaticFlushDoesNotReplayBeforeProgressDeadline() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        let replayedCount = renderer.snapshot.enqueuedPTS.count
        renderer.emit(.outputConfigurationChanged)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.enqueuedPTS.count, replayedCount)
        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(harness.pipeline.recoveryCount, 1)
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
    }

    func testDeadlineWithoutMediaProgressRebuildsCompressedRendererOnce() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 1)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
        guard harness.synchronizer.removalCount == 1 else { return }
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testSharedSynchronizerAdvanceAfterAutomaticFlushStillRebuildsCompressed() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)

        harness.synchronizer.setCurrentTime(CMTime(value: 1, timescale: 2))
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testNewAcceptedInputAfterAutomaticFlushStillRebuildsWithoutRendererConsumption()
        throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 1)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
    }

    func testSilentAlwaysAcceptingRendererCannotClearAutomaticFlushBaseline() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true, sufficient: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)

        harness.synchronizer.setCurrentTime(CMTime(value: 1, timescale: 2))
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 1)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testPostReplayBackpressureThenCurrentReadyKeepsCompressed() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10)
            ))
        }
        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        XCTAssertTrue(harness.pipeline.diagnostics.rendererRequestArmed)

        renderer.fireReady()
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 0)
        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 0)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testImmediateReadyWithoutPostResetAcceptanceAndBackpressureIsNotConsumption()
        throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: false)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 10, timescale: 1)
            ))
        }

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        renderer.configureReadiness(ready: true)
        renderer.fireReady()
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 1)
    }

    func testReadyCallbackCapturedBeforeRecoveryFlushCannotClearNewBaseline() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10),
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        let staleReady = try XCTUnwrap(renderer.captureReadyHandler())
        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        staleReady()
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 1)
    }

    func testStaleReadyCannotSuppressCurrentCallbackWhileExecutorIsBlocked() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10)
            ))
        }
        let staleReady = try XCTUnwrap(renderer.captureReadyHandler())

        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        let currentReady = try XCTUnwrap(renderer.captureReadyHandler())

        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseExecutor = DispatchSemaphore(value: 0)
        harness.executor.submit {
            blockerEntered.signal()
            _ = releaseExecutor.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2), .success)

        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        staleReady()
        for _ in 0..<100 { currentReady() }
        releaseExecutor.signal()
        drain(harness.executor)

        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(
            renderer.snapshot.enqueuedPTS.filter {
                $0 == CMTime(value: 2, timescale: 10)
            }.count,
            1,
            "the current registration must process its callback storm exactly once"
        )
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 0)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testCurrentReadyStormCannotBePerturbedByLaterStaleCallbacks() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10)
            ))
        }
        let staleReady = try XCTUnwrap(renderer.captureReadyHandler())

        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        let currentReady = try XCTUnwrap(renderer.captureReadyHandler())

        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseExecutor = DispatchSemaphore(value: 0)
        harness.executor.submit {
            blockerEntered.signal()
            _ = releaseExecutor.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2), .success)

        renderer.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        for _ in 0..<100 { currentReady() }
        for _ in 0..<100 { staleReady() }
        releaseExecutor.signal()
        drain(harness.executor)

        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(
            renderer.snapshot.enqueuedPTS.filter {
                $0 == CMTime(value: 2, timescale: 10)
            }.count,
            1
        )
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
        XCTAssertEqual(harness.pipeline.diagnostics.automaticFlushNoProgressCount, 0)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReplacementNoProgressFallsBackOnlyAfterItsOwnDeadline() throws {
        let harness = try makeHarness()
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        original.emit(.automaticFlush(.zero))
        drain(harness.executor)

        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        guard harness.synchronizer.removalCount == 1 else { return }
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.configureReadiness(ready: true)
        replacement.fireReady()
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        harness.recoveryScheduler.advance(by: .milliseconds(999))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        harness.recoveryScheduler.advance(by: .milliseconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        guard harness.synchronizer.removalCount == 2 else { return }
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(
            harness.pipeline.diagnostics.lastFallbackReason,
            .compressedRendererNoProgressAfterRebuild
        )
    }

    func testProgressDeadlineTicketExhaustionTerminatesWithoutPCMOrCrash() throws {
        let harness = try makeHarness(progressDeadlineTicketStart: UInt64.max)
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 10, timescale: 1)
            ))
        }

        original.emit(.automaticFlush(.zero))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioRendererFailed(AudioRenderPipeline.progressTicketExhaustedError),
        ])
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed,
            .compressed,
        ])
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.pcmFallbackCount, 0)
    }

    func testReplacementSharedClockAndInputMotionStillFallsBackAtItsDeadline() throws {
        let harness = try makeHarness()
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        original.emit(.automaticFlush(.zero))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.configureReadiness(ready: true)
        replacement.fireReady()
        drain(harness.executor)

        harness.synchronizer.setCurrentTime(CMTime(value: 1, timescale: 2))
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 10, timescale: 1)
            ))
        }
        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(
            harness.pipeline.diagnostics.lastFallbackReason,
            .compressedRendererNoProgressAfterRebuild
        )
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
    }

    func testAutomaticFlushWithoutLocalMediaNeverConsumesRebuildBudget() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)

        renderer.emit(.automaticFlush(.zero))
        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(2))
        drain(harness.executor)

        XCTAssertTrue(renderer.snapshot.operations.filter { $0 == "flush" }.isEmpty)
        XCTAssertEqual(harness.pipeline.recoveryCount, 0)
        XCTAssertEqual(harness.synchronizer.removalCount, 0)

        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        renderer.emit(.failed("after-empty-flush:-1"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
    }

    func testAutomaticFlushPrunesExpiredOnlyReplayBeforeStartingProgressAttempt() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 1)
            ))
        }
        harness.synchronizer.setCurrentTime(CMTime(value: 2, timescale: 1))
        let readsBeforeRecovery = harness.synchronizer.currentTimeReadCount

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(
            harness.synchronizer.currentTimeReadCount - readsBeforeRecovery,
            1,
            "the replay eligibility check and recovery must share one playhead capture"
        )
        XCTAssertEqual(harness.pipeline.recoveryCount, 0)
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 0)

        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 0)

        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            ))
        }
        renderer.emit(.failed("fresh:first"))
        drain(harness.executor)

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertTrue(harness.decoderFactory.snapshot.isEmpty)
    }

    func testRendererFailureAndNoProgressShareOneRebuildBudget() throws {
        let harness = try makeHarness()
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }

        original.emit(.failed("first:-1"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.configureReadiness(ready: true)
        replacement.fireReady()
        drain(harness.executor)

        harness.recoveryScheduler.advance(by: .seconds(1))
        drain(harness.executor)

        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        guard harness.synchronizer.removalCount == 2 else { return }
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [
            .compressed, .compressed, .linearPCM,
        ])
        XCTAssertEqual(harness.pipeline.diagnostics.compressedRendererRetryCount, 1)
    }

    func testReplacementConstructionOrAttachFailureFallsBackWithoutRemovingMissingRenderer() throws {
        for failure in ["create", "attach"] {
            let harness = try makeHarness()
            let original = try XCTUnwrap(harness.renderers.snapshot.first)
            original.configureReadiness(ready: true)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }
            original.emit(.failed("original:\(failure)"))
            drain(harness.executor)
            if failure == "create" {
                harness.renderers.configureNextCreateError(
                    .audioRendererFailed("replacement.create"),
                    for: .compressed
                )
            } else {
                harness.synchronizer.configureNextAttachError(
                    .audioRendererFailed("replacement.attach")
                )
            }

            harness.synchronizer.completeRemoval(index: 0, didRemove: true)
            drain(harness.executor)

            XCTAssertEqual(harness.synchronizer.removalCount, 1)
            XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
            XCTAssertEqual(harness.renderers.snapshot.last?.mediaKind, .linearPCM)
            XCTAssertEqual(harness.decoderFactory.snapshot.count, 1)
            XCTAssertTrue(harness.failures.snapshot.isEmpty)
        }
    }

    func testInitialCompressedAttachFailureRollsBackUnattachedCandidate() throws {
        let harness = try makeHarness(configure: false)
        let expected = PlaybackCoreError.audioRendererFailed("initial.compressed.attach")
        harness.synchronizer.configureNextAttachError(expected)

        assertCoreError(expected) {
            try perform(on: harness.executor) {
                try harness.pipeline.configure(
                    format: try self.makeFormat(codec: .aac),
                    codec: .aac,
                    generation: MediaGeneration(rawValue: 1),
                    fingerprint: self.fingerprint(1)
                )
            }
        }

        let candidate = try XCTUnwrap(harness.renderers.snapshot.first)
        XCTAssertEqual(candidate.snapshot.observationStartCount, 1)
        XCTAssertEqual(candidate.snapshot.observationStopCount, 1)
        XCTAssertNil(candidate.captureEventHandler())
        XCTAssertTrue(harness.synchronizer.attachedSnapshot.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        performWithoutThrow(on: harness.executor) { harness.pipeline.stop() }
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
    }

    func testUnavailableDecoderPCMRendererCreateFailureDestroysStagedDecoder() throws {
        let harness = makeCapabilityHarness()
        harness.decodeCapability.supported = false
        let expected = PlaybackCoreError.audioRendererFailed("initial.pcm.create")
        harness.renderers.configureNextCreateError(expected, for: .linearPCM)

        assertCoreError(expected) {
            try perform(on: harness.executor) {
                try harness.pipeline.configure(
                    self.makeRenderConfiguration(
                        codec: .aac,
                        extradata: Data([0x12, 0x10]),
                        fingerprint: self.fingerprint(1)
                    ),
                    generation: MediaGeneration(rawValue: 1)
                )
            }
        }

        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.first)
        XCTAssertEqual(decoder.destroyCountSnapshot, 1)
        XCTAssertTrue(harness.renderers.snapshot.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        performWithoutThrow(on: harness.executor) { harness.pipeline.stop() }
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
        XCTAssertEqual(decoder.destroyCountSnapshot, 1)
    }

    func testUnavailableDecoderPCMRendererAttachFailureRollsBackStagedResources() throws {
        let harness = makeCapabilityHarness()
        harness.decodeCapability.supported = false
        let expected = PlaybackCoreError.audioRendererFailed("initial.pcm.attach")
        harness.synchronizer.configureNextAttachError(expected)

        assertCoreError(expected) {
            try perform(on: harness.executor) {
                try harness.pipeline.configure(
                    self.makeRenderConfiguration(
                        codec: .aac,
                        extradata: Data([0x12, 0x10]),
                        fingerprint: self.fingerprint(1)
                    ),
                    generation: MediaGeneration(rawValue: 1)
                )
            }
        }

        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.first)
        let candidate = try XCTUnwrap(harness.renderers.snapshot.first)
        XCTAssertEqual(decoder.destroyCountSnapshot, 1)
        XCTAssertEqual(candidate.snapshot.observationStopCount, 1)
        XCTAssertNil(candidate.captureEventHandler())
        XCTAssertTrue(harness.synchronizer.attachedSnapshot.isEmpty)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        performWithoutThrow(on: harness.executor) { harness.pipeline.stop() }
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
        XCTAssertEqual(decoder.destroyCountSnapshot, 1)
    }

    func testPCMFallbackAttachFailureRollsBackStagedResourcesAndEmitsExactError() throws {
        let harness = try makeHarness()
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: original,
            in: harness,
            reason: "fallback-attach"
        )
        let expected = PlaybackCoreError.audioRendererFailed("fallback.pcm.attach")
        harness.synchronizer.configureNextAttachError(expected)

        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)

        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.first)
        let candidate = try XCTUnwrap(harness.renderers.snapshot.last)
        XCTAssertEqual(candidate.mediaKind, .linearPCM)
        XCTAssertEqual(candidate.snapshot.observationStopCount, 1)
        XCTAssertNil(candidate.captureEventHandler())
        XCTAssertEqual(decoder.destroyCountSnapshot, 1)
        XCTAssertEqual(harness.failures.snapshot, [
            AudioFailureRecord(error: expected, generation: MediaGeneration(rawValue: 1)),
        ])

        performWithoutThrow(on: harness.executor) { harness.pipeline.stop() }
        XCTAssertEqual(harness.synchronizer.removalCount, 2)
        XCTAssertEqual(decoder.destroyCountSnapshot, 1)
    }

    func testUnavailableLocalSystemDecoderStartsDirectlyOnPCM() throws {
        let harness = makeCapabilityHarness(initialRouteCategory: .hdmi)
        harness.decodeCapability.supported = false

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                self.makeRenderConfiguration(
                    codec: .aac,
                    extradata: Data([0xDE, 0xAD]),
                    fingerprint: self.fingerprint(1)
                ),
                generation: MediaGeneration(rawValue: 1)
            )
        }

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.linearPCM])
        XCTAssertEqual(harness.decoderFactory.creationSnapshot.map(\.extradata), [Data([0xDE, 0xAD])])
        XCTAssertEqual(harness.pipeline.diagnostics.lastFallbackReason, .systemDecoderUnavailable)
        XCTAssertEqual(harness.decodeCapability.formatIDSnapshot, [kAudioFormatMPEG4AAC])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testAvailableLocalDecoderStartsCompressedRegardlessOfOutputRoute() throws {
        for category in [AudioOutputRouteCategory.hdmi, .airPlay, .other, .none] {
            let harness = makeCapabilityHarness(initialRouteCategory: category)
            harness.decodeCapability.supported = true

            try perform(on: harness.executor) {
                try harness.pipeline.configure(
                    self.makeRenderConfiguration(
                        codec: .aac,
                        extradata: Data([0xCA, 0xFE]),
                        fingerprint: self.fingerprint(1)
                    ),
                    generation: MediaGeneration(rawValue: 1)
                )
            }

            XCTAssertEqual(harness.pipeline.route, .systemCompressed)
            XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
            XCTAssertTrue(harness.decoderFactory.creationSnapshot.isEmpty)
            XCTAssertEqual(harness.decodeCapability.formatIDSnapshot, [kAudioFormatMPEG4AAC])
        }
    }

    func testPCMDecoderReceivesOriginalExtradataNotSystemMagicCookie() throws {
        let sourceExtradata = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let harness = makeCapabilityHarness()
        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                self.makeRenderConfiguration(
                    codec: .aac,
                    extradata: sourceExtradata,
                    fingerprint: self.fingerprint(1)
                ),
                generation: MediaGeneration(rawValue: 1)
            )
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
        }
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        original.emit(.failed("first:-1"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.emit(.failed("second:-2"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.decoderFactory.creationSnapshot.map(\.extradata), [sourceExtradata])
        XCTAssertNotEqual(sourceExtradata, Data([0x11, 0x90]))
    }

    func testPCMValidatorChecksEveryDecodedOutputDescription() throws {
        let harness = makeCapabilityHarness()
        harness.decoderFactory.pushBody = { sample in
            [
                try self.makePCMBuffer(pts: sample.presentationTimeStamp),
                try self.makePCMBuffer(pts: CMTimeAdd(
                    sample.presentationTimeStamp,
                    CMTime(value: 1, timescale: 48_000)
                )),
            ]
        }
        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                self.makeRenderConfiguration(
                    codec: .aac,
                    extradata: Data([0x12, 0x10]),
                    fingerprint: self.fingerprint(1)
                ),
                generation: MediaGeneration(rawValue: 1)
            )
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
        }
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        original.emit(.failed("first:-1"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.emit(.failed("second:-2"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 1, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.pcmValidator.formatIDSnapshot, [
            kAudioFormatLinearPCM,
            kAudioFormatLinearPCM,
        ])
    }

    func testRunningRendererKeepsReadinessAcrossPrerollDipsAndAutomaticFlushes() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.preroll-latch")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { sample in
            [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
        }
        let readiness = LockedAudioReadinessChanges(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { _, _ in },
            rendererFactory: renderers,
            decoderFactory: decoderFactory,
            routeMonitor: FakeAudioRouteMonitor(),
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            clockMode: .externallyManaged,
            readinessSink: { change, generation in
                readiness.append(change, generation: generation)
            }
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
        }
        let renderer = try XCTUnwrap(renderers.snapshot.first)
        renderer.configureReadiness(ready: true, sufficient: true)
        for id in 1...4 {
            try perform(on: executor) {
                try pipeline.enqueue(try self.makeSample(
                    id: UInt64(id), pts: CMTime(value: Int64(id), timescale: 1)
                ))
            }
        }
        renderer.fireReady()
        drain(executor)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])

        // A running renderer keeps flipping its startup-preroll indicator as it
        // consumes what it holds, and AVFoundation flushes it automatically from
        // time to time. Neither is a loss of audio: the pipeline refills the same
        // renderer from `replay`. Reporting these as invalidations closed the
        // playback readiness gate several times a second.
        for _ in 0..<10 {
            renderer.configureReadiness(ready: true, sufficient: false)
            renderer.fireReady()
            drain(executor)
            renderer.emit(.automaticFlush(CMTime(value: 2, timescale: 1)))
            drain(executor)
            renderer.configureReadiness(ready: true, sufficient: true)
            renderer.fireReady()
            drain(executor)
        }

        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
    }

    func testPrepareAnchorInvalidatesRunningTimelineReadinessUntilRendererReprerolls() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.anchor-preroll")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let readiness = LockedAudioReadinessChanges(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { _, _ in },
            rendererFactory: renderers,
            decoderFactory: FakePCMAudioDecoderFactory { sample in
                [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
            },
            routeMonitor: FakeAudioRouteMonitor(),
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            clockMode: .externallyManaged,
            readinessSink: { change, generation in
                readiness.append(change, generation: generation)
            }
        )
        let generation = MediaGeneration(rawValue: 1)
        let island = AudioContinuityIslandID(rawValue: 1)
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: generation,
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(island, generation: generation)
        }
        let renderer = try XCTUnwrap(renderers.snapshot.first)
        renderer.configureReadiness(ready: true, sufficient: true)
        try perform(on: executor) {
            try pipeline.enqueue(try self.makeSample(
                id: 1,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 2)
            ))
        }
        XCTAssertTrue(pipeline.isReadyForPlayback)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        try perform(on: executor) {
            pipeline.setSharedTimelineOpened(true)
        }

        // prepareAnchor performs a destructive renderer flush. Model the real
        // renderer's post-flush state before the call returns: the old startup
        // preroll must not survive onto the replayed queue.
        renderer.configureReadiness(ready: true, sufficient: false)
        try perform(on: executor) {
            try pipeline.prepareAnchor(at: .zero, in: island)
        }

        XCTAssertFalse(pipeline.isReadyForPlayback)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available, .invalidated])

        renderer.configureReadiness(ready: true, sufficient: true)
        try perform(on: executor) {
            try pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 1, timescale: 2),
                duration: CMTime(value: 1, timescale: 2)
            ))
        }
        XCTAssertTrue(pipeline.isReadyForPlayback)
        XCTAssertEqual(
            readiness.snapshot.map(\.change),
            [.available, .invalidated, .available]
        )
    }

    func testExternallyManagedAutomaticFlushReplaysFiveSecondBurstFromCurrentClock() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.external-flush-time")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { _, _ in },
            rendererFactory: renderers,
            decoderFactory: FakePCMAudioDecoderFactory { sample in
                [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
            },
            routeMonitor: FakeAudioRouteMonitor(),
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            clockMode: .externallyManaged
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
        }
        let renderer = try XCTUnwrap(renderers.snapshot.first)
        renderer.configureReadiness(ready: true, sufficient: true)
        let packetDuration = CMTime(value: 1_024, timescale: 44_100)
        for index in 0..<216 {
            try perform(on: executor) {
                try pipeline.enqueue(try self.makeSample(
                    id: UInt64(index + 1),
                    pts: CMTimeMultiply(packetDuration, multiplier: Int32(index)),
                    duration: packetDuration
                ))
            }
        }
        let initialEnqueueCount = renderer.snapshot.enqueuedPTS.count
        XCTAssertEqual(initialEnqueueCount, 216)

        let blockerEntered = DispatchSemaphore(value: 0)
        let unblockExecutor = DispatchSemaphore(value: 0)
        executor.submit {
            blockerEntered.signal()
            _ = unblockExecutor.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2), .success)

        let capturedTime = CMTime(value: 2, timescale: 1)
        let executionTime = CMTime(value: 3, timescale: 1)
        synchronizer.setCurrentTime(capturedTime)
        renderer.emit(.automaticFlush(CMTime(value: 1, timescale: 1)))
        executor.submit { synchronizer.setCurrentTime(executionTime) }
        unblockExecutor.signal()
        drain(executor)

        let replayed = Array(renderer.snapshot.enqueuedPTS.dropFirst(initialEnqueueCount))
        let first = try XCTUnwrap(replayed.first)
        XCTAssertGreaterThan(CMTimeCompare(first, CMTimeSubtract(executionTime, packetDuration)), 0)
        XCTAssertLessThanOrEqual(CMTimeCompare(first, executionTime), 0)
        XCTAssertTrue(synchronizer.rateSnapshot.isEmpty)
    }

    func testFlushInvalidatesReadinessAndRequiresFreshPreroll() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true, sufficient: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        renderer.fireReady()
        drain(harness.executor)
        XCTAssertTrue(harness.pipeline.isReadyForPlayback)

        // A real renderer reports no startup preroll once it has been flushed.
        renderer.configureReadiness(ready: true, sufficient: false)
        harness.pipeline.flush(to: MediaGeneration(rawValue: 2))
        drain(harness.executor)
        performWithoutThrow(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 2)
            )
        }

        // The preroll latch must not survive a flush: the renderer is empty again,
        // so readiness has to be re-earned rather than inherited.
        XCTAssertFalse(harness.pipeline.isReadyForPlayback)

        renderer.configureReadiness(ready: true, sufficient: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 1),
                generation: MediaGeneration(rawValue: 2)
            ))
        }
        renderer.fireReady()
        drain(harness.executor)
        XCTAssertTrue(harness.pipeline.isReadyForPlayback)
    }

    func testExternallyClockedFallbackBridgesReadinessWithoutChangingRateOrAnchor() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.external-clock")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { sample in
            [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
        }
        let routeMonitor = FakeAudioRouteMonitor()
        let support = FakeAudioFormatSupportChecker()
        let failures = LockedAudioFailures(executor: executor)
        let readiness = LockedAudioReadinessChanges(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { error, generation in failures.append(error, generation: generation) },
            rendererFactory: renderers,
            decoderFactory: decoderFactory,
            routeMonitor: routeMonitor,
            decodeCapabilityChecker: support,
            pcmOutputValidator: support,
            clockMode: .externallyManaged,
            readinessSink: { change, generation in readiness.append(change, generation: generation) }
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
            try pipeline.enqueue(try self.makeSample(id: 1))
        }
        let compressed = try XCTUnwrap(renderers.snapshot.first)
        compressed.configureReadiness(ready: true, sufficient: true)
        compressed.fireReady()
        drain(executor)
        try perform(on: executor) {
            pipeline.setSharedTimelineOpened(true)
        }

        compressed.emit(.automaticFlush(CMTime(value: 1, timescale: 10)))
        drain(executor)
        compressed.fireReady()
        drain(executor)
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            renderers: renderers,
            synchronizer: synchronizer,
            executor: executor,
            reason: "force-fallback"
        )
        try perform(on: executor) {
            try pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10)
            ))
        }
        XCTAssertTrue(pipeline.isReadyForPlayback)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(executor)
        XCTAssertTrue(pipeline.isReadyForPlayback)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        let pcm = try XCTUnwrap(renderers.snapshot.last)
        pcm.configureReadiness(ready: true, sufficient: true)
        pcm.fireReady()
        drain(executor)

        XCTAssertTrue(synchronizer.rateSnapshot.isEmpty)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        XCTAssertTrue(failures.snapshot.isEmpty)
    }

    func testExternallyClockedFallbackGraceExpiresWhenReplacementCannotPreroll() async throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.external-timeout")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let readiness = LockedAudioReadinessChanges(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { _, _ in },
            rendererFactory: renderers,
            decoderFactory: FakePCMAudioDecoderFactory { sample in
                [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
            },
            routeMonitor: FakeAudioRouteMonitor(),
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            clockMode: .externallyManaged,
            readinessSink: { change, generation in
                readiness.append(change, generation: generation)
            }
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
        }
        let compressed = try XCTUnwrap(renderers.snapshot.first)
        compressed.configureReadiness(ready: true, sufficient: true)
        try perform(on: executor) {
            try pipeline.enqueue(try self.makeSample(id: 1))
        }
        compressed.fireReady()
        drain(executor)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available])
        try perform(on: executor) {
            pipeline.setSharedTimelineOpened(true)
        }

        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            renderers: renderers,
            synchronizer: synchronizer,
            executor: executor,
            reason: "force-fallback-timeout"
        )
        try perform(on: executor) {
            try pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10)
            ))
        }
        XCTAssertTrue(pipeline.isReadyForPlayback)

        try await eventually(timeout: .seconds(2)) {
            readiness.snapshot.map(\.change) == [.available, .invalidated]
        }
        XCTAssertFalse(pipeline.isReadyForPlayback)
        try await Task.sleep(for: .milliseconds(100))
        drain(executor)
        XCTAssertEqual(readiness.snapshot.map(\.change), [.available, .invalidated])

        synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(executor)
        synchronizer.releaseRemoval(index: transition.removalIndex)
        synchronizer.releaseRemoval(index: 0)
    }

    func testConfigurationOnlyRecoveryWaitsForCollectionAndUsesExecutionPlayhead() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.configureReadiness(ready: true)
        for id in 1...3 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    pts: CMTime(value: Int64(id), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1)
                ))
            }
        }
        harness.synchronizer.setCurrentTime(CMTime(value: 1, timescale: 1))
        renderer.emit(.outputConfigurationChanged)
        drain(harness.executor)
        XCTAssertTrue(renderer.snapshot.operations.filter { $0 == "flush" }.isEmpty)

        harness.synchronizer.setCurrentTime(CMTime(value: 2, timescale: 1))
        harness.recoveryScheduler.advance(by: .milliseconds(119))
        drain(harness.executor)
        XCTAssertTrue(renderer.snapshot.operations.filter { $0 == "flush" }.isEmpty)

        harness.recoveryScheduler.advance(by: .milliseconds(1))
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS.suffix(2), [
            CMTime(value: 2, timescale: 1),
            CMTime(value: 3, timescale: 1),
        ])
        XCTAssertEqual(harness.pipeline.recoveryCount, 1)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
    }

    func testSecondAutomaticFlushDuringSettleDoesNotStartSecondCompressedRecovery() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }

        renderer.emit(.automaticFlush(.zero))
        drain(harness.executor)
        renderer.emit(.automaticFlush(CMTime(value: 1, timescale: 1)))
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(harness.pipeline.recoveryCount, 1)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
    }

    func testSecondAutomaticFlushSupersedesFirstQueuedRecoveryTransaction() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseExecutor = DispatchSemaphore(value: 0)
        harness.executor.submit {
            blockerEntered.signal()
            _ = releaseExecutor.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2), .success)

        renderer.emit(.automaticFlush(.zero))
        renderer.emit(.automaticFlush(CMTime(value: 1, timescale: 1)))
        releaseExecutor.signal()
        drain(harness.executor)

        XCTAssertEqual(
            renderer.snapshot.operations.filter { $0 == "flush" }.count,
            1,
            "the superseded first ticket must not flush after the second ticket becomes active"
        )
        XCTAssertEqual(harness.pipeline.recoveryCount, 1)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
    }

    func testAirPlayRouteConfigurationRevisionRecoversWithoutCategoryChange() throws {
        let harness = try makeHarness(initialRouteCategory: .airPlay)
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)

        XCTAssertEqual(harness.pipeline.recoveryCount, 0, "initial snapshot must only seed route context")
        XCTAssertTrue(renderer.snapshot.operations.filter { $0 == "flush" }.isEmpty)

        let firstChange = AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 1
        )
        harness.routeMonitor.emit(firstChange)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.settleDelay)
        drain(harness.executor)

        harness.routeMonitor.emit(firstChange)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)
        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 2
        ))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 2)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed])
    }

    func testExecutorIsolatedSettleDeadlinePrecedesLaterConfigurationEvent() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.deadline-boundary")
        let scheduler = ExecutorIsolatedManualAudioRecoveryScheduler(executor: executor)
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { _, _ in },
            rendererFactory: renderers,
            decoderFactory: FakePCMAudioDecoderFactory { _ in [] },
            routeMonitor: FakeAudioRouteMonitor(),
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            recoveryScheduler: scheduler.schedule
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
        }
        let renderer = try XCTUnwrap(renderers.snapshot.first)

        renderer.emit(.automaticFlush(.zero))
        drain(executor)
        XCTAssertEqual(pipeline.recoveryCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 1)

        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit {
            blockerEntered.signal()
            releaseExecutor.wait()
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2), .success)

        scheduler.runNextOnExecutor()
        renderer.emit(.outputConfigurationChanged)
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(pipeline.diagnostics.outputConfigurationTriggerCount, 1)
        XCTAssertEqual(
            pipeline.diagnostics.suppressedCorrelatedTriggerCount,
            1,
            "only the automatic flush without replay is suppressed; the later event is collected"
        )
        XCTAssertEqual(scheduler.pendingCount, 1)

        if scheduler.pendingCount == 1 {
            scheduler.runNextOnExecutor()
            drain(executor)
        }
        XCTAssertEqual(pipeline.recoveryCount, 1)
    }

    func testCollectionDeadlineAfterStopOrReconfigureCannotRecoverStaleRenderer() throws {
        do {
            let harness = try makeHarness()
            let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
            renderer.emit(.outputConfigurationChanged)
            drain(harness.executor)

            performWithoutThrow(on: harness.executor) { harness.pipeline.stop() }
            XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
            harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
            drain(harness.executor)

            XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
            XCTAssertEqual(harness.pipeline.recoveryCount, 0)
            XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        }

        do {
            let harness = try makeHarness()
            let first = try XCTUnwrap(harness.renderers.snapshot.first)
            first.emit(.outputConfigurationChanged)
            drain(harness.executor)

            try perform(on: harness.executor) {
                try harness.pipeline.configure(
                    format: try self.makeFormat(codec: .ac3),
                    codec: .ac3,
                    generation: MediaGeneration(rawValue: 2),
                    fingerprint: self.fingerprint(2)
                )
            }
            harness.synchronizer.completeRemoval(didRemove: true)
            drain(harness.executor)
            let replacement = try XCTUnwrap(harness.renderers.snapshot.last)

            harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
            drain(harness.executor)

            XCTAssertEqual(first.snapshot.operations.filter { $0 == "flush" }.count, 1)
            XCTAssertTrue(replacement.snapshot.operations.filter { $0 == "flush" }.isEmpty)
            XCTAssertEqual(harness.pipeline.recoveryCount, 0)
            XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        }
    }

    func testPCMRouteReevaluationUsesDecodedFormatAndRecoversWithoutTerminalError() throws {
        let harness = try makeHarness()
        harness.support.requireRouteMatchingFormat = true
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        compressed.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-pcm"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)

        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true)
        pcm.fireReady()
        drain(harness.executor)
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .hdmi,
            reason: .newDeviceAvailable,
            revision: 1
        ))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
        XCTAssertEqual(harness.support.checkSnapshot.last?.0, .ffmpegPCM)
        XCTAssertEqual(harness.support.formatIDSnapshot.last, kAudioFormatLinearPCM)
        XCTAssertEqual(harness.decoderFactory.snapshot.first?.flushCountSnapshot, 1)
        XCTAssertGreaterThanOrEqual(pcm.snapshot.operations.filter { $0 == "flush" }.count, 1)
    }

    func testReconfigureWaitsForRemovalAndLatestConfigurationWinsStaleCompletions() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .ac3),
                codec: .ac3,
                generation: MediaGeneration(rawValue: 2),
                fingerprint: self.fingerprint(2)
            )
        }
        XCTAssertEqual(harness.renderers.snapshot.count, 1)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(first.snapshot.stopRequestCount, 0)
        XCTAssertEqual(harness.synchronizer.attachedSnapshot, [first.identity])

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .mp2),
                codec: .mp2,
                generation: MediaGeneration(rawValue: 3),
                fingerprint: self.fingerprint(3)
            )
        }
        XCTAssertEqual(harness.renderers.snapshot.count, 1)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)

        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)

        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        XCTAssertEqual(harness.renderers.snapshot.count, 2)
        XCTAssertEqual(harness.synchronizer.attachedSnapshot, [first.identity, replacement.identity])
        replacement.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 3)
            )
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                codec: .mp2,
                generation: MediaGeneration(rawValue: 2)
            ))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 3,
                codec: .mp2,
                generation: MediaGeneration(rawValue: 3)
            ))
        }
        replacement.fireReady()
        drain(harness.executor)
        XCTAssertEqual(replacement.snapshot.enqueuedFormatIDs, [kAudioFormatMPEGLayer2])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testReconfigureRemovalFailureEmitsOnceAndNeverAttachesSuccessor() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .ac3),
                codec: .ac3,
                generation: MediaGeneration(rawValue: 2),
                fingerprint: self.fingerprint(2)
            )
        }

        XCTAssertEqual(harness.renderers.snapshot.count, 1)
        harness.synchronizer.completeRemoval(didRemove: false)
        harness.synchronizer.completeRemoval(didRemove: false)
        drain(harness.executor)

        XCTAssertEqual(harness.failures.snapshot, [
            AudioFailureRecord(
                error: .audioRendererFailed(AudioRenderPipeline.removalFailedError),
                generation: MediaGeneration(rawValue: 2)
            ),
        ])
        XCTAssertEqual(harness.renderers.snapshot.count, 1)
        XCTAssertEqual(harness.synchronizer.attachedSnapshot, [first.identity])
    }

    func testStopRemovalStaysTrackedThroughConfigureAndFalseCompletionIsConsistent() throws {
        do {
            let harness = try makeHarness()
            performWithoutThrow(on: harness.executor) {
                harness.pipeline.stop()
                harness.pipeline.stop()
            }
            XCTAssertEqual(harness.synchronizer.removalCount, 1)
            harness.synchronizer.completeRemoval(didRemove: false)
            harness.synchronizer.completeRemoval(didRemove: false)
            drain(harness.executor)
            XCTAssertTrue(harness.failures.snapshot.isEmpty, "stop-only removal failure is silent")
            XCTAssertEqual(harness.renderers.snapshot.count, 1)
            XCTAssertFalse(harness.pipeline.isReadyForPlayback)
        }

        do {
            let harness = try makeHarness()
            let first = try XCTUnwrap(harness.renderers.snapshot.first)
            performWithoutThrow(on: harness.executor) { harness.pipeline.stop() }
            try perform(on: harness.executor) {
                try harness.pipeline.configure(
                    format: try self.makeFormat(codec: .ac3),
                    codec: .ac3,
                    generation: MediaGeneration(rawValue: 2),
                    fingerprint: self.fingerprint(2)
                )
            }
            XCTAssertEqual(harness.synchronizer.removalCount, 1)
            XCTAssertEqual(harness.renderers.snapshot.count, 1)

            harness.synchronizer.completeRemoval(didRemove: true)
            harness.synchronizer.completeRemoval(didRemove: true)
            drain(harness.executor)

            let successor = try XCTUnwrap(harness.renderers.snapshot.last)
            XCTAssertEqual(harness.renderers.snapshot.count, 2)
            XCTAssertEqual(harness.synchronizer.attachedSnapshot, [first.identity, successor.identity])
            XCTAssertTrue(harness.failures.snapshot.isEmpty)
        }

        do {
            let harness = try makeHarness()
            let first = try XCTUnwrap(harness.renderers.snapshot.first)
            performWithoutThrow(on: harness.executor) { harness.pipeline.stop() }
            try perform(on: harness.executor) {
                try harness.pipeline.configure(
                    format: try self.makeFormat(codec: .mp2),
                    codec: .mp2,
                    generation: MediaGeneration(rawValue: 2),
                    fingerprint: self.fingerprint(2)
                )
            }
            XCTAssertEqual(harness.synchronizer.removalCount, 1)
            XCTAssertEqual(harness.renderers.snapshot.count, 1)

            harness.synchronizer.completeRemoval(didRemove: false)
            harness.synchronizer.completeRemoval(didRemove: false)
            drain(harness.executor)

            XCTAssertEqual(harness.failures.snapshot, [
                AudioFailureRecord(
                    error: .audioRendererFailed(AudioRenderPipeline.removalFailedError),
                    generation: MediaGeneration(rawValue: 2)
                ),
            ])
            XCTAssertEqual(harness.renderers.snapshot.count, 1)
            XCTAssertEqual(harness.synchronizer.attachedSnapshot, [first.identity])
        }
    }

    func testFlushDuringFallbackRemovalNeverResurrectsFailedRendererAndCompletesPCM() throws {
        let harness = try makeHarness()
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        compressed.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        compressed.fireReady()
        drain(harness.executor)
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-pcm"
        )

        performWithoutThrow(on: harness.executor) {
            harness.pipeline.flush(to: MediaGeneration(rawValue: 2))
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 2)
            )
        }
        XCTAssertEqual(
            transition.retryRenderer.snapshot.requestCount,
            1,
            "compressed renderer was not removed"
        )
        XCTAssertEqual(transition.retryRenderer.snapshot.observationStartCount, 1)
        XCTAssertEqual(harness.renderers.snapshot.count, 2)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10),
                generation: MediaGeneration(rawValue: 2)
            ))
        }
        XCTAssertEqual(compressed.snapshot.enqueuedPTS.count, 1)

        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)
        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true)
        pcm.fireReady()
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.renderers.snapshot.count, 3)
        XCTAssertEqual(harness.decoderFactory.snapshot.first?.pushedIDSnapshot, [2])
        XCTAssertEqual(
            pcm.snapshot.enqueuedFormatIDs,
            [kAudioFormatLinearPCM],
            "fallback renderer did not become ready"
        )
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
        XCTAssertEqual(
            compressed.snapshot.requestCount,
            0,
            "compressed renderer was not removed"
        )
        XCTAssertEqual(compressed.snapshot.observationStartCount, 1)
    }

    func testRouteMonitorEmitsSanitizedInitialAndRouteConfigurationSnapshots() {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.route")
        let center = NotificationCenter()
        let snapshots = LockedRouteSnapshots(executor: executor)
        let monitor = AudioOutputRouteMonitor(
            executor: executor,
            notificationCenter: center,
            snapshotProvider: { [.HDMI, .airPlay] },
            latencyProvider: { (0, 0) }
        )
        monitor.start { snapshots.append($0) }

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: "Living Room Apple TV secret UID",
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue,
                "portName": "Do Not Capture",
                "UID": "secret",
            ]
        )
        drain(executor)

        XCTAssertEqual(snapshots.snapshot, [
            AudioOutputRouteSnapshot(category: .hdmi, reason: .initial, revision: 0),
            AudioOutputRouteSnapshot(
                category: .hdmi,
                reason: .routeConfigurationChange,
                revision: 1
            ),
        ])
        XCTAssertEqual(snapshots.isolationSnapshot, [true, true])
        XCTAssertFalse(String(describing: snapshots.snapshot).contains("Living Room"))
        XCTAssertFalse(String(describing: snapshots.snapshot).contains("secret"))
        monitor.stop()
    }

    func testRouteSnapshotEqualityIncludesLatencyAndIOBufferDuration() {
        let baseline = AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 4,
            outputLatency: 0.200,
            ioBufferDuration: 0.020
        )

        XCTAssertNotEqual(baseline, AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 4,
            outputLatency: 0.250,
            ioBufferDuration: 0.020
        ))
        XCTAssertNotEqual(baseline, AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 4,
            outputLatency: 0.200,
            ioBufferDuration: 0.030
        ))
    }

    func testRouteNotificationResamplesFreshLatencyAndIOBufferDuration() {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.route-latency")
        let center = NotificationCenter()
        let latency = MutableRouteLatency(outputLatency: 0.100, ioBufferDuration: 0.010)
        let snapshots = LockedRouteSnapshots(executor: executor)
        let monitor = AudioOutputRouteMonitor(
            executor: executor,
            notificationCenter: center,
            snapshotProvider: { [.airPlay] },
            latencyProvider: latency.snapshot
        )
        monitor.start { snapshots.append($0) }
        drain(executor)
        latency.set(outputLatency: 0.300, ioBufferDuration: 0.030)

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue,
            ]
        )
        drain(executor)

        XCTAssertEqual(snapshots.snapshot.map(\.outputLatency), [0.100, 0.300])
        XCTAssertEqual(snapshots.snapshot.map(\.ioBufferDuration), [0.010, 0.030])
        monitor.stop()
    }

    func testOutputConfigurationChangeResamplesAndPublishesFreshRouteSnapshot() throws {
        let harness = try makeHarness(initialRouteCategory: .airPlay)
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        let refreshed = AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 1,
            outputLatency: 0.450,
            ioBufferDuration: 0.025
        )
        harness.routeMonitor.setNextResampleSnapshot(refreshed)

        renderer.emit(.outputConfigurationChanged)
        drain(harness.executor)

        XCTAssertEqual(harness.routeMonitor.resampleCountSnapshot, 1)
        XCTAssertEqual(harness.pipeline.currentRouteSnapshot, refreshed)
        XCTAssertEqual(harness.pipeline.diagnostics.routeRevision, refreshed.revision)
        XCTAssertEqual(harness.pipeline.anchorLeadTime.seconds, 0.575, accuracy: 0.001)
    }

    func testNoOutputRouteFailsExactlyAtDeadlineOnce() throws {
        let harness = try makeHarness(initialRouteCategory: .none)

        harness.recoveryScheduler.advance(by: .milliseconds(2_999))
        drain(harness.executor)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        harness.recoveryScheduler.advance(by: .milliseconds(1))
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot, [
            AudioFailureRecord(
                error: .audioRendererFailed("audio.output-route.unavailable"),
                generation: MediaGeneration(rawValue: 1)
            ),
        ])

        harness.recoveryScheduler.advance(by: .seconds(30))
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot.count, 1)
    }

    func testUsableRouteCancelsNoOutputRouteDeadline() throws {
        let harness = try makeHarness(initialRouteCategory: .none)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .hdmi,
            reason: .newDeviceAvailable,
            revision: 1
        ))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(3))
        drain(harness.executor)

        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testConfigureInvalidatesOldNoOutputRouteTicketIdentity() throws {
        let harness = try makeHarness(initialRouteCategory: .none)

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 2),
                fingerprint: self.fingerprint(2)
            )
        }
        harness.recoveryScheduler.advance(by: .seconds(3))
        drain(harness.executor)

        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testStopAndRendererReplacementInvalidateNoOutputRouteTickets() throws {
        do {
            let harness = try makeHarness(initialRouteCategory: .none)
            try perform(on: harness.executor) { harness.pipeline.stop() }
            harness.recoveryScheduler.advance(by: .seconds(3))
            drain(harness.executor)
            XCTAssertTrue(harness.failures.snapshot.isEmpty)
        }

        do {
            let harness = try makeHarness(initialRouteCategory: .none)
            let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
            renderer.configureReadiness(ready: true)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: 1,
                    pts: .zero,
                    duration: CMTime(value: 10, timescale: 1)
                ))
            }
            renderer.emit(.automaticFlush(.zero))
            drain(harness.executor)
            harness.recoveryScheduler.advance(by: .seconds(1))
            drain(harness.executor)
            XCTAssertEqual(harness.synchronizer.removalCount, 1)
            harness.recoveryScheduler.advance(by: .seconds(2))
            drain(harness.executor)
            XCTAssertTrue(harness.failures.snapshot.isEmpty)
        }
    }

    func testCompressedRetryCreatesFreshNoRouteDeadlineForReplacementIdentity() throws {
        let harness = try makeHarness(initialRouteCategory: .none)
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 1, timescale: 1)
            ))
        }

        original.emit(.failed("retry:first"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        XCTAssertNotEqual(replacement.identity, original.identity)
        replacement.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        replacement.fireReady()
        drain(harness.executor)
        replacement.fireReady()
        drain(harness.executor)

        harness.recoveryScheduler.advance(by: .milliseconds(2_999))
        drain(harness.executor)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
        harness.recoveryScheduler.advance(by: .milliseconds(1))
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioRendererFailed("audio.output-route.unavailable"),
        ])
        harness.recoveryScheduler.advance(by: .seconds(30))
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot.count, 1)
    }

    func testUsableRouteCancelsCompressedReplacementNoRouteDeadline() throws {
        let harness = try makeHarness(initialRouteCategory: .none)
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 1, timescale: 1)
            ))
        }
        original.emit(.failed("retry:first"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        replacement.configureReadiness(ready: true, maximumEnqueuesPerCallback: 1)
        replacement.fireReady()
        drain(harness.executor)
        replacement.fireReady()
        drain(harness.executor)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .hdmi,
            reason: .newDeviceAvailable,
            revision: 1
        ))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(3))
        drain(harness.executor)

        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testPCMFallbackCreatesFreshNoRouteDeadlineForReplacementIdentity() throws {
        let harness = try makeHarness(initialRouteCategory: .none)
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: original,
            in: harness,
            reason: "fallback"
        )
        harness.synchronizer.completeRemoval(
            index: transition.removalIndex,
            didRemove: true
        )
        drain(harness.executor)
        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        XCTAssertEqual(replacement.mediaKind, .linearPCM)
        XCTAssertNotEqual(replacement.identity, original.identity)

        harness.recoveryScheduler.advance(by: .milliseconds(2_999))
        drain(harness.executor)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
        harness.recoveryScheduler.advance(by: .milliseconds(1))
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioRendererFailed("audio.output-route.unavailable"),
        ])
        harness.recoveryScheduler.advance(by: .seconds(30))
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot.count, 1)
    }

    func testUsableRouteCancelsPCMReplacementNoRouteDeadline() throws {
        let harness = try makeHarness(initialRouteCategory: .none)
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: original,
            in: harness,
            reason: "fallback"
        )
        harness.synchronizer.completeRemoval(
            index: transition.removalIndex,
            didRemove: true
        )
        drain(harness.executor)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .newDeviceAvailable,
            revision: 1
        ))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: .seconds(3))
        drain(harness.executor)

        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testAudioSessionResetRebuildsCompressedRendererWithoutChangingGeneration() throws {
        let harness = try makeHarness()
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
            harness.pipeline.recoverFromAudioSessionReset()
        }

        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        XCTAssertEqual(harness.renderers.snapshot.map(\.mediaKind), [.compressed, .compressed])
        XCTAssertNotEqual(replacement.identity, original.identity)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testAudioSessionResetDestroysAndRecreatesPCMDecoderAndRenderer() throws {
        let harness = try makeHarness()
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let fallback = try beginFallbackAfterCompressedRetry(
            initialRenderer: original,
            in: harness,
            reason: "reset"
        )
        harness.synchronizer.completeRemoval(index: fallback.removalIndex, didRemove: true)
        drain(harness.executor)
        let pcmRenderer = try XCTUnwrap(harness.renderers.snapshot.last)
        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.last)

        try perform(on: harness.executor) {
            harness.pipeline.recoverFromAudioSessionReset()
        }
        XCTAssertEqual(harness.synchronizer.removalCount, fallback.removalIndex + 2)
        harness.synchronizer.completeRemoval(
            index: fallback.removalIndex + 1,
            didRemove: true
        )
        drain(harness.executor)

        let replacement = try XCTUnwrap(harness.renderers.snapshot.last)
        XCTAssertEqual(replacement.mediaKind, .linearPCM)
        XCTAssertNotEqual(replacement.identity, pcmRenderer.identity)
        XCTAssertEqual(decoder.destroyCountSnapshot, 1)
        XCTAssertEqual(harness.decoderFactory.snapshot.count, 2)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testAudioSessionResetDuringFallbackRemovalPreservesPCMTarget() throws {
        let harness = try makeHarness()
        let original = try XCTUnwrap(harness.renderers.snapshot.first)
        original.configureReadiness(ready: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let fallback = try beginFallbackAfterCompressedRetry(
            initialRenderer: original,
            in: harness,
            reason: "reset"
        )

        try perform(on: harness.executor) {
            harness.pipeline.recoverFromAudioSessionReset()
        }
        harness.synchronizer.completeRemoval(index: fallback.removalIndex, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.renderers.snapshot.last?.mediaKind, .linearPCM)
        XCTAssertEqual(harness.decoderFactory.snapshot.count, 1)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testOnlyUsableRouteTimingChangesPublishAnchorTimingChange() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio-route-timing")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let routeMonitor = FakeAudioRouteMonitor(initialCategory: .airPlay)
        let readiness = LockedAudioReadinessChanges(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { _, _ in },
            rendererFactory: renderers,
            decoderFactory: FakePCMAudioDecoderFactory { _ in [] },
            routeMonitor: routeMonitor,
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            recoveryScheduler: ManualAudioRecoveryScheduler().schedule,
            clockMode: .externallyManaged,
            readinessSink: { change, generation in
                readiness.append(change, generation: generation)
            }
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
        }

        routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 1,
            outputLatency: 0.400,
            ioBufferDuration: 0.020
        ))
        drain(executor)
        routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 2,
            outputLatency: 0.400,
            ioBufferDuration: 0.020
        ))
        drain(executor)
        let renderer = try XCTUnwrap(renderers.snapshot.first)
        routeMonitor.setNextResampleSnapshot(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 3,
            outputLatency: 0.400,
            ioBufferDuration: 0.020
        ))
        renderer.emit(.outputConfigurationChanged)
        renderer.emit(.automaticFlush(.zero))
        drain(executor)
        routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .none,
            reason: .oldDeviceUnavailable,
            revision: 4
        ))
        drain(executor)

        XCTAssertEqual(readiness.snapshot, [
            AudioReadinessRecord(
                change: .anchorTimingChanged(routeRevision: 1),
                generation: MediaGeneration(rawValue: 1)
            ),
            AudioReadinessRecord(
                change: .outputRouteUnavailable,
                generation: MediaGeneration(rawValue: 1)
            ),
        ])
    }

    func testRouteMonitorPreservesBufferedAndDrainBoundaryNotificationOrder() {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.route-start-race")
        let center = RouteChangesDuringObserverInstallationNotificationCenter()
        let snapshots = LockedRouteSnapshots(executor: executor)
        let monitor = AudioOutputRouteMonitor(
            executor: executor,
            notificationCenter: center,
            snapshotProvider: { [.airPlay] },
            latencyProvider: { (0, 0) },
            initialDrainBoundaryHook: {
                center.post(
                    name: AVAudioSession.routeChangeNotification,
                    object: nil,
                    userInfo: [
                        AVAudioSessionRouteChangeReasonKey:
                            AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue,
                    ]
                )
            }
        )

        monitor.start { snapshots.append($0) }
        drain(executor)

        XCTAssertEqual(snapshots.snapshot, [
            AudioOutputRouteSnapshot(category: .airPlay, reason: .initial, revision: 0),
            AudioOutputRouteSnapshot(
                category: .airPlay,
                reason: .newDeviceAvailable,
                revision: 1
            ),
            AudioOutputRouteSnapshot(
                category: .airPlay,
                reason: .oldDeviceUnavailable,
                revision: 2
            ),
            AudioOutputRouteSnapshot(
                category: .airPlay,
                reason: .routeConfigurationChange,
                revision: 3
            ),
        ])
        monitor.stop()
    }

    func testRouteMonitorNormalizesEveryAppleReasonAndIncrementsEveryNotification() {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.route-reasons")
        let center = NotificationCenter()
        let snapshots = LockedRouteSnapshots(executor: executor)
        let monitor = AudioOutputRouteMonitor(
            executor: executor,
            notificationCenter: center,
            snapshotProvider: { [.airPlay] }
        )
        monitor.start { snapshots.append($0) }
        let cases: [(AVAudioSession.RouteChangeReason, AudioRouteChangeReason)] = [
            (.newDeviceAvailable, .newDeviceAvailable),
            (.oldDeviceUnavailable, .oldDeviceUnavailable),
            (.categoryChange, .categoryChange),
            (.override, .override),
            (.wakeFromSleep, .wakeFromSleep),
            (.noSuitableRouteForCategory, .noSuitableRoute),
            (.routeConfigurationChange, .routeConfigurationChange),
            (.unknown, .unknown),
        ]
        for (reason, _) in cases {
            center.post(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
        }
        drain(executor)

        XCTAssertEqual(snapshots.snapshot.map(\.reason), [.initial] + cases.map(\.1))
        XCTAssertEqual(snapshots.snapshot.map(\.revision), Array(0...UInt64(cases.count)))
        XCTAssertEqual(snapshots.snapshot.map(\.category), Array(
            repeating: AudioOutputRouteCategory.airPlay,
            count: cases.count + 1
        ))
        monitor.stop()
    }

    func testRouteMonitorDropsNotificationQueuedBeforeStopAndRestart() {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.route-stale")
        let center = NotificationCenter()
        let snapshots = LockedRouteSnapshots(executor: executor)
        let monitor = AudioOutputRouteMonitor(
            executor: executor,
            notificationCenter: center,
            snapshotProvider: { [.HDMI] },
            latencyProvider: { (0, 0) }
        )
        monitor.start { _ in XCTFail("old handler must not run") }
        center.post(name: AVAudioSession.routeChangeNotification, object: nil)
        monitor.stop()
        monitor.start { snapshots.append($0) }
        drain(executor)

        XCTAssertEqual(snapshots.snapshot, [
            AudioOutputRouteSnapshot(category: .hdmi, reason: .initial, revision: 0),
        ])
        monitor.stop()
    }

    func testPipelineRejectsRouteSnapshotRevisionRollback() throws {
        let harness = try makeHarness(initialRouteCategory: .airPlay)
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        let change = AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 1
        )
        harness.routeMonitor.emit(change)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.settleDelay)
        drain(harness.executor)
        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .hdmi,
            reason: .initial,
            revision: 0
        ))
        harness.routeMonitor.emit(change)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(
            renderer.snapshot.operations.filter { $0 == "flush" }.count,
            1,
            "revision rollback must not make a previously consumed snapshot appear new"
        )
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
    }

    func testCompressedRouteNeverConsultsSupportWhilePCMRouteStillValidatesOutput() throws {
        let harness = try makeHarness()
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        harness.support.compressedSupported = false
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .newDeviceAvailable,
            revision: 1
        ))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 0)
        XCTAssertTrue(harness.support.checkSnapshot.isEmpty)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)

        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-pcm"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)

        harness.support.pcmSupported = false
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .hdmi,
            reason: .newDeviceAvailable,
            revision: 2
        ))
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioRendererFailed(AudioRenderPipeline.unsupportedPCMError),
        ])
        XCTAssertEqual(harness.renderers.snapshot.count, 3)
    }

    func testOldCallbacksAfterConfigureFlushStopAndRemovalAreHarmless() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        first.configureReadiness(ready: false)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let staleReadyHandler = try XCTUnwrap(first.captureReadyHandler())
        first.emit(.failed("first"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .ac3),
                codec: .ac3,
                generation: MediaGeneration(rawValue: 2),
                fingerprint: self.fingerprint(2)
            )
        }
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        staleReadyHandler()
        first.fireReady()
        first.emit(.automaticFlush(.zero))
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)

        performWithoutThrow(on: harness.executor) {
            harness.pipeline.flush(to: MediaGeneration(rawValue: 3))
            harness.pipeline.stop()
            harness.pipeline.stop()
        }
        first.fireReady()
        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .hdmi,
            reason: .newDeviceAvailable,
            revision: 1
        ))
        drain(harness.executor)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testPCMAdapterDeepCopiesBorrowedMemoryAndPreservesExactTokenPTSAndLayout() throws {
        let native = FakeFFmpegAudioDecoderAPI()
        let decoder = try FFmpegPCMAudioDecoder(
            codec: .aac,
            extradata: Data([0x12, 0x10]),
            api: native
        )
        let originalPTS = CMTime(value: 1001, timescale: 30000)
        native.outputScripts = [[
            .init(samples: [0.25, -0.5, 0.75, -1], frames: 2, rate: 48_000, channels: 2,
                  channelOrder: VPFF_CHANNEL_ORDER_NATIVE, mask: 3),
            .init(samples: [1, 0, 0, 1], frames: 2, rate: 48_000, channels: 2,
                  channelOrder: VPFF_CHANNEL_ORDER_NATIVE, mask: 3),
        ]]
        let outputs = try decoder.push(makeSample(id: 1, pts: originalPTS))
        native.mutateLastBorrowedMemory()

        XCTAssertEqual(native.pushedTokens.count, 1)
        XCTAssertGreaterThan(native.pushedTokens[0], 0)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs.map(CMSampleBufferGetPresentationTimeStamp), [
            originalPTS,
            CMTimeAdd(originalPTS, CMTime(value: 2, timescale: 48_000)),
        ])
        XCTAssertEqual(outputs.map(CMSampleBufferGetNumSamples), [2, 2])
        XCTAssertTrue(outputs.allSatisfy(CMSampleBufferDataIsReady))
        let firstBytes = try copiedData(outputs[0])
        XCTAssertEqual(firstBytes.count, 16)
        XCTAssertEqual(firstBytes.withUnsafeBytes { $0.load(as: Float.self) }, 0.25)
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(outputs[0]))
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mBytesPerFrame, 8)
        XCTAssertEqual(asbd.mFramesPerPacket, 1)
        XCTAssertEqual(asbd.mBitsPerChannel, 32)
        let layout = try copiedLayout(description)
        XCTAssertEqual(layout.mChannelLayoutTag, kAudioChannelLayoutTag_Stereo)
        XCTAssertEqual(layout.mChannelBitmap.rawValue, 0)
    }

    func testLivePCMDecoderCreateWithEmptyExtradataUsesNullZeroABIAndDestroys() throws {
        let decoder = try FFmpegPCMAudioDecoder(
            codec: .ac3,
            extradata: Data()
        )
        decoder.destroy()
        decoder.destroy()
    }

    func testPCMAdapterRejectsUnknownMalformedFutureAndOverflowingCallbacks() throws {
        let native = FakeFFmpegAudioDecoderAPI()
        let decoder = try FFmpegPCMAudioDecoder(
            codec: .aac,
            extradata: Data([0x12, 0x10]),
            api: native
        )
        native.overrideToken = 999
        native.outputScripts = [[.stereo(frames: 1)]]
        assertCoreError(.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)) {
            _ = try decoder.push(makeSample(id: 1))
        }
        decoder.flush()
        XCTAssertEqual(native.flushCount, 1)
        decoder.destroy()
        decoder.destroy()
        XCTAssertEqual(native.destroyCount, 1)
    }

    func testPCMAdapterRejectsShortOrWrongVersionABIAndAcceptsFutureTail() throws {
        do {
            let native = FakeFFmpegAudioDecoderAPI()
            native.overrideStructSize = 40
            native.outputScripts = [[.stereo(frames: 1)]]
            let decoder = try FFmpegPCMAudioDecoder(
                codec: .aac,
                extradata: Data([0x12, 0x10]),
                api: native
            )
            assertCoreError(.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)) {
                _ = try decoder.push(makeSample(id: 1))
            }
        }
        do {
            let native = FakeFFmpegAudioDecoderAPI()
            native.overrideABIVersion = 2
            native.outputScripts = [[.stereo(frames: 1)]]
            let decoder = try FFmpegPCMAudioDecoder(
                codec: .aac,
                extradata: Data([0x12, 0x10]),
                api: native
            )
            assertCoreError(.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)) {
                _ = try decoder.push(makeSample(id: 1))
            }
        }
        do {
            let native = FakeFFmpegAudioDecoderAPI()
            native.overrideStructSize = 72
            native.outputScripts = [[.stereo(frames: 1)]]
            let decoder = try FFmpegPCMAudioDecoder(
                codec: .aac,
                extradata: Data([0x12, 0x10]),
                api: native
            )
            XCTAssertEqual(try decoder.push(makeSample(id: 1)).count, 1)
        }
    }

    func testFallbackPushFailureEmitsOneExactDecodeError() throws {
        let harness = try makeHarness()
        harness.decoderFactory.pushBody = { _ in
            throw PlaybackCoreError.audioFallbackDecode(-32_109)
        }
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-fallback"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)
        transition.retryRenderer.emit(.failed("duplicate"))
        drain(harness.executor)

        XCTAssertEqual(harness.failures.snapshot.map(\.error), [.audioFallbackDecode(-32_109)])
    }

    func testPCMEnqueueDecodeFailureEmitsOnceWithoutThrowingOrRepeatingWork() throws {
        let harness = try makeHarness()
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            in: harness,
            reason: "force-fallback"
        )
        harness.synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.first)
        XCTAssertEqual(decoder.pushedIDSnapshot, [1])
        performWithoutThrow(on: harness.executor) {
            harness.pipeline.flush(to: MediaGeneration(rawValue: 2))
            harness.pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 2)
            )
        }
        decoder.configurePushError(.audioFallbackDecode(-32_110))

        XCTAssertNoThrow(try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                generation: MediaGeneration(rawValue: 2)
            ))
        })
        XCTAssertNoThrow(try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 3,
                generation: MediaGeneration(rawValue: 2)
            ))
        })

        XCTAssertEqual(harness.failures.snapshot, [
            AudioFailureRecord(
                error: .audioFallbackDecode(-32_110),
                generation: MediaGeneration(rawValue: 2)
            ),
        ])
        XCTAssertEqual(decoder.pushedIDSnapshot, [1, 2])
    }

    func testPCMPendingCapacityDrainsThenContinuesDecodingWithoutAnotherReadyCallback() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.pcm-cap")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { sample in
            [
                try self.makePCMBuffer(pts: sample.presentationTimeStamp),
                try self.makePCMBuffer(pts: CMTimeAdd(sample.presentationTimeStamp, CMTime(value: 2, timescale: 48_000))),
            ]
        }
        let routeMonitor = FakeAudioRouteMonitor()
        let support = FakeAudioFormatSupportChecker()
        let failures = LockedAudioFailures(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { error, generation in failures.append(error, generation: generation) },
            rendererFactory: renderers,
            decoderFactory: decoderFactory,
            routeMonitor: routeMonitor,
            decodeCapabilityChecker: support,
            pcmOutputValidator: support
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac), codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
            for id in 1...96 { try pipeline.enqueue(try self.makeSample(id: UInt64(id))) }
        }
        let compressed = try XCTUnwrap(renderers.snapshot.first)
        let transition = try beginFallbackAfterCompressedRetry(
            initialRenderer: compressed,
            renderers: renderers,
            synchronizer: synchronizer,
            executor: executor,
            reason: "force-fallback"
        )
        synchronizer.completeRemoval(index: transition.removalIndex, didRemove: true)
        drain(executor)
        let pcm = try XCTUnwrap(renderers.snapshot.last)
        pcm.configureReadiness(ready: true)
        pcm.fireReady()
        drain(executor)

        XCTAssertEqual(pcm.snapshot.enqueuedPTS.count, 192)
        XCTAssertTrue(failures.snapshot.isEmpty)
    }

    func testNativeCABIValidationLifecycleCapsAndInvalidPacketError() throws {
        XCTAssertEqual(VPFF_AUDIO_DECODER_ABI_VERSION, 1)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.interleaved), 0)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.frame_count), 8)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.sample_rate), 16)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.channels), 20)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.pts), 24)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.abi_version), 32)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.struct_size), 36)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.channel_order), 40)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.has_channel_layout_mask), 44)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.offset(of: \.channel_layout_mask), 48)
        XCTAssertEqual(MemoryLayout<VPFFPCMFrame>.stride, 56)

        for codec in [
            VPFF_CODEC_AAC,
            VPFF_CODEC_AC3,
            VPFF_CODEC_EAC3,
            VPFF_CODEC_MP1,
            VPFF_CODEC_MP2,
            VPFF_CODEC_MP3,
        ] {
            var decoder: OpaquePointer?
            XCTAssertEqual(vp_ffmpeg_audio_decoder_create(codec, nil, 0, { _, frame in
                guard let frame else { return }
                XCTAssertEqual(frame.pointee.abi_version, 1)
                XCTAssertEqual(frame.pointee.struct_size, UInt32(MemoryLayout<VPFFPCMFrame>.stride))
                XCTAssertEqual(frame.pointee.reserved.0, 0)
                XCTAssertEqual(frame.pointee.reserved.1, 0)
                XCTAssertEqual(frame.pointee.reserved.2, 0)
            }, nil, &decoder), 0)
            let handle = try XCTUnwrap(decoder)
            var invalid: UInt8 = 0
            XCTAssertEqual(
                vp_ffmpeg_audio_decoder_push(handle, &invalid, 1, 7),
                FFmpegPCMAudioDecoder.invalidPacketErrorCode
            )
            vp_ffmpeg_audio_decoder_flush(handle)
            vp_ffmpeg_audio_decoder_flush(handle)
            vp_ffmpeg_audio_decoder_destroy(handle)
        }

        var decoder: OpaquePointer?
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_create(VPFF_CODEC_H264, nil, 0, { _, _ in }, nil, &decoder), 0)
        XCTAssertNil(decoder)
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_create(VPFF_CODEC_AAC, nil, 1, { _, _ in }, nil, &decoder), 0)
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_create(VPFF_CODEC_AAC, nil, 0, nil, nil, &decoder), 0)
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_create(VPFF_CODEC_AAC, nil, 0, { _, _ in }, nil, nil), 0)
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_push(nil, nil, 0, 1), 0)
        var byte: UInt8 = 0
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_create(
            VPFF_CODEC_AAC, &byte, 64 * 1_024 * 1_024 + 1,
            { _, _ in }, nil, &decoder
        ), 0)
        XCTAssertEqual(vp_ffmpeg_audio_decoder_create(
            VPFF_CODEC_AAC, nil, 0, { _, _ in }, nil, &decoder
        ), 0)
        let capped = try XCTUnwrap(decoder)
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_push(
            capped, &byte, 64 * 1_024 * 1_024 + 1, 1
        ), 0)
        XCTAssertLessThan(vp_ffmpeg_audio_decoder_push(capped, &byte, 1, 0), 0)
        vp_ffmpeg_audio_decoder_destroy(capped)
        vp_ffmpeg_audio_decoder_flush(nil)
        vp_ffmpeg_audio_decoder_destroy(nil)
    }

    func testTask7StaticScopeAndPrivacyGate() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let productionPaths = [
            "Sources/VPlayerPlayback/include/VPFFmpegAudioDecoder.h",
            "Sources/VPlayerPlayback/FFmpeg/VPFFmpegAudioDecoder.c",
            "Sources/VPlayerPlayback/Audio/AudioRendering.swift",
            "Sources/VPlayerPlayback/Audio/SystemAudioRenderer.swift",
            "Sources/VPlayerPlayback/Audio/FFmpegPCMAudioDecoder.swift",
            "Sources/VPlayerPlayback/Audio/AudioRenderPipeline.swift",
            "Sources/VPlayerPlayback/Audio/AudioOutputRouteMonitor.swift",
        ]
        let sources = try productionPaths.map {
            try String(contentsOf: repository.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        for forbidden in ["port" + "Name", "localized" + "Description", "UID", "NWListener",
                          "socket(" , "http" + "Server", "Metal", "Shaders", "PlaybackPipeline"] {
            XCTAssertNil(sources.range(of: forbidden, options: .caseInsensitive))
        }
    }

    private func makeHarness(
        codec: VPlayerPlayback.AudioCodec = .aac,
        configure: Bool = true,
        initialRouteCategory: AudioOutputRouteCategory = .other,
        fingerprint: MediaFormatFingerprint = MediaFormatFingerprint(bytes: Data([1])),
        replayRetentionLimits: CompressedAudioRetentionLimits =
            CompressedAudioRetentionPolicy.replay,
        replayHardCount: Int = CompressedAudioRetentionPolicy.replayHardCount,
        progressDeadlineTicketStart: UInt64? = nil
    ) throws -> AudioHarness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { sample in
            [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
        }
        let routeMonitor = FakeAudioRouteMonitor(initialCategory: initialRouteCategory)
        let recoveryScheduler = ManualAudioRecoveryScheduler()
        let diagnosticsClock = ManualAudioDiagnosticsClock()
        let support = FakeAudioFormatSupportChecker()
        let failures = LockedAudioFailures(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { error, generation in failures.append(error, generation: generation) },
            rendererFactory: renderers,
            decoderFactory: decoderFactory,
            routeMonitor: routeMonitor,
            decodeCapabilityChecker: support,
            pcmOutputValidator: support,
            recoveryScheduler: recoveryScheduler.schedule,
            diagnosticsNow: diagnosticsClock.now,
            replayRetentionLimits: replayRetentionLimits,
            replayHardCount: replayHardCount,
            testingProgressDeadlineTicketStart: progressDeadlineTicketStart
        )
        if configure {
            try perform(on: executor) {
                try pipeline.configure(
                    format: try self.makeFormat(codec: codec),
                    codec: codec,
                    generation: MediaGeneration(rawValue: 1),
                    fingerprint: fingerprint
                )
                pipeline.activateContinuityIsland(
                    AudioContinuityIslandID(rawValue: 1),
                    generation: MediaGeneration(rawValue: 1)
                )
            }
        }
        return AudioHarness(
            executor: executor, synchronizer: synchronizer, renderers: renderers,
            decoderFactory: decoderFactory, routeMonitor: routeMonitor,
            support: support, failures: failures, recoveryScheduler: recoveryScheduler,
            diagnosticsClock: diagnosticsClock,
            pipeline: pipeline
        )
    }

    private func makeCapabilityHarness(
        initialRouteCategory: AudioOutputRouteCategory = .other
    ) -> CapabilityAudioHarness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.capability")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { sample in
            [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
        }
        let decodeCapability = FakeCoreAudioDecodeCapabilityChecker()
        let pcmValidator = FakePCMOutputFormatValidator()
        let failures = LockedAudioFailures(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { error, generation in failures.append(error, generation: generation) },
            rendererFactory: renderers,
            decoderFactory: decoderFactory,
            routeMonitor: FakeAudioRouteMonitor(initialCategory: initialRouteCategory),
            decodeCapabilityChecker: decodeCapability,
            pcmOutputValidator: pcmValidator,
            recoveryScheduler: ManualAudioRecoveryScheduler().schedule
        )
        return CapabilityAudioHarness(
            executor: executor,
            synchronizer: synchronizer,
            renderers: renderers,
            decoderFactory: decoderFactory,
            decodeCapability: decodeCapability,
            pcmValidator: pcmValidator,
            failures: failures,
            pipeline: pipeline
        )
    }

    private func makeResetAttachmentHarness() throws -> ResetAttachmentAudioHarness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio.reset-attachment")
        let synchronizer = FakeAudioSynchronizer()
        let rendererFactory = ResetAttachmentAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { sample in
            [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
        }
        let recoveryScheduler = ManualAudioRecoveryScheduler()
        let failures = LockedAudioFailures(executor: executor)
        let pipeline = AudioRenderPipeline(
            synchronizer: synchronizer,
            executor: executor,
            failureSink: { error, generation in failures.append(error, generation: generation) },
            rendererFactory: rendererFactory,
            decoderFactory: decoderFactory,
            routeMonitor: FakeAudioRouteMonitor(),
            decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
            pcmOutputValidator: FakeAudioFormatSupportChecker(),
            recoveryScheduler: recoveryScheduler.schedule
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1),
                fingerprint: self.fingerprint(1)
            )
            pipeline.activateContinuityIsland(
                AudioContinuityIslandID(rawValue: 1),
                generation: MediaGeneration(rawValue: 1)
            )
        }
        return ResetAttachmentAudioHarness(
            executor: executor,
            synchronizer: synchronizer,
            renderer: try XCTUnwrap(rendererFactory.snapshot.first),
            renderers: rendererFactory,
            failures: failures,
            recoveryScheduler: recoveryScheduler,
            pipeline: pipeline
        )
    }

    private func beginFallbackAfterCompressedRetry(
        initialRenderer: FakeAudioRenderer,
        renderers: FakeAudioRendererFactory,
        synchronizer: FakeAudioSynchronizer,
        executor: PlaybackSerialExecutor,
        reason: String
    ) throws -> (retryRenderer: FakeAudioRenderer, removalIndex: Int) {
        initialRenderer.emit(.failed("\(reason):retry"))
        drain(executor)
        let retryRemovalIndex = synchronizer.removalCount - 1
        synchronizer.completeRemoval(index: retryRemovalIndex, didRemove: true)
        drain(executor)
        let retryRenderer = try XCTUnwrap(renderers.snapshot.last)
        retryRenderer.emit(.failed("\(reason):fallback"))
        drain(executor)
        return (retryRenderer, synchronizer.removalCount - 1)
    }

    private func beginFallbackAfterCompressedRetry(
        initialRenderer: FakeAudioRenderer,
        in harness: AudioHarness,
        reason: String
    ) throws -> (retryRenderer: FakeAudioRenderer, removalIndex: Int) {
        try beginFallbackAfterCompressedRetry(
            initialRenderer: initialRenderer,
            renderers: harness.renderers,
            synchronizer: harness.synchronizer,
            executor: harness.executor,
            reason: reason
        )
    }

    private func fingerprint(_ value: UInt8) -> MediaFormatFingerprint {
        MediaFormatFingerprint(bytes: Data([value]))
    }

    private func makeFormat(codec: VPlayerPlayback.AudioCodec) throws -> CMAudioFormatDescription {
        return try AudioFormatDescriptionBuilder.make(SystemCompressedAudioFormat(
            profileID: profileID(for: codec),
            codec: codec,
            formatID: formatID(for: codec),
            sampleRate: 48_000,
            channelCount: 2,
            framesPerPacket: framesPerPacket(for: codec),
            layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
            magicCookie: codec == .aac ? Data([0x11, 0x90]) : nil
        )).description
    }

    private func makeRenderConfiguration(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data,
        fingerprint: MediaFormatFingerprint
    ) throws -> CompressedAudioRenderConfiguration {
        CompressedAudioRenderConfiguration(
            formatDescription: try makeFormat(codec: codec),
            codec: codec,
            decoderExtradata: extradata,
            fingerprint: fingerprint
        )
    }

    private func makeSample(
        id: UInt64,
        codec: VPlayerPlayback.AudioCodec = .aac,
        pts: CMTime = CMTime(value: 1, timescale: 10),
        duration: CMTime = CMTime(value: 1, timescale: 10),
        generation: MediaGeneration = MediaGeneration(rawValue: 1),
        continuityIslandID: AudioContinuityIslandID = AudioContinuityIslandID(rawValue: 1),
        payloadBytes: Int = 2
    ) throws -> CompressedAudioSample {
        let format = try makeFormat(codec: codec)
        let frame = CompressedAudioFrame(
            id: id,
            payload: Data(
                repeating: UInt8(truncatingIfNeeded: id),
                count: payloadBytes
            ),
            codec: codec,
            generation: generation,
            presentationTimeStamp: pts,
            duration: duration,
            frameSampleCount: Int32(framesPerPacket(for: codec) == 0
                ? 1_536
                : framesPerPacket(for: codec))
        )
        let buffer = try SampleBufferBuilder.makeAudio(
            frame: AdmittedAudioFrame(
                frame: frame,
                normalizedPresentationTimeStamp: pts,
                effectiveCoverageStartPTS: pts,
                duration: duration,
                continuityIslandID: continuityIslandID,
                startsNewIsland: false,
                gapBefore: nil,
                resetDecoderBeforeDecoding: false,
                fillDiscontinuitiesWithSilence: false
            ),
            formatDescription: format,
            forceResetDecoderBeforeDecoding: false
        )
        return CompressedAudioSample(
            id: id, sampleBuffer: buffer, codec: codec,
            generation: generation,
            presentationTimeStamp: pts, duration: duration,
            continuityIslandID: continuityIslandID
        )
    }

    private func makePCMBuffer(
        pts: CMTime,
        frameCount: Int = 2
    ) throws -> CMSampleBuffer {
        let samples = [Float](repeating: 0, count: frameCount * 2)
        let bytes = samples.withUnsafeBytes { Data($0) }
        return try PCMSampleBufferBuilder.make(
            bytes: bytes,
            frameCount: frameCount,
            sampleRate: 48_000,
            channels: 2,
            channelOrder: .native,
            channelLayoutMask: 3,
            presentationTimeStamp: pts
        )
    }

    private func copiedData(_ sampleBuffer: CMSampleBuffer) throws -> Data {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination.baseAddress!)
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        return data
    }

    private func copiedLayout(_ format: CMAudioFormatDescription) throws -> AudioToolbox.AudioChannelLayout {
        var size = 0
        let pointer = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size))
        XCTAssertGreaterThanOrEqual(size, MemoryLayout<AudioToolbox.AudioChannelLayout>.size)
        return pointer.pointee
    }

    private func perform(
        on executor: PlaybackSerialExecutor,
        _ operation: @escaping @Sendable () throws -> Void
    ) throws {
        let result = LockedAudioCallResult()
        let completed = expectation(description: "audio executor call")
        executor.submit {
            do { try operation(); result.store(nil) } catch { result.store(error) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        if let error = result.error { throw error }
    }

    private func performWithoutThrow(
        on executor: PlaybackSerialExecutor,
        _ operation: @escaping @Sendable () -> Void
    ) {
        let completed = expectation(description: "audio executor call")
        executor.submit { operation(); completed.fulfill() }
        wait(for: [completed], timeout: 5)
    }

    private func drain(_ executor: PlaybackSerialExecutor) {
        let completed = expectation(description: "audio executor fully drained")
        executor.submit {
            executor.submit { completed.fulfill() }
        }
        wait(for: [completed], timeout: 5)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition was not satisfied before timeout")
    }

    func testBluetoothRouteUpdatesDiagnosticOutputCategoryAndAnchorLeadTime() throws {
        let harness = try makeHarness(initialRouteCategory: .hdmi)
        XCTAssertEqual(harness.pipeline.diagnostics.outputCategory, .hdmi)
        XCTAssertEqual(harness.pipeline.anchorLeadTime.seconds, 0.100, accuracy: 0.001)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .bluetooth,
            reason: .newDeviceAvailable,
            revision: 1,
            outputLatency: 0.200,
            ioBufferDuration: 0.020
        ))
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.diagnostics.outputCategory, .bluetooth)
        XCTAssertEqual(harness.pipeline.diagnostics.routeRevision, 1)
        XCTAssertEqual(harness.pipeline.anchorLeadTime.seconds, 0.320, accuracy: 0.001)
    }

    func testCompressedStartupWaitsForRendererSufficiencyAcrossOutputConfigurationRecovery() throws {
        let harness = try makeHarness(codec: .ac3)
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        compressed.configureReadiness(ready: true, sufficient: false)

        XCTAssertFalse(harness.pipeline.isReadyForPlayback)

        for id in 1...15 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id),
                    codec: .ac3,
                    pts: CMTime(value: Int64((id - 1) * 30), timescale: 1_000),
                    duration: CMTime(value: 30, timescale: 1_000)
                ))
            }
        }
        drain(harness.executor)

        XCTAssertEqual(compressed.snapshot.enqueuedPTS.count, 15)
        XCTAssertFalse(harness.pipeline.isReadyForPlayback)

        compressed.emit(.outputConfigurationChanged)
        drain(harness.executor)
        harness.recoveryScheduler.advance(by: AudioRecoveryCoordinator.collectionDelay)
        drain(harness.executor)

        XCTAssertEqual(compressed.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(harness.pipeline.recoveryCount, 1)
        XCTAssertFalse(harness.pipeline.isReadyForPlayback)

        compressed.configureReadiness(ready: true, sufficient: true)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 16,
                codec: .ac3,
                pts: CMTime(value: 450, timescale: 1_000),
                duration: CMTime(value: 30, timescale: 1_000)
            ))
        }
        drain(harness.executor)

        XCTAssertTrue(harness.pipeline.isReadyForPlayback)
    }

    func testAirPlayRouteWithAC3FallsBackToPCMWithUnsupportedRouteReason() throws {
        let harness = try makeHarness(codec: .ac3, initialRouteCategory: .hdmi)
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        compressed.configureReadiness(ready: true, sufficient: true)

        XCTAssertEqual(harness.pipeline.route, .systemCompressed)
        XCTAssertEqual(harness.pipeline.diagnostics.pcmFallbackCount, 0)

        harness.routeMonitor.emit(AudioOutputRouteSnapshot(
            category: .airPlay,
            reason: .routeConfigurationChange,
            revision: 2
        ))
        drain(harness.executor)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.pipeline.diagnostics.pcmFallbackCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.lastFallbackReason, .unsupportedRoute)
    }

    func testInitialAirPlayRouteWithAC3FallsBackToPCMWithUnsupportedRouteReason() throws {
        let harness = try makeHarness(codec: .ac3, initialRouteCategory: .airPlay)
        drain(harness.executor)

        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.pipeline.diagnostics.pcmFallbackCount, 1)
        XCTAssertEqual(harness.pipeline.diagnostics.lastFallbackReason, .unsupportedRoute)
    }


    private func assertCoreError(
        _ expected: PlaybackCoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do { try body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch let error as PlaybackCoreError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }
}

private struct ResetAttachmentAudioHarness {
    let executor: PlaybackSerialExecutor
    let synchronizer: FakeAudioSynchronizer
    let renderer: ResetAttachmentAudioRenderer
    let renderers: ResetAttachmentAudioRendererFactory
    let failures: LockedAudioFailures
    let recoveryScheduler: ManualAudioRecoveryScheduler
    let pipeline: AudioRenderPipeline
}

private final class ResetAttachmentAudioRendererFactory:
    AudioRendererFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var nextIdentity: UInt64 = 1
    private var renderers: [ResetAttachmentAudioRenderer] = []

    func makeRenderer(mediaKind: AudioRendererMediaKind) throws -> any AudioRenderer {
        lock.withLock {
            let renderer = ResetAttachmentAudioRenderer(
                identity: AudioRendererIdentity(rawValue: nextIdentity),
                mediaKind: mediaKind
            )
            nextIdentity += 1
            renderers.append(renderer)
            return renderer
        }
    }

    var snapshot: [ResetAttachmentAudioRenderer] {
        lock.withLock { renderers }
    }
}

private final class ResetAttachmentAudioRenderer: AudioRenderer, @unchecked Sendable {
    let identity: AudioRendererIdentity
    let mediaKind: AudioRendererMediaKind

    private let lock = NSLock()
    private var ready = true
    private var sufficient = false
    private var enqueueResults: [AudioRendererEnqueueResult] = []
    private var attemptedResetDecoder: [Bool] = []
    private var acceptedResetDecoder: [Bool] = []
    private var readyHandler: (@Sendable () -> Void)?
    private var eventHandler: (@Sendable (AudioRendererEvent) -> Void)?
    private var requestCount = 0
    private var stopRequestCount = 0

    init(identity: AudioRendererIdentity, mediaKind: AudioRendererMediaKind) {
        self.identity = identity
        self.mediaKind = mediaKind
    }

    var isReadyForMoreMediaData: Bool { lock.withLock { ready } }

    var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        lock.withLock { sufficient }
    }

    func configureEnqueueResults(_ results: [AudioRendererEnqueueResult]) {
        lock.withLock { enqueueResults = results }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) throws -> AudioRendererEnqueueResult {
        let resetDecoder = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil
        ).map { CFEqual($0, kCFBooleanTrue) } ?? false
        return lock.withLock {
            attemptedResetDecoder.append(resetDecoder)
            let scriptedResult = enqueueResults.isEmpty ? nil : enqueueResults.removeFirst()
            guard ready, scriptedResult != .backpressured else { return .backpressured }
            acceptedResetDecoder.append(resetDecoder)
            return .accepted
        }
    }

    func flush() {}

    func requestMediaDataWhenReady(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            requestCount += 1
            readyHandler = handler
        }
    }

    func stopRequestingMediaData() {
        lock.withLock {
            stopRequestCount += 1
            readyHandler = nil
        }
    }

    func startObserving(_ handler: @escaping @Sendable (AudioRendererEvent) -> Void) {
        lock.withLock { eventHandler = handler }
    }

    func stopObserving() {
        lock.withLock { eventHandler = nil }
    }

    func fireReady() {
        lock.withLock { readyHandler }?()
    }

    func emit(_ event: AudioRendererEvent) {
        lock.withLock { eventHandler }?(event)
    }

    var attemptedResetDecoderSnapshot: [Bool] {
        lock.withLock { attemptedResetDecoder }
    }

    var acceptedResetDecoderSnapshot: [Bool] {
        lock.withLock { acceptedResetDecoder }
    }

    var requestCountSnapshot: Int { lock.withLock { requestCount } }
    var stopRequestCountSnapshot: Int { lock.withLock { stopRequestCount } }
}

private final class ControllableAVSampleBufferAudioRenderer:
    AVSampleBufferAudioRenderer,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedEnqueueCount = 0
    private var readyHandler: (@Sendable () -> Void)?

    override var isReadyForMoreMediaData: Bool { true }

    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
        lock.withLock { storedEnqueueCount += 1 }
    }

    override func requestMediaDataWhenReady(
        on queue: dispatch_queue_t,
        using block: @escaping @Sendable () -> Void
    ) {
        _ = queue
        lock.withLock { readyHandler = block }
    }

    override func stopRequestingMediaData() {
        lock.withLock { readyHandler = nil }
    }

    func fireReady() {
        lock.withLock { readyHandler }?()
    }

    var enqueueCount: Int { lock.withLock { storedEnqueueCount } }
}

private final class AlwaysBackpressuredAVSampleBufferAudioRenderer:
    AVSampleBufferAudioRenderer,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedEnqueueCount = 0
    private var storedRequestCount = 0
    private var storedStopRequestCount = 0

    override var isReadyForMoreMediaData: Bool { false }

    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
        lock.withLock { storedEnqueueCount += 1 }
    }

    override func requestMediaDataWhenReady(
        on queue: dispatch_queue_t,
        using block: @escaping @Sendable () -> Void
    ) {
        _ = queue
        _ = block
        lock.withLock { storedRequestCount += 1 }
    }

    override func stopRequestingMediaData() {
        lock.withLock { storedStopRequestCount += 1 }
    }

    var enqueueCount: Int {
        lock.withLock { storedEnqueueCount }
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    var stopRequestCount: Int {
        lock.withLock { storedStopRequestCount }
    }
}

private struct AudioHarness {
    let executor: PlaybackSerialExecutor
    let synchronizer: FakeAudioSynchronizer
    let renderers: FakeAudioRendererFactory
    let decoderFactory: FakePCMAudioDecoderFactory
    let routeMonitor: FakeAudioRouteMonitor
    let support: FakeAudioFormatSupportChecker
    let failures: LockedAudioFailures
    let recoveryScheduler: ManualAudioRecoveryScheduler
    let diagnosticsClock: ManualAudioDiagnosticsClock
    let pipeline: AudioRenderPipeline
}

private struct CapabilityAudioHarness {
    let executor: PlaybackSerialExecutor
    let synchronizer: FakeAudioSynchronizer
    let renderers: FakeAudioRendererFactory
    let decoderFactory: FakePCMAudioDecoderFactory
    let decodeCapability: FakeCoreAudioDecodeCapabilityChecker
    let pcmValidator: FakePCMOutputFormatValidator
    let failures: LockedAudioFailures
    let pipeline: AudioRenderPipeline
}

private final class ManualAudioDiagnosticsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func set(_ value: TimeInterval) {
        lock.withLock { self.value = value }
    }

    func now() -> TimeInterval {
        lock.withLock { value }
    }
}

private struct AudioFailureRecord: Sendable, Equatable {
    let error: PlaybackCoreError
    let generation: MediaGeneration
}

private final class LockedAudioFailures: @unchecked Sendable {
    private let lock = NSLock()
    private let executor: PlaybackSerialExecutor
    private var records: [AudioFailureRecord] = []
    init(executor: PlaybackSerialExecutor) { self.executor = executor }
    func append(_ error: PlaybackCoreError, generation: MediaGeneration) {
        XCTAssertTrue(executor.isIsolated)
        lock.lock(); records.append(.init(error: error, generation: generation)); lock.unlock()
    }
    var snapshot: [AudioFailureRecord] { lock.lock(); defer { lock.unlock() }; return records }
}

private struct AudioReadinessRecord: Sendable, Equatable {
    let change: AudioRenderReadinessChange
    let generation: MediaGeneration
}

private final class LockedAudioReadinessChanges: @unchecked Sendable {
    private let lock = NSLock()
    private let executor: PlaybackSerialExecutor
    private var records: [AudioReadinessRecord] = []
    init(executor: PlaybackSerialExecutor) { self.executor = executor }
    func append(_ change: AudioRenderReadinessChange, generation: MediaGeneration) {
        XCTAssertTrue(executor.isIsolated)
        lock.withLock { records.append(.init(change: change, generation: generation)) }
    }
    var snapshot: [AudioReadinessRecord] { lock.withLock { records } }
}

private final class LockedRouteSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private let executor: PlaybackSerialExecutor
    private var snapshots: [AudioOutputRouteSnapshot] = []
    private var isolation: [Bool] = []
    init(executor: PlaybackSerialExecutor) { self.executor = executor }
    func append(_ snapshot: AudioOutputRouteSnapshot) {
        lock.lock(); snapshots.append(snapshot); isolation.append(executor.isIsolated); lock.unlock()
    }
    var snapshot: [AudioOutputRouteSnapshot] { lock.lock(); defer { lock.unlock() }; return snapshots }
    var isolationSnapshot: [Bool] { lock.lock(); defer { lock.unlock() }; return isolation }
}

private final class MutableRouteLatency: @unchecked Sendable {
    private let lock = NSLock()
    private var outputLatency: TimeInterval
    private var ioBufferDuration: TimeInterval

    init(outputLatency: TimeInterval, ioBufferDuration: TimeInterval) {
        self.outputLatency = outputLatency
        self.ioBufferDuration = ioBufferDuration
    }

    func set(outputLatency: TimeInterval, ioBufferDuration: TimeInterval) {
        lock.withLock {
            self.outputLatency = outputLatency
            self.ioBufferDuration = ioBufferDuration
        }
    }

    func snapshot() -> (outputLatency: TimeInterval, ioBufferDuration: TimeInterval) {
        lock.withLock { (outputLatency, ioBufferDuration) }
    }
}

private final class RouteChangesDuringObserverInstallationNotificationCenter:
    NotificationCenter,
    @unchecked Sendable
{
    override func addObserver(
        forName name: Notification.Name?,
        object objectToObserve: Any?,
        queue: OperationQueue?,
        using block: @Sendable @escaping (Notification) -> Void
    ) -> any NSObjectProtocol {
        let observer = super.addObserver(
            forName: name,
            object: objectToObserve,
            queue: queue,
            using: block
        )
        for reason in [
            AVAudioSession.RouteChangeReason.newDeviceAvailable,
            .oldDeviceUnavailable,
        ] {
            post(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
        }
        return observer
    }
}

private final class ManualAudioRecoveryScheduler: @unchecked Sendable {
    private struct ScheduledOperation: Sendable {
        let deadlineNanoseconds: Int64
        let sequence: UInt64
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var nowNanoseconds: Int64 = 0
    private var nextSequence: UInt64 = 0
    private var scheduled: [ScheduledOperation] = []

    func schedule(
        after delay: DispatchTimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            scheduled.append(ScheduledOperation(
                deadlineNanoseconds: nowNanoseconds + delay.nanosecondsForAudioTests,
                sequence: nextSequence,
                operation: operation
            ))
            nextSequence += 1
        }
    }

    func advance(by interval: DispatchTimeInterval) {
        let ready = lock.withLock { () -> [ScheduledOperation] in
            nowNanoseconds += interval.nanosecondsForAudioTests
            let due = scheduled
                .filter { $0.deadlineNanoseconds <= nowNanoseconds }
                .sorted {
                    ($0.deadlineNanoseconds, $0.sequence) < ($1.deadlineNanoseconds, $1.sequence)
                }
            scheduled.removeAll { $0.deadlineNanoseconds <= nowNanoseconds }
            return due
        }
        for item in ready { item.operation() }
    }
}

private final class ExecutorIsolatedManualAudioRecoveryScheduler: @unchecked Sendable {
    private let executor: PlaybackSerialExecutor
    private let lock = NSLock()
    private var scheduled: [@Sendable () -> Void] = []

    init(executor: PlaybackSerialExecutor) {
        self.executor = executor
    }

    func schedule(
        after _: DispatchTimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) {
        lock.withLock { scheduled.append(operation) }
    }

    var pendingCount: Int {
        lock.withLock { scheduled.count }
    }

    func runNextOnExecutor() {
        let operation = lock.withLock { scheduled.removeFirst() }
        executor.submit(operation)
    }
}

private extension DispatchTimeInterval {
    var nanosecondsForAudioTests: Int64 {
        switch self {
        case let .seconds(value): Int64(value) * 1_000_000_000
        case let .milliseconds(value): Int64(value) * 1_000_000
        case let .microseconds(value): Int64(value) * 1_000
        case let .nanoseconds(value): Int64(value)
        case .never: Int64.max
        @unknown default: Int64.max
        }
    }
}

private final class LockedAudioCallResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func store(_ error: Error?) { lock.lock(); stored = error; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class LockedAudioCompletionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

private final class LegacySynchronousAudioPipeline: AudioRenderPipelineProtocol {
    var isReadyForPlayback = false
    var isOutputRouteReadyForSharedAnchor = true
    var route = AudioRoute.systemCompressed
    var currentRouteSnapshot: AudioOutputRouteSnapshot? {
        AudioOutputRouteSnapshot(category: .other, reason: .initial, revision: 0)
    }
    private(set) var stopCount = 0

    func configure(
        _: CompressedAudioRenderConfiguration,
        generation _: MediaGeneration
    ) throws {}

    func enqueue(_: CompressedAudioSample) throws {}
    func activateContinuityIsland(_: AudioContinuityIslandID, generation _: MediaGeneration) {}
    func updateRecoveryFloor(_: CMTime?) {}
    func prepareAnchor(at _: CMTime, in _: AudioContinuityIslandID) throws {}
    func recoverFromAudioSessionReset() {}
    func flush(to _: MediaGeneration) {}
    func stop() { stopCount += 1 }
}

private extension AudioRenderPipeline {
    func configure(
        format: CMAudioFormatDescription,
        codec: VPlayerPlayback.AudioCodec,
        generation: MediaGeneration,
        fingerprint: MediaFormatFingerprint
    ) throws {
        try configure(
            CompressedAudioRenderConfiguration(
                formatDescription: format,
                codec: codec,
                decoderExtradata: Data(),
                fingerprint: fingerprint
            ),
            generation: generation
        )
    }
}

private func formatID(for codec: VPlayerPlayback.AudioCodec) -> AudioFormatID {
    switch codec {
    case .aac: kAudioFormatMPEG4AAC
    case .ac3: kAudioFormatAC3
    case .eac3: kAudioFormatEnhancedAC3
    case .mp2: kAudioFormatMPEGLayer2
    case .mp1: kAudioFormatMPEGLayer1
    case .mp3: kAudioFormatMPEGLayer3
    }
}

private func profileID(for codec: VPlayerPlayback.AudioCodec) -> AudioCodecProfileID {
    switch codec {
    case .aac: .aacLC
    case .ac3: .ac3
    case .eac3: .eac3
    case .mp1: .mpegLayer1
    case .mp2: .mpegLayer2
    case .mp3: .mpegLayer3
    }
}

private func framesPerPacket(for codec: VPlayerPlayback.AudioCodec) -> UInt32 {
    switch codec {
    case .aac: 1_024
    case .ac3: 1_536
    case .eac3: 0
    case .mp1: 384
    case .mp2: 1_152
    case .mp3: 0
    }
}
