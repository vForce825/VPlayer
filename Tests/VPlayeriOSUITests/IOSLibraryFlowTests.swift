// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

@MainActor
final class IOSLibraryFlowTests: XCTestCase {
    private func require(_ element: XCUIElement, in app: XCUIApplication, stage: String,
                         timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let found = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(found, found ? "" : "IOS_UI_STAGE=\(stage)\n" + String(app.debugDescription.prefix(3000)),
            file: file, line: line)
    }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "seeded", "-uiTestResetPlaybackSettings"]
        app.launch()
        return app
    }
    func testTouchChannelSelectionCloseAndReopen() {
        let app = launch()
        defer { app.terminate() }
        let channel = app.buttons["channel.http"]
        require(channel, in: app, stage: "initial-channel", timeout: 15)
        for _ in 0..<3 {
            channel.tap()
            require(app.buttons["player-back"], in: app, stage: "player-back", timeout: 5)
            app.buttons["player-back"].tap()
            require(channel, in: app, stage: "channel-after-close", timeout: 5)
        }
    }
    func testSourceEditorCancelAndReopen() {
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["播放列表"].tap()
        let add = app.buttons["source.add"]
        require(add, in: app, stage: "source-add", timeout: 10)
        for _ in 0..<2 {
            add.tap()
            require(app.textFields["source.editor.name"], in: app, stage: "source-editor", timeout: 5)
            app.buttons["source.editor.cancel"].tap()
            require(add, in: app, stage: "source-after-cancel", timeout: 5)
        }
    }
    func testRotationAndPlaybackSettingsKeepPlayerSession() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "rotation-initial-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        require(app.buttons["player-back"], in: app, stage: "player-back", timeout: 5)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["player-back"].exists, "IOS_UI_STAGE=after-rotation\n" + String(app.debugDescription.prefix(3000)))
        app.buttons["player-settings"].tap()
        require(app.buttons["player.settings.done"], in: app, stage: "settings-presented", timeout: 5)
        app.buttons["player.settings.done"].tap()
        require(app.buttons["player-back"], in: app, stage: "player-back", timeout: 5)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["player-back"].tap()
    }
}
