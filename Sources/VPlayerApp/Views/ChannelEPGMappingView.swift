// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct ChannelEPGMappingView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let channel: Channel

    @State private var selection: String?
    @State private var searchText = ""
    @State private var isSaving = false

    init(model: AppModel, channel: Channel) {
        self.model = model
        self.channel = channel
        // Preselect only an existing manual override — not the automatic match.
        // Preselecting the auto-match meant a plain "save" would freeze today's
        // guess into a permanent manual mapping, defeating future auto-matching.
        _selection = State(initialValue: model.manualEPGChannelID(for: channel))
    }

    var body: some View {
        NavigationStack {
            List {
                if model.manualEPGChannelID(for: channel) != nil {
                    Button {
                        selection = nil
                    } label: {
                        mappingLabel(title: "清除手动映射", selected: selection == nil)
                    }
                    .accessibilityIdentifier("mapping.clear")
                }

                if model.epgChannels.isEmpty {
                    ContentUnavailableView(
                        "没有可用的 EPG 频道",
                        systemImage: "list.bullet.rectangle",
                        description: Text("请先刷新当前播放列表的 EPG。")
                    )
                    .accessibilityIdentifier("mapping.empty")
                } else if filteredEPGChannels.isEmpty {
                    ContentUnavailableView(
                        "没有匹配的频道",
                        systemImage: "magnifyingglass",
                        description: Text("试试其他关键字。")
                    )
                    .accessibilityIdentifier("mapping.no-results")
                } else {
                    ForEach(filteredEPGChannels) { epgChannel in
                        Button {
                            selection = epgChannel.id
                        } label: {
                            mappingLabel(
                                title: epgChannel.displayNames.first ?? epgChannel.id,
                                subtitle: subtitle(for: epgChannel),
                                selected: selection == epgChannel.id
                            )
                        }
                        .accessibilityIdentifier("mapping.\(epgChannel.id)")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索 EPG 频道")
            .navigationTitle("为“\(channel.displayName)”设置 EPG")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("mapping.save")
                }
            }
        }
    }

    private var filteredEPGChannels: [EPGChannel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.epgChannels }
        return model.epgChannels.filter { epgChannel in
            epgChannel.id.lowercased().contains(query)
                || epgChannel.displayNames.contains { $0.lowercased().contains(query) }
        }
    }

    private func subtitle(for epgChannel: EPGChannel) -> String {
        // Surface the effective match so the user can see today's automatic
        // guess without it being silently persisted as a manual override.
        if model.manualEPGChannelID(for: channel) == nil,
           model.matchedEPGChannelID(for: channel) == epgChannel.id {
            return "\(epgChannel.id) · 自动匹配"
        }
        return epgChannel.id
    }

    private func mappingLabel(
        title: String,
        subtitle: String? = nil,
        selected: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .accessibilityLabel("当前映射")
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let succeeded = await model.saveMapping(
                channel: channel,
                xmltvChannelID: selection
            )
            guard !Task.isCancelled else { return }
            isSaving = false
            if succeeded {
                dismiss()
            }
        }
    }
}
