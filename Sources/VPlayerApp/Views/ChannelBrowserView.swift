// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct ChannelBrowserView: View {
    @Bindable var model: AppModel
    @State private var mappingChannel: Channel?
    @State private var searchText = ""
    @FocusState private var focusedChannelID: String?
    private let focusPolicy = AcceptanceFocusPolicy.current()

    /// Tiles fill the whole canvas: adaptive sizing yields five logo-led
    /// columns on a 1080p screen and still degrades gracefully under larger
    /// dynamic type.
    private static let gridColumns = [
        GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 40)
    ]

    var body: some View {
        Group {
            switch contentState {
            case .loading:
                ProgressView("正在读取频道…")
                    .accessibilityIdentifier("channel.loading")
            case .noSource:
                ContentUnavailableView(
                    "还没有播放列表",
                    systemImage: "play.square.stack",
                    description: Text("请前往“播放列表”添加 M3U 和 EPG 地址。")
                )
            case .noChannels:
                ContentUnavailableView(
                    "没有频道",
                    systemImage: "tv.slash",
                    description: Text("请在“播放列表”中刷新频道列表。")
                )
            case .channels:
                // Search is only reachable alongside an actual channel list;
                // the loading and empty states above stay chrome-free. Default
                // focus is pinned to the first channel so entering the tab
                // lands on content rather than the search keyboard.
                channelGrid
                    .searchable(text: $searchText, prompt: "搜索频道")
                    .defaultFocus($focusedChannelID, defaultFocusChannelID)
            }
        }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel)
        }
    }

    private var defaultFocusChannelID: String? {
        guard !focusPolicy.isEnabled || focusPolicy.focusesFirstChannel else {
            return nil
        }
        return filteredChannels.first?.id
    }

    private var contentState: ChannelBrowserContentState {
        ChannelBrowserContentState.resolve(
            isLoading: model.isLoading,
            hasActiveProfile: model.activeProfile != nil,
            hasChannels: !model.channels.isEmpty
        )
    }

    @ViewBuilder
    private var channelGrid: some View {
        if groups.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            groupedChannelGrid
        }
    }

    private var groupedChannelGrid: some View {
        ScrollView {
            LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 40) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.channels) { channel in
                            channelCard(for: channel)
                        }
                    } header: {
                        groupHeader(for: group)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    private func channelCard(for channel: Channel) -> some View {
        Button {
            model.select(channel: channel)
        } label: {
            ChannelCard(
                channel: channel,
                programmes: model.programmesByChannelID[channel.id, default: []]
            )
        }
        .buttonStyle(.card)
        .accessibilityIdentifier(channelIdentifier(channel))
        .focused($focusedChannelID, equals: channel.id)
        .contextMenu {
            Button("设置 EPG") {
                mappingChannel = channel
            }
            .accessibilityIdentifier("channel.mapping.\(channel.id)")
        }
    }

    private func groupHeader(for group: ChannelGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(group.title)
                .font(.title3.weight(.semibold))
            Text("\(group.channels.count) 个频道")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }

    private var groups: [ChannelGroup] {
        // model.channels is already sorted by (order, id) in AppModel.apply, so
        // group in a single O(n) pass with a title→index map instead of the
        // previous re-sort plus O(groups) firstIndex scan per channel.
        var indexByTitle: [String: Int] = [:]
        var result: [ChannelGroup] = []
        for channel in filteredChannels {
            let title = channel.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "其他"
            if let index = indexByTitle[resolvedTitle] {
                result[index].channels.append(channel)
            } else {
                indexByTitle[resolvedTitle] = result.count
                result.append(ChannelGroup(title: resolvedTitle, channels: [channel]))
            }
        }
        return result
    }

    /// Channels narrowed by the search field. Large IPTV playlists are not
    /// navigable by scrolling alone, so name, group, and tvg-name all match.
    private var filteredChannels: [Channel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.channels }
        return model.channels.filter { channel in
            channel.displayName.localizedCaseInsensitiveContains(query)
                || channel.groupTitle?.localizedCaseInsensitiveContains(query) == true
                || channel.tvgName?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func channelIdentifier(_ channel: Channel) -> String {
        channel.attributes["ui-test-id"] ?? "channel.\(channel.id)"
    }
}

enum ChannelBrowserContentState: Equatable {
    case loading
    case noSource
    case noChannels
    case channels

    static func resolve(
        isLoading: Bool,
        hasActiveProfile: Bool,
        hasChannels: Bool
    ) -> Self {
        if isLoading { return .loading }
        if !hasActiveProfile { return .noSource }
        if !hasChannels { return .noChannels }
        return .channels
    }
}

private struct ChannelGroup: Identifiable {
    let title: String
    var channels: [Channel]
    var id: String { title }
}
