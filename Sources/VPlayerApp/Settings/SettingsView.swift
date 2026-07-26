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
                SettingsSummaryLink(
                    title: "视频缓冲",
                    value: PlaybackBufferRows.videoBufferTitle(playback.videoBufferSeconds),
                    identifier: "settings.buffer.video.current"
                ) {
                    VideoBufferSelectionView(playback: playback)
                }
                SettingsSummaryLink(
                    title: "反交错缓冲",
                    value: DeinterlaceBufferRows.title(playback.deinterlaceBufferFrames),
                    identifier: "settings.buffer.deinterlace.current"
                ) {
                    DeinterlaceBufferSelectionView(playback: playback)
                }
                SettingsSummaryLink(
                    title: "频道排列",
                    value: groupingTitle(channelBrowsing.grouping),
                    identifier: "settings.channels.current"
                ) {
                    ChannelGroupingSelectionView(channelBrowsing: channelBrowsing)
                }
            }
            .navigationTitle("设置")
        }
    }

    private func groupingTitle(_ grouping: ChannelGrouping) -> String {
        switch grouping {
        case .playlistGroups:
            "按播放列表分组（默认）"
        case .playlistOrder:
            "按原始顺序平铺"
        }
    }
}

private struct ChannelGroupingSelectionView: View {
    @Bindable var channelBrowsing: ChannelBrowsingSettingsStore

    var body: some View {
        List {
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
        .navigationTitle("频道排列")
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
