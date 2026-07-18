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
    @State private var isSaving = false

    init(model: AppModel, channel: Channel) {
        self.model = model
        self.channel = channel
        _selection = State(initialValue: model.matchedEPGChannelID(for: channel))
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selection = nil
                } label: {
                    mappingLabel(title: "清除手动映射", selected: selection == nil)
                }
                .accessibilityIdentifier("mapping.clear")

                ForEach(model.epgChannels) { epgChannel in
                    Button {
                        selection = epgChannel.id
                    } label: {
                        mappingLabel(
                            title: epgChannel.displayNames.first ?? epgChannel.id,
                            subtitle: epgChannel.id,
                            selected: selection == epgChannel.id
                        )
                    }
                    .accessibilityIdentifier("mapping.\(epgChannel.id)")
                }
            }
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
            await model.saveMapping(channel: channel, xmltvChannelID: selection)
            guard !Task.isCancelled else { return }
            isSaving = false
            dismiss()
        }
    }
}
