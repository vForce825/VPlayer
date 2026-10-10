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

/// Composition keeps lifecycle tests independent of native PiP capability.
/// The callback object must have stable identity and be strongly retained.
@MainActor
protocol PiPControllerHandle: AnyObject {
    var callbackObject: AnyObject { get }
    var nativeController: AVPictureInPictureController? { get }
    var contentSource: AVPictureInPictureController.ContentSource? { get }
    var isPictureInPictureActive: Bool { get }
    func observePossibility(_ change: @escaping @Sendable (Bool) -> Void)
    func cancelObservation()
    func startPictureInPicture()
    func stopPictureInPicture()
    func invalidatePlaybackState()
    func detach()
}

@MainActor
private final class NativePiPControllerHandle: PiPControllerHandle {
    private let controller: AVPictureInPictureController
    private var observation: NSKeyValueObservation?
    var callbackObject: AnyObject { controller }
    var nativeController: AVPictureInPictureController? { controller }
    var contentSource: AVPictureInPictureController.ContentSource? { controller.contentSource }
    var isPictureInPictureActive: Bool { controller.isPictureInPictureActive }

    static func make(source: AVPictureInPictureController.ContentSource,
                     delegate: any AVPictureInPictureControllerDelegate) -> (any PiPControllerHandle)? {
        // AVKit documents that unsupported construction returns nil despite the
        // nonfailable Swift signature. A policy/test override cannot bypass this.
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        return NativePiPControllerHandle(source: source, delegate: delegate)
    }
    private init(source: AVPictureInPictureController.ContentSource,
                 delegate: any AVPictureInPictureControllerDelegate) {
        controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = delegate
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
    }
    func observePossibility(_ change: @escaping @Sendable (Bool) -> Void) {
        cancelObservation()
        observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { _, value in
            change(value.newValue ?? false)
        }
    }
    func cancelObservation() {
        observation?.invalidate()
        observation = nil
    }
    func startPictureInPicture() { controller.startPictureInPicture() }
    func stopPictureInPicture() { controller.stopPictureInPicture() }
    func invalidatePlaybackState() {
        guard contentSource?.sampleBufferDisplayLayer != nil else { return }
        controller.invalidatePlaybackState()
    }
    func detach() {
        cancelObservation()
        controller.delegate = nil
        controller.contentSource = nil
    }
}

final class PiPPlaybackSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = true
    private var available = false
    private var identity: ObjectIdentifier?
    private var restoreIdentity: ObjectIdentifier?
    private var pendingTransport: (PiPCallbackReference<AnyObject>, Bool)?
    private var transportDeliveryQueued = false
    func update(paused: Bool, available: Bool, identity: ObjectIdentifier?) {
        lock.withLock {
            if self.identity != identity { restoreIdentity = nil; pendingTransport = nil }
            self.paused = paused; self.available = available; self.identity = identity
        }
    }
    func queueTransport(_ reference: PiPCallbackReference<AnyObject>, paused: Bool) -> Bool {
        lock.withLock {
            guard identity == reference.identity else { return false }
            pendingTransport = (reference, paused)
            let shouldQueue = !transportDeliveryQueued
            transportDeliveryQueued = true
            return shouldQueue
        }
    }
    func takeTransport() -> (PiPCallbackReference<AnyObject>, Bool)? {
        lock.withLock {
            defer { pendingTransport = nil; transportDeliveryQueued = false }
            return pendingTransport
        }
    }
    func requestRestore(_ identity: ObjectIdentifier) {
        lock.withLock { if self.identity == identity { restoreIdentity = identity } }
    }
    func clearRestoreIntent() { lock.withLock { restoreIdentity = nil } }
    func consumeRestoreIntent(_ identity: ObjectIdentifier) -> Bool {
        lock.withLock {
            guard restoreIdentity == identity else { return false }
            restoreIdentity = nil
            return true
        }
    }
    func read(for controller: AnyObject) -> (paused: Bool, available: Bool) {
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
    typealias ControllerFactory = @MainActor (AVPictureInPictureController.ContentSource,
        any AVPictureInPictureControllerDelegate) -> (any PiPControllerHandle)?
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var message: String?
    @ObservationIgnored var onStarted: (@MainActor () -> Void)?
    @ObservationIgnored var onStopped: (@MainActor () -> Void)?
    @ObservationIgnored var onRestore: RestoreRequest?
    @ObservationIgnored private weak var target: (any NowPlayingPlaybackTarget)?
    @ObservationIgnored private var controller: (any PiPControllerHandle)?
    @ObservationIgnored private var retiring: (any PiPControllerHandle)?
    @ObservationIgnored private var pending: (PresentationIdentity, AVPictureInPictureController.ContentSource)?
    @ObservationIgnored private var presentationIdentity: PresentationIdentity?
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTransport: (PresentationIdentity, Bool)?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var state: PlaybackState = .idle
    @ObservationIgnored private var paused = true
    nonisolated private let snapshot = PiPPlaybackSnapshot()
    @ObservationIgnored private let supportsPictureInPicture: @MainActor () -> Bool
    @ObservationIgnored private let setPictureInPicture: @MainActor (Bool) -> Void
    @ObservationIgnored private let makeController: ControllerFactory

    #if DEBUG
    /// Read-only native state for hosted integration tests, not a transport authority.
    var nativeControllerForTesting: AVPictureInPictureController? { controller?.nativeController }
    #endif

    init(target: any NowPlayingPlaybackTarget,
         supportsPictureInPicture: @escaping @MainActor () -> Bool = { AVPictureInPictureController.isPictureInPictureSupported() },
         setPictureInPicture: @escaping @MainActor (Bool) -> Void = PlaybackVideoProcessingActivity.setPictureInPicture,
         makeController: @escaping ControllerFactory = { NativePiPControllerHandle.make(source: $0, delegate: $1) }) {
        self.target = target
        self.supportsPictureInPicture = supportsPictureInPicture
        self.setPictureInPicture = setPictureInPicture
        self.makeController = makeController
        super.init()
    }

    func install(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer, identity: PresentationIdentity) {
        install(.init(sampleBufferDisplayLayer: sampleBufferDisplayLayer, playbackDelegate: self), identity: identity)
    }
    func requestPlayerTransport(paused: Bool, identity: PresentationIdentity) {
        guard !closed, presentationIdentity == identity else { return }
        pendingTransport = (identity, paused)
        startTransportWorker()
    }
    private func startTransportWorker() {
        guard !closed, transportTask == nil, pendingTransport != nil else { return }
        transportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.transportTask = nil; self.startTransportWorker() }
            while !Task.isCancelled, !self.closed, let command = self.pendingTransport {
                self.pendingTransport = nil
                guard self.presentationIdentity == command.0 else { continue }
                await self.target?.setPausedFromNowPlaying(command.1)
            }
        }
    }
    private func drainSampleTransport() {
        guard let command = snapshot.takeTransport(), currentID == command.0.identity,
              let identity = presentationIdentity else { return }
        requestPlayerTransport(paused: command.1, identity: identity)
    }
    func install(playerLayer: AVPlayerLayer, identity: PresentationIdentity) {
        install(.init(playerLayer: playerLayer), identity: identity)
    }
    private func install(_ source: AVPictureInPictureController.ContentSource, identity: PresentationIdentity) {
        guard !closed, presentationIdentity != identity else { return }
        guard supportsPictureInPicture() else {
            message = "当前设备不支持画中画。后台音频仍由系统播放策略管理。"
            return
        }
        pending = (identity, source)
        retireCurrent()
        installPendingIfPossible()
    }
    func retire(identity: PresentationIdentity) {
        if pending?.0 == identity { pending = nil }
        guard presentationIdentity == identity else { return }
        pending = nil
        retireCurrent()
    }
    private func retireCurrent() {
        guard let current = controller else { return }
        pendingTransport = nil
        transportTask?.cancel()
        current.cancelObservation()
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
            current.detach()
            // Native state can become inactive before its queued didStop actor
            // hop. Retiring the identity makes that callback stale, so retire
            // its processing policy here as well. Do not stop the replacement session.
            starting = false
            isActive = false
            restoring = false
            setPictureInPicture(false)
        }
    }
    private func installPendingIfPossible() {
        guard !closed, retiring == nil, let pending else { return }
        self.pending = nil
        guard let current = makeController(pending.1, self) else {
            presentationIdentity = nil
            starting = false; isActive = false; isPossible = false; restoring = false
            updateSnapshot()
            setPictureInPicture(false)
            message = "当前设备无法创建画中画，播放会继续。"
            return
        }
        controller = current
        presentationIdentity = pending.0
        let reference = PiPCallbackReference(current.callbackObject)
        current.observePossibility { [weak self] possible in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentID == reference.identity else { return }
                self.isPossible = possible
            }
        }
        updateSnapshot()
        invalidatePlaybackStateIfNeeded()
    }
    private var currentID: ObjectIdentifier? { controller.map { ObjectIdentifier($0.callbackObject) } }
    private var retiringID: ObjectIdentifier? { retiring.map { ObjectIdentifier($0.callbackObject) } }
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
        setPictureInPicture(true)
        controller.startPictureInPicture()
    }
    func stopForRestoration() {
        guard let controller, isActive || starting || controller.isPictureInPictureActive else { return }
        restoring = true
        controller.stopPictureInPicture()
    }
    func update(state: PlaybackState, paused: Bool) {
        self.state = state; self.paused = paused
        updateSnapshot()
        invalidatePlaybackStateIfNeeded()
    }
    private func invalidatePlaybackStateIfNeeded() {
        guard let controller, controller.contentSource?.sampleBufferDisplayLayer != nil else { return }
        controller.invalidatePlaybackState()
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
        pendingTransport = nil
        transportTask?.cancel()
        pending = nil
        for item in [controller, retiring].compactMap({ $0 }) {
            item.cancelObservation()
            item.stopPictureInPicture()
            item.detach()
        }
        controller = nil; retiring = nil; presentationIdentity = nil
        isActive = false; isPossible = false; starting = false
        updateSnapshot()
        setPictureInPicture(false)
    }
    private func didStart(_ identity: ObjectIdentifier) {
        guard !closed else { return }
        if retiringID == identity {
            retiring?.stopPictureInPicture()
            return
        }
        guard currentID == identity else { return }
        starting = false; isActive = true
        setPictureInPicture(true)
        onStarted?()
    }
    private func didStop(_ identity: ObjectIdentifier) {
        guard !closed else { return }
        if retiringID == identity {
            retiring?.cancelObservation()
            retiring?.detach()
            retiring = nil
            starting = false; isActive = false
            setPictureInPicture(false)
            installPendingIfPossible()
            return
        }
        guard currentID == identity else { return }
        starting = false; isActive = false
        setPictureInPicture(false)
        let restored = snapshot.consumeRestoreIntent(identity)
        if !restoring && !restored { onStopped?() }
        restoring = false
    }
    private func failed(_ identity: ObjectIdentifier) {
        guard !closed else { return }
        if retiringID == identity {
            didStop(identity)
            return
        }
        guard currentID == identity else { return }
        starting = false; isActive = false; restoring = false
        snapshot.clearRestoreIntent()
        setPictureInPicture(false)
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
        receiveDidStart(controller)
    }
    nonisolated func receiveDidStart(_ controller: AnyObject) {
        let reference = PiPCallbackReference(controller)
        DispatchQueue.main.async { [weak self] in self?.didStart(reference.identity) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        receiveDidStop(controller)
    }
    nonisolated func receiveDidStop(_ controller: AnyObject) {
        let reference = PiPCallbackReference(controller)
        DispatchQueue.main.async { [weak self] in self?.didStop(reference.identity) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error) {
        receiveFailure(controller)
    }
    nonisolated func receiveFailure(_ controller: AnyObject) {
        let reference = PiPCallbackReference(controller)
        DispatchQueue.main.async { [weak self] in self?.failed(reference.identity) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        receiveRestore(controller, completionHandler: completionHandler)
    }
    nonisolated func receiveRestore(_ controller: AnyObject, completionHandler: @escaping (Bool) -> Void) {
        let reference = PiPCallbackReference(controller)
        let reply = PiPRestoreReply(completionHandler)
        snapshot.requestRestore(reference.identity)
        DispatchQueue.main.async { [weak self] in
            guard let self else { reply.call(false); return }
            self.restore(reference.identity, reply: reply)
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        receiveTransport(controller, playing: playing)
    }
    nonisolated func receiveTransport(_ controller: AnyObject, playing: Bool) {
        let reference = PiPCallbackReference(controller)
        guard snapshot.queueTransport(reference, paused: !playing) else { return }
        DispatchQueue.main.async { [weak self] in self?.drainSampleTransport() }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        playbackTimeRange(for: controller)
    }
    nonisolated func playbackTimeRange(for controller: AnyObject) -> CMTimeRange {
        snapshot.read(for: controller).available ? CMTimeRange(start: .zero, duration: .positiveInfinity) : .invalid
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        isPlaybackPaused(for: controller)
    }
    nonisolated func isPlaybackPaused(for controller: AnyObject) -> Bool {
        snapshot.read(for: controller).paused
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool { false }
}
