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

                    NavigationLink("开源许可") {
                        OpenSourceNoticesView()
                    }
                    .accessibilityIdentifier("settings.open-source")
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
    static let sourceURL = URL(string: "https://github.com/vForce825/VPlayer")!
    static let privacyURL = URL(
        string: "https://vplayerdemom3u.vercel.app/privacy.html"
    )!
    static let licenseURL = URL(
        string: "https://github.com/vForce825/VPlayer/blob/main/LICENSE"
    )!
    static let appStoreExceptionURL = URL(
        string: "https://github.com/vForce825/VPlayer/blob/main/LICENSE.APPSTORE-EXCEPTION"
    )!
    static let thirdPartyNoticesURL = URL(
        string: "https://github.com/vForce825/VPlayer/blob/main/THIRD_PARTY_NOTICES"
    )!
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

            Link("查看完整在线隐私政策", destination: AppLegalInformation.privacyURL)
        }
        .navigationTitle("隐私政策")
    }
}

private struct OpenSourceNoticesView: View {
    var body: some View {
        List {
            Section("VPlayer") {
                Text("Copyright © 2026 VPlayer contributors")
                Text("VPlayer 是自由软件，按 GNU GPL 第 3 版（仅该版本）授权。通过 Apple App Store 分发同时受项目的 App Store 分发例外条款约束。本软件不提供任何担保。")
                Link("GNU GPLv3 许可全文", destination: AppLegalInformation.licenseURL)
                Link("App Store 分发例外", destination: AppLegalInformation.appStoreExceptionURL)
                Link("VPlayer 源代码", destination: AppLegalInformation.sourceURL)
            }

            Section("FFmpeg") {
                Text("本产品使用 FFmpeg 8.1.2 的 libavcodec、libavformat、libavutil 和 libswresample，按 GNU LGPL 2.1 或更高版本授权。")
                Text("This software is based in part on the work of the Independent JPEG Group.")
                Link("第三方软件声明", destination: AppLegalInformation.thirdPartyNoticesURL)
            }
        }
        .navigationTitle("开源许可")
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
