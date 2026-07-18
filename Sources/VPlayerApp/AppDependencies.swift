// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import VPlayerCore

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
struct VPlayerDependencies {
    let libraryStartup: LibraryStartup
    let foregroundRefreshDriver: ForegroundRefreshDriver
    let backgroundRefreshRegistrar: BackgroundRefreshRegistrar

    init(
        libraryStartup: LibraryStartup,
        foregroundRefreshDriver: ForegroundRefreshDriver,
        backgroundRefreshRegistrar: BackgroundRefreshRegistrar
    ) {
        self.libraryStartup = libraryStartup
        self.foregroundRefreshDriver = foregroundRefreshDriver
        self.backgroundRefreshRegistrar = backgroundRefreshRegistrar
    }

    static func production() -> Self {
        do {
            let container = try VPlayerModelContainer.make()
            let repository = SwiftDataLibraryStore(modelContainer: container)
            let coordinator = RefreshCoordinator(
                repository: repository,
                downloader: URLSessionBoundedDownloader()
            )
            let loadProfiles: ForegroundRefreshDriver.LoadProfiles = {
                try await repository.profiles()
            }
            let refresh: ForegroundRefreshDriver.Refresh = { profileID, resources, trigger in
                await coordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
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
                    loadProfiles: loadProfiles,
                    refresh: refresh,
                    reportStatus: { _ in }
                )
            )
        } catch {
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
                )
            )
        }
    }

    @discardableResult
    func start() async -> LibraryStartupOutcome {
        await libraryStartup.start()
    }

    func launch() {
        Task {
            _ = await start()
        }
    }
}

private enum ProductionDependencyError: Error {
    case libraryUnavailable
}
