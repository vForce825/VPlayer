// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Metal
import QuartzCore
import XCTest
@testable import VPlayerPlayback

@MainActor
final class MetalDisplayLinkDriverTests: XCTestCase {
    func testStartPauseResumeStopLifecycleIsIdempotentAndTerminal() throws {
        let harness = try makeHarness()
        let runLoop = RunLoop.main

        harness.driver.start(runLoop: runLoop)
        harness.driver.start(runLoop: runLoop)
        XCTAssertEqual(harness.factoryCount(), 1)
        XCTAssertEqual(harness.lifecycle.operations, ["add:kCFRunLoopCommonModes"])
        XCTAssertTrue(harness.driver.displayLink.delegate === harness.driver)

        harness.driver.pause()
        harness.driver.pause()
        XCTAssertTrue(harness.driver.displayLink.isPaused)
        harness.driver.resume()
        harness.driver.resume()
        XCTAssertFalse(harness.driver.displayLink.isPaused)

        harness.driver.stop()
        harness.driver.stop()
        harness.driver.start(runLoop: runLoop)
        harness.driver.resume()
        XCTAssertTrue(harness.driver.displayLink.isPaused)
        XCTAssertNil(harness.driver.displayLink.delegate)
        XCTAssertEqual(harness.lifecycle.operations, [
            "add:kCFRunLoopCommonModes",
            "remove:kCFRunLoopCommonModes",
            "invalidate",
        ])
        XCTAssertTrue(harness.lifecycle.addedRunLoop === harness.lifecycle.removedRunLoop)
        XCTAssertTrue(harness.lifecycle.removeObservedPaused)
        XCTAssertTrue(harness.lifecycle.invalidateObservedDelegateNil)
    }

    func testStopBeforeStartIsTerminalWithoutRemovingAnUnscheduledLink() throws {
        let harness = try makeHarness()

        harness.driver.stop()
        harness.driver.start()
        harness.driver.resume()

        XCTAssertEqual(harness.lifecycle.operations, ["invalidate"])
        XCTAssertTrue(harness.driver.displayLink.isPaused)
        XCTAssertNil(harness.driver.displayLink.delegate)
    }

    func testTargetPresentationTimestampUsesNanosecondHostTimeAndClockBeforeRenderer() throws {
        let harness = try makeHarness()
        let drawable = try DriverDrawable(device: harness.device)
        harness.driver.start()

        harness.driver.render(
            targetPresentationTimestamp: 123.456_789_123,
            drawable: drawable
        )

        XCTAssertEqual(harness.order.values, ["clock", "draw"])
        XCTAssertEqual(harness.clock.hostTimes, [
            CMTime(seconds: 123.456_789_123, preferredTimescale: 1_000_000_000),
        ])
        XCTAssertEqual(harness.renderer.targetTimes, [CMTime(value: 7, timescale: 1)])
    }

    func testInvalidHostOrMediaTimeAndTerminalDriverNeverDraw() throws {
        let harness = try makeHarness()
        let drawable = try DriverDrawable(device: harness.device)
        harness.driver.start()

        harness.driver.render(targetPresentationTimestamp: .nan, drawable: drawable)
        harness.driver.render(targetPresentationTimestamp: .infinity, drawable: drawable)
        harness.clock.mediaTime = .invalid
        harness.driver.render(targetPresentationTimestamp: 10, drawable: drawable)
        harness.driver.stop()
        harness.clock.mediaTime = .zero
        harness.driver.render(targetPresentationTimestamp: 11, drawable: drawable)

        XCTAssertTrue(harness.renderer.targetTimes.isEmpty)
        XCTAssertEqual(harness.clock.hostTimes.count, 1)
    }

    func testResetPresentationTimingForwardsToOptionalRendererSeam() throws {
        let harness = try makeHarness()

        harness.driver.resetPresentationTiming()
        harness.driver.stop()
        harness.driver.resetPresentationTiming()

        XCTAssertEqual(harness.renderer.resetCount, 1)
    }

    func testDeinitializationSchedulesTheSameTerminalTeardown() throws {
        let expectation = expectation(description: "driver invalidated")
        let lifecycle = DriverLifecycleRecorder(invalidationExpectation: expectation)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        let clock = DriverClock(order: DriverOrderRecorder())
        let renderer = DriverRenderer(order: DriverOrderRecorder())
        var driver: MetalDisplayLinkDriver? = MetalDisplayLinkDriver(
            layer: layer,
            renderer: renderer,
            clock: clock,
            lifecycle: lifecycle.lifecycle
        )
        driver?.start()

        driver = nil

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(lifecycle.operations, [
            "add:kCFRunLoopCommonModes",
            "remove:kCFRunLoopCommonModes",
            "invalidate",
        ])
    }

    func testExplicitStopThenDeinitializationInvalidatesExactlyOnce() async throws {
        let lifecycle = DriverLifecycleRecorder()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        var driver: MetalDisplayLinkDriver? = MetalDisplayLinkDriver(
            layer: layer,
            renderer: DriverRenderer(order: DriverOrderRecorder()),
            clock: DriverClock(order: DriverOrderRecorder()),
            lifecycle: lifecycle.lifecycle
        )
        driver?.start()
        driver?.stop()

        driver = nil
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(lifecycle.operations, [
            "add:kCFRunLoopCommonModes",
            "remove:kCFRunLoopCommonModes",
            "invalidate",
        ])
    }

    func testViewOwnsOneDriverAndForwardsControlWhileKeepingMetalLayerPolicy() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let order = DriverOrderRecorder()
        let clock = DriverClock(order: order)
        let renderer = DriverRenderer(order: order)
        let lifecycle = DriverLifecycleRecorder()
        var factoryCount = 0
        let view = MetalVideoView(
            frame: .zero,
            clock: clock,
            renderer: renderer,
            device: device,
            displayLinkFactory: {
                factoryCount += 1
                return CAMetalDisplayLink(metalLayer: $0)
            },
            lifecycle: lifecycle.lifecycle
        )
        let metalLayer = try XCTUnwrap(view.layer as? CAMetalLayer)

        XCTAssertTrue(MetalVideoView.layerClass === CAMetalLayer.self)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(lifecycle.operations, ["add:kCFRunLoopCommonModes"])
        XCTAssertEqual(metalLayer.pixelFormat, .rgba16Float)
        XCTAssertTrue(metalLayer.framebufferOnly)
        XCTAssertEqual(metalLayer.colorspace?.name, CGColorSpace.extendedLinearITUR_2020)
        XCTAssertEqual(metalLayer.toneMapMode, .automatic)

        view.pauseDisplayLink()
        XCTAssertTrue(view.displayLink.isPaused)
        view.resumeDisplayLink()
        XCTAssertFalse(view.displayLink.isPaused)
        view.stopDisplayLink()
        view.startDisplayLink()
        XCTAssertTrue(view.displayLink.isPaused)
    }

    private func makeHarness() throws -> DriverHarness {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        let order = DriverOrderRecorder()
        let clock = DriverClock(order: order)
        let renderer = DriverRenderer(order: order)
        let lifecycle = DriverLifecycleRecorder()
        var factoryCount = 0
        let driver = MetalDisplayLinkDriver(
            layer: layer,
            renderer: renderer,
            clock: clock,
            displayLinkFactory: {
                factoryCount += 1
                return CAMetalDisplayLink(metalLayer: $0)
            },
            lifecycle: lifecycle.lifecycle
        )
        return DriverHarness(
            device: device,
            driver: driver,
            clock: clock,
            renderer: renderer,
            lifecycle: lifecycle,
            order: order,
            factoryCount: { factoryCount }
        )
    }
}

@MainActor
private struct DriverHarness {
    let device: any MTLDevice
    let driver: MetalDisplayLinkDriver
    let clock: DriverClock
    let renderer: DriverRenderer
    let lifecycle: DriverLifecycleRecorder
    let order: DriverOrderRecorder
    let factoryCount: () -> Int
}

@MainActor
private final class DriverLifecycleRecorder {
    var operations: [String] = []
    var addedRunLoop: RunLoop?
    var removedRunLoop: RunLoop?
    var removeObservedPaused = false
    var invalidateObservedDelegateNil = false
    private let invalidationExpectation: XCTestExpectation?

    init(invalidationExpectation: XCTestExpectation? = nil) {
        self.invalidationExpectation = invalidationExpectation
    }

    var lifecycle: MetalDisplayLinkDriver.Lifecycle {
        .init(
            add: { [self] _, runLoop, mode in
                addedRunLoop = runLoop
                operations.append("add:\(mode.rawValue)")
            },
            remove: { [self] link, runLoop, mode in
                removedRunLoop = runLoop
                removeObservedPaused = link.isPaused
                operations.append("remove:\(mode.rawValue)")
            },
            invalidate: { [self] link in
                invalidateObservedDelegateNil = link.delegate == nil
                operations.append("invalidate")
                invalidationExpectation?.fulfill()
            }
        )
    }
}

private final class DriverOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private final class DriverClock: PlaybackClock {
    private let order: DriverOrderRecorder
    var currentTime: CMTime = .zero
    var mediaTime: CMTime = CMTime(value: 7, timescale: 1)
    private(set) var hostTimes: [CMTime] = []

    init(order: DriverOrderRecorder) {
        self.order = order
    }

    func mediaTime(forHostTime hostTime: CMTime) -> CMTime {
        order.append("clock")
        hostTimes.append(hostTime)
        return mediaTime
    }

    func pause() {}
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {}
}

private final class DriverRenderer: VideoRendering, VideoPresentationTimingResetting {
    private let order: DriverOrderRecorder
    private(set) var targetTimes: [CMTime] = []
    private(set) var resetCount = 0

    init(order: DriverOrderRecorder) {
        self.order = order
    }

    func enqueue(_ frame: VideoPresentationFrame) {}
    func flush(to generation: MediaGeneration) {}

    func draw(
        targetMediaTime: CMTime,
        drawable: any CAMetalDrawable
    ) -> VideoRenderDecision {
        order.append("draw")
        targetTimes.append(targetMediaTime)
        return .init(
            action: .noFrame,
            sourceAccessUnitID: nil,
            sequenceNumber: nil,
            droppedFrameCount: 0
        )
    }

    func resetPresentationTiming() {
        resetCount += 1
    }
}

private final class DriverDrawable: NSObject, CAMetalDrawable, @unchecked Sendable {
    let texture: any MTLTexture
    let layer: CAMetalLayer
    let presentedTime: CFTimeInterval = 0
    let drawableID: Int = 1

    init(device: any MTLDevice) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 2,
            height: 2,
            mipmapped: false
        )
        texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        layer = CAMetalLayer()
        super.init()
    }

    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {}
}
