// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest

@MainActor
final class IOSReleaseStartupTests: XCTestCase {
    private func mark(_ value: String) {
        FileHandle.standardOutput.write(Data(("IOS_RELEASE_"+value+"\n").utf8))
    }
    func testRunnerControlWithoutAppLaunch() {
        mark("RUNNER_CONTROL_PASS")
        XCTAssertTrue(Thread.isMainThread)
    }
    func testReleaseIgnoresSeededFixtureAcrossThreeColdStarts() {
        mark("STARTUP_TEST_ENTER")
        for index in 0..<3 {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-fixture", "seeded", "-ui-playback-fixture", "failed"]
            mark("LAUNCH_BEGIN index=\(index)")
            app.launch()
            mark("LAUNCH_RETURNED index=\(index) state=\(app.state.rawValue)")
            let ready = app.tabBars.buttons["频道"].waitForExistence(timeout: 20)
            mark("LIBRARY_READY index=\(index) ready=\(ready)")
            XCTAssertTrue(ready)
            XCTAssertFalse(app.buttons["channel.http"].exists,
                "Release must not publish the DEBUG seeded library or fake player")
            mark("TERMINATE_BEGIN index=\(index)")
            app.terminate()
            mark("TERMINATE_RETURNED index=\(index)")
        }
    }
}
