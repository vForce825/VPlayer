// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

final class LiveStartupUITests: XCTestCase {
    @MainActor
    func testLiveLaunchIsUsable() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["频道"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["操作失败"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["无法读取数据，请稍后重试。"].exists)

        selectTab(named: "数据源", in: app)
        let add = app.buttons["source.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["source.editor.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["source.editor.m3u"].exists)
        XCTAssertTrue(app.textFields["source.editor.epg"].exists)
        XCTAssertTrue(app.buttons["source.editor.save"].exists)
        XCTAssertFalse(app.alerts["操作失败"].exists)
    }

    @MainActor
    private func selectTab(named name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        for _ in 0..<8 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        for _ in 0..<3 { XCUIRemote.shared.press(.left) }
        for _ in 0..<4 where !tab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(tab.hasFocus)
        XCUIRemote.shared.press(.select)
    }
}
