// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

@preconcurrency import BackgroundTasks
import Foundation
import VPlayerCore

protocol BackgroundRefreshTask: AnyObject, Sendable {
    @MainActor func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void)
    @MainActor func clearExpirationHandler()
    @MainActor func setTaskCompleted(success: Bool)
}

@MainActor
protocol BackgroundRefreshScheduling: AnyObject, Sendable {
    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool
    func cancel(identifier: String)
    func submit(identifier: String, earliestBeginDate: Date) async throws
}

@MainActor
final class BackgroundRefreshRegistrar {
    static let identifier = "com.vforce.vplayer.refresh"

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
    private var submissionTask: Task<Void, any Error>?
    private var schedulingRevision = UUID()
    private var prefersReducedResourceUsage = false

    func setPrefersReducedResourceUsage(_ preferred: Bool) {
        // Signal changes must not launch a refresh or another submission.
        prefersReducedResourceUsage = preferred
    }

    private func beginScheduling() -> UUID {
        let revision = UUID()
        schedulingRevision = revision
        return revision
    }

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
        let revision = beginScheduling()
        schedulingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let profiles = try await loadProfiles()
                try Task.checkCancellation()
                try await submitNext(profiles: profiles, revision: revision)
            } catch is CancellationError {
                return
            } catch {
                guard revision == schedulingRevision, !Task.isCancelled else { return }
                reportStatus(Self.sanitizedSchedulingError(error))
            }
        }
    }

    private func handle(_ task: any BackgroundRefreshTask) {
        let loadProfiles = loadProfiles
        let refresh = refresh
        let planner = planner
        let now = now
        let reportStatus = reportStatus
        let execution = BackgroundRefreshExecution(task: task)
        task.setExpirationHandler {
            execution.expire()
        }
        // A latched system expiration is delivered synchronously above. Such
        // an execution has no replacement intent and must not supersede a
        // live caller that is loading profiles or awaiting native submission.
        guard !execution.isCompleted else { return }
        let revision = beginScheduling()
        execution.start { [weak self] in
            guard let self else { return false }
            do {
                let profiles = try await loadProfiles()
                try Task.checkCancellation()

                var succeeded = true
                do {
                    try await self.submitNext(profiles: profiles, revision: revision)
                } catch is CancellationError {
                    try Task.checkCancellation()
                } catch {
                    try Task.checkCancellation()
                    succeeded = false
                    if revision == self.schedulingRevision {
                        reportStatus(Self.sanitizedSchedulingError(error))
                    }
                }

                let refreshDate = now()
                for profile in profiles {
                    try Task.checkCancellation()
                    if self.prefersReducedResourceUsage { break }
                    let resources = planner.dueResources(for: profile, now: refreshDate)
                    guard !resources.isEmpty else { continue }
                    let outcomes = await refresh(profile.id, resources, .background)
                    succeeded = succeeded && outcomes.allSatisfy(\.succeeded)
                }
                return succeeded
            } catch is CancellationError {
                return false
            } catch {
                guard !Task.isCancelled, revision == self.schedulingRevision else { return false }
                reportStatus(Self.sanitizedProfileLoadError(error))
                return false
            }
        }
    }

    private func submitNext(profiles: [SourceProfile], revision: UUID) async throws {
        try Task.checkCancellation()
        guard revision == schedulingRevision else { throw CancellationError() }
        // Coalesce callers onto the one physical operation; obsolete revisions
        // never create a chain of queued native submission tasks.
        while let previous = submissionTask {
            _ = try? await previous.value
            try Task.checkCancellation()
            guard revision == schedulingRevision else { throw CancellationError() }
        }
        let submission = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { self.submissionTask = nil }
            guard revision == self.schedulingRevision else { throw CancellationError() }
            // Transfer the pending request only when the latest viable caller
            // reaches the settled physical slot. A successor may expire while
            // loading or waiting, so intent alone must not remove the fallback.
            self.scheduler.cancel(identifier: Self.identifier)
            let now = self.now()
            guard var date = self.planner.nextBackgroundDate(for: profiles, now: now) else {
                return
            }
            if self.prefersReducedResourceUsage {
                date = max(date, now.addingTimeInterval(60 * 60))
            }
            try await self.scheduler.submit(identifier: Self.identifier, earliestBeginDate: date)
            guard revision == self.schedulingRevision else {
                // The old caller is obsolete, but its successful pending request
                // remains a fallback until a live successor cancels/replaces it
                // above. Cancelling here could strand an expired successor.
                throw CancellationError()
            }
        }
        submissionTask = submission
        try await submission.value
        try Task.checkCancellation()
    }

    private static func sanitizedSchedulingError(_ error: any Error) -> String {
        return "无法安排后台刷新：\(ErrorDiagnosticSnapshot(error).summary)"
    }

    private static func sanitizedProfileLoadError(_ error: any Error) -> String {
        return "后台刷新无法读取源配置：\(ErrorDiagnosticSnapshot(error).summary)"
    }
}

@MainActor
private final class BackgroundRefreshExecution {
    private let task: any BackgroundRefreshTask
    private var workTask: Task<Void, Never>?
    private(set) var isCompleted = false

    init(task: any BackgroundRefreshTask) {
        self.task = task
    }

    func start(work: @escaping @MainActor @Sendable () async -> Bool) {
        guard !isCompleted else { return }
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
    private let handoff = SystemBackgroundRefreshTaskHandoff()

    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool {
        let handoff = handoff
        return BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handoff.handoff(
                systemTask: BGAppRefreshTaskSystemTask(appRefreshTask),
                handler: handler
            )
        }
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    func submit(identifier: String, earliestBeginDate: Date) async throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }
}

protocol SystemBackgroundRefreshSystemTask: AnyObject, Sendable {
    func installSystemExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    @MainActor func clearSystemExpirationHandler()
    @MainActor func completeSystemTask(success: Bool)
}

final class SystemBackgroundRefreshTaskHandoff: Sendable {
    typealias MainActorDispatch = @Sendable (
        @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private let mainActorDispatch: MainActorDispatch

    init(
        mainActorDispatch: @escaping MainActorDispatch = { action in
            Task { @MainActor in
                action()
            }
        }
    ) {
        self.mainActorDispatch = mainActorDispatch
    }

    func handoff(
        systemTask: any SystemBackgroundRefreshSystemTask,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) {
        let taskBridge = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {
                systemTask.clearSystemExpirationHandler()
            },
            completeSystemTask: { success in
                systemTask.completeSystemTask(success: success)
            }
        )
        systemTask.installSystemExpirationHandler { [weak taskBridge] in
            taskBridge?.systemDidExpire()
        }
        mainActorDispatch {
            handler(taskBridge)
        }
    }
}

private final class BGAppRefreshTaskSystemTask: SystemBackgroundRefreshSystemTask, @unchecked Sendable {
    private let task: BGAppRefreshTask

    init(_ task: BGAppRefreshTask) {
        self.task = task
    }

    func installSystemExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    @MainActor
    func clearSystemExpirationHandler() {
        task.expirationHandler = nil
    }

    @MainActor
    func completeSystemTask(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

final class SystemBackgroundRefreshTaskBridge: BackgroundRefreshTask, @unchecked Sendable {
    typealias MainActorAction = @MainActor @Sendable () -> Void
    typealias CompleteSystemTask = @MainActor @Sendable (Bool) -> Void

    private struct State {
        var didSystemExpire = false
        var didDeliverExpiration = false
        var didClearSystemExpirationHandler = false
        var didComplete = false
        var expirationHandler: MainActorAction?
    }

    private let lock = NSLock()
    private var state = State()
    private let clearSystemExpirationHandler: MainActorAction
    private let completeSystemTask: CompleteSystemTask

    init(
        clearSystemExpirationHandler: @escaping MainActorAction,
        completeSystemTask: @escaping CompleteSystemTask
    ) {
        self.clearSystemExpirationHandler = clearSystemExpirationHandler
        self.completeSystemTask = completeSystemTask
    }

    nonisolated func systemDidExpire() {
        let handler: MainActorAction? = withLock { state in
            guard !state.didSystemExpire else { return nil }
            state.didSystemExpire = true
            guard
                !state.didComplete,
                !state.didDeliverExpiration,
                let handler = state.expirationHandler
            else {
                return nil
            }
            state.didDeliverExpiration = true
            return handler
        }

        guard let handler else { return }
        Task { @MainActor in
            handler()
        }
    }

    @MainActor
    func setExpirationHandler(_ handler: @escaping MainActorAction) {
        let pendingHandler: MainActorAction? = withLock { state in
            guard !state.didComplete else { return nil }
            state.expirationHandler = handler
            guard state.didSystemExpire, !state.didDeliverExpiration else {
                return nil
            }
            state.didDeliverExpiration = true
            return handler
        }

        pendingHandler?()
    }

    @MainActor
    func clearExpirationHandler() {
        let shouldClear = withLock { state in
            state.expirationHandler = nil
            guard !state.didClearSystemExpirationHandler else { return false }
            state.didClearSystemExpirationHandler = true
            return true
        }

        if shouldClear {
            clearSystemExpirationHandler()
        }
    }

    @MainActor
    func setTaskCompleted(success: Bool) {
        let completion = withLock { state -> Bool? in
            guard !state.didComplete else { return nil }
            state.didComplete = true
            state.expirationHandler = nil
            return success && !state.didSystemExpire
        }

        if let completion {
            completeSystemTask(completion)
        }
    }

    private nonisolated func withLock<Result>(
        _ body: (inout State) -> Result
    ) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
