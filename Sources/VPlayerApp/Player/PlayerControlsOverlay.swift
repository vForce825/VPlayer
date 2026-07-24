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

    let title: String
    let isPaused: Bool
    let onBack: () -> Void
    let onPlayPause: () -> Void
    let onSettings: () -> Void
    @FocusState private var focusedControl: Control?
    @State private var isVisible = true
    @State private var hideTask: Task<Void, Never>?
    private let focusPolicy = AcceptanceFocusPolicy.current()

    // Controls fade out after this much inactivity so a permanent overlay never
    // sits on a live channel (which also risks burn-in on OLED panels). Any
    // remote navigation, or entering the paused state, brings them back.
    private static let autoHideDelay: Duration = .seconds(5)

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
        }
        .padding(56)
        .opacity(controlsShown ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: controlsShown)
        .defaultFocus($focusedControl, initialControl)
        .onMoveCommand { _ in reveal() }
        .onChange(of: focusedControl) { _, _ in reveal() }
        .onChange(of: isPaused) { _, _ in reveal() }
        .task {
            await Task.yield()
            focusedControl = initialControl
            reveal()
        }
        .onDisappear { hideTask?.cancel() }
    }

    // Paused playback keeps the controls pinned; otherwise they follow the
    // auto-hide timer so the live picture is unobstructed.
    private var controlsShown: Bool {
        isVisible || isPaused
    }

    private func reveal() {
        isVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !isPaused else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.autoHideDelay)
            guard !Task.isCancelled else { return }
            isVisible = false
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
