// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class PlaybackPipelineTests: XCTestCase {
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

    func testAlgorithmSelectionIsRecordedWhileNoticesRemainSilent() async throws {
        let controller = PlaybackController(factory: FakeControllerPipelineFactory([]))
        await controller.setDeinterlaceAlgorithm(.metalYADIF2x)
        let algorithm = await controller.selectedDeinterlaceAlgorithmForTesting
        XCTAssertEqual(algorithm, .metalYADIF2x)

        let expectation = expectation(description: "phase-2 notices remain silent")
        expectation.isInverted = true
        let stream = await controller.notices()
        let task = Task {
            var iterator = stream.makeAsyncIterator()
            if await iterator.next() != nil { expectation.fulfill() }
        }
        await fulfillment(of: [expectation], timeout: 0.05)
        task.cancel()
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
        XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [MediaGeneration(rawValue: 1)])
        harness.audio.setReady(true)

        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
            id: 1, generation: generation, pts: .zero, duration: CMTime(value: 249, timescale: 1_000)
        )))
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 1, generation: generation, pts: .zero, interlaced: false
        )))
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 2, generation: generation, pts: CMTime(value: 1, timescale: 25), interlaced: false
        )))
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
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 1, generation: generation, pts: .zero, interlaced: false
        )))
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 2, generation: generation, pts: CMTime(value: 1, timescale: 25), interlaced: true
        )))

        try await eventually { harness.processor.snapshot().metadata.count == 2 }
        XCTAssertEqual(harness.processor.snapshot().metadata.map(\.isInterlaced), [false, true])
        XCTAssertEqual(harness.renderer.snapshot().frames.count, 2)
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
        let operations = harness.decoder.snapshot()
        XCTAssertTrue(operations.suffix(4).elementsEqual([
            .finish, .wait, .invalidate,
            .configure(MediaGeneration(rawValue: generation.rawValue + 1), .bothFields),
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
            XCTAssertEqual(harness.decoder.snapshot().filter {
                if case .configure = $0 { return true }
                return false
            }, [.configure(MediaGeneration(rawValue: 1), .bothFields)])
            XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [MediaGeneration(rawValue: 1)])
        }
    }

    func testRealSharedStateAssemblersDeliverPartialThenCompleteAndDropFirstSideMedia() async throws {
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
            if videoFirst {
                XCTAssertEqual(harness.audio.snapshot().samples.map(\.generation), [generation])
                XCTAssertFalse(harness.decoder.snapshot().contains {
                    if case .decode = $0 { return true }
                    return false
                })
                harness.demux.emit(.packet(PlaybackFakeMedia.videoPacket(marker: 1, pts: 93_000)))
            } else {
                XCTAssertTrue(harness.audio.snapshot().samples.isEmpty)
                harness.demux.emit(.packet(PlaybackFakeMedia.audioPacket(id: 2)))
            }
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
        XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [initial, afterVideo, afterAudio])
        XCTAssertEqual(harness.decoder.snapshot().filter {
            if case .configure = $0 { return true }
            return false
        }, [
            .configure(initial, .bothFields),
            .configure(afterVideo, .bothFields),
            .configure(afterAudio, .bothFields),
        ])
    }

    func testChangedTrackAndDiscontinuityEpochsDropMediaUntilBothFreshFormatsThenGateVideoOnRandomAccess() async throws {
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
            let operationsBeforeFirstFormatMedia = harness.decoder.snapshot()
            let audioSamplesBeforeFirstFormatMedia = harness.audio.snapshot().samples

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
            XCTAssertEqual(harness.decoder.snapshot(), operationsBeforeFirstFormatMedia)
            XCTAssertEqual(
                harness.audio.snapshot().samples.map(\.id),
                audioSamplesBeforeFirstFormatMedia.map(\.id)
            )

            harness.pipeline.receive(audio: .format(
                try PlaybackFakeMedia.audioFormat(),
                .aac,
                MediaFormatFingerprint(bytes: Data([0x32]))
            ))
            let expectedGeneration = MediaGeneration(rawValue: initial.rawValue + 1)
            try await eventually {
                (await harness.pipeline.debugSnapshot()).generation == expectedGeneration
                    && harness.audio.snapshot().configured.last?.1 == expectedGeneration
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
            XCTAssertFalse(harness.decoder.snapshot().contains {
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
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            interlaced: false
        )))
        try await eventually { harness.clock.snapshot().anchors.count == 1 }

        harness.processor.setAutomaticallyCompletes(false)
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 99,
            generation: generation,
            pts: CMTime(value: 1, timescale: 25),
            interlaced: false
        )))
        try await eventually { harness.processor.snapshot().metadata.count == 2 }
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
        let decodeFlags = harness.decoder.snapshot().compactMap { operation -> VTDecodeFrameFlags? in
            guard case let .decode(_, _, flags) = operation else { return nil }
            return flags
        }
        XCTAssertEqual(decodeFlags, [._EnableAsynchronousDecompression])
        XCTAssertFalse(harness.renderer.snapshot().frames.contains { $0.sourceAccessUnitID == 99 })
    }

    func testPCMRouteCannotOpenReadinessUntilPCMReportsReady() async throws {
        let harness = makeHarness()
        harness.audio.selectedRoute = .ffmpegPCM
        let generation = try await configure(harness)
        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
            id: 1, generation: generation, pts: .zero, duration: CMTime(value: 1, timescale: 4)
        )))
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 1, generation: generation, pts: .zero, interlaced: false
        )))
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
            harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
                id: 1,
                generation: generation,
                pts: videoPTS,
                interlaced: false
            )))

            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(harness.events.snapshot().contains(.ready(readinessCycle: 0)))
            XCTAssertTrue(harness.clock.snapshot().anchors.isEmpty)
            XCTAssertFalse(harness.display.snapshot().contains("resume"))
        }
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
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            interlaced: false
        )))

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
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            interlaced: false
        )))
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
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(
            id: 1,
            generation: generation,
            pts: .zero,
            interlaced: false
        )))
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
            var callbacks = [
                try PlaybackFakeMedia.decodedFrame(id: 1, generation: oldGeneration, pts: .zero, interlaced: false),
                try PlaybackFakeMedia.decodedFrame(id: 2, generation: current, pts: .zero, interlaced: false),
            ]
            callbacks.shuffle(using: &generator)
            for callback in callbacks { harness.pipeline.receive(decoder: .frame(callback)) }
            try await eventually { harness.renderer.snapshot().frames.contains { $0.generation == current } }
            XCTAssertFalse(harness.renderer.snapshot().frames.contains { $0.generation == oldGeneration })
            await harness.pipeline.stop()
        }
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
        return (await harness.pipeline.debugSnapshot()).generation
    }

    private func makeHarness(
        requiredVideoFrames: Int = 1,
        playbackAssemblerBuilder: (any PlaybackAssemblerBuilding)? = nil
    ) -> Harness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.pipeline")
        let demux = FakePipelineDemuxer()
        let assemblers = FakePlaybackAssemblerBuilder()
        let decoder = FakeVideoDecoder()
        let processor = FakePipelineVideoProcessor(requiredInputFrameCount: requiredVideoFrames)
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
            renderer: renderer,
            audio: audio,
            clock: clock,
            display: display,
            eventSink: { events.append($0) }
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
