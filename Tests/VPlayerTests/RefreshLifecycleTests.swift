// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer
@testable import VPlayerCore

@MainActor
final class RefreshLifecycleTests: XCTestCase {
    func testForegroundActivationReplacesAndDeactivationCancelsTheLoopTask() async {
        let probe = ForegroundLoopProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            now: Date.init,
            sleep: {
                await probe.recordSleepStarted()
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    await probe.recordCancellation()
                    throw error
                }
            },
            reportStatus: { _ in }
        )

        driver.activate()
        await probe.waitForSleepCount(1)
        driver.activate()
        await probe.waitForCancellationCount(1)
        await probe.waitForSleepCount(2)
        driver.deactivate()
        await probe.waitForCancellationCount(2)

        let cancellationCount = await probe.cancellationCount
        XCTAssertEqual(cancellationCount, 2)
    }

    func testForegroundReplacementDoesNotReportLoadErrorFromCancelledLoop() async {
        let loadGate = ForegroundLoadFailureGate()
        var reportedStatuses: [String] = []
        let driver = ForegroundRefreshDriver(
            loadProfiles: {
                try await loadGate.load()
            },
            refresh: { _, _, _ in [] },
            sleep: {
                try await Task.sleep(for: .seconds(3_600))
            },
            reportStatus: { message in
                reportedStatuses.append(message)
            }
        )

        driver.activate()
        await loadGate.waitForLoadCount(1)
        driver.activate()
        await loadGate.waitForLoadCount(2)
        await loadGate.failFirstLoad()
        await loadGate.waitUntilFirstLoadReturned()
        for _ in 0..<100 {
            await Task.yield()
        }
        driver.deactivate()

        XCTAssertEqual(reportedStatuses, [])
    }

    func testBackgroundRegistrationIsIdempotentAndSchedulesBeforeRefreshing() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        let probe = BackgroundWorkProbe()
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [profile] },
            refresh: { _, resources, trigger in
                await probe.recordRefresh(resources: resources, trigger: trigger)
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: true, message: nil)
                }
            },
            now: { now },
            reportStatus: { _ in }
        )

        registrar.register()
        registrar.register()
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await probe.waitUntilRefreshed()
        await eventually { task.completions.count == 1 }

        let refreshedResources = await probe.resources
        let refreshTrigger = await probe.trigger

        XCTAssertEqual(scheduler.registrationCount, 1)
        XCTAssertEqual(scheduler.cancelledIdentifiers, [BackgroundRefreshRegistrar.identifier])
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertEqual(scheduler.submissions.first?.identifier, BackgroundRefreshRegistrar.identifier)
        XCTAssertEqual(scheduler.submissions.first?.earliestBeginDate, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(refreshedResources, [.playlist])
        guard case .background? = refreshTrigger else {
            return XCTFail("Expected a background refresh trigger")
        }
        XCTAssertEqual(task.completions, [true])
    }

    func testBackgroundExpirationCancelsWorkAndCompletesExactlyOnce() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(now: now)
        let scheduler = BackgroundSchedulerSpy()
        let probe = BackgroundWorkProbe(suspendRefresh: true)
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [profile] },
            refresh: { _, resources, trigger in
                await probe.recordRefresh(resources: resources, trigger: trigger)
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    await probe.recordCancellation()
                }
                return []
            },
            now: { now },
            reportStatus: { _ in }
        )

        registrar.register()
        let task = BackgroundTaskSpy()
        try scheduler.launch(task)
        await probe.waitUntilRefreshed()
        task.expire()
        await probe.waitUntilCancelled()
        await eventually { task.completions.count == 1 }
        await Task.yield()

        let cancellationCount = await probe.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(task.completions, [false])
    }

    func testSystemExpirationBeforeMainActorLaunchCompletesFalseWithoutStartingWork() async throws {
        let scheduler = BackgroundSchedulerSpy()
        let loadProbe = BackgroundLoadProbe()
        var completions: [Bool] = []
        let bridge = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { success in
                completions.append(success)
            }
        )
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: {
                await loadProbe.recordLoad()
                return []
            },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )

        registrar.register()
        await Task.detached {
            bridge.systemDidExpire()
            bridge.systemDidExpire()
        }.value
        try scheduler.launch(bridge)
        await eventually { completions.count == 1 }
        for _ in 0..<100 {
            await Task.yield()
        }

        let loadCount = await loadProbe.loadCount
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(completions, [false])
    }

    func testSystemHandoffInstallsExpirationBeforeDispatchAndPreventsWorkAfterEarlyExpiration() async throws {
        let scheduler = BackgroundSchedulerSpy()
        let loadProbe = BackgroundLoadProbe()
        let systemTask = SystemTaskSurfaceSpy()
        let dispatchCapture = MainActorDispatchCapture()
        let handoff = SystemBackgroundRefreshTaskHandoff(
            mainActorDispatch: { action in
                dispatchCapture.capture(
                    action,
                    expirationInstalled: systemTask.hasExpirationHandler
                )
            }
        )
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: {
                await loadProbe.recordLoad()
                return []
            },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )

        registrar.register()
        handoff.handoff(systemTask: systemTask) { task in
            try? scheduler.launch(task)
        }

        XCTAssertTrue(systemTask.hasExpirationHandler)
        XCTAssertEqual(dispatchCapture.expirationInstalledBeforeCapture, true)
        XCTAssertEqual(dispatchCapture.count, 1)
        systemTask.expire()
        systemTask.expire()
        dispatchCapture.runFirst()
        await eventually { systemTask.completions.count == 1 }
        for _ in 0..<100 {
            await Task.yield()
        }

        let loadCount = await loadProbe.loadCount
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(systemTask.completions, [false])
    }

    func testSystemExpirationRacingSuccessCompletesFalseExactlyOnce() async {
        var expirationCount = 0
        var completions: [Bool] = []
        let bridge = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {},
            completeSystemTask: { success in
                completions.append(success)
            }
        )
        bridge.setExpirationHandler {
            expirationCount += 1
        }

        await Task.detached {
            bridge.systemDidExpire()
            bridge.systemDidExpire()
        }.value
        bridge.setTaskCompleted(success: true)
        await eventually { expirationCount == 1 }
        bridge.setTaskCompleted(success: false)

        XCTAssertEqual(expirationCount, 1)
        XCTAssertEqual(completions, [false])
    }

    func testSystemBridgeOrdinarySuccessCompletesOnceAndReleasesOwnership() async throws {
        let scheduler = BackgroundSchedulerSpy()
        var clearCount = 0
        var completions: [Bool] = []
        let registrar = BackgroundRefreshRegistrar(
            scheduler: scheduler,
            loadProfiles: { [] },
            refresh: { _, _, _ in [] },
            reportStatus: { _ in }
        )
        var bridge: SystemBackgroundRefreshTaskBridge? = SystemBackgroundRefreshTaskBridge(
            clearSystemExpirationHandler: {
                clearCount += 1
            },
            completeSystemTask: { success in
                completions.append(success)
            }
        )
        weak let weakBridge = bridge

        registrar.register()
        try scheduler.launch(bridge!)
        await eventually { completions.count == 1 }
        bridge = nil
        await eventually { weakBridge == nil }

        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(completions, [true])
        XCTAssertNil(weakBridge)
    }

    private func makeProfile(now: Date) -> SourceProfile {
        SourceProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Test",
            m3uURL: URL(string: "https://example.com/playlist.m3u")!,
            epgURL: URL(string: "https://example.com/epg.xml")!,
            m3uRefreshInterval: .hourly,
            epgRefreshInterval: .manual,
            m3uStatus: ResourceRefreshStatus(),
            epgStatus: ResourceRefreshStatus(),
            createdAt: now,
            updatedAt: now
        )
    }

    private func eventually(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

private actor ForegroundLoopProbe {
    private(set) var cancellationCount = 0
    private var sleepCount = 0

    func recordSleepStarted() {
        sleepCount += 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func waitForCancellationCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if cancellationCount >= expected { return }
            await Task.yield()
        }
    }

    func waitForSleepCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if sleepCount >= expected { return }
            await Task.yield()
        }
    }
}

private actor ForegroundLoadFailureGate {
    private var loadCount = 0
    private var firstLoadContinuation: CheckedContinuation<[SourceProfile], any Error>?
    private var firstLoadReturned = false

    func load() async throws -> [SourceProfile] {
        loadCount += 1
        guard loadCount == 1 else { return [] }

        do {
            return try await withCheckedThrowingContinuation { continuation in
                firstLoadContinuation = continuation
            }
        } catch {
            firstLoadReturned = true
            throw error
        }
    }

    func failFirstLoad() {
        firstLoadContinuation?.resume(throwing: LifecycleTestError.loadFailed)
        firstLoadContinuation = nil
    }

    func waitForLoadCount(_ expected: Int) async {
        for _ in 0..<1_000 {
            if loadCount >= expected { return }
            await Task.yield()
        }
    }

    func waitUntilFirstLoadReturned() async {
        for _ in 0..<1_000 {
            if firstLoadReturned { return }
            await Task.yield()
        }
    }
}

private actor BackgroundWorkProbe {
    private(set) var resources: Set<RefreshResource> = []
    private(set) var trigger: RefreshTrigger?
    private(set) var cancellationCount = 0
    private let suspendRefresh: Bool

    init(suspendRefresh: Bool = false) {
        self.suspendRefresh = suspendRefresh
    }

    func recordRefresh(resources: Set<RefreshResource>, trigger: RefreshTrigger) {
        self.resources = resources
        self.trigger = trigger
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func waitUntilRefreshed() async {
        for _ in 0..<1_000 {
            if trigger != nil { return }
            await Task.yield()
        }
    }

    func waitUntilCancelled() async {
        guard suspendRefresh else { return }
        for _ in 0..<1_000 {
            if cancellationCount > 0 { return }
            await Task.yield()
        }
    }
}

private actor BackgroundLoadProbe {
    private(set) var loadCount = 0

    func recordLoad() {
        loadCount += 1
    }
}

private final class SystemTaskSurfaceSpy: SystemBackgroundRefreshSystemTask, @unchecked Sendable {
    private let lock = NSLock()

    var hasExpirationHandler: Bool {
        withLock { $0.expirationHandler != nil }
    }

    var completions: [Bool] {
        withLock { $0.completionValues }
    }

    func installSystemExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        withLock { $0.expirationHandler = handler }
    }

    @MainActor
    func clearSystemExpirationHandler() {
        withLock { $0.expirationHandler = nil }
    }

    @MainActor
    func completeSystemTask(success: Bool) {
        withLock { $0.completionValues.append(success) }
    }

    func expire() {
        let handler = withLock { $0.expirationHandler }
        handler?()
    }

    private func withLock<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private struct State {
        var expirationHandler: (@Sendable () -> Void)?
        var completionValues: [Bool] = []
    }

    private var state = State()
}

private final class MainActorDispatchCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor @Sendable () -> Void] = []
    private var recordedExpirationInstalled: Bool?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }

    var expirationInstalledBeforeCapture: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedExpirationInstalled
    }

    func capture(
        _ action: @escaping @MainActor @Sendable () -> Void,
        expirationInstalled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        recordedExpirationInstalled = expirationInstalled
        actions.append(action)
    }

    @MainActor
    func runFirst() {
        let action: (@MainActor @Sendable () -> Void)?
        lock.lock()
        action = actions.isEmpty ? nil : actions.removeFirst()
        lock.unlock()
        action?()
    }
}

@MainActor
private final class BackgroundSchedulerSpy: BackgroundRefreshScheduling {
    struct Submission: Equatable {
        let identifier: String
        let earliestBeginDate: Date
    }

    private(set) var registrationCount = 0
    private(set) var cancelledIdentifiers: [String] = []
    private(set) var submissions: [Submission] = []
    private var handler: (@MainActor @Sendable (any BackgroundRefreshTask) -> Void)?

    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any BackgroundRefreshTask) -> Void
    ) -> Bool {
        registrationCount += 1
        self.handler = handler
        return true
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }

    func submit(identifier: String, earliestBeginDate: Date) throws {
        submissions.append(Submission(
            identifier: identifier,
            earliestBeginDate: earliestBeginDate
        ))
    }

    func launch(_ task: any BackgroundRefreshTask) throws {
        guard let handler else { throw LifecycleTestError.notRegistered }
        handler(task)
    }
}

@MainActor
private final class BackgroundTaskSpy: BackgroundRefreshTask {
    private var expirationHandler: (@MainActor @Sendable () -> Void)?
    private(set) var completions: [Bool] = []

    func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        expirationHandler = handler
    }

    func clearExpirationHandler() {
        expirationHandler = nil
    }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    func expire() {
        expirationHandler?()
    }
}

private enum LifecycleTestError: Error {
    case notRegistered
    case loadFailed
}
