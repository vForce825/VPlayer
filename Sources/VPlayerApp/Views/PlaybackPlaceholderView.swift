// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct PlaybackPlaceholderView: View {
    let request: PlaybackRequest
    let onDismiss: () -> Void
    @FocusState private var isBackFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 88))
                Text(request.title)
                    .font(.largeTitle.bold())
                Text("播放器将在后续版本连接")
                    .foregroundStyle(.secondary)
                Button("返回") {
                    onDismiss()
                }
                .focused($isBackFocused)
                .accessibilityIdentifier("playback.back")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.placeholder")
        .onAppear {
            isBackFocused = true
        }
        .onExitCommand(perform: onDismiss)
    }
}
