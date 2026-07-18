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
}
