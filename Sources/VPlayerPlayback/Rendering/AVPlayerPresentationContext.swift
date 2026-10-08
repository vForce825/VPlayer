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
    public func attach(to layer: AVPlayerLayer) {
        mountedController?.player = nil
        mountedController = nil
        if mountedLayer !== layer {
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
        mountedLayer?.player = nil
        mountedLayer = nil
        #endif
        mountedController?.player = nil
        mountedController = nil
    }
}
