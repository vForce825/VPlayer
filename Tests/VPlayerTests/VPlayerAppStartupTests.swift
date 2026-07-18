// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer

@MainActor
final class VPlayerAppStartupTests: XCTestCase {
    func testProductionAppStartupPurgesLibrarySnapshotsOnceAfterRepeatedStartRequests() async {
        let probe = StartupMaintenanceProbe()
        let dependencies = VPlayerDependencies.production {
            probe
        }

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
