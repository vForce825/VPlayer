// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayer

// The broader tvOS startup suite is excluded from the iOS target.
// Keep the launch-policy assertion available under the required iOS identity.
@MainActor
final class VPlayerAppStartupTests: XCTestCase {
    func testSeededFixtureLaunchFlagIsHonoredOnlyInDebugBuilds() {
        #if DEBUG
        let expectedSeededMode: AppLaunchMode = .seededFixture
        let expectedReset = true
        let expectedPlaybackFixture: String? = "failed-diagnostic"
        #else
        let expectedSeededMode: AppLaunchMode = .live
        let expectedReset = false
        let expectedPlaybackFixture: String? = nil
        #endif
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: ["VPlayer", "-ui-fixture", "seeded"]).mode,
            expectedSeededMode
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
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: ["VPlayer", "-uiTestResetPlaybackSettings"])
                .resetsPlaybackSettings,
            expectedReset
        )
        XCTAssertEqual(
            AppLaunchConfiguration(arguments: [
                "VPlayer", "-ui-fixture", "seeded",
                "-ui-playback-fixture", "failed-diagnostic",
            ]).playbackFixture,
            expectedPlaybackFixture
        )
        XCTAssertNil(AppLaunchConfiguration(arguments: [
            "VPlayer", "-ui-playback-fixture",
        ]).playbackFixture)
        XCTAssertNil(AppLaunchConfiguration(arguments: [
            "VPlayer", "-ui-playback-fixture", "failed-diagnostic",
            "-ui-playback-fixture", "another-fixture",
        ]).playbackFixture)
        let combined = AppLaunchConfiguration(arguments: [
            "VPlayer", "-ui-fixture", "seeded", "-acceptance-playback",
            "-uiTestResetPlaybackSettings", "-ui-playback-fixture", "failed-diagnostic",
        ])
        XCTAssertEqual(combined.mode, .live)
        XCTAssertEqual(combined.resetsPlaybackSettings, expectedReset)
        XCTAssertEqual(combined.playbackFixture, expectedPlaybackFixture)
    }
}
