// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct MetalPlayerView: UIViewRepresentable {
    let context: PlaybackPresentationContext

    final class Coordinator {
        let context: PlaybackPresentationContext

        init(context: PlaybackPresentationContext) {
            self.context = context
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context)
    }

    func makeUIView(context _: Context) -> MetalVideoView {
        context.makeMetalVideoView()
    }

    func updateUIView(_: MetalVideoView, context _: Context) {}

    static func dismantleUIView(_ uiView: MetalVideoView, coordinator: Coordinator) {
        _ = uiView
        coordinator.context.detach()
    }
}
