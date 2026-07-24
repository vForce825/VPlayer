// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

final class VPlayerUITests: XCTestCase {
    @MainActor
    func testSeededLaunchExposesSourceChannelAndSettingsFlow() {
        let app = launchSeededApp()

        XCTAssertTrue(app.tabBars.buttons["频道"].waitForExistence(timeout: 5))

        selectTab(named: "播放列表", in: app)
        XCTAssertTrue(app.buttons["source.add"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["source.refresh.playlist"].exists)
        XCTAssertTrue(app.buttons["source.refresh.epg"].exists)
        XCTAssertTrue(app.images["source.active.seeded"].exists)

        selectTab(named: "设置", in: app)
        XCTAssertTrue(app.staticTexts["Apple Temporal（默认）"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Metal YADIF 2x"].exists)
        XCTAssertTrue(app.buttons["settings.deinterlace.apple"].isSelected)
        XCTAssertFalse(app.staticTexts["关闭自动检测"].exists)
        XCTAssertFalse(app.buttons["关闭自动检测"].exists)
        XCTAssertFalse(app.switches["关闭自动检测"].exists)
    }

    @MainActor
    func testUnsupportedMulticastNeverPresentsPlaybackAndHTTPRelayDoes() {
        let app = launchSeededApp()

        XCTAssertTrue(app.buttons["channel.udp"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        // Channels of one group tile left-to-right in the browser grid, so
        // neighbours are reached with horizontal presses.
        if app.buttons["channel.udp"].hasFocus {
            XCUIRemote.shared.press(.left)
        }
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.buttons["channel.udp"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.alerts["无法播放"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts["首版暂不支持组播地址"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["player-full-screen"].exists)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.buttons["channel.udp"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.otherElements["player-full-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["测试频道"].exists)
        XCTAssertTrue(app.buttons["player-play-pause"].hasFocus)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(app.buttons["player-back"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-fixture", "seeded",
            "-uiTestResetPlaybackSettings"
        ]
        app.launch()
        return app
    }

    @MainActor
    private func selectTab(named name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        for _ in 0..<8 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        for _ in 0..<3 {
            XCUIRemote.shared.press(.left)
        }
        for _ in 0..<4 where !tab.hasFocus {
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(tab.hasFocus, "Expected focus to reach the \(name) tab")
        XCUIRemote.shared.press(.select)
    }
}
