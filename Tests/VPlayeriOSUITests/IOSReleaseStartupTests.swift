// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

@MainActor
final class IOSReleaseStartupTests: XCTestCase {
    func testReleaseIgnoresSeededFixtureAcrossThreeColdStarts() {
        for _ in 0..<3 {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-fixture", "seeded", "-ui-playback-fixture", "failed"]
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["频道"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.buttons["channel.http"].exists,
                "Release must not publish the DEBUG seeded library or fake player")
            app.terminate()
        }
    }
}
