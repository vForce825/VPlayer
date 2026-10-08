// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AVKit
import XCTest
import SwiftUI
import UIKit
@testable import VPlayer
import VPlayerPlayback

@MainActor
final class IOSPictureInPictureCoordinatorTests: XCTestCase {
    func testRestoreIntentIsConsumedBeforeTheNextAutomaticPiPCycle() {
        let snapshot = PiPPlaybackSnapshot()
        let object = NSObject()
        let identity = ObjectIdentifier(object)
        snapshot.update(paused: false, available: true, identity: identity)
        snapshot.requestRestore(identity)
        XCTAssertTrue(snapshot.consumeRestoreIntent(identity))
        XCTAssertFalse(snapshot.consumeRestoreIntent(identity), "A later automatic PiP close is not a restore")
    }
    func testCallbackReferencePinsIdentityUntilTheActorHopFinishes() {
        weak var weakObject: NSObject?
        var reference: PiPCallbackReference<NSObject>?
        do {
            let object = NSObject()
            weakObject = object
            reference = PiPCallbackReference(object)
        }
        XCTAssertNotNil(weakObject)
        XCTAssertEqual(reference?.identity, weakObject.map(ObjectIdentifier.init))
        reference = nil
        XCTAssertNil(weakObject)
    }
    func testUnavailablePiPDoesNotStopThePlaybackTarget() {
        let target = PiPTestTarget()
        let coordinator = IOSPictureInPictureCoordinator(target: target)
        coordinator.start()
        XCTAssertNotNil(coordinator.message)
        XCTAssertEqual(target.stopCount, 0)
        XCTAssertEqual(target.pauseRequests, [])
        coordinator.close()
    }
    func testUnownedControllerCannotPauseOrRestoreAnotherSession() async {
        let target = PiPTestTarget()
        let coordinator = IOSPictureInPictureCoordinator(target: target)
        let player = AVPlayer()
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: AVPlayerLayer(player: player)))
        coordinator.pictureInPictureController(controller, setPlaying: false)
        let restored: Bool = await withCheckedContinuation { continuation in
            coordinator.pictureInPictureController(controller,
                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: {
                    continuation.resume(returning: $0)
                })
        }
        XCTAssertFalse(restored)
        XCTAssertTrue(coordinator.pictureInPictureControllerIsPlaybackPaused(controller))
        XCTAssertFalse(coordinator.pictureInPictureControllerTimeRangeForPlayback(controller).isValid)
        XCTAssertTrue(target.pauseRequests.isEmpty)
        XCTAssertEqual(target.stopCount, 0)
        coordinator.close()
    }
    func testCloseIsIdempotentAndLateDelegateStopDoesNotReopenSession() async {
        let target = PiPTestTarget()
        let coordinator = IOSPictureInPictureCoordinator(target: target)
        var stopped = 0
        coordinator.onStopped = { stopped += 1 }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: AVPlayerLayer()))
        coordinator.close()
        coordinator.close()
        coordinator.pictureInPictureControllerDidStopPictureInPicture(controller)
        let restored: Bool = await withCheckedContinuation { continuation in
            coordinator.pictureInPictureController(controller,
                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: {
                    continuation.resume(returning: $0)
                })
        }
        XCTAssertFalse(restored)
        XCTAssertEqual(stopped, 0)
        XCTAssertFalse(coordinator.isActive)
    }
}

@MainActor
private final class PiPTestTarget: NowPlayingPlaybackTarget {
    var stopCount = 0
    var pauseRequests: [Bool] = []
    func setPausedFromNowPlaying(_ paused: Bool) async { pauseRequests.append(paused) }
    func stopFromNowPlaying() async { stopCount += 1 }
}

@MainActor
final class IOSPlaybackSessionTests: XCTestCase {
    func testMinimizingAndRestoringKeepsSameModelAndRemoteStopRetiresSession() async {
        let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "synthetic",
            streamURL: URL(string: "https://example.invalid/live")!, title: "Synthetic")
        let session = IOSPlaybackSession(presentation: PlayerChannelPresentation(request: request,
            logoURL: nil, programmes: []), dependencies: .uiTesting(playbackFixture: nil))
        let model = session.model
        session.start()
        for _ in 0..<100 {
            if case .playing = model.state { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard case .playing = model.state else { XCTFail("Fixture did not start"); session.close(); return }
        session.isFullScreenPresented = false
        session.showFullScreen()
        session.start() // Reappearing must not register another playback owner.
        XCTAssertTrue(session.model === model)
        XCTAssertFalse(session.isClosing)
        await model.stopFromNowPlaying()
        for _ in 0..<100 {
            if session.isClosing { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(session.isClosing)
        XCTAssertFalse(session.isFullScreenPresented)
        session.close()
    }
}

@MainActor
final class IOSNativePictureInPictureTests: XCTestCase {
    func testRealSampleBufferPiPStartsRestoresAndClosesTheRetainedSession() async throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw XCTSkip("AVKit reports Picture in Picture unsupported on this runtime")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "PiP test requires an active app scene")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "homepod-live-h264-aac-80s",
            withExtension: "ts", subdirectory: "Video"))
        let origin = try NativeHLSHTTPFixture(resources: ["/synthetic.ts": .init(
            data: Data(contentsOf: fixture), contentType: "video/mp2t")], credential: nil)
        let base = AppDependencies.uiTesting()
        // Use the real PlaybackController/audio-session owner, not UITestPlaybackEngine.
        let dependencies = AppDependencies(libraryStartup: base.libraryStartup,
            foregroundRefreshDriver: base.foregroundRefreshDriver,
            backgroundRefreshRegistrar: base.backgroundRefreshRegistrar,
            repository: base.repository, playbackSettings: base.playbackSettings)
        let request = PlaybackRequest(sourceProfileID: UUID(), channelID: "synthetic-pip",
            streamURL: origin.url("synthetic.ts"), title: "Synthetic PiP")
        let session = IOSPlaybackSession(presentation: .init(request: request, logoURL: nil, programmes: []),
            dependencies: dependencies)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NativePiPSmokeRoot(session: session))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        var failure: (any Error)?
        do {
            session.start()
            try await waitFor("sample-buffer playback and PiP readiness", timeout: 25) {
                guard case .playing = session.model.state,
                      let presentation = session.model.presentation,
                      case let .sampleBuffer(context) = presentation.presentation,
                      let layer = context.makeVideoView().layer as? AVSampleBufferDisplayLayer else { return false }
                return layer.isReadyForDisplay && session.pictureInPicture.isPossible
            }
            let model = session.model
            let host = session.host
            let presentation = try XCTUnwrap(model.presentation)
            guard case let .sampleBuffer(context) = presentation.presentation else {
                throw NativePiPTestFailure.wrongBackend
            }
            let layer = context.makeVideoView().layer
            let native = try XCTUnwrap(session.pictureInPicture.nativeControllerForTesting)
            let beforeTransitions = await dependencies.playbackMetricsProvider(.seconds(1))
            let baselineAudioGaps = try XCTUnwrap(beforeTransitions).audioLargeGapCount
            let enterBegan = ContinuousClock.now
            session.pictureInPicture.start()
            try await waitFor("native PiP start", timeout: 10) {
                native.isPictureInPictureActive && session.pictureInPicture.isActive && !session.isFullScreenPresented
            }
            print("IOS_PIP_NATIVE_ENTER_LIFECYCLE_DURATION=\(enterBegan.duration(to: .now))")
            try await assertMediaProgress(dependencies: dependencies, stage: "PiP", baselineAudioGaps: baselineAudioGaps)
            XCTAssertTrue(session.model === model)
            XCTAssertTrue(session.host === host)
            XCTAssertTrue(context.makeVideoView().layer === layer)
            let restoreBegan = ContinuousClock.now
            session.showFullScreen()
            try await waitFor("app-initiated native PiP restoration", timeout: 10) {
                !native.isPictureInPictureActive && !session.pictureInPicture.isActive &&
                    host.isViewLoaded && host.view.window === window
            }
            print("IOS_PIP_NATIVE_RESTORE_LIFECYCLE_DURATION=\(restoreBegan.duration(to: .now))")
            try await assertMediaProgress(dependencies: dependencies, stage: "restored-fullscreen", baselineAudioGaps: baselineAudioGaps)
            XCTAssertFalse(session.isClosing)
            XCTAssertEqual(model.presentation?.identity, presentation.identity)
            XCTAssertTrue(context.makeVideoView().layer === layer)
            try await waitFor("reattached source ready for second PiP", timeout: 10) {
                session.pictureInPicture.isPossible &&
                    session.pictureInPicture.nativeControllerForTesting === native &&
                    model.presentation?.identity == presentation.identity
            }
            session.pictureInPicture.start()
            try await waitFor("second native PiP start", timeout: 10) {
                native.isPictureInPictureActive && session.pictureInPicture.isActive
            }
            session.close()
            try await waitFor("native PiP stop after explicit close", timeout: 10) { !native.isPictureInPictureActive }
            XCTAssertTrue(session.isClosing)
        } catch {
            print("IOS_PIP_NATIVE_FAILURE os=\(UIDevice.current.systemVersion) scene=\(scene.activationState.rawValue) visible=\(!window.isHidden) possible=\(session.pictureInPicture.isPossible) active=\(session.pictureInPicture.isActive)")
            failure = error
        }
        session.close()
        await session.model.stop()
        await origin.close()
        if let failure { throw failure }
    }

    private func assertMediaProgress(dependencies: AppDependencies, stage: String, baselineAudioGaps: UInt64) async throws {
        let initialSnapshot = await dependencies.playbackMetricsProvider(.seconds(1))
        let initial = try XCTUnwrap(initialSnapshot, "Missing production playback metrics")
        let clock = try XCTUnwrap(initial.clockTimeSeconds)
        let pts = try XCTUnwrap(initial.videoLatestPTSSeconds)
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            guard let next = await dependencies.playbackMetricsProvider(.seconds(1)),
                  let nextClock = next.clockTimeSeconds, let nextPTS = next.videoLatestPTSSeconds else { continue }
            if nextClock > clock + 0.25, nextPTS > pts,
               next.videoRendererTotalFrameCount > initial.videoRendererTotalFrameCount {
                XCTAssertEqual(next.audioLargeGapCount, baselineAudioGaps,
                    "PiP lifecycle must not introduce a large audio discontinuity")
                print("IOS_PIP_NATIVE_PROGRESS stage=\(stage) clock_delta=\(nextClock-clock) rendered_delta=\(next.videoRendererTotalFrameCount-initial.videoRendererTotalFrameCount)")
                return
            }
        }
        XCTFail("Production clock, processed video and native renderer did not progress during \(stage)")
        throw NativePiPTestFailure.timeout
    }

    private func waitFor(_ stage: String, timeout: Int, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native PiP timed out: \(stage)")
        throw NativePiPTestFailure.timeout
    }
}

private enum NativePiPTestFailure: Error { case timeout, wrongBackend }

private struct NativePiPSmokeRoot: View {
    @Bindable var session: IOSPlaybackSession
    var body: some View {
        if session.isFullScreenPresented {
            IOSFullScreenPlayerView(session: session, onClose: {})
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}
