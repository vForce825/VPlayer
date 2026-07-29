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
        harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioFormat(), .aac, fingerprint))
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

        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
            id: 1, generation: generation, pts: .zero, duration: CMTime(value: 249, timescale: 1_000)
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

        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
            id: 2,
            generation: generation,
            pts: CMTime(value: 249, timescale: 1_000),
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
            try PlaybackFakeMedia.audioFormat(), .aac, changedFingerprint
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

        harness.demux.emit(.discontinuity(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation == MediaGeneration(rawValue: generation.rawValue + 2) }
        XCTAssertEqual(harness.renderer.snapshot().flushes.last, MediaGeneration(rawValue: generation.rawValue + 2))
        XCTAssertEqual(harness.audio.snapshot().flushes.last, MediaGeneration(rawValue: generation.rawValue + 2))

        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), changedFingerprint
        ))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioFormat(), .aac, changedFingerprint
        ))
        try await Task.sleep(for: .milliseconds(20))
        let postDiscontinuityFormat = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(postDiscontinuityFormat.generation, MediaGeneration(rawValue: generation.rawValue + 2))
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
            try PlaybackFakeMedia.audioFormat(),
            .aac,
            fingerprint
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
                    try PlaybackFakeMedia.audioFormat(), .aac, partialFingerprint
                ))
            }
            try await Task.sleep(for: .milliseconds(20))
            let oneSidedGeneration = await harness.pipeline.debugSnapshot().generation
            XCTAssertEqual(oneSidedGeneration, MediaGeneration(rawValue: 0))
            XCTAssertTrue(harness.decoder.snapshot().isEmpty)
            XCTAssertTrue(harness.audio.snapshot().configured.isEmpty)

            if videoFirst {
                harness.pipeline.receive(audio: .format(
                    try PlaybackFakeMedia.audioFormat(), .aac, completeFingerprint
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
                    ? PlaybackFakeMedia.videoPacket(marker: 1)
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
                    : PlaybackFakeMedia.videoPacket(marker: 1)
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

    func testCorruptDemuxPacketsAreDroppedBeforeAssemblersAndCleanPacketsContinue() async throws {
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
                harness.assemblers.audio.packets.count == 1
        }
        XCTAssertEqual(harness.assemblers.video.packets.map(\.data), [Data([2])])
        XCTAssertEqual(harness.assemblers.audio.packets.count, 1)
        XCTAssertFalse(harness.assemblers.audio.packets[0].isCorrupt)
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
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
                id: UInt64(id),
                generation: MediaGeneration(rawValue: 0),
                pts: CMTime(value: CMTimeValue(id), timescale: 40),
                duration: CMTime(value: 1, timescale: 40)
            )))
        }
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioFormat(),
            .aac,
            MediaFormatFingerprint(bytes: Data([0x42]))
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
            try PlaybackFakeMedia.audioFormat(),
            .aac,
            MediaFormatFingerprint(bytes: Data([0x22]))
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
            harness.demux.emit(discontinuity ? .discontinuity(updatedTracks) : .tracks(updatedTracks))
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
                randomAccess: true
            )))
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
                try PlaybackFakeMedia.audioFormat(),
                .aac,
                MediaFormatFingerprint(bytes: Data([0x32]))
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
                randomAccess: false
            )))
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
                id: 32,
                generation: expectedGeneration,
                pts: CMTime(value: 1, timescale: 4),
                duration: CMTime(value: 1, timescale: 4)
            )))
            harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
                id: 33,
                generation: expectedGeneration,
                randomAccess: true
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
                harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioFormat(), .aac, fingerprint))
            }
            try await Task.sleep(for: .milliseconds(20))
            let oneSidedGeneration = await harness.pipeline.debugSnapshot().generation
            XCTAssertEqual(oneSidedGeneration, generation)
            XCTAssertEqual(harness.decoder.snapshot().count, decoderOperationCount)
            XCTAssertEqual(harness.audio.snapshot().configured.count, audioConfigurationCount)

            if videoFirst {
                harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioFormat(), .aac, fingerprint))
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
            harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioFormat(), .aac, fingerprint))
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
            try PlaybackFakeMedia.audioFormat(), .aac, replacementFingerprint
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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

    func testSkewedAndNonOverlappingMediaNeverOpenReadiness() async throws {
        for videoPTS in [CMTime(value: 1, timescale: 1), CMTime(value: 1, timescale: 5)] {
            let harness = makeHarness()
            let generation = try await configure(harness)
            harness.audio.setReady(true)
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
                id: 1,
                generation: generation,
                pts: .zero,
                duration: CMTime(value: 1, timescale: 4)
            )))
            try receiveAndReleaseNormalizedFrames([
                PlaybackFakeMedia.decodedFrame(
                    id: 1,
                    generation: generation,
                    pts: videoPTS,
                    interlaced: false
                ),
            ], in: harness)

            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
            XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)
            XCTAssertFalse(harness.display.snapshot().contains("resume"))
        }
    }

    func testClosedReadinessPreservesEarliestBoundedVideoWindowUntilLaggingAudioCatchesUp() async throws {
        let metrics = PlaybackMetrics(
            channelID: "video-lead",
            now: { 1 },
            residentMemoryProvider: { 1 }
        )
        let harness = makeHarness(metrics: metrics)
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
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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

        let audioDuration = CMTime(value: 1, timescale: 40)
        for index in 0..<128 {
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }
        try await eventually {
            metrics.snapshot(window: .seconds(60)).retainedAudioCount
                == PlaybackPipeline.retainedAudioCapacity
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

    func testAudioTimestampRoundingDoesNotBreakStartupContinuity() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)

        // MPEG-TS timestamps use a 90 kHz clock while AAC duration is exact at
        // 44.1 kHz. Rounding 1,024 samples to 2,090 transport ticks leaves a
        // harmless ~2 microsecond gap between some adjacent packets.
        let audioDuration = CMTime(value: 1_024, timescale: 44_100)
        for index in 0..<12 {
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        let advancedRecoveryPTS = CMTime(value: 25, timescale: 4)
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
            pts: advancedRecoveryPTS
        )))
        harness.audio.setReady(false)
        harness.pipeline.receive(audioReadiness: .invalidated, generation: generation)

        for index in 20..<420 {
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
                id: UInt64(index + 1),
                generation: generation,
                pts: CMTime(value: Int64(index), timescale: 40),
                duration: audioDuration
            )))
        }
        try await eventually {
            harness.decoder.snapshot().contains {
                if case let .decode(id, decodedGeneration, _) = $0 {
                    return id == 200 && decodedGeneration == generation
                }
                return false
            }
        }

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 200,
                generation: generation,
                pts: advancedRecoveryPTS,
                interlaced: false
            ),
        ], in: harness)
        try await eventually {
            harness.events.snapshot().filter { $0 == .ready(readinessCycle: 0) }.count == 2
        }
        XCTAssertEqual(harness.display.snapshot().last, "resume")
    }

    func testClosedReadinessPreservesDeferredHeadWhenBacklogIsFull() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        let audioDuration = CMTime(value: 1, timescale: 40)

        for index in 0..<20 {
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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

        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        harness.clock.setTime(CMTime(value: 7, timescale: 10))
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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

        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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

    func testAudioAnchorReenqueueFailureVetoesReadyRateAndDisplayResume() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
            id: 1,
            generation: generation,
            pts: .zero,
            duration: CMTime(value: 1, timescale: 4)
        )))
        try await eventually { harness.audio.snapshot().samples.count == 1 }
        harness.audio.enqueueError = .audioRendererFailed("anchor.reenqueue")
        try receiveAndReleaseNormalizedFrames([
            PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: .zero,
                interlaced: false
            ),
        ], in: harness)

        try await eventually {
            harness.events.snapshot().contains(.failed(.audioRendererFailed("anchor.reenqueue")))
        }
        XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
        XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)
        XCTAssertFalse(harness.display.snapshot().contains("resume"))
        let snapshot = await harness.pipeline.debugSnapshot()
        XCTAssertTrue(snapshot.isTerminal)
    }

    func testExternalAudioAnchorFlushWaitsForReadinessWithoutRefushingForever() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        let initialFlushCount = harness.audio.snapshot().flushes.count
        harness.audio.setFlushHandler { [audio = harness.audio, pipeline = harness.pipeline] generation in
            audio.setReady(false)
            pipeline.receive(audioReadiness: .invalidated, generation: generation)
        }
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        try await eventually { harness.audio.snapshot().flushes.count == initialFlushCount + 1 }
        XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)

        harness.audio.setReady(true)
        harness.pipeline.receive(audioReadiness: .available, generation: generation)

        try await eventually {
            harness.events.snapshot().contains(.ready(readinessCycle: 0))
        }
        XCTAssertEqual(harness.audio.snapshot().flushes.count, initialFlushCount + 1)
        XCTAssertEqual(harness.clock.snapshot().anchors.count, 1)
    }

    func testExternalAudioInvalidationClosesAndReopensTheSoleReadinessGate() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)
        harness.audio.setReady(true)
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
                try PlaybackFakeMedia.audioFormat(), .aac, replacementFingerprint
            ))
            try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue > oldGeneration.rawValue }
            let current = (await harness.pipeline.debugSnapshot()).generation
            harness.audio.setReady(true)
            harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
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

    private func configure(_ harness: Harness) async throws -> MediaGeneration {
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        let fingerprint = MediaFormatFingerprint(bytes: Data([1]))
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioFormat(), .aac, fingerprint
        ))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), fingerprint
        ))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == 1 }
        let generation = await harness.pipeline.debugSnapshot().generation
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(
            id: 0,
            generation: generation,
            randomAccess: true
        )))
        try await eventually {
            harness.decoder.snapshot().contains(.configure(generation))
        }
        return generation
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

    private func makeHarness(
        requiredVideoFrames: Int = 1,
        playbackAssemblerBuilder: (any PlaybackAssemblerBuilding)? = nil,
        metrics: PlaybackMetrics? = nil
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
        let pipeline = PlaybackPipeline(
            executor: executor,
            demuxer: demux,
            assemblerBuilder: playbackAssemblerBuilder ?? assemblers,
            decoder: decoder,
            processor: processor,
            yadifProcessor: yadifProcessor,
            rawReadinessRequirementOverride: requiredVideoFrames,
            renderer: renderer,
            audio: audio,
            clock: clock,
            display: display,
            eventSink: { events.append($0) },
            metrics: metrics
        )
        return Harness(
            pipeline: pipeline,
            demux: demux,
            decoder: decoder,
            processor: processor,
            renderer: renderer,
            audio: audio,
            assemblers: assemblers,
            clock: clock,
            display: display,
            events: events
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

    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition was not satisfied before timeout")
    }
}

private struct Harness: @unchecked Sendable {
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
