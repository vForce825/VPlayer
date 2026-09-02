// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

final class FullScreenPlayerUITests: XCTestCase {
    @MainActor
    func testPreparingFixtureKeepsStatusAndControlsCenteredWithChannelCardTopTrailing() {
        let app = launchFixture(playback: "preparing")
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)

        let screen = app.otherElements["player-full-screen"]
        let preparing = app.descendants(matching: .any)["player-preparing"]
        let back = app.buttons["player-back"]
        let playPause = app.buttons["player-play-pause"]
        let settings = app.buttons["player-settings"]
        let card = app.otherElements
            .matching(identifier: "player-channel-info")
            .firstMatch

        XCTAssertTrue(screen.waitForExistence(timeout: 3))
        XCTAssertTrue(preparing.waitForExistence(timeout: 3))
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        XCTAssertTrue(playPause.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(card.waitForExistence(timeout: 3))

        let screenFrame = screen.frame
        XCTAssertEqual(preparing.frame.midX, screenFrame.midX, accuracy: 20)
        XCTAssertEqual(preparing.frame.midY, screenFrame.midY, accuracy: 20)

        let controlsFrame = back.frame.union(playPause.frame).union(settings.frame)
        XCTAssertEqual(controlsFrame.midX, screenFrame.midX, accuracy: 20)
        XCTAssertGreaterThan(controlsFrame.midY, screenFrame.midY)

        XCTAssertGreaterThan(card.frame.midX, screenFrame.midX)
        XCTAssertLessThan(card.frame.midY, screenFrame.midY)
    }

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
    func testBufferingFixtureExposesPinnedBufferingStatus() {
        let app = launchFixture(playback: "buffering")
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.descendants(matching: .any)["player-buffering"].waitForExistence(
            timeout: 3
        ))
        let state = app.otherElements["player-acceptance-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.value as? String, "buffering")
        XCTAssertEqual(
            app.otherElements["player-controls-visibility"].value as? String,
            "visible"
        )
    }

    @MainActor
    func testRecoveringFixtureExposesPinnedRecoveryStatus() {
        let app = launchFixture(playback: "recovering")
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.descendants(matching: .any)["player-recovering"].waitForExistence(
            timeout: 3
        ))
        let state = app.otherElements["player-acceptance-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.value as? String, "recovering")
        XCTAssertEqual(
            app.otherElements["player-controls-visibility"].value as? String,
            "visible"
        )
    }

    @MainActor
    func testPlayingFixtureAutoHidesAndRemoteCommandsWakeBothOverlays() {
        let app = launchFixture()
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.select)

        let state = app.otherElements["player-acceptance-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.value as? String, "playing")

        let card = app.otherElements["player-channel-info"]
        let playPause = app.buttons["player-play-pause"]
        let visibility = app.otherElements["player-controls-visibility"]
        XCTAssertTrue(visibility.waitForExistence(timeout: 1))
        XCTAssertEqual(visibility.value as? String, "visible")
        XCTAssertTrue(card.exists)
        XCTAssertTrue(playPause.exists)

        XCTAssertTrue(waitForValue(visibility, equals: "hidden", timeout: 5))
        XCTAssertFalse(playPause.isHittable)

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForValue(visibility, equals: "visible", timeout: 2))
        XCTAssertTrue(playPause.wait(for: \.isHittable, toEqual: true, timeout: 2))

        XCTAssertTrue(waitForValue(visibility, equals: "hidden", timeout: 5))
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitForValue(visibility, equals: "visible", timeout: 2))
        XCTAssertTrue(playPause.wait(for: \.isHittable, toEqual: true, timeout: 2))
    }

    @MainActor
    func testMediaInformationFixtureUsesWideCompactChannelCard() {
        let app = launchFixture(playback: "media-information")
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].wait(
            for: \.hasFocus,
            toEqual: true,
            timeout: 2
        ))
        XCUIRemote.shared.press(.select)

        let state = app.otherElements["player-acceptance-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.value as? String, "playing")

        let card = app.otherElements["player-channel-info"]
        let current = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "当前节目：")
        ).firstMatch
        let next = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "下一节目：")
        ).firstMatch
        let progress = app.progressIndicators["player-channel-progress"]
        let technical = app.descendants(matching: .any)[
            "1920 乘 1080 隔行扫描，从每秒 25 帧增强到每秒 50 帧"
        ]

        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertTrue(current.waitForExistence(timeout: 3))
        XCTAssertTrue(next.waitForExistence(timeout: 3))
        XCTAssertTrue(technical.waitForExistence(timeout: 3))
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(card.frame.width, 470)
        XCTAssertLessThan(card.frame.width, 540)
        XCTAssertGreaterThanOrEqual(progress.frame.width, 240)
        XCTAssertLessThan(progress.frame.width, 320)
        XCTAssertLessThan(card.frame.height, 250)
        XCTAssertLessThan(current.frame.height, 30)
        XCTAssertLessThan(next.frame.height, 30)

        let visibility = app.otherElements["player-controls-visibility"]
        XCTAssertTrue(visibility.waitForExistence(timeout: 1))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForValue(visibility, equals: "visible", timeout: 2))
        XCTAssertTrue(card.waitForExistence(timeout: 1))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "channel-info-density"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
    func testNonRetryFailuresHideRetryAndFocusTheExistingBackControl() {
        for fixture in ["failed-choose-channel", "failed-do-not-retry"] {
            let app = launchFixture(playback: fixture)
            XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
            selectTab(named: "频道", in: app)
            XCTAssertTrue(app.buttons["channel.http"].wait(
                for: \.hasFocus,
                toEqual: true,
                timeout: 2
            ))
            XCUIRemote.shared.press(.select)

            let back = app.buttons["player-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 3))
            XCTAssertTrue(back.wait(for: \.hasFocus, toEqual: true, timeout: 2))
            XCTAssertEqual(app.buttons.matching(identifier: "player-retry").count, 0)
            app.terminate()
        }
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

    @MainActor
    private func waitForValue(
        _ element: XCUIElement,
        equals expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            (object as? XCUIElement)?.value as? String == expected
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
