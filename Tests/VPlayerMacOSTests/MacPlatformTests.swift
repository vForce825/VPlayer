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
}
