// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import Foundation
import Metal
import QuartzCore
import UIKit

@MainActor
public final class MetalVideoView: UIView, DisplayLinkControlling {
    typealias Lifecycle = MetalDisplayLinkDriver.Lifecycle

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    private var driver: MetalDisplayLinkDriver!
    private var preferredContentFrameRate: Float?
    var windowDidChange: ((UIWindow?) -> Void)?

    public var displayLink: CAMetalDisplayLink { driver.displayLink }

    public convenience init(
        frame: CGRect,
        clock: PlaybackClock,
        renderer: VideoRendering,
        device: any MTLDevice
    ) {
        self.init(
            frame: frame,
            clock: clock,
            renderer: renderer,
            device: device,
            displayLinkFactory: { CAMetalDisplayLink(metalLayer: $0) },
            lifecycle: Lifecycle()
        )
    }

    convenience init(
        frame: CGRect,
        clock: PlaybackClock,
        renderer: VideoRendering,
        device: any MTLDevice,
        displayLinkFactory: (CAMetalLayer) -> CAMetalDisplayLink
    ) {
        self.init(
            frame: frame,
            clock: clock,
            renderer: renderer,
            device: device,
            displayLinkFactory: displayLinkFactory,
            lifecycle: Lifecycle()
        )
    }

    init(
        frame: CGRect,
        clock: PlaybackClock,
        renderer: VideoRendering,
        device: any MTLDevice,
        displayLinkFactory: (CAMetalLayer) -> CAMetalDisplayLink = {
            CAMetalDisplayLink(metalLayer: $0)
        },
        lifecycle: Lifecycle
    ) {
        super.init(frame: frame)

        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("MetalVideoView requires CAMetalLayer")
        }
        metalLayer.device = device
        HDRPresentationPolicy.systemManaged.configure(layer: metalLayer)
        driver = MetalDisplayLinkDriver(
            layer: metalLayer,
            renderer: renderer,
            clock: clock,
            displayLinkFactory: displayLinkFactory,
            lifecycle: lifecycle
        )
        driver.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    public func startDisplayLink(runLoop: RunLoop = .main) {
        driver.start(runLoop: runLoop)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            contentScaleFactor = window.screen.nativeScale
            applyPreferredFrameRate(for: window.screen)
        }
        updateDrawableSize()
        windowDidChange?(window)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    public func stopDisplayLink() {
        driver.stop()
    }

    public func teardown() {
        stopDisplayLink()
    }

    public func pauseDisplayLink() {
        driver.pause()
    }

    public func resumeDisplayLink() {
        driver.resume()
    }

    public func pause() {
        driver.pause()
    }

    public func resume() {
        driver.resume()
    }

    public func resetPresentationTiming() {
        driver.resetPresentationTiming()
    }

    func setPreferredContentFrameRate(_ framesPerSecond: Float) {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else { return }
        preferredContentFrameRate = framesPerSecond
        if let window {
            applyPreferredFrameRate(for: window.screen)
        }
    }

    func render(
        targetPresentationTimestamp: CFTimeInterval,
        drawable: any CAMetalDrawable
    ) {
        driver.render(
            targetPresentationTimestamp: targetPresentationTimestamp,
            drawable: drawable
        )
    }

    private func updateDrawableSize() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let scale = contentScaleFactor
        let size = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
    }

    private func applyPreferredFrameRate(for screen: UIScreen) {
        driver.setPreferredFrameRate(
            contentFramesPerSecond: preferredContentFrameRate,
            maximumFramesPerSecond: screen.maximumFramesPerSecond
        )
    }
}
