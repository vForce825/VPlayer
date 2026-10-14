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
                PlaybackSettingsSections(playback: playback)
                IOSPlaybackOrientationSettingsSection(playback: playback)
                Picker("频道排列", selection: $channelBrowsing.grouping) {
                    Text("按播放列表分组").tag(ChannelGrouping.playlistGroups)
                    Text("按原始顺序平铺").tag(ChannelGrouping.playlistOrder)
                }
                PlaybackSettingsResetSection(playback: playback)
                Section("隐私") {
                    Text("播放列表、节目单和设置保存在本机。VPlayer 不包含账号、广告或分析跟踪功能。")
                        .font(.footnote)
                    Link("在线隐私政策", destination: URL(string: "https://vplayerdemom3u.vercel.app/privacy.html")!)
                }
            }.navigationTitle("设置")
        }
    }
}

struct IOSPlaybackOrientationSettingsSection: View {
    @Bindable var playback: PlaybackSettingsStore

    var body: some View {
        Section {
            Toggle("强制横屏播放", isOn: $playback.forceLandscapePlayback)
                .accessibilityIdentifier("settings.playback.force-landscape")
        } header: {
            Text("画面方向")
        } footer: {
            Text("开启后自动横屏播放，播放期间保持横向。关闭或退出播放后，恢复随设备方向旋转。")
        }
    }
}
