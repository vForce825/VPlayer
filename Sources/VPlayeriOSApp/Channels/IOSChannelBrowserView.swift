// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct IOSChannelBrowserView: View {
    @Bindable var model: AppModel
    @Bindable var browsingSettings: ChannelBrowsingSettingsStore
    @State private var searchText = ""
    @State private var mappingChannel: Channel?

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("正在读取频道…")
                } else if model.activeProfile == nil {
                    ContentUnavailableView("还没有播放列表", systemImage: "play.square.stack",
                        description: Text("请前往“播放列表”添加 M3U 和 EPG 地址。"))
                } else if model.channels.isEmpty {
                    ContentUnavailableView("没有频道", systemImage: "tv.slash",
                        description: Text("请在“播放列表”中刷新频道列表。"))
                } else {
                    channelList
                        .searchable(text: $searchText, prompt: "搜索频道")
                }
            }
            .navigationTitle("频道")
        }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel)
        }
    }

    private var channelList: some View {
        let presentation = ChannelBrowserPresentation(channels: model.channels,
            searchText: searchText, grouping: browsingSettings.grouping)
        return Group {
            if presentation.sections.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    if let end = model.staleEPGCoverageEnd {
                        Text(EPGCoverageNotice.text(staleCoverageEnd: end))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(presentation.sections) { section in
                        Section {
                            ForEach(section.channels) { channel in
                                Button { model.select(channel: channel) } label: {
                                    IOSChannelRow(channel: channel,
                                        programmes: model.programmesByChannelID[channel.id, default: []])
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(channel.attributes["ui-test-id"] ?? "channel.\(channel.id)")
                                .contextMenu {
                                    Button("设置 EPG") { mappingChannel = channel }
                                }
                            }
                        } header: {
                            if let title = section.title { Text(title) }
                        }
                    }
                }
            }
        }
    }
}
