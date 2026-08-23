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
    @State private var pendingGroupFocusID: String?
    @FocusState private var focusedElement: ChannelBrowserFocus?
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
                let presentation = ChannelBrowserPresentation(
                    channels: model.channels,
                    searchText: searchText,
                    grouping: browsingSettings.grouping
                )
                let defaultFocusElement = defaultFocusElement(
                    for: presentation.sections,
                    defaultFocusChannelID: presentation.defaultFocusChannelID
                )
                channelGrid(
                    sections: presentation.sections,
                    showsGroupRail: presentation.showsGroupRail
                )
                    .searchable(text: $searchText, prompt: "搜索频道")
                    .defaultFocus($focusedElement, defaultFocusElement)
            }
        }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel)
        }
    }

    private func defaultFocusElement(
        for sections: [ChannelSection],
        defaultFocusChannelID: String?
    ) -> ChannelBrowserFocus? {
        guard !focusPolicy.isEnabled || focusPolicy.focusesFirstChannel else {
            return nil
        }
        guard let firstChannelID = sections.first?.channels.first?.id,
              firstChannelID == defaultFocusChannelID else {
            return nil
        }
        return .channel(firstChannelID)
    }

    private var contentState: ChannelBrowserContentState {
        ChannelBrowserContentState.resolve(
            isLoading: model.isLoading,
            hasActiveProfile: model.activeProfile != nil,
            hasChannels: !model.channels.isEmpty
        )
    }

    @ViewBuilder
    private func channelGrid(
        sections: [ChannelSection],
        showsGroupRail: Bool
    ) -> some View {
        if sections.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            sectionedChannelGrid(sections: sections, showsGroupRail: showsGroupRail)
        }
    }

    private func sectionedChannelGrid(
        sections: [ChannelSection],
        showsGroupRail: Bool
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The group rail is ordinary scroll content: it is visible
                    // at the top of the browser and leaves the screen with the
                    // channel rows instead of occupying a permanent viewport.
                    if showsGroupRail {
                        groupRail(proxy: proxy, sections: sections)
                    }
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
                }
            }
            .scrollClipDisabled()
        }
    }

    /// Group jumps for playlists too long to reach by scrolling. Selecting a
    /// group both scrolls its header to the top — which also realizes the lazy
    /// rows — and hands focus to its first channel, so the remote ends up in
    /// the group rather than merely pointing at it.
    private func groupRail(
        proxy: ScrollViewProxy,
        sections: [ChannelSection]
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(sections) { section in
                    Button(section.title ?? "") {
                        guard let channelID = section.channels.first?.id else { return }
                        pendingGroupFocusID = channelID
                        focusedElement = nil
                        proxy.scrollTo(sectionScrollID(for: section), anchor: .top)
                        // A distant lazy section is realized by `scrollTo` on
                        // the following layout pass. Move focus after that pass
                        // and ignore stale jumps if another chip is selected.
                        Task { @MainActor in
                            await Task.yield()
                            guard pendingGroupFocusID == channelID else { return }
                            focusedElement = .channel(channelID)
                            pendingGroupFocusID = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("channel.group.\(section.id)")
                    .focused($focusedElement, equals: .group(section.id))
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
        }
        .background(.regularMaterial)
        .scrollClipDisabled()
        // One focus section keeps the rail a single up/down stop rather than a
        // row the remote has to traverse chip by chip on its way to the grid.
        .focusSection()
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
        .focused($focusedElement, equals: .channel(channel.id))
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
        VStack(alignment: .leading, spacing: 8) {
            Label(
                EPGCoverageNotice.text(staleCoverageEnd: coverageEnd),
                systemImage: "calendar.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if model.activeProfile?.m3uStatus.state == .refreshing {
                Label("正在刷新频道列表…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("channel.playlist.refreshing")
            }

            if model.activeProfile?.epgStatus.state == .refreshing {
                Label("正在刷新节目单…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("channel.epg.refreshing")
            }
        }
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
            .id(sectionScrollID(for: section))
        }
    }

    private func sectionScrollID(for section: ChannelSection) -> String {
        "channel.section.\(section.id)"
    }

    private func channelIdentifier(_ channel: Channel) -> String {
        channel.attributes["ui-test-id"] ?? "channel.\(channel.id)"
    }
}

private enum ChannelBrowserFocus: Hashable {
    case channel(String)
    case group(String)
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
