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
        for _ in 0..<5 where !row.hasFocus && !cell.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(
            row.hasFocus || cell.hasFocus,
            "Expected focus to reach settings row \(row.identifier)"
        )
    }
}


/// Diagnostic tests keep the production grid and native CardButtonStyle intact.
/// Only the synthetic fixture supplies a layout-neutral colored measurement line.
final class ChannelCardFocusDiagnosticTests: XCTestCase {
    @MainActor
    func testFlatPlaylistCardsLoseVisualFocusAfterScrolling() throws {
        try exerciseFocusAndScroll(grouping: "playlistOrder")
    }

    @MainActor
    func testGroupedPlaylistCardsLoseVisualFocusAfterScrolling() throws {
        try exerciseFocusAndScroll(grouping: "playlistGroups")
    }

    @MainActor
    private func exerciseFocusAndScroll(grouping: String) throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-fixture", "seeded", "-uiTestResetPlaybackSettings",
            "-ui-card-focus-diagnostics", "-channels.grouping", grouping,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]
        app.launch()
        defer { app.terminate() }
        let first = app.buttons["channel.focus-probe.000"]
        let second = app.buttons["channel.focus-probe.001"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        try enterChannelGrid(app: app, first: first)

        // Calibrate on rendered pixels before asserting anything about residual
        // scale. AX frame widths are logged only, never used as the visual oracle.
        let initial = try stableSnapshot(app: app)
        let firstFocused = try initial.observation("channel.focus-probe.000")
        let secondUnfocused = try initial.observation("channel.focus-probe.001")
        let baseline = secondUnfocused.visualWidth
        let focusDelta = firstFocused.visualWidth - baseline
        guard firstFocused.hasFocus, !secondUnfocused.hasFocus,
              focusDelta >= 3, focusDelta < baseline * 0.3 else {
            attach(initial, name: "focus-calibration-unavailable-\(grouping)")
            throw CardFocusProbeError.unavailable(
                "Initial rendered focus expansion could not be calibrated: \(initial.summary)"
            )
        }
        print("CARD_FOCUS_CALIBRATION grouping=\(grouping) baseline=\(baseline) "
            + "focusDelta=\(focusDelta) \(initial.summary)")
        attach(initial, name: "focus-calibration-initial-\(grouping)")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(second.wait(for: \.hasFocus, toEqual: true, timeout: 5))
        let moved = try stableSnapshot(app: app)
        let secondFocused = try moved.observation("channel.focus-probe.001")
        guard secondFocused.visualWidth - baseline >= 3 else {
            attach(moved, name: "focus-calibration-move-unavailable-\(grouping)")
            throw CardFocusProbeError.unavailable(
                "Pixels did not measure expansion on the newly focused card: \(moved.summary)"
            )
        }
        let tolerance = max(2, focusDelta * 0.2)
        try assertUnfocusedWidths(moved, baseline: baseline, tolerance: tolerance,
            label: "\(grouping)-initial-right")
        attach(moved, name: "focus-calibration-moved-\(grouping)")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(first.wait(for: \.hasFocus, toEqual: true, timeout: 5))

        for cycle in 0..<2 {
            var snapshot = try stableSnapshot(app: app)
            var reachedBottom = false
            for step in 0..<30 {
                if try snapshot.focusedIndex() >= 75 {
                    reachedBottom = true
                    break
                }
                let index = try snapshot.focusedIndex()
                if cycle == 1 && index < 60 {
                    XCUIRemote.shared.press(.down, forDuration: 0.5)
                } else {
                    XCUIRemote.shared.press(.down)
                }
                snapshot = try stableSnapshot(app: app)
                try assertUnfocusedWidths(snapshot, baseline: baseline, tolerance: tolerance,
                    label: "\(grouping)-cycle\(cycle)-down\(step)")
            }
            if !reachedBottom { reachedBottom = try snapshot.focusedIndex() >= 75 }
            XCTAssertTrue(reachedBottom, "Coverage failure: did not reach the last fixture rows")
            XCTAssertFalse(first.isHittable, "Coverage failure: the first card never left the viewport")
            attach(snapshot, name: "focus-bottom-\(grouping)-\(cycle)")

            var reachedTop = false
            for step in 0..<30 {
                if try snapshot.focusedIndex() == 0 {
                    reachedTop = true
                    break
                }
                let index = try snapshot.focusedIndex()
                if cycle == 1 && index > 20 {
                    XCUIRemote.shared.press(.up, forDuration: 0.5)
                } else {
                    XCUIRemote.shared.press(.up)
                }
                snapshot = try stableSnapshot(app: app)
                try assertUnfocusedWidths(snapshot, baseline: baseline, tolerance: tolerance,
                    label: "\(grouping)-cycle\(cycle)-up\(step)")
            }
            if !reachedTop { reachedTop = try snapshot.focusedIndex() == 0 }
            XCTAssertTrue(reachedTop, "Coverage failure: did not return to the first fixture card")
            XCTAssertTrue(first.hasFocus)
            attach(snapshot, name: "focus-returned-\(grouping)-\(cycle)")
        }
        print("CARD_FOCUS_RESULT grouping=\(grouping) calibrated=true cycles=2 residualScale=notObserved")
    }

    @MainActor
    private func enterChannelGrid(app: XCUIApplication, first: XCUIElement) throws {
        logEntryFocus(app: app, phase: "launch")
        if first.hasFocus { return }

        // defaultFocus chooses an item when the grid receives focus; it does not
        // promise that a freshly launched TabView has entered that region. Use
        // the same real remote tab-entry flow as the existing application tests.
        let channelTab = app.tabBars.buttons["频道"]
        for _ in 0..<8 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        guard app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) else {
            throw entryFailure(app: app, reason: "Could not acquire the tab bar")
        }
        for _ in 0..<3 { XCUIRemote.shared.press(.left) }
        for _ in 0..<4 where !channelTab.hasFocus { XCUIRemote.shared.press(.right) }
        guard channelTab.hasFocus else {
            throw entryFailure(app: app, reason: "Could not focus the channels tab")
        }
        XCUIRemote.shared.press(.select)
        // Some tvOS configurations retain focus on the selected tab until Down.
        // Never Select a channel here: the experiment must not open playback.
        for _ in 0..<4 {
            if first.wait(for: \.hasFocus, toEqual: true, timeout: 2) {
                logEntryFocus(app: app, phase: "entered-grid")
                return
            }
            XCUIRemote.shared.press(.down)
        }
        guard first.wait(for: \.hasFocus, toEqual: true, timeout: 2) else {
            throw entryFailure(app: app, reason: "Channels tab entry did not focus the first probe card")
        }
        logEntryFocus(app: app, phase: "entered-grid")
    }

    @MainActor
    private func logEntryFocus(app: XCUIApplication, phase: String) {
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map {
            "\($0.label):focus=\($0.hasFocus)"
        }.joined(separator: " ")
        let first = app.buttons["channel.focus-probe.000"]
        print("CARD_FOCUS_ENTRY phase=\(phase) firstFocus=\(first.hasFocus) tabs=[\(tabs)]")
    }

    @MainActor
    private func entryFailure(app: XCUIApplication, reason: String) -> CardFocusProbeError {
        logEntryFocus(app: app, phase: "failed-entry")
        print("CARD_FOCUS_ENTRY_HIERARCHY \(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "focus-entry-unavailable"
        attachment.lifetime = .keepAlways
        add(attachment)
        return .unavailable(reason)
    }

    @MainActor
    private func stableSnapshot(app: XCUIApplication) throws -> CardFocusSnapshot {
        let started = Date()
        let deadline = started.addingTimeInterval(12)
        var previous: CardFocusSnapshot?
        var lastScreenshot: XCUIScreenshot?
        var lastReason = "Rendered focus/scroll state never stabilized"
        var samples = 0
        while Date() < deadline {
            samples += 1
            // Capture the hierarchy once. Live index-bound XCUIElement proxies
            // can change identity or disappear as LazyVGrid realizes/removes rows;
            // querying each attribute also used to cost 10+ seconds per checkpoint.
            let hierarchy: any XCUIElementSnapshot
            do {
                hierarchy = try app.snapshot()
            } catch {
                lastReason = "Could not capture the AX hierarchy: \(error)"
                previous = nil
                Thread.sleep(forTimeInterval: 0.15)
                continue
            }
            let candidates = probeAttributes(in: hierarchy)
            let screenshot = XCUIScreen.main.screenshot()
            lastScreenshot = screenshot
            let screenFrame = hierarchy.frame
            guard let image = screenshot.image.cgImage else {
                throw CardFocusProbeError.unavailable("Screenshot has no CGImage")
            }
            let raster = try CardFocusRaster(image: image, screenFrame: screenFrame)
            var observations: [CardFocusObservation] = []
            var incompleteReason: String?
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
                catch { incompleteReason = String(describing: error) }
            }
            if let incompleteReason {
                // Screenshots and AX attributes cannot be captured atomically.
                // A scroll can move between those reads, so retry the whole sample.
                lastReason = incompleteReason
                previous = nil
            } else {
                if let previous, current.isStable(comparedTo: previous) {
                    print("CARD_FOCUS_CAPTURE elapsed=\(Date().timeIntervalSince(started)) "
                        + "samples=\(samples) candidates=\(candidates.count) visible=\(observations.count)")
                    return current
                }
                lastReason = "Rendered geometry is changing: \(current.summary)"
                previous = current
            }
            // Poll for stable rendered widths and AX positions, rather than
            // treating a transient screenshot/AX mismatch as a product failure.
            Thread.sleep(forTimeInterval: 0.15)
        }
        if let lastScreenshot {
            let attachment = XCTAttachment(screenshot: lastScreenshot)
            attachment.name = "focus-measurement-never-settled"
            attachment.lifetime = .keepAlways
            add(attachment)
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
        _ snapshot: CardFocusSnapshot, baseline: CGFloat, tolerance: CGFloat, label: String
    ) throws {
        _ = try snapshot.focusedIndex()
        print("CARD_FOCUS_SAMPLE phase=\(label) \(snapshot.summary)")
        let residual = snapshot.observations.filter {
            !$0.hasFocus && $0.visualWidth > baseline + tolerance
        }
        if !residual.isEmpty {
            attach(snapshot, name: "residual-focus-scale-\(label)")
            XCTFail("CARD_FOCUS_RESIDUAL baseline=\(baseline) tolerance=\(tolerance) "
                + "phase=\(label) \(snapshot.summary)")
            throw CardFocusProbeError.residualScale
        }
        XCTAssertGreaterThanOrEqual(snapshot.observations.filter { !$0.hasFocus }.count, 1,
            "Coverage failure: no unfocused peer was measured")
    }

    @MainActor
    private func attach(_ snapshot: CardFocusSnapshot, name: String) {
        let attachment = XCTAttachment(screenshot: snapshot.screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func raster(marker: Range<Int>) -> CardFocusRaster {
        var pixels = [UInt8](repeating: 0, count: 600 * 200 * 4)
        for y in 40..<46 {
            for x in marker {
                let offset = (y * 600 + x) * 4
                pixels[offset] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
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
        let scaleX = CGFloat(width) / screenFrame.width
        let scaleY = CGFloat(height) / screenFrame.height
        let centreX = (frame.midX - screenFrame.minX) * scaleX
        // Include native visual scale even on platforms where AX reports only
        // the untransformed layout rectangle. Do not include adjacent centres.
        let x0 = max(0, Int(((frame.minX - 30 - screenFrame.minX) * scaleX).rounded(.down)))
        let x1 = min(width, Int(((frame.maxX + 30 - screenFrame.minX) * scaleX).rounded(.up)))
        let y0 = max(0, Int(((frame.minY - 60 - screenFrame.minY) * scaleY).rounded(.down)))
        let y1 = min(height, Int(((frame.minY + 60 - screenFrame.minY) * scaleY).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return nil }
        var longest = 0
        for y in y0..<y1 {
            var start: Int?
            for x in x0...x1 {
                let offset = (y * width + min(x, width - 1)) * 4
                let isMarker = x < x1 && rgba[offset] >= 180
                    && rgba[offset + 1] <= 100 && rgba[offset + 2] >= 180
                if isMarker {
                    if start == nil { start = x }
                } else if let runStart = start {
                    let length = x - runStart
                    let centre = CGFloat(runStart + x) / 2
                    if runStart > x0, x < x1,
                       abs(centre - centreX) < frame.width * scaleX * 0.12,
                       CGFloat(length) >= frame.width * scaleX * 0.5 {
                        longest = max(longest, length)
                    }
                    start = nil
                }
            }
        }
        return longest > 0 ? CGFloat(longest) / scaleX : nil
    }
}
