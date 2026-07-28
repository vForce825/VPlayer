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
        let videoSummary = app.buttons["settings.buffer.video.current"]
        let channelSummary = app.buttons["settings.channels.current"]
        XCTAssertTrue(videoSummary.waitForExistence(timeout: 3))
        XCTAssertEqual(videoSummary.value as? String, "2 秒（默认）")
        XCTAssertEqual(channelSummary.value as? String, "按播放列表分组（默认）")
        XCTAssertTrue(app.buttons["settings.privacy"].exists)
        XCTAssertTrue(app.buttons["settings.open-source"].exists)
        XCTAssertFalse(app.buttons["settings.about.current"].exists)
        XCTAssertFalse(app.buttons["settings.buffer.video.2"].exists)
        XCTAssertFalse(app.buttons["settings.channels.grouped"].exists)

        focusSettingsRow(videoSummary, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["settings.buffer.video.2"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings.buffer.video.2"].isSelected)
        XCUIRemote.shared.press(.menu)

        focusSettingsRow(channelSummary, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["settings.channels.grouped"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings.channels.grouped"].isSelected)
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
    func testGroupRailJumpsFocusIntoTheChosenGroupIncludingTheUngroupedOne() {
        let app = launchSeededApp()
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.group.第二分组"].waitForExistence(timeout: 3))

        jumpToGroup(named: "第二分组", in: app)
        XCTAssertTrue(
            app.buttons["channel.grouped"].wait(for: \.hasFocus, toEqual: true, timeout: 2)
        )
        XCTAssertFalse(
            app.buttons["channel.group.测试分组"].isHittable,
            "Expected the group rail to scroll off screen with the channel grid"
        )

        // Channels whose playlist entry carries no group-title collect under
        // 其他 and stay reachable like any other group.
        jumpToGroup(named: "其他", in: app)
        XCTAssertTrue(
            app.buttons["channel.ungrouped"].wait(for: \.hasFocus, toEqual: true, timeout: 2)
        )
    }

    @MainActor
    func testFlatOrderSettingDropsGroupHeadersAndTheRail() {
        let app = launchSeededApp()
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.staticTexts["测试分组"].exists)
        XCTAssertTrue(app.buttons["channel.group.第二分组"].exists)

        selectTab(named: "设置", in: app)
        let channelSummary = app.buttons["settings.channels.current"]
        XCTAssertTrue(channelSummary.waitForExistence(timeout: 3))
        focusSettingsRow(channelSummary, in: app)
        XCUIRemote.shared.press(.select)
        let flat = app.buttons["settings.channels.flat"]
        let grouped = app.buttons["settings.channels.grouped"]
        XCTAssertTrue(flat.waitForExistence(timeout: 3))
        XCTAssertTrue(grouped.isSelected)
        let flatRow = app.cells.containing(
            .button,
            identifier: "settings.channels.flat"
        ).element
        for _ in 0..<12 where !flatRow.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(flatRow.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(flat.wait(for: \.isSelected, toEqual: true, timeout: 2))
        XCTAssertFalse(grouped.isSelected)
        XCUIRemote.shared.press(.menu)
        XCTAssertEqual(channelSummary.value as? String, "按原始顺序平铺")

        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["测试分组"].exists)
        XCTAssertFalse(app.buttons["channel.group.第二分组"].exists)
        // Every channel survives the switch, including the ungrouped one.
        XCTAssertTrue(app.buttons["channel.udp"].exists)
        XCTAssertTrue(app.buttons["channel.grouped"].exists)
        XCTAssertTrue(app.buttons["channel.ungrouped"].exists)
    }

    /// Moves focus back up to the scrolling rail and along it until `name` is
    /// focused, then selects it.
    @MainActor
    private func jumpToGroup(named name: String, in app: XCUIApplication) {
        let chip = app.buttons["channel.group.\(name)"]
        for _ in 0..<3 where !railHasFocus(in: app) {
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(railHasFocus(in: app), "Expected focus to reach the group rail")
        for _ in 0..<4 where !chip.hasFocus {
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(chip.hasFocus, "Expected the rail to reach the \(name) chip")
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func railHasFocus(in app: XCUIApplication) -> Bool {
        ["测试分组", "第二分组", "其他"].contains { group in
            let button = app.buttons["channel.group.\(group)"]
            return button.exists && button.hasFocus
        }
    }

    /// A playlist card carries its controls at the trailing edge while the add
    /// button sits at the leading one. Nothing lines up between them, so the
    /// remote used to dead-end on the add button with the card's own buttons
    /// unreachable — every vertical press has to cross into the card and back.
    @MainActor
    func testRemoteReachesEveryControlOnAPlaylistCard() {
        let app = launchSeededApp()
        XCTAssertTrue(app.tabBars.buttons["频道"].waitForExistence(timeout: 5))
        selectTab(named: "播放列表", in: app)

        let add = app.buttons["source.add"]
        let edit = cardButton(prefixed: "source.edit.", in: app)
        let delete = cardButton(prefixed: "source.delete.", in: app)
        let playlistRefresh = app.buttons["source.refresh.playlist"]
        let epgRefresh = app.buttons["source.refresh.epg"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        XCTAssertTrue(add.wait(for: \.hasFocus, toEqual: true, timeout: 2))

        // Down off the add button lands on the card rather than going nowhere.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            delete.wait(for: \.hasFocus, toEqual: true, timeout: 2),
            "Expected the first card's header row to take focus"
        )
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(edit.wait(for: \.hasFocus, toEqual: true, timeout: 2))

        // Both resource rows are reachable from the header row.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(playlistRefresh.wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(epgRefresh.wait(for: \.hasFocus, toEqual: true, timeout: 2))

        // And the way back out of the card is symmetric.
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(playlistRefresh.wait(for: \.hasFocus, toEqual: true, timeout: 2))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(delete.hasFocus || edit.hasFocus)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(add.wait(for: \.hasFocus, toEqual: true, timeout: 2))
    }

    /// Card controls carry the playlist's identifier, which the seeded fixture
    /// generates fresh on each launch.
    @MainActor
    private func cardButton(prefixed prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        ).firstMatch
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
        // Bounded by the longest list this suite navigates away from — the
        // settings screen, whose buffer sections put ten rows below the tab bar.
        for _ in 0..<16 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
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

    @MainActor
    private func focusSettingsRow(_ row: XCUIElement, in app: XCUIApplication) {
        let cell = app.cells.containing(.button, identifier: row.identifier).element
        for _ in 0..<5 where !row.hasFocus && !cell.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(
            row.hasFocus || cell.hasFocus,
            "Expected focus to reach settings row \(row.identifier)"
        )
    }
}
