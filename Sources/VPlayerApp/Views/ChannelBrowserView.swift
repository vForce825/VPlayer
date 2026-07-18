// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct ChannelBrowserView: View {
    @Bindable var model: AppModel
    @State private var mappingChannel: Channel?
    @Namespace private var channelFocus

    var body: some View {
        Group {
            if model.isLoading && model.profiles.isEmpty {
                ProgressView("正在读取频道…")
            } else if model.activeProfile == nil {
                ContentUnavailableView(
                    "还没有数据源",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("请前往“数据源”添加 M3U 和 EPG 地址。")
                )
            } else if model.channels.isEmpty {
                ContentUnavailableView(
                    "没有频道",
                    systemImage: "tv.slash",
                    description: Text("请在“数据源”中刷新播放列表。")
                )
            } else {
                channelList
            }
        }
        .sheet(item: $mappingChannel) { channel in
            ChannelEPGMappingView(model: model, channel: channel)
        }
    }

    private var channelList: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.channels) { channel in
                        Button {
                            model.select(channel: channel)
                        } label: {
                            ChannelRow(
                                channel: channel,
                                programmes: model.programmesByChannelID[channel.id, default: []]
                            )
                        }
                        .buttonStyle(.card)
                        .accessibilityIdentifier(channelIdentifier(channel))
                        .prefersDefaultFocus(channel.id == model.channels.first?.id, in: channelFocus)
                        .contextMenu {
                            Button("设置 EPG") {
                                mappingChannel = channel
                            }
                            .accessibilityIdentifier("channel.mapping.\(channel.id)")
                        }
                    }
                }
            }
        }
        .focusScope(channelFocus)
    }

    private var groups: [ChannelGroup] {
        var result: [ChannelGroup] = []
        for channel in model.channels.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }) {
            let title = channel.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "其他"
            if let index = result.firstIndex(where: { $0.title == resolvedTitle }) {
                result[index].channels.append(channel)
            } else {
                result.append(ChannelGroup(title: resolvedTitle, channels: [channel]))
            }
        }
        return result
    }

    private func channelIdentifier(_ channel: Channel) -> String {
        channel.attributes["ui-test-id"] ?? "channel.\(channel.id)"
    }
}

private struct ChannelGroup: Identifiable {
    let title: String
    var channels: [Channel]
    var id: String { title }
}
