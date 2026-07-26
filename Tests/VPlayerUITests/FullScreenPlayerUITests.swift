// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

final class FullScreenPlayerUITests: XCTestCase {
    @MainActor
    func testPlayingFixtureExposesSanitizedAcceptanceState() {
        let app = launchFixture()
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)

        let state = app.otherElements["player-acceptance-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.value as? String, "playing")
        XCTAssertFalse(state.hasFocus)
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
        let state = app.otherElements["player-acceptance-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.value as? String, "failed:ui.fixture")
        XCTAssertFalse(state.hasFocus)
    }

    @MainActor
    func testFailureDiagnosticFixturePrefersSignedStatusWithoutTakingFocus() {
        let app = launchFixture(playback: "failed-diagnostic")
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)

        let retry = app.buttons["player-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(retry.wait(for: \.hasFocus, toEqual: true, timeout: 2))
        let state = app.otherElements["player-acceptance-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.value as? String, "failed:video.decode.status.-12909")
        XCTAssertFalse(state.hasFocus)
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
