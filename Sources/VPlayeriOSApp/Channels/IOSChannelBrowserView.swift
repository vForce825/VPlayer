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
    @State private var informationChannel: Channel?

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
            .safeAreaInset(edge: .top, spacing: 0) {
                if let profile = model.activeProfile {
                    HStack(spacing: 10) {
                        Image(systemName: "play.square.stack")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前播放列表").font(.caption).foregroundStyle(.secondary)
                            Text(profile.name)
                                .font(.subheadline.weight(.semibold))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("channel.active-playlist")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar, ignoresSafeAreaEdges: [])
                }
            }
            .navigationTitle("频道")
        }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel)
        }
        .sheet(item: $informationChannel) { channel in
            IOSChannelInformationView(model: model, channel: channel)
        }
    }

    private var channelList: some View {
        let presentation = ChannelBrowserPresentation(channels: model.channels,
            searchText: searchText, grouping: browsingSettings.grouping)
        return ScrollViewReader { proxy in
            Group {
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
                                    channelRow(for: channel)
                                        .id(channel.id)
                                }
                            } header: {
                                if let title = section.title { Text(title) }
                            }
                        }
                    }
                    .toolbar {
                        if presentation.showsGroupRail {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    ForEach(presentation.sections) { section in
                                        Button(section.title ?? ChannelSectionBuilder.ungroupedTitle) {
                                            guard let firstChannelID = section.channels.first?.id else { return }
                                            withAnimation {
                                                proxy.scrollTo(firstChannelID, anchor: .top)
                                            }
                                        }
                                        .accessibilityIdentifier("channel.group.\(section.id)")
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "list.bullet")
                                        Text("分组")
                                    }
                                }
                                .accessibilityLabel("选择频道分组")
                                .accessibilityIdentifier("channel.groups")
                            }
                        }
                    }
                }
            }
        }
    }

    private func channelRow(for channel: Channel) -> some View {
        let identifier = channel.attributes["ui-test-id"] ?? "channel.\(channel.id)"
        return HStack(spacing: 8) {
            Button {
                #if DEBUG
                IOSPlaybackRouteDiagnostics.record("tap:loading=\(model.isLoading):profile=\(model.activeProfile?.id == channel.sourceProfileID):channel=\(model.channels.contains { $0.id == channel.id && $0.sourceProfileID == channel.sourceProfileID })")
                #endif
                model.select(channel: channel)
                #if DEBUG
                IOSPlaybackRouteDiagnostics.record("selected:request=\(model.presentedPlaybackRequest != nil):alert=\(model.alertMessage != nil)")
                #endif
            } label: {
                IOSChannelRow(channel: channel,
                    programmes: model.programmesByChannelID[channel.id, default: []])
            }
            .accessibilityIdentifier(identifier)
            .contextMenu {
                Button("设置 EPG") { mappingChannel = channel }
            }
            Button { informationChannel = channel } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("查看\(channel.displayName)的信息")
            .accessibilityIdentifier("channel.info.\(identifier)")
        }
        // List 的默认按钮样式会共享整行点击行为，显式样式确保两个入口各自响应。
        .buttonStyle(.plain)
    }
}
