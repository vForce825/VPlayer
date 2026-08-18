// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation
import OSLog
import UIKit
import VPlayerCore
import VPlayerPlayback

@MainActor
final class ChannelLogoCache {
    static let shared = ChannelLogoCache()

    private struct LoadedLogo {
        let image: UIImage
        let cost: Int
    }

    private let memoryCache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private let diskCache: ChannelLogoDiskCache?
    private let maximumResponseBytes: Int
    private var inFlight: [URL: Task<LoadedLogo?, Never>] = [:]

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        memoryCostLimit: Int = 64 * 1_024 * 1_024,
        diskCapacity: Int = 128 * 1_024 * 1_024,
        maximumResponseBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.session = session
        self.maximumResponseBytes = maximumResponseBytes
        memoryCache.totalCostLimit = memoryCostLimit
        memoryCache.countLimit = 256

        do {
            let directory = try cacheDirectory
                ?? Self.defaultCacheDirectory(fileManager: fileManager)
            diskCache = try ChannelLogoDiskCache(
                directory: directory,
                capacity: diskCapacity
            )
        } catch {
            // A cache failure must not prevent the channel browser from loading.
            // The in-memory layer and direct network request remain available.
            diskCache = nil
        }
    }

    func image(for url: URL) async -> UIImage? {
        let cacheKey = url as NSURL
        if let image = memoryCache.object(forKey: cacheKey) {
            return image
        }
        if let task = inFlight[url] {
            return await task.value?.image
        }

        let task = Task { [weak self] () -> LoadedLogo? in
            guard let self else { return nil }
            return await self.loadLogo(for: url)
        }
        inFlight[url] = task
        let loaded = await task.value
        inFlight[url] = nil
        if let loaded {
            memoryCache.setObject(loaded.image, forKey: cacheKey, cost: loaded.cost)
        }
        return loaded?.image
    }

    func memoryCachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    static func defaultCacheDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let cachesRoot = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return cachesRoot
            .appendingPathComponent("VPlayer", isDirectory: true)
            .appendingPathComponent("ChannelLogos", isDirectory: true)
    }

    private func loadLogo(for url: URL) async -> LoadedLogo? {
        let diskKey = Self.diskKey(for: url)
        if let diskCache,
           let data = await diskCache.data(forKey: diskKey) {
            if let image = await preparedImage(from: data) {
                return LoadedLogo(image: image, cost: Self.memoryCost(for: image, data: data))
            }
            await diskCache.removeData(forKey: diskKey)
        }

        guard let data = await downloadLogo(from: url),
              let image = await preparedImage(from: data) else {
            return nil
        }
        if let diskCache {
            await diskCache.store(data, forKey: diskKey)
        }
        return LoadedLogo(image: image, cost: Self.memoryCost(for: image, data: data))
    }

    private func preparedImage(from data: Data) async -> UIImage? {
        guard let image = UIImage(data: data, scale: 1) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }

    private func downloadLogo(from url: URL) async -> Data? {
        if url.isFileURL {
            return await Task.detached(priority: .utility) { [maximumResponseBytes] in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let fileSize = values.fileSize,
                      fileSize <= maximumResponseBytes else {
                    return nil
                }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        }

        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= maximumResponseBytes else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func diskKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func memoryCost(for image: UIImage, data: Data) -> Int {
        guard let cgImage = image.cgImage else { return data.count }
        return cgImage.bytesPerRow * cgImage.height
    }
}

private actor ChannelLogoDiskCache {
    private struct Entry {
        let url: URL
        let size: Int
        let modificationDate: Date
    }

    private let directory: URL
    private let capacity: Int
    private let fileManager: FileManager

    init(directory: URL, capacity: Int) throws {
        self.directory = directory
        self.capacity = capacity
        fileManager = .default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func data(forKey key: String) -> Data? {
        let fileURL = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        return data
    }

    func store(_ data: Data, forKey key: String) {
        guard data.count <= capacity else { return }
        do {
            try data.write(to: fileURL(forKey: key), options: .atomic)
            try pruneIfNeeded()
        } catch {
            // Disk caching is best-effort; the memory cache already owns the image.
        }
    }

    func removeData(forKey key: String) {
        try? fileManager.removeItem(at: fileURL(forKey: key))
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false)
    }

    private func pruneIfNeeded() throws {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        var entries: [Entry] = []
        var totalSize = 0
        for fileURL in fileURLs {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            totalSize += size
            entries.append(Entry(
                url: fileURL,
                size: size,
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }
        guard totalSize > capacity else { return }
        for entry in entries.sorted(by: { $0.modificationDate < $1.modificationDate }) {
            try? fileManager.removeItem(at: entry.url)
            totalSize -= entry.size
            if totalSize <= capacity { break }
        }
    }
}

protocol LibrarySnapshotMaintenance: Sendable {
    func purgeUnreferencedSnapshots() async throws
}

extension SwiftDataLibraryStore: LibrarySnapshotMaintenance {}

enum LibraryStartupOutcome: Equatable, Sendable {
    case completed
    case alreadyCompleted
    case failed
}

actor LibraryStartup {
    typealias Maintenance = @Sendable () async throws -> Void

    private let maintenance: Maintenance
    private var runningTask: Task<Bool, Never>?
    private var isCompleted = false

    init(maintenance: @escaping Maintenance) {
        self.maintenance = maintenance
    }

    func start() async -> LibraryStartupOutcome {
        if isCompleted {
            return .alreadyCompleted
        }
        if let runningTask {
            return await runningTask.value ? .alreadyCompleted : .failed
        }

        let maintenance = maintenance
        let task = Task {
            do {
                try await maintenance()
                return true
            } catch {
                return false
            }
        }
        runningTask = task
        let succeeded = await task.value
        runningTask = nil
        if succeeded {
            isCompleted = true
            return .completed
        }
        return .failed
    }
}

struct LiveLibraryRuntime: Sendable {
    typealias Refresh = @Sendable (
        UUID,
        Set<RefreshResource>,
        RefreshTrigger
    ) async -> [RefreshOutcome]
    typealias Operation = @Sendable () async throws -> Void

    let repository: any LibraryRepository & RefreshSnapshotCommitting
    let refresh: Refresh
    let prepare: Operation
    let maintenance: Operation
}

/// Owns the one production-library construction task shared by the initial
/// scene, foreground scheduling, and a background launch. The factory runs in
/// a detached user-initiated task so opening or recovering the SwiftData store
/// can never hold MainActor before the first SwiftUI frame. Failed attempts are
/// deliberately not cached, allowing the launch retry UI to try again.
actor LiveLibraryRuntimeLoader {
    typealias Factory = @Sendable () async throws -> LiveLibraryRuntime

    private struct RunningLoad {
        let id: UUID
        let task: Task<LiveLibraryRuntime, Error>
    }

    private let factory: Factory
    private var loadedRuntime: LiveLibraryRuntime?
    private var runningLoad: RunningLoad?

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func load() async throws -> LiveLibraryRuntime {
        if let loadedRuntime {
            return loadedRuntime
        }
        if let runningLoad {
            return try await resolve(runningLoad)
        }

        let factory = factory
        let runningLoad = RunningLoad(
            id: UUID(),
            task: Task.detached(priority: .userInitiated) {
                try await factory()
            }
        )
        self.runningLoad = runningLoad
        return try await resolve(runningLoad)
    }

    private func resolve(_ load: RunningLoad) async throws -> LiveLibraryRuntime {
        do {
            let runtime = try await load.task.value
            if runningLoad?.id == load.id {
                loadedRuntime = runtime
                runningLoad = nil
            }
            return runtime
        } catch {
            if runningLoad?.id == load.id {
                runningLoad = nil
            }
            throw error
        }
    }
}

private func makeProductionLibraryRuntime(
    onPersistedOutcome: @escaping RefreshCoordinator.PersistedOutcomeHandler,
    onRefreshStarted: @escaping RefreshCoordinator.RefreshStartedHandler
) throws -> LiveLibraryRuntime {
    let container = try VPlayerModelContainer.make()
    let repository = SwiftDataLibraryStore(
        modelContainer: container,
        profileMirror: SourceProfileMirror(defaults: .standard)
    )
    let coordinator = RefreshCoordinator(
        repository: repository,
        downloader: URLSessionBoundedDownloader(),
        onPersistedOutcome: onPersistedOutcome,
        onRefreshStarted: onRefreshStarted
    )
    let refresh: LiveLibraryRuntime.Refresh = { profileID, resources, trigger in
        await coordinator.refresh(
            profileID: profileID,
            resources: resources,
            trigger: trigger
        )
    }
    return LiveLibraryRuntime(
        repository: repository,
        refresh: refresh,
        prepare: {
            // tvOS can delete the Caches-resident store between launches.
            // Restore the non-refetchable source profiles before the first
            // library read.
            if try await repository.synchronizeProfileMirror() > 0 {
                logger.notice("Restored source profiles after a purged persistent store.")
            }
        },
        maintenance: {
            try await repository.purgeUnreferencedSnapshots()
        }
    )
}

@MainActor
final class LiveAppBootstrap {
    let foregroundRefreshDriver: ForegroundRefreshDriver
    let backgroundRefreshRegistrar: BackgroundRefreshRegistrar

    private let runtimeLoader: LiveLibraryRuntimeLoader
    private let libraryChanges: LibraryChangeSignal
    private var loadedDependencies: AppDependencies?

    static func production() -> LiveAppBootstrap {
        let libraryChanges = LibraryChangeSignal()
        let onPersistedOutcome: RefreshCoordinator.PersistedOutcomeHandler = {
            [weak libraryChanges] _, _ in
            await MainActor.run {
                libraryChanges?.notify()
            }
        }
        let onRefreshStarted: RefreshCoordinator.RefreshStartedHandler = {
            [weak libraryChanges] profileID, resource in
            await MainActor.run {
                libraryChanges?.notifyRefreshStarted(
                    profileID: profileID,
                    resource: resource
                )
            }
        }
        let runtimeLoader = LiveLibraryRuntimeLoader {
            try makeProductionLibraryRuntime(
                onPersistedOutcome: onPersistedOutcome,
                onRefreshStarted: onRefreshStarted
            )
        }
        return LiveAppBootstrap(
            runtimeLoader: runtimeLoader,
            libraryChanges: libraryChanges
        )
    }

    init(
        runtimeLoader: LiveLibraryRuntimeLoader,
        libraryChanges: LibraryChangeSignal,
        backgroundScheduler: (any BackgroundRefreshScheduling)? = nil
    ) {
        self.runtimeLoader = runtimeLoader
        self.libraryChanges = libraryChanges

        let loadProfiles: ForegroundRefreshDriver.LoadProfiles = {
            let runtime = try await runtimeLoader.load()
            return try await runtime.repository.profiles()
        }
        let refresh: ForegroundRefreshDriver.Refresh = {
            profileID,
            resources,
            trigger in
            do {
                let runtime = try await runtimeLoader.load()
                return await runtime.refresh(profileID, resources, trigger)
            } catch {
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: false, message: nil)
                }
            }
        }
        foregroundRefreshDriver = ForegroundRefreshDriver(
            loadProfiles: loadProfiles,
            refresh: refresh,
            reportStatus: { _ in }
        )
        if let backgroundScheduler {
            backgroundRefreshRegistrar = BackgroundRefreshRegistrar(
                scheduler: backgroundScheduler,
                loadProfiles: loadProfiles,
                refresh: refresh,
                reportStatus: { _ in }
            )
        } else {
            backgroundRefreshRegistrar = BackgroundRefreshRegistrar(
                loadProfiles: loadProfiles,
                refresh: refresh,
                reportStatus: { _ in }
            )
        }
    }

    func dependencies() async throws -> AppDependencies {
        if let loadedDependencies {
            return loadedDependencies
        }
        let runtime = try await runtimeLoader.load()
        try Task.checkCancellation()
        if let loadedDependencies {
            return loadedDependencies
        }

        let dependencies = AppDependencies(
            libraryStartup: LibraryStartup(maintenance: runtime.maintenance),
            foregroundRefreshDriver: foregroundRefreshDriver,
            backgroundRefreshRegistrar: backgroundRefreshRegistrar,
            repository: runtime.repository,
            refresh: runtime.refresh,
            prepare: runtime.prepare,
            libraryChanges: libraryChanges
        )
        loadedDependencies = dependencies
        return dependencies
    }
}

@MainActor
struct AppDependencies {
    typealias Refresh = AppModel.Refresh
    typealias Prepare = @Sendable () async throws -> Void
    typealias PlaybackPresentationProvider = @Sendable () async -> PlaybackPresentationContext?
    typealias PlaybackMediaInformationProvider = @Sendable () async -> AsyncStream<PlaybackMediaInformation?>
    typealias PlaybackMetricsProvider = @Sendable (Duration) async -> PlaybackMetricsSnapshot?

    let repository: any LibraryRepository
    let refresh: Refresh
    let prepare: Prepare
    let playbackSettings: PlaybackSettingsStore
    let channelBrowsingSettings: ChannelBrowsingSettingsStore
    let playbackEngine: any PlaybackEngine
    let playbackPresentationProvider: PlaybackPresentationProvider
    let playbackMediaInformationProvider: PlaybackMediaInformationProvider
    let playbackMetricsProvider: PlaybackMetricsProvider
    let exposesAcceptanceMetrics: Bool
    let exposesAcceptanceState: Bool
    /// False when the persistent store could not be opened at all. Every
    /// repository call then fails, so the UI shows a dedicated explanation
    /// instead of a generic "try again later" alert on every screen.
    let isLibraryAvailable: Bool
    let libraryChanges: LibraryChangeSignal
    let libraryStartup: LibraryStartup
    let foregroundRefreshDriver: ForegroundRefreshDriver
    let backgroundRefreshRegistrar: BackgroundRefreshRegistrar

    init(
        libraryStartup: LibraryStartup,
        foregroundRefreshDriver: ForegroundRefreshDriver,
        backgroundRefreshRegistrar: BackgroundRefreshRegistrar,
        repository: any LibraryRepository = UnavailableLibraryRepository(),
        refresh: @escaping Refresh = { _, resources, _ in
            resources.map { RefreshOutcome(resource: $0, succeeded: false, message: nil) }
        },
        prepare: @escaping Prepare = {},
        playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore(),
        channelBrowsingSettings: ChannelBrowsingSettingsStore = ChannelBrowsingSettingsStore(),
        playbackEngine: (any PlaybackEngine)? = nil,
        playbackPresentationProvider: PlaybackPresentationProvider? = nil,
        playbackMediaInformationProvider: PlaybackMediaInformationProvider? = nil,
        playbackMetricsProvider: PlaybackMetricsProvider? = nil,
        exposesAcceptanceMetrics: Bool = false,
        exposesAcceptanceState: Bool = false,
        isLibraryAvailable: Bool = true,
        libraryChanges: LibraryChangeSignal = LibraryChangeSignal()
    ) {
        self.isLibraryAvailable = isLibraryAvailable
        self.repository = repository
        self.refresh = refresh
        self.prepare = prepare
        self.playbackSettings = playbackSettings
        self.channelBrowsingSettings = channelBrowsingSettings
        let resolvedPlaybackEngine: any PlaybackEngine
        if let playbackEngine {
            resolvedPlaybackEngine = playbackEngine
            self.playbackPresentationProvider = playbackPresentationProvider ?? { nil }
            self.playbackMediaInformationProvider = playbackMediaInformationProvider ?? {
                AsyncStream<PlaybackMediaInformation?> { continuation in
                    continuation.finish()
                }
            }
            self.playbackMetricsProvider = playbackMetricsProvider ?? { _ in nil }
        } else {
            let controller = PlaybackController()
            resolvedPlaybackEngine = controller
            self.playbackPresentationProvider = {
                await controller.presentationContext()
            }
            self.playbackMediaInformationProvider = {
                await controller.playbackMediaInformation()
            }
            self.playbackMetricsProvider = { window in
                await controller.playbackMetricsSnapshot(window: window)
            }
        }
        self.playbackEngine = resolvedPlaybackEngine
        self.libraryChanges = libraryChanges
        self.exposesAcceptanceMetrics = exposesAcceptanceMetrics
        self.exposesAcceptanceState = exposesAcceptanceState
        self.libraryStartup = libraryStartup
        self.foregroundRefreshDriver = foregroundRefreshDriver
        self.backgroundRefreshRegistrar = backgroundRefreshRegistrar

        let tuningSelection = PlaybackTuningSelectionController(
            engine: resolvedPlaybackEngine
        )
        playbackSettings.setTuningChangeHandler(tuningSelection.apply)
        // A stored buffer length has to reach the engine before the first stream
        // starts, otherwise the setting only takes effect once it is changed.
        tuningSelection.apply(playbackSettings.tuning)
    }

    static func live() -> Self {
        do {
            let libraryChanges = LibraryChangeSignal()
            let runtime = try makeProductionLibraryRuntime(
                onPersistedOutcome: { [weak libraryChanges] _, _ in
                    await MainActor.run {
                        libraryChanges?.notify()
                    }
                },
                onRefreshStarted: { [weak libraryChanges] profileID, resource in
                    await MainActor.run {
                        libraryChanges?.notifyRefreshStarted(
                            profileID: profileID,
                            resource: resource
                        )
                    }
                }
            )

            return make(
                repository: runtime.repository,
                refresh: runtime.refresh,
                libraryChanges: libraryChanges,
                libraryStartup: LibraryStartup(maintenance: runtime.maintenance),
                prepare: runtime.prepare
            )
        } catch {
            // The UI can only say "storage is unavailable"; without this the
            // real reason never leaves the process and the failure is
            // undiagnosable on a device.
            logger.error(
                "Persistent library store unavailable (\(String(describing: type(of: error)), privacy: .public))."
            )
            let repository = UnavailableLibraryRepository()
            let loadProfiles: ForegroundRefreshDriver.LoadProfiles = {
                throw ProductionDependencyError.libraryUnavailable
            }
            let refresh: ForegroundRefreshDriver.Refresh = { _, _, _ in [] }
            return Self(
                libraryStartup: LibraryStartup {
                    throw ProductionDependencyError.libraryUnavailable
                },
                foregroundRefreshDriver: ForegroundRefreshDriver(
                    loadProfiles: loadProfiles,
                    refresh: refresh,
                    reportStatus: { _ in }
                ),
                backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                    loadProfiles: loadProfiles,
                    refresh: refresh,
                    reportStatus: { _ in }
                ),
                repository: repository,
                refresh: refresh,
                isLibraryAvailable: false
            )
        }
    }

    static func production() -> Self {
        live()
    }

    #if DEBUG
    static func acceptance() -> Self {
        do {
            let container = try VPlayerModelContainer.make(inMemory: true)
            let repository = SwiftDataLibraryStore(modelContainer: container)
            let libraryChanges = LibraryChangeSignal()
            let coordinator = RefreshCoordinator(
                repository: repository,
                downloader: URLSessionBoundedDownloader(),
                onPersistedOutcome: { [weak libraryChanges] _, _ in
                    await MainActor.run { libraryChanges?.notify() }
                },
                onRefreshStarted: { [weak libraryChanges] profileID, resource in
                    await MainActor.run {
                        libraryChanges?.notifyRefreshStarted(
                            profileID: profileID,
                            resource: resource
                        )
                    }
                }
            )
            let refresh: ForegroundRefreshDriver.Refresh = { profileID, resources, trigger in
                await coordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            }
            return make(
                repository: repository,
                refresh: refresh,
                libraryChanges: libraryChanges,
                libraryStartup: LibraryStartup {
                    try await repository.purgeUnreferencedSnapshots()
                },
                exposesAcceptanceMetrics: true,
                exposesAcceptanceState: true
            )
        } catch {
            // Acceptance runs must never silently fall back to the on-disk
            // production store; fail loudly instead so the harness surfaces it.
            fatalError("Acceptance dependencies require an in-memory store; container creation failed: \(error)")
        }
    }

    private static func uiTestMediaInformationProvider(
        for playbackFixture: String?
    ) -> PlaybackMediaInformationProvider? {
        guard playbackFixture == "media-information" else { return nil }
        return {
            AsyncStream { continuation in
                continuation.yield(.some(PlaybackMediaInformation(
                    width: 1_920,
                    height: 1_080,
                    scanMode: .interlaced,
                    sourceFrameRate: MediaRational(num: 25, den: 1),
                    outputFrameRate: 50,
                    isSmoothMotionEnhanced: true
                )))
                continuation.finish()
            }
        }
    }

    static func uiTesting(playbackFixture: String? = nil) -> Self {
        do {
            let container = try VPlayerModelContainer.make(inMemory: true)
            let repository = SwiftDataLibraryStore(modelContainer: container)
            let seeder = SeededLibrarySeeder(repository: repository)
            let libraryChanges = LibraryChangeSignal()
            let refresh = fixtureRefresh(
                repository: repository,
                libraryChanges: libraryChanges
            )
            let loadProfiles: ForegroundRefreshDriver.LoadProfiles = {
                try await repository.profiles()
            }
            return Self(
                libraryStartup: LibraryStartup {
                    try await repository.purgeUnreferencedSnapshots()
                },
                foregroundRefreshDriver: ForegroundRefreshDriver(
                    loadProfiles: loadProfiles,
                    refresh: refresh,
                    reportStatus: { _ in }
                ),
                backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                    scheduler: InertBackgroundRefreshScheduler(),
                    loadProfiles: loadProfiles,
                    refresh: refresh,
                    reportStatus: { _ in }
                ),
                repository: repository,
                refresh: refresh,
                prepare: {
                    await seeder.seed()
                },
                playbackEngine: UITestPlaybackEngine(fixture: playbackFixture),
                playbackPresentationProvider: { nil },
                playbackMediaInformationProvider: uiTestMediaInformationProvider(
                    for: playbackFixture
                ),
                exposesAcceptanceState: true,
                libraryChanges: libraryChanges
            )
        } catch {
            let repository = UnavailableLibraryRepository()
            let refresh: Refresh = { _, resources, _ in
                resources.map { RefreshOutcome(resource: $0, succeeded: false, message: nil) }
            }
            return Self(
                libraryStartup: LibraryStartup {},
                foregroundRefreshDriver: ForegroundRefreshDriver(
                    loadProfiles: { [] },
                    refresh: refresh,
                    reportStatus: { _ in }
                ),
                backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                    scheduler: InertBackgroundRefreshScheduler(),
                    loadProfiles: { [] },
                    refresh: refresh,
                    reportStatus: { _ in }
                ),
                repository: repository,
                refresh: refresh,
                playbackEngine: UITestPlaybackEngine(fixture: playbackFixture),
                playbackPresentationProvider: { nil },
                playbackMediaInformationProvider: uiTestMediaInformationProvider(
                    for: playbackFixture
                ),
                exposesAcceptanceState: true
            )
        }
    }
    #endif

    @discardableResult
    func start() async -> LibraryStartupOutcome {
        await libraryStartup.start()
    }

    @discardableResult
    func openInitialLibrary(using model: AppModel) async -> Bool {
        do {
            try await prepare()
        } catch {
            logger.error(
                "Initial library preparation failed (\(String(describing: type(of: error)), privacy: .public))."
            )
            return false
        }
        guard !Task.isCancelled else { return false }

        _ = await model.reload()
        let didApplyLibrarySnapshot = await model.waitForLibraryReloadsToSettle()
        guard !Task.isCancelled, didApplyLibrarySnapshot else { return false }

        foregroundRefreshDriver.initialLibraryLoadDidComplete()
        // Orphan cleanup is maintenance, not a prerequisite for rendering a
        // cached library. Start it only after the first stable snapshot is
        // visible and foreground refresh can recover network-backed data.
        launch()
        return true
    }

    func launch() {
        Task(priority: .utility) {
            _ = await start()
        }
    }

    private static func make(
        repository: any LibraryRepository & RefreshSnapshotCommitting,
        refresh: @escaping Refresh,
        libraryChanges: LibraryChangeSignal,
        libraryStartup: LibraryStartup,
        prepare: @escaping Prepare = {},
        exposesAcceptanceMetrics: Bool = false,
        exposesAcceptanceState: Bool = false
    ) -> Self {
        let loadProfiles: ForegroundRefreshDriver.LoadProfiles = {
            try await repository.profiles()
        }
        return Self(
            libraryStartup: libraryStartup,
            foregroundRefreshDriver: ForegroundRefreshDriver(
                loadProfiles: loadProfiles,
                refresh: refresh,
                reportStatus: { _ in }
            ),
            backgroundRefreshRegistrar: BackgroundRefreshRegistrar(
                loadProfiles: loadProfiles,
                refresh: refresh,
                reportStatus: { _ in }
            ),
            repository: repository,
            refresh: refresh,
            prepare: prepare,
            exposesAcceptanceMetrics: exposesAcceptanceMetrics,
            exposesAcceptanceState: exposesAcceptanceState,
            libraryChanges: libraryChanges
        )
    }

    private static func fixtureRefresh(
        repository: any LibraryRepository,
        libraryChanges: LibraryChangeSignal
    ) -> Refresh {
        { profileID, resources, _ in
            let timestamp = Date()
            var outcomes: [RefreshOutcome] = []
            for resource in resources.sorted(by: { $0.rawValue < $1.rawValue }) {
                let attemptID = UUID()
                let outcome: RefreshOutcome
                do {
                    try await repository.recordAttempt(
                        profileID: profileID,
                        resource: resource,
                        at: timestamp,
                        attemptID: attemptID
                    )
                    try await repository.recordSuccess(
                        profileID: profileID,
                        resource: resource,
                        at: timestamp,
                        attemptID: attemptID
                    )
                    outcome = RefreshOutcome(
                        resource: resource,
                        succeeded: true,
                        message: nil,
                        attemptID: attemptID
                    )
                } catch {
                    let message = "测试刷新失败。"
                    try? await repository.recordFailure(
                        profileID: profileID,
                        resource: resource,
                        summary: message,
                        at: timestamp,
                        attemptID: attemptID
                    )
                    outcome = RefreshOutcome(
                        resource: resource,
                        succeeded: false,
                        message: message,
                        attemptID: attemptID
                    )
                }
                outcomes.append(outcome)
                await MainActor.run {
                    libraryChanges.notify()
                }
            }
            return outcomes
        }
    }
}

typealias VPlayerDependencies = AppDependencies

private let logger = Logger(subsystem: "com.vforce.vplayer", category: "AppDependencies")

private enum ProductionDependencyError: Error {
    case libraryUnavailable
}

#if DEBUG
@MainActor
private final class InertBackgroundRefreshScheduler: BackgroundRefreshScheduling {
    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool {
        _ = identifier
        _ = handler
        return true
    }

    func cancel(identifier: String) {
        _ = identifier
    }

    func submit(identifier: String, earliestBeginDate: Date) throws {
        _ = identifier
        _ = earliestBeginDate
    }
}

private actor SeededLibrarySeeder {
    private let repository: any LibraryRepository
    private var didSeed = false

    init(repository: any LibraryRepository) {
        self.repository = repository
    }

    func seed() async {
        guard !didSeed else { return }
        didSeed = true
        let now = Date()

        do {
            // Channel identity hashes the stream URL, so every fixture channel
            // needs its own or the playlist install rejects the duplicate.
            guard let relayStreamURL = URL(
                string: "https://relay.fixture.invalid/rtp/239.1.1.1:5000"
            ), let multicastStreamURL = URL(string: "udp://239.1.1.1:5000"),
                let secondGroupStreamURL = URL(
                    string: "https://relay.fixture.invalid/rtp/239.1.1.2:5000"
                ), let ungroupedStreamURL = URL(
                    string: "https://relay.fixture.invalid/rtp/239.1.1.3:5000"
                ) else {
                return
            }
            let profile = try await repository.createProfile(
                SourceProfileInput(
                    name: "测试播放列表",
                    m3uURLString: "https://fixture.invalid/playlist.m3u",
                    epgURLString: "https://fixture.invalid/epg.xml",
                    m3uRefreshInterval: .manual,
                    epgRefreshInterval: .manual
                ).validated(),
                now: now
            )
            try await repository.installPlaylist(
                profileID: profile.id,
                channels: [
                    Channel(
                        sourceProfileID: profile.id,
                        displayName: "测试频道",
                        streamURL: relayStreamURL,
                        tvgID: "fixture-channel",
                        tvgName: "测频道",
                        logoURL: nil,
                        groupTitle: "测试分组",
                        attributes: ["ui-test-id": "channel.http"],
                        order: 0
                    ),
                    Channel(
                        sourceProfileID: profile.id,
                        displayName: "组播频道",
                        streamURL: multicastStreamURL,
                        tvgID: nil,
                        tvgName: nil,
                        logoURL: nil,
                        groupTitle: "测试分组",
                        attributes: ["ui-test-id": "channel.udp"],
                        order: 1
                    ),
                    // A second group makes the group rail real, and a blank
                    // group-title covers the playlists that leave it out.
                    Channel(
                        sourceProfileID: profile.id,
                        displayName: "另一组频道",
                        streamURL: secondGroupStreamURL,
                        tvgID: nil,
                        tvgName: nil,
                        logoURL: nil,
                        groupTitle: "第二分组",
                        attributes: ["ui-test-id": "channel.grouped"],
                        order: 2
                    ),
                    Channel(
                        sourceProfileID: profile.id,
                        displayName: "无分组频道",
                        streamURL: ungroupedStreamURL,
                        tvgID: nil,
                        tvgName: nil,
                        logoURL: nil,
                        groupTitle: "   ",
                        attributes: ["ui-test-id": "channel.ungrouped"],
                        order: 3
                    ),
                ],
                fetchedAt: now
            )
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("vplayer-ui-fixture-\(UUID().uuidString).xml")
            try Self.epgData(now: now).write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            _ = try await repository.installEPG(
                profileID: profile.id,
                fileURL: temporaryURL,
                fetchedAt: now
            )
        } catch {
            return
        }
    }

    private static func epgData(now: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let currentStart = formatter.string(from: now.addingTimeInterval(-900))
        let currentStop = formatter.string(from: now.addingTimeInterval(900))
        let nextStop = formatter.string(from: now.addingTimeInterval(2_700))
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="fixture-channel"><display-name>测试频道</display-name></channel>
          <programme channel="fixture-channel" start="\(currentStart)" stop="\(currentStop)">
            <title>正在播出</title>
          </programme>
          <programme channel="fixture-channel" start="\(currentStop)" stop="\(nextStop)">
            <title>接下来</title>
          </programme>
        </tv>
        """.utf8)
    }
}
#endif

private actor UnavailableLibraryRepository: LibraryRepository {
    func profiles() throws -> [SourceProfile] { throw ProductionDependencyError.libraryUnavailable }
    func activeProfile() throws -> SourceProfile? { throw ProductionDependencyError.libraryUnavailable }
    func createProfile(_ input: ValidatedSourceProfileInput, now: Date) throws -> SourceProfile {
        _ = input
        _ = now
        throw ProductionDependencyError.libraryUnavailable
    }
    func updateProfile(id: UUID, input: ValidatedSourceProfileInput, now: Date) throws {
        _ = id
        _ = input
        _ = now
        throw ProductionDependencyError.libraryUnavailable
    }
    func deleteProfile(id: UUID) throws { _ = id; throw ProductionDependencyError.libraryUnavailable }
    func setActiveProfile(id: UUID) throws { _ = id; throw ProductionDependencyError.libraryUnavailable }
    func channels(profileID: UUID) throws -> [Channel] {
        _ = profileID
        throw ProductionDependencyError.libraryUnavailable
    }
    func epgChannels(profileID: UUID) throws -> [EPGChannel] {
        _ = profileID
        throw ProductionDependencyError.libraryUnavailable
    }
    func epgProgrammeCount(profileID: UUID) async throws -> Int {
        _ = profileID
        throw ProductionDependencyError.libraryUnavailable
    }
    func epgCoverageEnd(profileID: UUID) async throws -> Date? {
        _ = profileID
        throw ProductionDependencyError.libraryUnavailable
    }
    func programmes(
        profileID: UUID,
        xmltvChannelID: String,
        overlapping: Range<Date>
    ) throws -> [Programme] {
        _ = profileID
        _ = xmltvChannelID
        _ = overlapping
        throw ProductionDependencyError.libraryUnavailable
    }
    func manualMapping(profileID: UUID, channelID: String) throws -> ManualEPGMapping? {
        _ = profileID
        _ = channelID
        throw ProductionDependencyError.libraryUnavailable
    }
    func manualMappings(profileID: UUID) throws -> [String: String] {
        _ = profileID
        throw ProductionDependencyError.libraryUnavailable
    }
    func programmes(
        profileID: UUID,
        xmltvChannelIDs: Set<String>,
        overlapping: Range<Date>
    ) throws -> [String: [Programme]] {
        _ = profileID
        _ = xmltvChannelIDs
        _ = overlapping
        throw ProductionDependencyError.libraryUnavailable
    }
    func setManualMapping(profileID: UUID, channelID: String, xmltvChannelID: String?) throws {
        _ = profileID
        _ = channelID
        _ = xmltvChannelID
        throw ProductionDependencyError.libraryUnavailable
    }
    func setManualMappingIfCurrentChannel(
        profileID: UUID,
        channelID: String,
        xmltvChannelID: String?
    ) throws -> Bool {
        _ = profileID
        _ = channelID
        _ = xmltvChannelID
        throw ProductionDependencyError.libraryUnavailable
    }
    func installPlaylist(profileID: UUID, channels: [Channel], fetchedAt: Date) throws {
        _ = profileID
        _ = channels
        _ = fetchedAt
        throw ProductionDependencyError.libraryUnavailable
    }
    func installEPG(profileID: UUID, fileURL: URL, fetchedAt: Date) throws -> XMLTVParseSummary {
        _ = profileID
        _ = fileURL
        _ = fetchedAt
        throw ProductionDependencyError.libraryUnavailable
    }
    func recordAttempt(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) throws {
        _ = profileID
        _ = resource
        _ = at
        _ = attemptID
        throw ProductionDependencyError.libraryUnavailable
    }
    func recordSuccess(
        profileID: UUID,
        resource: RefreshResource,
        at: Date,
        attemptID: UUID?
    ) throws {
        _ = profileID
        _ = resource
        _ = at
        _ = attemptID
        throw ProductionDependencyError.libraryUnavailable
    }
    func recordFailure(
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at: Date,
        attemptID: UUID?
    ) throws {
        _ = profileID
        _ = resource
        _ = summary
        _ = at
        _ = attemptID
        throw ProductionDependencyError.libraryUnavailable
    }
    func purgeUnreferencedSnapshots() throws { throw ProductionDependencyError.libraryUnavailable }
}
