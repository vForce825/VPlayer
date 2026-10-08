// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AVKit

public final class AVPlayerPresentationContext: @unchecked Sendable {
    public let player: AVPlayer
    @MainActor private weak var mountedController: AVPlayerViewController?
    #if os(iOS)
    @MainActor private weak var mountedLayer: AVPlayerLayer?
    #endif

    public init(player: AVPlayer) {
        self.player = player
    }

    @MainActor
    public func attach(to controller: AVPlayerViewController) {
        #if os(iOS)
        (player as? IOSControlledAVPlayer)?.setTransportIntentHandler(nil)
        mountedLayer?.player = nil
        mountedLayer = nil
        #endif
        if mountedController !== controller {
            mountedController?.player = nil
            mountedController = controller
        }
        controller.showsPlaybackControls = false
        controller.player = player
    }

    #if os(iOS)
    @MainActor
    public func setPictureInPictureTransportHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?,
        for expectedLayer: AVPlayerLayer
    ) -> Bool {
        guard mountedLayer === expectedLayer,
              let controlled = player as? IOSControlledAVPlayer else { return false }
        controlled.setTransportIntentHandler(handler)
        return true
    }

    @MainActor
    public func detach(from expectedLayer: AVPlayerLayer) {
        guard mountedLayer === expectedLayer else { return }
        _ = setPictureInPictureTransportHandler(nil, for: expectedLayer)
        expectedLayer.player = nil
        mountedLayer = nil
    }

    @MainActor
    public func attach(to layer: AVPlayerLayer) {
        mountedController?.player = nil
        mountedController = nil
        if mountedLayer !== layer {
            (player as? IOSControlledAVPlayer)?.setTransportIntentHandler(nil)
            mountedLayer?.player = nil
            mountedLayer = layer
        }
        layer.player = player
    }
    #endif

    @MainActor
    public func detach(from expectedController: AVPlayerViewController) {
        guard mountedController === expectedController else { return }
        expectedController.player = nil
        mountedController = nil
    }

    @MainActor
    public func detach() {
        #if os(iOS)
        (player as? IOSControlledAVPlayer)?.setTransportIntentHandler(nil)
        mountedLayer?.player = nil
        mountedLayer = nil
        #endif
        mountedController?.player = nil
        mountedController = nil
    }
}

#if os(iOS)
/// AVKit's player-layer PiP controls use AVPlayer transport entry points, not
/// AVPictureInPictureSampleBufferPlaybackDelegate. Keep those calls as intents
/// until the existing registry grants the driver its exact mutation authority.
/// The recursive lock keeps the permission scope thread-local in practice:
/// another thread cannot borrow a driver call's open scope.
private final class IOSPlayerTransportState: @unchecked Sendable {
    private let transportLock = NSRecursiveLock()
    private var driverMutationDepth = 0
    private var intentHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var pendingIntent: Bool?
    private var deliveryQueued = false

    @MainActor
    func setTransportIntentHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        transportLock.lock()
        intentHandler = handler
        pendingIntent = nil
        transportLock.unlock()
    }

    func performDriverMutation(_ operation: () -> Void) {
        transportLock.lock()
        driverMutationDepth += 1
        defer { driverMutationDepth -= 1; transportLock.unlock() }
        operation()
    }

    func transport(paused: Bool, native: () -> Void) {
        transportLock.lock()
        if driverMutationDepth > 0 {
            native()
            transportLock.unlock()
            return
        }
        guard intentHandler != nil else { transportLock.unlock(); return }
        pendingIntent = paused
        let shouldQueue = !deliveryQueued
        deliveryQueued = true
        transportLock.unlock()
        guard shouldQueue else { return }
        DispatchQueue.main.async { [weak self] in self?.deliverIntent() }
    }

    @MainActor
    private func deliverIntent() {
        transportLock.lock()
        deliveryQueued = false
        let handler = intentHandler
        let paused = pendingIntent
        pendingIntent = nil
        transportLock.unlock()
        if let handler, let paused { handler(paused) }
    }

}

final class IOSControlledAVPlayer: AVPlayer, @unchecked Sendable {
    nonisolated private let transportState = IOSPlayerTransportState()

    @MainActor
    func setTransportIntentHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        transportState.setTransportIntentHandler(handler)
    }
    func performDriverMutation(_ operation: () -> Void) {
        transportState.performDriverMutation(operation)
    }

    override var rate: Float {
        get { super.rate }
        set { transportState.transport(paused: newValue == 0) { super.rate = newValue } }
    }
    override func play() { transportState.transport(paused: false) { super.play() } }
    override func pause() { transportState.transport(paused: true) { super.pause() } }
    override func playImmediately(atRate rate: Float) {
        transportState.transport(paused: rate == 0) { super.playImmediately(atRate: rate) }
    }
    override func setRate(_ rate: Float, time itemTime: CMTime, atHostTime hostClockTime: CMTime) {
        transportState.transport(paused: rate == 0) { super.setRate(rate, time: itemTime, atHostTime: hostClockTime) }
    }
}
#endif
