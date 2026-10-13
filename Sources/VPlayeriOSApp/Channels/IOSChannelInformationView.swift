// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
import VPlayerCore

struct IOSChannelInformationView: View {
    @Bindable var model: AppModel
    let channel: Channel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResourceUsage
    @State private var showsMapping = false
    @State private var copiedStreamURL = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: reducedResourceUsage ? 120 : 30)) { tick in
                let programmes = model.programmesByChannelID[channel.id, default: []]
                let presentation = ChannelProgrammePresentation.resolve(programmes: programmes, at: tick.date)
                let upcoming = programmes.filter { $0.start >= tick.date && $0.stop > $0.start }
                List {
                    basicInformation
                    epgInformation
                    Section("当前节目") {
                        if let current = presentation.current {
                            programmeRow(current)
                            if let progress = presentation.progress {
                                ProgressView(value: progress)
                                    .accessibilityLabel("当前节目进度")
                            }
                        } else {
                            Text("暂无当前节目").foregroundStyle(.secondary)
                        }
                    }
                    Section("后续节目") {
                        if upcoming.isEmpty {
                            Text("暂无后续节目").foregroundStyle(.secondary)
                        } else {
                            ForEach(upcoming) { programme in programmeRow(programme) }
                        }
                    }
                }
            }
            .navigationTitle("频道信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("channel.info.done")
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showsMapping) {
            ChannelEPGMappingView(model: model, channel: channel)
        }
    }

    private var basicInformation: some View {
        Section("基础信息") {
            LabeledContent("频道名称") {
                Text(channel.displayName).textSelection(.enabled)
                    .accessibilityIdentifier("channel.info.name")
            }
            if let profile = model.profiles.first(where: { $0.id == channel.sourceProfileID }) {
                LabeledContent("播放列表", value: profile.name)
            }
            let groupTitle = channel.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            LabeledContent("频道分组", value: groupTitle.isEmpty ? ChannelSectionBuilder.ungroupedTitle : groupTitle)
            VStack(alignment: .leading, spacing: 8) {
                Text("播放链接").font(.subheadline).foregroundStyle(.secondary)
                Text(channel.streamURL.absoluteString)
                    .font(.callout)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("channel.info.stream-url")
                Button {
                    UIPasteboard.general.string = channel.streamURL.absoluteString
                    copiedStreamURL = true
                } label: {
                    Label(copiedStreamURL ? "已复制播放链接" : "复制播放链接", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("channel.info.copy")
            }
            .padding(.vertical, 4)
        }
    }

    private var epgInformation: some View {
        Section("EPG 信息") {
            if let id = model.matchedEPGChannelID(for: channel) {
                if let epgChannel = model.epgChannels.first(where: { $0.id == id }),
                   let name = epgChannel.displayNames.first {
                    LabeledContent("EPG 频道", value: name)
                }
                LabeledContent("EPG 频道 ID", value: id).textSelection(.enabled)
                LabeledContent("匹配方式", value: model.manualEPGChannelID(for: channel) == id ? "手动映射" : "自动匹配")
            } else {
                Text("尚未匹配 EPG 频道").foregroundStyle(.secondary)
            }
            if let id = channel.tvgID, !id.isEmpty {
                LabeledContent("列表中的 EPG ID", value: id).textSelection(.enabled)
            }
            if let name = channel.tvgName, !name.isEmpty {
                LabeledContent("列表中的 EPG 名称", value: name)
            }
            Button("设置 EPG") { showsMapping = true }
                .accessibilityIdentifier("channel.info.mapping")
        }
    }

    private func programmeRow(_ programme: Programme) -> some View {
        IOSProgrammeRow(programme: programme)
    }
}

struct IOSProgrammeGuideView: View {
    let presentation: PlayerChannelPresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResourceUsage
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: reducedResourceUsage ? 120 : 30)) { tick in
                let programme = ChannelProgrammePresentation.resolve(programmes: presentation.programmes, at: tick.date)
                let upcoming = presentation.programmes.filter { $0.start >= tick.date && $0.stop > $0.start }
                List {
                    Section {
                        Text(presentation.request.title).font(.headline)
                    }
                    Section("当前节目") {
                        if let current = programme.current {
                            IOSProgrammeRow(programme: current)
                            if let progress = programme.progress {
                                ProgressView(value: progress).accessibilityLabel("节目播出进度")
                            }
                        } else {
                            Text("暂无当前节目").foregroundStyle(.secondary)
                        }
                    }
                    Section("后续节目") {
                        if upcoming.isEmpty {
                            Text("暂无后续节目").foregroundStyle(.secondary)
                        } else {
                            ForEach(upcoming) { IOSProgrammeRow(programme: $0) }
                        }
                    }
                    if presentation.programmes.isEmpty {
                        Section {
                            Text("暂时没有可用的节目单，可在“播放列表”中刷新节目单。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("节目单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("player.programmes.done")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }
}

private struct IOSProgrammeRow: View {
    let programme: Programme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(programme.title).font(.headline)
            Text("\(programme.start.formatted(date: .abbreviated, time: .shortened)) – \(programme.stop.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if let subtitle = programme.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.subheadline)
            }
            if let summary = programme.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
