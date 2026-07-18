// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

@preconcurrency import BackgroundTasks
import Foundation
import VPlayerCore

@MainActor
protocol BackgroundRefreshTask: AnyObject {
    func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void)
    func clearExpirationHandler()
    func setTaskCompleted(success: Bool)
}

@MainActor
protocol BackgroundRefreshScheduling: AnyObject, Sendable {
    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool
    func cancel(identifier: String)
    func submit(identifier: String, earliestBeginDate: Date) throws
}

@MainActor
final class BackgroundRefreshRegistrar {
    static let identifier = "com.vplayer.app.refresh"

    typealias LoadProfiles = @Sendable () async throws -> [SourceProfile]
    typealias Refresh = @Sendable (
        UUID,
        Set<RefreshResource>,
        RefreshTrigger
    ) async -> [RefreshOutcome]
    typealias ReportStatus = @MainActor @Sendable (String) -> Void

    private let scheduler: any BackgroundRefreshScheduling
    private let loadProfiles: LoadProfiles
    private let refresh: Refresh
    private let planner: RefreshSchedulePlanner
    private let now: @Sendable () -> Date
    private let reportStatus: ReportStatus
    private var isRegistered = false
    private var schedulingTask: Task<Void, Never>?

    init(
        scheduler: any BackgroundRefreshScheduling = SystemBackgroundRefreshScheduler(),
        loadProfiles: @escaping LoadProfiles,
        refresh: @escaping Refresh,
        planner: RefreshSchedulePlanner = RefreshSchedulePlanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        reportStatus: @escaping ReportStatus
    ) {
        self.scheduler = scheduler
        self.loadProfiles = loadProfiles
        self.refresh = refresh
        self.planner = planner
        self.now = now
        self.reportStatus = reportStatus
    }

    func register() {
        guard !isRegistered else { return }
        let registered = scheduler.register(identifier: Self.identifier) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(task)
        }
        if registered {
            isRegistered = true
        } else {
            reportStatus("无法注册后台刷新。")
        }
    }

    func scheduleNext() {
        schedulingTask?.cancel()

        let scheduler = scheduler
        let loadProfiles = loadProfiles
        let planner = planner
        let now = now
        let reportStatus = reportStatus
        schedulingTask = Task { @MainActor in
            do {
                let profiles = try await loadProfiles()
                try Task.checkCancellation()
                try Self.submitNext(
                    profiles: profiles,
                    scheduler: scheduler,
                    planner: planner,
                    now: now()
                )
            } catch is CancellationError {
                return
            } catch {
                reportStatus(Self.sanitizedSchedulingError(error))
            }
        }
    }

    private func handle(_ task: any BackgroundRefreshTask) {
        let scheduler = scheduler
        let loadProfiles = loadProfiles
        let refresh = refresh
        let planner = planner
        let now = now
        let reportStatus = reportStatus
        let execution = BackgroundRefreshExecution(task: task)
        task.setExpirationHandler {
            execution.expire()
        }
        execution.start {
            do {
                let profiles = try await loadProfiles()
                try Task.checkCancellation()

                var succeeded = true
                do {
                    try await MainActor.run {
                        try Self.submitNext(
                            profiles: profiles,
                            scheduler: scheduler,
                            planner: planner,
                            now: now()
                        )
                    }
                } catch {
                    succeeded = false
                    await MainActor.run {
                        reportStatus(Self.sanitizedSchedulingError(error))
                    }
                }

                let refreshDate = now()
                for profile in profiles {
                    try Task.checkCancellation()
                    let resources = planner.dueResources(for: profile, now: refreshDate)
                    guard !resources.isEmpty else { continue }
                    let outcomes = await refresh(profile.id, resources, .background)
                    succeeded = succeeded && outcomes.allSatisfy(\.succeeded)
                }
                return succeeded
            } catch is CancellationError {
                return false
            } catch {
                await MainActor.run {
                    reportStatus(Self.sanitizedProfileLoadError(error))
                }
                return false
            }
        }
    }

    private static func submitNext(
        profiles: [SourceProfile],
        scheduler: any BackgroundRefreshScheduling,
        planner: RefreshSchedulePlanner,
        now: Date
    ) throws {
        scheduler.cancel(identifier: identifier)
        guard let earliestBeginDate = planner.nextBackgroundDate(for: profiles, now: now) else {
            return
        }
        try scheduler.submit(identifier: identifier, earliestBeginDate: earliestBeginDate)
    }

    private static func sanitizedSchedulingError(_ error: any Error) -> String {
        _ = error
        return "无法安排后台刷新，系统稍后可能再次提供刷新机会。"
    }

    private static func sanitizedProfileLoadError(_ error: any Error) -> String {
        _ = error
        return "后台刷新无法读取源配置。"
    }
}

@MainActor
private final class BackgroundRefreshExecution {
    private let task: any BackgroundRefreshTask
    private var workTask: Task<Void, Never>?
    private var isCompleted = false

    init(task: any BackgroundRefreshTask) {
        self.task = task
    }

    func start(work: @escaping @Sendable () async -> Bool) {
        workTask = Task { @MainActor [weak self] in
            let succeeded = await work()
            guard let self else { return }
            self.finish(success: succeeded && !Task.isCancelled)
        }
    }

    func expire() {
        workTask?.cancel()
        finish(success: false)
    }

    private func finish(success: Bool) {
        guard !isCompleted else { return }
        isCompleted = true
        task.clearExpirationHandler()
        task.setTaskCompleted(success: success)
    }
}

@MainActor
private final class SystemBackgroundRefreshScheduler: BackgroundRefreshScheduling {
    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let taskBox = UncheckedSendableBox(appRefreshTask)
            Task { @MainActor in
                handler(SystemBackgroundRefreshTask(task: taskBox.value))
            }
        }
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    func submit(identifier: String, earliestBeginDate: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }
}

@MainActor
private final class SystemBackgroundRefreshTask: BackgroundRefreshTask {
    private let task: BGAppRefreshTask

    init(task: BGAppRefreshTask) {
        self.task = task
    }

    func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        task.expirationHandler = {
            Task { @MainActor in
                handler()
            }
        }
    }

    func clearExpirationHandler() {
        task.expirationHandler = nil
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
