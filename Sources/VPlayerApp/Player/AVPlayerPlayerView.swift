// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVKit
import SwiftUI
import VPlayerPlayback

struct AVPlayerPlayerView: UIViewControllerRepresentable {
    let context: AVPlayerPresentationContext

    final class Coordinator {
        var context: AVPlayerPresentationContext

        init(context: AVPlayerPresentationContext) {
            self.context = context
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context)
    }

    static func makeController(context: AVPlayerPresentationContext) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        context.attach(to: controller)
        return controller
    }

    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        Self.makeController(context: context)
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context update: Context) {
        controller.showsPlaybackControls = false
        if update.coordinator.context !== self.context {
            update.coordinator.context.detach(from: controller)
            update.coordinator.context = self.context
            self.context.attach(to: controller)
        } else if controller.player !== self.context.player {
            self.context.attach(to: controller)
        }
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        coordinator.context.detach(from: controller)
        controller.player = nil
    }
}
