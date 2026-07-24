// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct ChannelBrowserView: View {
    @Bindable var model: AppModel
    @Bindable var browsingSettings: ChannelBrowsingSettingsStore
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
        if sections.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            sectionedChannelGrid
        }
    }

    private var sectionedChannelGrid: some View {
        // The rail is a pinned header rather than a sibling above the scroll
        // view: the search field swallows any focus move out of the top of the
        // content, so a rail outside the scroll view is unreachable by remote.
        // Pinned, it both stays on screen and sits in the focus path.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if let staleCoverageEnd = model.staleEPGCoverageEnd {
                            staleEPGBanner(coverageEnd: staleCoverageEnd)
                                .padding(.top, 16)
                        }
                        LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 40) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.channels) { channel in
                                        channelCard(for: channel)
                                    }
                                } header: {
                                    sectionHeader(for: section)
                                }
                            }
                        }
                        .padding(.vertical, 24)
                    } header: {
                        if showsGroupRail {
                            groupRail(proxy: proxy)
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// Group jumps for playlists too long to reach by scrolling. Selecting a
    /// group both scrolls its header to the top — which also realizes the lazy
    /// rows — and hands focus to its first channel, so the remote ends up in
    /// the group rather than merely pointing at it.
    private func groupRail(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(sections) { section in
                    Button(section.title ?? "") {
                        proxy.scrollTo(section.id, anchor: .top)
                        focusedChannelID = section.channels.first?.id
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("channel.group.\(section.id)")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
        }
        // Opaque enough that pinned chips never blur into the tiles scrolling
        // underneath them.
        .background(.regularMaterial)
        .scrollClipDisabled()
        // One focus section keeps the rail a single up/down stop rather than a
        // row the remote has to traverse chip by chip on its way to the grid.
        .focusSection()
    }

    private var showsGroupRail: Bool {
        browsingSettings.grouping == .playlistGroups && sections.count > 1
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

    /// Explains a grid full of "暂无当前节目": the EPG imported, but every
    /// programme in it already ended. Never focusable — it is a note, not a
    /// control standing between the remote and the channels.
    private func staleEPGBanner(coverageEnd: Date) -> some View {
        Label(
            EPGCoverageNotice.text(staleCoverageEnd: coverageEnd),
            systemImage: "calendar.badge.exclamationmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .accessibilityIdentifier("channel.epg.stale")
        .focusable(false)
    }

    @ViewBuilder
    private func sectionHeader(for section: ChannelSection) -> some View {
        if let title = section.title {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text("\(section.channels.count) 个频道")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .id(section.id)
        }
    }

    private var sections: [ChannelSection] {
        ChannelSectionBuilder.sections(
            channels: filteredChannels,
            grouping: browsingSettings.grouping
        )
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
