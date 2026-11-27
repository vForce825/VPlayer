// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import AVFoundation
import CoreAudio
import XCTest
#if !VPLAYER_MACOS_HEADLESS_TESTS
@testable import VPlayer
#endif
@testable import VPlayerCore
@testable import VPlayerPlayback

@MainActor
final class MacPlatformTests: XCTestCase {
    func testKeyboardFocusKeepsSidebarOpenAfterPointerLeaves() async throws {
        let overlay = MacPlayerOverlayState(delay: .milliseconds(20))
        overlay.interact(paused: false, revealSidebar: true)
        overlay.sidebarHasFocus = true
        overlay.holdsSidebarOpen = false
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(overlay.sidebarVisible)
        overlay.sidebarHasFocus = false
        overlay.scheduleAutoHide(paused: false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(overlay.sidebarVisible)
    }

    func testMacUsesDurableApplicationSupportStorage() throws {
        let root = try VPlayerModelContainer.persistentStoreRootURL()
        XCTAssertTrue(root.path.contains("Application Support"))
        XCTAssertEqual(VPlayerCore.deploymentTarget, "macOS 27.0")
    }
    func testMacDefaultAudioRouteIsFiniteAndUsesActualDeviceIdentity() {
        let route = MacAudioRouteSnapshot()
        XCTAssertTrue(route.outputLatency.isFinite)
        XCTAssertTrue(route.ioBufferDuration.isFinite)
        XCTAssertGreaterThanOrEqual(route.outputLatency, 0)
        XCTAssertGreaterThanOrEqual(route.ioBufferDuration, 0)
        if route.endpointCount == 1 { XCTAssertFalse(route.endpoint(at: 0).uid.length == 0) }
        XCTAssertEqual(MacAudioDeviceProperties.portName(transport: kAudioDeviceTransportTypeHDMI), PlaybackAudioPortNames.HDMI)
        XCTAssertEqual(MacAudioDeviceProperties.portName(transport: kAudioDeviceTransportTypeAirPlay), PlaybackAudioPortNames.airPlay)
    }
    func testMacDeviceListenersFitExistingRouteAndGlobalAllocationCaps() {
        XCTAssertGreaterThan(PlaybackRuntimeAllocationReservations.route.notificationObserver, 1_024)
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.route.total, PlaybackRuntimeAllocationReservations.routeHardCap)
        XCTAssertLessThanOrEqual(PlaybackRuntimeAllocationReservations.globalReachablePeak, PlaybackRuntimeAllocationReservations.globalHardCap)
    }
    func testSystemAirPlayAudioDeviceKeepsMacSampleBufferOutput() throws {
        XCTAssertEqual(try PlaybackBackendSelection.select(ports: [.airPlay], actualPolicy: .default), .sampleBuffer)
        XCTAssertNil(try PlaybackBackendSelection.select(ports: [], actualPolicy: .default))
    }
    func testNativeSurfaceMountingMovesOneOwnedViewBetweenHosts() {
        #if !VPLAYER_MACOS_HEADLESS_TESTS
        _ = NSApplication.shared
        #endif
        let context = PlaybackPresentationContext()
        #if VPLAYER_MACOS_HEADLESS_TESTS
        let container = NSView(frame: .init(x: 0, y: 0, width: 640, height: 360))
        let surface = context.makeVideoView()
        container.addSubview(surface)
        XCTAssertTrue(surface.superview === container)
        #else
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        let surface = context.makeVideoView()
        window.contentView = surface
        XCTAssertTrue(surface.window === window)
        #endif
        XCTAssertTrue(context.makeVideoView() === surface)
        XCTAssertTrue(surface.pictureInPictureDisplayLayer.superlayer === surface.layer)
        context.teardown()
        #if !VPLAYER_MACOS_HEADLESS_TESTS
        window.orderOut(nil)
        #endif
    }
    func testOverlayAutoHidesAndMouseActivityRestoresEnabledInformation() async throws {
        let overlay = MacPlayerOverlayState(delay: .milliseconds(30))
        XCTAssertFalse(overlay.sidebarVisible)
        overlay.interact(paused: false, revealSidebar: true)
        XCTAssertTrue(overlay.sidebarVisible)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(overlay.controlsVisible)
        XCTAssertFalse(overlay.informationVisible)
        XCTAssertFalse(overlay.sidebarVisible)
        overlay.interact(paused: false)
        XCTAssertTrue(overlay.controlsVisible)
        XCTAssertTrue(overlay.informationVisible)
        XCTAssertFalse(overlay.sidebarVisible)
        overlay.toggleSidebar(paused: false)
        XCTAssertTrue(overlay.sidebarVisible)
        overlay.cancel()
    }
    func testManualInformationDismissalSurvivesMouseMovementAndCanBeReopened() {
        let overlay = MacPlayerOverlayState()
        overlay.toggleInformation(paused: false)
        overlay.interact(paused: false)
        XCTAssertFalse(overlay.informationVisible)
        overlay.toggleInformation(paused: false)
        XCTAssertTrue(overlay.informationVisible)
        overlay.cancel()
    }
    func testPauseAndControlHoverPreventAutomaticDismissal() async throws {
        let overlay = MacPlayerOverlayState(delay: .milliseconds(30))
        overlay.interact(paused: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(overlay.controlsVisible)
        overlay.holdsControlsOpen = true
        overlay.interact(paused: false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(overlay.controlsVisible)
        overlay.holdsControlsOpen = false
        overlay.holdsSidebarOpen = true
        overlay.interact(paused: false, revealSidebar: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(overlay.sidebarVisible)
        overlay.cancel()
    }

    func testPointerMovementReusesSingleAutoHideTaskWithoutThrashing() async throws {
        let overlay = MacPlayerOverlayState(delay: .milliseconds(50))
        overlay.interact(paused: false)
        XCTAssertEqual(overlay.hideTaskCreationCountForTesting, 1)
        for step in 1...15 {
            overlay.pointerMoved(to: CGPoint(x: Double(step * 4), y: 20), paused: false)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(overlay.hideTaskCreationCountForTesting, 1)
        XCTAssertTrue(overlay.controlsVisible)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(overlay.controlsVisible)
        XCTAssertFalse(overlay.informationVisible)
    }

    func testClosingSidebarWhileHoveringClearsHoldAndAllowsAutoHide() async throws {
        let overlay = MacPlayerOverlayState(delay: .milliseconds(30))
        overlay.toggleSidebar(paused: false)
        XCTAssertTrue(overlay.sidebarVisible)
        overlay.holdsSidebarOpen = true
        overlay.toggleSidebar(paused: false)
        XCTAssertFalse(overlay.sidebarVisible)
        XCTAssertFalse(overlay.holdsSidebarOpen)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(overlay.controlsVisible)
    }

    func testHasVisibleOverlayReflectsHiddenState() {
        let overlay = MacPlayerOverlayState()
        XCTAssertTrue(overlay.hasVisibleOverlay)
        overlay.hide(pointerLocation: CGPoint(x: 10, y: 10))
        XCTAssertFalse(overlay.hasVisibleOverlay)
    }

    func testOverlayCarryOverPreservesInformationAndSidebarPreferences() {
        let source = MacPlayerOverlayState()
        source.toggleInformation(paused: false)
        source.toggleSidebar(paused: false)
        source.holdsSidebarOpen = true
        let snapshot = source.snapshotForChannelSwitch()
        source.cancel()

        let destination = MacPlayerOverlayState()
        destination.applyChannelSwitchCarryOver(snapshot, paused: false)
        XCTAssertFalse(destination.informationEnabled)
        XCTAssertFalse(destination.informationVisible)
        XCTAssertTrue(destination.sidebarVisible)
        XCTAssertTrue(destination.holdsSidebarOpen)
        destination.cancel()
    }

    func testSidebarPreferencesDefersPersistenceUntilCommitAndGuardsClampedNoOp() throws {
        let suiteName = "com.vplayer.tests.sidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MacSidebarPreferences(defaults: defaults)
        XCTAssertEqual(preferences.width, MacSidebarPreferences.defaultWidth)
        preferences.resize(to: 300)
        XCTAssertEqual(preferences.width, 300)
        XCTAssertNil(defaults.object(forKey: MacSidebarPreferences.widthKey))

        preferences.resize(to: 500)
        XCTAssertEqual(preferences.width, 360)
        preferences.resize(to: 600)
        XCTAssertEqual(preferences.width, 360)
        XCTAssertNil(defaults.object(forKey: MacSidebarPreferences.widthKey))

        preferences.commitWidth()
        XCTAssertEqual(defaults.double(forKey: MacSidebarPreferences.widthKey), 360)
    }

    func testPlayerKeyShortcutResolutionRespectsTextEditingAndEscapeOverride() {
        XCTAssertEqual(
            MacPlayerKeyShortcut.resolve(keyCode: 53, charactersIgnoringModifiers: nil, modifierFlags: [], isRepeat: false, isEditingText: true),
            .escape
        )
        XCTAssertEqual(
            MacPlayerKeyShortcut.resolve(keyCode: 49, charactersIgnoringModifiers: " ", modifierFlags: [], isRepeat: false, isEditingText: false),
            .togglePause
        )
        XCTAssertNil(
            MacPlayerKeyShortcut.resolve(keyCode: 49, charactersIgnoringModifiers: " ", modifierFlags: [], isRepeat: false, isEditingText: true)
        )
        XCTAssertEqual(
            MacPlayerKeyShortcut.resolve(keyCode: 34, charactersIgnoringModifiers: "i", modifierFlags: [], isRepeat: false, isEditingText: false),
            .toggleInformation
        )
        XCTAssertEqual(
            MacPlayerKeyShortcut.resolve(keyCode: 14, charactersIgnoringModifiers: "e", modifierFlags: [], isRepeat: false, isEditingText: false),
            .showProgrammes
        )
        XCTAssertEqual(
            MacPlayerKeyShortcut.resolve(keyCode: 37, charactersIgnoringModifiers: "l", modifierFlags: [], isRepeat: false, isEditingText: false),
            .toggleSidebar
        )
        XCTAssertNil(
            MacPlayerKeyShortcut.resolve(keyCode: 37, charactersIgnoringModifiers: "l", modifierFlags: [], isRepeat: true, isEditingText: false)
        )
        XCTAssertNil(
            MacPlayerKeyShortcut.resolve(keyCode: 37, charactersIgnoringModifiers: "l", modifierFlags: [.command], isRepeat: false, isEditingText: false)
        )
        XCTAssertNil(
            MacPlayerKeyShortcut.resolve(keyCode: 34, charactersIgnoringModifiers: "i", modifierFlags: [], isRepeat: false, isEditingText: true)
        )
        XCTAssertNil(
            MacPlayerKeyShortcut.resolve(
                keyCode: 49,
                charactersIgnoringModifiers: " ",
                modifierFlags: [],
                isRepeat: false,
                isEditingText: false,
                isActivatingControl: true
            )
        )
        XCTAssertEqual(
            MacPlayerKeyShortcut.resolve(
                keyCode: 34,
                charactersIgnoringModifiers: "i",
                modifierFlags: [],
                isRepeat: false,
                isEditingText: false,
                isActivatingControl: true
            ),
            .toggleInformation
        )
    }

    func testPictureInPictureClampsToContainingSecondaryMonitor() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: 0, width: 2560, height: 1440)
        let screens = [primary, secondary]

        let savedOnSecondary = NSRect(x: 1600, y: 120, width: 480, height: 270)
        XCTAssertEqual(
            MacPictureInPictureCoordinator.clampedFrame(savedOnSecondary, screens: screens, fallbackVisibleFrame: primary),
            savedOnSecondary
        )

        let slightlyOffSecondaryRight = NSRect(x: 3800, y: 120, width: 480, height: 270)
        XCTAssertEqual(
            MacPictureInPictureCoordinator.clampedFrame(slightlyOffSecondaryRight, screens: screens, fallbackVisibleFrame: primary),
            NSRect(x: 3520, y: 120, width: 480, height: 270)
        )

        let completelyOffAllScreens = NSRect(x: 9000, y: 9000, width: 480, height: 270)
        XCTAssertEqual(
            MacPictureInPictureCoordinator.clampedFrame(completelyOffAllScreens, screens: screens, fallbackVisibleFrame: primary),
            NSRect(x: 960, y: 630, width: 480, height: 270)
        )
    }

    func testWindowVisibilityRequiresVisibleUnminiaturizedOnActiveSpaceAndUnoccluded() {
        XCTAssertTrue(MacApplicationState.isWindowVisiblyOnScreen(
            isVisible: true, isMiniaturized: false, isOnActiveSpace: true, occlusionState: .visible
        ))
        XCTAssertFalse(MacApplicationState.isWindowVisiblyOnScreen(
            isVisible: true, isMiniaturized: false, isOnActiveSpace: true, occlusionState: []
        ))
        XCTAssertFalse(MacApplicationState.isWindowVisiblyOnScreen(
            isVisible: true, isMiniaturized: false, isOnActiveSpace: false, occlusionState: .visible
        ))
        XCTAssertFalse(MacApplicationState.isWindowVisiblyOnScreen(
            isVisible: true, isMiniaturized: true, isOnActiveSpace: true, occlusionState: .visible
        ))
        XCTAssertFalse(MacApplicationState.isWindowVisiblyOnScreen(
            isVisible: false, isMiniaturized: false, isOnActiveSpace: true, occlusionState: .visible
        ))
    }

    #if !VPLAYER_MACOS_HEADLESS_TESTS
    func testApplicationDelegateReopensLibraryWhenMainWindowIsNotVisible() {
        let app = NSApplication.shared
        let delegate = MacApplicationDelegate()
        let state = MacApplicationState()
        delegate.state = state

        XCTAssertTrue(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))

        var reopenCount = 0
        delegate.openLibraryWindow = { reopenCount += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true))
        XCTAssertEqual(reopenCount, 1)

        XCTAssertEqual(
            MacApplicationState.libraryWindowReopenAction(hasWindow: true, isVisible: false, isMiniaturized: true),
            .deminiaturizeAndFocus
        )
        XCTAssertEqual(
            MacApplicationState.libraryWindowReopenAction(hasWindow: true, isVisible: true, isMiniaturized: false),
            .focusExisting
        )
        XCTAssertEqual(
            MacApplicationState.libraryWindowReopenAction(hasWindow: true, isVisible: false, isMiniaturized: false),
            .openNew
        )
        XCTAssertEqual(
            MacApplicationState.libraryWindowReopenAction(hasWindow: false, isVisible: false, isMiniaturized: false),
            .openNew
        )
    }
    #endif
}
