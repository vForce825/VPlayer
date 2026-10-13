// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
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
            .navigationTitle("频道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    navigationHeading
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel)
        }
        .sheet(item: $informationChannel) { channel in
            IOSChannelInformationView(model: model, channel: channel)
        }
    }

    private var navigationHeading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("频道")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("channel.title")
            if let profile = model.activeProfile {
                Menu {
                    ForEach(model.profiles) { candidate in
                        Button {
                            guard candidate.id != model.activeProfile?.id else { return }
                            Task { _ = await model.activate(profileID: candidate.id) }
                        } label: {
                            if candidate.id == model.activeProfile?.id {
                                Label(candidate.name, systemImage: "checkmark")
                            } else {
                                Text(candidate.name)
                            }
                        }
                        .accessibilityIdentifier("channel.playlist.\(candidate.id.uuidString)")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(profile.name).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading)
                .accessibilityLabel("当前播放列表")
                .accessibilityValue(profile.name)
                .accessibilityIdentifier("channel.active-playlist")
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
                            .id("channel-section.\(section.id)")
                        }
                    }
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    .toolbar {
                        if presentation.showsGroupRail {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    ForEach(presentation.sections) { section in
                                        Button(section.title ?? ChannelSectionBuilder.ungroupedTitle) {
                                            withAnimation {
                                                proxy.scrollTo("channel-section.\(section.id)", anchor: .top)
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

/// 换台只在用户选定可播放频道后提交请求，浏览、搜索和取消不会停止当前播放。
struct IOSPlayerChannelPickerView: View {
    @Bindable var model: AppModel
    let grouping: ChannelGrouping
    let onSelect: (Channel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectionMessage: String?
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            let presentation = ChannelBrowserPresentation(channels: model.channels,
                searchText: searchText, grouping: grouping)
            List {
                if let selectionMessage {
                    Text(selectionMessage).font(.callout).foregroundStyle(.red)
                        .accessibilityIdentifier("player.channels.message")
                }
                if presentation.sections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
                ForEach(presentation.sections) { section in
                    Section {
                        ForEach(section.channels) { channel in
                            Button { select(channel) } label: {
                                HStack(spacing: 12) {
                                    IOSChannelRow(channel: channel,
                                        programmes: model.programmesByChannelID[channel.id, default: []])
                                    if model.presentedPlaybackRequest?.channelID == channel.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel("正在播放")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.presentedPlaybackRequest?.channelID == channel.id ? .isSelected : [])
                            .accessibilityIdentifier("player.switch.\(channel.attributes["ui-test-id"] ?? channel.id)")
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索频道")
            .navigationTitle("换台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("player.channels.done")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private func select(_ channel: Channel) {
        switch StreamProtocolPolicy.evaluate(channel.streamURL) {
        case .allowed:
            onSelect(channel)
            dismiss()
        case let .rejected(rejection):
            selectionMessage = rejection.userMessage
        }
    }
}
