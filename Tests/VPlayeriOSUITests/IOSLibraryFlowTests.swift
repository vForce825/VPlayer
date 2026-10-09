// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

@MainActor
final class IOSLibraryFlowTests: XCTestCase {
    private func identified(_ identifier: String, in query: XCUIElementQuery) -> XCUIElementQuery {
        query.matching(NSPredicate(format: "identifier == %@", identifier))
    }
    private func failureDetails(in app: XCUIApplication, stage: String) -> String {
        let route = app.descendants(matching: .any)
            .matching(identifier: "ios.playback.route").firstMatch
        let snapshot = route.exists ? (route.value as? String ?? "value-unavailable") : "probe-unavailable"
        let channel = app.buttons["channel.http"]
        let channelExists = channel.exists
        let playerExists = app.buttons["player-back"].exists
        let playerContainerExists = app.descendants(matching: .any)
            .matching(identifier: "player-full-screen").firstMatch.exists
        let miniPlayerExists = app.buttons["player-mini-resume"].exists
        let channelNavigationExists = app.navigationBars["频道"].exists
        let closeByLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "关闭播放"))
        let knownIdentifiers = ["player-back", "player-full-screen", "player-pip", "player-settings"]
        let closeElements = closeByLabel.allElementsBoundByIndex.prefix(3).map { element in
            let identifier = knownIdentifiers.contains(element.identifier) ? element.identifier : "other"
            return "role=\(element.elementType.rawValue):id=\(identifier):hit=\(element.isHittable):frame=\(element.frame)"
        }.joined(separator: ";")
        let screenIDButtons = identified("player-full-screen", in: app.buttons).count
        return "IOS_UI_STAGE=\(stage) IOS_UI_ROUTE=\(snapshot) " +
            "playerBack=\(playerExists) playerContainer=\(playerContainerExists) miniPlayer=\(miniPlayerExists) " +
            "row=channel.http exists=\(channelExists) hittable=\(channelExists && channel.isHittable) " +
            "channelNavigation=\(channelNavigationExists) alerts=\(app.alerts.count) " +
            "screenIDButtons=\(screenIDButtons) closeLabelMatches=\(closeByLabel.count) closeElements=[\(closeElements)]"
    }
    private func require(_ element: XCUIElement, in app: XCUIApplication, stage: String,
                         timeout: TimeInterval, hittable: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) {
        let found = hittable ? element.wait(for: \.isHittable, toEqual: true, timeout: timeout)
            : element.waitForExistence(timeout: timeout)
        XCTAssertTrue(found, found ? "" : failureDetails(in: app, stage: stage),
            file: file, line: line)
    }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "seeded", "-uiTestResetPlaybackSettings",
                               "-ui-playback-route-diagnostics"]
        app.launch()
        return app
    }
    private func assertPlayerControls(in app: XCUIApplication, stage: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let screens = identified("player-full-screen", in: app.descendants(matching: .any))
        XCTAssertEqual(screens.count, 1, failureDetails(in: app, stage: stage + "-screen-identity"),
            file: file, line: line)
        XCTAssertEqual(identified("player-full-screen", in: app.buttons).count, 0,
            failureDetails(in: app, stage: stage + "-screen-is-not-button"), file: file, line: line)
        let screen = screens.firstMatch
        for (identifier, label) in [("player-back", "关闭播放"), ("player-pip", "画中画"),
                                     ("player-settings", "播放设置")] {
            let buttons = identified(identifier, in: screen.descendants(matching: .button))
            XCTAssertEqual(buttons.count, 1, failureDetails(in: app, stage: stage + "-" + identifier),
                file: file, line: line)
            let button = buttons.firstMatch
            XCTAssertEqual(button.identifier, identifier, file: file, line: line)
            XCTAssertEqual(button.elementType, .button, file: file, line: line)
            XCTAssertEqual(button.label, label, file: file, line: line)
            if identifier != "player-pip" {
                XCTAssertTrue(button.isEnabled, file: file, line: line)
                XCTAssertTrue(button.isHittable, failureDetails(in: app, stage: stage + "-" + identifier + "-hit"),
                    file: file, line: line)
            } else {
                // The seeded engine does not install a native PiP presentation.
                XCTAssertFalse(button.isEnabled, file: file, line: line)
            }
        }
    }
    func testTouchChannelSelectionCloseAndReopen() {
        let app = launch()
        defer { app.terminate() }
        let channel = app.buttons["channel.http"]
        require(channel, in: app, stage: "initial-channel", timeout: 15)
        for cycle in 1...3 {
            channel.tap()
            require(app.buttons["player-back"], in: app, stage: "touch-cycle-\(cycle)-player-back", timeout: 5)
            assertPlayerControls(in: app, stage: "touch-cycle-\(cycle)")
            app.buttons["player-back"].tap()
            require(channel, in: app, stage: "touch-cycle-\(cycle)-channel-after-close", timeout: 5, hittable: true)
            XCTAssertFalse(identified("player-full-screen", in: app.descendants(matching: .any)).firstMatch.exists,
                failureDetails(in: app, stage: "touch-cycle-\(cycle)-player-dismissed"))
        }
    }
    func testSourceEditorCancelAndReopen() {
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["播放列表"].tap()
        let add = app.buttons["source.add"]
        require(add, in: app, stage: "source-add", timeout: 10)
        for cycle in 1...2 {
            add.tap()
            require(app.textFields["source.editor.name"], in: app, stage: "source-cycle-\(cycle)-editor", timeout: 5)
            app.buttons["source.editor.cancel"].tap()
            require(add, in: app, stage: "source-cycle-\(cycle)-after-cancel", timeout: 5)
        }
    }
    func testPlaylistEditOpensExistingSourceWithoutDeletingIt() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "edit-seeded-channel", timeout: 15)
        app.tabBars.buttons["播放列表"].tap()

        // Query the visible controls so this exercises the same List row touch
        // handling as a person tapping Edit, including on the unfixed app.
        let edit = app.buttons["编辑"]
        require(edit, in: app, stage: "edit-source-control", timeout: 5, hittable: true)
        for cycle in 1...2 {
            edit.tap()
            let name = app.textFields["source.editor.name"]
            require(name, in: app, stage: "edit-existing-source-\(cycle)", timeout: 5, hittable: true)
            XCTAssertEqual(name.value as? String, "测试播放列表")
            XCTAssertEqual(app.textFields["source.editor.m3u"].value as? String,
                           "https://fixture.invalid/playlist.m3u")
            XCTAssertFalse(app.staticTexts["已导入的频道和节目单会一并移除。"].exists,
                           "Tapping Edit must not also request deletion.")
            app.buttons["source.editor.cancel"].tap()
            require(edit, in: app, stage: "edit-cancelled-\(cycle)", timeout: 5, hittable: true)
            XCTAssertTrue(app.staticTexts["测试播放列表"].exists)
        }

        app.tabBars.buttons["频道"].tap()
        require(app.buttons["channel.http"], in: app, stage: "edit-preserved-channel", timeout: 5,
                hittable: true)
    }
    func testPlaylistDeleteCancelsWithoutRemovalAndRequiresExplicitConfirmation() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "delete-seeded-channel", timeout: 15)
        app.tabBars.buttons["播放列表"].tap()

        let delete = app.buttons["删除"]
        require(delete, in: app, stage: "delete-source-control", timeout: 5, hittable: true)
        delete.tap()
        let dialog = app.sheets.firstMatch
        require(dialog.buttons["取消"], in: app, stage: "delete-cancel-confirmation", timeout: 5,
                hittable: true)
        XCTAssertTrue(dialog.staticTexts["已导入的频道和节目单会一并移除。"].exists)
        XCTAssertFalse(app.textFields["source.editor.name"].exists,
                       "Tapping Delete must not also open the editor.")
        dialog.buttons["取消"].tap()
        require(delete, in: app, stage: "delete-cancelled", timeout: 5, hittable: true)
        XCTAssertTrue(app.staticTexts["测试播放列表"].exists)
        app.tabBars.buttons["频道"].tap()
        require(app.buttons["channel.http"], in: app, stage: "delete-cancel-preserved-channel", timeout: 5)

        app.tabBars.buttons["播放列表"].tap()
        delete.tap()
        require(dialog.buttons["删除"], in: app, stage: "delete-explicit-confirmation", timeout: 5,
                hittable: true)
        // Only the isolated in-memory seeded source is ever confirmed for deletion.
        dialog.buttons["删除"].tap()
        require(app.staticTexts["还没有播放列表"], in: app, stage: "delete-source-removed", timeout: 5)
        XCTAssertFalse(app.staticTexts["测试播放列表"].exists)
        app.tabBars.buttons["频道"].tap()
        XCTAssertFalse(app.buttons["channel.http"].exists)
    }
    func testRotationAndPlaybackSettingsKeepPlayerSession() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "rotation-initial-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        require(app.buttons["player-back"], in: app, stage: "rotation-initial-player-back", timeout: 5)
        assertPlayerControls(in: app, stage: "rotation-initial")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["player-back"].exists, failureDetails(in: app, stage: "after-rotation"))
        assertPlayerControls(in: app, stage: "after-rotation")
        app.buttons["player-settings"].tap()
        require(app.buttons["player.settings.done"], in: app, stage: "settings-presented", timeout: 5)
        app.buttons["player.settings.done"].tap()
        require(app.buttons["player-back"], in: app, stage: "after-settings-player-back", timeout: 5)
        assertPlayerControls(in: app, stage: "after-settings")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["player-back"].tap()
    }
}
