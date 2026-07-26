// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import OSLog
import VPlayerCore
import VPlayerPlayback

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

@MainActor
struct AppDependencies {
    typealias Refresh = AppModel.Refresh
    typealias Prepare = @Sendable () async -> Void
    typealias PlaybackPresentationProvider = @Sendable () async -> PlaybackPresentationContext?
    typealias PlaybackMetricsProvider = @Sendable (Duration) async -> PlaybackMetricsSnapshot?

    let repository: any LibraryRepository
    let refresh: Refresh
    let prepare: Prepare
    let playbackSettings: PlaybackSettingsStore
    let channelBrowsingSettings: ChannelBrowsingSettingsStore
    let playbackEngine: any PlaybackEngine
    let playbackPresentationProvider: PlaybackPresentationProvider
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
            self.playbackMetricsProvider = playbackMetricsProvider ?? { _ in nil }
        } else {
            let controller = PlaybackController()
            resolvedPlaybackEngine = controller
            self.playbackPresentationProvider = {
                await controller.presentationContext()
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
            let container = try VPlayerModelContainer.make()
            let repository = SwiftDataLibraryStore(
                modelContainer: container,
                profileMirror: SourceProfileMirror(defaults: .standard)
            )
            let libraryChanges = LibraryChangeSignal()
            let coordinator = RefreshCoordinator(
                repository: repository,
                downloader: URLSessionBoundedDownloader(),
                onPersistedOutcome: { [weak libraryChanges] _, _ in
                    await MainActor.run {
                        libraryChanges?.notify()
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
                libraryStartup: LibraryStartup { [weak libraryChanges] in
                    // tvOS can delete the Caches-resident store between
                    // launches. Everything else in it is refetchable, so this
                    // is the one thing that has to be put back, and anything
                    // that already read the empty library needs telling.
                    if try await repository.synchronizeProfileMirror() > 0 {
                        logger.notice("Restored source profiles after a purged persistent store.")
                        await MainActor.run { libraryChanges?.notify() }
                    }
                    try await repository.purgeUnreferencedSnapshots()
                }
            )
        } catch {
            // The UI can only say "storage is unavailable"; without this the
            // real reason never leaves the process and the failure is
            // undiagnosable on a device.
            logger.error("Persistent library store unavailable: \(error, privacy: .public)")
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
                exposesAcceptanceState: true
            )
        }
    }
    #endif

    @discardableResult
    func start() async -> LibraryStartupOutcome {
        await libraryStartup.start()
    }

    func launch() {
        Task {
            _ = await start()
        }
    }

    private static func make(
        repository: any LibraryRepository & RefreshSnapshotCommitting,
        refresh: @escaping Refresh,
        libraryChanges: LibraryChangeSignal,
        libraryStartup: LibraryStartup,
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

private let logger = Logger(subsystem: "com.vplayer.app", category: "AppDependencies")

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
