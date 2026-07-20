// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import Metal
import XCTest
@testable import VPlayer
@testable import VPlayerPlayback

@MainActor
final class FullScreenPlayerViewModelTests: XCTestCase {
    func testStartSubscribesBeforeAlgorithmPlayAndPresentationLookup() async throws {
        let log = ViewModelOperationLog()
        let engine = ViewModelPlaybackEngine(log: log)
        let settings = makeSettings(algorithm: .metalYADIF2x)
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationProvider: {
                log.append("presentation")
                return nil
            },
            settings: settings
        )

        model.start()
        try await eventually { log.values.count >= 5 }

        XCTAssertEqual(Array(log.values.prefix(5)), [
            "events", "notices", "algorithm:metalYADIF2x", "play", "presentation",
        ])
    }

    func testPauseRetryAndStopExactlyOnce() async throws {
        let log = ViewModelOperationLog()
        let engine = ViewModelPlaybackEngine(log: log)
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationProvider: { nil },
            settings: makeSettings(algorithm: .appleTemporal)
        )
        model.start()
        try await eventually { await engine.playCount == 1 }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually { await engine.pauses == [true] }
        model.retry()
        try await eventually { await engine.playCount == 2 }
        await model.stop()
        await model.stop()

        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testRepeatedVisibleNoticeDoesNotRestartOrExtendThreeSecondTimer() async throws {
        let sleep = ViewModelSleepProbe()
        let engine = ViewModelPlaybackEngine(log: ViewModelOperationLog())
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationProvider: { nil },
            settings: makeSettings(algorithm: .appleTemporal),
            sleep: { try await sleep.sleep(for: $0) }
        )
        model.start()
        try await eventually { await engine.hasNoticeSubscriber }
        let notice = PlaybackNotice(
            id: "temporal-unavailable",
            message: "Apple 反交错不可用，可在设置中切换到 Metal YADIF 2x。",
            duration: .seconds(3),
            isFocusStealing: false
        )

        await engine.emit(notice: notice)
        try await eventually { model.visibleNotice == notice }
        await engine.emit(notice: notice)
        try await Task.sleep(for: .milliseconds(30))
        let durations = await sleep.durations
        XCTAssertEqual(durations, [.seconds(3)])

        await sleep.finish()
        try await eventually { model.visibleNotice == nil }
    }

    func testConcurrentStopsWaitForSuspendedStartupAndTheSameEngineStop() async throws {
        let eventsGate = ViewModelBlockingGate()
        let stopGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            eventsGate: eventsGate,
            stopGate: stopGate
        )
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationProvider: { nil },
            settings: makeSettings(algorithm: .appleTemporal)
        )
        let firstFinished = ViewModelFlag()
        let secondFinished = ViewModelFlag()

        model.start()
        try await eventually { eventsGate.hasEntered }
        let firstStop = Task {
            await model.stop()
            firstFinished.set()
        }
        let secondStop = Task {
            await model.stop()
            secondFinished.set()
        }
        await Task.yield()

        XCTAssertFalse(firstFinished.value)
        XCTAssertFalse(secondFinished.value)
        eventsGate.open()
        try await eventually { await stopGate.hasWaiter }
        XCTAssertFalse(firstFinished.value)
        XCTAssertFalse(secondFinished.value)

        await stopGate.open()
        await firstStop.value
        await secondStop.value
        let stopCount = await engine.stopCount
        let subscriberCount = await engine.subscriberCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(subscriberCount, 0)
    }

    func testStopDoesNotWaitForNonCooperativeProviderOrWriteBackItsLateContext() async throws {
        let providerGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let lateContext = PlaybackPresentationContext(
            renderer: ViewModelPresentationRenderer(),
            clock: ViewModelPresentationClock(),
            device: device
        )
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationProvider: {
                await providerGate.wait()
                return lateContext
            },
            settings: makeSettings(algorithm: .appleTemporal)
        )
        let stopFinished = ViewModelFlag()

        model.start()
        try await eventually { await providerGate.hasWaiter }
        let stop = Task {
            await model.stop()
            stopFinished.set()
        }
        try await eventually { stopFinished.value }

        XCTAssertTrue(stopFinished.value)
        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(model.presentationContext)

        await providerGate.open()
        await stop.value
        await Task { @MainActor in }.value
        XCTAssertNil(model.presentationContext)
        lateContext.teardown()
    }

    func testStaleProviderCompletionCannotTeardownCurrentRetryContext() async throws {
        let engine = ControlledViewModelPlaybackEngine()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let sharedContext = PlaybackPresentationContext(
            renderer: ViewModelPresentationRenderer(),
            clock: ViewModelPresentationClock(),
            device: device
        )
        let provider = ViewModelPresentationProviderSequence(context: sharedContext)
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationProvider: { await provider.next() },
            settings: makeSettings(algorithm: .appleTemporal)
        )

        model.start()
        try await eventually { provider.firstCallHasWaiter }
        model.retry()
        try await eventually {
            provider.callCount == 2 && model.presentationContext === sharedContext
        }
        let displayLink = sharedContext.makeMetalVideoView().displayLink
        XCTAssertNotNil(displayLink.delegate)

        provider.releaseFirstCall()
        await Task { @MainActor in }.value

        XCTAssertTrue(model.presentationContext === sharedContext)
        XCTAssertNotNil(displayLink.delegate)
        sharedContext.teardown()
    }

    func testStopWaitsForSuspendedRetryBeforeStoppingEngine() async throws {
        let retryGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedPlayCall: 2,
            playGate: retryGate
        )
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationProvider: { nil },
            settings: makeSettings(algorithm: .appleTemporal)
        )
        model.start()
        try await eventually { await engine.playCount == 1 }

        model.retry()
        try await eventually { await retryGate.hasWaiter }
        let stopFinished = ViewModelFlag()
        let stop = Task {
            await model.stop()
            stopFinished.set()
        }
        await Task.yield()

        XCTAssertFalse(stopFinished.value)
        await retryGate.open()
        await stop.value
        let operations = await engine.operations
        let playEnd = try XCTUnwrap(operations.firstIndex(of: "play:2:end"))
        let stopStart = try XCTUnwrap(operations.firstIndex(of: "stop:start"))
        XCTAssertLessThan(playEnd, stopStart)
        XCTAssertEqual(operations.last, "stop:end")
    }

    func testStopWaitsForSuspendedPauseBeforeStoppingEngine() async throws {
        let pauseGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(pauseGate: pauseGate)
        let request = makeRequest()
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationProvider: { nil },
            settings: makeSettings(algorithm: .appleTemporal)
        )
        model.start()
        try await eventually { await engine.subscriberCount == 2 }
        await engine.emit(state: .playing(request))
        try await eventually { model.state == .playing(request) }

        model.togglePause()
        try await eventually { await pauseGate.hasWaiter }
        let stopFinished = ViewModelFlag()
        let stop = Task {
            await model.stop()
            stopFinished.set()
        }
        await Task.yield()

        XCTAssertFalse(stopFinished.value)
        await pauseGate.open()
        await stop.value
        let operations = await engine.operations
        let pauseEnd = try XCTUnwrap(operations.firstIndex(of: "pause:true:end"))
        let stopStart = try XCTUnwrap(operations.firstIndex(of: "stop:start"))
        XCTAssertLessThan(pauseEnd, stopStart)
    }

    func testRapidAlgorithmSelectionAlwaysAppliesTheLatestSelectionLast() async throws {
        let firstAlgorithmGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedAlgorithmCall: 1,
            algorithmGate: firstAlgorithmGate
        )
        let settings = makeSettings(algorithm: .appleTemporal)
        let model = FullScreenPlayerViewModel(
            request: makeRequest(),
            engine: engine,
            presentationProvider: { nil },
            settings: settings
        )

        model.selectAlgorithm(.metalYADIF2x)
        try await eventually { await firstAlgorithmGate.hasWaiter }
        model.selectAlgorithm(.appleTemporal)
        await Task.yield()
        let algorithmsBeforeRelease = await engine.completedAlgorithms
        XCTAssertTrue(algorithmsBeforeRelease.isEmpty)
        await firstAlgorithmGate.open()
        try await eventually { await engine.completedAlgorithms.count == 2 }

        let algorithms = await engine.completedAlgorithms
        XCTAssertEqual(algorithms.last, .appleTemporal)
        XCTAssertEqual(settings.deinterlaceAlgorithm, .appleTemporal)
    }

    func testSettingsAlgorithmSelectionControllerSerializesRapidChanges() async throws {
        let firstAlgorithmGate = ViewModelAsyncGate()
        let engine = ControlledViewModelPlaybackEngine(
            suspendedAlgorithmCall: 1,
            algorithmGate: firstAlgorithmGate
        )
        let controller = PlaybackAlgorithmSelectionController(engine: engine)

        controller.select(.metalYADIF2x)
        try await eventually { await firstAlgorithmGate.hasWaiter }
        controller.select(.appleTemporal)
        await Task.yield()
        let algorithmsBeforeRelease = await engine.completedAlgorithms
        XCTAssertTrue(algorithmsBeforeRelease.isEmpty)

        await firstAlgorithmGate.open()
        try await eventually { await engine.completedAlgorithms.count == 2 }
        let algorithms = await engine.completedAlgorithms
        XCTAssertEqual(algorithms.last, .appleTemporal)
    }

    private func makeSettings(algorithm: DeinterlaceAlgorithm) -> PlaybackSettingsStore {
        let suite = "FullScreenPlayerViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.deinterlaceAlgorithm = algorithm
        return settings
    }

    private func makeRequest() -> PlaybackRequest {
        PlaybackRequest(
            sourceProfileID: UUID(),
            channelID: "fixture",
            streamURL: URL(string: "https://fixture.invalid/live")
                ?? URL(fileURLWithPath: "/fixture.invalid/live"),
            title: "Fixture"
        )
    }

    private func eventually(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not reached")
    }
}

private final class ViewModelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false
    var value: Bool { lock.withLock { storedValue } }
    func set() { lock.withLock { storedValue = true } }
}

private final class ViewModelPresentationProviderSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let context: PlaybackPresentationContext
    private var storedCallCount = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    init(context: PlaybackPresentationContext) {
        self.context = context
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    var firstCallHasWaiter: Bool {
        lock.withLock { firstCallContinuation != nil }
    }

    func next() async -> PlaybackPresentationContext {
        let call = lock.withLock {
            storedCallCount += 1
            return storedCallCount
        }
        if call == 1 {
            await withCheckedContinuation { continuation in
                lock.withLock { firstCallContinuation = continuation }
            }
        }
        return context
    }

    func releaseFirstCall() {
        let continuation = lock.withLock {
            let continuation = firstCallContinuation
            firstCallContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class ViewModelBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var isOpen = false

    var hasEntered: Bool {
        condition.withLock { entered }
    }

    func wait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }
}

private actor ViewModelAsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var waiterCount = 0
    var hasWaiter: Bool { waiterCount > 0 }

    func wait() async {
        waiterCount += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor ControlledViewModelPlaybackEngine: PlaybackEngine {
    private let eventsGate: ViewModelBlockingGate?
    private let stopGate: ViewModelAsyncGate?
    private let suspendedPlayCall: Int?
    private let playGate: ViewModelAsyncGate?
    private let suspendedAlgorithmCall: Int?
    private let algorithmGate: ViewModelAsyncGate?
    private let pauseGate: ViewModelAsyncGate?
    private var eventContinuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var noticeContinuations: [UUID: AsyncStream<PlaybackNotice>.Continuation] = [:]
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var completedAlgorithms: [DeinterlaceAlgorithm] = []
    private(set) var operations: [String] = []
    private var algorithmCallCount = 0

    var subscriberCount: Int { eventContinuations.count + noticeContinuations.count }

    init(
        eventsGate: ViewModelBlockingGate? = nil,
        stopGate: ViewModelAsyncGate? = nil,
        suspendedPlayCall: Int? = nil,
        playGate: ViewModelAsyncGate? = nil,
        suspendedAlgorithmCall: Int? = nil,
        algorithmGate: ViewModelAsyncGate? = nil,
        pauseGate: ViewModelAsyncGate? = nil
    ) {
        self.eventsGate = eventsGate
        self.stopGate = stopGate
        self.suspendedPlayCall = suspendedPlayCall
        self.playGate = playGate
        self.suspendedAlgorithmCall = suspendedAlgorithmCall
        self.algorithmGate = algorithmGate
        self.pauseGate = pauseGate
    }

    func events() -> AsyncStream<PlaybackState> {
        eventsGate?.wait()
        let id = UUID()
        let pair = AsyncStream.makeStream(of: PlaybackState.self)
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    func notices() -> AsyncStream<PlaybackNotice> {
        let id = UUID()
        let pair = AsyncStream.makeStream(of: PlaybackNotice.self)
        noticeContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNoticeContinuation(id) }
        }
        return pair.stream
    }

    func play(_ request: PlaybackRequest) async {
        _ = request
        playCount += 1
        let call = playCount
        operations.append("play:\(call):start")
        if suspendedPlayCall == call, let playGate { await playGate.wait() }
        operations.append("play:\(call):end")
    }

    func setPaused(_ paused: Bool) async {
        operations.append("pause:\(paused):start")
        if let pauseGate { await pauseGate.wait() }
        operations.append("pause:\(paused):end")
    }

    func emit(state: PlaybackState) {
        for continuation in eventContinuations.values { continuation.yield(state) }
    }

    func stop() async {
        stopCount += 1
        operations.append("stop:start")
        if let stopGate { await stopGate.wait() }
        operations.append("stop:end")
    }

    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm) async {
        algorithmCallCount += 1
        let call = algorithmCallCount
        if suspendedAlgorithmCall == call, let algorithmGate { await algorithmGate.wait() }
        completedAlgorithms.append(algorithm)
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func removeNoticeContinuation(_ id: UUID) {
        noticeContinuations[id] = nil
    }
}

private final class ViewModelPresentationClock: PlaybackClock {
    var currentTime: CMTime = .zero
    func mediaTime(forHostTime hostTime: CMTime) -> CMTime { hostTime }
    func pause() {}
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {}
}

private final class ViewModelPresentationRenderer: VideoRendering {
    func enqueue(_ frame: VideoPresentationFrame) {}
    func flush(to generation: MediaGeneration) {}
    func draw(targetMediaTime: CMTime, drawable: any CAMetalDrawable) -> VideoRenderDecision {
        VideoRenderDecision(
            action: .noFrame,
            sourceAccessUnitID: nil,
            sequenceNumber: nil,
            droppedFrameCount: 0
        )
    }
}

private final class ViewModelOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

private actor ViewModelPlaybackEngine: PlaybackEngine {
    private let log: ViewModelOperationLog
    private var stateContinuation: AsyncStream<PlaybackState>.Continuation?
    private var noticeContinuation: AsyncStream<PlaybackNotice>.Continuation?
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var pauses: [Bool] = []
    var hasNoticeSubscriber: Bool { noticeContinuation != nil }

    init(log: ViewModelOperationLog) {
        self.log = log
    }

    func events() -> AsyncStream<PlaybackState> {
        let pair = AsyncStream.makeStream(of: PlaybackState.self)
        stateContinuation = pair.continuation
        log.append("events")
        return pair.stream
    }

    func notices() -> AsyncStream<PlaybackNotice> {
        let pair = AsyncStream.makeStream(of: PlaybackNotice.self)
        noticeContinuation = pair.continuation
        log.append("notices")
        return pair.stream
    }

    func play(_ request: PlaybackRequest) async {
        playCount += 1
        log.append("play")
    }

    func setPaused(_ paused: Bool) async {
        pauses.append(paused)
    }

    func stop() async {
        stopCount += 1
        log.append("stop")
    }

    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm) async {
        log.append("algorithm:\(algorithm.rawValue)")
    }

    func emit(state: PlaybackState) {
        stateContinuation?.yield(state)
    }

    func emit(notice: PlaybackNotice) {
        noticeContinuation?.yield(notice)
    }
}

private actor ViewModelSleepProbe {
    private(set) var durations: [Duration] = []
    private var continuation: CheckedContinuation<Void, any Error>?

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
