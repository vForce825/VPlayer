// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import NowPlaying
import XCTest
@testable import VPlayerCore
import VPlayerPlayback
@testable import VPlayer

@MainActor
final class NowPlayingIntegrationTests: XCTestCase {
    func testLiveMetadataAndOnlySupportedTransportCommands() throws {
        let coordinator = PlaybackNowPlayingCoordinator { _ in TestNowPlayingSession() }
        let target = TestNowPlayingTarget()
        let request = request("Channel")
        let token = coordinator.begin(owner: target, presentation: .init(
            request: request,
            logoURL: nil,
            programmes: [.init(id: "show", xmltvChannelID: "guide", start: .distantPast,
                               stop: .distantFuture, title: "Current programme",
                               subtitle: nil, summary: nil, categories: [])]
        ))
        coordinator.update(.playing(request), owner: token)
        let model = try XCTUnwrap(coordinator.current)
        let content = try XCTUnwrap(model.content as? GenericContent)
        XCTAssertEqual(content.title, "Current programme")
        XCTAssertEqual(content.subtitle, "Channel")
        guard case .live? = content.duration else { return XCTFail("Live streams must not advertise a finite seek window") }
        XCTAssertEqual(model.commands.count, 3, "Live playback supports play, pause and stop, not seek/skip")
        XCTAssertEqual(model.playbackSnapshot, MediaPlaybackSnapshot(state: .playing(rate: 1)))
    }

    func testReplacedOwnerCannotPublishStopOrHandleSavedCommands() async throws {
        let coordinator = PlaybackNowPlayingCoordinator { _ in TestNowPlayingSession() }
        let first = TestNowPlayingTarget()
        let second = TestNowPlayingTarget()
        let firstToken = coordinator.begin(owner: first, presentation: presentation("First"))
        let obsolete = try XCTUnwrap(coordinator.current)
        let secondPresentation = presentation("Second")
        let secondToken = coordinator.begin(owner: second, presentation: secondPresentation)
        coordinator.update(.playing(secondPresentation.request), owner: secondToken)
        coordinator.update(.stopped, owner: firstToken)
        coordinator.end(owner: firstToken)
        await obsolete.setPaused(true)
        await obsolete.stop()
        XCTAssertTrue(first.pauseCommands.isEmpty)
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertNotNil(coordinator.current)
        XCTAssertEqual((coordinator.current?.content as? GenericContent)?.title, "Second")
        await coordinator.current?.setPaused(true)
        XCTAssertEqual(second.pauseCommands, [true])
        coordinator.end(owner: secondToken)
        XCTAssertNil(coordinator.current)
        XCTAssertNil(obsolete.content)
        XCTAssertTrue(obsolete.commands.isEmpty)
    }

    func testSessionDoesNotRetainPlaybackOwner() async {
        let coordinator = PlaybackNowPlayingCoordinator { _ in TestNowPlayingSession() }
        var target: TestNowPlayingTarget? = TestNowPlayingTarget()
        let weakTarget = WeakNowPlayingTargetProbe(target)
        _ = coordinator.begin(owner: target!, presentation: presentation("Channel"))
        XCTAssertNotNil(weakTarget.value)
        target = nil
        XCTAssertNil(weakTarget.value)
        await coordinator.current?.setPaused(true)
    }

    func testFullScreenOwnerPublishesStateAndUsesOrderedPauseLane() async throws {
        let coordinator = PlaybackNowPlayingCoordinator { _ in TestNowPlayingSession() }
        let engine = TestNowPlayingEngine()
        let request = request("Channel")
        let model = FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationStreamProvider: { AsyncStream { $0.finish() } },
            presentationMount: DefaultPlaybackPresentationMount(),
            settings: PlaybackSettingsStore(),
            nowPlaying: coordinator
        )
        model.start()
        try await eventually { coordinator.current?.playbackSnapshot == MediaPlaybackSnapshot(state: .playing(rate: 1)) }
        await coordinator.current?.setPaused(true)
        await coordinator.current?.setPaused(true)
        let commands = await engine.pauseCommands
        XCTAssertEqual(commands, [true], "Repeated remote pause must not toggle or duplicate the pending intent")
        try await eventually { model.isPaused }
        await model.stop()
        XCTAssertNil(coordinator.current)
    }

    func testReducedResourcePreferencePreservesCachedChannelPlaybackAndCurrentOwnerTransport() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = SourceProfile(
            id: UUID(), name: "Cached source",
            m3uURL: URL(string: "https://example.invalid/list.m3u")!,
            epgURL: URL(string: "https://example.invalid/guide.xml")!,
            m3uRefreshInterval: .hourly, epgRefreshInterval: .hourly,
            m3uStatus: ResourceRefreshStatus(), epgStatus: ResourceRefreshStatus(),
            createdAt: now, updatedAt: now
        )
        let channel = Channel(
            sourceProfileID: profile.id, displayName: "Cached channel",
            streamURL: URL(string: "https://example.invalid/live")!,
            tvgID: nil, tvgName: nil, logoURL: nil, groupTitle: nil, attributes: [:], order: 0
        )
        let automaticWork = expectation(description: "Playback must not admit deferred automatic refresh")
        automaticWork.isInverted = true
        let sleeping = expectation(description: "Reduced automatic loop reached sleep")
        let refresh: AppModel.Refresh = { _, _, _ in automaticWork.fulfill(); return [] }
        let engine = TestNowPlayingEngine()
        let dependencies = AppDependencies(
            libraryStartup: LibraryStartup {},
            foregroundRefreshDriver: ForegroundRefreshDriver(
                loadProfiles: { automaticWork.fulfill(); return [profile] },
                refresh: refresh,
                now: { now },
                sleep: { sleeping.fulfill(); try await Task.sleep(for: .seconds(3_600)) },
                reportStatus: { _ in XCTFail("Automatic refresh should remain deferred") }
            ),
            backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                scheduler: NowPlayingBackgroundSchedulerStub(),
                loadProfiles: { [profile] }, refresh: refresh, now: { now },
                reportStatus: { _ in XCTFail("No background refresh error is expected") }
            ),
            repository: RepositorySpy(profiles: [profile], channels: [profile.id: [channel]]),
            refresh: refresh,
            playbackEngine: engine
        )
        dependencies.foregroundRefreshDriver.setPrefersReducedResourceUsage(true)
        dependencies.backgroundRefreshRegistrar.setPrefersReducedResourceUsage(true)
        dependencies.foregroundRefreshDriver.activate()
        defer { dependencies.foregroundRefreshDriver.deactivate() }
        let appModel = AppModel(repository: dependencies.repository, refresh: dependencies.refresh, now: { now })
        let opened = await dependencies.openInitialLibrary(using: appModel)
        XCTAssertTrue(opened)
        await fulfillment(of: [sleeping], timeout: 2)
        appModel.select(channel: channel)
        let request = try XCTUnwrap(appModel.presentedPlaybackRequest)
        XCTAssertEqual(request.channelID, channel.id)
        XCTAssertEqual(request.sourceProfileID, profile.id)
        XCTAssertEqual(request.streamURL, channel.streamURL)

        let coordinator = PlaybackNowPlayingCoordinator { _ in TestNowPlayingSession() }
        let model = FullScreenPlayerViewModel(
            request: request, engine: dependencies.playbackEngine,
            presentationStreamProvider: { AsyncStream { $0.finish() } },
            presentationMount: DefaultPlaybackPresentationMount(),
            settings: dependencies.playbackSettings, nowPlaying: coordinator
        )
        model.start()
        try await eventually { model.state == .playing(request) }
        let currentOwner = try XCTUnwrap(coordinator.current)
        await currentOwner.setPaused(true)
        try await eventually { model.state == .paused(request) }
        await currentOwner.setPaused(false)
        try await eventually { model.state == .playing(request) }
        await currentOwner.stop()
        XCTAssertNil(coordinator.current)
        let plays = await engine.playRequests
        let pauseCommands = await engine.pauseCommands
        let stops = await engine.stopCount
        XCTAssertEqual(plays, [request])
        XCTAssertEqual(pauseCommands, [true, false])
        XCTAssertEqual(stops, 1)
        await fulfillment(of: [automaticWork], timeout: 0.05)
    }

    func testOldFullScreenStopCannotStopReplacementOnSharedEngine() async throws {
        let coordinator = PlaybackNowPlayingCoordinator { _ in TestNowPlayingSession() }
        let engine = TestNowPlayingEngine()
        func model(_ title: String) -> FullScreenPlayerViewModel {
            FullScreenPlayerViewModel(
                request: request(title), engine: engine,
                presentationStreamProvider: { AsyncStream { $0.finish() } },
                presentationMount: DefaultPlaybackPresentationMount(),
                settings: PlaybackSettingsStore(), nowPlaying: coordinator
            )
        }
        let first = model("First")
        first.start()
        try await eventually { first.state == .playing(first.request) }
        let second = model("Second")
        second.start()
        try await eventually { second.state == .playing(second.request) }
        await first.stop()
        let obsoleteStops = await engine.stopCount
        XCTAssertEqual(obsoleteStops, 0)
        XCTAssertEqual((coordinator.current?.content as? GenericContent)?.title, "Second")
        await coordinator.current?.stop()
        let currentStops = await engine.stopCount
        XCTAssertEqual(currentStops, 1)
        XCTAssertNil(coordinator.current)
    }

    func testLatePrimaryCompletionSettlesNewestOwnerInOrder() async throws {
        let firstSession = SuspendedNowPlayingSession()
        let secondSession = TestNowPlayingSession()
        var created = 0
        let coordinator = PlaybackNowPlayingCoordinator { _ in
            created += 1
            if created == 1 { return firstSession }
            return secondSession
        }
        let first = TestNowPlayingTarget()
        let firstPresentation = presentation("First")
        let firstToken = coordinator.begin(owner: first, presentation: firstPresentation)
        coordinator.update(.playing(firstPresentation.request), owner: firstToken)
        try await eventually { firstSession.hasStarted }
        let second = TestNowPlayingTarget()
        let secondPresentation = presentation("Second")
        let secondToken = coordinator.begin(owner: second, presentation: secondPresentation)
        coordinator.update(.playing(secondPresentation.request), owner: secondToken)
        XCTAssertEqual(secondSession.requestCount, 0)
        firstSession.complete()
        try await eventually { secondSession.requestCount == 1 }
        coordinator.end(owner: firstToken)
        XCTAssertEqual((coordinator.current?.content as? GenericContent)?.title, "Second")
        coordinator.end(owner: secondToken)
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not reached")
    }

    private func presentation(_ title: String) -> PlayerChannelPresentation {
        .init(request: request(title), logoURL: nil, programmes: [])
    }

    private func request(_ title: String) -> PlaybackRequest {
        .init(sourceProfileID: UUID(), channelID: title,
              streamURL: URL(string: "https://example.invalid/live")!, title: title)
    }
}

@MainActor
private final class WeakNowPlayingTargetProbe {
    weak var value: TestNowPlayingTarget?

    init(_ value: TestNowPlayingTarget?) {
        self.value = value
    }
}

@MainActor
private final class TestNowPlayingTarget: NowPlayingPlaybackTarget {
    var pauseCommands: [Bool] = []
    var stopCount = 0
    func stopFromNowPlaying() async { stopCount += 1 }
    func setPausedFromNowPlaying(_ paused: Bool) async { pauseCommands.append(paused) }
}

@MainActor
private final class TestNowPlayingSession: NowPlayingSessionPublishing {
    private(set) var requestCount = 0
    func requestPrimary() async throws { requestCount += 1 }
}

@MainActor
private final class SuspendedNowPlayingSession: NowPlayingSessionPublishing {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    func requestPrimary() async throws {
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
    }
    func complete() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class NowPlayingBackgroundSchedulerStub: BackgroundRefreshScheduling {
    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool { true }
    func cancel(identifier: String) { XCTFail("Playback must not cancel background scheduling") }
    func submit(identifier: String, earliestBeginDate: Date) async throws {
        XCTFail("Playback must not submit background refresh")
    }
}

private actor TestNowPlayingEngine: PlaybackEngine {
    private(set) var playRequests: [PlaybackRequest] = []
    private var continuations: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
    private var state: PlaybackState = .idle
    private var request: PlaybackRequest?
    private(set) var pauseCommands: [Bool] = []
    private(set) var stopCount = 0
    func events() -> AsyncStream<PlaybackState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.remove(id) }
        }
        continuation.yield(state)
        return stream
    }
    private func remove(_ id: UUID) { continuations[id] = nil }
    private func emit(_ state: PlaybackState) {
        self.state = state
        for continuation in continuations.values { continuation.yield(state) }
    }
    func play(_ request: PlaybackRequest) async {
        playRequests.append(request)
        self.request = request
        emit(.preparing(request))
        emit(.playing(request))
    }
    func setPaused(_ paused: Bool) async {
        pauseCommands.append(paused)
        if let request { emit(paused ? .paused(request) : .playing(request)) }
    }
    func stop() async { stopCount += 1; emit(.stopped) }
}
