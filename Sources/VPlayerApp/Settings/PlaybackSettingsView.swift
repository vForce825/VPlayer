// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct PlaybackSettingsView: View {
    @Bindable var settings: PlaybackSettingsStore

    var body: some View {
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
        HStack {
            Text(title)
            Spacer()
            Button {
                settings.deinterlaceAlgorithm = algorithm
            } label: {
                Image(systemName: settings.deinterlaceAlgorithm == algorithm ? "checkmark.circle.fill" : "circle")
            }
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(settings.deinterlaceAlgorithm == algorithm ? .isSelected : [])
        }
    }
}
