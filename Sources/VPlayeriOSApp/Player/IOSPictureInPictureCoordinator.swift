// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AVKit
import Foundation
import Observation
import UIKit
import VPlayerPlayback

/// Pins the native controller through a MainActor hop. A bare ObjectIdentifier
/// is unsafe once a retiring object can deallocate and its address be reused.
struct PiPCallbackReference<Object: AnyObject>: @unchecked Sendable {
    let object: Object
    init(_ object: Object) { self.object = object }
    var identity: ObjectIdentifier { ObjectIdentifier(object) }
}

private final class PiPPlaybackSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = true
    private var available = false
    private var identity: ObjectIdentifier?
    private var restoreIdentity: ObjectIdentifier?
    func update(paused: Bool, available: Bool, identity: ObjectIdentifier?) {
        lock.withLock {
            if self.identity != identity { restoreIdentity = nil }
            self.paused = paused; self.available = available; self.identity = identity
        }
    }
    func requestRestore(_ identity: ObjectIdentifier) {
        lock.withLock { if self.identity == identity { restoreIdentity = identity } }
    }
    func clearRestoreIntent() { lock.withLock { restoreIdentity = nil } }
    func isRestoring(_ identity: ObjectIdentifier) -> Bool { lock.withLock { restoreIdentity == identity } }
    func read(for controller: AVPictureInPictureController) -> (paused: Bool, available: Bool) {
        lock.withLock {
            guard identity == ObjectIdentifier(controller) else { return (true, false) }
            return (paused, available)
        }
    }
}

private final class PiPRestoreReply: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Bool) -> Void)?
    init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    func call(_ result: Bool) {
        let callback = lock.withLock { let value = self.callback; self.callback = nil; return value }
        callback?(result)
    }
}

@MainActor
@Observable
final class IOSPictureInPictureCoordinator: NSObject,
    AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    typealias RestoreRequest = @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var message: String?
    @ObservationIgnored var onStarted: (@MainActor () -> Void)?
    @ObservationIgnored var onStopped: (@MainActor () -> Void)?
    @ObservationIgnored var onRestore: RestoreRequest?
    @ObservationIgnored private weak var target: (any NowPlayingPlaybackTarget)?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var retiring: AVPictureInPictureController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var pending: (PresentationIdentity, AVPictureInPictureController.ContentSource)?
    @ObservationIgnored private var presentationIdentity: PresentationIdentity?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var state: PlaybackState = .idle
    @ObservationIgnored private var paused = true
    nonisolated private let snapshot = PiPPlaybackSnapshot()

    init(target: any NowPlayingPlaybackTarget) { self.target = target; super.init() }

    func install(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer, identity: PresentationIdentity) {
        install(.init(sampleBufferDisplayLayer: sampleBufferDisplayLayer, playbackDelegate: self), identity: identity)
    }
    func install(playerLayer: AVPlayerLayer, identity: PresentationIdentity) {
        install(.init(playerLayer: playerLayer), identity: identity)
    }
    private func install(_ source: AVPictureInPictureController.ContentSource, identity: PresentationIdentity) {
        guard !closed, presentationIdentity != identity else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            message = "当前设备不支持画中画。后台音频仍由系统播放策略管理。"
            return
        }
        pending = (identity, source)
        retireCurrent()
        installPendingIfPossible()
    }
    func retire(identity: PresentationIdentity) {
        guard presentationIdentity == identity else { return }
        pending = nil
        retireCurrent()
    }
    private func retireCurrent() {
        guard let current = controller else { return }
        observation = nil
        controller = nil
        presentationIdentity = nil
        isPossible = false
        updateSnapshot()
        if current.isPictureInPictureActive || starting {
            // Exactly one retiring controller and one latest desired source.
            // Never create replacements while the old PiP is still stopping.
            precondition(retiring == nil)
            retiring = current
            current.stopPictureInPicture()
        } else {
            current.delegate = nil
            current.contentSource = nil
            starting = false
        }
    }
    private func installPendingIfPossible() {
        guard !closed, retiring == nil, let pending else { return }
        self.pending = nil
        let current = AVPictureInPictureController(contentSource: pending.1)
        controller = current
        presentationIdentity = pending.0
        current.delegate = self
        current.requiresLinearPlayback = true
        current.canStartPictureInPictureAutomaticallyFromInline = true
        let reference = PiPCallbackReference(current)
        observation = current.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor [weak self] in
                guard let self, self.currentID == reference.identity else { return }
                self.isPossible = possible
            }
        }
        updateSnapshot()
        current.invalidatePlaybackState()
    }
    private var currentID: ObjectIdentifier? { controller.map(ObjectIdentifier.init) }
    func start() {
        guard !closed, !starting, let controller, isPossible else {
            message = "画中画尚未就绪，请在画面开始播放后重试。"
            return
        }
        message = nil
        restoring = false
        snapshot.clearRestoreIntent()
        starting = true
        // Close GPU admission before asking AVKit to start its transition.
        PlaybackVideoProcessingActivity.setPictureInPicture(true)
        controller.startPictureInPicture()
    }
    func stopForRestoration() {
        restoring = true
        controller?.stopPictureInPicture()
    }
    func update(state: PlaybackState, paused: Bool) {
        self.state = state; self.paused = paused
        updateSnapshot()
        controller?.invalidatePlaybackState()
    }
    private func updateSnapshot() {
        let available: Bool
        switch state {
        case .playing, .paused, .buffering, .recovering: available = true
        case .idle, .preparing, .stopped, .failed: available = false
        }
        snapshot.update(paused: paused, available: available, identity: currentID)
    }
    func close() {
        guard !closed else { return }
        closed = true
        observation = nil
        pending = nil
        for item in [controller, retiring].compactMap({ $0 }) {
            item.delegate = nil
            item.stopPictureInPicture()
            item.contentSource = nil
        }
        controller = nil; retiring = nil; presentationIdentity = nil
        isActive = false; isPossible = false; starting = false
        updateSnapshot()
        PlaybackVideoProcessingActivity.setPictureInPicture(false)
    }
    private func didStart(_ identity: ObjectIdentifier) {
        guard !closed else { return }
        if retiring.map(ObjectIdentifier.init) == identity {
            retiring?.stopPictureInPicture()
            return
        }
        guard currentID == identity else { return }
        starting = false; isActive = true
        PlaybackVideoProcessingActivity.setPictureInPicture(true)
        onStarted?()
    }
    private func didStop(_ identity: ObjectIdentifier) {
        guard !closed else { return }
        if retiring.map(ObjectIdentifier.init) == identity {
            retiring?.delegate = nil
            retiring?.contentSource = nil
            retiring = nil
            starting = false; isActive = false
            PlaybackVideoProcessingActivity.setPictureInPicture(false)
            installPendingIfPossible()
            return
        }
        guard currentID == identity else { return }
        starting = false; isActive = false
        PlaybackVideoProcessingActivity.setPictureInPicture(false)
        if !restoring && !snapshot.isRestoring(identity) { onStopped?() }
        restoring = false
    }
    private func failed(_ identity: ObjectIdentifier) {
        guard !closed else { return }
        if retiring.map(ObjectIdentifier.init) == identity {
            didStop(identity)
            return
        }
        guard currentID == identity else { return }
        starting = false; isActive = false
        PlaybackVideoProcessingActivity.setPictureInPicture(false)
        message = "暂时无法进入画中画，播放会继续。请返回全屏后重试。"
    }
    private func restore(_ identity: ObjectIdentifier, reply: PiPRestoreReply) {
        guard !closed, currentID == identity, let onRestore else { reply.call(false); return }
        restoring = true
        onRestore { [weak self] success in
            guard let self, !self.closed, self.currentID == identity else { reply.call(false); return }
            reply.call(success)
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let reference = PiPCallbackReference(controller)
        Task { @MainActor [weak self] in self?.didStart(reference.identity) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let reference = PiPCallbackReference(controller)
        Task { @MainActor [weak self] in self?.didStop(reference.identity) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error) {
        let reference = PiPCallbackReference(controller)
        Task { @MainActor [weak self] in self?.failed(reference.identity) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let reference = PiPCallbackReference(controller)
        let reply = PiPRestoreReply(completionHandler)
        snapshot.requestRestore(reference.identity)
        Task { @MainActor [weak self] in
            guard let self else { reply.call(false); return }
            self.restore(reference.identity, reply: reply)
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        let reference = PiPCallbackReference(controller)
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.currentID == reference.identity else { return }
            await self.target?.setPausedFromNowPlaying(!playing)
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        snapshot.read(for: controller).available ? CMTimeRange(start: .zero, duration: .positiveInfinity) : .invalid
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        snapshot.read(for: controller).paused
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool { false }
}
