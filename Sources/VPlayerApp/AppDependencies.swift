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

struct VPlayerDependencies: Sendable {
    typealias LibraryMaintenanceFactory = @Sendable () throws -> any LibrarySnapshotMaintenance

    let libraryStartup: LibraryStartup

    static func production(
        makeLibraryMaintenance: @escaping LibraryMaintenanceFactory = {
            let container = try VPlayerModelContainer.make()
            return SwiftDataLibraryStore(modelContainer: container)
        }
    ) -> Self {
        Self(libraryStartup: LibraryStartup {
            let maintenance = try makeLibraryMaintenance()
            try await maintenance.purgeUnreferencedSnapshots()
        })
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
