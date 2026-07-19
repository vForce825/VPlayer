// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
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
        fake.emit(.ready)
        let playing = await events.next()
        XCTAssertEqual(playing, .playing(request))

        await controller.setPaused(true)
        let paused = await events.next()
        XCTAssertEqual(paused, .paused(request))
        fake.emit(.ready)
        try await Task.sleep(for: .milliseconds(20))
        let stablePaused = await controller.currentStateForTesting
        XCTAssertEqual(stablePaused, .paused(request))
        await controller.setPaused(false)
        let resumePreparing = await events.next()
        XCTAssertEqual(resumePreparing, .preparing(request))
        fake.emit(.ready)
        let resumed = await events.next()
        XCTAssertEqual(resumed, .playing(request))

        await controller.stop()
        let stopped = await events.next()
        XCTAssertEqual(stopped, .stopped)
        XCTAssertEqual(fake.snapshot().pauses, [true, false])
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
        second.emit(.ready)
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
        fake.emit(.ready)
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
        let audioFingerprint = MediaFormatFingerprint(bytes: Data([1]))
        harness.pipeline.receive(audio: .format(try PlaybackFakeMedia.audioFormat(), .aac, audioFingerprint))
        let videoFingerprint = MediaFormatFingerprint(bytes: Data([2]))
        harness.pipeline.receive(video: .format(try PlaybackFakeMedia.videoFormat(), videoFingerprint))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == 2 }
        let generation = (await harness.pipeline.debugSnapshot()).generation
        XCTAssertEqual(harness.audio.snapshot().configured.map(\.1), [
            MediaGeneration(rawValue: 1),
            MediaGeneration(rawValue: 2),
        ])
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
        XCTAssertFalse(harness.events.snapshot().contains(.ready))

        harness.pipeline.receive(audio: .sample(try PlaybackFakeMedia.audioSample(
            id: 2,
            generation: generation,
            pts: CMTime(value: 249, timescale: 1_000),
            duration: CMTime(value: 1, timescale: 1_000)
        )))
        try await eventually { harness.events.snapshot().contains(.ready) }
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

        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([9]))
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
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([9]))
        ))
        try await Task.sleep(for: .milliseconds(20))
        let postDiscontinuityFormat = await harness.pipeline.debugSnapshot()
        XCTAssertEqual(postDiscontinuityFormat.generation, MediaGeneration(rawValue: generation.rawValue + 2))
    }

    func testChangedTracksAdvanceOnceWhenTheirCanonicalFingerprintArrives() async throws {
        let harness = makeHarness()
        let generation = try await configure(harness)

        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks(videoExtradata: Data([0x01]))))
        try await Task.sleep(for: .milliseconds(20))
        let preFingerprintGeneration = await harness.pipeline.debugSnapshot().generation
        XCTAssertEqual(preFingerprintGeneration, generation)

        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([0x0A]))
        ))
        try await eventually {
            (await harness.pipeline.debugSnapshot()).generation
                == MediaGeneration(rawValue: generation.rawValue + 1)
        }
    }

    func testReplacementDecoderAcceptsOnlyNextRandomAccessAndDropsOldCallback() async throws {
        let harness = makeHarness()
        let oldGeneration = try await configure(harness)
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(),
            MediaFormatFingerprint(bytes: Data([7]))
        ))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == oldGeneration.rawValue + 1 }
        let generation = (await harness.pipeline.debugSnapshot()).generation
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(id: 1, generation: generation, randomAccess: false)))
        harness.pipeline.receive(video: .accessUnit(try PlaybackFakeMedia.accessUnit(id: 2, generation: generation, randomAccess: true)))
        harness.pipeline.receive(decoder: .frame(try PlaybackFakeMedia.decodedFrame(id: 99, generation: oldGeneration, pts: .zero, interlaced: false)))

        try await eventually { harness.decoder.snapshot().contains(.decode(2, generation)) }
        XCTAssertFalse(harness.decoder.snapshot().contains(.decode(1, generation)))
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
        XCTAssertFalse(harness.events.snapshot().contains(.ready))

        harness.audio.setReady(true)
        harness.pipeline.refreshReadiness()
        try await eventually { harness.events.snapshot().contains(.ready) }
    }

    func testPauseKeepsBoundedPacketsAndBackpressuresUntilResume() async throws {
        let harness = makeHarness()
        _ = try await configure(harness)
        harness.pipeline.setPaused(true)
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

        harness.pipeline.setPaused(false)
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
        cancelled.pipeline.stop()
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

    func testOneHundredRandomizedOldCallbacksNeverReachPresentation() async throws {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for iteration in 0..<100 {
            let harness = makeHarness()
            let oldGeneration = try await configure(harness)
            harness.pipeline.receive(video: .format(
                try PlaybackFakeMedia.videoFormat(),
                MediaFormatFingerprint(bytes: Data([UInt8(iteration + 17)]))
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
            harness.pipeline.stop()
        }
    }

    private func configure(_ harness: Harness) async throws -> MediaGeneration {
        harness.pipeline.start(url: makeRequest().streamURL)
        try await eventually { harness.demux.snapshot().startedURLs.count == 1 }
        harness.demux.emit(.tracks(PlaybackFakeMedia.tracks()))
        try await eventually { (await harness.pipeline.debugSnapshot()).hasTracks }
        harness.pipeline.receive(audio: .format(
            try PlaybackFakeMedia.audioFormat(), .aac, MediaFormatFingerprint(bytes: Data([1]))
        ))
        harness.pipeline.receive(video: .format(
            try PlaybackFakeMedia.videoFormat(), MediaFormatFingerprint(bytes: Data([2]))
        ))
        try await eventually { (await harness.pipeline.debugSnapshot()).generation.rawValue == 2 }
        return (await harness.pipeline.debugSnapshot()).generation
    }

    private func makeHarness(requiredVideoFrames: Int = 1) -> Harness {
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
            assemblerBuilder: assemblers,
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
