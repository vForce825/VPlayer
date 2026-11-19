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
    func testDelayedStopCannotCancelNewlySelectedChannel() async throws {
        let state = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: nil))
        let old = request("旧频道")
        state.replaceSession(for: old)
        try await wait { state.session?.model.state == .playing(old) }
        let latest = request("新频道")
        state.replaceSession(for: latest)
        await state.stopPlayback(requestID: old.id)
        try await wait { state.session?.model.state == .playing(latest) }
        XCTAssertEqual(state.session?.model.request.id, latest.id)
        await state.shutdown()
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
        XCTAssertTrue(state.isLibraryWindowVisible)
        state.registerLibraryWindow(nil)
        XCTAssertTrue(state.libraryWindow === library)
        state.libraryWindowWillClose(library)
        XCTAssertFalse(state.isLibraryWindowVisible)
        library.orderOut(nil)
        #endif
    }

    func testModelObserversSyncPlaybackAndProgrammeUpdatesWithoutRootView() async throws {
        let dependencies = AppDependencies.uiTesting(playbackFixture: nil)
        let state = MacApplicationState(dependenciesForTesting: dependencies)
        let model = try XCTUnwrap(state.model)
        let opened = await dependencies.openInitialLibrary(using: model)
        XCTAssertTrue(opened)
        let channel = try XCTUnwrap(model.channels.first)

        model.select(channel: channel)
        try await wait {
            state.session?.model.request.channelID == channel.id
                && state.session?.model.state == .playing(state.session!.model.request)
        }

        let updatedProgramme = Programme(
            id: "pip-sync-programme",
            xmltvChannelID: channel.tvgID ?? channel.id,
            start: Date().addingTimeInterval(-60),
            stop: Date().addingTimeInterval(3600),
            title: "后台画中画同步节目",
            subtitle: nil,
            summary: nil,
            categories: []
        )
        model.programmesByChannelID[channel.id] = [updatedProgramme]
        try await wait {
            state.session?.presentation.programmes.first?.title == "后台画中画同步节目"
        }

        await state.shutdown()
    }

    func testChannelSwitchKeepsSessionNonNilAndCarriesOverOverlayPreferences() async throws {
        let state = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: nil))
        let first = request("频道一")
        state.replaceSession(for: first)
        try await wait { state.session?.model.state == .playing(first) }
        let firstSession = try XCTUnwrap(state.session)
        firstSession.overlay.toggleInformation(paused: false)
        firstSession.overlay.toggleSidebar(paused: false)
        XCTAssertFalse(firstSession.overlay.informationEnabled)
        XCTAssertTrue(firstSession.overlay.sidebarVisible)

        let second = request("频道二")
        state.replaceSession(for: second)
        XCTAssertNotNil(state.session)
        try await wait {
            state.session?.model.request.id == second.id
                && state.session?.model.state == .playing(second)
        }
        let secondSession = try XCTUnwrap(state.session)
        XCTAssertFalse(secondSession.overlay.informationEnabled)
        XCTAssertFalse(secondSession.overlay.informationVisible)
        XCTAssertTrue(secondSession.overlay.sidebarVisible)

        await state.shutdown()
    }

    func testShutdownSerializesBehindInFlightStopPlayback() async throws {
        let state = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: nil))
        let req = request("停止序列化")
        state.replaceSession(for: req)
        try await wait { state.session?.model.state == .playing(req) }
        let previous = try XCTUnwrap(state.session)

        let stopTask = Task { await state.stopPlayback(requestID: req.id) }
        await state.shutdown()
        await stopTask.value

        XCTAssertNil(state.session)
        XCTAssertTrue(previous.isClosing)
        XCTAssertEqual(previous.model.state, .stopped)
        XCTAssertFalse(state.hasInFlightReplacementForTesting)
    }

    func testPlaybackSessionHoldsDisplaySleepAssertionDuringBufferingAndReleasesOnPauseOrFailure() async throws {
        let bufferingState = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: "buffering"))
        let bufferingReq = request("缓冲保活")
        bufferingState.replaceSession(for: bufferingReq)
        try await wait { bufferingState.session?.model.state == .buffering(bufferingReq) }
        XCTAssertEqual(bufferingState.session?.holdsActivityForTesting, true)
        await bufferingState.shutdown()

        let playingState = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: nil))
        let playingReq = request("暂停释放")
        playingState.replaceSession(for: playingReq)
        try await wait { playingState.session?.model.state == .playing(playingReq) }
        XCTAssertEqual(playingState.session?.holdsActivityForTesting, true)
        playingState.session?.model.togglePause()
        try await wait { playingState.session?.model.isPaused == true }
        try await wait { playingState.session?.holdsActivityForTesting == false }
        await playingState.shutdown()

        let failedState = MacApplicationState(dependenciesForTesting: .uiTesting(playbackFixture: "failed"))
        let failedReq = request("失败释放")
        failedState.replaceSession(for: failedReq)
        try await wait {
            if case .failed = failedState.session?.model.state { return true }
            return false
        }
        XCTAssertEqual(failedState.session?.holdsActivityForTesting, false)
        await failedState.shutdown()
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
