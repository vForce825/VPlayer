// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import XCTest

@MainActor
final class MacLibraryUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "seeded", "-ui-playback-fixture", "media-information", "-uiTestResetPlaybackSettings"]
        app.launch()
        XCTAssertTrue(app.textFields["channels.search"].waitForExistence(timeout: 10))
        // macOS 可能恢复上次测试的全屏窗口，先用系统菜单的实际状态统一测试起点。
        let fullscreen = app.menuItems["toggleFullScreen:"]
        if fullscreen.label == "Exit Full Screen" || fullscreen.label.hasPrefix("退出全屏") {
            app.typeKey("f", modifierFlags: [.control, .command])
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@ AND NOT label BEGINSWITH %@", "Exit Full Screen", "退出全屏"),
                object: fullscreen)], timeout: 5), .completed)
        }
        return app
    }
    func testSearchSourceManagementAndEditorValidation() {
        let app = launch()
        let search = app.textFields["channels.search"]
        search.click(); search.typeText("测试频道")
        XCTAssertTrue(app.staticTexts["测试频道"].waitForExistence(timeout: 5))
        app.buttons["sources.manage"].click()
        XCTAssertTrue(app.staticTexts["测试播放列表"].waitForExistence(timeout: 5))
        app.buttons["完成"].click()
        app.buttons["sources.add"].click()
        XCTAssertTrue(app.textFields["source.editor.name"].waitForExistence(timeout: 5))
        app.buttons["source.editor.save"].click()
        let validation = app.descendants(matching: .any)["source.editor.error"].firstMatch
        XCTAssertTrue(validation.waitForExistence(timeout: 3))
        XCTAssertTrue(validation.label.contains("名称"))
        app.buttons["source.editor.cancel"].click()
    }
    func testBottomControlsProgrammeGuideAndInformationCanBeHiddenAndRestored() {
        let app = launch()
        app.staticTexts["测试频道"].firstMatch.doubleClick()
        let pause = app.buttons["player.play-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["channels.search"].exists)
        let progress = app.progressIndicators["player.programme-progress"]
        XCTAssertTrue(progress.exists)
        XCTAssertGreaterThan(pause.frame.midY, app.windows.firstMatch.frame.midY)
        app.buttons["player.information.hide"].click()
        XCTAssertFalse(app.buttons["player.information.hide"].exists)
        app.buttons["player.information"].click()
        XCTAssertTrue(app.buttons["player.information.hide"].waitForExistence(timeout: 3))
        app.buttons["player.programmes"].click()
        let guide = app.sheets.firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 3))
        XCTAssertTrue(guide.staticTexts.containing(NSPredicate(format: "value == %@", "正在播出")).firstMatch.exists)
        app.buttons["完成"].click()
        pause.click()
        XCTAssertEqual(pause.label, "播放")
        let surface = app.descendants(matching: .any)["player.interaction-surface"].firstMatch
        surface.doubleClick()
        let fullscreen = app.buttons["player.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "退出全屏"), object: fullscreen)], timeout: 5), .completed)
        surface.doubleClick()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "全屏"), object: fullscreen)], timeout: 5), .completed)
        app.buttons["player.channels"].click()
        XCTAssertTrue(app.textFields["channels.search"].waitForExistence(timeout: 3))
        pause.click()
        surface.hover()
        XCTAssertTrue(app.textFields["channels.search"].waitForNonExistence(timeout: 8))
        app.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "macOS-播放界面"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["player.stop"].click()
        XCTAssertFalse(app.buttons["player.play-pause"].exists)
        XCTAssertTrue(app.textFields["channels.search"].waitForExistence(timeout: 3))
    }
    func testSidebarStartsNarrowAndRemembersDraggedWidthAfterRelaunch() {
        let app = launch()
        let search = app.textFields["channels.search"]
        let originalWidth = search.frame.width
        XCTAssertLessThan(originalWidth, 260)
        let handle = app.descendants(matching: .any)["channels.resize"].firstMatch
        XCTAssertTrue(handle.exists)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)))
        let adjustedWidth = search.frame.width
        XCTAssertGreaterThan(adjustedWidth, originalWidth + 40)
        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestResetPlaybackSettings" }
        app.launch()
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertEqual(search.frame.width, adjustedWidth, accuracy: 2)
    }
    func testEscapeHidesPausedControlsAndFocusedSidebarWithoutLeavingFullscreen() {
        let app = launch()
        app.staticTexts["测试频道"].firstMatch.doubleClick()
        XCTAssertTrue(app.windows["VPlayer - 测试频道"].waitForExistence(timeout: 5))
        let pause = app.buttons["player.play-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.click()
        XCTAssertEqual(pause.label, "播放")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pause.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["player.information.hide"].exists)

        let surface = app.descendants(matching: .any)["player.interaction-surface"].firstMatch
        surface.hover()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        app.buttons["player.channels"].click()
        let search = app.textFields["channels.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 3))
        XCTAssertFalse(pause.exists)
        XCTAssertFalse(app.buttons["player.information.hide"].exists)

        surface.hover()
        app.buttons["player.information.hide"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pause.waitForNonExistence(timeout: 3))
        surface.hover()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["player.information.hide"].exists)

        surface.doubleClick()
        let fullscreen = app.buttons["player.fullscreen"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "退出全屏"), object: fullscreen)], timeout: 5), .completed)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pause.waitForNonExistence(timeout: 3))
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)).hover()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3))
        XCTAssertEqual(fullscreen.label, "退出全屏")
        surface.doubleClick()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "全屏"), object: fullscreen)], timeout: 5), .completed)
        app.buttons["player.programmes"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(pause.exists)
        app.typeKey(".", modifierFlags: [.command])
    }
    func testStopButtonTextAndTrailingPaddingBothStopPlaybackAndResetWindowTitle() {
        let app = launch()
        for (name, horizontalPosition) in [("测试频道", 0.72), ("另一组频道", 0.98)] {
            app.staticTexts[name].firstMatch.doubleClick()
            XCTAssertTrue(app.windows["VPlayer - \(name)"].waitForExistence(timeout: 5))
            let stop = app.buttons["player.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            stop.coordinate(withNormalizedOffset: CGVector(dx: horizontalPosition, dy: 0.5)).click()
            XCTAssertTrue(app.textFields["channels.search"].waitForExistence(timeout: 3))
            XCTAssertFalse(stop.exists)
            XCTAssertTrue(app.windows["VPlayer"].exists)
        }
    }
}
