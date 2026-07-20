// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI

struct PlayerControlsOverlay: View {
    enum Control: Hashable { case back, playPause, settings }

    let title: String
    let isPaused: Bool
    let onBack: () -> Void
    let onPlayPause: () -> Void
    let onSettings: () -> Void
    @FocusState private var focusedControl: Control?

    var body: some View {
        VStack {
            HStack {
                Text(title)
                    .font(.title2.bold())
                Spacer()
            }
            Spacer()
            HStack(spacing: 36) {
                Button("返回", systemImage: "chevron.backward", action: onBack)
                    .accessibilityIdentifier("player-back")
                    .focused($focusedControl, equals: .back)
                Button(
                    isPaused ? "播放" : "暂停",
                    systemImage: isPaused ? "play.fill" : "pause.fill",
                    action: onPlayPause
                )
                .accessibilityIdentifier("player-play-pause")
                .focused($focusedControl, equals: .playPause)
                Button("播放设置", systemImage: "gearshape", action: onSettings)
                    .accessibilityIdentifier("player-settings")
                    .focused($focusedControl, equals: .settings)
            }
            .defaultFocus($focusedControl, .playPause)
        }
        .padding(56)
        .task {
            await Task.yield()
            focusedControl = .playPause
        }
    }
}
