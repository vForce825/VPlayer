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
    func testGroupRailJumpsFocusIntoTheChosenGroupIncludingTheUngroupedOne() {
        let app = launchSeededApp()
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 5))
        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.group.第二分组"].waitForExistence(timeout: 3))

        jumpToGroup(named: "第二分组", in: app)
        XCTAssertTrue(
            app.buttons["channel.grouped"].wait(for: \.hasFocus, toEqual: true, timeout: 2)
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
        let flat = app.buttons["settings.channels.flat"]
        let grouped = app.buttons["settings.channels.grouped"]
        XCTAssertTrue(flat.waitForExistence(timeout: 3))
        XCTAssertTrue(grouped.isSelected)
        // Rows run apple, yadif, grouped, flat from the top of the list.
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(flat.wait(for: \.isSelected, toEqual: true, timeout: 2))
        XCTAssertFalse(grouped.isSelected)

        selectTab(named: "频道", in: app)
        XCTAssertTrue(app.buttons["channel.http"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["测试分组"].exists)
        XCTAssertFalse(app.buttons["channel.group.第二分组"].exists)
        // Every channel survives the switch, including the ungrouped one.
        XCTAssertTrue(app.buttons["channel.udp"].exists)
        XCTAssertTrue(app.buttons["channel.grouped"].exists)
        XCTAssertTrue(app.buttons["channel.ungrouped"].exists)
    }

    /// Moves focus up into the pinned rail and along it until `name` is focused,
    /// then selects it.
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
        app.buttons.allElementsBoundByIndex.contains {
            $0.identifier.hasPrefix("channel.group.") && $0.hasFocus
        }
    }

    @MainActor
    func testZZDiagnoseSourceFocus() {
        let app = launchSeededApp()
        XCTAssertTrue(app.tabBars.buttons["频道"].waitForExistence(timeout: 5))
        selectTab(named: "播放列表", in: app)
        XCTAssertTrue(app.buttons["source.add"].waitForExistence(timeout: 3))

        print("DIAG-TREE-LIST\n\(app.debugDescription)\nDIAG-TREE-LIST-END")
        attachScreenshot(named: "list")

        print("DIAG-FOCUS start: \(focusDump(app))")
        let moves: [(String, XCUIRemote.Button)] = [
            ("down", .down), ("down", .down), ("down", .down),
            ("up", .up), ("up", .up), ("up", .up)
        ]
        for (name, button) in moves {
            XCUIRemote.shared.press(button)
            print("DIAG-FOCUS after \(name): \(focusDump(app))")
        }

        XCTAssertTrue(app.buttons["source.add"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["source.editor.name"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 3)
        print("DIAG-TREE-ADD\n\(app.debugDescription)\nDIAG-TREE-ADD-END")
        attachScreenshot(named: "add-name-focused")
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(named: "add-m3u-focused")
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(named: "add-epg-focused")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(named: "add-away-from-fields")
    }

    @MainActor
    private func editButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'source.edit.'")
        ).firstMatch
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func focusDump(_ app: XCUIApplication) -> String {
        var found: [String] = []
        for type in [XCUIElement.ElementType.button, .textField] {
            for element in app.descendants(matching: type).allElementsBoundByIndex where element.hasFocus {
                let label = element.identifier.isEmpty ? element.label : element.identifier
                found.append("\(type.rawValue)/\(label)/\(element.frame)")
            }
        }
        return found.isEmpty ? "<none>" : found.joined(separator: " | ")
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
