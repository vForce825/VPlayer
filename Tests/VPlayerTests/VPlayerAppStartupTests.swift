// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer

@MainActor
final class VPlayerAppStartupTests: XCTestCase {
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
                "-ui-playback-fixture", "interlaced-temporal-unsupported",
            ]).playbackFixture,
            "interlaced-temporal-unsupported"
        )
        XCTAssertNil(AppLaunchConfiguration(arguments: [
            "VPlayer", "-ui-playback-fixture",
        ]).playbackFixture)
    }

    func testProductionAppStartupPurgesLibrarySnapshotsOnceAfterRepeatedStartRequests() async {
        let probe = StartupMaintenanceProbe()
        let dependencies = makeDependencies(maintenance: probe)

        _ = VPlayerApp(dependencies: dependencies)
        await probe.waitUntilAttempted()
        let repeatedOutcome = await dependencies.start()
        let attemptCount = await probe.attemptCount

        XCTAssertEqual(repeatedOutcome, .alreadyCompleted)
        XCTAssertEqual(attemptCount, 1)
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

private enum StartupProbeError: Error {
    case expected
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
