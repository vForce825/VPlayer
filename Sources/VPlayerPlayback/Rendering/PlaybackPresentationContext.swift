// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import Metal
import UIKit

public enum PlaybackPresentationRoute: UInt8, Sendable, Equatable {
    case progressive
    case appleTemporal
    case metalYADIF2x
    case rawInterlacedAfterTemporalFailure
}

public enum PlaybackPresentationCadencePolicy {
    public static func outputFrameRate(
        for frame: VideoPresentationFrame,
        route: PlaybackPresentationRoute
    ) -> Float? {
        let duration = frame.duration
        guard duration.isNumeric,
              duration.epoch == 0,
              duration.value > 0,
              duration.timescale > 0 else { return nil }
        var rate = Float(duration.timescale) / Float(duration.value)
        if route == .rawInterlacedAfterTemporalFailure {
            rate *= 2
        }
        guard rate.isFinite, rate > 0 else { return nil }
        return min(rate, 120)
    }
}

@MainActor
private final class PresentationReadinessAdapter: DisplayReadinessControlling {
    private let switchWillStart: () -> Void
    private let switchStarted: @Sendable () -> Void
    private let switchEnded: @Sendable () -> Void

    init(
        switchWillStart: @escaping () -> Void,
        switchStarted: @escaping @Sendable () -> Void,
        switchEnded: @escaping @Sendable () -> Void
    ) {
        self.switchWillStart = switchWillStart
        self.switchStarted = switchStarted
        self.switchEnded = switchEnded
    }

    func closeForDisplayModeSwitch() {
        switchWillStart()
        switchStarted()
    }

    func reanchorAfterDisplayModeSwitch() -> Bool {
        switchEnded()
        return false
    }
}

public final class PlaybackPresentationContext: @unchecked Sendable {
    private struct CriteriaRequest {
        let formatIdentity: ObjectIdentifier
        let formatDescription: CMFormatDescription
        let outputFrameRate: Float
    }

    typealias DisplayManagerFactory = @MainActor @Sendable (UIWindow) -> any DisplayCriteriaManaging

    private let renderer: any VideoRendering
    private let clock: any PlaybackClock
    private let device: any MTLDevice
    private let switchStarted: @Sendable () -> Void
    private let switchEnded: @Sendable () -> Void
    private let displayManagerFactory: DisplayManagerFactory

    @MainActor private var cachedView: MetalVideoView?
    @MainActor private var criteriaController: DisplayCriteriaController?
    @MainActor private weak var attachedWindow: UIWindow?
    @MainActor private var pendingCriteria: CriteriaRequest?
    @MainActor private var submissionPaused = true
    @MainActor private var displayModeSwitchPending = false
    @MainActor private var terminal = false

    init(
        renderer: any VideoRendering,
        clock: any PlaybackClock,
        device: any MTLDevice,
        displayManagerFactory: @escaping DisplayManagerFactory = {
            WindowDisplayCriteriaManager(window: $0)
        }
    ) {
        self.renderer = renderer
        self.clock = clock
        self.device = device
        switchStarted = {}
        switchEnded = {}
        self.displayManagerFactory = displayManagerFactory
    }

    init(
        renderer: any VideoRendering,
        clock: any PlaybackClock,
        device: any MTLDevice,
        switchStarted: @escaping @Sendable () -> Void,
        switchEnded: @escaping @Sendable () -> Void,
        displayManagerFactory: @escaping DisplayManagerFactory = {
            WindowDisplayCriteriaManager(window: $0)
        }
    ) {
        self.renderer = renderer
        self.clock = clock
        self.device = device
        self.switchStarted = switchStarted
        self.switchEnded = switchEnded
        self.displayManagerFactory = displayManagerFactory
    }

    @MainActor
    public func makeMetalVideoView() -> MetalVideoView {
        if let cachedView { return cachedView }
        let view = MetalVideoView(
            frame: .zero,
            clock: clock,
            renderer: renderer,
            device: device
        )
        view.windowDidChange = { [weak self] window in
            guard let self else { return }
            if let window {
                self.attach(to: window)
            } else {
                self.detach()
            }
        }
        applySubmissionState(to: view)
        if terminal { view.stopDisplayLink() }
        cachedView = view
        return view
    }

    @MainActor
    public func attach(to window: UIWindow) {
        guard !terminal else { return }
        let view = makeMetalVideoView()
        guard attachedWindow !== window || criteriaController == nil else {
            applySubmissionState(to: view)
            return
        }
        criteriaController?.leaveFullScreen()
        attachedWindow = window
        let readiness = PresentationReadinessAdapter(
            switchWillStart: { [weak self] in
                self?.displayModeSwitchPending = true
            },
            switchStarted: switchStarted,
            switchEnded: switchEnded
        )
        let controller = DisplayCriteriaController(
            manager: displayManagerFactory(window),
            displayLink: view,
            readiness: readiness
        )
        criteriaController = controller
        applySubmissionState(to: view)
        if let pendingCriteria {
            controller.enterFullScreen(
                formatDescription: pendingCriteria.formatDescription,
                outputFrameRate: pendingCriteria.outputFrameRate
            )
        }
    }

    @MainActor
    public func detach() {
        criteriaController?.leaveFullScreen()
        criteriaController = nil
        attachedWindow = nil
        cachedView?.pauseDisplayLink()
    }

    @MainActor
    func pauseSubmission() {
        guard !terminal else { return }
        submissionPaused = true
        cachedView?.pauseDisplayLink()
    }

    @MainActor
    func resumeSubmission() {
        guard !terminal else { return }
        submissionPaused = false
        displayModeSwitchPending = false
        guard attachedWindow != nil else {
            cachedView?.pauseDisplayLink()
            return
        }
        cachedView?.resumeDisplayLink()
    }

    @MainActor
    func resetPresentationTiming() {
        guard !terminal else { return }
        cachedView?.resetPresentationTiming()
    }

    @MainActor
    func updateDisplayCriteria(
        formatDescription: CMFormatDescription,
        outputFrameRate: Float
    ) {
        guard !terminal, outputFrameRate.isFinite, outputFrameRate > 0 else { return }
        let request = CriteriaRequest(
            formatIdentity: ObjectIdentifier(formatDescription as AnyObject),
            formatDescription: formatDescription,
            outputFrameRate: outputFrameRate
        )
        if let pendingCriteria,
           pendingCriteria.formatIdentity == request.formatIdentity,
           pendingCriteria.outputFrameRate == request.outputFrameRate {
            return
        }
        pendingCriteria = request
        criteriaController?.enterFullScreen(
            formatDescription: formatDescription,
            outputFrameRate: outputFrameRate
        )
    }

    @MainActor
    public func teardown() {
        guard !terminal else { return }
        terminal = true
        submissionPaused = true
        pendingCriteria = nil
        criteriaController?.leaveFullScreen()
        criteriaController = nil
        attachedWindow = nil
        cachedView?.windowDidChange = nil
        cachedView?.pauseDisplayLink()
        cachedView?.stopDisplayLink()
    }

    @MainActor
    private func applySubmissionState(to view: MetalVideoView) {
        if submissionPaused || displayModeSwitchPending || attachedWindow == nil || terminal {
            view.pauseDisplayLink()
        } else {
            view.resumeDisplayLink()
        }
    }
}

final class PlaybackPresentationDisplayBridge: PlaybackDisplayControlling, @unchecked Sendable {
    let context: PlaybackPresentationContext
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(context: PlaybackPresentationContext) {
        self.context = context
    }

    func pauseSubmission() {
        enqueue { $0.pauseSubmission() }
    }

    func resumeSubmission() {
        enqueue { $0.resumeSubmission() }
    }

    func resetPresentationTiming() {
        enqueue { $0.resetPresentationTiming() }
    }

    func updateDisplayCriteria(
        formatDescription: CMFormatDescription,
        outputFrameRate: Float
    ) {
        enqueue { context in
            context.updateDisplayCriteria(
                formatDescription: formatDescription,
                outputFrameRate: outputFrameRate
            )
        }
    }

    func clearDisplayCriteria() async {
        await enqueue { $0.teardown() }.value
    }

    @discardableResult
    private func enqueue(
        _ operation: @escaping @MainActor @Sendable (PlaybackPresentationContext) -> Void
    ) -> Task<Void, Never> {
        lock.withLock {
            let predecessor = tail
            let context = context
            let task = Task { @MainActor in
                await predecessor?.value
                operation(context)
            }
            tail = task
            return task
        }
    }
}
