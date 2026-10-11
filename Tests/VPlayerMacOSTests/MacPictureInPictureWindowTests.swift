// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import XCTest
#if !VPLAYER_MACOS_HEADLESS_TESTS
@testable import VPlayer
@testable import VPlayerPlayback

@MainActor
final class MacPictureInPictureWindowTests: XCTestCase {
    func testClosedMainWindowRestoresTheSameVideoViewWithoutReplacingRenderer() throws {
        let harness = Harness()
        defer { harness.close() }
        let renderer = harness.surface.pictureInPictureDisplayLayer.sampleBufferRenderer
        harness.coordinator.start()
        let floating = try XCTUnwrap(harness.coordinator.floatingWindowForTesting)
        harness.window.orderOut(nil)
        XCTAssertTrue(harness.surface.window === floating)
        XCTAssertTrue(floating.isVisible)
        XCTAssertTrue(floating.collectionBehavior.contains(.fullScreenAuxiliary))
        harness.coordinator.onRestore = { completion in
            harness.window.makeKeyAndOrderFront(nil)
            completion(true)
        }
        harness.coordinator.stopForRestoration()
        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertTrue(harness.surface.window === harness.window)
        XCTAssertTrue(harness.surface.pictureInPictureDisplayLayer.sampleBufferRenderer === renderer)
        XCTAssertEqual(harness.surface.frame, harness.container.bounds)
    }

    func testOldRestoreReplyCannotDismissReplacementOutput() {
        let harness = Harness()
        defer { harness.close() }
        var reply: (@MainActor (Bool) -> Void)?
        harness.coordinator.onRestore = { reply = $0 }
        harness.coordinator.start()
        let floating = harness.coordinator.floatingWindowForTesting
        harness.coordinator.stopForRestoration()
        harness.coordinator.retire(identity: harness.identity)
        let replacement = SampleBufferVideoView(frame: harness.container.bounds)
        harness.container.addSubview(replacement)
        harness.coordinator.install(videoView: replacement, identity: Harness.identity(2))
        reply?(true)
        XCTAssertTrue(harness.coordinator.isActive)
        XCTAssertTrue(harness.coordinator.floatingWindowForTesting === floating)
        XCTAssertTrue(replacement.window === floating)
        XCTAssertTrue(harness.surface.superview === harness.container)
        harness.coordinator.close()
        XCTAssertTrue(replacement.superview === harness.container)
        XCTAssertFalse(harness.coordinator.isActive)
    }

    func testWindowCloseNotifiesOnceAndReturnsSurface() throws {
        let harness = Harness()
        defer { harness.close() }
        var stops = 0
        harness.coordinator.onStopped = { stops += 1 }
        harness.coordinator.start()
        let floating = try XCTUnwrap(harness.coordinator.floatingWindowForTesting)
        floating.performClose(nil)
        floating.performClose(nil)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(harness.coordinator.isActive)
        XCTAssertTrue(harness.surface.superview === harness.container)
    }

    func testQuickPauseThenPlayKeepsTheLatestIntent() async {
        let harness = Harness()
        defer { harness.close() }
        harness.coordinator.togglePause()
        while harness.target.requests.isEmpty { await Task.yield() }
        harness.coordinator.togglePause()
        harness.target.continuation?.resume()
        harness.target.continuation = nil
        for _ in 0..<100 {
            if harness.target.requests.count == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(harness.target.requests, [true, false])
        harness.target.continuation?.resume()
        harness.target.continuation = nil
    }

    private final class Target: NowPlayingPlaybackTarget {
        var requests: [Bool] = []
        var continuation: CheckedContinuation<Void, Never>?
        func setPausedFromNowPlaying(_ paused: Bool) async {
            requests.append(paused)
            await withCheckedContinuation { continuation = $0 }
        }
        func stopFromNowPlaying() async {}
    }
    @MainActor
    private final class Harness {
        let target = Target()
        let coordinator: MacPictureInPictureCoordinator
        let window: NSWindow
        let container = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 700))
        let surface = SampleBufferVideoView(frame: .init(x: 0, y: 0, width: 1000, height: 700))
        let identity = Harness.identity(1)
        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = container
            container.addSubview(surface)
            surface.autoresizingMask = [.width, .height]
            coordinator = MacPictureInPictureCoordinator(target: target, persistsWindowFrame: false)
            coordinator.install(videoView: surface, identity: identity)
            coordinator.update(state: .playing(.init(sourceProfileID: UUID(), channelID: "浮窗验收",
                streamURL: URL(string: "https://example.invalid/live")!, title: "浮窗验收")), paused: false)
        }
        func close() {
            coordinator.close()
            target.continuation?.resume()
            target.continuation = nil
            window.orderOut(nil)
        }
        static func identity(_ nonce: UInt64) -> PresentationIdentity {
            let session = PlaybackSessionIdentity(sessionID: 1, requestID: UUID())
            let backend = PlaybackBackendIdentity(sessionIdentity: session, backendGeneration: 1)
            return .init(sessionIdentity: session, backendIdentity: backend,
                outputLifecycleEpoch: .init(backendIdentity: backend, outputNonce: nonce),
                itemGeneration: .init(rawValue: nonce), presentationNonce: nonce)
        }
    }
}
#endif
