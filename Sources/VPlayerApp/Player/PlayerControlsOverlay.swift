// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI

struct PlayerControlsOverlay: View {
    private enum Control: Hashable {
        case back
        case playPause
        case settings
    }

    let isPaused: Bool
    let onBack: () -> Void
    let onPlayPause: () -> Void
    let onSettings: () -> Void
    let onInteraction: () -> Void
    @FocusState private var focusedControl: Control?
    private let focusPolicy = AcceptanceFocusPolicy.current()

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 36) {
                Button("返回", systemImage: "chevron.backward") {
                    onInteraction()
                    onBack()
                }
                    .accessibilityIdentifier("player-back")
                    .focused($focusedControl, equals: .back)
                Button(
                    isPaused ? "播放" : "暂停",
                    systemImage: isPaused ? "play.fill" : "pause.fill"
                ) {
                    onInteraction()
                    onPlayPause()
                }
                .accessibilityIdentifier("player-play-pause")
                .focused($focusedControl, equals: .playPause)
                Button("播放设置", systemImage: "gearshape") {
                    onInteraction()
                    onSettings()
                }
                    .accessibilityIdentifier("player-settings")
                    .focused($focusedControl, equals: .settings)
            }
        }
        .padding(56)
        .defaultFocus($focusedControl, initialControl)
        .onMoveCommand { _ in onInteraction() }
        .onChange(of: focusedControl) { _, _ in onInteraction() }
        .onChange(of: isPaused) { _, _ in onInteraction() }
        .task {
            await Task.yield()
            focusedControl = initialControl
        }
    }

    private var initialControl: Control {
        switch focusPolicy.initialPlayerControl {
        case .back: .back
        case .playPause: .playPause
        case .settings: .settings
        }
    }
}
