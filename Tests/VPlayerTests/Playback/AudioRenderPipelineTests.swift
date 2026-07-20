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

    func testReplayCapacityIsExactly96AndPrunesOnlyFullyExpiredSamples() throws {
        let harness = try makeHarness()
        for id in 0..<96 {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(
                    id: UInt64(id + 1),
                    pts: CMTime(value: Int64(id * 2), timescale: 10),
                    duration: CMTime(value: 2, timescale: 10)
                ))
            }
        }
        assertCoreError(.audioRendererFailed(AudioRenderPipeline.replayCapacityError)) {
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 97, pts: CMTime(value: 30, timescale: 1)))
            }
        }

        harness.synchronizer.setCurrentTime(CMTime(value: 3, timescale: 10))
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 98, pts: CMTime(value: 100, timescale: 1)))
        }
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        compressed.emit(.failed("force-replay-inspection"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        let pushed = try XCTUnwrap(harness.decoderFactory.snapshot.first).pushedIDSnapshot
        XCTAssertEqual(pushed.count, 96)
        XCTAssertTrue(pushed.contains(2), "overlapping sample must survive")
        XCTAssertFalse(pushed.contains(1), "fully expired sample must be pruned")
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

        compressed.emit(.failed("AVFoundationErrorDomain:-11800"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(harness.renderers.snapshot.count, 1, "replacement must wait for async removal")
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.0, 0)
        XCTAssertEqual(compressed.snapshot.stopRequestCount, 1)
        XCTAssertEqual(compressed.snapshot.observationStopCount, 1)

        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true, sufficient: true)
        pcm.fireReady()
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.synchronizer.attachedSnapshot, [compressed.identity, pcm.identity])
        XCTAssertEqual(compressed.snapshot.enqueuedFormatIDs, [kAudioFormatMPEG4AAC])
        XCTAssertEqual(pcm.snapshot.enqueuedFormatIDs, [kAudioFormatLinearPCM])
        XCTAssertEqual(harness.decoderFactory.snapshot.first?.pushedIDSnapshot, [44])
        XCTAssertEqual(pcm.snapshot.enqueuedPTS, [sample.presentationTimeStamp])
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.0, 1)
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.1, sample.presentationTimeStamp)
    }

    func testFalseRemovalAndDecoderAndSecondRendererFailuresEachEmitOneExactError() throws {
        do {
            let harness = try makeHarness()
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            compressed.emit(.failed("renderer:-1"))
            drain(harness.executor)
            harness.synchronizer.completeRemoval(didRemove: false)
            drain(harness.executor)
            harness.synchronizer.completeRemoval(didRemove: false)
            drain(harness.executor)
            XCTAssertEqual(harness.failures.snapshot.map(\.error), [
                .audioRendererFailed(AudioRenderPipeline.removalFailedError),
            ])
            XCTAssertEqual(harness.renderers.snapshot.count, 1)
        }

        do {
            let harness = try makeHarness()
            harness.decoderFactory.createError = .audioFallbackDecode(-12_345)
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            compressed.emit(.failed("renderer:-1"))
            drain(harness.executor)
            harness.synchronizer.completeRemoval(didRemove: true)
            drain(harness.executor)
            XCTAssertEqual(harness.failures.snapshot.map(\.error), [.audioFallbackDecode(-12_345)])
        }

        do {
            let harness = try makeHarness()
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            compressed.emit(.failed("renderer:-1"))
            drain(harness.executor)
            harness.synchronizer.completeRemoval(didRemove: true)
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

    func testAutomaticFlushOutputAndRouteRecoveryPauseReplayAndReanchor() throws {
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

        renderer.emit(.automaticFlush(CMTime(value: 2, timescale: 1)))
        drain(harness.executor)
        renderer.fireReady()
        drain(harness.executor)
        XCTAssertEqual(renderer.snapshot.enqueuedPTS.suffix(2), [
            CMTime(value: 2, timescale: 1), CMTime(value: 3, timescale: 1),
        ])
        XCTAssertEqual(harness.synchronizer.rateSnapshot.last?.1, CMTime(value: 2, timescale: 1))

        harness.synchronizer.setCurrentTime(CMTime(value: 3, timescale: 1))
        renderer.emit(.outputConfigurationChanged)
        drain(harness.executor)
        harness.routeMonitor.emit(.hdmi)
        drain(harness.executor)
        XCTAssertGreaterThanOrEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 3)
        XCTAssertEqual(harness.support.checkSnapshot.suffix(2).map(\.1), [.other, .hdmi])
    }

    func testExternallyClockedFallbackAndRecoveryReportReadinessWithoutChangingRateOrAnchor() throws {
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
            supportChecker: support,
            clockMode: .externallyManaged,
            readinessSink: { change, generation in readiness.append(change, generation: generation) }
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac),
                codec: .aac,
                generation: MediaGeneration(rawValue: 1)
            )
            try pipeline.enqueue(try self.makeSample(id: 1))
        }
        let compressed = try XCTUnwrap(renderers.snapshot.first)
        compressed.configureReadiness(ready: true, sufficient: true)
        compressed.fireReady()
        drain(executor)

        compressed.emit(.automaticFlush(CMTime(value: 1, timescale: 10)))
        drain(executor)
        compressed.fireReady()
        drain(executor)
        compressed.emit(.failed("force-fallback"))
        drain(executor)
        synchronizer.completeRemoval(didRemove: true)
        drain(executor)
        let pcm = try XCTUnwrap(renderers.snapshot.last)
        pcm.configureReadiness(ready: true, sufficient: true)
        pcm.fireReady()
        drain(executor)

        XCTAssertTrue(synchronizer.rateSnapshot.isEmpty)
        XCTAssertTrue(readiness.snapshot.map(\.change).contains(.invalidated))
        XCTAssertTrue(readiness.snapshot.map(\.change).contains(.available))
        XCTAssertTrue(failures.snapshot.isEmpty)
    }

    func testOverlappingRecoveryEventsMergeIntoOneFlushAndReevaluation() throws {
        let harness = try makeHarness()
        let renderer = try XCTUnwrap(harness.renderers.snapshot.first)
        renderer.emit(.automaticFlush(CMTime(value: 1, timescale: 1)))
        renderer.emit(.outputConfigurationChanged)
        harness.routeMonitor.emit(.hdmi)
        drain(harness.executor)

        XCTAssertEqual(renderer.snapshot.operations.filter { $0 == "flush" }.count, 1)
        XCTAssertEqual(harness.support.checkSnapshot.count, 1)
        XCTAssertEqual(harness.support.checkSnapshot.first?.1, .hdmi)
    }

    func testScheduledRecoveryCoalescesBehindFallbackAndRechecksPCMExactlyOnce() throws {
        for pcmSupported in [true, false] {
            let harness = try makeHarness()
            harness.support.requireRouteMatchingFormat = true
            harness.support.compressedSupported = false
            harness.support.pcmSupported = pcmSupported
            let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
            try perform(on: harness.executor) {
                try harness.pipeline.enqueue(try self.makeSample(id: 1))
            }

            compressed.emit(.outputConfigurationChanged)
            compressed.emit(.failed("force-fallback-before-scheduled-recovery"))
            drain(harness.executor)

            XCTAssertEqual(harness.synchronizer.removalCount, 1)
            XCTAssertTrue(
                harness.support.checkSnapshot.isEmpty,
                "scheduled recovery must not classify the route while replacement is active"
            )

            harness.synchronizer.completeRemoval(didRemove: true)
            drain(harness.executor)

            XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
            XCTAssertEqual(harness.support.checkSnapshot.map(\.0), [.ffmpegPCM])
            XCTAssertEqual(harness.support.formatIDSnapshot, [kAudioFormatLinearPCM])
            if pcmSupported {
                XCTAssertTrue(harness.failures.snapshot.isEmpty)
                XCTAssertEqual(harness.decoderFactory.snapshot.first?.flushCountSnapshot, 1)
            } else {
                XCTAssertEqual(harness.failures.snapshot.map(\.error), [
                    .audioRendererFailed(AudioRenderPipeline.unsupportedPCMError),
                ])
            }
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
        compressed.emit(.failed("force-pcm"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)

        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true)
        pcm.fireReady()
        drain(harness.executor)
        harness.routeMonitor.emit(.hdmi)
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
                generation: MediaGeneration(rawValue: 2)
            )
        }
        XCTAssertEqual(harness.renderers.snapshot.count, 1)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        XCTAssertEqual(first.snapshot.stopRequestCount, 1)
        XCTAssertEqual(harness.synchronizer.attachedSnapshot, [first.identity])

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .mp2),
                codec: .mp2,
                generation: MediaGeneration(rawValue: 3)
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
                generation: MediaGeneration(rawValue: 2)
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
                    generation: MediaGeneration(rawValue: 2)
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
                    generation: MediaGeneration(rawValue: 2)
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
        compressed.emit(.failed("force-pcm"))
        drain(harness.executor)

        performWithoutThrow(on: harness.executor) {
            harness.pipeline.flush(to: MediaGeneration(rawValue: 2))
        }
        XCTAssertEqual(compressed.snapshot.requestCount, 1)
        XCTAssertEqual(compressed.snapshot.observationStartCount, 1)
        XCTAssertEqual(harness.renderers.snapshot.count, 1)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(
                id: 2,
                pts: CMTime(value: 2, timescale: 10),
                generation: MediaGeneration(rawValue: 2)
            ))
        }
        XCTAssertEqual(compressed.snapshot.enqueuedPTS.count, 1)

        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        let pcm = try XCTUnwrap(harness.renderers.snapshot.last)
        pcm.configureReadiness(ready: true)
        pcm.fireReady()
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        XCTAssertEqual(harness.renderers.snapshot.count, 2)
        XCTAssertEqual(harness.decoderFactory.snapshot.first?.pushedIDSnapshot, [2])
        XCTAssertEqual(pcm.snapshot.enqueuedFormatIDs, [kAudioFormatLinearPCM])
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
        XCTAssertEqual(compressed.snapshot.requestCount, 1)
        XCTAssertEqual(compressed.snapshot.observationStartCount, 1)
    }

    func testRouteMonitorUsesActualNotificationAndCopiesOnlyCategoryOnExecutor() {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.route")
        let center = NotificationCenter()
        let categories = LockedCategories(executor: executor)
        let monitor = AudioOutputRouteMonitor(
            executor: executor,
            notificationCenter: center,
            snapshotProvider: { [.HDMI, .airPlay] }
        )
        monitor.start { categories.append($0) }

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: "Living Room Apple TV secret UID",
            userInfo: ["portName": "Do Not Capture", "UID": "secret"]
        )
        drain(executor)

        XCTAssertEqual(categories.snapshot, [.hdmi])
        XCTAssertEqual(categories.isolationSnapshot, [true])
        XCTAssertFalse(String(describing: categories.snapshot).contains("Living Room"))
        monitor.stop()
    }

    func testRouteMonitorDropsNotificationQueuedBeforeStopAndRestart() {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.route-stale")
        let center = NotificationCenter()
        let categories = LockedCategories(executor: executor)
        let monitor = AudioOutputRouteMonitor(
            executor: executor,
            notificationCenter: center,
            snapshotProvider: { [.HDMI] }
        )
        monitor.start { _ in XCTFail("old handler must not run") }
        center.post(name: AVAudioSession.routeChangeNotification, object: nil)
        monitor.stop()
        monitor.start { categories.append($0) }
        drain(executor)

        XCTAssertTrue(categories.snapshot.isEmpty)
        monitor.stop()
    }

    func testUnsupportedCompressedRouteFallsBackOnceAndUnsupportedPCMTerminates() throws {
        let harness = try makeHarness()
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        harness.support.compressedSupported = false
        harness.routeMonitor.emit(.airPlay)
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)

        harness.support.pcmSupported = false
        harness.routeMonitor.emit(.hdmi)
        harness.routeMonitor.emit(.hdmi)
        drain(harness.executor)
        XCTAssertEqual(harness.failures.snapshot.map(\.error), [
            .audioRendererFailed(AudioRenderPipeline.unsupportedPCMError),
        ])
        XCTAssertEqual(harness.renderers.snapshot.count, 2)
    }

    func testOldCallbacksAfterConfigureFlushStopAndRemovalAreHarmless() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.renderers.snapshot.first)
        first.emit(.failed("first"))
        drain(harness.executor)
        XCTAssertEqual(harness.synchronizer.removalCount, 1)

        try perform(on: harness.executor) {
            try harness.pipeline.configure(
                format: try self.makeFormat(codec: .ac3),
                codec: .ac3,
                generation: MediaGeneration(rawValue: 2)
            )
        }
        harness.synchronizer.completeRemoval(index: 0, didRemove: true)
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
        harness.routeMonitor.emit(.hdmi)
        drain(harness.executor)
        XCTAssertTrue(harness.failures.snapshot.isEmpty)
    }

    func testPCMAdapterDeepCopiesBorrowedMemoryAndPreservesExactTokenPTSAndLayout() throws {
        let native = FakeFFmpegAudioDecoderAPI()
        let decoder = try FFmpegPCMAudioDecoder(
            codec: .aac,
            format: makeFormat(codec: .aac),
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
        XCTAssertEqual(layout.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelBitmap)
        XCTAssertEqual(layout.mChannelBitmap.rawValue, 3)
    }

    func testLivePCMDecoderCreateWithoutCookieUsesNullZeroABIAndDestroys() throws {
        let decoder = try FFmpegPCMAudioDecoder(
            codec: .ac3,
            format: makeFormat(codec: .ac3)
        )
        decoder.destroy()
        decoder.destroy()
    }

    func testPCMAdapterRejectsUnknownMalformedFutureAndOverflowingCallbacks() throws {
        let native = FakeFFmpegAudioDecoderAPI()
        let decoder = try FFmpegPCMAudioDecoder(codec: .aac, format: makeFormat(codec: .aac), api: native)
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
            let decoder = try FFmpegPCMAudioDecoder(codec: .aac, format: makeFormat(codec: .aac), api: native)
            assertCoreError(.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)) {
                _ = try decoder.push(makeSample(id: 1))
            }
        }
        do {
            let native = FakeFFmpegAudioDecoderAPI()
            native.overrideABIVersion = 2
            native.outputScripts = [[.stereo(frames: 1)]]
            let decoder = try FFmpegPCMAudioDecoder(codec: .aac, format: makeFormat(codec: .aac), api: native)
            assertCoreError(.audioFallbackDecode(FFmpegPCMAudioDecoder.invalidCallbackErrorCode)) {
                _ = try decoder.push(makeSample(id: 1))
            }
        }
        do {
            let native = FakeFFmpegAudioDecoderAPI()
            native.overrideStructSize = 72
            native.outputScripts = [[.stereo(frames: 1)]]
            let decoder = try FFmpegPCMAudioDecoder(codec: .aac, format: makeFormat(codec: .aac), api: native)
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
        compressed.emit(.failed("force-fallback"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)
        compressed.emit(.failed("duplicate"))
        drain(harness.executor)

        XCTAssertEqual(harness.failures.snapshot.map(\.error), [.audioFallbackDecode(-32_109)])
    }

    func testPCMEnqueueDecodeFailureEmitsOnceWithoutThrowingOrRepeatingWork() throws {
        let harness = try makeHarness()
        let compressed = try XCTUnwrap(harness.renderers.snapshot.first)
        try perform(on: harness.executor) {
            try harness.pipeline.enqueue(try self.makeSample(id: 1))
        }
        compressed.emit(.failed("force-fallback"))
        drain(harness.executor)
        harness.synchronizer.completeRemoval(didRemove: true)
        drain(harness.executor)

        XCTAssertEqual(harness.pipeline.route, .ffmpegPCM)
        let decoder = try XCTUnwrap(harness.decoderFactory.snapshot.first)
        XCTAssertEqual(decoder.pushedIDSnapshot, [1])
        performWithoutThrow(on: harness.executor) {
            harness.pipeline.flush(to: MediaGeneration(rawValue: 2))
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
            supportChecker: support
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: .aac), codec: .aac,
                generation: MediaGeneration(rawValue: 1)
            )
            for id in 1...96 { try pipeline.enqueue(try self.makeSample(id: UInt64(id))) }
        }
        let compressed = try XCTUnwrap(renderers.snapshot.first)
        compressed.emit(.failed("force-fallback"))
        drain(executor)
        synchronizer.completeRemoval(didRemove: true)
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

        for codec in [VPFF_CODEC_AAC, VPFF_CODEC_AC3, VPFF_CODEC_EAC3, VPFF_CODEC_MP2] {
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
            XCTAssertLessThan(vp_ffmpeg_audio_decoder_push(handle, &invalid, 1, 7), 0)
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

    private func makeHarness(codec: VPlayerPlayback.AudioCodec = .aac) throws -> AudioHarness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.audio")
        let synchronizer = FakeAudioSynchronizer()
        let renderers = FakeAudioRendererFactory()
        let decoderFactory = FakePCMAudioDecoderFactory { sample in
            [try self.makePCMBuffer(pts: sample.presentationTimeStamp)]
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
            supportChecker: support
        )
        try perform(on: executor) {
            try pipeline.configure(
                format: try self.makeFormat(codec: codec),
                codec: codec,
                generation: MediaGeneration(rawValue: 1)
            )
        }
        return AudioHarness(
            executor: executor, synchronizer: synchronizer, renderers: renderers,
            decoderFactory: decoderFactory, routeMonitor: routeMonitor,
            support: support, failures: failures, pipeline: pipeline
        )
    }

    private func makeFormat(codec: VPlayerPlayback.AudioCodec) throws -> CMAudioFormatDescription {
        try AudioFormatDescriptionBuilder.make(
            codec: codec,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            cookie: codec == .aac ? Data([0x11, 0x90]) : nil
        ).description
    }

    private func makeSample(
        id: UInt64,
        codec: VPlayerPlayback.AudioCodec = .aac,
        pts: CMTime = CMTime(value: 1, timescale: 10),
        duration: CMTime = CMTime(value: 1, timescale: 10),
        generation: MediaGeneration = MediaGeneration(rawValue: 1)
    ) throws -> CompressedAudioSample {
        let format = try makeFormat(codec: codec)
        let buffer = try SampleBufferBuilder.makeAudio(
            data: Data([UInt8(truncatingIfNeeded: id), 0xAA]),
            formatDescription: format,
            presentationTimeStamp: pts,
            variableFramesInPacket: codec == .aac ? 1_024 : 1_536
        )
        return CompressedAudioSample(
            id: id, sampleBuffer: buffer, codec: codec,
            generation: generation,
            presentationTimeStamp: pts, duration: duration
        )
    }

    private func makePCMBuffer(pts: CMTime) throws -> CMSampleBuffer {
        let samples = [Float](repeating: 0, count: 4)
        let bytes = samples.withUnsafeBytes { Data($0) }
        return try PCMSampleBufferBuilder.make(
            bytes: bytes,
            frameCount: 2,
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

private struct AudioHarness {
    let executor: PlaybackSerialExecutor
    let synchronizer: FakeAudioSynchronizer
    let renderers: FakeAudioRendererFactory
    let decoderFactory: FakePCMAudioDecoderFactory
    let routeMonitor: FakeAudioRouteMonitor
    let support: FakeAudioFormatSupportChecker
    let failures: LockedAudioFailures
    let pipeline: AudioRenderPipeline
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

private final class LockedCategories: @unchecked Sendable {
    private let lock = NSLock()
    private let executor: PlaybackSerialExecutor
    private var categories: [AudioOutputCategory] = []
    private var isolation: [Bool] = []
    init(executor: PlaybackSerialExecutor) { self.executor = executor }
    func append(_ category: AudioOutputCategory) {
        lock.lock(); categories.append(category); isolation.append(executor.isIsolated); lock.unlock()
    }
    var snapshot: [AudioOutputCategory] { lock.lock(); defer { lock.unlock() }; return categories }
    var isolationSnapshot: [Bool] { lock.lock(); defer { lock.unlock() }; return isolation }
}

private final class LockedAudioCallResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func store(_ error: Error?) { lock.lock(); stored = error; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
}

private func formatID(for codec: VPlayerPlayback.AudioCodec) -> AudioFormatID {
    switch codec {
    case .aac: kAudioFormatMPEG4AAC
    case .ac3: kAudioFormatAC3
    case .eac3: kAudioFormatEnhancedAC3
    case .mp2: kAudioFormatMPEGLayer2
    }
}
