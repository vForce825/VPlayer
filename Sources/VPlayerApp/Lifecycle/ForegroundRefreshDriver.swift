// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

@MainActor
final class ForegroundRefreshDriver {
    typealias LoadProfiles = @Sendable () async throws -> [SourceProfile]
    typealias Refresh = @Sendable (
        UUID,
        Set<RefreshResource>,
        RefreshTrigger
    ) async -> [RefreshOutcome]
    typealias Sleep = @Sendable () async throws -> Void
    typealias ReportStatus = @MainActor @Sendable (String) -> Void

    private let loadProfiles: LoadProfiles
    private let refresh: Refresh
    private let planner: RefreshSchedulePlanner
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let reportStatus: ReportStatus
    private var loopTask: Task<Void, Never>?
    private var isActive = false
    private(set) var isInitialLibraryLoadComplete = false

    init(
        loadProfiles: @escaping LoadProfiles,
        refresh: @escaping Refresh,
        planner: RefreshSchedulePlanner = RefreshSchedulePlanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleep = {
            try await ContinuousClock().sleep(for: .seconds(60))
        },
        reportStatus: @escaping ReportStatus
    ) {
        self.loadProfiles = loadProfiles
        self.refresh = refresh
        self.planner = planner
        self.now = now
        self.sleep = sleep
        self.reportStatus = reportStatus
    }

    func activate() {
        isActive = true
        startLoopIfReady()
    }

    /// Foreground refresh must not race the first library read. In particular,
    /// an overdue EPG can import thousands of rows and make the empty launch UI
    /// wait behind that write. RootView opens the cached snapshot first, then
    /// releases this one-way gate.
    func initialLibraryLoadDidComplete() {
        guard !isInitialLibraryLoadComplete else { return }
        isInitialLibraryLoadComplete = true
        startLoopIfReady()
    }

    private func startLoopIfReady() {
        guard isActive, isInitialLibraryLoadComplete else { return }
        loopTask?.cancel()

        let loadProfiles = loadProfiles
        let refresh = refresh
        let planner = planner
        let now = now
        let sleep = sleep
        let reportStatus = reportStatus
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let profiles = try await loadProfiles()
                    try Task.checkCancellation()
                    for profile in profiles {
                        try Task.checkCancellation()
                        let resources = planner.dueResources(for: profile, now: now())
                        guard !resources.isEmpty else { continue }
                        _ = await refresh(profile.id, resources, .foreground)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    reportStatus(Self.sanitizedProfileLoadError(error))
                }

                do {
                    try await sleep()
                } catch {
                    return
                }
            }
        }
    }

    func deactivate() {
        isActive = false
        loopTask?.cancel()
        loopTask = nil
    }

    private static func sanitizedProfileLoadError(_ error: any Error) -> String {
        switch error {
        case LibraryRepositoryError.profileNotFound:
            return "无法读取源配置：找不到源配置。"
        default:
            return "无法读取源配置。"
        }
    }
}
