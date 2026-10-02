// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer

@MainActor
final class ReducedResourceUsageTests: XCTestCase {
    func testReducedResourcePreferenceDefersAutomaticProfileLoads() async {
        let probe = ReducedResourceRefreshProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { await probe.loaded(); return [] },
            refresh: { _, _, _ in [] },
            sleep: { await probe.slept(); try await Task.sleep(for: .seconds(3_600)) },
            reportStatus: { _ in }
        )
        driver.setPrefersReducedResourceUsage(true)
        driver.initialLibraryLoadDidComplete()
        driver.activate()
        for _ in 0..<1_000 {
            if await probe.sleepCount > 0 { break }
            await Task.yield()
        }
        let loads = await probe.loadCount
        let sleeps = await probe.sleepCount
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(sleeps, 1)
        driver.deactivate()
    }

    func testPreferenceChangeDoesNotStartAnImmediateRefresh() async {
        let probe = ReducedResourceRefreshProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { await probe.loaded(); return [] },
            refresh: { _, _, _ in [] },
            sleep: { await probe.slept(); try await Task.sleep(for: .seconds(3_600)) },
            reportStatus: { _ in }
        )
        driver.setPrefersReducedResourceUsage(true)
        driver.initialLibraryLoadDidComplete()
        driver.activate()
        for _ in 0..<1_000 {
            if await probe.sleepCount > 0 { break }
            await Task.yield()
        }
        driver.setPrefersReducedResourceUsage(false)
        for _ in 0..<100 { await Task.yield() }
        let loads = await probe.loadCount
        XCTAssertEqual(loads, 0, "Preference changes must not trigger expensive work")
        driver.deactivate()
    }
}

private actor ReducedResourceRefreshProbe {
    private(set) var loadCount = 0
    private(set) var sleepCount = 0
    func loaded() { loadCount += 1 }
    func slept() { sleepCount += 1 }
}
