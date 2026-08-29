// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct SampleBufferPlayerView: UIViewRepresentable {
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

    func makeUIView(context _: Context) -> SampleBufferVideoView {
        context.makeVideoView()
    }

    func updateUIView(_: SampleBufferVideoView, context _: Context) {}

    static func dismantleUIView(
        _ uiView: SampleBufferVideoView,
        coordinator: Coordinator
    ) {
        _ = uiView
        coordinator.context.detach()
    }
}
