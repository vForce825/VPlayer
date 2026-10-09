// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest

@MainActor
final class IOSLibraryFlowTests: XCTestCase {
    private func identified(_ identifier: String, in query: XCUIElementQuery) -> XCUIElementQuery {
        query.matching(NSPredicate(format: "identifier == %@", identifier))
    }
    private func deletionConfirmationButtons(in element: XCUIElement) -> XCUIElementQuery {
        element.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH %@)",
                                            "删除", "source.delete."))
    }
    private func cancellationPoint(appFrame: CGRect, sheetFrame: CGRect) -> CGPoint? {
        guard !appFrame.isEmpty, !sheetFrame.isEmpty, !appFrame.isInfinite, !sheetFrame.isInfinite,
              [appFrame.minX, appFrame.minY, appFrame.maxX, appFrame.maxY,
               sheetFrame.minX, sheetFrame.minY, sheetFrame.maxX, sheetFrame.maxY].allSatisfy({ $0.isFinite }),
              appFrame.intersects(sheetFrame) else { return nil }
        let safeApp = appFrame.insetBy(dx: 44, dy: 44)
        guard safeApp.size.width >= 44, safeApp.size.height >= 44 else { return nil }
        let excluded = sheetFrame.insetBy(dx: -22, dy: -22)
        let regions = [
            CGRect(x: safeApp.minX, y: safeApp.minY, width: safeApp.width, height: excluded.minY - safeApp.minY),
            CGRect(x: safeApp.minX, y: excluded.maxY, width: safeApp.width, height: safeApp.maxY - excluded.maxY),
            CGRect(x: safeApp.minX, y: safeApp.minY, width: excluded.minX - safeApp.minX, height: safeApp.height),
            CGRect(x: excluded.maxX, y: safeApp.minY, width: safeApp.maxX - excluded.maxX, height: safeApp.height)
        ]
        return regions.filter { $0.size.width >= 44 && $0.size.height >= 44 }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .map { CGPoint(x: $0.midX, y: $0.midY) }
            .first { safeApp.contains($0) && !excluded.contains($0) }
    }
    private func cancelDeletionConfirmation(in app: XCUIApplication) {
        let cancel = app.buttons["取消"]
        if cancel.exists {
            require(cancel, in: app, stage: "delete-cancel-confirmation", timeout: 5, hittable: true)
            cancel.tap()
            return
        }

        // Popover action sheets omit Cancel; outside dismissal cancels them.
        // Every fallback must first identify the actual confirmation sheet.
        let sheet = app.sheets.firstMatch
        guard app.sheets.count == 1,
              sheet.staticTexts["已导入的频道和节目单会一并移除。"].exists,
              deletionConfirmationButtons(in: sheet).count == 1 else {
            XCTFail(failureDetails(in: app, stage: "delete-cancel-sheet-identity"))
            return
        }
        let appFrame = app.frame
        let sheetFrame = sheet.frame
        let noticeFrame = sheet.staticTexts["已导入的频道和节目单会一并移除。"].frame
        let confirmFrame = deletionConfirmationButtons(in: sheet).firstMatch.frame
        guard !appFrame.isEmpty, !sheetFrame.isEmpty, !appFrame.isInfinite, !sheetFrame.isInfinite,
              !noticeFrame.isEmpty, !confirmFrame.isEmpty,
              [appFrame.minX, appFrame.minY, appFrame.maxX, appFrame.maxY,
               sheetFrame.minX, sheetFrame.minY, sheetFrame.maxX, sheetFrame.maxY].allSatisfy({ $0.isFinite }),
              appFrame.intersects(sheetFrame), sheetFrame.contains(noticeFrame), sheetFrame.contains(confirmFrame) else {
            XCTFail(failureDetails(in: app, stage: "delete-cancel-sheet-geometry"))
            return
        }
        let safeApp = appFrame.insetBy(dx: 44, dy: 44)
        let excluded = sheetFrame.insetBy(dx: -22, dy: -22)
        let dismissRegions = identified("PopoverDismissRegion", in: app.descendants(matching: .any))
        if dismissRegions.count == 1 {
            let dismiss = dismissRegions.firstMatch
            let frame = dismiss.frame
            if !frame.isEmpty, !frame.isInfinite,
               [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy({ $0.isFinite }),
               safeApp.contains(frame), !excluded.intersects(frame), dismiss.isHittable {
                print("IOS_DELETE_CANCEL method=system-dismiss appFrame=\(appFrame) sheetFrame=\(sheetFrame) dismissFrame=\(frame)")
                dismiss.tap()
                return
            }
        }
        // Derive an exterior point from live frames, with margins from both the
        // app edges and sheet. No coordinates are guessed from a device model.
        guard let point = cancellationPoint(appFrame: appFrame, sheetFrame: sheetFrame) else {
            XCTFail(failureDetails(in: app, stage: "delete-cancel-no-observed-exterior"))
            return
        }
        print("IOS_DELETE_CANCEL method=observed-exterior appFrame=\(appFrame) sheetFrame=\(sheetFrame) point=\(point)")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - appFrame.minX, dy: point.y - appFrame.minY)).tap()
    }
    private func failureDetails(in app: XCUIApplication, stage: String) -> String {
        let route = app.descendants(matching: .any)
            .matching(identifier: "ios.playback.route").firstMatch
        let snapshot = route.exists ? (route.value as? String ?? "value-unavailable") : "probe-unavailable"
        let channel = app.buttons["channel.http"]
        let channelExists = channel.exists
        let playerExists = app.buttons["player-back"].exists
        let playerContainerExists = app.descendants(matching: .any)
            .matching(identifier: "player-full-screen").firstMatch.exists
        let miniPlayerExists = app.buttons["player-mini-resume"].exists
        let channelNavigationExists = app.navigationBars["频道"].exists
        let closeByLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "关闭播放"))
        let knownIdentifiers = ["player-back", "player-full-screen", "player-pip", "player-settings"]
        let closeElements = closeByLabel.allElementsBoundByIndex.prefix(3).map { element in
            let identifier = knownIdentifiers.contains(element.identifier) ? element.identifier : "other"
            return "role=\(element.elementType.rawValue):id=\(identifier):hit=\(element.isHittable):frame=\(element.frame)"
        }.joined(separator: ";")
        let screenIDButtons = identified("player-full-screen", in: app.buttons).count
        let cancellationButtons = app.buttons.matching(NSPredicate(format: "label == %@", "取消"))
        let cancellationControls = cancellationButtons.allElementsBoundByIndex.prefix(3).map { element in
            "role=\(element.elementType.rawValue):hit=\(element.isHittable):frame=\(element.frame)"
        }.joined(separator: ";")
        let confirmationButtons = deletionConfirmationButtons(in: app)
        let confirmationControls = confirmationButtons.allElementsBoundByIndex.prefix(3).map { element in
            "role=\(element.elementType.rawValue):hit=\(element.isHittable):frame=\(element.frame)"
        }.joined(separator: ";")
        let deletionNotice = app.staticTexts["已导入的频道和节目单会一并移除。"]
        let deletionNoticeDetails = deletionNotice.exists ? "frame=\(deletionNotice.frame)" : "absent"
        let sheetFrames = app.sheets.allElementsBoundByIndex.prefix(2).map { "\($0.frame)" }.joined(separator: ";")
        let dismissRegions = identified("PopoverDismissRegion", in: app.descendants(matching: .any))
        let dismissControls = dismissRegions.allElementsBoundByIndex.prefix(2).map { element in
            "role=\(element.elementType.rawValue):hit=\(element.isHittable):frame=\(element.frame)"
        }.joined(separator: ";")
        return "IOS_UI_STAGE=\(stage) IOS_UI_ROUTE=\(snapshot) " +
            "playerBack=\(playerExists) playerContainer=\(playerContainerExists) miniPlayer=\(miniPlayerExists) " +
            "row=channel.http exists=\(channelExists) hittable=\(channelExists && channel.isHittable) " +
            "channelNavigation=\(channelNavigationExists) alerts=\(app.alerts.count) sheets=\(app.sheets.count) " +
            "appFrame=\(app.frame) sheetFrames=[\(sheetFrames)] dismissRegions=[\(dismissControls)] " +
            "deletionNotice=\(deletionNoticeDetails) editor=\(app.textFields["source.editor.name"].exists) " +
            "cancelButtons=\(cancellationButtons.count) cancellationControls=[\(cancellationControls)] " +
            "confirmDeleteButtons=\(confirmationButtons.count) confirmationControls=[\(confirmationControls)] " +
            "screenIDButtons=\(screenIDButtons) closeLabelMatches=\(closeByLabel.count) closeElements=[\(closeElements)]"
    }
    private func require(_ element: XCUIElement, in app: XCUIApplication, stage: String,
                         timeout: TimeInterval, hittable: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) {
        let found = hittable ? element.wait(for: \.isHittable, toEqual: true, timeout: timeout)
            : element.waitForExistence(timeout: timeout)
        XCTAssertTrue(found, found ? "" : failureDetails(in: app, stage: stage),
            file: file, line: line)
    }
    private func launch(playbackFixture: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "seeded", "-uiTestResetPlaybackSettings",
                               "-ui-playback-route-diagnostics"]
        if let playbackFixture { app.launchArguments += ["-ui-playback-fixture", playbackFixture] }
        app.launch()
        return app
    }
    private func assertPlayerControls(in app: XCUIApplication, stage: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        // Detailed accessibility queries can exceed the real idle timeout.
        // Pause through the actual button before inspecting its sibling controls.
        let pause = app.buttons["player-play-pause"]
        if !pause.exists { tapPlayerBackground(in: app) }
        require(pause, in: app, stage: stage + "-pause-for-inspection", timeout: 3, hittable: true)
        if pause.label == "暂停" { pause.tap() }
        XCTAssertTrue(pause.wait(for: \.label, toEqual: "播放", timeout: 3), file: file, line: line)
        let screens = identified("player-full-screen", in: app.descendants(matching: .any))
        XCTAssertEqual(screens.count, 1, failureDetails(in: app, stage: stage + "-screen-identity"),
            file: file, line: line)
        XCTAssertEqual(identified("player-full-screen", in: app.buttons).count, 0,
            failureDetails(in: app, stage: stage + "-screen-is-not-button"), file: file, line: line)
        let screen = screens.firstMatch
        for (identifier, label) in [("player-back", "关闭播放"), ("player-pip", "画中画"),
                                     ("player-settings", "播放设置")] {
            let buttons = identified(identifier, in: screen.descendants(matching: .button))
            XCTAssertEqual(buttons.count, 1, failureDetails(in: app, stage: stage + "-" + identifier),
                file: file, line: line)
            let button = buttons.firstMatch
            XCTAssertEqual(button.identifier, identifier, file: file, line: line)
            XCTAssertEqual(button.elementType, .button, file: file, line: line)
            XCTAssertEqual(button.label, label, file: file, line: line)
            if identifier != "player-pip" {
                XCTAssertTrue(button.isEnabled, file: file, line: line)
                XCTAssertTrue(button.isHittable, failureDetails(in: app, stage: stage + "-" + identifier + "-hit"),
                    file: file, line: line)
            } else {
                // The seeded engine does not install a native PiP presentation.
                XCTAssertFalse(button.isEnabled, file: file, line: line)
            }
        }
    }
    func testTouchChannelSelectionCloseAndReopen() {
        let app = launch()
        defer { app.terminate() }
        let channel = app.buttons["channel.http"]
        require(channel, in: app, stage: "initial-channel", timeout: 15)
        for cycle in 1...3 {
            channel.tap()
            require(app.buttons["player-back"], in: app, stage: "touch-cycle-\(cycle)-player-back", timeout: 5)
            assertPlayerControls(in: app, stage: "touch-cycle-\(cycle)")
            app.buttons["player-back"].tap()
            require(channel, in: app, stage: "touch-cycle-\(cycle)-channel-after-close", timeout: 5, hittable: true)
            XCTAssertFalse(identified("player-full-screen", in: app.descendants(matching: .any)).firstMatch.exists,
                failureDetails(in: app, stage: "touch-cycle-\(cycle)-player-dismissed"))
        }
    }
    private func tapPlayerBackground(in app: XCUIApplication) {
        let screen = identified("player-full-screen", in: app.descendants(matching: .any)).firstMatch
        require(screen, in: app, stage: "controls-background-screen", timeout: 5)
        // The observed center is outside the top bar and bottom transport card.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func playerSessionIdentity(in app: XCUIApplication) -> String {
        let screen = identified("player-full-screen", in: app.descendants(matching: .any)).firstMatch
        let value = screen.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("session="), failureDetails(in: app, stage: "controls-session-identity"))
        return value
    }
    private func assertPlayerSession(_ identity: String, in app: XCUIApplication) {
        XCTAssertEqual(playerSessionIdentity(in: app), identity, "Controls must not replace the playback session")
        let route = app.descendants(matching: .any).matching(identifier: "ios.playback.route").firstMatch
        let snapshot = route.value as? String ?? ""
        for expected in ["session=true", "matching=true", "closing=false", "fullScreen=true"] {
            XCTAssertTrue(snapshot.contains(expected), failureDetails(in: app, stage: "controls-session-preserved"))
        }
        XCTAssertFalse(snapshot.contains("session-close:"), "Controls must not stop playback")
    }
    func testPlaybackControlsBackgroundTapAndIdleTimeoutPreserveSession() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "controls-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        let back = app.buttons["player-back"]
        require(back, in: app, stage: "controls-initial", timeout: 5)
        let identity = playerSessionIdentity(in: app)
        // First allow the real three-second task to hide both overlay bars.
        XCTAssertTrue(back.waitForNonExistence(timeout: 6), "The top bar must auto-hide during playback")
        XCTAssertFalse(app.buttons["player-play-pause"].exists)
        XCTAssertFalse(app.statusBars.firstMatch.exists, "The system status bar follows the overlay")
        assertPlayerSession(identity, in: app)
        tapPlayerBackground(in: app)
        require(back, in: app, stage: "controls-tap-show", timeout: 2, hittable: true)
        tapPlayerBackground(in: app)
        XCTAssertTrue(back.waitForNonExistence(timeout: 2), "A second background tap hides immediately")
        tapPlayerBackground(in: app)
        require(app.buttons["player-play-pause"], in: app, stage: "controls-reshown", timeout: 2, hittable: true)
        app.buttons["player-play-pause"].tap()
        XCTAssertTrue(app.buttons["player-play-pause"].wait(for: \.label, toEqual: "播放", timeout: 3))
        XCTAssertFalse(back.waitForNonExistence(timeout: 4), "Paused controls stay visible")
        XCTAssertTrue(app.statusBars.firstMatch.exists)
        assertPlayerSession(identity, in: app)
        back.tap()
    }
    func testPlaybackControlTapsAndSettingsDoNotToggleBackgroundOrStopSession() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "control-taps-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        let pause = app.buttons["player-play-pause"]
        require(pause, in: app, stage: "control-taps-playing", timeout: 5, hittable: true)
        pause.tap()
        XCTAssertTrue(pause.wait(for: \.label, toEqual: "播放", timeout: 3))
        let identity = playerSessionIdentity(in: app)
        tapPlayerBackground(in: app)
        XCTAssertTrue(pause.exists, "A background tap cannot hide paused controls")
        pause.tap()
        XCTAssertTrue(pause.wait(for: \.label, toEqual: "暂停", timeout: 2),
                      "Tapping Play must leave the transport visible, without a second background toggle")
        app.buttons["player-settings"].tap()
        let done = app.buttons["player.settings.done"]
        require(done, in: app, stage: "control-taps-settings", timeout: 3, hittable: true)
        XCTAssertFalse(done.waitForNonExistence(timeout: 4), "Settings remain open beyond the idle timeout")
        done.tap()
        require(pause, in: app, stage: "control-taps-settings-return", timeout: 2, hittable: true)
        XCTAssertEqual(pause.label, "暂停")
        pause.tap()
        XCTAssertTrue(pause.wait(for: \.label, toEqual: "播放", timeout: 3))
        assertPlayerSession(identity, in: app)
        app.buttons["player-back"].tap()
    }
    func testHiddenPlaybackControlsCanBeRevealedAfterRotation() {
        let app = launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        require(app.buttons["channel.http"], in: app, stage: "hidden-rotation-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        let back = app.buttons["player-back"]
        require(back, in: app, stage: "hidden-rotation-player", timeout: 5)
        let identity = playerSessionIdentity(in: app)
        XCTAssertTrue(back.waitForNonExistence(timeout: 6))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertFalse(back.exists, "Rotation does not recreate the controls or their idle timer")
        assertPlayerSession(identity, in: app)
        tapPlayerBackground(in: app)
        let pause = app.buttons["player-play-pause"]
        require(pause, in: app, stage: "hidden-rotation-revealed", timeout: 2, hittable: true)
        pause.tap()
        XCTAssertTrue(pause.wait(for: \.label, toEqual: "播放", timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        assertPlayerSession(identity, in: app)
        require(back, in: app, stage: "hidden-rotation-exit", timeout: 3, hittable: true)
        back.tap()
    }
    func testForegroundReturnRevealsControlsAndStartsFreshIdleTimeout() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "foreground-controls-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        let back = app.buttons["player-back"]
        require(back, in: app, stage: "foreground-controls-player", timeout: 5)
        let identity = playerSessionIdentity(in: app)
        XCTAssertTrue(back.waitForNonExistence(timeout: 6))
        XCUIDevice.shared.press(.home)
        let backgroundState = app.state
        XCTAssertTrue(backgroundState == .runningBackground || backgroundState == .runningBackgroundSuspended)
        app.activate()
        require(back, in: app, stage: "foreground-controls-revealed", timeout: 2, hittable: true)
        XCTAssertEqual(playerSessionIdentity(in: app), identity)
        XCTAssertTrue(back.waitForNonExistence(timeout: 6), "Foreground playback starts a fresh idle timeout")
        assertPlayerSession(identity, in: app)
        tapPlayerBackground(in: app)
        require(back, in: app, stage: "foreground-controls-exit", timeout: 2, hittable: true)
        back.tap()
    }
    func testPlaybackFailureKeepsControlsAndExitVisible() {
        let app = launch(playbackFixture: "failed")
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "failure-controls-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        require(app.buttons["player-retry"], in: app, stage: "failure-controls-retry", timeout: 5)
        let back = app.buttons["player-back"]
        XCTAssertFalse(back.waitForNonExistence(timeout: 4), "Failure cannot hide the exit or settings")
        tapPlayerBackground(in: app)
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(app.buttons["player-settings"].isHittable)
        back.tap()
        require(app.buttons["channel.http"], in: app, stage: "failure-controls-closed", timeout: 5, hittable: true)
    }
    func testSourceEditorCancelAndReopen() {
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["播放列表"].tap()
        let add = app.buttons["source.add"]
        require(add, in: app, stage: "source-add", timeout: 10)
        for cycle in 1...2 {
            add.tap()
            require(app.textFields["source.editor.name"], in: app, stage: "source-cycle-\(cycle)-editor", timeout: 5)
            app.buttons["source.editor.cancel"].tap()
            require(add, in: app, stage: "source-cycle-\(cycle)-after-cancel", timeout: 5)
        }
    }
    func testPlaylistEditOpensExistingSourceWithoutDeletingIt() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "edit-seeded-channel", timeout: 15)
        app.tabBars.buttons["播放列表"].tap()

        // Query the visible controls so this exercises the same List row touch
        // handling as a person tapping Edit, including on the unfixed app.
        let edit = app.buttons["编辑"]
        require(edit, in: app, stage: "edit-source-control", timeout: 5, hittable: true)
        for cycle in 1...2 {
            edit.tap()
            let name = app.textFields["source.editor.name"]
            require(name, in: app, stage: "edit-existing-source-\(cycle)", timeout: 5, hittable: true)
            XCTAssertEqual(name.value as? String, "测试播放列表")
            XCTAssertEqual(app.textFields["source.editor.m3u"].value as? String,
                           "https://fixture.invalid/playlist.m3u")
            XCTAssertFalse(app.staticTexts["已导入的频道和节目单会一并移除。"].exists,
                           "Tapping Edit must not also request deletion.")
            app.buttons["source.editor.cancel"].tap()
            require(edit, in: app, stage: "edit-cancelled-\(cycle)", timeout: 5, hittable: true)
            XCTAssertTrue(app.staticTexts["测试播放列表"].exists)
        }

        app.tabBars.buttons["频道"].tap()
        require(app.buttons["channel.http"], in: app, stage: "edit-preserved-channel", timeout: 5,
                hittable: true)
    }
    func testPlaylistDeleteCancelsWithoutRemovalAndRequiresExplicitConfirmation() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "delete-seeded-channel", timeout: 15)
        app.tabBars.buttons["播放列表"].tap()

        let delete = app.buttons["删除"]
        require(delete, in: app, stage: "delete-source-control", timeout: 5, hittable: true)
        delete.tap()
        // A system confirmation dialog need not expose an AX sheet container.
        // Verify its warning and distinct destructive action before cancelling.
        let notice = app.staticTexts["已导入的频道和节目单会一并移除。"]
        require(notice, in: app, stage: "delete-confirmation-warning", timeout: 5)
        let confirmations = deletionConfirmationButtons(in: app)
        let confirm = confirmations.firstMatch
        require(confirm, in: app, stage: "delete-confirmation-control", timeout: 5, hittable: true)
        XCTAssertEqual(confirmations.count, 1, failureDetails(in: app, stage: "delete-confirmation-identity"))
        XCTAssertFalse(app.textFields["source.editor.name"].exists,
                       "Tapping Delete must not also open the editor.")
        cancelDeletionConfirmation(in: app)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5),
                      failureDetails(in: app, stage: "delete-confirmation-dismissed"))
        require(delete, in: app, stage: "delete-cancelled", timeout: 5, hittable: true)
        XCTAssertTrue(app.staticTexts["测试播放列表"].exists)
        app.tabBars.buttons["频道"].tap()
        require(app.buttons["channel.http"], in: app, stage: "delete-cancel-preserved-channel", timeout: 5)

        app.tabBars.buttons["播放列表"].tap()
        delete.tap()
        require(notice, in: app, stage: "delete-second-confirmation-warning", timeout: 5)
        require(confirm, in: app, stage: "delete-explicit-confirmation", timeout: 5, hittable: true)
        XCTAssertEqual(confirmations.count, 1, failureDetails(in: app, stage: "delete-explicit-identity"))
        // Only the isolated in-memory seeded source is ever confirmed for deletion.
        confirm.tap()
        require(app.staticTexts["还没有播放列表"], in: app, stage: "delete-source-removed", timeout: 5)
        XCTAssertFalse(app.staticTexts["测试播放列表"].exists)
        app.tabBars.buttons["频道"].tap()
        XCTAssertFalse(app.buttons["channel.http"].exists)
    }
    func testDeletionCancellationGeometryUsesOnlyObservedExteriorSpace() throws {
        let appFrame = CGRect(x: 11, y: 17, width: 400, height: 860)
        let sheets = [
            CGRect(x: 91, y: 717, width: 240, height: 140),
            CGRect(x: 91, y: 37, width: 240, height: 140),
            CGRect(x: 11, y: 17, width: 140, height: 860),
            CGRect(x: 271, y: 17, width: 140, height: 860)
        ]
        for sheet in sheets {
            let point = try XCTUnwrap(cancellationPoint(appFrame: appFrame, sheetFrame: sheet))
            XCTAssertTrue(appFrame.insetBy(dx: 44, dy: 44).contains(point))
            XCTAssertFalse(sheet.insetBy(dx: -22, dy: -22).contains(point))
        }
        for sheet in [appFrame, appFrame.insetBy(dx: 10, dy: 10), .zero, .null, .infinite,
                      CGRect(x: 1_000, y: 1_000, width: 100, height: 100)] {
            XCTAssertNil(cancellationPoint(appFrame: appFrame, sheetFrame: sheet))
        }
        XCTAssertNil(cancellationPoint(appFrame: .zero, sheetFrame: sheets[0]))
        XCTAssertNil(cancellationPoint(appFrame: .infinite, sheetFrame: sheets[0]))
        XCTAssertNil(cancellationPoint(appFrame: CGRect(x: 0, y: 0, width: 120, height: 120),
            sheetFrame: CGRect(x: 40, y: 40, width: 40, height: 40)))
        // The remaining gap must fit a full 44-point region after both margins.
        XCTAssertNil(cancellationPoint(appFrame: appFrame,
            sheetFrame: CGRect(x: 11, y: 126, width: 400, height: 751)))
        XCTAssertNotNil(cancellationPoint(appFrame: appFrame,
            sheetFrame: CGRect(x: 11, y: 127, width: 400, height: 750)))
    }
    func testRotationAndPlaybackSettingsKeepPlayerSession() {
        let app = launch()
        defer { app.terminate() }
        require(app.buttons["channel.http"], in: app, stage: "rotation-initial-channel", timeout: 15)
        app.buttons["channel.http"].tap()
        require(app.buttons["player-back"], in: app, stage: "rotation-initial-player-back", timeout: 5)
        assertPlayerControls(in: app, stage: "rotation-initial")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["player-back"].exists, failureDetails(in: app, stage: "after-rotation"))
        assertPlayerControls(in: app, stage: "after-rotation")
        app.buttons["player-settings"].tap()
        require(app.buttons["player.settings.done"], in: app, stage: "settings-presented", timeout: 5)
        app.buttons["player.settings.done"].tap()
        require(app.buttons["player-back"], in: app, stage: "after-settings-player-back", timeout: 5)
        assertPlayerControls(in: app, stage: "after-settings")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["player-back"].tap()
    }
}
