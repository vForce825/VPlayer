// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreGraphics
import CoreMedia
import Foundation
import Metal
import QuartzCore
import UIKit

@MainActor
public final class MetalVideoView: UIView, DisplayLinkControlling {
    struct Lifecycle {
        let add: (CAMetalDisplayLink, RunLoop.Mode) -> Void
        let remove: (CAMetalDisplayLink, RunLoop.Mode) -> Void
        let invalidate: (CAMetalDisplayLink) -> Void

        init(
            add: @escaping (CAMetalDisplayLink, RunLoop.Mode) -> Void = {
                $0.add(to: .main, forMode: $1)
            },
            remove: @escaping (CAMetalDisplayLink, RunLoop.Mode) -> Void = {
                $0.remove(from: .main, forMode: $1)
            },
            invalidate: @escaping (CAMetalDisplayLink) -> Void = { $0.invalidate() }
        ) {
            self.add = add
            self.remove = remove
            self.invalidate = invalidate
        }
    }

    private final class DisplayLinkTeardown: @unchecked Sendable {
        private let lock = NSLock()
        private let link: CAMetalDisplayLink
        private let lifecycle: Lifecycle
        private var isComplete = false

        init(link: CAMetalDisplayLink, lifecycle: Lifecycle) {
            self.link = link
            self.lifecycle = lifecycle
        }

        @MainActor
        func perform() {
            let shouldPerform = lock.withLock {
                guard !isComplete else { return false }
                isComplete = true
                return true
            }
            guard shouldPerform else { return }
            lifecycle.remove(link, .common)
            link.delegate = nil
            lifecycle.invalidate(link)
        }

        nonisolated func schedule() {
            Task { @MainActor [self] in
                perform()
            }
        }
    }

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public private(set) var displayLink: CAMetalDisplayLink!
    private let clock: PlaybackClock
    private let renderer: VideoRendering
    private var teardownState: DisplayLinkTeardown!
    private var isTornDown = false

    convenience init(
        frame: CGRect,
        clock: PlaybackClock,
        renderer: VideoRendering,
        device: any MTLDevice,
        displayLinkFactory: (CAMetalLayer) -> CAMetalDisplayLink = {
            CAMetalDisplayLink(metalLayer: $0)
        }
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
        self.clock = clock
        self.renderer = renderer
        super.init(frame: frame)

        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("MetalVideoView requires CAMetalLayer")
        }
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        metalLayer.toneMapMode = .automatic

        displayLink = displayLinkFactory(metalLayer)
        displayLink.delegate = self
        lifecycle.add(displayLink, .common)
        teardownState = DisplayLinkTeardown(link: displayLink, lifecycle: lifecycle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        teardownState.schedule()
    }

    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        displayLink.isPaused = true
        teardownState.perform()
    }

    public func pauseDisplayLink() {
        guard !isTornDown, !displayLink.isPaused else { return }
        displayLink.isPaused = true
    }

    public func resumeDisplayLink() {
        guard !isTornDown, displayLink.isPaused else { return }
        displayLink.isPaused = false
    }

    public func pause() {
        pauseDisplayLink()
    }

    public func resume() {
        resumeDisplayLink()
    }

    public func resetPresentationTiming() {
        guard !isTornDown else { return }
        (renderer as? VideoPresentationTimingResetting)?.resetPresentationTiming()
    }

    func render(
        targetPresentationTimestamp: CFTimeInterval,
        drawable: any CAMetalDrawable
    ) {
        guard !isTornDown, targetPresentationTimestamp.isFinite else { return }
        let hostTime = CMTime(
            seconds: targetPresentationTimestamp,
            preferredTimescale: 1_000_000_000
        )
        guard hostTime.isNumeric else { return }
        let mediaTime = clock.mediaTime(forHostTime: hostTime)
        guard mediaTime.isNumeric else { return }
        _ = renderer.draw(targetMediaTime: mediaTime, drawable: drawable)
    }
}

extension MetalVideoView: @MainActor CAMetalDisplayLinkDelegate {
    public func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        guard link === displayLink, !isTornDown else { return }
        render(
            targetPresentationTimestamp: update.targetPresentationTimestamp,
            drawable: update.drawable
        )
    }
}
