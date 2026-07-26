// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

/// The settings tab: picture settings plus the preferences that shape the
/// channel browser.
struct SettingsView: View {
    @Bindable var playback: PlaybackSettingsStore
    @Bindable var channelBrowsing: ChannelBrowsingSettingsStore

    init(playback: PlaybackSettingsStore, channelBrowsing: ChannelBrowsingSettingsStore) {
        self.playback = playback
        self.channelBrowsing = channelBrowsing
    }

    var body: some View {
        NavigationStack {
            List {
                Section("视频缓冲") {
                    PlaybackBufferRows(playback: playback)
                }
                Section("反交错缓冲") {
                    DeinterlaceBufferRows(playback: playback)
                }
                Section("频道排列") {
                    groupingRow(
                        title: "按播放列表分组（默认）",
                        grouping: .playlistGroups,
                        identifier: "settings.channels.grouped"
                    )
                    groupingRow(
                        title: "按原始顺序平铺",
                        grouping: .playlistOrder,
                        identifier: "settings.channels.flat"
                    )
                }
            }
            .navigationTitle("设置")
        }
    }

    private func groupingRow(
        title: String,
        grouping: ChannelGrouping,
        identifier: String
    ) -> some View {
        Button {
            channelBrowsing.grouping = grouping
        } label: {
            SettingsSelectionLabel(
                title: title,
                isSelected: channelBrowsing.grouping == grouping
            )
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(channelBrowsing.grouping == grouping ? .isSelected : [])
    }
}
