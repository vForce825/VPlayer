// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Metal
import XCTest
@testable import VPlayerPlayback

@MainActor
final class PlaybackPresentationContextTests: XCTestCase {
    func testContextCachesExactlyOneMetalViewAndTeardownIsIdempotent() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device
        )

        let first = context.makeMetalVideoView()
        let second = context.makeMetalVideoView()

        XCTAssertTrue(first === second)
        context.teardown()
        context.teardown()
        XCTAssertTrue(first.displayLink.isPaused)
        XCTAssertNil(first.displayLink.delegate)
    }

    func testBridgeHopsToMainActorCachesPauseAndSuppressesLateCallsAfterTerminalClear() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device
        )
        let bridge = PlaybackPresentationDisplayBridge(context: context)
        let view = context.makeMetalVideoView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        await Task.detached { bridge.pauseSubmission() }.value
        try await eventually { await MainActor.run { view.displayLink.isPaused } }
        context.attach(to: window)
        bridge.resumeSubmission()
        try await eventually { await MainActor.run { !view.displayLink.isPaused } }

        await bridge.clearDisplayCriteria()
        XCTAssertNil(view.displayLink.delegate)
        bridge.resumeSubmission()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(view.displayLink.isPaused)
        XCTAssertNil(view.displayLink.delegate)
    }

    // The cadence is the processed frame's own duration: the field-rate route
    // has already doubled it by the time a frame reaches here.
    func testCadencePolicyUsesProcessedDurationOnEveryRoute() throws {
        let frame25 = try presentationFrame(duration: CMTime(value: 1, timescale: 25))
        let frame50 = try presentationFrame(duration: CMTime(value: 1, timescale: 50))

        XCTAssertEqual(
            PlaybackPresentationCadencePolicy.outputFrameRate(for: frame25, route: .progressive),
            25
        )
        XCTAssertEqual(
            PlaybackPresentationCadencePolicy.outputFrameRate(for: frame50, route: .metalYADIF2x),
            50
        )
        XCTAssertEqual(
            PlaybackPresentationCadencePolicy.outputFrameRate(for: frame25, route: .metalYADIF2x),
            25
        )
        XCTAssertNil(PlaybackPresentationCadencePolicy.outputFrameRate(
            for: try presentationFrame(duration: .invalid),
            route: .progressive
        ))
        XCTAssertNil(PlaybackPresentationCadencePolicy.outputFrameRate(
            for: try presentationFrame(duration: .zero),
            route: .metalYADIF2x
        ))
    }

    func testAttachIsIdempotentForSameWindowCriteriaAreDeduplicatedAndReattachRestoresResume() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let managerFactory = PresentationManagerFactory()
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device,
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let view = context.makeMetalVideoView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        let format = try makeFormatDescription()

        context.resumeSubmission()
        context.attach(to: window)
        context.updateDisplayCriteria(formatDescription: format, outputFrameRate: 50)
        context.attach(to: window)
        context.updateDisplayCriteria(formatDescription: format, outputFrameRate: 50)

        XCTAssertEqual(managerFactory.makeCount, 1)
        XCTAssertEqual(managerFactory.manager.nonNilAssignmentCount, 1)
        context.detach()
        XCTAssertTrue(view.displayLink.isPaused)
        context.attach(to: window)
        XCTAssertFalse(view.displayLink.isPaused)
        XCTAssertEqual(managerFactory.makeCount, 2)
    }

    func testDetachedContextRejectsLateResumeUntilItsViewMovesIntoAWindowAgain() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let managerFactory = PresentationManagerFactory()
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device,
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let bridge = PlaybackPresentationDisplayBridge(context: context)
        let view = context.makeMetalVideoView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        context.attach(to: window)
        bridge.resumeSubmission()
        try await eventually { !view.displayLink.isPaused }
        context.detach()
        bridge.resumeSubmission()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(view.displayLink.isPaused)
    }

    func testViewMovingIntoAndOutOfWindowOwnsAttachmentWithoutRepresentablePolling() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let managerFactory = PresentationManagerFactory()
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device,
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let view = context.makeMetalVideoView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        context.resumeSubmission()
        XCTAssertTrue(view.displayLink.isPaused)
        window.addSubview(view)
        try await eventually { managerFactory.makeCount == 1 }
        XCTAssertFalse(view.displayLink.isPaused)

        view.removeFromSuperview()
        try await eventually { view.displayLink.isPaused }
        XCTAssertEqual(managerFactory.manager.nilAssignmentCount, 1)
    }

    func testDetachDuringModeSwitchBalancesCallbackAndReattachRecoversWithoutEndNotification() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let managerFactory = PresentationManagerFactory()
        let callbacks = PresentationSwitchCallbackRecorder()
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device,
            switchStarted: { callbacks.recordStart() },
            switchEnded: { callbacks.recordEnd() },
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let view = context.makeMetalVideoView()
        let firstWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        let secondWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        context.attach(to: firstWindow)
        context.updateDisplayCriteria(
            formatDescription: try makeFormatDescription(),
            outputFrameRate: 50
        )
        context.resumeSubmission()
        NotificationCenter.default.post(
            name: .AVDisplayManagerModeSwitchStart,
            object: nil
        )
        var callbackSnapshot = callbacks.snapshot()
        XCTAssertEqual(callbackSnapshot.starts, 1)
        XCTAssertEqual(callbackSnapshot.ends, 0)

        context.detach()

        callbackSnapshot = callbacks.snapshot()
        XCTAssertEqual(callbackSnapshot.starts, 1)
        XCTAssertEqual(callbackSnapshot.ends, 1)
        XCTAssertTrue(view.displayLink.isPaused)

        context.attach(to: secondWindow)

        XCTAssertTrue(view.displayLink.isPaused)
        callbackSnapshot = callbacks.snapshot()
        XCTAssertEqual(callbackSnapshot.starts, 1)
        XCTAssertEqual(callbackSnapshot.ends, 1)
        XCTAssertEqual(managerFactory.makeCount, 2)

        context.resumeSubmission()

        XCTAssertFalse(view.displayLink.isPaused)
        context.detach()
    }

    func testPreAttachCriteriaCacheAppliesOnlyTheLatestFormatAndRate() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let managerFactory = PresentationManagerFactory()
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device,
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        let oldFormat = try makeFormatDescription(width: 1_280)
        let latestFormat = try makeFormatDescription(width: 1_920)

        context.updateDisplayCriteria(formatDescription: oldFormat, outputFrameRate: 25)
        context.updateDisplayCriteria(formatDescription: latestFormat, outputFrameRate: 50)
        context.attach(to: window)
        context.updateDisplayCriteria(formatDescription: latestFormat, outputFrameRate: 50)

        XCTAssertEqual(managerFactory.manager.nonNilAssignmentCount, 1)
        context.updateDisplayCriteria(formatDescription: oldFormat, outputFrameRate: 25)
        XCTAssertEqual(managerFactory.manager.nonNilAssignmentCount, 2)
    }

    func testTerminalClearIsACompletionBarrierBeforeStopCanReturn() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = PlaybackPresentationContext(
            renderer: PresentationRenderer(),
            clock: PresentationClock(),
            device: device
        )
        let bridge = PlaybackPresentationDisplayBridge(context: context)
        let view = context.makeMetalVideoView()

        await bridge.clearDisplayCriteria()

        XCTAssertNil(view.displayLink.delegate)
        XCTAssertTrue(view.displayLink.isPaused)
    }

    private func presentationFrame(duration: CMTime) throws -> VideoPresentationFrame {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        return VideoPresentationFrame(
            storage: .metalPlanes(MetalPlaneSet(
                luma: texture,
                chroma: texture,
                retainedObjects: []
            )),
            presentationTimeStamp: .zero,
            duration: duration,
            generation: MediaGeneration(rawValue: 1),
            sequenceNumber: 1,
            sourceAccessUnitID: 1,
            formatMetadata: VideoFormatMetadata(
                dimensions: CMVideoDimensions(width: 1_920, height: 1_080),
                bitDepth: 8,
                range: .video,
                matrix: .bt709,
                transfer: .bt709,
                primaries: .bt709,
                cleanAperture: nil,
                chromaLocation: .init(topField: nil, bottomField: nil),
                hdrStaticMetadata: .init(
                    masteringDisplayColorVolume: nil,
                    contentLightLevelInfo: nil
                )
            )
        )
    }

    private func makeFormatDescription(width: Int32 = 1_920) throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: kCMVideoCodecType_HEVC,
            width: width,
            height: 1_080,
            extensions: nil,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }

    private func eventually(
        _ predicate: @escaping () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not reached")
    }
}

@MainActor
private final class PresentationManagerFactory {
    private(set) var makeCount = 0
    let manager = PresentationCriteriaManager()

    func make(window: UIWindow) -> any DisplayCriteriaManaging {
        _ = window
        makeCount += 1
        return manager
    }
}

@MainActor
private final class PresentationCriteriaManager: DisplayCriteriaManaging {
    private(set) var nonNilAssignmentCount = 0
    private(set) var nilAssignmentCount = 0
    var preferredDisplayCriteria: AVDisplayCriteria? {
        didSet {
            if preferredDisplayCriteria != nil {
                nonNilAssignmentCount += 1
            } else {
                nilAssignmentCount += 1
            }
        }
    }
}

private final class PresentationClock: PlaybackClock {
    var currentTime: CMTime = .zero
    func mediaTime(forHostTime hostTime: CMTime) -> CMTime { hostTime }
    func pause() {}
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {}
}

private final class PresentationRenderer: VideoRendering {
    func enqueue(_ frame: VideoPresentationFrame) {}
    func flush(to generation: MediaGeneration) {}
    func draw(targetMediaTime: CMTime, drawable: any CAMetalDrawable) -> VideoRenderDecision {
        VideoRenderDecision(
            action: .noFrame,
            sourceAccessUnitID: nil,
            sequenceNumber: nil,
            droppedFrameCount: 0
        )
    }
}

private final class PresentationSwitchCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var ends = 0

    func recordStart() { lock.withLock { starts += 1 } }
    func recordEnd() { lock.withLock { ends += 1 } }
    func snapshot() -> (starts: Int, ends: Int) {
        lock.withLock { (starts, ends) }
    }
}
