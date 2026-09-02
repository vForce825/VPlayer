// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import XCTest
import UIKit
@testable import VPlayer
@testable import VPlayerCore
import VPlayerPlayback

private enum LiveRuntimeLoadTaskContext {
    @TaskLocal static var inheritedMarker = false
}

@MainActor
final class VPlayerAppStartupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testChannelLogoCacheUsesWritableCachesDirectory() throws {
        let fileManager = FileManager.default
        let cachesRoot = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = try ChannelLogoCache.defaultCacheDirectory(fileManager: fileManager)
        _ = ChannelLogoCache(fileManager: fileManager, cacheDirectory: directory)

        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "VPlayer")
        XCTAssertEqual(directory.lastPathComponent, "ChannelLogos")
        XCTAssertTrue(directory.path.hasPrefix(cachesRoot.path + "/"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testChannelLogoCachePersistsDownloadedImageAndAvoidsSecondRequest() async throws {
        let cacheDirectory = temporaryLogoCacheDirectory()
        let downloadsDirectory = temporaryLogoDownloadsDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        defer { try? FileManager.default.removeItem(at: downloadsDirectory) }
        let dataLoader = logoDataLoader(downloadsDirectory: downloadsDirectory)
        let logoURL = try XCTUnwrap(URL(string: "https://images.example/oriental-4k.png"))
        StubURLProtocol.enqueue(.init(
            response: .http(statusCode: 200, headers: ["Content-Type": "image/png"]),
            chunks: [Self.onePixelPNG]
        ))

        let firstCache = ChannelLogoCache(
            dataLoader: dataLoader,
            cacheDirectory: cacheDirectory
        )
        let downloadedImage = await firstCache.image(for: logoURL)
        let memoryCachedImage = await firstCache.image(for: logoURL)
        XCTAssertNotNil(downloadedImage)
        XCTAssertNotNil(memoryCachedImage)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        let relaunchedCache = ChannelLogoCache(
            dataLoader: dataLoader,
            cacheDirectory: cacheDirectory
        )
        let diskCachedImage = await relaunchedCache.image(for: logoURL)
        XCTAssertNotNil(diskCachedImage)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).count,
            1
        )
    }

    func testChannelLogoCacheCoalescesConcurrentRequestsForSameURL() async throws {
        let cacheDirectory = temporaryLogoCacheDirectory()
        let downloadsDirectory = temporaryLogoDownloadsDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        defer { try? FileManager.default.removeItem(at: downloadsDirectory) }
        let logoURL = try XCTUnwrap(URL(string: "https://images.example/shared.png"))
        StubURLProtocol.enqueue(.init(
            response: .http(statusCode: 200),
            chunks: [Self.onePixelPNG],
            callbackDelay: 0.02
        ))
        let cache = ChannelLogoCache(
            dataLoader: logoDataLoader(downloadsDirectory: downloadsDirectory),
            cacheDirectory: cacheDirectory
        )

        let first = Task { await cache.image(for: logoURL) }
        let second = Task { await cache.image(for: logoURL) }
        let firstImage = await first.value
        let secondImage = await second.value
        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testChannelLogoCacheRejectsDeclaredLengthAndCancelsBeforeRemainingBody() async throws {
        let cacheDirectory = temporaryLogoCacheDirectory()
        let downloadsDirectory = temporaryLogoDownloadsDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        defer { try? FileManager.default.removeItem(at: downloadsDirectory) }
        let logoURL = try XCTUnwrap(URL(string: "https://images.example/declared-too-large.png"))
        let limit = 8 * 1_024 * 1_024
        let plannedChunkCount = 3
        StubURLProtocol.enqueue(.init(
            response: .http(
                statusCode: 200,
                headers: ["Content-Length": "\(limit + 1)"]
            ),
            chunks: Array(
                repeating: Data(repeating: 0x41, count: limit / 2),
                count: plannedChunkCount
            ),
            callbackDelay: 0.02
        ))
        let cache = ChannelLogoCache(
            dataLoader: logoDataLoader(downloadsDirectory: downloadsDirectory),
            cacheDirectory: cacheDirectory
        )

        let image = await cache.image(for: logoURL)
        await waitForLogoProtocolCancellation()

        XCTAssertNil(image)
        XCTAssertEqual(StubURLProtocol.deliveredChunkCount, 1)
        XCTAssertGreaterThanOrEqual(StubURLProtocol.stopLoadingCount, 1)
    }

    func testChannelLogoCacheCancelsChunkedTransferAtFirstOverflowChunk() async throws {
        let cacheDirectory = temporaryLogoCacheDirectory()
        let downloadsDirectory = temporaryLogoDownloadsDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        defer { try? FileManager.default.removeItem(at: downloadsDirectory) }
        let logoURL = try XCTUnwrap(URL(string: "https://images.example/chunked-too-large.png"))
        let limit = 8 * 1_024 * 1_024
        StubURLProtocol.enqueue(.init(
            chunks: [
                Data(repeating: 0x41, count: limit),
                Data([0x42]),
                Data("must-not-be-delivered".utf8),
            ],
            callbackDelay: 0.02
        ))
        let cache = ChannelLogoCache(
            dataLoader: logoDataLoader(downloadsDirectory: downloadsDirectory),
            cacheDirectory: cacheDirectory
        )

        let image = await cache.image(for: logoURL)
        await waitForLogoProtocolCancellation()

        XCTAssertNil(image)
        XCTAssertEqual(StubURLProtocol.deliveredChunkCount, 2)
        XCTAssertGreaterThanOrEqual(StubURLProtocol.stopLoadingCount, 1)
    }

    func testChannelLogoCacheDecodesAwayFromMainThreadWhenCalledOnMainActor() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let cacheDirectory = temporaryLogoCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let logoURL = try XCTUnwrap(URL(string: "https://images.example/thread-probe.png"))
        let probe = ChannelLogoDecoderThreadProbe()
        let cache = ChannelLogoCache(
            dataLoader: FixedChannelLogoDataLoader(data: Self.onePixelPNG),
            imageDecoder: ThreadRecordingChannelLogoDecoder(probe: probe),
            cacheDirectory: cacheDirectory
        )

        let image = await cache.image(for: logoURL)

        XCTAssertNotNil(image)
        XCTAssertEqual(probe.threadValues, [false])
    }

    func testChannelLogoCacheDoesNotPersistMalformedDownloadedBytes() async throws {
        let cacheDirectory = temporaryLogoCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let logoURL = try XCTUnwrap(URL(string: "https://images.example/malformed.png"))
        let malformed = Data("not-an-image".utf8)
        let cache = ChannelLogoCache(
            dataLoader: FixedChannelLogoDataLoader(data: malformed),
            cacheDirectory: cacheDirectory
        )

        let image = await cache.image(for: logoURL)

        XCTAssertNil(image)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path),
            []
        )

        let relaunchedCache = ChannelLogoCache(
            dataLoader: NilChannelLogoDataLoader(),
            cacheDirectory: cacheDirectory
        )
        let relaunchedImage = await relaunchedCache.image(for: logoURL)

        XCTAssertNil(relaunchedImage)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path),
            []
        )
    }

    func testChannelLogoCacheEvictsMalformedDiskEntryBeforeFallbackCompletes() async throws {
        let cacheDirectory = temporaryLogoCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let logoURL = try XCTUnwrap(URL(string: "https://images.example/corrupt-disk.png"))
        let diskKey = SHA256.hash(data: Data(logoURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let corruptEntryURL = cacheDirectory.appendingPathComponent(diskKey)
        try Data("not-an-image".utf8).write(to: corruptEntryURL)
        let cache = ChannelLogoCache(
            dataLoader: NilChannelLogoDataLoader(),
            cacheDirectory: cacheDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptEntryURL.path))

        let image = await cache.image(for: logoURL)

        XCTAssertNil(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptEntryURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path),
            []
        )
    }

    func testLaunchArgumentsSelectOnlyTheExactSeededFixturePair() {
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: ["VPlayer", "-ui-fixture", "seeded"]).mode,
            .seededFixture
        )
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: ["VPlayer", "-ui-testing"]).mode,
            .live
        )
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: ["VPlayer", "-ui-fixture"]).mode,
            .live
        )
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: ["VPlayer", "-ui-fixture", "unknown"]).mode,
            .live
        )
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: [
                "VPlayer", "-ui-fixture", "unknown", "-ui-fixture", "seeded",
            ]).mode,
            .live
        )
        XCTAssertTrue(
            AppLaunchConfiguration(arguments: ["VPlayer", "-uiTestResetPlaybackSettings"])
                .resetsPlaybackSettings
        )
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: [
                "VPlayer", "-ui-fixture", "seeded",
                "-ui-playback-fixture", "failed-diagnostic",
            ]).playbackFixture,
            "failed-diagnostic"
        )
        XCTAssertNil(AppLaunchConfiguration(arguments: [
            "VPlayer", "-ui-playback-fixture",
        ]).playbackFixture)
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private func temporaryLogoCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VPlayerLogoCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryLogoDownloadsDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VPlayerLogoDownloads-\(UUID().uuidString)", isDirectory: true)
    }

    private func logoDataLoader(downloadsDirectory: URL) -> LiveChannelLogoDataLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LiveChannelLogoDataLoader(
            downloader: URLSessionBoundedDownloader(
                configuration: configuration,
                downloadsDirectory: downloadsDirectory
            ),
            fileManager: .default
        )
    }

    private func waitForLogoProtocolCancellation() async {
        let deadline = Date().addingTimeInterval(2)
        while StubURLProtocol.stopLoadingCount == 0, Date() < deadline {
            await Task.yield()
        }
    }

    func testAcceptanceLaunchIsExactDebugOnlyAndNeverSelectsTheFixtureEngine() {
        let acceptance = AppLaunchConfiguration(arguments: [
            "VPlayer", "-acceptance-playback",
        ])
        #if DEBUG
        XCTAssertNotEqual(acceptance.mode, .live)
        #else
        XCTAssertEqual(acceptance.mode, .live)
        #endif
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: [
                "VPlayer", "-acceptance-playback", "duplicate",
                "-acceptance-playback",
            ]).mode,
            .live
        )
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: [
                "VPlayer", "-ui-fixture", "seeded", "-acceptance-playback",
            ]).mode,
            .live
        )
    }

    #if DEBUG
    func testAcceptanceSourcePrefillAcceptsOnlyBase64LaunchTransport() throws {
        let source = "https://example.test/list.m3u"
        let epg = "http://example.test/epg.xml"
        let encoded = Data(source.utf8).base64EncodedString()
        let encodedEPG = Data(epg.utf8).base64EncodedString()

        let prefill = try XCTUnwrap(AcceptanceSourcePrefill.current(
            arguments: ["VPlayer", "-acceptance-playback"],
            environment: [
                AcceptanceSourcePrefill.encodedM3UKey: encoded,
                AcceptanceSourcePrefill.encodedEPGKey: encodedEPG,
            ]
        ))

        XCTAssertEqual(prefill.m3uURLString, source)
        XCTAssertEqual(prefill.epgURLString, epg)
        XCTAssertNil(AcceptanceSourcePrefill.current(
            arguments: ["VPlayer"],
            environment: [AcceptanceSourcePrefill.encodedM3UKey: encoded]
        ))
        XCTAssertNil(AcceptanceSourcePrefill.current(
            arguments: ["VPlayer", "-acceptance-playback"],
            environment: ["VPLAYER_ACCEPTANCE_M3U_URL": source]
        ))
        XCTAssertNil(AcceptanceSourcePrefill.current(
            arguments: [
                "VPlayer", "-ui-fixture", "seeded", "-acceptance-playback",
            ],
            environment: [AcceptanceSourcePrefill.encodedM3UKey: encoded]
        ))
        XCTAssertFalse(AcceptanceSourcePrefill.isActive(arguments: [
            "VPlayer", "-ui-fixture", "seeded", "-acceptance-playback",
        ]))
        XCTAssertNil(AcceptanceSourcePrefill.current(
            arguments: ["VPlayer", "-acceptance-playback"],
            environment: [
                AcceptanceSourcePrefill.encodedM3UKey: encoded,
                AcceptanceSourcePrefill.encodedEPGKey: "not-base64",
            ]
        ))
    }

    func testAcceptanceM3UFieldPresentationNeverDisplaysRawURL() {
        let source = "https://user:secret@example.test/list.m3u?token=private"

        let protected = SourceProfileEditorM3UFieldPresentation(
            rawValue: source,
            protectsValue: true
        )
        let normal = SourceProfileEditorM3UFieldPresentation(
            rawValue: source,
            protectsValue: false
        )

        XCTAssertTrue(protected.isProtected)
        XCTAssertEqual(protected.displayedValue, "Protected URL configured")
        XCTAssertFalse(protected.displayedValue.contains(source))
        XCTAssertFalse(normal.isProtected)
        XCTAssertEqual(normal.displayedValue, source)
    }

    func testAcceptancePlaybackStatePresentationUsesOnlySanitizedStateAndFailureCode() {
        let secretChannelID = "secret-channel-id"
        let secretTitle = "Secret Channel Title"
        let secretURL = "https://user:password@example.test/live?token=secret"
        let request = PlaybackRequest(
            sourceProfileID: UUID(),
            channelID: secretChannelID,
            streamURL: URL(string: secretURL)!,
            title: secretTitle
        )
        let failure = PlaybackFailure(
            code: "decoder.invalid-data",
            userMessage: "Could not play \(secretTitle) from \(secretURL)"
        )
        let presentations = [
            AcceptancePlaybackStatePresentation(state: .idle).value,
            AcceptancePlaybackStatePresentation(state: .preparing(request)).value,
            AcceptancePlaybackStatePresentation(state: .buffering(request)).value,
            AcceptancePlaybackStatePresentation(state: .recovering(request)).value,
            AcceptancePlaybackStatePresentation(state: .playing(request)).value,
            AcceptancePlaybackStatePresentation(state: .paused(request)).value,
            AcceptancePlaybackStatePresentation(state: .stopped).value,
            AcceptancePlaybackStatePresentation(state: .failed(failure)).value,
        ]

        XCTAssertEqual(presentations, [
            "idle", "preparing", "buffering", "recovering", "playing", "paused", "stopped",
            "failed:decoder.invalid-data",
        ])
        for presentation in presentations {
            XCTAssertFalse(presentation.contains(secretChannelID))
            XCTAssertFalse(presentation.contains(secretTitle))
            XCTAssertFalse(presentation.contains(secretURL))
            XCTAssertFalse(presentation.contains(failure.userMessage))
        }
    }

    func testAcceptancePlaybackStatePresentationPrefersDiagnosticCodeWithoutSecrets() {
        let secretChannelID = "secret-channel-id"
        let secretTitle = "Secret Channel Title"
        let secretURL = "https://user:password@example.test/live?token=secret"
        let failure = PlaybackFailure(
            code: "public-\(secretChannelID)",
            userMessage: "Could not play \(secretTitle) from \(secretURL)",
            diagnosticCode: "video.decode.status.-12909"
        )

        let presentation = AcceptancePlaybackStatePresentation(
            state: .failed(failure)
        ).value

        XCTAssertEqual(presentation, "failed:video.decode.status.-12909")
        XCTAssertFalse(presentation.contains(secretChannelID))
        XCTAssertFalse(presentation.contains(secretTitle))
        XCTAssertFalse(presentation.contains(secretURL))
        XCTAssertFalse(presentation.contains(failure.userMessage))
    }

    func testExactAcceptanceEditorFocusPolicyStartsOnSave() {
        XCTAssertEqual(
            SourceProfileEditorFocusPolicy(
                protectsAcceptanceSourceValue: true
            ).initialTarget,
            .save
        )
    }

    func testNormalEditorFocusPolicyDoesNotForceAControl() {
        XCTAssertNil(
            SourceProfileEditorFocusPolicy(
                protectsAcceptanceSourceValue: false
            ).initialTarget
        )
    }

    func testExactAcceptanceSourcesFocusStartsOnAddThenMovesToPlaylistRefresh() {
        let policy = AcceptanceFocusPolicy(isEnabled: true)

        XCTAssertEqual(policy.initialSourceControl, .add)
        XCTAssertEqual(policy.sourceControlAfterEditorDismissal, .playlistRefresh)
    }

    func testNormalSourcesFocusDoesNotForceAControl() {
        let policy = AcceptanceFocusPolicy(isEnabled: false)

        XCTAssertNil(policy.initialSourceControl)
        XCTAssertNil(policy.sourceControlAfterEditorDismissal)
    }

    func testAcceptanceFocusPolicyOwnsEveryRealFlowBoundaryOnlyWhenExactLaunchIsActive() {
        let acceptance = AcceptanceFocusPolicy(isEnabled: true)
        XCTAssertEqual(acceptance.initialRootTab, .sources)
        XCTAssertEqual(acceptance.initialSourceControl, .add)
        XCTAssertEqual(acceptance.sourceControlAfterEditorDismissal, .playlistRefresh)
        XCTAssertTrue(acceptance.focusesFirstChannel)
        XCTAssertEqual(acceptance.initialPlayerControl, .settings)

        let normal = AcceptanceFocusPolicy(isEnabled: false)
        XCTAssertEqual(normal.initialRootTab, .channels)
        XCTAssertNil(normal.initialSourceControl)
        XCTAssertNil(normal.sourceControlAfterEditorDismissal)
        XCTAssertFalse(normal.focusesFirstChannel)
        XCTAssertEqual(normal.initialPlayerControl, .playPause)

    }
    #endif

    func testAppInitializationDefersMaintenanceUntilLibraryLaunchAndThenRunsItOnce() async {
        let probe = StartupMaintenanceProbe()
        let dependencies = makeDependencies(maintenance: probe)

        _ = VPlayerApp(dependencies: dependencies)
        for _ in 0..<100 {
            await Task.yield()
        }
        let countBeforeLibraryLaunch = await probe.attemptCount
        XCTAssertEqual(countBeforeLibraryLaunch, 0)

        dependencies.launch()
        await probe.waitUntilAttempted()
        let repeatedOutcome = await dependencies.start()
        let attemptCount = await probe.attemptCount

        XCTAssertEqual(repeatedOutcome, .alreadyCompleted)
        XCTAssertEqual(attemptCount, 1)
    }

    func testLiveAppRegistersBackgroundBeforeDetachedRuntimeStarts() async {
        let repository = RepositorySpy(profiles: [])
        let factory = LiveRuntimeFactoryProbe(repository: repository, blocksFirstAttempt: true)
        let loader = LiveLibraryRuntimeLoader {
            try await factory.makeRuntime(
                inheritedTaskLocal: LiveRuntimeLoadTaskContext.inheritedMarker
            )
        }
        let scheduler = StartupBackgroundSchedulerSpy()
        let bootstrap = LiveAppBootstrap(
            runtimeLoader: loader,
            libraryChanges: LibraryChangeSignal(),
            backgroundScheduler: scheduler
        )

        _ = VPlayerApp(liveBootstrap: bootstrap)

        XCTAssertEqual(scheduler.registrationCount, 1)
        let attemptCount = await factory.attemptCount
        XCTAssertEqual(attemptCount, 0)
    }

    func testLiveRuntimeLoadIsDetachedCoalescedAndCached() async throws {
        let repository = RepositorySpy(profiles: [])
        let factory = LiveRuntimeFactoryProbe(repository: repository, blocksFirstAttempt: true)
        let loader = LiveLibraryRuntimeLoader {
            try await factory.makeRuntime(
                inheritedTaskLocal: LiveRuntimeLoadTaskContext.inheritedMarker
            )
        }

        let first = Task {
            try await LiveRuntimeLoadTaskContext.$inheritedMarker.withValue(true) {
                try await loader.load()
            }
        }
        await factory.waitUntilAttemptCount(1)
        let second = Task { try await loader.load() }
        for _ in 0..<100 {
            await Task.yield()
        }

        let countWhileBlocked = await factory.attemptCount
        XCTAssertEqual(countWhileBlocked, 1)
        await factory.releaseFirstAttempt()
        _ = try await first.value
        _ = try await second.value
        _ = try await loader.load()

        let finalCount = await factory.attemptCount
        let inheritedTaskLocal = await factory.inheritedTaskLocal
        XCTAssertEqual(finalCount, 1)
        XCTAssertEqual(inheritedTaskLocal, false)
    }

    func testLiveRuntimeFailureCanRetryAndBootstrapSharesTheSuccessfulRuntime() async throws {
        let repository = RepositorySpy(profiles: [])
        let factory = LiveRuntimeFactoryProbe(repository: repository, failsFirstAttempt: true)
        let loader = LiveLibraryRuntimeLoader {
            try await factory.makeRuntime(
                inheritedTaskLocal: LiveRuntimeLoadTaskContext.inheritedMarker
            )
        }
        let bootstrap = LiveAppBootstrap(
            runtimeLoader: loader,
            libraryChanges: LibraryChangeSignal(),
            backgroundScheduler: StartupBackgroundSchedulerSpy()
        )

        do {
            _ = try await bootstrap.dependencies()
            XCTFail("Expected the first runtime construction to fail")
        } catch is StartupProbeError {
            // Expected: a failed shared task must be discarded for retry.
        }

        let dependencies = try await bootstrap.dependencies()
        let profiles = try await dependencies.repository.profiles()
        let attemptCount = await factory.attemptCount

        XCTAssertTrue(profiles.isEmpty)
        XCTAssertEqual(attemptCount, 2)
    }

    func testInitialLibraryUsesPreparedCacheBeforeBlockedMaintenanceCompletes() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = SourceProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Source",
            m3uURL: URL(string: "https://example.test/list.m3u")!,
            epgURL: URL(string: "https://example.test/epg.xml")!,
            m3uRefreshInterval: .sixHours,
            epgRefreshInterval: .daily,
            m3uStatus: ResourceRefreshStatus(),
            epgStatus: ResourceRefreshStatus(),
            createdAt: now,
            updatedAt: now
        )
        let channel = Channel(
            sourceProfileID: profile.id,
            displayName: "Cached Channel",
            streamURL: URL(string: "https://example.test/live")!,
            tvgID: nil,
            tvgName: nil,
            logoURL: nil,
            groupTitle: nil,
            attributes: [:],
            order: 0
        )
        let repository = RepositorySpy(profiles: [profile])
        let maintenance = BlockingStartupMaintenanceProbe()
        let completion = StartupOpeningCompletionProbe()
        let dependencies = VPlayerDependencies(
            libraryStartup: LibraryStartup {
                try await maintenance.purgeUnreferencedSnapshots()
            },
            foregroundRefreshDriver: ForegroundRefreshDriver(
                loadProfiles: { [] },
                refresh: { _, _, _ in [] },
                reportStatus: { _ in }
            ),
            backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                scheduler: StartupBackgroundSchedulerSpy(),
                loadProfiles: { [] },
                refresh: { _, _, _ in [] },
                reportStatus: { _ in }
            ),
            repository: repository,
            prepare: {
                await repository.replaceChannels(
                    profileID: profile.id,
                    channels: [channel]
                )
            }
        )
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            now: { now }
        )

        let opening = Task {
            await dependencies.openInitialLibrary(using: model)
            await completion.recordCompletion()
        }
        await maintenance.waitUntilAttempted()
        for _ in 0..<100 {
            await Task.yield()
        }
        let completedBeforeCleanupRelease = await completion.isComplete

        XCTAssertEqual(model.channels, [channel])
        await maintenance.release()
        await opening.value
        XCTAssertTrue(completedBeforeCleanupRelease)
    }

    func testInitialLibraryPreparationFailureKeepsLibraryClosedUntilRetrySucceeds() async {
        let repository = RepositorySpy(profiles: [])
        let prepare = RetryingLibraryPrepareProbe()
        let foreground = ForegroundRefreshDriver(
            loadProfiles: { try await repository.profiles() },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )
        defer { foreground.deactivate() }
        foreground.activate()
        let dependencies = VPlayerDependencies(
            libraryStartup: LibraryStartup {},
            foregroundRefreshDriver: foreground,
            backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                scheduler: StartupBackgroundSchedulerSpy(),
                loadProfiles: { try await repository.profiles() },
                refresh: { _, _, _ in [] },
                reportStatus: { _ in }
            ),
            repository: repository,
            prepare: {
                try await prepare.run()
            }
        )
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] }
        )

        let firstOpen = await dependencies.openInitialLibrary(using: model)
        let firstSnapshot = await repository.snapshot()

        XCTAssertFalse(firstOpen)
        XCTAssertFalse(foreground.isInitialLibraryLoadComplete)
        XCTAssertEqual(firstSnapshot.profileLookupCount, 0)

        let retryOpen = await dependencies.openInitialLibrary(using: model)
        let prepareAttemptCount = await prepare.attemptCount

        XCTAssertTrue(retryOpen)
        XCTAssertTrue(foreground.isInitialLibraryLoadComplete)
        XCTAssertEqual(prepareAttemptCount, 2)
        foreground.deactivate()
    }

    func testInitialLibraryReadFailureKeepsLibraryClosedUntilRetryAppliesSnapshot() async {
        let repository = RepositorySpy(profiles: [])
        await repository.setReadFailure(true)
        let foreground = ForegroundRefreshDriver(
            loadProfiles: { try await repository.profiles() },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )
        defer { foreground.deactivate() }
        foreground.activate()
        let dependencies = VPlayerDependencies(
            libraryStartup: LibraryStartup {},
            foregroundRefreshDriver: foreground,
            backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                scheduler: StartupBackgroundSchedulerSpy(),
                loadProfiles: { try await repository.profiles() },
                refresh: { _, _, _ in [] },
                reportStatus: { _ in }
            ),
            repository: repository
        )
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] }
        )

        let firstOpen = await dependencies.openInitialLibrary(using: model)

        XCTAssertFalse(firstOpen)
        XCTAssertFalse(foreground.isInitialLibraryLoadComplete)

        await repository.setReadFailure(false)
        let retryOpen = await dependencies.openInitialLibrary(using: model)

        XCTAssertTrue(retryOpen)
        XCTAssertTrue(foreground.isInitialLibraryLoadComplete)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertFalse(model.isLoading)
        foreground.deactivate()
    }

    func testFailedLibraryStartupCanRetryAndCompletesOnlyOnceAfterSuccess() async {
        let probe = StartupMaintenanceProbe(failFirstAttempt: true)
        let startup = LibraryStartup {
            try await probe.purgeUnreferencedSnapshots()
        }

        let firstOutcome = await startup.start()
        let retryOutcome = await startup.start()
        let repeatedOutcome = await startup.start()
        let attemptCount = await probe.attemptCount

        XCTAssertEqual(firstOutcome, .failed)
        XCTAssertEqual(retryOutcome, .completed)
        XCTAssertEqual(repeatedOutcome, .alreadyCompleted)
        XCTAssertEqual(attemptCount, 2)
    }

    func testAppInitializationRegistersBackgroundRefreshExactlyOnce() {
        let scheduler = StartupBackgroundSchedulerSpy()
        let dependencies = makeDependencies(
            maintenance: StartupMaintenanceProbe(),
            scheduler: scheduler
        )

        _ = VPlayerApp(dependencies: dependencies)

        XCTAssertEqual(scheduler.registrationCount, 1)
    }

    func testScenePhaseRoutesActiveThenBackgroundLifecycle() async {
        let loopProbe = StartupLoopProbe()
        let scheduler = StartupBackgroundSchedulerSpy()
        let dependencies = makeDependencies(
            maintenance: StartupMaintenanceProbe(),
            scheduler: scheduler,
            sleep: {
                await loopProbe.recordSleepStarted()
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    await loopProbe.recordCancellation()
                    throw error
                }
            }
        )
        let app = VPlayerApp(dependencies: dependencies)

        app.handleScenePhase(.active)
        for _ in 0..<100 {
            await Task.yield()
        }
        let sleepCountBeforeInitialLoad = await loopProbe.sleepCountValue()
        XCTAssertEqual(sleepCountBeforeInitialLoad, 0)
        dependencies.foregroundRefreshDriver.initialLibraryLoadDidComplete()
        await loopProbe.waitUntilSleeping()
        app.handleScenePhase(.background)
        await loopProbe.waitUntilCancelled()
        await scheduler.waitUntilCancelled()

        let cancellationCount = await loopProbe.cancellationCountValue()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(scheduler.cancelledIdentifiers, [BackgroundRefreshRegistrar.identifier])
    }

    private func makeDependencies(
        maintenance: any LibrarySnapshotMaintenance,
        scheduler: StartupBackgroundSchedulerSpy = StartupBackgroundSchedulerSpy(),
        sleep: @escaping ForegroundRefreshDriver.Sleep = {
            try await ContinuousClock().sleep(for: .seconds(60))
        }
    ) -> VPlayerDependencies {
        let foreground = ForegroundRefreshDriver(
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            sleep: sleep,
            reportStatus: { _ in }
        )
        let background = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )
        return VPlayerDependencies(
            libraryStartup: LibraryStartup {
                try await maintenance.purgeUnreferencedSnapshots()
            },
            foregroundRefreshDriver: foreground,
            backgroundRefreshRegistrar: background
        )
    }
}

private struct FixedChannelLogoDataLoader: ChannelLogoDataLoading {
    let data: Data

    func data(for url: URL, maximumByteCount: Int) async -> Data? {
        _ = url
        return data.count <= maximumByteCount ? data : nil
    }
}

private struct NilChannelLogoDataLoader: ChannelLogoDataLoading {
    func data(for url: URL, maximumByteCount: Int) async -> Data? {
        _ = url
        _ = maximumByteCount
        return nil
    }
}

private struct ThreadRecordingChannelLogoDecoder: ChannelLogoImageDecoding {
    let probe: ChannelLogoDecoderThreadProbe

    func decodeThumbnail(from data: Data) -> DecodedChannelLogo? {
        probe.record(Thread.isMainThread)
        return ChannelLogoImageDecoder().decodeThumbnail(from: data)
    }
}

private final class ChannelLogoDecoderThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    var threadValues: [Bool] {
        lock.withLock { values }
    }

    func record(_ isMainThread: Bool) {
        lock.withLock { values.append(isMainThread) }
    }
}

private actor LiveRuntimeFactoryProbe {
    private let repository: RepositorySpy
    private let blocksFirstAttempt: Bool
    private let failsFirstAttempt: Bool
    private var attemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstAttemptRelease: CheckedContinuation<Void, Never>?
    private var isFirstAttemptReleased = false
    private(set) var attemptCount = 0
    private(set) var inheritedTaskLocal: Bool?

    init(
        repository: RepositorySpy,
        blocksFirstAttempt: Bool = false,
        failsFirstAttempt: Bool = false
    ) {
        self.repository = repository
        self.blocksFirstAttempt = blocksFirstAttempt
        self.failsFirstAttempt = failsFirstAttempt
    }

    func makeRuntime(inheritedTaskLocal: Bool) async throws -> LiveLibraryRuntime {
        attemptCount += 1
        let attempt = attemptCount
        self.inheritedTaskLocal = inheritedTaskLocal
        for waiter in attemptWaiters {
            waiter.resume()
        }
        attemptWaiters = []

        if blocksFirstAttempt, attempt == 1, !isFirstAttemptReleased {
            await withCheckedContinuation { continuation in
                firstAttemptRelease = continuation
            }
        }
        if failsFirstAttempt, attempt == 1 {
            throw StartupProbeError.expected
        }

        let repository = repository
        return LiveLibraryRuntime(
            repository: repository,
            refresh: { _, resources, _ in
                resources.map {
                    RefreshOutcome(resource: $0, succeeded: true, message: nil)
                }
            },
            prepare: {},
            maintenance: {}
        )
    }

    func waitUntilAttemptCount(_ expectedCount: Int) async {
        guard attemptCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            attemptWaiters.append(continuation)
        }
    }

    func releaseFirstAttempt() {
        isFirstAttemptReleased = true
        firstAttemptRelease?.resume()
        firstAttemptRelease = nil
    }
}

private actor StartupMaintenanceProbe: LibrarySnapshotMaintenance {
    private(set) var attemptCount = 0
    private let failFirstAttempt: Bool
    private var firstAttemptWaiter: CheckedContinuation<Void, Never>?

    init(failFirstAttempt: Bool = false) {
        self.failFirstAttempt = failFirstAttempt
    }

    func purgeUnreferencedSnapshots() throws {
        attemptCount += 1
        firstAttemptWaiter?.resume()
        firstAttemptWaiter = nil
        if failFirstAttempt && attemptCount == 1 {
            throw StartupProbeError.expected
        }
    }

    func waitUntilAttempted() async {
        guard attemptCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstAttemptWaiter = continuation
        }
    }
}

private actor BlockingStartupMaintenanceProbe: LibrarySnapshotMaintenance {
    private var attemptedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasAttempted = false

    func purgeUnreferencedSnapshots() async throws {
        hasAttempted = true
        for waiter in attemptedWaiters {
            waiter.resume()
        }
        attemptedWaiters = []
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilAttempted() async {
        guard !hasAttempted else { return }
        await withCheckedContinuation { continuation in
            attemptedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor StartupOpeningCompletionProbe {
    private(set) var isComplete = false

    func recordCompletion() {
        isComplete = true
    }
}

private enum StartupProbeError: Error {
    case expected
}

private actor RetryingLibraryPrepareProbe {
    private(set) var attemptCount = 0

    func run() throws {
        attemptCount += 1
        if attemptCount == 1 {
            throw StartupProbeError.expected
        }
    }
}

private actor StartupLoopProbe {
    private var sleepCount = 0
    private var cancellationCount = 0

    func recordSleepStarted() {
        sleepCount += 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func waitUntilSleeping() async {
        for _ in 0..<1_000 {
            if sleepCount > 0 { return }
            await Task.yield()
        }
    }

    func waitUntilCancelled() async {
        for _ in 0..<1_000 {
            if cancellationCount > 0 { return }
            await Task.yield()
        }
    }

    func cancellationCountValue() -> Int {
        cancellationCount
    }

    func sleepCountValue() -> Int {
        sleepCount
    }
}

@MainActor
private final class StartupBackgroundSchedulerSpy: BackgroundRefreshScheduling {
    private(set) var registrationCount = 0
    private(set) var cancelledIdentifiers: [String] = []

    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool {
        _ = identifier
        _ = handler
        registrationCount += 1
        return true
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }

    func submit(identifier: String, earliestBeginDate: Date) throws {
        _ = identifier
        _ = earliestBeginDate
    }

    func waitUntilCancelled() async {
        for _ in 0..<1_000 {
            if !cancelledIdentifiers.isEmpty { return }
            await Task.yield()
        }
    }
}
