// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import UIKit
import XCTest

final class VPlayerUITests: XCTestCase {
    @MainActor
    func testAccessibilityLargeTextReducesGridDensity() {
        let standard = gridLayout(contentSizeCategory: "UICTContentSizeCategoryL")
        let accessible = gridLayout(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")

        XCTAssertEqual(standard.firstRowCount, 4,
            "All four seeded channels should share a row at standard text size")
        XCTAssertGreaterThan(accessible.firstRowCount, 0)
        XCTAssertLessThan(accessible.firstRowCount, standard.firstRowCount,
            "Accessibility text must reduce actual rendered columns")
        XCTAssertGreaterThan(accessible.tileWidth, standard.tileWidth)
        XCTAssertGreaterThanOrEqual(accessible.tileWidth, 500,
            "Accessibility text needs fewer, wider channel columns")
    }

    @MainActor
    private func gridLayout(contentSizeCategory: String) -> (firstRowCount: Int, tileWidth: CGFloat) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-fixture", "seeded", "-uiTestResetPlaybackSettings",
            // UserDefaults launch arguments have precedence over the fixture's
            // persisted-default reset; no production-only test switch is needed.
            "-channels.grouping", "playlistOrder",
            "-UIPreferredContentSizeCategoryName", contentSizeCategory
        ]
        app.launch()
        defer { app.terminate() }
        let channel = app.buttons["channel.http"]
        XCTAssertTrue(channel.waitForExistence(timeout: 5))
        XCTAssertTrue(channel.isHittable)
        XCTAssertFalse(app.buttons["channel.group.测试分组"].exists,
            "This comparison requires the same flat playlist on both launches")
        let channelIDs = ["channel.http", "channel.udp", "channel.grouped", "channel.ungrouped"]
        for identifier in channelIDs {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 3),
                "Fewer fixture channels must not masquerade as fewer grid columns: \(identifier)")
        }
        let firstFrame = channel.frame
        // A focused card can be scaled and EPG text makes cards differ in
        // height. Intersecting the first card's vertical centre identifies its
        // row without relying on equal frames or a snapshot pixel threshold.
        let firstRowCount = channelIDs.filter { identifier in
            let candidate = app.buttons[identifier]
            return candidate.exists && candidate.frame.minY <= firstFrame.midY
                && candidate.frame.maxY >= firstFrame.midY
        }.count
        return (firstRowCount, firstFrame.width)
    }

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
        XCTAssertFalse(app.buttons["settings.open-source"].exists)
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
        XCUIRemote.shared.press(.menu)

        let privacy = app.buttons["settings.privacy"]
        focusSettingsRow(privacy, in: app)
        XCUIRemote.shared.press(.select)
        let privacyURL = app.staticTexts["settings.privacy.url"]
        XCTAssertTrue(privacyURL.waitForExistence(timeout: 3))
        XCTAssertEqual(privacyURL.label, "https://vplayerdemom3u.vercel.app/privacy.html")
        XCTAssertFalse(app.buttons["查看完整在线隐私政策"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["settings.privacy"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
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
        var presses = 0
        for _ in 0..<5 where !row.hasFocus && !cell.hasFocus {
            XCUIRemote.shared.press(.down)
            presses += 1
        }
        // Freeze the original verdict before collecting evidence. A focus
        // transition during diagnostics must not turn a failed check into a pass.
        let reachedRow = row.hasFocus || cell.hasFocus
        XCTAssertTrue(
            reachedRow,
            "Expected focus to reach settings row \(row.identifier)"
                + (reachedRow ? "" : settingsFocusFailureDetails(
                    row: row, cell: cell, app: app, presses: presses
                ))
        )
    }

    @MainActor
    private func settingsFocusFailureDetails(
        row: XCUIElement, cell: XCUIElement, app: XCUIApplication, presses: Int
    ) -> String {
        // Failure-only evidence for the seeded fixture. Keep the compact state
        // in assertion text so the bounded CI failure report preserves it even
        // when the complete UI log or xcresult attachments are unavailable.
        func frame(_ rect: CGRect) -> String {
            String(format: "%.0f,%.0f,%.0f,%.0f", rect.minX, rect.minY, rect.width, rect.height)
        }
        func describe(_ snapshot: any XCUIElementSnapshot) -> String {
            "type=\(snapshot.elementType.rawValue),id=\(snapshot.identifier.prefix(64)),"
                + "focus=\(snapshot.hasFocus),selected=\(snapshot.isSelected),frame=\(frame(snapshot.frame))"
        }

        let identifier = row.identifier
        var evidence = " SETTINGS_FOCUS_FAILURE downPresses=\(presses) initialRowOrCellFocus=false"
        let rowExists = row.exists
        let cellExists = cell.exists
        evidence += " lateRowExists=\(rowExists) lateRowHittable=\(rowExists && row.isHittable)"
            + " lateCellExists=\(cellExists) lateCellHittable=\(cellExists && cell.isHittable)"
        do {
            let root = try app.snapshot()
            var pending: [(node: any XCUIElementSnapshot, ancestors: [String], viewport: CGRect)] = [
                (root, [], root.frame)
            ]
            var visited = 0
            var target: [String] = []
            var focused: [String] = []
            var settings: [String] = []
            while !pending.isEmpty && visited < 256 {
                let entry = pending.removeLast()
                let node = entry.node
                visited += 1
                var viewport = entry.viewport
                if [.scrollView, .collectionView, .table].contains(node.elementType) {
                    viewport = viewport.intersection(node.frame)
                }
                let summary = describe(node)
                if node.identifier == identifier && target.count < 2 {
                    target.append("\(summary),viewport=\(frame(viewport)),"
                        + "intersectsViewport=\(viewport.intersects(node.frame)),"
                        + "insideViewport=\(viewport.contains(node.frame)),"
                        + "ancestors=\(entry.ancestors.suffix(5).joined(separator: "/"))")
                }
                if node.hasFocus && focused.count < 4 {
                    focused.append(summary)
                }
                if node.elementType == .button && node.identifier.hasPrefix("settings."),
                   settings.count < 6 {
                    settings.append(summary)
                }
                // Bound both traversal and the ancestry carried by each entry.
                let ancestor = "\(node.elementType.rawValue):\(node.identifier.prefix(48)):focus=\(node.hasFocus)"
                let ancestors = Array((entry.ancestors + [ancestor]).suffix(5))
                let remaining = max(0, 256 - visited - pending.count)
                pending.append(contentsOf: node.children.prefix(remaining).reversed().map {
                    ($0, ancestors, viewport)
                })
            }
            evidence += " lateSnapshotScreen=\(frame(root.frame)) visited=\(visited)"
                + " scanAtLimit=\(visited == 256) target=[\(target.joined(separator: ";"))]"
                + " focused=[\(focused.joined(separator: ";"))]"
                + " settings=[\(settings.joined(separator: ";"))]"
        } catch {
            evidence += " lateSnapshotError=\(String(describing: error).prefix(256))"
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "settings-focus-failure-\(identifier)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // The report limits each failure string to 4096 characters. Reserve
        // room for XCTest's prefix and the original assertion message.
        return String(evidence.prefix(3_700))
    }
}


/// Diagnostic tests keep the production grid and native CardButtonStyle intact.
/// Only the synthetic fixture supplies a layout-neutral colored measurement line.
final class ChannelCardFocusDiagnosticTests: XCTestCase {
    @MainActor
    func testFlatPlaylistCardsLoseVisualFocusAfterScrolling() throws {
        try exerciseFocusAndScroll(grouping: "playlistOrder", testCase: .flat)
    }

    @MainActor
    func testGroupedPlaylistCardsLoseVisualFocusAfterScrolling() throws {
        try exerciseFocusAndScroll(grouping: "playlistGroups", testCase: .grouped)
    }

    @MainActor
    private func exerciseFocusAndScroll(grouping: String, testCase: CardFocusProgress.TestCase) throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let progress = CardFocusProgress(testCase: testCase)
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-fixture", "seeded", "-uiTestResetPlaybackSettings",
            "-ui-card-focus-diagnostics", "-channels.grouping", grouping,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]
        progress.measure(.launch) { app.launch() }
        defer { progress.measure(.terminate) { app.terminate() } }
        let first = app.buttons["channel.focus-probe.000"]
        let second = app.buttons["channel.focus-probe.001"]
        XCTAssertTrue(progress.measure(.focusWait) { first.waitForExistence(timeout: 10) })
        try progress.measure(.entry) { try enterChannelGrid(app: app, first: first, progress: progress) }

        // Calibrate on rendered pixels before asserting anything about residual
        // scale. AX frame widths are logged only, never used as the visual oracle.
        let initial = try stableSnapshot(app: app, progress: progress)
        let firstFocused = try initial.observation("channel.focus-probe.000")
        let secondUnfocused = try initial.observation("channel.focus-probe.001")
        let baseline = secondUnfocused.visualWidth
        let focusDelta = firstFocused.visualWidth - baseline
        guard firstFocused.hasFocus, !secondUnfocused.hasFocus,
              focusDelta >= 3, focusDelta < baseline * 0.3 else {
            attach(initial, name: "focus-calibration-unavailable-\(grouping)", progress: progress)
            throw CardFocusProbeError.unavailable(
                "Initial rendered focus expansion could not be calibrated: \(initial.summary)"
            )
        }
        print("CARD_FOCUS_CALIBRATION grouping=\(grouping) baseline=\(baseline) "
            + "focusDelta=\(focusDelta) \(initial.summary)")
        attach(initial, name: "focus-calibration-initial-\(grouping)", progress: progress)

        progress.direction = .right
        progress.measure(.navigation) { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(progress.measure(.focusWait) { second.wait(for: \.hasFocus, toEqual: true, timeout: 5) })
        let moved = try stableSnapshot(app: app, progress: progress)
        let secondFocused = try moved.observation("channel.focus-probe.001")
        guard secondFocused.visualWidth - baseline >= 3 else {
            attach(moved, name: "focus-calibration-move-unavailable-\(grouping)", progress: progress)
            throw CardFocusProbeError.unavailable(
                "Pixels did not measure expansion on the newly focused card: \(moved.summary)"
            )
        }
        let tolerance = max(2, focusDelta * 0.2)
        try assertUnfocusedWidths(moved, baseline: baseline, tolerance: tolerance,
            label: "\(grouping)-initial-right", progress: progress)
        attach(moved, name: "focus-calibration-moved-\(grouping)", progress: progress)
        progress.direction = .left
        progress.measure(.navigation) { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(progress.measure(.focusWait) { first.wait(for: \.hasFocus, toEqual: true, timeout: 5) })

        var verifiedTop: CardFocusSnapshot?
        for cycle in 0..<2 {
            progress.cycle = cycle
            progress.step = -1
            progress.direction = .none
            var snapshot: CardFocusSnapshot
            if let verifiedTop {
                // The previous cycle already verified this top snapshot with
                // two complete samples. Only focus reads and attachment creation
                // intervened; every new navigation still captures a fresh pair.
                snapshot = verifiedTop
            } else {
                snapshot = try stableSnapshot(app: app, progress: progress)
            }
            verifiedTop = nil
            var reachedBottom = false
            for step in 0..<30 {
                if try snapshot.focusedIndex() >= 75 {
                    reachedBottom = true
                    break
                }
                let index = try snapshot.focusedIndex()
                progress.step = step
                progress.direction = .down
                progress.measure(.navigation) {
                    if cycle == 1 && index < 60 {
                        XCUIRemote.shared.press(.down, forDuration: 0.5)
                    } else {
                        XCUIRemote.shared.press(.down)
                    }
                }
                snapshot = try stableSnapshot(app: app, progress: progress)
                try assertUnfocusedWidths(snapshot, baseline: baseline, tolerance: tolerance,
                    label: "\(grouping)-cycle\(cycle)-down\(step)", progress: progress)
            }
            if !reachedBottom { reachedBottom = try snapshot.focusedIndex() >= 75 }
            XCTAssertTrue(reachedBottom, "Coverage failure: did not reach the last fixture rows")
            XCTAssertFalse(progress.measure(.viewport) { first.isHittable },
                "Coverage failure: the first card never left the viewport")
            attach(snapshot, name: "focus-bottom-\(grouping)-\(cycle)", progress: progress)

            var reachedTop = false
            for step in 0..<30 {
                if try snapshot.focusedIndex() == 0 {
                    reachedTop = true
                    break
                }
                let index = try snapshot.focusedIndex()
                progress.step = step
                progress.direction = .up
                progress.measure(.navigation) {
                    if cycle == 1 && index > 20 {
                        XCUIRemote.shared.press(.up, forDuration: 0.5)
                    } else {
                        XCUIRemote.shared.press(.up)
                    }
                }
                snapshot = try stableSnapshot(app: app, progress: progress)
                try assertUnfocusedWidths(snapshot, baseline: baseline, tolerance: tolerance,
                    label: "\(grouping)-cycle\(cycle)-up\(step)", progress: progress)
            }
            if !reachedTop { reachedTop = try snapshot.focusedIndex() == 0 }
            XCTAssertTrue(reachedTop, "Coverage failure: did not return to the first fixture card")
            XCTAssertTrue(progress.measure(.focusWait) { first.hasFocus })
            attach(snapshot, name: "focus-returned-\(grouping)-\(cycle)", progress: progress)
            verifiedTop = snapshot
        }
        print("CARD_FOCUS_RESULT grouping=\(grouping) calibrated=true cycles=2 residualScale=notObserved")
    }

    @MainActor
    private func enterChannelGrid(app: XCUIApplication, first: XCUIElement, progress: CardFocusProgress) throws {
        logEntryFocus(app: app, phase: "launch", progress: progress)
        if progress.measure(.ax, { first.hasFocus }) { return }

        // defaultFocus chooses an item when the grid receives focus; it does not
        // promise that a freshly launched TabView has entered that region. Use
        // the same real remote tab-entry flow as the existing application tests.
        let channelTab = app.tabBars.buttons["频道"]
        for _ in 0..<8 where !tabsHaveFocus(app: app, progress: progress) {
            progress.direction = .up
            progress.measure(.navigation) { XCUIRemote.shared.press(.up) }
        }
        guard tabsHaveFocus(app: app, progress: progress) else {
            throw entryFailure(app: app, reason: "Could not acquire the tab bar", progress: progress)
        }
        progress.direction = .left
        for _ in 0..<3 { progress.measure(.navigation) { XCUIRemote.shared.press(.left) } }
        progress.direction = .right
        for _ in 0..<4 where !progress.measure(.ax, { channelTab.hasFocus }) {
            progress.measure(.navigation) { XCUIRemote.shared.press(.right) }
        }
        guard progress.measure(.ax, { channelTab.hasFocus }) else {
            throw entryFailure(app: app, reason: "Could not focus the channels tab", progress: progress)
        }
        progress.direction = .select
        progress.measure(.navigation) { XCUIRemote.shared.press(.select) }
        // Some tvOS configurations retain focus on the selected tab until Down.
        // Never Select a channel here: the experiment must not open playback.
        for _ in 0..<4 {
            if progress.measure(.focusWait, { first.wait(for: \.hasFocus, toEqual: true, timeout: 2) }) {
                logEntryFocus(app: app, phase: "entered-grid", progress: progress)
                return
            }
            progress.direction = .down
            progress.measure(.navigation) { XCUIRemote.shared.press(.down) }
        }
        guard progress.measure(.focusWait, { first.wait(for: \.hasFocus, toEqual: true, timeout: 2) }) else {
            throw entryFailure(app: app, reason: "Channels tab entry did not focus the first probe card",
                progress: progress)
        }
        logEntryFocus(app: app, phase: "entered-grid", progress: progress)
    }

    @MainActor
    private func tabsHaveFocus(app: XCUIApplication, progress: CardFocusProgress) -> Bool {
        progress.measure(.ax) { app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) }
    }

    @MainActor
    private func logEntryFocus(app: XCUIApplication, phase: String, progress: CardFocusProgress) {
        progress.measure(.ax) {
            let tabs = app.tabBars.buttons.allElementsBoundByIndex.map {
                "\($0.label):focus=\($0.hasFocus)"
            }.joined(separator: " ")
            let first = app.buttons["channel.focus-probe.000"]
            print("CARD_FOCUS_ENTRY phase=\(phase) firstFocus=\(first.hasFocus) tabs=[\(tabs)]")
        }
    }

    @MainActor
    private func entryFailure(app: XCUIApplication, reason: String, progress: CardFocusProgress) -> CardFocusProbeError {
        logEntryFocus(app: app, phase: "failed-entry", progress: progress)
        let hierarchy = progress.measure(.ax) { app.debugDescription }
        print("CARD_FOCUS_ENTRY_HIERARCHY \(hierarchy)")
        let screenshot = progress.measure(.screenshot) { XCUIScreen.main.screenshot() }
        progress.measure(.attachment) {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "focus-entry-unavailable"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return .unavailable(reason)
    }

    @MainActor
    private func stableSnapshot(app: XCUIApplication, progress: CardFocusProgress) throws -> CardFocusSnapshot {
        try progress.measure(.capture) { try captureStableSnapshot(app: app, progress: progress) }
    }

    @MainActor
    private func captureStableSnapshot(app: XCUIApplication, progress: CardFocusProgress) throws -> CardFocusSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 12
        // Remote presses can return before the native focus/scroll transition
        // finishes. Avoid paying for an immediate transitional screenshot, but
        // still require two complete matching samples within the same deadline.
        progress.settleAfterNavigation()
        var previous: CardFocusSnapshot?
        var lastScreenshot: XCUIScreenshot?
        var previousScreenshotCompleted: TimeInterval?
        var lastReason = "Rendered focus/scroll state never stabilized"
        var samples = 0
        while let delay = CardFocusSamplingTiming.delayBeforeSample(
            now: ProcessInfo.processInfo.systemUptime, deadline: deadline,
            previousScreenshotCompleted: previousScreenshotCompleted
        ) {
            // Raster/bookkeeping work already consumes the polling interval.
            // Finish any remaining wait before acquiring AX, so no new delay
            // can make the following fresh hierarchy/pixel pair less current.
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            samples += 1
            progress.sample = samples
            let sampleStarted = ProcessInfo.processInfo.systemUptime
            // Capture the hierarchy once. Live index-bound XCUIElement proxies
            // can change identity or disappear as LazyVGrid realizes/removes rows;
            // querying each attribute also used to cost 10+ seconds per checkpoint.
            let hierarchy: any XCUIElementSnapshot
            do {
                hierarchy = try progress.measure(.ax) { try app.snapshot() }
            } catch {
                lastReason = "Could not capture the AX hierarchy: \(error)"
                progress.sampleOutcome(.axUnavailable, started: sampleStarted)
                previous = nil
                Thread.sleep(forTimeInterval: 0.15)
                continue
            }
            let candidates = probeAttributes(in: hierarchy)
            let screenshot = progress.measure(.screenshot) {
                let screenshot = XCUIScreen.main.screenshot()
                // Pixels may be captured near the return of a slow call. Its
                // invocation time cannot pay the next observation's interval.
                previousScreenshotCompleted = ProcessInfo.processInfo.systemUptime
                return screenshot
            }
            lastScreenshot = screenshot
            let rasterStarted = progress.begin(.raster)
            let screenFrame = hierarchy.frame
            guard let image = screenshot.image.cgImage else {
                throw CardFocusProbeError.unavailable("Screenshot has no CGImage")
            }
            let raster = try CardFocusRaster(image: image, screenFrame: screenFrame)
            var observations: [CardFocusObservation] = []
            var incompleteReason: String?
            var incompleteOutcome: CardFocusSampleOutcome?
            for candidate in candidates {
                let frame = candidate.frame
                // Clip-edge cards have no complete visual oracle. Fully visible
                // cards must have a marker; silently dropping one could hide a bug.
                guard frame.width > 0, frame.height > 0,
                      frame.minX >= screenFrame.minX + 10,
                      frame.maxX <= screenFrame.maxX - 10,
                      frame.minY >= screenFrame.minY + 80,
                      frame.maxY <= screenFrame.maxY - 10 else { continue }
                guard let width = raster.markerWidth(near: frame) else {
                    incompleteReason = "No marker for \(candidate.identifier), AX frame=\(frame)"
                    incompleteOutcome = .missingMarker
                    break
                }
                observations.append(CardFocusObservation(
                    identifier: candidate.identifier, hasFocus: candidate.hasFocus,
                    visualWidth: width, accessibilityFrame: frame
                ))
            }
            let current = CardFocusSnapshot(
                observations: observations.sorted { $0.identifier < $1.identifier },
                screenshot: screenshot
            )
            if incompleteReason == nil {
                do { _ = try current.focusedIndex() }
                catch {
                    incompleteReason = String(describing: error)
                    incompleteOutcome = .invalidFocus
                }
            }
            progress.end(.raster, started: rasterStarted)
            if let incompleteReason {
                // Screenshots and AX attributes cannot be captured atomically.
                // A scroll can move between those reads, so retry the whole sample.
                lastReason = incompleteReason
                progress.sampleOutcome(incompleteOutcome ?? .invalidFocus, started: sampleStarted)
                previous = nil
            } else {
                if let previous, current.isStable(comparedTo: previous) {
                    progress.sampleOutcome(.stablePair, started: sampleStarted)
                    print("CARD_FOCUS_CAPTURE elapsed=\(ProcessInfo.processInfo.systemUptime - started) "
                        + "samples=\(samples) candidates=\(candidates.count) visible=\(observations.count)")
                    return current
                }
                progress.sampleOutcome(previous.map { current.mismatchOutcome(comparedTo: $0) }
                    ?? .firstComplete, started: sampleStarted)
                lastReason = "Rendered geometry is changing: \(current.summary)"
                previous = current
            }
            // The next iteration still needs a fresh complete AX/pixel sample;
            // its start gate replaces the unconditional post-processing sleep.
        }
        if let lastScreenshot {
            progress.measure(.attachment) {
                let attachment = XCTAttachment(screenshot: lastScreenshot)
                attachment.name = "focus-measurement-never-settled"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        throw CardFocusProbeError.unavailable("After 12 seconds: \(lastReason)")
    }

    @MainActor
    private func probeAttributes(in hierarchy: any XCUIElementSnapshot) -> [CardFocusAttributes] {
        var pending: [any XCUIElementSnapshot] = [hierarchy]
        var result: [CardFocusAttributes] = []
        while let snapshot = pending.popLast() {
            if snapshot.elementType == .button,
               snapshot.identifier.hasPrefix("channel.focus-probe.") {
                result.append(CardFocusAttributes(
                    identifier: snapshot.identifier, frame: snapshot.frame,
                    hasFocus: snapshot.hasFocus
                ))
            }
            pending.append(contentsOf: snapshot.children)
        }
        return result
    }

    @MainActor
    private func assertUnfocusedWidths(
        _ snapshot: CardFocusSnapshot, baseline: CGFloat, tolerance: CGFloat, label: String,
        progress: CardFocusProgress
    ) throws {
        _ = try snapshot.focusedIndex()
        print("CARD_FOCUS_SAMPLE phase=\(label) \(snapshot.summary)")
        let residual = snapshot.observations.filter {
            !$0.hasFocus && $0.visualWidth > baseline + tolerance
        }
        if !residual.isEmpty {
            attach(snapshot, name: "residual-focus-scale-\(label)", progress: progress)
            XCTFail("CARD_FOCUS_RESIDUAL baseline=\(baseline) tolerance=\(tolerance) "
                + "phase=\(label) \(snapshot.summary)")
            throw CardFocusProbeError.residualScale
        }
        XCTAssertGreaterThanOrEqual(snapshot.observations.filter { !$0.hasFocus }.count, 1,
            "Coverage failure: no unfocused peer was measured")
    }

    @MainActor
    private func attach(_ snapshot: CardFocusSnapshot, name: String, progress: CardFocusProgress) {
        progress.measure(.attachment) {
            let attachment = XCTAttachment(screenshot: snapshot.screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

/// Fixed scalar vocabulary only. Unbuffered writes preserve the last started
/// operation when XCTest interrupts a synchronous automation call. The CI relay
/// retains the last valid and last error record per case; these are not pass verdicts.
@MainActor
private final class CardFocusProgress {
    enum TestCase: String { case flat, grouped }
    enum Stage: String {
        case launch, entry, navigation, capture, ax, screenshot, raster, viewport, attachment, terminate
        case focusWait = "focus_wait"
    }
    enum Direction: String { case none, up, down, left, right, select }
    private enum Event: String { case begin, end, error }

    var cycle = -1
    var step = -1
    var sample = 0
    var direction: Direction = .none
    private let testCase: TestCase
    private let started = ProcessInfo.processInfo.systemUptime
    private var captures = 0
    private var sequence = 0
    private var cumulativeMilliseconds: [Stage: Int] = [:]
    private var lastNavigationEnd: TimeInterval?

    init(testCase: TestCase) { self.testCase = testCase }

    func settleAfterNavigation() {
        guard let lastNavigationEnd else { return }
        let age = max(0, ProcessInfo.processInfo.systemUptime - lastNavigationEnd)
        let delay = max(0, 0.5 - age)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        print("CARD_FOCUS_SETTLE case=\(testCase.rawValue) cycle=\(cycle) step=\(step) "
            + "direction=\(direction.rawValue) captures=\(captures) "
            + "navigation_age_ms=\(Int(age * 1_000)) delay_ms=\(Int(delay * 1_000))")
    }

    func sampleOutcome(_ outcome: CardFocusSampleOutcome, started: TimeInterval) {
        let navigationAge = lastNavigationEnd.map { max(0, Int((started - $0) * 1_000)) } ?? -1
        print("CARD_FOCUS_SAMPLE_OUTCOME case=\(testCase.rawValue) cycle=\(cycle) step=\(step) "
            + "direction=\(direction.rawValue) captures=\(captures) "
            + "sample=\(sample) outcome=\(outcome.rawValue) navigation_age_ms=\(navigationAge)")
    }

    func measure<T>(_ stage: Stage, _ operation: () throws -> T) rethrows -> T {
        let operationStarted = begin(stage)
        do {
            let result = try operation()
            end(stage, started: operationStarted)
            return result
        } catch {
            finish(stage, started: operationStarted, event: .error)
            throw error
        }
    }

    func begin(_ stage: Stage) -> TimeInterval {
        if stage == .capture { sample = 0 }
        let now = ProcessInfo.processInfo.systemUptime
        emit(stage, event: .begin, operationMilliseconds: 0, now: now)
        return now
    }

    func end(_ stage: Stage, started: TimeInterval) {
        finish(stage, started: started, event: .end)
    }

    private func finish(_ stage: Stage, started: TimeInterval, event: Event) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, Int((now - started) * 1_000))
        cumulativeMilliseconds[stage, default: 0] += elapsed
        if stage == .navigation && event == .end { lastNavigationEnd = now }
        if stage == .capture && event == .end { captures += 1 }
        emit(stage, event: event, operationMilliseconds: elapsed, now: now)
    }

    private func emit(_ stage: Stage, event: Event, operationMilliseconds: Int, now: TimeInterval) {
        sequence += 1
        let record: [String: Any] = [
            "schema": 1, "case": testCase.rawValue, "stage": stage.rawValue,
            "event": event.rawValue, "direction": direction.rawValue,
            "cycle": cycle, "step": step, "sample": sample, "captures": captures,
            "sequence": sequence, "elapsed_ms": max(0, Int((now - started) * 1_000)),
            "operation_ms": operationMilliseconds,
            "stage_ms": cumulativeMilliseconds[stage, default: 0],
            "capture_ms": cumulativeMilliseconds[.capture, default: 0]
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        var line = Data("CARD_FOCUS_PROGRESS ".utf8)
        line.append(json)
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }
}

private enum CardFocusProbeError: Error, CustomStringConvertible {
    case unavailable(String)
    case residualScale

    var description: String {
        switch self {
        case let .unavailable(reason): "CARD_FOCUS_MEASUREMENT_UNAVAILABLE: \(reason)"
        case .residualScale: "CARD_FOCUS_RESIDUAL: a nonfocused card retained measured visual expansion"
        }
    }
}

/// Value-only projection of one immutable AX hierarchy; reading these values
/// never resolves an element by index or makes another automation round trip.
private struct CardFocusAttributes {
    let identifier: String
    let frame: CGRect
    let hasFocus: Bool
}

private struct CardFocusObservation {
    let identifier: String
    let hasFocus: Bool
    let visualWidth: CGFloat
    let accessibilityFrame: CGRect

    var accessibilityWidth: CGFloat { accessibilityFrame.width }
}

private enum CardFocusSampleOutcome: String {
    case axUnavailable, missingMarker, invalidFocus, firstComplete, stablePair
    case peerCount, identifiers, focus, renderedWidth, position, otherChange
}

private struct CardFocusSnapshot {
    let observations: [CardFocusObservation]
    let screenshot: XCUIScreenshot

    var summary: String {
        observations.map {
            "\($0.identifier):focus=\($0.hasFocus),renderedWidthPoints=\($0.visualWidth),axWidth=\($0.accessibilityWidth)"
        }.joined(separator: " ")
    }

    func observation(_ identifier: String) throws -> CardFocusObservation {
        guard let value = observations.first(where: { $0.identifier == identifier }) else {
            throw CardFocusProbeError.unavailable("No fully visible observation for \(identifier): \(summary)")
        }
        return value
    }

    func focusedIndex() throws -> Int {
        let focused = observations.filter(\.hasFocus)
        guard focused.count == 1,
              let suffix = focused.first?.identifier.split(separator: ".").last,
              let index = Int(suffix) else {
            throw CardFocusProbeError.unavailable("Expected exactly one focused probe card: \(summary)")
        }
        return index
    }

    func isStable(comparedTo previous: Self) -> Bool {
        guard observations.count >= 2,
              observations.count == previous.observations.count else { return false }
        return zip(observations, previous.observations).allSatisfy { lhs, rhs in
            lhs.identifier == rhs.identifier && lhs.hasFocus == rhs.hasFocus
                && abs(lhs.visualWidth - rhs.visualWidth) <= 1
                && abs(lhs.accessibilityFrame.minX - rhs.accessibilityFrame.minX) <= 1
                && abs(lhs.accessibilityFrame.minY - rhs.accessibilityFrame.minY) <= 1
        }
    }

    // Failure categories use only the already captured values. They do not
    // participate in the acceptance predicate or add automation round trips.
    func mismatchOutcome(comparedTo previous: Self) -> CardFocusSampleOutcome {
        guard observations.count >= 2,
              observations.count == previous.observations.count else { return .peerCount }
        let pairs = Array(zip(observations, previous.observations))
        if pairs.contains(where: { $0.0.identifier != $0.1.identifier }) { return .identifiers }
        if pairs.contains(where: { $0.0.hasFocus != $0.1.hasFocus }) { return .focus }
        if pairs.contains(where: { abs($0.0.visualWidth - $0.1.visualWidth) > 1 }) { return .renderedWidth }
        if pairs.contains(where: {
            abs($0.0.accessibilityFrame.minX - $0.1.accessibilityFrame.minX) > 1
                || abs($0.0.accessibilityFrame.minY - $0.1.accessibilityFrame.minY) > 1
        }) { return .position }
        return .otherChange
    }
}

private enum CardFocusSamplingTiming {
    static func delayBeforeSample(
        now: TimeInterval, deadline: TimeInterval, previousScreenshotCompleted: TimeInterval?
    ) -> TimeInterval? {
        guard now < deadline else { return nil }
        let earliestSampleStart = previousScreenshotCompleted.map { $0 + 0.15 } ?? now
        guard earliestSampleStart < deadline else { return nil }
        return max(0, earliestSampleStart - now)
    }
}

final class ChannelCardFocusSamplingTimingTests: XCTestCase {
    func testFirstSampleDoesNotWaitForAnUnobservedScreenshot() throws {
        XCTAssertEqual(try XCTUnwrap(CardFocusSamplingTiming.delayBeforeSample(
            now: 4, deadline: 12, previousScreenshotCompleted: nil)), 0)
    }

    func testSlowScreenshotStillRequiresTheIntervalAfterItsCompletion() throws {
        // Capture started at t=0, but pixels may have been observed just before
        // it completed at t=1. Only the later 10 ms count toward the interval.
        XCTAssertEqual(try XCTUnwrap(CardFocusSamplingTiming.delayBeforeSample(
            now: 1.01, deadline: 12, previousScreenshotCompleted: 1)), 0.14, accuracy: 0.000_001)
    }

    func testRasterAndBookkeepingWorkConsumeThePollingInterval() throws {
        for elapsed in [0.15, 0.5, 2.4] {
            XCTAssertEqual(try XCTUnwrap(CardFocusSamplingTiming.delayBeforeSample(
                now: 4 + elapsed, deadline: 12, previousScreenshotCompleted: 4)), 0)
        }
    }

    func testExpiredDeadlineDoesNotAdmitAnotherSample() {
        for now in [12.0, 12.1] {
            XCTAssertNil(CardFocusSamplingTiming.delayBeforeSample(
                now: now, deadline: 12, previousScreenshotCompleted: nil))
        }
    }

    func testRequiredIntervalMustFinishBeforeTheDeadline() {
        for deadline in [0.10, 0.15] {
            XCTAssertNil(CardFocusSamplingTiming.delayBeforeSample(
                now: 0.05, deadline: deadline, previousScreenshotCompleted: 0))
        }
    }

    func testEnoughDeadlineRoomPreservesTheFullMinimumInterval() throws {
        let now = 0.05
        let delay = try XCTUnwrap(CardFocusSamplingTiming.delayBeforeSample(
            now: now, deadline: 0.16, previousScreenshotCompleted: 0))
        XCTAssertEqual(now + delay, 0.15, accuracy: 0.000_001)
        XCTAssertLessThan(now + delay, 0.16)
    }
}

final class ChannelCardFocusRasterTests: XCTestCase {
    func testPixelMeasurementDetectsScaleEvenWhenAccessibilityFrameDoesNotChange() throws {
        let frame = CGRect(x: 40, y: 40, width: 200, height: 100)
        let idle = raster(marker: 60..<220)
        let enlarged = raster(marker: 50..<230)
        XCTAssertEqual(try XCTUnwrap(idle.markerWidth(near: frame)), 160, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(enlarged.markerWidth(near: frame)), 180, accuracy: 0.001)
    }

    func testCGImageDecodingPreservesScreenPixelCoordinates() throws {
        let source = raster(marker: 60..<220)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(source.rgba) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: source.width, height: source.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: source.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let decoded = try CardFocusRaster(image: image, screenFrame: source.screenFrame)
        XCTAssertEqual(try XCTUnwrap(decoded.markerWidth(
            near: CGRect(x: 40, y: 40, width: 200, height: 100)
        )), 160, accuracy: 0.001)
        XCTAssertNil(decoded.markerWidth(
            near: CGRect(x: 40, y: 140, width: 200, height: 100)
        ), "Decoding must not mirror the line to the bottom of the screen")
        let doubled = try CardFocusRaster(image: image,
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 100))
        XCTAssertEqual(try XCTUnwrap(doubled.markerWidth(
            near: CGRect(x: 20, y: 20, width: 100, height: 50)
        )), 80, accuracy: 0.001)
    }

    func testClippedMarkerIsUnavailableRatherThanAnUnderestimatedWidth() {
        XCTAssertNil(raster(marker: 0..<220).markerWidth(
            near: CGRect(x: 40, y: 40, width: 200, height: 100)
        ))
    }

    func testMissingMarkerIsUnavailableRatherThanZeroWidth() {
        XCTAssertNil(raster(marker: 0..<0).markerWidth(
            near: CGRect(x: 40, y: 40, width: 200, height: 100)
        ))
    }

    func testAnotherCardsMarkerCannotStandInForTheRequestedCard() {
        XCTAssertNil(raster(marker: 60..<220).markerWidth(
            near: CGRect(x: 350, y: 40, width: 200, height: 100)
        ))
    }

    func testMarkerSearchIsBoundedByRowsAndIntersectingRuns() throws {
        let frame = CGRect(x: 40, y: 40, width: 200, height: 100)
        var inspectedPixelCount = 0
        XCTAssertEqual(try XCTUnwrap(raster(marker: 60..<220).markerWidth(
            near: frame, inspectedPixelCount: &inspectedPixelCount
        )), 160, accuracy: 0.001)
        // 100 candidate rows plus six 160-pixel marker runs and their edges.
        // Scanning all 260 columns per row would exceed this by over 20 times.
        XCTAssertLessThanOrEqual(inspectedPixelCount, 1_100,
            "Empty rows must use one center-column read, not a full-width scan")
    }

    func testCenteredMarkerSearchPreservesGeometryRejectionsAndLongestRun() throws {
        let frame = CGRect(x: 40, y: 40, width: 200, height: 100)
        for marker in [60..<220, 61..<221, 90..<190] {
            XCTAssertEqual(try XCTUnwrap(raster(marker: marker).markerWidth(near: frame)),
                CGFloat(marker.count), accuracy: 0.001)
        }
        for marker in [84..<244, 34..<194, 91..<189] {
            XCTAssertNil(raster(marker: marker).markerWidth(near: frame),
                "Center tolerance and minimum run length must still reject \(marker)")
        }
        let fractionalCenter = CGRect(x: 139.0625, y: 40, width: 1, height: 100)
        XCTAssertEqual(try XCTUnwrap(raster(marker: 139..<140).markerWidth(
            near: fractionalCenter
        )), 1, accuracy: 0.001,
            "The center column must be floored; rounding would miss this accepted run")
        XCTAssertNil(raster(marker: 60..<300).markerWidth(near: frame),
            "A run crossing the right search edge must remain unavailable")
        let split = raster(markers: [(40..<46, 60..<130), (40..<46, 150..<220)])
        XCTAssertNil(split.markerWidth(near: frame), "Separated runs must not be joined")
        let varied = raster(markers: [(40..<42, 60..<220), (42..<46, 50..<230)])
        XCTAssertEqual(try XCTUnwrap(varied.markerWidth(near: frame)), 180, accuracy: 0.001,
            "All marker rows must be measured, including a later, wider run")
    }

    func testInvalidRasterStorageAndNonfiniteBoundsAreUnavailable() {
        let frame = CGRect(x: 40, y: 40, width: 200, height: 100)
        let short = CardFocusRaster(width: 600, height: 200,
            screenFrame: CGRect(x: 0, y: 0, width: 600, height: 200), rgba: [0])
        XCTAssertNil(short.markerWidth(near: frame))
        XCTAssertNil(raster(marker: 60..<220).markerWidth(near: .null))
        let invalidScreen = CardFocusRaster(width: 600, height: 200,
            screenFrame: CGRect(x: 0, y: 0, width: 0, height: 200),
            rgba: raster(marker: 60..<220).rgba)
        XCTAssertNil(invalidScreen.markerWidth(near: frame))
    }

    private func raster(marker: Range<Int>) -> CardFocusRaster {
        raster(markers: [(40..<46, marker)])
    }

    private func raster(markers: [(rows: Range<Int>, columns: Range<Int>)]) -> CardFocusRaster {
        var pixels = [UInt8](repeating: 0, count: 600 * 200 * 4)
        for marker in markers {
            for y in marker.rows {
                for x in marker.columns {
                    let offset = (y * 600 + x) * 4
                    pixels[offset] = 255
                    pixels[offset + 2] = 255
                    pixels[offset + 3] = 255
                }
            }
        }
        return CardFocusRaster(width: 600, height: 200,
            screenFrame: CGRect(x: 0, y: 0, width: 600, height: 200), rgba: pixels)
    }
}

/// Reads a saturated magenta line inside the native button label. The rendered
/// marker inherits the card's transform, unlike an AX frame or @FocusState flag.
private struct CardFocusRaster {
    let width: Int
    let height: Int
    let screenFrame: CGRect
    let rgba: [UInt8]

    init(width: Int, height: Int, screenFrame: CGRect, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.screenFrame = screenFrame
        self.rgba = rgba
    }

    init(image: CGImage, screenFrame: CGRect) throws {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard decoded, screenFrame.width > 0, screenFrame.height > 0 else {
            throw CardFocusProbeError.unavailable("Screenshot RGBA decoding failed")
        }
        self.init(width: width, height: height, screenFrame: screenFrame, rgba: pixels)
    }

    func markerWidth(near frame: CGRect) -> CGFloat? {
        var inspectedPixelCount = 0
        return markerWidth(near: frame, inspectedPixelCount: &inspectedPixelCount)
    }

    func markerWidth(near frame: CGRect, inspectedPixelCount: inout Int) -> CGFloat? {
        // Validate one contiguous read before scanning the screenshot. Repeated
        // Array subscripts make this diagnostic unnecessarily slow in Debug;
        // the pointer stays inside this synchronous, owner-retaining closure.
        guard width > 0, height > 0, screenFrame.width > 0, screenFrame.height > 0,
              frame.width > 0, frame.height > 0,
              [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
               frame.minX, frame.maxX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
        let area = width.multipliedReportingOverflow(by: height)
        let byteCount = area.partialValue.multipliedReportingOverflow(by: 4)
        guard !area.overflow, !byteCount.overflow, rgba.count == byteCount.partialValue else { return nil }
        let scaleX = CGFloat(width) / screenFrame.width
        let scaleY = CGFloat(height) / screenFrame.height
        let centreX = (frame.midX - screenFrame.minX) * scaleX
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0, centreX.isFinite else { return nil }
        // Include native visual scale even on platforms where AX reports only
        // the untransformed layout rectangle. Do not include adjacent centres.
        let bounds = [((frame.minX - 30 - screenFrame.minX) * scaleX).rounded(.down),
                      ((frame.maxX + 30 - screenFrame.minX) * scaleX).rounded(.up),
                      ((frame.minY - 60 - screenFrame.minY) * scaleY).rounded(.down),
                      ((frame.minY + 60 - screenFrame.minY) * scaleY).rounded(.up)]
        guard bounds.allSatisfy(\.isFinite) else { return nil }
        let x0 = Int(min(CGFloat(width), max(0, bounds[0])))
        let x1 = Int(min(CGFloat(width), max(0, bounds[1])))
        let y0 = Int(min(CGFloat(height), max(0, bounds[2])))
        let y1 = Int(min(CGFloat(height), max(0, bounds[3])))
        guard x0 < x1, y0 < y1 else { return nil }
        // Every accepted run spans the center column: its half-length is at
        // least 25% of the card width while its center offset is below 12%.
        // Empty rows therefore need only one pixel read. This preserves the
        // longest complete run, clipping rejection and all geometry thresholds.
        guard centreX >= CGFloat(x0), centreX < CGFloat(x1) else { return nil }
        let centerColumn = Int(centreX.rounded(.down))
        return rgba.withUnsafeBufferPointer { storage in
            guard let base = storage.baseAddress else { return nil }
            func isMarker(_ x: Int, row: UnsafePointer<UInt8>) -> Bool {
                inspectedPixelCount += 1
                let pixel = row.advanced(by: x * 4)
                return pixel[0] >= 180 && pixel[1] <= 100 && pixel[2] >= 180
            }
            var longest = 0
            for y in y0..<y1 {
                let row = base.advanced(by: y * width * 4)
                guard isMarker(centerColumn, row: row) else { continue }
                var runStart = centerColumn
                while runStart > x0, isMarker(runStart - 1, row: row) {
                    runStart -= 1
                }
                var runEnd = centerColumn + 1
                while runEnd < x1, isMarker(runEnd, row: row) {
                    runEnd += 1
                }
                let length = runEnd - runStart
                let centre = CGFloat(runStart + runEnd) / 2
                if runStart > x0, runEnd < x1,
                   abs(centre - centreX) < frame.width * scaleX * 0.12,
                   CGFloat(length) >= frame.width * scaleX * 0.5 {
                    longest = max(longest, length)
                }
            }
            guard longest > 0 else { return nil }
            let measured = CGFloat(longest) / scaleX
            return measured.isFinite ? measured : nil
        }
    }
}
