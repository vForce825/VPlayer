// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import XCTest
#if !VPLAYER_MACOS_HEADLESS_TESTS
@testable import VPlayer
#endif
@testable import VPlayerCore
@testable import VPlayerPlayback

@MainActor
final class MacPlaybackSessionTests: XCTestCase {
    private func request(_ title: String) -> PlaybackRequest {
        .init(sourceProfileID: UUID(), channelID: title,
              streamURL: URL(string: "https://example.invalid/live")!, title: title)
    }
    func testRapidChannelReplacementClosesPredecessorBeforeStartingFinalRequest() async throws {
        let state = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: nil))
        state.replaceSession(for: request("第一个频道"))
        try await wait {
            guard let session = state.session else { return false }
            return session.model.state == .playing(session.model.request)
        }
        let previous = try XCTUnwrap(state.session)
        let obsolete = request("被替换的频道")
        let final = request("最后一个频道")
        state.replaceSession(for: obsolete)
        state.replaceSession(for: final)
        try await wait { state.session?.model.request.id == final.id && state.session?.model.state == .playing(final) }
        XCTAssertTrue(previous.isClosing)
        XCTAssertEqual(previous.model.state, .stopped)
        await state.shutdown()
        XCTAssertNil(state.session)
    }
    func testDismissalBeforeCreationAndImmediateShutdownCannotStartStalePlayback() async throws {
        let state = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: nil))
        state.replaceSession(for: request("已取消的频道"))
        state.replaceSession(for: nil)
        await state.shutdown()
        XCTAssertNil(state.session)
        state.replaceSession(for: request("退出前的频道"))
        await state.shutdown()
        XCTAssertNil(state.session)
    }
    func testRemoteStopClosesSessionEvenWithoutVisiblePlayerView() async throws {
        let state = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: nil))
        let request = request("远程控制验收")
        state.replaceSession(for: request)
        try await wait { state.session?.model.state == .playing(request) }
        let session = try XCTUnwrap(state.session)
        await session.model.stopFromNowPlaying()
        try await wait { state.session == nil && session.isClosing }
        await state.shutdown()
    }
    func testWindowTrackingDoesNotAdoptUnrelatedSettingsWindow() throws {
        #if VPLAYER_MACOS_HEADLESS_TESTS
        throw XCTSkip("窗口验收需要已解锁的图形登录会话。")
        #else
        _ = NSApplication.shared
        let state = MacApplicationState()
        let library = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        state.registerLibraryWindow(library)
        state.registerLibraryWindow(nil)
        XCTAssertTrue(state.libraryWindow === library)
        library.orderOut(nil)
        #endif
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("播放会话未在 2 秒内完成状态切换")
        throw NSError(domain: "MacSessionTest", code: 1)
    }
}
