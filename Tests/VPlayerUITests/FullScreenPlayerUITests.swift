// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

final class FullScreenPlayerUITests: XCTestCase {
    @MainActor
    func testSettingsExposeExactlyTwoAlgorithmsAndAppleIsDefault() {
        let app = launchFixture()
        selectTab(named: "设置", in: app)

        XCTAssertTrue(app.buttons["settings.deinterlace.apple"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings.deinterlace.yadif"].exists)
        XCTAssertTrue(app.buttons["settings.deinterlace.apple"].isSelected)
        XCTAssertEqual(app.buttons.matching(identifier: "settings.deinterlace.apple").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "settings.deinterlace.yadif").count, 1)
        XCTAssertFalse(app.staticTexts["关闭自动检测"].exists)
    }

    @MainActor
    func testTemporalFailureBannerDoesNotTakeFocusAndDisappears() {
        let app = launchFixture(playback: "interlaced-temporal-unsupported")
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.otherElements["player-full-screen"].waitForExistence(timeout: 3))

        let banner = app.staticTexts["Apple 反交错不可用，可在设置中切换到 Metal YADIF 2x。"]
        XCTAssertTrue(banner.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["player-play-pause"].hasFocus)
        XCTAssertFalse(banner.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["player-seek-forward"].exists)
        XCTAssertFalse(app.buttons["player-seek-backward"].exists)
    }

    @MainActor
    func testFailureOverlayDefaultsFocusToRetry() {
        let app = launchFixture(playback: "failed")
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)

        let retry = app.buttons["player-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(retry.wait(for: \.hasFocus, toEqual: true, timeout: 2))
    }

    @MainActor
    private func launchFixture(playback: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "seeded", "-uiTestResetPlaybackSettings"]
        if let playback {
            app.launchArguments += ["-ui-playback-fixture", playback]
        }
        app.launch()
        return app
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
