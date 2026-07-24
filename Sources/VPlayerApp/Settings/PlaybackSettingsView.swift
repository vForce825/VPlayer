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
            .navigationTitle("设置")
        }
    }

    private func algorithmRow(
        title: String,
        algorithm: DeinterlaceAlgorithm,
        identifier: String
    ) -> some View {
        Button {
            settings.deinterlaceAlgorithm = algorithm
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: settings.deinterlaceAlgorithm == algorithm ? "checkmark.circle.fill" : "circle")
            }
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(settings.deinterlaceAlgorithm == algorithm ? .isSelected : [])
        .prefersDefaultFocus(
            focusPolicy.settingsControl(for: settings.deinterlaceAlgorithm) == algorithm,
            in: settingsFocus
        )
    }
}
