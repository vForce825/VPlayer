// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AVKit
import XCTest
@testable import VPlayer
import VPlayerPlayback

@MainActor
final class IOSPictureInPictureCoordinatorTests: XCTestCase {
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
