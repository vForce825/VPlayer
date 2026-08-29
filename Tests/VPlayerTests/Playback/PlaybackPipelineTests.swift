// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import Metal
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class PlaybackPipelineTests: XCTestCase {
    func testAudioConfigurationUsesActiveSourceTrackExtradata() async throws {
        let sourceExtradata = Data([0x13, 0x88, 0x42])
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks(
            audioExtradata: sourceExtradata
        )))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA8]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(
                fingerprint: fingerprint,
                decoderExtradata: sourceExtradata
            )
        ))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), fingerprint
        ))

        try await eventually { harness.audio.snapshot().configured.count == 1 }
        XCTAssertEqual(harness.audio.snapshot().configured.last?.3, sourceExtradata)
    }

    func testReadinessMetricsForwardAudioRenderDiagnostics() async throws {
        let metrics = PlaybackMetrics(channelID: "audio-diagnostics", now: { 1 })
        let diagnostics = AudioRenderDiagnostics(
            automaticFlushTriggerCount: 1,
            outputConfigurationTriggerCount: 2,
            routeChangeTriggerCount: 3,
            recoveryTransactionCount: 4,
            suppressedCorrelatedTriggerCount: 5,
            compressedRendererRetryCount: 6,
            pcmFallbackCount: 7,
            lastFallbackReason: .repeatedCompressedRendererFailure,
            startupWaitingSeconds: 8.5,
            rendererReady: true,
            rendererSufficient: false
        )
        let harness = makeHarness(metrics: metrics, audioDiagnostics: diagnostics)

        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try await eventually {
            metrics.snapshot(window: .seconds(60)).audioRecoveryTransactionCount == 4
        }
        let snapshot = metrics.snapshot(window: .seconds(60))

        XCTAssertEqual(snapshot.audioAutomaticFlushTriggerCount, 1)
        XCTAssertEqual(snapshot.audioOutputConfigurationTriggerCount, 2)
        XCTAssertEqual(snapshot.audioRouteChangeTriggerCount, 3)
        XCTAssertEqual(snapshot.audioRecoveryTransactionCount, 4)
        XCTAssertEqual(snapshot.audioSuppressedCorrelatedTriggerCount, 5)
        XCTAssertEqual(snapshot.audioCompressedRendererRetryCount, 6)
        XCTAssertEqual(snapshot.audioPCMFallbackCount, 7)
        XCTAssertEqual(snapshot.audioLastFallbackReason, .repeatedCompressedRendererFailure)
        XCTAssertEqual(snapshot.audioStartupWaitingSeconds, 8.5)
        XCTAssertTrue(snapshot.audioRendererReady)
        XCTAssertFalse(snapshot.audioRendererSufficient)
    }

    func testMetricsSnapshotResamplesStartupWaitWithoutAnotherMediaEvent() async throws {
        let diagnosticsClock = PipelineAudioDiagnosticsClock(value: 10)
        let metrics = PlaybackMetrics(channelID: "fresh-audio-diagnostics", now: { 10 })
        let harness = makeHarness(
            metrics: metrics,
            useRealCompressedAudio: true,
            audioDiagnosticsNow: diagnosticsClock.now
        )
        harness.pipeline.start(url: makeRequest().streamURL)
        _ = await harness.pipeline.debugSnapshot()
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        _ = await harness.pipeline.debugSnapshot()
        let fingerprint = MediaFormatFingerprint(bytes: Data([0xB2]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), fingerprint
        ))
        let generation = await harness.pipeline.debugSnapshot().generation

        let audio = try XCTUnwrap(harness.compressedAudio)
        let renderer = try XCTUnwrap(audio.renderers.snapshot.first)
        renderer.configureReadiness(ready: true, sufficient: false)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        _ = await harness.pipeline.debugSnapshot()

        XCTAssertEqual(
            harness.pipeline.metricsSnapshot(window: .seconds(60))?.audioStartupWaitingSeconds,
            0
        )
        diagnosticsClock.set(14.25)

        XCTAssertEqual(
            try XCTUnwrap(
                harness.pipeline.metricsSnapshot(window: .seconds(60))?.audioStartupWaitingSeconds
            ),
            4.25,
            accuracy: 0.001
        )
    }

    func testSystemFactorySynchronizerDoesNotDelayRateChangesForMediaReadiness() {
        let synchronizer = SystemPlaybackPipelineFactory.makeSynchronizer()

        XCTAssertFalse(synchronizer.delaysRateChangeUntilHasSufficientMediaData)
    }

    func testCompressedRetryBeforeSharedGateOpenRequiresReplacementAudioPreroll() async throws {
        let harness = makeHarness(useRealCompressedAudio: true)
        harness.pipeline.start(url: makeRequest().streamURL)
        _ = await harness.pipeline.debugSnapshot()
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        _ = await harness.pipeline.debugSnapshot()

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xB1]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), fingerprint
        ))
        let configured = await harness.pipeline.debugSnapshot()
        let generation = configured.generation
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 0,
            generation: generation,
            randomAccess: true,
            pts: .zero
        )))
        _ = await harness.pipeline.debugSnapshot()

        let audio = try XCTUnwrap(harness.compressedAudio)
        let firstRenderer = try XCTUnwrap(audio.renderers.snapshot.first)
        firstRenderer.configureReadiness(ready: true, sufficient: true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        _ = await harness.pipeline.debugSnapshot()

        XCTAssertTrue(audio.pipeline.isReadyForPlayback)
        XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)

        firstRenderer.emit(.failed("AVFoundation:-11819"))
        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(audio.synchronizer.removalCount, 1)
        audio.synchronizer.completeRemoval(index: 0, didRemove: true)
        _ = await harness.pipeline.debugSnapshot()

        let replacement = try XCTUnwrap(audio.renderers.snapshot.last)
        replacement.configureReadiness(ready: true, sufficient: false)
        replacement.fireReady()
        _ = await harness.pipeline.debugSnapshot()

        XCTAssertFalse(
            audio.pipeline.isReadyForPlayback,
            "a replacement renderer cannot inherit audio-only preroll before shared playback opens"
        )

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        _ = await harness.pipeline.debugSnapshot()

        XCTAssertTrue(
            harness.clock.snapshot().anchors.isEmpty,
            "video availability must not open the gate while replacement audio is insufficient"
        )

        replacement.configureReadiness(ready: true, sufficient: true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 2),
            duration: CMTime(value: 1, timescale: 2)
        )))
        _ = await harness.pipeline.debugSnapshot()

        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)
        XCTAssertEqual(
            harness.events.snapshot().filter {
                if case .ready = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testControllerClearsMediaInformationAcrossReplacementAndFailure() async throws {
        let first = FakeControllerPipeline()
        let second = FakeControllerPipeline()
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([first, second]))
        var info = await controller.playbackMediaInformation().makeAsyncIterator()
        let initial = await info.next()
        let initialInformation = try XCTUnwrap(initial)
        XCTAssertNil(initialInformation)

        await controller.play(makeRequest(title: "first"))
        first.emit(.mediaInformation(PlaybackMediaInformation(
            width: 1_920,
            height: 1_080,
            scanMode: .interlaced,
            sourceFrameRate: MediaRational(num: 25, den: 1),
            outputFrameRate: 50,
            isSmoothMotionEnhanced: true
        )))
        let publishedEvent = await info.next()
        let published = try XCTUnwrap(publishedEvent.flatMap { $0 })
        XCTAssertEqual(published.width, 1_920)

        await controller.play(makeRequest(title: "second"))
        let cleared = await info.next()
        let clearedInformation = try XCTUnwrap(cleared)
        XCTAssertNil(clearedInformation)

        second.emit(.mediaInformation(PlaybackMediaInformation(
            width: 1_280,
            height: 720,
            scanMode: .progressive,
            sourceFrameRate: MediaRational(num: 30, den: 1),
            outputFrameRate: 30,
            isSmoothMotionEnhanced: false
        )))
        let secondPublishedEvent = await info.next()
        _ = try XCTUnwrap(secondPublishedEvent.flatMap { $0 })

        second.emit(.failed(.demuxRead(-1)))
        let clearedOnFailure = await info.next()
        let failureInformation = try XCTUnwrap(clearedOnFailure)
        XCTAssertNil(failureInformation)
    }

    func testVideoReadinessWaitsForClassificationAndMediaInformation() async throws {
        let harness = makeHarness(
            classifierConfiguration: ScanClassifierConfiguration(
                progressiveConfirmationFrames: 2,
                psfConfirmationFrames: 2,
                exitInterlacedConfirmationFrames: 2
            )
        )
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))

        let first = try PlaybackFakeMedia.decodedFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            interlaced: false
        )
        harness.pipeline.receive(decoder: .frame(first))
        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(harness.processor.snapshot().metadata.count, 0)
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
        XCTAssertFalse(harness.events.snapshot().contains {
            if case .mediaInformation = $0 { return true }
            return false
        })

        let second = try PlaybackFakeMedia.decodedFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 25),
            interlaced: false
        )
        harness.pipeline.receive(decoder: .frame(second))
        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(harness.processor.snapshot().metadata.count, 0)
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))

        let third = try PlaybackFakeMedia.decodedFrame(
            id: 3,
            generation: generation,
            pts: CMTime(value: 2, timescale: 25),
            interlaced: false
        )
        harness.pipeline.receive(decoder: .frame(third))
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        let events = harness.events.snapshot()
        let informationIndex = try XCTUnwrap(events.firstIndex {
            if case let .mediaInformation(information, _) = $0 { return information != nil }
            return false
        })
        let readyIndex = try XCTUnwrap(events.firstIndex(of: .ready(readinessCycle: 0)))
        XCTAssertLessThan(informationIndex, readyIndex)
        XCTAssertEqual(events.filter { $0 == .ready(readinessCycle: 0) }.count, 1)
    }

    func testStartupKeepsDecodingUntilFieldScanClassificationCanOpenReadiness() async throws {
        let harness = makeHarness(scanProbe: InconclusivePipelineScanProbe())
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 2, timescale: 1)
        )))

        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 0,
            generation: generation,
            pts: .zero,
            interlaced: true
        )))
        _ = await harness.pipeline.debugSnapshot()

        for id in 1...6 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(id),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: Int64(id), timescale: 25)
            )))
            try await eventually {
                harness.decoder.snapshot().contains(.decode(
                    UInt64(id),
                    generation,
                    ._EnableAsynchronousDecompression
                ))
            }
            harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
                id: UInt64(id),
                generation: generation,
                pts: CMTime(value: Int64(id), timescale: 25),
                interlaced: true
            )))
            _ = await harness.pipeline.debugSnapshot()
        }

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        let information = try XCTUnwrap(harness.events.snapshot().compactMap {
            event -> PlaybackMediaInformation? in
            guard case let .mediaInformation(information, eventGeneration) = event,
                  eventGeneration == generation else { return nil }
            return information
        }.last)
        XCTAssertEqual(information.scanMode, .interlaced)
        XCTAssertTrue(information.isSmoothMotionEnhanced)
    }

    func testAudioOnlyReadinessDoesNotWaitForVideoInformation() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.audioOnlyTracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA1]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1)
        }
        let generation = await harness.pipeline.debugSnapshot().generation
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertFalse(harness.events.snapshot().contains {
            if case .mediaInformation = $0 { return true }
            return false
        })
    }

    func testAudioOnlyReadinessAnchorsClockAndResumesAtRateOne() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.audioOnlyTracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA2]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1)
        }
        let generation = await harness.pipeline.debugSnapshot().generation
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
                && harness.clock.snapshot().anchors.count == 1
        }
        let openingAnchor = try XCTUnwrap(harness.clock.snapshot().anchors.first)
        XCTAssertEqual(CMTimeCompare(openingAnchor.0, .zero), 0)
        XCTAssertEqual(openingAnchor.2, 1)

        let pausesBeforePause = harness.clock.snapshot().pauses
        harness.pipeline.setPaused(true, readinessCycle: 1)
        try await eventually { (await harness.pipeline.debugSnapshot()).isPaused }
        XCTAssertGreaterThan(harness.clock.snapshot().pauses, pausesBeforePause)

        harness.pipeline.setPaused(false, readinessCycle: 2)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 2))
                && harness.clock.snapshot().anchors.count == 2
        }
        let resumedAnchor = try XCTUnwrap(harness.clock.snapshot().anchors.last)
        XCTAssertEqual(CMTimeCompare(resumedAnchor.0, .zero), 0)
        XCTAssertEqual(resumedAnchor.2, 1)
    }

    func testAudioOnlyResumeNeverReanchorsBeforeRecoveryFloor() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.audioOnlyTracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA3]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1)
        }
        let generation = await harness.pipeline.debugSnapshot().generation
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: CMTime(value: 10, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
                && harness.clock.snapshot().anchors.count == 1
        }

        // Keep a retained audio interval that starts before the running clock
        // while still covering it. A resume must not use that old first PTS as
        // a new anchor.
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 20, timescale: 1)
        )))
        _ = await harness.pipeline.debugSnapshot()
        harness.pipeline.setPaused(true, readinessCycle: 1)
        try await eventually { (await harness.pipeline.debugSnapshot()).isPaused }

        harness.pipeline.setPaused(false, readinessCycle: 2)
        try await eventually { harness.events.snapshot().filter {
            if case .ready = $0 { return true }
            return false
        }.count == 2 }

        let anchors = harness.clock.snapshot().anchors
        XCTAssertEqual(anchors.count, 2)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(anchors[1].0, anchors[0].0), 0)
    }

    func testAudioOnlyReadinessWaitsForDisplayModeAnchorBeforePublishingReady() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.audioOnlyTracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA4]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1)
        }
        let generation = await harness.pipeline.debugSnapshot().generation
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: CMTime(value: 4, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
                && harness.clock.snapshot().anchors.count == 1
        }

        harness.pipeline.displayModeSwitchStarted()
        harness.pipeline.refreshReadiness()
        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(harness.events.snapshot().filter {
            if case .ready = $0 { return true }
            return false
        }.count, 1)

        harness.pipeline.displayModeSwitchEnded()
        try await eventually {
            harness.events.snapshot().filter {
                if case .ready = $0 { return true }
                return false
            }.count == 2 && harness.clock.snapshot().anchors.count == 2
        }
    }

    func testAudioOnlyAnchorPreparationIgnoresSynchronousReadinessReentry() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.audioOnlyTracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA5]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1)
        }
        let generation = await harness.pipeline.debugSnapshot().generation
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: CMTime(value: 6, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
                && harness.clock.snapshot().anchors.count == 1
        }
        let resetsBeforeResume = harness.renderer.snapshot().resets

        harness.audio.setSynchronousReadinessCallback(onPrepare: true, maxCallbacks: 4) {
            [pipeline = harness.pipeline] generation in
            pipeline.receive(audioReadiness: .available, generation: generation)
        }
        harness.pipeline.setPaused(true, readinessCycle: 1)
        try await eventually { (await harness.pipeline.debugSnapshot()).isPaused }
        harness.pipeline.setPaused(false, readinessCycle: 2)
        _ = await harness.pipeline.debugSnapshot()

        let events = harness.events.snapshot()
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 2)
        XCTAssertEqual(events.filter {
            if case .ready = $0 { return true }
            return false
        }.count, 2)
        XCTAssertEqual(harness.audio.synchronousReadinessCallbackCountSnapshot, 1)
        XCTAssertEqual(harness.renderer.snapshot().resets, resetsBeforeResume + 1)
    }

    func testDecoderSessionRestartClearsMediaInformationAndCadenceBeforeRebuild() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 8, timescale: 1)
        )))

        let oldFrames = try (0..<7).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(10 + index),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 25),
                interlaced: true,
                duration: CMTime(value: 1, timescale: 25),
                pictureStructure: .topField
            )
        }
        try receiveAndReleaseNormalizedFrames(oldFrames, in: harness)
        try await eventually {
            harness.events.snapshot().contains { event in
                if case let .mediaInformation(information, eventGeneration) = event {
                    return information != nil && eventGeneration == generation
                }
                return false
            }
        }
        let oldInformation = try XCTUnwrap(harness.events.snapshot().compactMap { event -> PlaybackMediaInformation? in
            if case let .mediaInformation(information, eventGeneration) = event,
               eventGeneration == generation {
                return information
            }
            return nil
        }.last)
        XCTAssertEqual(try XCTUnwrap(oldInformation.outputFrameRate), 50, accuracy: 0.001)

        harness.pipeline.receive(decoder: .submissionFailure(
            .malfunction(kVTVideoDecoderMalfunctionErr),
            generation: generation
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation > generation
        }
        let restartedGeneration = await harness.pipeline.debugSnapshot().generation
        try await eventually {
            harness.events.snapshot().contains { event in
                if case let .mediaInformation(information, eventGeneration) = event {
                    return information == nil && eventGeneration == restartedGeneration
                }
                return false
            }
        }

        let newFrames = try (0..<7).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(20 + index),
                generation: restartedGeneration,
                pts: CMTime(value: Int64(index), timescale: 20),
                interlaced: true,
                duration: CMTime(value: 1, timescale: 20),
                pictureStructure: .topField
            )
        }
        try receiveAndReleaseNormalizedFrames(newFrames, in: harness)
        try await eventually {
            harness.events.snapshot().contains { event in
                if case let .mediaInformation(information, eventGeneration) = event {
                    return information != nil && eventGeneration == restartedGeneration
                }
                return false
            }
        }

        let events = harness.events.snapshot()
        let nilIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .mediaInformation(information, eventGeneration) = event {
                return information == nil && eventGeneration == restartedGeneration
            }
            return false
        })
        let rebuiltIndex = try XCTUnwrap(events.firstIndex { event in
            if case let .mediaInformation(information, eventGeneration) = event {
                return information != nil && eventGeneration == restartedGeneration
            }
            return false
        })
        XCTAssertLessThan(nilIndex, rebuiltIndex)
        let rebuiltInformation: PlaybackMediaInformation
        if case let .mediaInformation(information?, _) = events[rebuiltIndex] {
            rebuiltInformation = information
        } else {
            XCTFail("expected rebuilt media information")
            return
        }
        XCTAssertEqual(try XCTUnwrap(rebuiltInformation.outputFrameRate), 40, accuracy: 0.001)
    }

    func testBypassWithoutTrustedSourceFrameRateLeavesOutputFrameRateUnknown() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false,
                duration: CMTime(value: 1, timescale: 25)
            ),
        ], in: harness)

        var information: PlaybackMediaInformation?
        try await eventually {
            information = harness.events.snapshot().compactMap { event -> PlaybackMediaInformation? in
                if case let .mediaInformation(information, eventGeneration) = event,
                   eventGeneration == generation {
                    return information
                }
                return nil
            }.first
            return information != nil
        }
        let resolvedInformation = try XCTUnwrap(information)
        XCTAssertNil(resolvedInformation.sourceFrameRate)
        XCTAssertNil(resolvedInformation.outputFrameRate)
        XCTAssertFalse(resolvedInformation.isSmoothMotionEnhanced)
    }

    func testControllerPublishesOnlyCurrentSessionPresentationContextAndClearsItOnFailure() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = PlaybackPresentationContext(
            renderer: FakePipelineVideoRenderer(),
            clock: FakePipelineClock(),
            device: device
        )
        let first = FakeControllerPipeline(presentationContext: context)
        let second = FakeControllerPipeline()
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([first, second]))

        let contextBeforePlay = await controller.presentationContext()
        XCTAssertNil(contextBeforePlay)
        await controller.play(makeRequest(title: "first"))
        let firstContext = await controller.presentationContext()
        XCTAssertTrue(firstContext === context)
        await controller.play(makeRequest(title: "second"))
        let secondContext = await controller.presentationContext()
        XCTAssertNil(secondContext)
        second.emit(.failed(.demuxRead(-1)))
        try await Task.sleep(for: .milliseconds(20))
        let failedContext = await controller.presentationContext()
        XCTAssertNil(failedContext)
    }

    func testControllerMetricsProviderPublishesOnlyTheCurrentSessionCollector() async throws {
        let firstMetrics = PlaybackMetrics(
            channelID: "first",
            now: { 60 },
            residentMemoryProvider: { 11 }
        )
        firstMetrics.recordDecoderCallback()
        let secondMetrics = PlaybackMetrics(
            channelID: "second",
            now: { 60 },
            residentMemoryProvider: { 22 }
        )
        let first = FakeControllerPipeline(metrics: firstMetrics)
        let second = FakeControllerPipeline(metrics: secondMetrics)
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([first, second]))

        let idleSnapshot = await controller.playbackMetricsSnapshot(window: .seconds(60))
        XCTAssertNil(idleSnapshot)
        await controller.play(makeRequest(title: "first"))
        let firstSnapshot = await controller.playbackMetricsSnapshot(window: .seconds(60))
        XCTAssertEqual(firstSnapshot?.residentMemoryBytes, 11)
        await controller.play(makeRequest(title: "second"))
        let secondSnapshot = await controller.playbackMetricsSnapshot(window: .seconds(60))
        XCTAssertEqual(secondSnapshot?.residentMemoryBytes, 22)
        second.emit(.failed(.demuxRead(-1)))
        try await Task.sleep(for: .milliseconds(20))
        let failedSnapshot = await controller.playbackMetricsSnapshot(window: .seconds(60))
        XCTAssertNil(failedSnapshot)
    }

    func testControllerPublishesIdlePreparingPlayingPauseResumeAndStopped() async throws {
        let fake = FakeControllerPipeline()
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([fake]))
        var events = await controller.events().makeAsyncIterator()
        let request = makeRequest()

        let idle = await events.next()
        XCTAssertEqual(idle, .idle)
        await controller.play(request)
        let preparing = await events.next()
        XCTAssertEqual(preparing, .preparing(request))
        fake.emit(.ready(readinessCycle: 0))
        let playing = await events.next()
        XCTAssertEqual(playing, .playing(request))

        await controller.setPaused(true)
        let paused = await events.next()
        XCTAssertEqual(paused, .paused(request))
        fake.emit(.ready(readinessCycle: 0))
        try await Task.sleep(for: .milliseconds(20))
        let stablePaused = await controller.currentStateForTesting
        XCTAssertEqual(stablePaused, .paused(request))
        await controller.setPaused(false)
        let resumePreparing = await events.next()
        XCTAssertEqual(resumePreparing, .preparing(request))
        fake.emit(.ready(readinessCycle: 2))
        let resumed = await events.next()
        XCTAssertEqual(resumed, .playing(request))

        await controller.stop()
        let stopped = await events.next()
        XCTAssertEqual(stopped, .stopped)
        XCTAssertEqual(fake.snapshot().pauses.map(\.0), [true, false])
        XCTAssertEqual(fake.snapshot().pauses.map(\.1), [1, 2])
        XCTAssertEqual(fake.snapshot().stopCount, 1)
    }

    func testReplacementAndExplicitCancellationNeverPublishCancelledFailure() async throws {
        let first = FakeControllerPipeline()
        let second = FakeControllerPipeline()
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([first, second]))
        var events = await controller.events().makeAsyncIterator()
        _ = await events.next()

        let request1 = makeRequest(title: "one")
        let request2 = makeRequest(title: "two")
        await controller.play(request1)
        let preparing1 = await events.next()
        XCTAssertEqual(preparing1, .preparing(request1))
        await controller.play(request2)
        let preparing2 = await events.next()
        XCTAssertEqual(preparing2, .preparing(request2))
        XCTAssertEqual(first.snapshot().stopCount, 1)

        first.emit(.failed(.cancelled))
        second.emit(.ready(readinessCycle: 0))
        let playing2 = await events.next()
        XCTAssertEqual(playing2, .playing(request2))
        await controller.stop()
        let stopped = await events.next()
        XCTAssertEqual(stopped, .stopped)
        second.emit(.failed(.cancelled))
        try await Task.sleep(for: .milliseconds(20))
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .stopped)
    }

    func testReplacementAndExplicitStopAwaitCompletedTeardownBeforeReturningOrCreating() async throws {
        let first = FakeControllerPipeline()
        first.stopAutomaticallyCompletes = false
        let second = FakeControllerPipeline()
        let factory = FakeControllerPipelineFactory([first, second])
        let controller = PlaybackController(factory: factory)
        let firstRequest = makeRequest(title: "first")
        let secondRequest = makeRequest(title: "second")
        await controller.play(firstRequest)

        let replacementFinished = LockedFlag()
        let replacement = Task {
            await controller.play(secondRequest)
            replacementFinished.set()
        }
        try await eventually { first.snapshot().isStopWaiting }
        XCTAssertEqual(factory.makeCountSnapshot, 1)
        XCTAssertTrue(second.snapshot().starts.isEmpty)
        XCTAssertFalse(replacementFinished.value)

        first.completeStop()
        await replacement.value
        XCTAssertEqual(first.snapshot().completedStopCount, 1)
        XCTAssertEqual(factory.makeCountSnapshot, 2)
        XCTAssertEqual(second.snapshot().starts, [secondRequest.streamURL])

        second.stopAutomaticallyCompletes = false
        let explicitStopFinished = LockedFlag()
        let explicitStop = Task {
            await controller.stop()
            explicitStopFinished.set()
        }
        try await eventually { second.snapshot().isStopWaiting }
        XCTAssertFalse(explicitStopFinished.value)
        second.completeStop()
        await explicitStop.value
        XCTAssertTrue(explicitStopFinished.value)
        XCTAssertEqual(second.snapshot().completedStopCount, 1)
    }

    func testExplicitStopDuringReplacementAwaitsSharedTeardownAndCancelsCreation() async throws {
        let first = FakeControllerPipeline()
        first.stopAutomaticallyCompletes = false
        let second = FakeControllerPipeline()
        let factory = FakeControllerPipelineFactory([first, second])
        let controller = PlaybackController(factory: factory)
        await controller.play(makeRequest(title: "first"))
        let replacementRequest = makeRequest(title: "replacement")

        let replacement = Task {
            await controller.play(replacementRequest)
        }
        try await eventually { first.snapshot().isStopWaiting }

        let stopFinished = LockedFlag()
        let explicitStop = Task {
            await controller.stop()
            stopFinished.set()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(stopFinished.value)
        XCTAssertEqual(factory.makeCountSnapshot, 1)

        first.completeStop()
        await replacement.value
        await explicitStop.value

        XCTAssertTrue(stopFinished.value)
        XCTAssertEqual(first.snapshot().stopCount, 1)
        XCTAssertEqual(factory.makeCountSnapshot, 1)
        XCTAssertTrue(second.snapshot().starts.isEmpty)
        let state = await controller.currentStateForTesting
        XCTAssertEqual(state, .stopped)
    }

    func testPauseCycleRejectsDelayedReadyAndRedundantLifecycleOperationsAreNoOps() async throws {
        let fake = FakeControllerPipeline()
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([fake]))
        let request = makeRequest()
        await controller.play(request)
        fake.emit(.ready(readinessCycle: 0))
        try await eventually { await controller.currentStateForTesting == .playing(request) }

        await controller.setPaused(false)
        XCTAssertTrue(fake.snapshot().pauses.isEmpty)
        let stateAfterRedundantResume = await controller.currentStateForTesting
        XCTAssertEqual(stateAfterRedundantResume, .playing(request))

        await controller.setPaused(true)
        await controller.setPaused(true)
        XCTAssertEqual(fake.snapshot().pauses.map(\.0), [true])
        XCTAssertEqual(fake.snapshot().pauses.map(\.1), [1])

        await controller.setPaused(false)
        fake.emit(.ready(readinessCycle: 0))
        try await Task.sleep(for: .milliseconds(20))
        let stateAfterStaleReady = await controller.currentStateForTesting
        XCTAssertEqual(stateAfterStaleReady, .preparing(request))
        fake.emit(.ready(readinessCycle: 2))
        try await eventually { await controller.currentStateForTesting == .playing(request) }
        await controller.setPaused(false)
        XCTAssertEqual(fake.snapshot().pauses.map(\.0), [true, false])
        XCTAssertEqual(fake.snapshot().pauses.map(\.1), [1, 2])

        await controller.stop()
        await controller.stop()
        XCTAssertEqual(fake.snapshot().stopCount, 1)
        fake.emit(.ready(readinessCycle: 2))
        fake.emit(.failed(.metalCommand("late")))
        try await Task.sleep(for: .milliseconds(20))
        let stateAfterLateEvents = await controller.currentStateForTesting
        XCTAssertEqual(stateAfterLateEvents, .stopped)
    }

    func testTerminalFailureIsStableAndNeverEscapesTheActor() async throws {
        let fake = FakeControllerPipeline()
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([fake]))
        var events = await controller.events().makeAsyncIterator()
        _ = await events.next()
        await controller.play(makeRequest())
        _ = await events.next()

        fake.emit(.failed(.demuxRead(-1)))
        let failed = await events.next()
        XCTAssertEqual(
            failed,
            .failed(PlaybackFailure(code: "demux.read", userMessage: "读取频道流失败，请检查网络后重试。"))
        )
        fake.emit(.failed(.metalCommand("late")))
        fake.emit(.ready(readinessCycle: 0))
        try await Task.sleep(for: .milliseconds(20))
        let stableState = await controller.currentStateForTesting
        XCTAssertEqual(
            stableState,
            .failed(PlaybackFailure(code: "demux.read", userMessage: "读取频道流失败，请检查网络后重试。"))
        )
    }

    func testControllerForwardsPrePlayAndLiveBufferTuning() async throws {
        let first = FakeControllerPipeline()
        let second = FakeControllerPipeline()
        let factory = FakeControllerPipelineFactory([first, second])
        let controller = PlaybackController(factory: factory)
        let long = PlaybackTuning(videoBufferSeconds: 4, deinterlaceBufferFrames: 16)

        // Set before playing: the pipeline has to be built with it, otherwise a
        // stored setting only takes effect the second time a channel is opened.
        await controller.setTuning(long)
        await controller.play(makeRequest())
        XCTAssertEqual(factory.requestedTuningsSnapshot, [long])
        XCTAssertTrue(first.snapshot().tunings.isEmpty)

        // Changed while playing: applied to the running stream, and remembered
        // for the pipeline built for the next channel.
        let short = PlaybackTuning(videoBufferSeconds: 0.5, deinterlaceBufferFrames: 4)
        await controller.setTuning(short)
        XCTAssertEqual(first.snapshot().tunings, [short])
        await controller.play(makeRequest())
        XCTAssertEqual(factory.requestedTuningsSnapshot, [long, short])
    }

    func testPipelineWaitsForExactAudioAndVideoReadinessThenAnchorsOnce() async throws {
        let harness = makeHarness(requiredVideoFrames: 2)
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        let fingerprint = MediaFormatFingerprint(bytes: Data([1]))
        harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)))
        harness.pipeline.receive(video: .format(try PlaybackFakeMedia.videoFormat(), fingerprint))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == 1 }
        let generation = (await harness.pipeline.debugSnapshot()).generation
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 0,
            generation: generation,
            randomAccess: true
        )))
        try await eventually {
            harness.decoder.snapshot().contains(.configure(generation))
        }
        XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [MediaGeneration(rawValue: 1)])
        harness.audio.setReady(true)

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 79, timescale: 1_000)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation, pts: .zero, interlaced: false
            ),
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: CMTime(value: 1, timescale: 25),
                interlaced: false
            ),
        ], in: harness)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 79, timescale: 1_000),
            duration: CMTime(value: 1, timescale: 1_000)
        )))
        try await eventually { harness.events.snapshot().contains(.ready(readinessCycle: 0)) }
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)
        XCTAssertGreaterThanOrEqual(harness.renderer.snapshot().resets, 1)
    }

    func testProgressiveAndInterlacedFramesBothUseInjectedPassthroughPath() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation, pts: .zero, interlaced: false
            ),
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: CMTime(value: 1, timescale: 25),
                interlaced: true
            ),
        ], in: harness)

        try await eventually { harness.processor.snapshot().metadata.count == 2 }
        XCTAssertEqual(harness.processor.snapshot().metadata.map(\.isInterlaced), [false, true])
        XCTAssertEqual(harness.renderer.snapshot().frames.count, 2)
    }

    func testPipelineReadinessRequirementTracksCurrentCoordinatorRoute() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        let initialSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(initialSnapshot.requiredVideoFrameCount, 1)

        let base = try PlaybackFakeMedia.decodedFrame(
            id: 10,
            generation: generation,
            pts: .zero,
            interlaced: true
        )
        harness.pipeline.receive(decoder: .frame(DecodedVideoFrame(
            accessUnitID: base.accessUnitID,
            pixelBuffer: base.pixelBuffer,
            presentationTimeStamp: base.presentationTimeStamp,
            duration: base.duration,
            generation: base.generation,
            parserMetadata: VideoParserMetadata(
                fieldOrder: .tt,
                pictureStructure: .topField,
                isInterlaced: true,
                repeatFirstField: false,
                topFieldFirst: true,
                sourcePTS90k: 0
            ),
            formatMetadata: base.formatMetadata
        )))

        try await eventually {
            await harness.pipeline.debugSnapshot().requiredVideoFrameCount == 2
        }
        let routedSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(routedSnapshot.generation, generation)
        XCTAssertEqual(harness.display.snapshot().last, "pause")
        XCTAssertEqual(harness.renderer.snapshot().flushes.last, generation)
    }

    func testRepeatedTracksKeepGenerationWhileChangedFormatAndDiscontinuityAdvanceAndFlush() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await Task.sleep(for: .milliseconds(20))
        let repeatedSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(repeatedSnapshot.generation, generation)

        let changedFingerprint = MediaFormatFingerprint(bytes: Data([9]))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), changedFingerprint
        ))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: changedFingerprint)
        ))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: generation.rawValue + 1) }
        let changedGeneration = MediaGeneration(rawValue: generation.rawValue + 1)
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 40,
            generation: changedGeneration,
            randomAccess: true
        )))
        try await eventually {
            harness.decoder.snapshot().contains(.configure(changedGeneration))
        }
        let operations = harness.decoder.snapshot()
        XCTAssertTrue(operations.suffix(5).elementsEqual([
            .finish, .wait, .invalidate,
            .configure(changedGeneration),
            .decode(40, changedGeneration, ._EnableAsynchronousDecompression),
        ]))

        harness.demux.emit(.discontinuity(
            PlaybackFakeMedia.tracks(),
            reason: .timelineReset
        ))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: generation.rawValue + 2) }
        XCTAssertEqual(harness.renderer.snapshot().flushes.last, MediaGeneration(rawValue: generation.rawValue + 2))
        XCTAssertEqual(harness.audio.snapshot().flushes.last, MediaGeneration(rawValue: generation.rawValue + 2))

        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), changedFingerprint
        ))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: changedFingerprint)
        ))
        try await Task.sleep(for: .milliseconds(20))
        let postDiscontinuityFormat = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(postDiscontinuityFormat.generation, MediaGeneration(rawValue: generation.rawValue + 2))
    }

    func testSameFormatTimelineResetAdvancesPipelineEpochAndFlushes() async throws {
        let harness = makeHarness()
        let initial = try await configure(harness)
        let tracks = PlaybackFakeMedia.tracks()

        harness.demux.emit(.discontinuity(tracks, reason: .timelineReset))

        let expected = MediaGeneration(rawValue: initial.rawValue + 1)
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == expected
        }
        XCTAssertEqual(harness.assemblers.video.resetTracks, [tracks])
        XCTAssertEqual(harness.assemblers.audio.resetTracks, [tracks])
        XCTAssertEqual(harness.renderer.snapshot().flushes.last, expected)
        XCTAssertEqual(harness.audio.snapshot().flushes.last, expected)
    }

    func testAudioOnlySameFormatTimelineResetAdvancesOnceAndFlushesQueuedAudio() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        let tracks = PlaybackFakeMedia.audioOnlyTracks()
        harness.demux.emit(.tracks(tracks))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA6]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1)
        }
        let initial = (await harness.pipeline.debugSnapshot()).generation
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 61,
            generation: initial,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try await eventually { harness.audio.snapshot().samples.map(\.id) == [61] }

        harness.demux.emit(.discontinuity(tracks, reason: .timelineReset))

        let expected = MediaGeneration(rawValue: initial.rawValue + 1)
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == expected
        }
        let resetSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(resetSnapshot.generation, expected)
        XCTAssertEqual(harness.audio.snapshot().flushes, [expected])
        XCTAssertTrue(harness.audio.snapshot().samples.isEmpty)
    }

    func testFormatChangeDrainFailureCannotReconfigureAudioOrReopenAdmission() async throws {
        let harness = makeHarness()
        let oldGeneration = try await configure(harness)
        let audioConfigurationCount = harness.audio.snapshot().configured.count
        harness.decoder.finishError = .malfunction(-211)
        let fingerprint = MediaFormatFingerprint(bytes: Data([0xD1]))

        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            fingerprint
        ))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))

        try await eventually {
            harness.events.snapshot().contains(.failed(.videoDecode(-211)))
        }
        XCTAssertEqual(
            harness.events.snapshot().filter {
                if case .failed = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            harness.audio.snapshot().configured.count,
            audioConfigurationCount
        )
        let failedGeneration = await harness.pipeline.debugSnapshot().generation
        XCTAssertGreaterThan(failedGeneration, oldGeneration)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 99,
            generation: failedGeneration,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(harness.audio.snapshot().samples.contains { $0.id == 99 })
        let terminalSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertTrue(terminalSnapshot.isTerminal)
        XCTAssertFalse(terminalSnapshot.mediaAdmissionOpen)
        XCTAssertFalse(terminalSnapshot.videoAdmissionOpen)
    }

    func testCanonicalFingerprintUsesLatestCompleteEventAfterDistinctPartialInEitherOrder() async throws {
        for videoFirst in [true, false] {
            let harness = makeHarness()
            harness.pipeline.start(url: makeRequest().streamURL)
            try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
            harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
            try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
            let partialFingerprint = MediaFormatFingerprint(bytes: Data([0x0A]))
            let completeFingerprint = MediaFormatFingerprint(bytes: Data([0x0B]))

            if videoFirst {
                harness.pipeline.receive(video: .format(
                    try PlaybackFakeMedia.videoFormat(), partialFingerprint
                ))
            } else {
                harness.pipeline.receive(audio: .format(
                    try PlaybackFakeMedia.audioConfiguration(fingerprint: partialFingerprint)
                ))
            }
            try await Task.sleep(for: .milliseconds(20))
            let oneSidedGeneration = await harness.pipeline.debugSnapshot().generation
            XCTAssertEqual(oneSidedGeneration, MediaGeneration(rawValue: 0))
            XCTAssertTrue(harness.decoder.snapshot().isEmpty)
            XCTAssertTrue(harness.audio.snapshot().configured.isEmpty)

            if videoFirst {
                harness.pipeline.receive(audio: .format(
                    try PlaybackFakeMedia.audioConfiguration(fingerprint: completeFingerprint)
                ))
            } else {
                harness.pipeline.receive(video: .format(
                    try PlaybackFakeMedia.videoFormat(), completeFingerprint
                ))
            }
            try await eventually { (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1) }
            let generation = MediaGeneration(rawValue: 1)
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: 1,
                generation: generation,
                randomAccess: true
            )))
            try await eventually {
                harness.decoder.snapshot().contains(.configure(generation))
            }
            XCTAssertEqual(harness.decoder.snapshot().filter {
                if case .configure = $0 { return true }
                return false
            }, [.configure(MediaGeneration(rawValue: 1))])
            XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [MediaGeneration(rawValue: 1)])
        }
    }

    func testRealSharedStateAssemblersReplayFirstSideMediaAfterBothFormatsComplete() async throws {
        for videoFirst in [true, false] {
            let builder = AssemblerBackedPlaybackBuilder()
            let harness = makeHarness(playbackAssemblerBuilder: builder)
            harness.pipeline.start(url: makeRequest().streamURL)
            try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
            harness.demux.emit(.tracks(PlaybackFakeMedia.tracks(audioExtradata: Data())))
            try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

            harness.demux.emit(.packet(
                videoFirst
                    ? PlaybackFakeMedia.videoPacket(marker: 1, pts: 0)
                    : PlaybackFakeMedia.audioPacket(id: 1)
            ))
            try await eventually { builder.formatFingerprintsSnapshot.count == 1 }
            let firstSideSnapshot = await harness.pipeline.debugSnapshot()
            XCTAssertEqual(firstSideSnapshot.generation.rawValue, 0)
            XCTAssertFalse(harness.decoder.snapshot().contains {
                if case .decode = $0 { return true }
                return false
            })
            XCTAssertTrue(harness.audio.snapshot().samples.isEmpty)

            harness.demux.emit(.packet(
                videoFirst
                    ? PlaybackFakeMedia.audioPacket(id: 2)
                    : PlaybackFakeMedia.videoPacket(marker: 1, pts: 0)
            ))
            try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == 1 }
            let fingerprints = builder.formatFingerprintsSnapshot
            XCTAssertEqual(fingerprints.count, 2)
            XCTAssertNotEqual(fingerprints[0], fingerprints[1])

            let generation = (await harness.pipeline.debugSnapshot()).generation
            try await eventually {
                harness.decoder.snapshot().contains {
                    if case let .decode(_, decodedGeneration, _) = $0 {
                        return decodedGeneration == generation
                    }
                    return false
                } && harness.audio.snapshot().samples.contains { $0.generation == generation }
            }
        }
    }

    func testCorruptVideoIsDroppedWhileCorruptAudioReachesItsProfile() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        harness.demux.emit(.packet(PlaybackFakeMedia.videoPacket(marker: 1, isCorrupt: true)))
        harness.demux.emit(.packet(PlaybackFakeMedia.audioPacket(id: 1, isCorrupt: true)))
        harness.demux.emit(.packet(PlaybackFakeMedia.videoPacket(marker: 2)))
        harness.demux.emit(.packet(PlaybackFakeMedia.audioPacket(id: 2)))

        try await eventually {
            harness.assemblers.video.packets.count == 1 &&
                harness.assemblers.audio.packets.count == 2
        }
        XCTAssertEqual(harness.assemblers.video.packets.map(\.data), [Data([2])])
        XCTAssertEqual(harness.assemblers.audio.packets.map(\.isCorrupt), [true, false])
        XCTAssertFalse(harness.events.snapshot().contains {
            if case .failed = $0 { return true }
            return false
        })
    }

    func testNegotiationAudioBufferIsBoundedAndKeepsNewestContiguousSamples() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }

        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([0x41]))
        ))
        let count = PlaybackPipeline.pendingTrackMediaCapacity + 20
        for id in 0..<count {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id),
                generation: MediaGeneration(rawValue: 0),
                pts: CMTime(value: CMTimeValue(id), timescale: 40),
                duration: CMTime(value: 1, timescale: 40)
            )))
        }
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(
                fingerprint: MediaFormatFingerprint(bytes: Data([0x42]))
            )
        ))

        try await eventually {
            harness.audio.snapshot().samples.count == PlaybackPipeline.pendingTrackMediaCapacity
        }
        let samples = harness.audio.snapshot().samples
        XCTAssertEqual(
            samples.first?.id,
            UInt64(count - PlaybackPipeline.pendingTrackMediaCapacity)
        )
        XCTAssertEqual(samples.last?.id, UInt64(count - 1))
        XCTAssertTrue(samples.allSatisfy {
            $0.generation == MediaGeneration(rawValue: 1)
        })
    }

    func testNegotiationAudioByteBudgetKeepsNewestTailBeforeCountCap() async throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 9,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = makeHarness(pendingTrackAudioRetentionLimits: limits)
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([0x51]))
        ))
        for id in 0..<3 {
            harness.pipeline.receive(audio: .frame(makePendingAudioFrame(
                id: UInt64(id),
                payloadBytes: 4,
                pts: CMTime(value: Int64(id), timescale: 1)
            )))
        }
        harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(
            fingerprint: MediaFormatFingerprint(bytes: Data([0x52]))
        )))

        try await eventually { harness.audio.snapshot().samples.count == 2 }
        XCTAssertEqual(harness.audio.snapshot().samples.map(\.id), [1, 2])
        XCTAssertFalse(harness.events.snapshot().contains {
            if case .failed = $0 { return true }
            return false
        })
    }

    func testPendingAudioTimeHorizonKeepsNewestActualTail() async throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 100,
            latestTailHorizon: CMTime(value: 2, timescale: 1)
        )
        let harness = makeHarness(pendingTrackAudioRetentionLimits: limits)
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([0x61]))
        ))
        for id in 0..<3 {
            harness.pipeline.receive(audio: .frame(makePendingAudioFrame(
                id: UInt64(id),
                payloadBytes: 2,
                pts: CMTime(value: Int64(id), timescale: 1)
            )))
        }
        harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(
            fingerprint: MediaFormatFingerprint(bytes: Data([0x62]))
        )))

        try await eventually { harness.audio.snapshot().samples.count == 2 }
        XCTAssertEqual(harness.audio.snapshot().samples.map(\.id), [1, 2])
    }

    func testPendingAudioClearAndReplayResetOwnedBytesExactlyOnce() async throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 10,
            maximumOwnedBytes: 8,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = makeHarness(pendingTrackAudioRetentionLimits: limits)
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([0x71]))
        ))
        for id in 0..<3 {
            harness.pipeline.receive(audio: .frame(makePendingAudioFrame(
                id: UInt64(id),
                payloadBytes: 4,
                pts: CMTime(value: Int64(id), timescale: 1)
            )))
        }
        harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(
            fingerprint: MediaFormatFingerprint(bytes: Data([0x72]))
        )))
        try await eventually { harness.audio.snapshot().samples.count == 2 }
        let currentGeneration = await harness.pipeline.debugSnapshot().generation

        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks(
            audioExtradata: Data([0x13, 0x90])
        )))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([0x73]))
        ))
        harness.pipeline.receive(audio: .frame(makePendingAudioFrame(
            id: 9,
            payloadBytes: 8,
            pts: CMTime(value: 9, timescale: 1),
            generation: currentGeneration
        )))
        harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(
            fingerprint: MediaFormatFingerprint(bytes: Data([0x74]))
        )))

        try await eventually { harness.audio.snapshot().samples.contains { $0.id == 9 } }
        XCTAssertFalse(harness.events.snapshot().contains {
            if case .failed = $0 { return true }
            return false
        })
    }

    func testInEpochSingleSideFormatChangesImmediatelyRebuildWithCurrentOppositeDescription() async throws {
        let harness = makeHarness()
        let initial = try await configure(harness)

        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([0x21]))
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation.rawValue == initial.rawValue + 1
        }
        let afterVideo = (await harness.pipeline.debugSnapshot()).generation
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 21,
            generation: afterVideo,
            randomAccess: true
        )))
        try await eventually {
            harness.decoder.snapshot().contains(.configure(afterVideo))
        }
        XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [initial, afterVideo])

        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(
                fingerprint: MediaFormatFingerprint(bytes: Data([0x22]))
            )
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation.rawValue == afterVideo.rawValue + 1
        }
        let afterAudio = (await harness.pipeline.debugSnapshot()).generation
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 22,
            generation: afterAudio,
            randomAccess: true
        )))
        try await eventually {
            harness.decoder.snapshot().contains(.configure(afterAudio))
        }
        XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [initial, afterVideo, afterAudio])
        XCTAssertEqual(harness.audio.snapshot().configured.map(\.2), [
            MediaFormatFingerprint(bytes: Data([1])),
            MediaFormatFingerprint(bytes: Data([1])),
            MediaFormatFingerprint(bytes: Data([0x22])),
        ])
        XCTAssertEqual(harness.decoder.snapshot().filter {
            if case .configure = $0 { return true }
            return false
        }, [
            .configure(initial),
            .configure(afterVideo),
            .configure(afterAudio),
        ])
    }

    func testChangedTrackAndDiscontinuityEpochsReplayNegotiationMediaIntoFreshGeneration() async throws {
        for discontinuity in [false, true] {
            let harness = makeHarness()
            let initial = try await configure(harness)
            let updatedTracks = PlaybackFakeMedia.tracks(videoExtradata: Data([0x01]))
            harness.demux.emit(discontinuity
                ? .discontinuity(updatedTracks, reason: .timelineReset)
                : .tracks(updatedTracks))
            if discontinuity {
                try await eventually {
                    (await harness.pipeline.debugSnapshot()).generation.rawValue == initial.rawValue + 1
                }
            }
            let awaitingGeneration = (await harness.pipeline.debugSnapshot()).generation
            harness.pipeline.receive(video: .format(
                try PlaybackFakeMedia.videoFormat(),
                MediaFormatFingerprint(bytes: Data([0x31]))
            ))
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: 31,
                generation: awaitingGeneration,
                randomAccess: true,
                pts: .zero
            )))
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: 31,
                generation: awaitingGeneration,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 4)
            )))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == 31 }
                return false
            })
            XCTAssertFalse(harness.audio.snapshot().samples.contains { $0.id == 31 })

            harness.pipeline.receive(audio: .format(
                try PlaybackFakeMedia.audioConfiguration(
                    fingerprint: MediaFormatFingerprint(bytes: Data([0x32]))
                )
            ))
            let expectedGeneration = MediaGeneration(rawValue: initial.rawValue + 1)
            try await eventually {
                (await harness.pipeline.debugSnapshot()).generation == expectedGeneration
                    && harness.audio.snapshot().configured.last?.1 == expectedGeneration
                    && harness.audio.snapshot().samples.contains {
                        $0.id == 31 && $0.generation == expectedGeneration
                    }
                    && harness.decoder.snapshot().contains(.decode(
                        31,
                        expectedGeneration,
                        ._EnableAsynchronousDecompression
                    ))
            }

            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: 32,
                generation: expectedGeneration,
                randomAccess: false,
                pts: CMTime(value: 1, timescale: 10)
            )))
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: 32,
                generation: expectedGeneration,
                pts: CMTime(value: 1, timescale: 4),
                duration: CMTime(value: 1, timescale: 4)
            )))
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: 33,
                generation: expectedGeneration,
                randomAccess: true,
                pts: CMTime(value: 1, timescale: 5)
            )))
            try await eventually {
                harness.audio.snapshot().samples.contains { $0.id == 32 }
                    && harness.decoder.snapshot().contains(.decode(
                        33,
                        expectedGeneration,
                        ._EnableAsynchronousDecompression
                    ))
            }
            XCTAssertTrue(harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == 32 }
                return false
            })
        }
    }

    func testAwaitingFreshTrackEpochRejectsPriorProcessorCompletionAndReadinessRefresh() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        harness.processor.setAutomaticallyCompletes(false)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 99,
                generation: generation,
                pts: CMTime(value: 3, timescale: 25),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.processor.snapshot().metadata.count == 4 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks(videoExtradata: Data([0x44]))))
        harness.processor.completePending()
        harness.pipeline.refreshReadiness()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(harness.renderer.snapshot().frames.contains { $0.sourceAccessUnitID == 99 })
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)
    }

    func testChangedTracksNeverMixStaleOppositeFormatAndConsumeCanonicalFingerprintOnce() async throws {
        for videoFirst in [true, false] {
            let harness = makeHarness()
            let generation = try await configure(harness)
            let decoderOperationCount = harness.decoder.snapshot().count
            let audioConfigurationCount = harness.audio.snapshot().configured.count

            harness.demux.emit(.tracks(PlaybackFakeMedia.tracks(videoExtradata: Data([0x01]))))
            try await Task.sleep(for: .milliseconds(20))
            let postTracksGeneration = await harness.pipeline.debugSnapshot().generation
            XCTAssertEqual(postTracksGeneration, generation)

            let fingerprint = MediaFormatFingerprint(bytes: Data([0x0B]))
            if videoFirst {
                harness.pipeline.receive(video: .format(try PlaybackFakeMedia.videoFormat(), fingerprint))
            } else {
                harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)))
            }
            try await Task.sleep(for: .milliseconds(20))
            let oneSidedGeneration = await harness.pipeline.debugSnapshot().generation
            XCTAssertEqual(oneSidedGeneration, generation)
            XCTAssertEqual(harness.decoder.snapshot().count, decoderOperationCount)
            XCTAssertEqual(harness.audio.snapshot().configured.count, audioConfigurationCount)

            if videoFirst {
                harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)))
            } else {
                harness.pipeline.receive(video: .format(try PlaybackFakeMedia.videoFormat(), fingerprint))
            }
            try await eventually {
                (await harness.pipeline.debugSnapshot()).generation
                    == MediaGeneration(rawValue: generation.rawValue + 1)
            }
            let rebuiltOperationCount = harness.decoder.snapshot().count
            let rebuiltAudioCount = harness.audio.snapshot().configured.count

            harness.pipeline.receive(video: .format(try PlaybackFakeMedia.videoFormat(), fingerprint))
            harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)))
            try await Task.sleep(for: .milliseconds(20))
            let repeatedGeneration = await harness.pipeline.debugSnapshot().generation
            XCTAssertEqual(repeatedGeneration, MediaGeneration(rawValue: generation.rawValue + 1))
            XCTAssertEqual(harness.decoder.snapshot().count, rebuiltOperationCount)
            XCTAssertEqual(harness.audio.snapshot().configured.count, rebuiltAudioCount)
        }
    }

    func testReplacementDecoderAcceptsOnlyNextRandomAccessAndDropsOldCallback() async throws {
        let harness = makeHarness()
        let oldGeneration = try await configure(harness)
        let replacementFingerprint = MediaFormatFingerprint(bytes: Data([7]))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), replacementFingerprint
        ))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: replacementFingerprint)
        ))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == oldGeneration.rawValue + 1 }
        let generation = (await harness.pipeline.debugSnapshot()).generation
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(id: 1, generation: generation, randomAccess: false)))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(id: 2, generation: generation, randomAccess: true)))
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(id: 99, generation: oldGeneration, pts: .zero, interlaced: false)))

        try await eventually {
            harness.decoder.snapshot().contains(.decode(
                2, generation, ._EnableAsynchronousDecompression
            ))
        }
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, decodedGeneration, _) = $0 {
                return id == 1 && decodedGeneration == generation
            }
            return false
        })
        let decodeOperations = harness.decoder.snapshot().compactMap {
            operation -> (UInt64, VTDecodeFrameFlags)? in
            guard case let .decode(id, _, flags) = operation else { return nil }
            return (id, flags)
        }
        XCTAssertEqual(decodeOperations.map(\.0), [0, 2])
        XCTAssertTrue(decodeOperations.allSatisfy {
            $0.1 == ._EnableAsynchronousDecompression
        })
        XCTAssertFalse(harness.renderer.snapshot().frames.contains { $0.sourceAccessUnitID == 99 })
    }

    func testPCMRouteCannotOpenReadinessUntilPCMReportsReady() async throws {
        let harness = makeHarness()
        harness.audio.selectedRoute = .ffmpegPCM
        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1, generation: generation, pts: .zero, duration: CMTime(value: 1, timescale: 4)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation, pts: .zero, interlaced: false
            ),
        ], in: harness)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))

        harness.audio.setReady(true)
        harness.pipeline.refreshReadiness()
        try await eventually { harness.events.snapshot().contains(.ready(readinessCycle: 0)) }
    }

    func testNonOverlappingMediaNeverOpenReadiness() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: CMTime(value: 1, timescale: 1),
                interlaced: false
            ),
        ], in: harness)

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
        XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)
        XCTAssertFalse(harness.display.snapshot().contains("resume"))
    }

    func testClosedReadinessPreservesEarliestBoundedVideoWindowUntilLaggingAudioCatchesUp() async throws {
        let metrics = PlaybackMetrics(
            channelID: "video-lead",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        // Keep this bounded-window regression on the production classifier
        // cadence: route selection after the eighth progressive observation
        // is what makes the first post-classification frame the 1.1s anchor.
        let harness = makeHarness(
            classifierConfiguration: .init(),
            metrics: metrics
        )
        let generation = try await configure(harness)
        harness.audio.setReady(true)

        let frames = try (0..<24).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: 50 + Int64(index), timescale: 50),
                interlaced: false
            )
        }
        try receiveAndReleaseNormalizedFrames(frames, in: harness)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
        let closedSnapshot = try XCTUnwrap(metrics.snapshot(window: .seconds(60)))
        XCTAssertEqual(
            closedSnapshot.retainedVideoCount,
            PlaybackPipeline.startupRetainedVideoCapacity
        )
        XCTAssertEqual(closedSnapshot.videoFirstPTSSeconds ?? -1, 1.1, accuracy: 0.001)

        for index in 0..<6 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 4),
                duration: CMTime(value: 1, timescale: 4)
            )))
        }

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(harness.clock.snapshot().anchors.last?.0, CMTime(value: 55, timescale: 50))
        XCTAssertEqual(harness.display.snapshot().last, "resume")
    }

    func testClosedReadinessPreservesEarlyAudioWhenIngestOutrunsVideoDecode() async throws {
        let metrics = PlaybackMetrics(
            channelID: "audio-leads-video-decode",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)
        harness.audio.setReady(true)

        let audioDuration = CMTime(value: 1, timescale: 50)
        let continuityCapacity = 512
        for index in 0..<continuityCapacity {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 50),
                duration: audioDuration
            )))
        }
        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedAudioCount
                == continuityCapacity
        }

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(harness.clock.snapshot().anchors.last?.0, .zero)
        XCTAssertEqual(harness.display.snapshot().last, "resume")
    }

    func testRetentionBudgetCannotAdvertiseUnretainedAudioCoverage() async throws {
        let metrics = PlaybackMetrics(
            channelID: "retained-audio-coverage",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 2,
            maximumOwnedBytes: 100,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = makeHarness(
            metrics: metrics,
            audioContinuityRetentionLimits: limits
        )
        let generation = try await configure(harness)

        for id in 0..<3 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id + 1),
                generation: generation,
                pts: CMTime(value: Int64(id), timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            )))
        }

        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedAudioCount == 2
        }
        let snapshot = metrics.snapshot(window: .seconds(60))
        XCTAssertEqual(snapshot.audioFirstPTSSeconds, 1)
        XCTAssertEqual(snapshot.audioDurationSeconds, 2)
        XCTAssertFalse(snapshot.readinessOpen)
    }

    func testSmallContinuityBudgetWithRecoveryFloorEventuallyReopensOnFutureVideo() async throws {
        let metrics = PlaybackMetrics(
            channelID: "small-retention-recovery",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 2,
            maximumOwnedBytes: 100,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = makeHarness(
            metrics: metrics,
            audioContinuityRetentionLimits: limits
        )
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let floor = CMTime(value: 1, timescale: 2)
        harness.clock.setTime(floor)
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        for id in 1...3 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id + 1),
                generation: generation,
                pts: CMTime(value: Int64(id), timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            )))
        }
        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: CMTime(value: 3, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }

        XCTAssertEqual(harness.clock.snapshot().anchors.last?.0, CMTime(value: 3, timescale: 1))
        XCTAssertEqual(metrics.snapshot(window: .seconds(60)).audioFirstPTSSeconds, 3)
        let floorUpdates = harness.audio.snapshot().recoveryFloors
        guard !floorUpdates.isEmpty else {
            return XCTFail("renderer recovery floor was never synchronized")
        }
        XCTAssertNil(floorUpdates[floorUpdates.index(before: floorUpdates.endIndex)])
        XCTAssertFalse(harness.events.snapshot().contains {
            if case .failed = $0 { return true }
            return false
        })
    }

    func testGateNeverReceivesOrOpensAcrossDisconnectedAudioRetention() async throws {
        let limits = try CompressedAudioRetentionLimits(
            maximumCount: 2,
            maximumOwnedBytes: 100,
            latestTailHorizon: CMTime(value: 12, timescale: 1)
        )
        let harness = makeHarness(audioContinuityRetentionLimits: limits)
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        harness.clock.setTime(CMTime(value: 1, timescale: 2))
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        for id in 1...3 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id + 1),
                generation: generation,
                pts: CMTime(value: Int64(id), timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            )))
        }
        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: CMTime(value: 3, timescale: 2),
                interlaced: false
            ),
        ], in: harness)
        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 3,
                generation: generation,
                pts: CMTime(value: 3, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        XCTAssertEqual(harness.clock.snapshot().anchors.last?.0, CMTime(value: 3, timescale: 1))
    }

    func testFiveSecondAudioSegmentBurstPreservesRecoveryWindowAtPlaybackClock() async throws {
        let metrics = PlaybackMetrics(
            channelID: "five-second-audio-burst",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let packetDuration = CMTime(value: 1_024, timescale: 44_100)

        for index in 0..<12 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTimeMultiply(packetDuration, multiplier: Int32(index)),
                duration: packetDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        harness.clock.setTime(CMTime(value: 1, timescale: 1))

        // HLS delivers this whole five-second segment in a short burst. The
        // recovery history must not slide to the final ~3 seconds while video
        // callbacks are still close to the playback clock.
        for index in 12..<216 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTimeMultiply(packetDuration, multiplier: Int32(index)),
                duration: packetDuration
            )))
        }

        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedAudioCount > 128
        }
        let snapshot = try XCTUnwrap(metrics.snapshot(window: .seconds(60)))
        XCTAssertLessThanOrEqual(snapshot.audioFirstPTSSeconds ?? .infinity, 1)
        XCTAssertTrue(snapshot.readinessOpen)
    }

    func testFiveSecondVideoSegmentStaysCompressedAndDrainsAsClockAdvances() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        let audioDuration = CMTime(value: 1_024, timescale: 44_100)
        for index in 0..<216 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTimeMultiply(audioDuration, multiplier: Int32(index)),
                duration: audioDuration
            )))
        }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true,
            pts: .zero
        )))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 1 && decodedGeneration == generation
                }
                return false
            }
        }
        harness.audio.setReady(true)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        for index in 2...150 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: Int64(index - 1), timescale: 30)
            )))
        }
        let capacityFrameCount = Int64(
            CMTimeGetSeconds(PlaybackTuning.default.videoBufferHorizon) * 30
        )
        let lastUnitInsideCapacity = UInt64(capacityFrameCount + 1)
        let firstUnitBeyondCapacity = lastUnitInsideCapacity + 1
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == lastUnitInsideCapacity
                        && decodedGeneration == generation
                }
                return false
            }
        }
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 {
                return id == firstUnitBeyondCapacity
            }
            return false
        })
        let bufferedSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertGreaterThan(bufferedSnapshot.pendingVideoDecodeCount, 0)

        harness.clock.setTime(CMTime(value: 1, timescale: 1))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 30 && decodedGeneration == generation
                }
                return false
            }
        }
        let drainedSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertLessThan(drainedSnapshot.pendingVideoDecodeCount, 140)
        await harness.pipeline.stop()
    }

    func testRunningDecodeAdmissionFillsTheActualPresentationCapacity() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 3, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        // The default presentation capacity spans two seconds for this small
        // test format. Feed a 25 fps decoder all the way to that real capacity;
        // a fixed quarter-second lead would starve a frame-threaded decoder well
        // before it had enough reference pictures to produce continuously.
        let frameRate: Int64 = 25
        let lastIndexInsideCapacity = Int64(
            CMTimeGetSeconds(PlaybackTuning.default.videoBufferHorizon)
                * Double(frameRate)
        )
        let firstIndexBeyondCapacity = lastIndexInsideCapacity + 1
        for index in 1...firstIndexBeyondCapacity {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(1_000 + index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: index, timescale: CMTimeScale(frameRate))
            )))
        }

        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == UInt64(1_000 + lastIndexInsideCapacity)
                        && decodedGeneration == generation
                }
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 {
                return id == UInt64(1_000 + firstIndexBeyondCapacity)
            }
            return false
        })
        await harness.pipeline.stop()
    }

    func testStartupRandomAccessAdmissionDoesNotDependOnAVTimestampSkew() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness, initialRandomAccessPTS: nil)
        harness.audio.setReady(true)

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 500,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 5, timescale: 1)
        )))

        // Broadcast MPEG-TS commonly starts audio before the first usable IDR.
        // Bootstrap is driven by decoder/media state, so even an intentionally
        // exaggerated skew must not become a hidden admission threshold.
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 500 && decodedGeneration == generation
                }
                return false
            }
        }

        for index in 1...20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 4),
                duration: CMTime(value: 1, timescale: 4)
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 500,
                generation: generation,
                pts: CMTime(value: 5, timescale: 1),
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(
            harness.clock.snapshot().anchors.last?.0,
            CMTime(value: 5, timescale: 1)
        )
    }

    func testStartupDecodeDoesNotPauseOnAPartiallyAudioCoveredFrame() async throws {
        let harness = makeHarness(requiredVideoFrames: 2)
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 3, timescale: 50)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 10,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
            PlaybackFakeMedia.decodedFrame(
                id: 11,
                generation: generation,
                pts: CMTime(value: 1, timescale: 25),
                interlaced: false
            ),
        ], in: harness)

        // Audio ends halfway through the second 40 ms frame. Touching that
        // frame is not enough to open readiness, so admission must continue
        // instead of stopping at a condition the gate itself rejects.
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 900,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 2, timescale: 25)
        )))

        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 900 && decodedGeneration == generation
                }
                return false
            }
        }
    }

    func testCompletedSubmissionsWithoutOutputKeepFeedingDecoderUntilFirstFrame() async throws {
        let harness = makeHarness(videoDecodeStallTimeout: .milliseconds(20))
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 2, timescale: 1)
        )))

        // A frame-threaded decoder may consume more than its in-flight window
        // before emitting the first reordered picture. `submissionCompleted` is
        // the exact resource-credit release signal, not evidence of a stall.
        for index in 1...16 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(700 + index),
                generation: generation,
                randomAccess: index == 1,
                pts: CMTime(value: Int64(index - 1), timescale: 25)
            )))
        }
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 716 && decodedGeneration == generation
                }
                return false
            }
        }
        XCTAssertFalse(harness.events.snapshot().contains { event in
            if case .failed = event { return true }
            return false
        })

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 701,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
    }

    func testStartupChoosesAudioIslandThatActuallyOverlapsVideo() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 800,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 11, timescale: 10)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 800,
                generation: generation,
                pts: CMTime(value: 11, timescale: 10),
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(
            harness.clock.snapshot().anchors.last?.0,
            CMTime(value: 11, timescale: 10)
        )
    }

    func testStartupChoosesLaterIslandWhenAudioStartsInsideFirstVideoFrame() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: CMTime(value: -1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 100),
            duration: CMTime(value: 24, timescale: 100)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 850,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 1, timescale: 100)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 850,
                generation: generation,
                pts: CMTime(value: 1, timescale: 100),
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(
            harness.clock.snapshot().anchors.last?.0,
            CMTime(value: 1, timescale: 100)
        )
    }

    func testStartupWalksPastVideoForASealedUnusableAudioPrefix() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 100)
        )))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 1)
        )))

        // The ten-millisecond prefix is sealed. Live-first recovery waits for
        // the first random-access unit at the new audio island and rejects old
        // decoded callbacks as evidence.
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 900,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 900,
                generation: generation,
                pts: CMTime(value: 1, timescale: 1),
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        let anchor = try XCTUnwrap(harness.clock.snapshot().anchors.last?.0)
        XCTAssertGreaterThanOrEqual(
            CMTimeCompare(anchor, CMTime(value: 1, timescale: 1)),
            0
        )
    }

    func testStartupDemandAllowsFutureReferenceNeededByEarlierBFrame() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 0,
                generation: generation,
                pts: CMTime(value: 2, timescale: 5),
                interlaced: false
            ),
        ], in: harness)
        _ = await harness.pipeline.debugSnapshot()

        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 600,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 3, timescale: 5)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 601,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 1, timescale: 5)
        )))

        try await eventually {
            let decodeIDs = harness.decoder.snapshot().compactMap { operation -> UInt64? in
                if case let .decode(id, decodedGeneration, _) = operation,
                   decodedGeneration == generation,
                   id >= 600 {
                    return id
                }
                return nil
            }
            return decodeIDs == [600, 601]
        }
    }

    func testRecoverySubmitsCRAHeadNeededByAnEarlierLeadingPicture() async throws {
        let harness = makeHarness(automaticallyCompleteDecoderSubmissions: false)
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 3, timescale: 1)
        )))

        let dimensions = CMVideoDimensions(width: 3_840, height: 2_160)
        for index in 0..<5 {
            harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
                id: UInt64(index),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 25),
                interlaced: false,
                dimensions: dimensions,
                bitDepth: 10
            )))
        }
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))
        harness.clock.setTime(CMTime(value: 1, timescale: 1))
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)

        // Keep one ordinary submission in flight so recovery cannot jump its
        // anchor to the CRA. The following leading picture has an earlier PTS
        // and needs the CRA to be submitted first in decode order.
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 100,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 1, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 200,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 2, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 201,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 3, timescale: 2)
        )))

        try await eventually {
            let ids = harness.decoder.snapshot().compactMap { operation -> UInt64? in
                if case let .decode(id, decodedGeneration, _) = operation,
                   decodedGeneration == generation,
                   id >= 100 {
                    return id
                }
                return nil
            }
            return ids == [100, 200, 201]
        }
        await harness.pipeline.stop()
    }

    func testTwoFiveSecondHLSSegmentsFitCompressedReservoirAndDrainWithoutDroppingTail() async throws {
        let metrics = PlaybackMetrics(
            channelID: "two-five-second-segments",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)
        let audioDuration = CMTime(value: 1_024, timescale: 44_100)

        // Starting one segment behind the live edge makes FFmpeg deliver about
        // ten seconds immediately: 300 video access units at 30 fps and 431 AAC
        // packets at 44.1 kHz. Both segment tails must remain compressed while
        // the clock is still at the beginning of the first segment.
        for index in 0..<431 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTimeMultiply(audioDuration, multiplier: Int32(index)),
                duration: audioDuration
            )))
        }
        for index in 1...300 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(index),
                generation: generation,
                randomAccess: index == 1 || index == 151,
                pts: CMTime(value: Int64(index - 1), timescale: 30)
            )))
        }

        try await eventually {
            (await harness.pipeline.debugSnapshot()).pendingVideoDecodeCount > 280
        }
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, decodedGeneration, _) = $0 {
                return id == 300 && decodedGeneration == generation
            }
            return false
        })
        XCTAssertEqual(
            metrics.snapshot(window: .seconds(60)).videoDropCountsBySource[
                VideoDropSource.decodeSubmissionBacklog.rawValue
            ],
            0
        )

        harness.audio.setReady(true)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        // The final AU is at 299/30 seconds. Advancing the clock puts it inside
        // the active presentation capacity and proves it was retained rather
        // than silently shed when the two-segment burst arrived.
        harness.clock.setTime(CMTime(value: 39, timescale: 4))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 300 && decodedGeneration == generation
                }
                return false
            }
        }
        try await eventually {
            (await harness.pipeline.debugSnapshot()).pendingVideoDecodeCount == 0
        }
        XCTAssertEqual(
            metrics.snapshot(window: .seconds(60)).videoDropCountsBySource[
                VideoDropSource.decodeSubmissionBacklog.rawValue
            ],
            0
        )
        await harness.pipeline.stop()
    }

    func testVideoStallRecoversAtTheClockWithoutReplayingRetainedMedia() async throws {
        let metrics = PlaybackMetrics(
            channelID: "video-resync-threshold",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 2, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        let opened = try XCTUnwrap(metrics.snapshot(window: .seconds(60)))

        // A few missed 25 fps frames are handled by normal late-frame dropping.
        harness.clock.setTime(CMTime(value: 8, timescale: 25))
        harness.pipeline.refreshReadiness()
        _ = await harness.pipeline.debugSnapshot()
        var snapshot = try XCTUnwrap(metrics.snapshot(window: .seconds(60)))
        XCTAssertEqual(snapshot.videoResyncCount, 0)
        XCTAssertEqual(snapshot.readinessCycleID, opened.readinessCycleID)
        XCTAssertEqual(
            snapshot.readinessCloseReasonCounts[Int(PlaybackReadinessCloseReason.buffering.rawValue)],
            opened.readinessCloseReasonCounts[Int(PlaybackReadinessCloseReason.buffering.rawValue)]
        )
        XCTAssertTrue(snapshot.readinessOpen)

        // A genuine stall pauses the clock so source-rate decode can catch up,
        // but it must not immediately reopen from the retained frame at zero.
        let recoveryFloor = CMTime(value: 6, timescale: 5)
        harness.clock.setTime(recoveryFloor)
        harness.pipeline.refreshReadiness()
        _ = await harness.pipeline.debugSnapshot()
        snapshot = try XCTUnwrap(metrics.snapshot(window: .seconds(60)))
        XCTAssertEqual(snapshot.videoResyncCount, 1)
        XCTAssertEqual(snapshot.readinessCycleID, opened.readinessCycleID + 1)
        XCTAssertEqual(
            snapshot.readinessCloseReasonCounts[Int(PlaybackReadinessCloseReason.buffering.rawValue)],
            opened.readinessCloseReasonCounts[Int(PlaybackReadinessCloseReason.buffering.rawValue)] + 1
        )
        XCTAssertFalse(snapshot.readinessOpen)
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)
        XCTAssertEqual(harness.clock.currentTime, recoveryFloor)

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: recoveryFloor,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: recoveryFloor,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }

        let recoveredAnchor = try XCTUnwrap(harness.clock.snapshot().anchors.last?.0)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(recoveredAnchor, recoveryFloor), 0)
        XCTAssertTrue(harness.renderer.snapshot().frames.allSatisfy {
            CMTimeCompare($0.presentationTimeStamp, recoveryFloor) >= 0
        })
    }

    func testSameTimelineRecoveryRejectsRetainedAndLateFramesBeforeTheClock() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let packetDuration = CMTime(value: 1, timescale: 40)
        for index in 0..<80 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: packetDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let recoveryFloor = CMTime(value: 6, timescale: 5)
        harness.clock.setTime(recoveryFloor)
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        _ = await harness.pipeline.debugSnapshot()

        // Retained startup media must not immediately reopen at PTS zero.
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)

        try receiveAndReleaseNormalizedFrames(try (10..<15).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(index),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 25),
                interlaced: false
            )
        }, in: harness)
        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 100,
                generation: generation,
                pts: recoveryFloor,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }

        let recoveredAnchor = try XCTUnwrap(harness.clock.snapshot().anchors.last?.0)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(recoveredAnchor, recoveryFloor), 0)
        XCTAssertTrue(harness.renderer.snapshot().frames.allSatisfy { frame in
            CMTimeCompare(frame.presentationTimeStamp, recoveryFloor) >= 0
        })
    }

    func testAudioGapRecoverySkipsLaggingCurrentGOPForNewRandomAccess() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let packetDuration = CMTime(value: 1, timescale: 40)
        for index in 0..<20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: packetDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        // Build a current-GOP compressed reservoir just beyond the active
        // presentation capacity while the running clock is still at zero. The
        // later recovery floor then overtakes its head without changing GOPs.
        let frameRate: Int64 = 25
        let capacityFrameCount = Int64(
            CMTimeGetSeconds(PlaybackTuning.default.videoBufferHorizon)
                * Double(frameRate)
        )
        let firstBufferedIndex = capacityFrameCount + 2
        let lastBufferedIndex = firstBufferedIndex + 25
        let recoveryIndex = lastBufferedIndex - 2
        for index in firstBufferedIndex...lastBufferedIndex {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(1_000 + index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: index, timescale: CMTimeScale(frameRate))
            )))
        }
        let expectedBufferedCount = Int(lastBufferedIndex - firstBufferedIndex + 1)
        try await eventually {
            (await harness.pipeline.debugSnapshot()).pendingVideoDecodeCount
                == expectedBufferedCount
        }

        let recoveryFloor = CMTime(value: recoveryIndex, timescale: CMTimeScale(frameRate))
        harness.clock.setTime(recoveryFloor)
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        _ = await harness.pipeline.debugSnapshot()

        let firstRecoveryAudioIndex = CMTimeConvertScale(
            recoveryFloor,
            timescale: 40,
            method: .default
        ).value
        for index in firstRecoveryAudioIndex..<(firstRecoveryAudioIndex + 24) {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(100 + index),
                generation: generation,
                pts: CMTime(value: index, timescale: 40),
                duration: packetDuration
            )))
        }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 2_000,
            generation: generation,
            randomAccess: true,
            pts: recoveryFloor
        )))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 2_000 && decodedGeneration == generation
                }
                return false
            }
        }

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 2_000,
                generation: generation,
                pts: recoveryFloor,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }

        let recoveredAnchor = try XCTUnwrap(harness.clock.snapshot().anchors.last?.0)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(recoveredAnchor, recoveryFloor), 0)
    }

    func testRecoverySkipsASealedAudioIslandAtTheClockFloorAndDecodesTheLaterRun() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let packetDuration = CMTime(value: 1, timescale: 40)
        for index in 0..<20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: packetDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let recoveryFloor = CMTime(value: 6, timescale: 5)
        harness.clock.setTime(recoveryFloor)
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 100,
            generation: generation,
            pts: recoveryFloor,
            duration: packetDuration
        )))
        for index in 0..<16 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(200 + index),
                generation: generation,
                pts: CMTimeAdd(CMTime(value: 3, timescale: 2),
                               CMTimeMultiply(packetDuration, multiplier: Int32(index))),
                duration: packetDuration
            )))
        }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 500,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 3, timescale: 2)
        )))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 500 && decodedGeneration == generation
                }
                return false
            }
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 500,
                generation: generation,
                pts: CMTime(value: 3, timescale: 2),
                interlaced: false
            ),
        ], in: harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }

        XCTAssertEqual(
            harness.clock.snapshot().anchors.last?.0,
            CMTime(value: 3, timescale: 2)
        )
    }

    func testTwoFrameRouteLeavesSealedOneFrameIslandForLaterRandomAccess() async throws {
        let harness = makeHarness(
            requiredVideoFrames: 2,
            automaticallyCompleteDecoderSubmissions: false
        )
        let generation = try await configure(harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: CMTime(value: 1, timescale: 25),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let recoveryFloor = CMTime(value: 1, timescale: 1)
        harness.clock.setTime(recoveryFloor)
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 100,
            generation: generation,
            pts: recoveryFloor,
            duration: CMTime(value: 1, timescale: 25)
        )))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 200,
            generation: generation,
            pts: CMTime(value: 2, timescale: 1),
            duration: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 100,
                generation: generation,
                pts: recoveryFloor,
                interlaced: false
            ),
        ], in: harness)

        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 900,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 2, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 901,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 51, timescale: 25)
        )))
        try await eventually {
            let decodedIDs = harness.decoder.snapshot().compactMap { operation -> UInt64? in
                if case let .decode(id, decodedGeneration, _) = operation {
                    return decodedGeneration == generation && id >= 900 ? id : nil
                }
                return nil
            }
            return decodedIDs == [900, 901]
        }

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 900,
                generation: generation,
                pts: CMTime(value: 2, timescale: 1),
                interlaced: false
            ),
            PlaybackFakeMedia.decodedFrame(
                id: 901,
                generation: generation,
                pts: CMTime(value: 51, timescale: 25),
                interlaced: false
            ),
        ], in: harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 900,
            generation: generation
        ))
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 901,
            generation: generation
        ))
        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        XCTAssertEqual(
            harness.clock.snapshot().anchors.last?.0,
            CMTime(value: 2, timescale: 1)
        )
    }

    func testRecoveryAdvancesToRandomAccessAfterATimestampHole() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let packetDuration = CMTime(value: 1, timescale: 40)
        for index in 0..<20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: packetDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let recoveryFloor = CMTime(value: 6, timescale: 5)
        let randomAccessPTS = CMTimeAdd(
            recoveryFloor,
            CMTimeAdd(PlaybackTuning.default.videoBufferHorizon, packetDuration)
        )

        // The current GOP ends well before the future recovery floor. Put the
        // next independently decodable picture just beyond the active capacity
        // so this exercises gap alignment rather than ordinary decode pacing.
        for index in 10...15 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(1_000 + index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: Int64(index), timescale: 25)
            )))
        }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 2_000,
            generation: generation,
            randomAccess: true,
            pts: randomAccessPTS
        )))

        harness.clock.setTime(recoveryFloor)
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        let recoveryPacketCount = Int(ceil(
            CMTimeGetSeconds(CMTimeSubtract(randomAccessPTS, recoveryFloor))
                / CMTimeGetSeconds(packetDuration)
        )) + 8
        for index in 0..<recoveryPacketCount {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(200 + index),
                generation: generation,
                pts: CMTimeAdd(
                    recoveryFloor,
                    CMTimeMultiply(packetDuration, multiplier: Int32(index))
                ),
                duration: packetDuration
            )))
        }

        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 2_000 && decodedGeneration == generation
                }
                return false
            }
        }

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 2_000,
                generation: generation,
                pts: randomAccessPTS,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        XCTAssertEqual(
            harness.clock.snapshot().anchors.last?.0,
            randomAccessPTS
        )
    }

    func testLateVideoBurstCannotBypassDecoderCompletionCredits() async throws {
        let harness = makeHarness(automaticallyCompleteDecoderSubmissions: false)
        let generation = try await configure(harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))
        _ = await harness.pipeline.debugSnapshot()

        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        harness.clock.setTime(CMTime(value: 6, timescale: 5))
        for index in 0..<40 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(3_000 + index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: Int64(1_200 + index), timescale: 1_000)
            )))
        }
        try await eventually {
            let decodeIDs = harness.decoder.snapshot().compactMap { operation -> UInt64? in
                if case let .decode(id, decodedGeneration, _) = operation,
                   decodedGeneration == generation,
                   id >= 3_000 {
                    return id
                }
                return nil
            }
            let snapshot = await harness.pipeline.debugSnapshot()
            return decodeIDs.count == 8 && snapshot.pendingVideoDecodeCount == 32
        }

        for id in 3_000..<3_003 {
            harness.pipeline.receive(decoder: .submissionCompleted(
                accessUnitID: UInt64(id),
                generation: generation
            ))
        }
        try await eventually {
            let decodeIDs = harness.decoder.snapshot().compactMap { operation -> UInt64? in
                if case let .decode(id, decodedGeneration, _) = operation,
                   decodedGeneration == generation,
                   id >= 3_000 {
                    return id
                }
                return nil
            }
            let snapshot = await harness.pipeline.debugSnapshot()
            return decodeIDs == Array(UInt64(3_000)...UInt64(3_010))
                && snapshot.pendingVideoDecodeCount == 29
        }
    }

    func testSaturatedDecoderWithoutACompletionRestartsInsteadOfDeadlocking() async throws {
        let harness = makeHarness(
            automaticallyCompleteDecoderSubmissions: false,
            videoDecodeStallTimeout: .milliseconds(20)
        )
        let generation = try await configure(harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 6, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let recoveryFloor = CMTime(value: 5, timescale: 1)
        harness.clock.setTime(recoveryFloor)

        for index in 0..<8 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(6_000 + index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: Int64(index), timescale: 100)
            )))
        }

        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation > generation
        }
        XCTAssertTrue(harness.decoder.snapshot().contains(.invalidate))
        let restartedGeneration = await harness.pipeline.debugSnapshot().generation
        try await assertSameTimelineRestartCannotRewind(
            harness,
            generation: restartedGeneration,
            recoveryFloor: recoveryFloor,
            baselineAnchorCount: 1
        )
    }

    func testDecoderSessionFailureRestartCannotReanchorBeforeThePausedClock() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 6, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let recoveryFloor = CMTime(value: 5, timescale: 1)
        harness.clock.setTime(recoveryFloor)
        harness.pipeline.receive(decoder: .submissionFailure(
            .malfunction(kVTVideoDecoderMalfunctionErr),
            generation: generation
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation > generation
        }

        let restartedGeneration = await harness.pipeline.debugSnapshot().generation
        try await assertSameTimelineRestartCannotRewind(
            harness,
            generation: restartedGeneration,
            recoveryFloor: recoveryFloor,
            baselineAnchorCount: 1
        )
    }

    func testPausedDecoderSaturationStartsWatchdogOnlyAfterResume() async throws {
        let stallTimeout: DispatchTimeInterval = .milliseconds(500)
        let harness = makeHarness(
            automaticallyCompleteDecoderSubmissions: false,
            videoDecodeStallTimeout: stallTimeout
        )
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 0,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        harness.pipeline.setPaused(true, readinessCycle: 1)
        try await eventually { (await harness.pipeline.debugSnapshot()).isPaused }
        for index in 0..<8 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(6_100 + index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: Int64(index), timescale: 100)
            )))
        }
        try await eventually {
            harness.decoder.snapshot().filter { operation in
                if case let .decode(id, decodedGeneration, _) = operation {
                    return decodedGeneration == generation && id >= 6_100
                }
                return false
            }.count == 8
        }

        // Hold the media executor across the original timeout. Resume is queued
        // before that deadline, so a watchdog incorrectly armed while paused
        // would run immediately behind resume and advance the generation. The
        // correct watchdog starts when resume actually executes instead.
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        harness.executor.submit {
            blockerEntered.signal()
            _ = releaseBlocker.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 1), .success)
        harness.pipeline.setPaused(false, readinessCycle: 2)
        try await Task.sleep(for: .milliseconds(600))
        releaseBlocker.signal()

        try await eventually { !(await harness.pipeline.debugSnapshot()).isPaused }
        let generationAtResume = await harness.pipeline.debugSnapshot().generation
        XCTAssertEqual(generationAtResume, generation)
        try await Task.sleep(for: .milliseconds(100))
        let generationBeforeFreshDeadline = await harness.pipeline.debugSnapshot().generation
        XCTAssertEqual(generationBeforeFreshDeadline, generation)

        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation > generation
        }
    }

    func testAudioGapWaitsForInFlightGOPBeforeSelectingNewRandomAccess() async throws {
        let harness = makeHarness(
            automaticallyCompleteDecoderSubmissions: false,
            videoDecodeStallTimeout: .seconds(5)
        )
        let generation = try await configure(harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))
        _ = await harness.pipeline.debugSnapshot()

        harness.audio.setReady(true)
        let packetDuration = CMTime(value: 1, timescale: 40)
        for index in 0..<20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: packetDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        let recoveryFloor = CMTime(value: 6, timescale: 5)
        harness.clock.setTime(recoveryFloor)
        for index in 0..<8 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(7_000 + index),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: Int64(1_200 + index * 20), timescale: 1_000)
            )))
        }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 7_100,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 1_460, timescale: 1_000)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 7_200,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 5, timescale: 1)
        )))
        try await eventually {
            let decoded = harness.decoder.snapshot().compactMap { operation -> UInt64? in
                if case let .decode(id, decodedGeneration, _) = operation,
                   decodedGeneration == generation,
                   id >= 7_000 {
                    return id
                }
                return nil
            }
            let snapshot = await harness.pipeline.debugSnapshot()
            return decoded.count == 8 && snapshot.pendingVideoDecodeCount == 2
        }

        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        for index in 0..<180 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(400 + index),
                generation: generation,
                pts: CMTimeAdd(
                    recoveryFloor,
                    CMTimeMultiply(packetDuration, multiplier: Int32(index))
                ),
                duration: packetDuration
            )))
        }
        let closedSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(closedSnapshot.pendingVideoDecodeCount, 2)

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try receiveAndReleaseNormalizedFrames(try (0..<8).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(7_000 + index),
                generation: generation,
                pts: CMTime(value: Int64(1_200 + index * 20), timescale: 1_000),
                interlaced: false
            )
        }, in: harness)
        for index in 0..<8 {
            harness.pipeline.receive(decoder: .submissionCompleted(
                accessUnitID: UInt64(7_000 + index),
                generation: generation
            ))
        }
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 7_200 && decodedGeneration == generation
                }
                return false
            }
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 7_200,
                generation: generation,
                pts: CMTime(value: 5, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }

        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, decodedGeneration, _) = $0 {
                return id == 7_100 && decodedGeneration == generation
            }
            return false
        })
    }

    func testOpenPlaybackPacesVideoFromClockNotAudioRecoveryHistory() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        // The compressed audio renderer can already own later samples even
        // when the bounded recovery history ends here. Running video follows
        // the shared clock; using this stale history as a second ceiling would
        // strand every access unit after 0.75 seconds.
        harness.clock.setTime(CMTime(value: 10, timescale: 1))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 100,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 101, timescale: 10)
        )))

        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 100 && decodedGeneration == generation
                }
                return false
            }
        }
        let snapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(snapshot.pendingVideoDecodeCount, 0)
    }

    func testAudioTimestampRoundingDoesNotBreakStartupContinuity() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)

        // MPEG-TS timestamps use a 90 kHz clock while AAC duration is exact at
        // 44.1 kHz. Rounding 1,024 samples to 2,090 transport ticks leaves a
        // harmless ~2 microsecond gap between some adjacent packets.
        let audioDuration = CMTime(value: 1_024, timescale: 44_100)
        for index in 0..<12 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index * 2_090), timescale: 90_000),
                duration: audioDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(harness.clock.snapshot().anchors.last?.0, .zero)
        XCTAssertEqual(harness.display.snapshot().last, "resume")
    }

    func testRebufferingAdvancesAudioWindowToDeferredVideoAfterPlaybackOpened() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let audioDuration = CMTime(value: 1, timescale: 40)

        for index in 0..<20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        let recoveryPTS = CMTime(value: 3, timescale: 1)
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 100,
            generation: generation,
            randomAccess: true,
            pts: recoveryPTS
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 200,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 25, timescale: 4)
        )))
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)

        for index in 20..<420 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 100 && decodedGeneration == generation
                }
                return false
            }
        }

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 100,
                generation: generation,
                pts: recoveryPTS,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().filter { $0 == .ready(readinessCycle: 0) }.count == 2
        }
        XCTAssertEqual(harness.display.snapshot().last, "resume")
    }

    func testAudioReplacementContinuesCurrentGOPWithoutWaitingForFutureRandomAccess() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let audioDuration = CMTime(value: 1, timescale: 40)

        for index in 0..<20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 100,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 3, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 200,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 7, timescale: 2)
        )))

        // Audio replacement does not reset VideoToolbox's reference chain. Once
        // audio reaches this GOP, recovery must keep its non-random-access head
        // instead of freezing until the next (potentially five-second) IDR.
        for index in 20..<150 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }

        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 100 && decodedGeneration == generation
                }
                return false
            }
        }

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 100,
                generation: generation,
                pts: CMTime(value: 3, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        harness.clock.setTime(CMTime(value: 33, timescale: 10))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 200 && decodedGeneration == generation
                }
                return false
            }
        }
        let snapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(snapshot.pendingVideoDecodeCount, 0)
    }

    func testClosedReadinessPreservesDeferredHeadWhenBacklogIsFull() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let audioDuration = CMTime(value: 1, timescale: 40)

        for index in 0..<20 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }

        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        for index in 0..<PlaybackPipeline.pendingVideoDecodeCapacity {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: UInt64(1_000 + index),
                generation: generation,
                randomAccess: index == 0,
                pts: CMTime(value: Int64(120 + index), timescale: 40)
            )))
        }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 9_999,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 9, timescale: 1)
        )))

        for index in 20..<160 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 1_000 && decodedGeneration == generation
                }
                return false
            }
        }
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 { return id == 9_999 }
            return false
        })
    }

    func testClosedReadinessKeepsDecoderPoolHeadroomAndDefersDisplaySubmission() async throws {
        let metrics = PlaybackMetrics(
            channelID: "decoder-pool-headroom",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)

        // A full horizon of 25 fps video.
        let framesPerHorizon = 25
        let frames = try (0..<framesPerHorizon).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 25),
                interlaced: false
            )
        }
        try receiveAndReleaseNormalizedFrames(frames, in: harness)

        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedVideoCount ==
                PlaybackPipeline.startupRetainedVideoCapacity
        }
        XCTAssertLessThan(PlaybackPipeline.startupRetainedVideoCapacity, framesPerHorizon)
        XCTAssertTrue(harness.renderer.snapshot().frames.isEmpty)
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
    }

    func testFourKDecodeWaitsForInterleavedAudioInsteadOfOverflowingDecodedSurfaces() async throws {
        let metrics = PlaybackMetrics(
            channelID: "4k-compressed-video-pacing",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))

        let duration = CMTime(value: 1, timescale: 50)
        let dimensions = CMVideoDimensions(width: 3_840, height: 2_160)
        for index in 0..<8 {
            harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 50),
                interlaced: false,
                duration: duration,
                dimensions: dimensions,
                bitDepth: 10
            )))
        }
        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedVideoCount > 0
        }

        let futureID: UInt64 = 900
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: futureID,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 1, timescale: 1),
            duration: duration
        )))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 { return id == futureID }
            return false
        })

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 2),
            duration: CMTime(value: 1, timescale: 2)
        )))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 { return id == futureID }
            return false
        })
        harness.clock.setTime(CMTime(value: 4, timescale: 5))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 3,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: duration
        )))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == futureID }
                return false
            }
        }
    }

    func testLateStartingAudioReleasesBoundedEarlyVideoWindowBeforeAnotherDecoderCallback() async throws {
        let metrics = PlaybackMetrics(
            channelID: "late-audio",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)
        harness.audio.setReady(true)

        let earlyFrames = try (0..<50).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 25),
                interlaced: false
            )
        }
        try receiveAndReleaseNormalizedFrames(earlyFrames, in: harness)
        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedVideoCount ==
                PlaybackPipeline.startupRetainedVideoCapacity
        }

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: CMTime(value: 5, timescale: 1),
            duration: CMTime(value: 1, timescale: 4)
        )))

        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedVideoCount == 0
        }
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
    }

    func testAudioAnchorPreparationFailureVetoesReadyRateAndDisplayResume() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try await eventually { harness.audio.snapshot().samples.count == 1 }
        harness.audio.prepareAnchorError = .audioRendererFailed("anchor.prepare")
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.failed(.audioRendererFailed("anchor.prepare")))
        }
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
        XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)
        XCTAssertFalse(harness.display.snapshot().contains("resume"))
        let snapshot = await harness.pipeline.debugSnapshot()
        XCTAssertTrue(snapshot.isTerminal)
    }

    func testExternalAudioAnchorPreparationWaitsForReadinessWithoutRepeatingForever() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        let initialPreparationCount = harness.audio.snapshot().anchorPreparations.count
        harness.audio.setSynchronousReadinessCallback(onPrepare: true) {
            [audio = harness.audio, pipeline = harness.pipeline] generation in
            audio.setReady(false)
            pipeline.receive(audioReadiness: .invalidated, generation: generation)
        }
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.audio.snapshot().anchorPreparations.count == initialPreparationCount + 1
        }
        XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(
            harness.audio.snapshot().anchorPreparations.count,
            initialPreparationCount + 2
        )
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)
    }

    func testExternalAudioInvalidationClosesAndReopensTheSoleReadinessGate() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().filter { $0 == .ready(readinessCycle: 0) }.count == 1
        }

        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)
        try await eventually { harness.display.snapshot().last == "pause" }
        let anchorsAfterInvalidation = harness.clock.snapshot().anchors.count
        XCTAssertEqual(anchorsAfterInvalidation, 1)

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try await eventually {
            harness.events.snapshot().filter { $0 == .ready(readinessCycle: 0) }.count == 2
        }
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 2)
        XCTAssertGreaterThanOrEqual(harness.renderer.snapshot().resets, 3)
    }

    func testDisplayModeSwitchWaitsForLaterReadinessThenResetsBeforeTheOnlyResume() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation, pts: .zero, interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.display.snapshot().last == "resume" }

        harness.pipeline.displayModeSwitchStarted()
        harness.audio.setReady(false)
        harness.pipeline.displayModeSwitchEnded()
        try await eventually { harness.display.snapshot().last == "pause" }
        let operationsWhileClosed = harness.display.snapshot()
        XCTAssertFalse(operationsWhileClosed.suffix(2).contains("reset"))

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try await eventually { harness.display.snapshot().suffix(2) == ["reset", "resume"] }
        XCTAssertEqual(
            harness.display.snapshot().dropFirst(operationsWhileClosed.count).filter {
                $0 == "resume"
            }.count,
            1
        )
    }

    func testRepeatedFramesWithSameFormatRouteAndCadenceRequestCriteriaOnlyOnce() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 2)
        )))

        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: CMTime(value: 1, timescale: 25),
                interlaced: false
            ),
            PlaybackFakeMedia.decodedFrame(
                id: 3,
                generation: generation,
                pts: CMTime(value: 2, timescale: 25),
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.renderer.snapshot().frames.count >= 3
        }

        XCTAssertEqual(
            harness.display.snapshot().filter { $0.hasPrefix("criteria:") }.count,
            1
        )
    }

    func testPauseKeepsBoundedPacketsAndBackpressuresUntilResume() async throws {
        let harness = makeHarness()
        _ = try await configure(harness)
        harness.pipeline.setPaused(true, readinessCycle: 1)
        try await eventually { (await harness.pipeline.debugSnapshot()).isPaused }

        let finished = LockedFlag()
        let emitter = Task.detached {
            for id in 0..<PlaybackPipeline.deferredPacketCapacity + 1 {
                harness.demux.emit(.packet(DemuxPacket(
                    streamIndex: 100,
                    codec: .video(.h264),
                    data: Data([UInt8(id & 0xff)]),
                    presentationTimeStamp: CMTime(value: Int64(id), timescale: 25),
                    decodeTimeStamp: .invalid,
                    duration: CMTime(value: 1, timescale: 25),
                    isKey: false,
                    isCorrupt: false
                )))
            }
            finished.set()
        }
        try await eventually { (await harness.pipeline.debugSnapshot()).deferredPacketCount == PlaybackPipeline.deferredPacketCapacity }
        XCTAssertFalse(finished.value)
        XCTAssertEqual(harness.demux.snapshot().cancelCount, 0)

        harness.pipeline.setPaused(false, readinessCycle: 2)
        _ = await emitter.value
        try await eventually { finished.value }
        let resumedSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertLessThanOrEqual(resumedSnapshot.deferredPacketCount, PlaybackPipeline.deferredPacketCapacity)
    }

    func testEndCancellationAndFailureUseDistinctTerminalPaths() async throws {
        let ended = makeHarness()
        let endedGeneration = try await configure(ended)
        let rendererFlushCount = ended.renderer.snapshot().flushes.count
        let audioFlushCount = ended.audio.snapshot().flushes.count
        ended.demux.emit(.endOfStream)
        try await eventually { ended.events.snapshot().contains(.stopped) }
        XCTAssertEqual(ended.decoder.snapshot().suffix(3), [.finish, .wait, .invalidate])
        XCTAssertEqual(ended.renderer.snapshot().flushes.count, rendererFlushCount + 1)
        XCTAssertEqual(ended.renderer.snapshot().flushes.last, endedGeneration)
        XCTAssertEqual(ended.audio.snapshot().flushes.count, audioFlushCount + 1)
        XCTAssertEqual(ended.audio.snapshot().flushes.last, endedGeneration)
        XCTAssertEqual(ended.display.snapshot().last, "clear")

        let cancelled = makeHarness()
        _ = try await configure(cancelled)
        await cancelled.pipeline.stop()
        try await eventually { cancelled.events.snapshot().contains(.stopped) }
        cancelled.demux.emit(.cancelled)
        cancelled.pipeline.receive(failure: .metalCommand("late"), generation: (await cancelled.pipeline.debugSnapshot()).generation)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(cancelled.events.snapshot().contains { if case .failed = $0 { true } else { false } })

        let failed = makeHarness()
        let generation = try await configure(failed)
        failed.pipeline.receive(failure: .renderTextureMapping, generation: generation)
        failed.pipeline.receive(failure: .metalCommand("second"), generation: generation)
        try await eventually { failed.events.snapshot().contains(.failed(.renderTextureMapping)) }
        XCTAssertEqual(failed.events.snapshot().filter { if case .failed = $0 { true } else { false } }.count, 1)
        XCTAssertFalse(failed.decoder.snapshot().contains(.wait))
    }

    func testEOSAndConcurrentExplicitStopAwaitAudioRemovalBeforeOneTerminalCompletion() async throws {
        let harness = makeHarness()
        _ = try await configure(harness)
        harness.audio.stopAutomaticallyCompletes = false

        harness.demux.emit(.endOfStream)
        try await eventually { harness.audio.snapshot().isStopWaiting }
        XCTAssertFalse(harness.events.snapshot().contains(.stopped))
        XCTAssertFalse(harness.display.snapshot().contains("clear"))

        let stopFinished = LockedFlag()
        let explicitStop = Task {
            await harness.pipeline.stop()
            stopFinished.set()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(stopFinished.value)
        XCTAssertEqual(harness.audio.snapshot().stops, 1)

        harness.audio.completeStop()
        await explicitStop.value
        XCTAssertTrue(stopFinished.value)
        XCTAssertEqual(harness.events.snapshot().filter { $0 == .stopped }.count, 1)
        XCTAssertEqual(harness.display.snapshot().filter { $0 == "clear" }.count, 1)
        XCTAssertEqual(harness.audio.snapshot().stops, 1)
    }

    func testNormalStopDoesNotReturnOrPublishUntilDisplayClearCompletes() async throws {
        let harness = makeHarness()
        _ = try await configure(harness)
        harness.display.clearAutomaticallyCompletes = false
        let stopFinished = LockedFlag()

        let stop = Task {
            await harness.pipeline.stop()
            stopFinished.set()
        }
        try await eventually { harness.display.isClearWaiting }

        XCTAssertFalse(stopFinished.value)
        XCTAssertFalse(harness.events.snapshot().contains(.stopped))
        harness.display.completeClear()
        await stop.value

        XCTAssertTrue(stopFinished.value)
        XCTAssertEqual(harness.events.snapshot().filter { $0 == .stopped }.count, 1)
    }

    func testFailureIsNotPublishedUntilDisplayClearCompletes() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.display.clearAutomaticallyCompletes = false

        harness.pipeline.receive(failure: .renderTextureMapping, generation: generation)
        try await eventually { harness.display.isClearWaiting }
        let stopFinished = LockedFlag()
        let stop = Task {
            await harness.pipeline.stop()
            stopFinished.set()
        }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(harness.events.snapshot().contains(.failed(.renderTextureMapping)))
        XCTAssertFalse(stopFinished.value)
        harness.display.completeClear()
        await stop.value
        try await eventually {
            harness.events.snapshot().contains(.failed(.renderTextureMapping))
        }
        XCTAssertTrue(stopFinished.value)
    }

    func testNormalStopIsolatesEveryDrainAndDecoderStageFailure() async throws {
        enum Stage { case videoDrain, audioDrain, finish, wait }
        for stage in [Stage.videoDrain, .audioDrain, .finish, .wait] {
            let harness = makeHarness()
            _ = try await configure(harness)
            switch stage {
            case .videoDrain:
                harness.assemblers.video.drainError = .videoDecode(-101)
            case .audioDrain:
                harness.assemblers.audio.drainError = .audioFallbackDecode(-102)
            case .finish:
                harness.decoder.finishError = .malfunction(-103)
            case .wait:
                harness.decoder.waitError = .malfunction(-104)
            }

            await harness.pipeline.stop()

            XCTAssertEqual(harness.assemblers.video.drainCount, 1)
            XCTAssertEqual(harness.assemblers.audio.drainCount, 1)
            XCTAssertTrue(harness.decoder.snapshot().contains(.finish))
            XCTAssertTrue(harness.decoder.snapshot().contains(.wait))
            XCTAssertEqual(harness.decoder.snapshot().last, .invalidate)
            XCTAssertEqual(harness.audio.snapshot().stops, 1)
            XCTAssertEqual(harness.display.snapshot().suffix(2), ["pause", "clear"])
            XCTAssertEqual(harness.events.snapshot().filter { $0 == .stopped }.count, 1)
        }
    }

    func testOneHundredRandomizedOldCallbacksNeverReachPresentation() async throws {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for iteration in 0..<100 {
            let harness = makeHarness()
            let oldGeneration = try await configure(harness)
            let replacementFingerprint = MediaFormatFingerprint(bytes: Data([UInt8(iteration + 17)]))
            harness.pipeline.receive(video: .format(
                try PlaybackFakeMedia.videoFormat(), replacementFingerprint
            ))
            harness.pipeline.receive(audio: .format(
                try PlaybackFakeMedia.audioConfiguration(fingerprint: replacementFingerprint)
            ))
            try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue > oldGeneration.rawValue }
            let current = (await harness.pipeline.debugSnapshot()).generation
            harness.audio.setReady(true)
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: 1,
                generation: current,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 2)
            )))
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: 200,
                generation: current,
                randomAccess: true
            )))
            var callbacks = [
                try PlaybackFakeMedia.decodedFrame(id: 1, generation: oldGeneration, pts: .zero, interlaced: false),
                try PlaybackFakeMedia.decodedFrame(id: 2, generation: current, pts: .zero, interlaced: false),
                try PlaybackFakeMedia.decodedFrame(
                    id: 3,
                    generation: current,
                    pts: CMTime(value: 1, timescale: 25),
                    interlaced: false
                ),
                try PlaybackFakeMedia.decodedFrame(
                    id: 4,
                    generation: current,
                    pts: CMTime(value: 2, timescale: 25),
                    interlaced: false
                ),
            ]
            callbacks.shuffle(using: &generator)
            for callback in callbacks { harness.pipeline.receive(decoder: .frame(callback)) }
            try await eventually { harness.renderer.snapshot().frames.contains { $0.generation == current } }
            XCTAssertFalse(harness.renderer.snapshot().frames.contains { $0.generation == oldGeneration })
            await harness.pipeline.stop()
        }
    }

    func testDisplaySubmissionResumesOnEveryReadinessOpenNotJustTheFirst() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1, generation: generation, pts: .zero, duration: CMTime(value: 1, timescale: 4)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation, pts: .zero, interlaced: false
            ),
        ], in: harness)
        // `updateDisplayCriteria` also records operations, so compare only the
        // submission transitions.
        func lastSubmissionOperation() -> String? {
            harness.display.snapshot().last { $0 == "pause" || $0 == "resume" }
        }
        try await eventually { lastSubmissionOperation() == "resume" }

        // An audio renderer replacement closes the gate and pauses submission.
        harness.pipeline.receive(
            audioReadiness: .invalidated,
            generation: generation
        )
        try await eventually { lastSubmissionOperation() == "pause" }

        // Reopening must resume submission again. Leaving it paused strands the
        // presentation queue: frames keep arriving and overflow without ever
        // being selected for display.
        harness.pipeline.receive(
            audioReadiness: .available,
            generation: generation
        )
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 4),
            duration: CMTime(value: 1, timescale: 4)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 2,
                generation: generation,
                pts: CMTime(value: 1, timescale: 25),
                interlaced: false
            ),
        ], in: harness)

        try await eventually { lastSubmissionOperation() == "resume" }
    }

    func testAudioRegressionNeverReachesRenderer() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 4)
        )))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 2),
            duration: CMTime(value: 1, timescale: 4)
        )))

        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(harness.audio.snapshot().samples.map(\.id), [1])
    }

    func testContinuityDiagnosticsCountEveryDropReasonAndGapTransition() async throws {
        let metrics = PlaybackMetrics(
            channelID: "synthetic-continuity-diagnostics",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1, generation: generation, pts: .zero, duration: .zero
        )))
        for id in 2...3 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id),
                generation: MediaGeneration(rawValue: generation.rawValue + 1),
                pts: .zero,
                duration: CMTime(value: 1, timescale: 4)
            )))
        }
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 4,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        for id in 5...7 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id),
                generation: generation,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 4)
            )))
        }
        for id in 8...11 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id),
                generation: generation,
                pts: CMTime(value: 1, timescale: 8),
                duration: CMTime(value: 1, timescale: 4)
            )))
        }
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 12,
            generation: generation,
            pts: CMTime(value: 450, timescale: 1_000),
            duration: CMTime(value: 1, timescale: 4)
        )))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 13,
            generation: generation,
            pts: CMTime(value: 900, timescale: 1_000),
            duration: CMTime(value: 1, timescale: 4)
        )))

        _ = await harness.pipeline.debugSnapshot()
        var snapshot = try XCTUnwrap(
            harness.pipeline.metricsSnapshot(window: .seconds(60))
        )
        XCTAssertEqual(snapshot.audioContinuityDropCountsByReason, [1, 2, 3, 4, 0])
        XCTAssertEqual(snapshot.audioShortGapCount, 2)
        XCTAssertEqual(snapshot.audioLargeGapCount, 0)
        XCTAssertEqual(snapshot.audioContinuityIslandSwitchCount, 0)

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 14,
            generation: generation,
            pts: CMTime(value: 2, timescale: 1),
            duration: CMTime(value: 1, timescale: 4)
        )))
        _ = await harness.pipeline.debugSnapshot()
        snapshot = try XCTUnwrap(harness.pipeline.metricsSnapshot(window: .seconds(60)))
        XCTAssertEqual(snapshot.audioShortGapCount, 2)
        XCTAssertEqual(snapshot.audioLargeGapCount, 1)
        XCTAssertEqual(snapshot.audioContinuityIslandSwitchCount, 1)

        for (id, pts) in [(15, 3), (16, 4)] {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id),
                generation: generation,
                pts: CMTime(value: Int64(pts), timescale: 1),
                duration: CMTime(value: 1, timescale: 4)
            )))
        }
        for id in 17...21 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(id),
                generation: generation,
                pts: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 1, timescale: 8)
            )))
        }

        _ = await harness.pipeline.debugSnapshot()
        snapshot = try XCTUnwrap(harness.pipeline.metricsSnapshot(window: .seconds(60)))
        XCTAssertEqual(snapshot.audioContinuityDropCountsByReason, [1, 2, 3, 4, 5])
        XCTAssertEqual(snapshot.audioShortGapCount, 2)
        XCTAssertEqual(snapshot.audioLargeGapCount, 3)
        XCTAssertEqual(snapshot.audioContinuityIslandSwitchCount, 3)
    }

    func testContinuityGapMetricsPublishBeforeRendererEnqueueFailure() async throws {
        let metrics = PlaybackMetrics(
            channelID: "continuity-failure-sentinel",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        _ = await harness.pipeline.debugSnapshot()
        harness.audio.enqueueError = .audioRendererFailed("synthetic-enqueue-failure")

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 4)
        )))
        _ = await harness.pipeline.debugSnapshot()

        let snapshot = try XCTUnwrap(
            harness.pipeline.metricsSnapshot(window: .seconds(60))
        )
        XCTAssertEqual(snapshot.audioLargeGapCount, 1)
        XCTAssertEqual(snapshot.audioContinuityIslandSwitchCount, 1)
    }

    func testEveryDecodeBreakReasonMarksNextAcceptedFrameForDecoderReset() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        for (offset, reason) in [
            AudioDecodeBreakReason.corruptPacket,
            .framingReset,
            .invalidFrame,
        ].enumerated() {
            harness.pipeline.receive(audio: .decodeBreak(reason))
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(offset + 2),
                generation: generation,
                pts: CMTime(value: Int64(offset + 1), timescale: 4),
                duration: CMTime(value: 1, timescale: 4)
            )))
        }

        try await eventually { harness.audio.snapshot().samples.count == 4 }
        for sample in harness.audio.snapshot().samples.dropFirst() {
            try assertBooleanAttachment(
                kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                on: sample.sampleBuffer
            )
        }
    }

    func testShortAudioGapKeepsReadinessOpenAndEnqueuesSilenceFill() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        let readyCount = harness.events.snapshot().filter {
            if case .ready = $0 { return true }
            return false
        }.count
        let pauseCount = harness.display.snapshot().filter { $0 == "pause" }.count

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 450, timescale: 1_000),
            duration: CMTime(value: 1, timescale: 4)
        )))

        try await eventually { harness.audio.snapshot().samples.last?.id == 2 }
        let sample = try XCTUnwrap(harness.audio.snapshot().samples.last)
        XCTAssertEqual(sample.continuityIslandID, AudioContinuityIslandID(rawValue: 1))
        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            on: sample.sampleBuffer
        )
        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
            on: sample.sampleBuffer
        )
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)
        XCTAssertEqual(harness.display.snapshot().filter { $0 == "pause" }.count, pauseCount)
        XCTAssertEqual(harness.events.snapshot().filter {
            if case .ready = $0 { return true }
            return false
        }.count, readyCount)
    }

    func testLargeAudioGapActivatesOnlyNewRendererIsland() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))

        try await eventually {
            harness.audio.snapshot().continuityIslandActivations.count == 2
        }
        XCTAssertEqual(
            harness.audio.snapshot().continuityIslandActivations.map(\.0),
            [AudioContinuityIslandID(rawValue: 1), AudioContinuityIslandID(rawValue: 2)]
        )
        XCTAssertEqual(harness.audio.snapshot().samples.map(\.id), [2])
        let snapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(snapshot.generation, generation)
    }

    func testLargeAudioGapWaitsForOutstandingVideoBeforeRandomAccessEscape() async throws {
        let harness = makeHarness(automaticallyCompleteDecoderSubmissions: false)
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 1, timescale: 1)
        )))

        _ = await harness.pipeline.debugSnapshot()
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 { return id == 20 }
            return false
        })

        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == 20 }
                return false
            }
        }
    }

    func testLargeAudioGapRejectsOldCallbacksAsReanchorEvidence() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 999,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            interlaced: false
        )))

        _ = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)

        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 20,
                generation: generation,
                pts: CMTime(value: 1, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 2 }
    }

    func testLargeAudioGapRejectsPreGapProcessorCompletionAfterAnchorTransactionClears()
        async throws {
        let harness = makeHarness(automaticallyCompleteDecoderSubmissions: false)
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))

        harness.processor.setAutomaticallyCompletes(false)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 10,
                generation: generation,
                pts: CMTime(value: 11, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.processor.pendingAccessUnitIDs.contains(10) }

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 10, timescale: 1),
            duration: CMTime(value: 3, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 12, timescale: 1)
        )))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == 20 }
                return false
            }
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 20,
                generation: generation,
                pts: CMTime(value: 12, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 20,
            generation: generation
        ))
        try await eventually { harness.processor.pendingAccessUnitIDs.contains(20) }
        harness.processor.completePending(accessUnitIDs: [20])

        try await eventually {
            guard harness.clock.snapshot().anchors.count == 2 else { return false }
            return (await harness.pipeline.debugSnapshot()).audioGapVideoEvidenceRecordCount == 0
        }
        let anchoredSnapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(
            anchoredSnapshot.audioGapVideoEvidenceRecordCount,
            0,
            "the pre-gap completion must be released only after the transaction is gone"
        )
        let framesBeforeStaleCompletion = harness.renderer.snapshot().frames

        harness.processor.completePending(accessUnitIDs: [10])
        _ = await harness.pipeline.debugSnapshot()

        XCTAssertEqual(harness.clock.snapshot().anchors.count, 2)
        XCTAssertEqual(
            harness.renderer.snapshot().frames.map(\.sourceAccessUnitID),
            framesBeforeStaleCompletion.map(\.sourceAccessUnitID)
        )
        XCTAssertFalse(harness.renderer.snapshot().frames.contains {
            $0.sourceAccessUnitID == 10
        })

        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 30,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 14, timescale: 1)
        )))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == 30 }
                return false
            }
        }
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 30,
                generation: generation,
                pts: CMTime(value: 14, timescale: 1),
                interlaced: false
            ),
        ], in: harness)
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 30,
            generation: generation
        ))
        try await eventually { harness.processor.pendingAccessUnitIDs.contains(30) }
        harness.processor.completePending(accessUnitIDs: [30])

        try await eventually {
            harness.renderer.snapshot().frames.contains { $0.sourceAccessUnitID == 30 }
        }
    }

    func testLargeAudioGapBoundsEvidenceWhileCurrentProcessorCallbacksAreDelayed() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        let baselineProcessedCount = harness.processor.snapshot().metadata.count
        harness.processor.setAutomaticallyCompletes(false)
        harness.audio.setReady(false)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 10, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))

        let firstRecoveryID: UInt64 = 100
        let submittedCount = 160
        for offset in 0..<submittedCount {
            let id = firstRecoveryID + UInt64(offset)
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: id,
                generation: generation,
                randomAccess: offset == 0,
                pts: CMTime(value: 250 + Int64(offset), timescale: 25)
            )))
        }
        try await eventually(timeout: .seconds(2)) {
            harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 {
                    return id == firstRecoveryID + UInt64(submittedCount - 1)
                }
                return false
            }
        }

        for offset in 0..<submittedCount {
            let id = firstRecoveryID + UInt64(offset)
            harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
                id: id,
                generation: generation,
                pts: CMTime(value: 250 + Int64(offset), timescale: 25),
                interlaced: false
            )))
        }
        try await eventually(timeout: .seconds(2)) {
            harness.processor.snapshot().metadata.count
                >= baselineProcessedCount + submittedCount
        }

        let stalled = await harness.pipeline.debugSnapshot()
        XCTAssertLessThanOrEqual(stalled.audioGapVideoEvidenceRecordCount, 1)

        harness.audio.setReady(true)
        harness.processor.completePending()
        try await eventually(timeout: .seconds(2)) {
            harness.clock.snapshot().anchors.count == 2
        }
        let recoveredFrames = harness.renderer.snapshot().frames
        XCTAssertFalse(recoveredFrames.isEmpty)
        XCTAssertTrue(recoveredFrames.allSatisfy {
            $0.sourceAccessUnitID >= firstRecoveryID
                && $0.sourceAccessUnitID < firstRecoveryID + UInt64(submittedCount)
        })
    }

    func testLargeAudioGapWaitsForRandomAccessAtOrAfterNewAudioIsland() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 2, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 3, timescale: 2)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 21,
            generation: generation,
            randomAccess: false,
            pts: CMTime(value: 2, timescale: 1)
        )))

        _ = await harness.pipeline.debugSnapshot()
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 { return id == 20 || id == 21 }
            return false
        })

        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 22,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 2, timescale: 1)
        )))
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == 22 }
                return false
            }
        }
    }

    func testLargeAudioGapPreservesFirstEligibleRandomAccessWhenPendingQueueIsFull() async throws {
        let harness = makeHarness(automaticallyCompleteDecoderSubmissions: false)
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 10, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))

        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 9, timescale: 1)
        )))
        for offset in 0..<511 {
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: 21 + UInt64(offset),
                generation: generation,
                randomAccess: false,
                pts: CMTime(value: 226 + Int64(offset), timescale: 25)
            )))
        }
        try await eventually {
            (await harness.pipeline.debugSnapshot()).pendingVideoDecodeCount == 512
        }

        let eligibleID: UInt64 = 1_000
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: eligibleID,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 10, timescale: 1)
        )))
        harness.pipeline.receive(decoder: .submissionCompleted(
            accessUnitID: 0,
            generation: generation
        ))

        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, _, _) = $0 { return id == eligibleID }
                return false
            }
        }
        let postGapDecodeIDs = harness.decoder.snapshot().compactMap { operation -> UInt64? in
            guard case let .decode(id, _, _) = operation, id != 0 else { return nil }
            return id
        }
        XCTAssertEqual(postGapDecodeIDs.first, eligibleID)
        XCTAssertFalse(postGapDecodeIDs.contains { $0 >= 20 && $0 < eligibleID })
    }

    func testLargeAudioGapReanchorsAudioAndVideoExactlyOnce() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        let preparationCount = harness.audio.snapshot().anchorPreparations.count
        let rendererResetCount = harness.renderer.snapshot().resets
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 20,
                generation: generation,
                pts: CMTime(value: 1, timescale: 1),
                interlaced: false
            ),
        ], in: harness)

        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        XCTAssertEqual(harness.audio.snapshot().anchorPreparations.count, preparationCount + 1)
        XCTAssertEqual(harness.renderer.snapshot().resets, rendererResetCount + 1)
        XCTAssertEqual(harness.clock.snapshot().anchors.last?.0, CMTime(value: 1, timescale: 1))
    }

    func testLargeAudioGapNeverReplaysPreviousAudioIsland() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 20,
                generation: generation,
                pts: CMTime(value: 1, timescale: 1),
                interlaced: false
            ),
        ], in: harness)

        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        XCTAssertEqual(harness.audio.snapshot().samples.map(\.id), [2])
        XCTAssertEqual(
            Set(harness.audio.snapshot().samples.map(\.continuityIslandID)),
            [AudioContinuityIslandID(rawValue: 2)]
        )
    }

    func testSynchronousAudioReadinessCannotReenterAnchorTransaction() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        try await openInitialSharedTimeline(harness, generation: generation)
        harness.audio.setSynchronousReadinessCallback(onEnqueue: true, maxCallbacks: 4) {
            [pipeline = harness.pipeline] generation in
            pipeline.receive(audioReadiness: .available, generation: generation)
        }
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 1)
        )))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 20,
            generation: generation,
            randomAccess: true,
            pts: CMTime(value: 1, timescale: 1)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 20,
                generation: generation,
                pts: CMTime(value: 1, timescale: 1),
                interlaced: false
            ),
        ], in: harness)

        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        XCTAssertEqual(harness.audio.snapshot().anchorPreparations.count, 2)
        XCTAssertLessThanOrEqual(harness.audio.synchronousReadinessCallbackCountSnapshot, 1)
    }

    func testAudioOnlyLargeGapReanchorsDirectlyAtNewIsland() async throws {
        let harness = makeHarness()
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.audioOnlyTracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        let fingerprint = MediaFormatFingerprint(bytes: Data([0xA9]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: 1)
        }
        let generation = await harness.pipeline.debugSnapshot().generation
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 2,
            generation: generation,
            pts: CMTime(value: 1, timescale: 1),
            duration: CMTime(value: 1, timescale: 2)
        )))

        try await eventually { harness.clock.snapshot().anchors.count == 2 }
        XCTAssertEqual(harness.clock.snapshot().anchors.last?.0, CMTime(value: 1, timescale: 1))
        XCTAssertEqual(harness.audio.snapshot().anchorPreparations.last?.1,
                       AudioContinuityIslandID(rawValue: 2))
        let snapshot = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(snapshot.generation, generation)
    }

    private func configure(
        _ harness: Harness,
        initialRandomAccessPTS: CMTime? = .zero
    ) async throws -> MediaGeneration {
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        let fingerprint = MediaFormatFingerprint(bytes: Data([1]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioConfiguration(fingerprint: fingerprint)
        ))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), fingerprint
        ))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == 1 }
        let generation = await harness.pipeline.debugSnapshot().generation
        guard let initialRandomAccessPTS else { return generation }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 0,
            generation: generation,
            randomAccess: true,
            pts: initialRandomAccessPTS
        )))
        try await eventually {
            harness.decoder.snapshot().contains(.configure(generation))
        }
        return generation
    }

    private func openInitialSharedTimeline(
        _ harness: Harness,
        generation: MediaGeneration
    ) async throws {
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 0,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)
        try await eventually { harness.clock.snapshot().anchors.count == 1 }
    }

    private func assertBooleanAttachment(
        _ key: CFString,
        on sampleBuffer: CMSampleBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var mode = kCMAttachmentMode_ShouldNotPropagate
        let value = try XCTUnwrap(
            CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: &mode),
            file: file,
            line: line
        )
        XCTAssertTrue(CFEqual(value, kCFBooleanTrue), file: file, line: line)
        XCTAssertEqual(mode, kCMAttachmentMode_ShouldPropagate, file: file, line: line)
    }

    private func receiveAndReleaseNormalizedFrames(
        _ frames: [DecodedVideoFrame],
        in harness: Harness
    ) throws {
        guard let last = frames.last else { return }
        for frame in frames {
            harness.pipeline.receive(decoder: .frame(frame))
        }
        for offset in 1...2 {
            harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
                id: last.accessUnitID &+ UInt64(offset),
                generation: last.generation,
                pts: CMTimeAdd(
                    last.presentationTimeStamp,
                    CMTimeMultiply(last.duration, multiplier: Int32(offset))
                ),
                interlaced: last.parserMetadata.isInterlaced ?? false
            )))
        }
    }

    private func assertSameTimelineRestartCannotRewind(
        _ harness: Harness,
        generation: MediaGeneration,
        recoveryFloor: CMTime,
        baselineAnchorCount: Int
    ) async throws {
        let packetDuration = CMTime(value: 1, timescale: 40)
        let staleStart = CMTimeSubtract(
            recoveryFloor,
            CMTime(value: 1, timescale: 2)
        )
        for index in 0..<40 {
            harness.pipeline.receive(audio: .frame(PlaybackFakeMedia.audioFrame(
                id: UInt64(20_000 + index),
                generation: generation,
                pts: CMTimeAdd(
                    staleStart,
                    CMTimeMultiply(packetDuration, multiplier: Int32(index))
                ),
                duration: packetDuration
            )))
        }
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 30_000,
            generation: generation,
            randomAccess: true,
            pts: staleStart
        )))
        try await eventually {
            harness.decoder.snapshot().contains(.configure(generation))
        }

        for index in 0..<8 {
            harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
                id: UInt64(30_000 + index),
                generation: generation,
                pts: CMTimeAdd(
                    staleStart,
                    CMTime(value: Int64(index), timescale: 25)
                ),
                interlaced: false
            )))
        }
        _ = await harness.pipeline.debugSnapshot()

        XCTAssertEqual(harness.clock.snapshot().anchors.count, baselineAnchorCount)
        XCTAssertTrue(harness.renderer.snapshot().frames.isEmpty)

        try receiveAndReleaseNormalizedFrames(try (0..<3).map { index in
            try PlaybackFakeMedia.decodedFrame(
                id: UInt64(31_000 + index),
                generation: generation,
                pts: CMTimeAdd(
                    recoveryFloor,
                    CMTime(value: Int64(index), timescale: 25)
                ),
                interlaced: false
            )
        }, in: harness)
        try await eventually {
            harness.clock.snapshot().anchors.count == baselineAnchorCount + 1
        }

        let recoveredAnchor = try XCTUnwrap(harness.clock.snapshot().anchors.last?.0)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(recoveredAnchor, recoveryFloor), 0)
        XCTAssertTrue(harness.renderer.snapshot().frames.allSatisfy { frame in
            CMTimeCompare(frame.presentationTimeStamp, recoveryFloor) >= 0
        })
    }

    private func makeHarness(
        requiredVideoFrames: Int = 1,
        classifierConfiguration: ScanClassifierConfiguration = ScanClassifierConfiguration(
            progressiveConfirmationFrames: 1,
            psfConfirmationFrames: 1,
            exitInterlacedConfirmationFrames: 1
        ),
        scanProbe: (any LumaScanProbing)? = nil,
        playbackAssemblerBuilder: (any PlaybackAssemblerBuilding)? = nil,
        metrics: PlaybackMetrics? = nil,
        audioDiagnostics: AudioRenderDiagnostics? = nil,
        useRealCompressedAudio: Bool = false,
        audioDiagnosticsNow: AudioRenderPipeline.DiagnosticsNow? = nil,
        automaticallyCompleteDecoderSubmissions: Bool = true,
        videoDecodeStallTimeout: DispatchTimeInterval = .seconds(1),
        pendingTrackAudioRetentionLimits: CompressedAudioRetentionLimits =
            CompressedAudioRetentionPolicy.pending,
        audioContinuityRetentionLimits: CompressedAudioRetentionLimits =
            CompressedAudioRetentionPolicy.continuity
    ) -> Harness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.pipeline")
        let demux = FakePipelineDemuxer()
        let assemblers = FakePlaybackAssemblerBuilder()
        let decoder = FakeVideoDecoder()
        let processor = FakePipelineVideoProcessor(requiredInputFrameCount: requiredVideoFrames)
        let yadifProcessor = FakePipelineYADIFProcessor()
        let renderer = FakePipelineVideoRenderer()
        let audio = FakePipelineAudio()
        let clock = FakePipelineClock()
        let display = FakePlaybackDisplay()
        let events = LockedPipelineEvents()
        let audioRelay = useRealCompressedAudio ? PipelineAudioRelay() : nil
        let compressedAudio: CompressedAudioPipelineHarness?
        let pipelineAudio: any AudioRenderPipelineProtocol
        if let audioRelay {
            let synchronizer = FakeAudioSynchronizer()
            let renderers = FakeAudioRendererFactory()
            let realAudio = AudioRenderPipeline(
                synchronizer: synchronizer,
                executor: executor,
                failureSink: { error, generation in
                    audioRelay.receive(failure: error, generation: generation)
                },
                rendererFactory: renderers,
                decoderFactory: FakePCMAudioDecoderFactory { _ in [] },
                routeMonitor: FakeAudioRouteMonitor(),
                decodeCapabilityChecker: FakeAudioFormatSupportChecker(),
                pcmOutputValidator: FakeAudioFormatSupportChecker(),
                diagnosticsNow: audioDiagnosticsNow
                    ?? { ProcessInfo.processInfo.systemUptime },
                clockMode: .externallyManaged,
                readinessSink: { change, generation in
                    audioRelay.receive(readiness: change, generation: generation)
                }
            )
            compressedAudio = CompressedAudioPipelineHarness(
                pipeline: realAudio,
                synchronizer: synchronizer,
                renderers: renderers
            )
            pipelineAudio = realAudio
        } else {
            compressedAudio = nil
            pipelineAudio = audioDiagnostics.map {
                DiagnosticsPipelineAudio(base: audio, diagnostics: $0)
            } ?? audio
        }
        let pipeline = PlaybackPipeline(
            executor: executor,
            demuxer: demux,
            assemblerBuilder: playbackAssemblerBuilder ?? assemblers,
            decoder: decoder,
            processor: processor,
            yadifProcessor: yadifProcessor,
            scanProbe: scanProbe,
            classifierConfiguration: classifierConfiguration,
            videoDecodeStallTimeout: videoDecodeStallTimeout,
            rawReadinessRequirementOverride: requiredVideoFrames,
            pendingTrackAudioRetentionLimits: pendingTrackAudioRetentionLimits,
            audioContinuityRetentionLimits: audioContinuityRetentionLimits,
            renderer: renderer,
            audio: pipelineAudio,
            clock: clock,
            display: display,
            eventSink: { events.append($0) },
            metrics: metrics
        )
        audioRelay?.install(pipeline)
        if automaticallyCompleteDecoderSubmissions {
            decoder.setSubmissionCompletionSink { [weak pipeline] accessUnitID, generation in
                // Production decoders publish completions asynchronously. Queue
                // the fake completion too so it cannot re-enter a FIFO drain
                // while that drain is still mutating the pending array.
                executor.submit { [weak pipeline] in
                    pipeline?.receive(decoder: .submissionCompleted(
                        accessUnitID: accessUnitID,
                        generation: generation
                    ))
                }
            }
        }
        return Harness(
            executor: executor,
            pipeline: pipeline,
            demux: demux,
            decoder: decoder,
            processor: processor,
            renderer: renderer,
            audio: audio,
            assemblers: assemblers,
            clock: clock,
            display: display,
            events: events,
            compressedAudio: compressedAudio
        )
    }

    private func makeRequest(title: String = "Channel") -> PlaybackRequest {
        PlaybackRequest(
            sourceProfileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            channelID: title,
            streamURL: URL(string: "https://example.test/live.ts")!,
            title: title
        )
    }

    private func makePendingAudioFrame(
        id: UInt64,
        payloadBytes: Int,
        pts: CMTime,
        duration: CMTime = CMTime(value: 1, timescale: 1),
        generation: MediaGeneration = MediaGeneration(rawValue: 0)
    ) -> CompressedAudioFrame {
        CompressedAudioFrame(
            id: id,
            payload: Data(repeating: UInt8(truncatingIfNeeded: id), count: payloadBytes),
            codec: .aac,
            generation: generation,
            presentationTimeStamp: pts,
            duration: duration,
            frameSampleCount: 1_024
        )
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition was not satisfied before timeout", file: file, line: line)
    }
}

private final class DiagnosticsPipelineAudio: AudioRenderPipelineProtocol, @unchecked Sendable {
    private let base: FakePipelineAudio
    let diagnostics: AudioRenderDiagnostics

    init(base: FakePipelineAudio, diagnostics: AudioRenderDiagnostics) {
        self.base = base
        self.diagnostics = diagnostics
    }

    var isReadyForPlayback: Bool { base.isReadyForPlayback }
    var route: AudioRoute { base.route }
    var recoveryCount: UInt64 { base.recoveryCount }

    func configure(
        _ configuration: CompressedAudioRenderConfiguration,
        generation: MediaGeneration
    ) throws {
        try base.configure(configuration, generation: generation)
    }

    func enqueue(_ sample: CompressedAudioSample) throws {
        try base.enqueue(sample)
    }

    func activateContinuityIsland(
        _ islandID: AudioContinuityIslandID,
        generation: MediaGeneration
    ) {
        base.activateContinuityIsland(islandID, generation: generation)
    }

    func updateRecoveryFloor(_ floor: CMTime?) {
        base.updateRecoveryFloor(floor)
    }

    func prepareAnchor(
        at commonPTS: CMTime,
        in islandID: AudioContinuityIslandID
    ) throws {
        try base.prepareAnchor(at: commonPTS, in: islandID)
    }

    func flush(to generation: MediaGeneration) {
        base.flush(to: generation)
    }

    func stop() {
        base.stop()
    }

    func stopAwaitingRendererRemoval() async {
        await base.stopAwaitingRendererRemoval()
    }
}

private struct Harness: @unchecked Sendable {
    let executor: PlaybackSerialExecutor
    let pipeline: PlaybackPipeline
    let demux: FakePipelineDemuxer
    let decoder: FakeVideoDecoder
    let processor: FakePipelineVideoProcessor
    let renderer: FakePipelineVideoRenderer
    let audio: FakePipelineAudio
    let assemblers: FakePlaybackAssemblerBuilder
    let clock: FakePipelineClock
    let display: FakePlaybackDisplay
    let events: LockedPipelineEvents
    let compressedAudio: CompressedAudioPipelineHarness?
}

private struct CompressedAudioPipelineHarness: @unchecked Sendable {
    let pipeline: AudioRenderPipeline
    let synchronizer: FakeAudioSynchronizer
    let renderers: FakeAudioRendererFactory
}

private final class PipelineAudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: PlaybackPipeline?

    func install(_ target: PlaybackPipeline) {
        lock.withLock { self.target = target }
    }

    func receive(readiness: AudioRenderReadinessChange, generation: MediaGeneration) {
        lock.withLock { target }?.receive(audioReadiness: readiness, generation: generation)
    }

    func receive(failure: PlaybackCoreError, generation: MediaGeneration) {
        lock.withLock { target }?.receive(failure: failure, generation: generation)
    }
}

private final class PipelineAudioDiagnosticsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(value: TimeInterval) {
        self.value = value
    }

    func set(_ value: TimeInterval) {
        lock.withLock { self.value = value }
    }

    func now() -> TimeInterval {
        lock.withLock { value }
    }
}

private final class LockedPipelineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlaybackPipelineEvent] = []
    func append(_ event: PlaybackPipelineEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [PlaybackPipelineEvent] { lock.withLock { events } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}

private final class InconclusivePipelineScanProbe: LumaScanProbing, @unchecked Sendable {
    func submit(
        current _: CVPixelBuffer,
        previous _: CVPixelBuffer,
        generation _: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) {
        completion(.success(ContentProbeSample(
            combRatio: 0.04,
            motionRatio: 0,
            sampleCount: 2_304
        )))
    }

    func stop(generation _: MediaGeneration) {}
}
