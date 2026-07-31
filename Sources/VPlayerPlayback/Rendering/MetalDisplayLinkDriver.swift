// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import QuartzCore

@MainActor
public final class MetalDisplayLinkDriver: NSObject {
    struct Lifecycle {
        let add: @MainActor (CAMetalDisplayLink, RunLoop, RunLoop.Mode) -> Void
        let remove: @MainActor (CAMetalDisplayLink, RunLoop, RunLoop.Mode) -> Void
        let invalidate: @MainActor (CAMetalDisplayLink) -> Void

        init(
            add: @escaping @MainActor (CAMetalDisplayLink, RunLoop, RunLoop.Mode) -> Void = {
                $0.add(to: $1, forMode: $2)
            },
            remove: @escaping @MainActor (CAMetalDisplayLink, RunLoop, RunLoop.Mode) -> Void = {
                $0.remove(from: $1, forMode: $2)
            },
            invalidate: @escaping @MainActor (CAMetalDisplayLink) -> Void = {
                $0.invalidate()
            }
        ) {
            self.add = add
            self.remove = remove
            self.invalidate = invalidate
        }
    }

    private final class TerminalTeardown: @unchecked Sendable {
        private let lock = NSLock()
        private let link: CAMetalDisplayLink
        private let lifecycle: Lifecycle
        private var scheduledRunLoop: RunLoop?
        private var isComplete = false

        init(link: CAMetalDisplayLink, lifecycle: Lifecycle) {
            self.link = link
            self.lifecycle = lifecycle
        }

        func recordScheduledRunLoop(_ runLoop: RunLoop) {
            lock.withLock {
                guard !isComplete else { return }
                scheduledRunLoop = runLoop
            }
        }

        @MainActor
        func perform() {
            let teardown = lock.withLock { () -> (Bool, RunLoop?) in
                guard !isComplete else { return (false, nil) }
                isComplete = true
                return (true, scheduledRunLoop)
            }
            guard teardown.0 else { return }
            link.isPaused = true
            if let runLoop = teardown.1 {
                lifecycle.remove(link, runLoop, .common)
            }
            link.delegate = nil
            lifecycle.invalidate(link)
        }

        nonisolated func schedule() {
            Task { @MainActor [self] in
                perform()
            }
        }
    }

    let displayLink: CAMetalDisplayLink
    private let clock: PlaybackClock
    private let renderer: VideoRendering
    private let lifecycle: Lifecycle
    private let teardownState: TerminalTeardown
    private var isStarted = false
    private var isStopped = false

    public convenience init(
        layer: CAMetalLayer,
        renderer: VideoRendering,
        clock: PlaybackClock
    ) {
        self.init(
            layer: layer,
            renderer: renderer,
            clock: clock,
            displayLinkFactory: { CAMetalDisplayLink(metalLayer: $0) },
            lifecycle: Lifecycle()
        )
    }

    init(
        layer: CAMetalLayer,
        renderer: VideoRendering,
        clock: PlaybackClock,
        displayLinkFactory: (CAMetalLayer) -> CAMetalDisplayLink = {
            CAMetalDisplayLink(metalLayer: $0)
        },
        lifecycle: Lifecycle
    ) {
        self.clock = clock
        self.renderer = renderer
        self.lifecycle = lifecycle
        let displayLink = displayLinkFactory(layer)
        self.displayLink = displayLink
        teardownState = TerminalTeardown(link: displayLink, lifecycle: lifecycle)
        super.init()
        displayLink.delegate = self
    }

    deinit {
        teardownState.schedule()
    }

    public func start(runLoop: RunLoop = .main) {
        guard runLoop === RunLoop.main, !isStopped, !isStarted else { return }
        isStarted = true
        teardownState.recordScheduledRunLoop(runLoop)
        displayLink.isPaused = false
        lifecycle.add(displayLink, runLoop, .common)
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        teardownState.perform()
    }

    public func pause() {
        guard !isStopped, isStarted, !displayLink.isPaused else { return }
        displayLink.isPaused = true
    }

    public func resume() {
        guard !isStopped, isStarted, displayLink.isPaused else { return }
        displayLink.isPaused = false
    }

    public func resetPresentationTiming() {
        guard !isStopped else { return }
        (renderer as? VideoPresentationTimingResetting)?.resetPresentationTiming()
    }

    /// The decoded presentation cadence is the system scheduling preference;
    /// the screen capability is only the upper bound. This lets a 50p stream
    /// align with a 50 Hz display mode while still allowing 60 callbacks when
    /// the current display cannot switch. Both values come from live media and
    /// UIKit rather than a channel-specific threshold.
    public func setPreferredFrameRate(
        contentFramesPerSecond: Float?,
        maximumFramesPerSecond: Int
    ) {
        guard !isStopped, maximumFramesPerSecond > 0 else { return }
        let maximum = Float(maximumFramesPerSecond)
        let preferred: Float
        if let contentFramesPerSecond,
           contentFramesPerSecond.isFinite,
           contentFramesPerSecond > 0 {
            preferred = min(contentFramesPerSecond, maximum)
        } else {
            preferred = maximum
        }
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: preferred,
            maximum: maximum,
            preferred: preferred
        )
        renderer.recordDisplayRefreshRate(framesPerSecond: Double(preferred))
    }

    func render(
        targetPresentationTimestamp: CFTimeInterval,
        drawable: any CAMetalDrawable
    ) {
        guard isStarted,
              !isStopped,
              !displayLink.isPaused,
              targetPresentationTimestamp.isFinite else {
            return
        }
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

extension MetalDisplayLinkDriver: @MainActor CAMetalDisplayLinkDelegate {
    public func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        guard link === displayLink else { return }
        // Counted before every guard below: a callback the driver discards is
        // still a callback CoreAnimation delivered, and conflating the two hides
        // which side is losing the vsync.
        renderer.recordDisplayLinkCallback(
            targetPresentationTimestamp: update.targetPresentationTimestamp
        )
        render(
            targetPresentationTimestamp: update.targetPresentationTimestamp,
            drawable: update.drawable
        )
    }
}
