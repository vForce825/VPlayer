// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

@MainActor
final class IOSLibraryFlowTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "seeded", "-uiTestResetPlaybackSettings"]
        app.launch()
        return app
    }
    func testTouchChannelSelectionCloseAndReopen() {
        let app = launch()
        let channel = app.buttons["channel.http"]
        XCTAssertTrue(channel.waitForExistence(timeout: 15))
        for _ in 0..<3 {
            channel.tap()
            XCTAssertTrue(app.buttons["player-back"].waitForExistence(timeout: 5))
            app.buttons["player-back"].tap()
            XCTAssertTrue(channel.waitForExistence(timeout: 5))
        }
    }
    func testSourceEditorCancelAndReopen() {
        let app = launch()
        app.tabBars.buttons["播放列表"].tap()
        let add = app.buttons["source.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            add.tap()
            XCTAssertTrue(app.textFields["source.editor.name"].waitForExistence(timeout: 5))
            app.buttons["source.editor.cancel"].tap()
            XCTAssertTrue(add.waitForExistence(timeout: 5))
        }
    }
    func testRotationAndPlaybackSettingsKeepPlayerSession() {
        let app = launch()
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 15))
        app.buttons["channel.http"].tap()
        XCTAssertTrue(app.buttons["player-back"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["player-back"].exists)
        app.buttons["player-settings"].tap()
        XCTAssertTrue(app.buttons["player.settings.done"].waitForExistence(timeout: 5))
        app.buttons["player.settings.done"].tap()
        XCTAssertTrue(app.buttons["player-back"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        app.buttons["player-back"].tap()
    }
}
