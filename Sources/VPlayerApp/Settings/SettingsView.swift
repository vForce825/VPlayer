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
                Section("法律") {
                    NavigationLink("隐私政策") {
                        PrivacyStatementView()
                    }
                    .accessibilityIdentifier("settings.privacy")
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

private enum AppLegalInformation {
    static let privacyURL = "https://vplayerdemom3u.vercel.app/privacy.html"
}

private struct PrivacyStatementView: View {
    var body: some View {
        List {
            Section("不收集个人数据") {
                Text("VPlayer 不包含广告、账号系统或分析跟踪功能，开发者不会通过 VPlayer 收集您的播放列表、观看记录或设备信息。")
            }

            Section("本机数据") {
                Text("您添加的播放列表与 EPG 地址、频道资料、播放设置和台标缓存保存在 Apple TV 的应用容器中。卸载 VPlayer 会删除这些本机数据。")
            }

            Section("网络连接") {
                Text("VPlayer 仅为获取您配置的播放列表、EPG、台标和媒体流而连接相应服务器。服务器可能按其自身政策处理 IP 地址和请求信息；这些服务器不由 VPlayer 开发者控制。")
            }

            Section("权限") {
                Text("当播放源位于家庭网络时，VPlayer 会请求本地网络访问权限。")
            }

            Section("在线隐私政策") {
                Text(AppLegalInformation.privacyURL)
                    .accessibilityIdentifier("settings.privacy.url")
            }
        }
        .navigationTitle("隐私政策")
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
