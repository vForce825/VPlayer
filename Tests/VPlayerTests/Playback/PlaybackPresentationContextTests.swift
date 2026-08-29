// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import XCTest
@testable import VPlayerPlayback

@MainActor
final class PlaybackPresentationContextTests: XCTestCase {
    func testVisibleLayerOwnsExactRendererUsedByPipeline() {
        let view = SampleBufferVideoView(frame: .zero)

        XCTAssertTrue(type(of: view.layer) == AVSampleBufferDisplayLayer.self)
        XCTAssertTrue(view.videoRenderer === view.displayLayer.sampleBufferRenderer)
        XCTAssertEqual(view.displayLayer.videoGravity, .resizeAspect)
    }

    func testContextCachesExactlyOneSystemVideoViewAndRenderer() {
        let context = PlaybackPresentationContext()

        let first = context.makeVideoView()
        let second = context.makeVideoView()

        XCTAssertTrue(first === second)
        XCTAssertTrue(context.videoRenderer === first.videoRenderer)
        context.teardown()
        context.teardown()
        XCTAssertNil(first.windowDidChange)
    }

    func testAttachIsIdempotentAndCriteriaAreDeduplicated() throws {
        let managerFactory = PresentationManagerFactory()
        let context = PlaybackPresentationContext(
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let window = try makeWindow()
        let format = try makeFormatDescription()

        context.attach(to: window)
        context.updateDisplayCriteria(formatDescription: format, outputFrameRate: 50)
        context.attach(to: window)
        context.updateDisplayCriteria(formatDescription: format, outputFrameRate: 50)

        XCTAssertEqual(managerFactory.makeCount, 1)
        XCTAssertEqual(managerFactory.manager.nonNilAssignmentCount, 1)
        context.detach()
        XCTAssertEqual(managerFactory.manager.nilAssignmentCount, 1)
    }

    func testModeSwitchAndDetachBalanceReadinessCallbacksWithoutReplacingView() throws {
        let managerFactory = PresentationManagerFactory()
        let callbacks = PresentationSwitchCallbackRecorder()
        let context = PlaybackPresentationContext(
            switchStarted: { callbacks.recordStart() },
            switchEnded: { callbacks.recordEnd() },
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let view = context.makeVideoView()
        context.attach(to: try makeWindow())
        context.updateDisplayCriteria(
            formatDescription: try makeFormatDescription(),
            outputFrameRate: 50
        )

        NotificationCenter.default.post(name: .AVDisplayManagerModeSwitchStart, object: nil)
        XCTAssertEqual(callbacks.snapshot().starts, 1)
        context.detach()

        XCTAssertEqual(callbacks.snapshot().ends, 1)
        XCTAssertTrue(context.makeVideoView() === view)
    }

    func testBridgeTerminalClearIsBarrierAndSuppressesLateCriteria() async throws {
        let managerFactory = PresentationManagerFactory()
        let context = PlaybackPresentationContext(
            displayManagerFactory: { window in managerFactory.make(window: window) }
        )
        let bridge = PlaybackPresentationDisplayBridge(context: context)
        let view = context.makeVideoView()
        context.attach(to: try makeWindow())

        await bridge.clearDisplayCriteria()
        bridge.updateDisplayCriteria(
            formatDescription: try makeFormatDescription(),
            outputFrameRate: 50
        )
        await Task.yield()

        XCTAssertNil(view.windowDidChange)
        XCTAssertEqual(managerFactory.manager.nonNilAssignmentCount, 0)
    }

    func testCadencePolicyUsesProcessedFrameDurationOnEveryRoute() throws {
        let pixelBuffer = try VideoTestFactories.nv12()
        let frame25 = presentationFrame(
            pixelBuffer: pixelBuffer,
            duration: .init(value: 1, timescale: 25)
        )
        let frame50 = presentationFrame(
            pixelBuffer: pixelBuffer,
            duration: .init(value: 1, timescale: 50)
        )

        XCTAssertEqual(
            PlaybackPresentationCadencePolicy.outputFrameRate(for: frame25, route: .progressive),
            25
        )
        XCTAssertEqual(
            PlaybackPresentationCadencePolicy.outputFrameRate(for: frame50, route: .metalYADIF2x),
            50
        )
        XCTAssertNil(PlaybackPresentationCadencePolicy.outputFrameRate(
            for: presentationFrame(pixelBuffer: pixelBuffer, duration: .invalid),
            route: .progressive
        ))
    }

    private func presentationFrame(
        pixelBuffer: CVPixelBuffer,
        duration: CMTime
    ) -> VideoPresentationFrame {
        VideoPresentationFrame(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: .zero,
            duration: duration,
            generation: MediaGeneration(rawValue: 1),
            sequenceNumber: 1,
            sourceAccessUnitID: 1,
            formatMetadata: VideoTestFactories.metadata()
        )
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        return window
    }

    private func makeFormatDescription() throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: kCMVideoCodecType_HEVC,
            width: 1_920,
            height: 1_080,
            extensions: nil,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
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
            if preferredDisplayCriteria == nil {
                nilAssignmentCount += 1
            } else {
                nonNilAssignmentCount += 1
            }
        }
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
