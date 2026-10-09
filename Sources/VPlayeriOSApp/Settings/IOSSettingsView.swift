// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct IOSSettingsView: View {
    @Bindable var playback: PlaybackSettingsStore
    @Bindable var channelBrowsing: ChannelBrowsingSettingsStore
    var body: some View {
        NavigationStack {
            List {
                SettingsSummaryLink(title: "视频缓冲",
                    value: PlaybackBufferRows.videoBufferTitle(playback.videoBufferSeconds),
                    identifier: "settings.buffer.video.current") { VideoBufferSelectionView(playback: playback) }
                SettingsSummaryLink(title: "反交错缓冲",
                    value: DeinterlaceBufferRows.title(playback.deinterlaceBufferFrames),
                    identifier: "settings.buffer.deinterlace.current") { DeinterlaceBufferSelectionView(playback: playback) }
                Picker("频道排列", selection: $channelBrowsing.grouping) {
                    Text("按播放列表分组").tag(ChannelGrouping.playlistGroups)
                    Text("按原始顺序平铺").tag(ChannelGrouping.playlistOrder)
                }
                Section("隐私") {
                    Text("播放列表、节目单和设置保存在本机。VPlayer 不包含账号、广告或分析跟踪功能。")
                        .font(.footnote)
                    Link("在线隐私政策", destination: URL(string: "https://vplayerdemom3u.vercel.app/privacy.html")!)
                }
            }.navigationTitle("设置")
        }
    }
}
