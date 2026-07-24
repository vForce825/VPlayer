// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

@MainActor
final class PlaybackAlgorithmSelectionController {
    private let engine: any PlaybackEngine
    private var task: Task<Void, Never>?

    init(engine: any PlaybackEngine) {
        self.engine = engine
    }

    func select(_ algorithm: DeinterlaceAlgorithm) {
        let predecessor = task
        let engine = engine
        task = Task {
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await engine.setDeinterlaceAlgorithm(algorithm)
        }
    }
}

/// The algorithm rows themselves, shared by the settings tab and the sheet the
/// player raises mid-playback so both switch algorithms identically.
struct DeinterlaceAlgorithmRows: View {
    @Bindable var playback: PlaybackSettingsStore
    let focusNamespace: Namespace.ID
    private let focusPolicy = AcceptanceFocusPolicy.current()

    var body: some View {
        algorithmRow(
            title: "Apple Temporal（默认）",
            algorithm: .appleTemporal,
            identifier: "settings.deinterlace.apple"
        )
        algorithmRow(
            title: "Metal YADIF 2x",
            algorithm: .metalYADIF2x,
            identifier: "settings.deinterlace.yadif"
        )
    }

    private func algorithmRow(
        title: String,
        algorithm: DeinterlaceAlgorithm,
        identifier: String
    ) -> some View {
        Button {
            playback.deinterlaceAlgorithm = algorithm
        } label: {
            SettingsSelectionLabel(
                title: title,
                isSelected: playback.deinterlaceAlgorithm == algorithm
            )
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(playback.deinterlaceAlgorithm == algorithm ? .isSelected : [])
        .prefersDefaultFocus(
            focusPolicy.settingsControl(for: playback.deinterlaceAlgorithm) == algorithm,
            in: focusNamespace
        )
    }
}

struct SettingsSelectionLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        }
    }
}

/// Raised over playback, where only the picture settings make sense — channel
/// browsing preferences belong to the settings tab, not to a running stream.
struct PlaybackSettingsView: View {
    @Bindable var settings: PlaybackSettingsStore
    @Namespace private var settingsFocus
    private let focusPolicy = AcceptanceFocusPolicy.current()

    init(settings: PlaybackSettingsStore) {
        self.settings = settings
    }

    var body: some View {
        Group {
            if focusPolicy.isEnabled {
                content
                    .focusScope(settingsFocus)
            } else {
                content
            }
        }
    }

    private var content: some View {
        NavigationStack {
            List {
                DeinterlaceAlgorithmRows(playback: settings, focusNamespace: settingsFocus)
            }
            .navigationTitle("设置")
        }
    }
}
