// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import AVKit
import XCTest
#if !VPLAYER_MACOS_HEADLESS_TESTS
@testable import VPlayer
#endif
@testable import VPlayerCore
@testable import VPlayerPlayback

@MainActor
final class MacNativePlaybackTests: XCTestCase {
    func testProgressiveAACPlaybackPauseResumeAndStop() async throws {
        try await verifyPlayback(path: "macos-progressive-h264-aac-live.ts", interlaced: false, exercisesPictureInPicture: true)
    }
    func testInterlacedMPEGAudioUsesRealMetalDeinterlacing() async throws {
        try await verifyPlayback(path: "macos-interlaced-h264-mp2-live.ts", interlaced: true)
    }
    func testLongPauseResumesWithoutExhaustingAudioReplay() async throws {
        try await verifyPlayback(path: "macos-progressive-h264-aac-live.ts", interlaced: false,
            pauseDuration: .seconds(16))
        try await verifyPlayback(path: "macos-interlaced-h264-mp2-live.ts", interlaced: true,
            pauseDuration: .seconds(16))
    }
    func testHLSPlaybackUsesSharedNativeDemuxPipeline() async throws {
        try await verifyPlayback(path: "hls/master.m3u8", interlaced: false, exercisesPause: false)
    }
    private func verifyPlayback(path: String, interlaced: Bool, exercisesPause: Bool = true, exercisesPictureInPicture: Bool = false,
        pauseDuration: Duration = .zero) async throws {
        _ = NSApplication.shared
        let base = ProcessInfo.processInfo.environment["VPLAYER_MACOS_FIXTURE_BASE_URL"] ?? "http://127.0.0.1:18765/"
        let url = try XCTUnwrap(URL(string: base)?.appendingPathComponent(path))
        let engine = PlaybackController()
        let channel = Channel(sourceProfileID: UUID(), displayName: "本地播放验收", streamURL: url,
            tvgID: nil, tvgName: nil, logoURL: nil, groupTitle: nil, attributes: [:], order: 0)
        let request = PlaybackRequest(channel: channel)
        let mount = PlaybackPresentationHostMount()
        let host = PlaybackPresentationHostController()
        mount.connect(to: host)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mac-playback-tests-\(UUID())"))
        let model = FullScreenPlayerViewModel(request: request, engine: engine,
            presentationStreamProvider: { try await engine.presentations() }, presentationMount: mount,
            settings: PlaybackSettingsStore(defaults: defaults))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        if runsDesktopPictureInPicture {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        model.start()
        var pip: MacPictureInPictureCoordinator?
        do {
            try await waitUntil("首次播放：\(path)") { if case .playing = model.state { return true }; return false }
            try await Task.sleep(for: .seconds(1))
            let snapshot = await engine.playbackMetricsSnapshot(window: .seconds(2))
            let metrics = try XCTUnwrap(snapshot)
            XCTAssertTrue(metrics.audioReady)
            XCTAssertTrue(metrics.readinessOpen)
            XCTAssertGreaterThan(metrics.decoderCallbacksPerSecond, 0)
            if interlaced { XCTAssertGreaterThan(metrics.yadifKernelDispatchCount, 0) }
            if exercisesPictureInPicture && runsDesktopPictureInPicture {
                let surface = try XCTUnwrap(host.children.first?.view as? SampleBufferVideoView)
                XCTAssertGreaterThan(surface.pictureInPictureDisplayLayer.bounds.width, 0)
                XCTAssertGreaterThan(surface.pictureInPictureDisplayLayer.bounds.height, 0)
                try await waitUntil("真实画面可显示") { surface.pictureInPictureDisplayLayer.isReadyForDisplay }
                let identity = try XCTUnwrap(host.mountedIdentity)
                let coordinator = MacPictureInPictureCoordinator(target: model, persistsWindowFrame: false)
                coordinator.onRestore = { completion in
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    completion(true)
                }
                pip = coordinator
                coordinator.install(videoView: surface, identity: identity)
                coordinator.update(state: model.state, paused: model.isPaused)
                try await waitUntil("画中画就绪") { coordinator.isPossible }
                coordinator.start()
                try await waitUntil("浮动播放窗口启动") { coordinator.isActive }
                let floating = try XCTUnwrap(coordinator.floatingWindowForTesting)
                XCTAssertTrue(surface.window === floating)
                XCTAssertEqual(floating.level, .floating)
                for size in [NSSize(width: 320, height: 180), NSSize(width: 640, height: 360)] {
                    floating.setContentSize(size)
                    floating.contentView?.layoutSubtreeIfNeeded()
                    XCTAssertEqual(surface.bounds.size, size)
                    XCTAssertEqual(surface.pictureInPictureDisplayLayer.frame, surface.bounds)
                    XCTAssertEqual(surface.pictureInPictureDisplayLayer.videoGravity, .resizeAspect)
                }
                coordinator.togglePause()
                try await waitUntil("浮窗暂停") { model.isPaused }
                coordinator.update(state: model.state, paused: model.isPaused)
                coordinator.togglePause()
                try await waitUntil("浮窗恢复") { !model.isPaused }
                coordinator.stopForRestoration()
                try await waitUntil("返回播放窗口") { !coordinator.isActive }
                XCTAssertTrue(surface.window === window)
                XCTAssertEqual(surface.frame, host.view.bounds)
                coordinator.close()
                pip = nil
            }
            if exercisesPause {
                model.togglePause()
                try await waitUntil("暂停，状态：\(model.state)") { model.isPaused }
                try await Task.sleep(for: pauseDuration)
                model.togglePause()
                try await waitUntil("恢复") { if case .playing = model.state { return true }; return false }
                if pauseDuration > .zero {
                    try await Task.sleep(for: .seconds(3))
                    guard case .playing = model.state else {
                        XCTFail("长暂停恢复后未能持续播放：\(model.state)")
                        throw NSError(domain: "MacPlaybackAcceptance", code: 2)
                    }
                }
            }
            await model.stop()
            XCTAssertEqual(model.state, .stopped)
            XCTAssertNil(host.mountedIdentity)
        } catch {
            let metrics = await engine.playbackMetricsSnapshot(window: .seconds(2))
            XCTFail("原生播放验收失败，终止状态：\(model.state)，音频就绪：\(String(describing: metrics?.audioReady))，renderer：\(String(describing: metrics?.audioRendererReady))/\(String(describing: metrics?.audioRendererSufficient))，音频时长：\(String(describing: metrics?.audioDurationSeconds))，视频：\(String(describing: metrics?.retainedVideoCount))，去隔行：\(String(describing: metrics?.yadifKernelDispatchCount))，就绪周期：\(String(describing: metrics?.readinessCycleID))，渲染请求：\(String(describing: metrics?.audioRendererRequestArmed))，音频恢复：\(String(describing: metrics?.audioRecoveryCount))，音频起点：\(String(describing: metrics?.audioFirstPTSSeconds))，视频起点：\(String(describing: metrics?.videoFirstPTSSeconds))，视频终点：\(String(describing: metrics?.videoLatestPTSSeconds))，时钟：\(String(describing: metrics?.clockTimeSeconds))，门控：\(String(describing: metrics?.readinessOpen))")
            pip?.close()
            await model.stop()
            window.orderOut(nil)
            throw error
        }
        window.orderOut(nil)
    }
    private var runsDesktopPictureInPicture: Bool {
        #if VPLAYER_MACOS_HEADLESS_TESTS
        false
        #else
        true
        #endif
    }
    private func waitUntil(_ message: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("\(message) 未在 30 秒内完成")
        throw NSError(domain: "MacPlaybackAcceptance", code: 1)
    }
}
