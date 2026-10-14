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
                List {
                    basicInformation
                    epgInformation
                    IOSProgrammeSections(guide: IOSProgrammeGuidePresentation(programmes: programmes, at: tick.date))
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

}

struct IOSProgrammeGuideView: View {
    let presentation: PlayerChannelPresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResourceUsage
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: reducedResourceUsage ? 120 : 30)) { tick in
                List {
                    Section {
                        Text(presentation.request.title).font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
                    }
                    IOSProgrammeSections(guide: IOSProgrammeGuidePresentation(
                        programmes: presentation.programmes, at: tick.date))
                    if presentation.programmes.isEmpty {
                        Section {
                            Text("暂时没有可用的节目单，可在“播放列表”中刷新节目单。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .listSectionSpacing(.compact)
                .contentMargins(.top, 12, for: .scrollContent)
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

private struct IOSProgrammeSections: View {
    let guide: IOSProgrammeGuidePresentation

    var body: some View {
        if !guide.hasCurrent {
            Section { Text("暂无当前节目").foregroundStyle(.secondary) }
        }
        ForEach(guide.days) { day in
            Section(day.title) {
                ForEach(day.rows) { row in
                    IOSProgrammeRow(row: row)
                        .listRowBackground(row.isCurrent ? Color.accentColor.opacity(0.08) : nil)
                }
            }
        }
        if !guide.hasUpcoming {
            Section { Text("暂无后续节目").foregroundStyle(.secondary) }
        }
    }
}

private struct IOSProgrammeRow: View {
    let row: IOSProgrammeGuidePresentation.Row
    @State private var isExpanded = false
    private var details: [String] {
        [row.programme.subtitle, row.programme.summary].compactMap {
            guard let value = $0?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
    }

    var body: some View {
        Group {
            if details.isEmpty {
                summary
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("\(row.accessibilityPrefix).details")
                } label: { summary }
                .tint(.secondary)
                .accessibilityIdentifier("\(row.accessibilityPrefix).disclosure")
            }
        }
        .padding(.vertical, 8)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    timeRange.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    status
                }
                VStack(alignment: .leading, spacing: 6) {
                    timeRange
                    status
                }
            }
            Text(row.programme.title).font(.headline).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(row.accessibilityPrefix).title")
            if let progress = row.progress, let remaining = row.remainingText {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress).tint(.accentColor)
                        .accessibilityLabel("节目播出进度")
                    Text(remaining).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("programme.current.remaining")
                }
            }
        }
    }

    private var timeRange: some View {
        Text(row.timeRange).font(.subheadline.weight(.semibold)).monospacedDigit()
            .foregroundStyle(row.isCurrent ? Color.accentColor : Color.primary)
            .accessibilityLabel("播出时间，\(row.timeRange.replacingOccurrences(of: " – ", with: " 至 "))")
            .accessibilityIdentifier("\(row.accessibilityPrefix).time")
    }

    @ViewBuilder private var status: some View {
        if row.isCurrent {
            Text("正在播出").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
        } else if row.isNext {
            Text("下一节目").font(.caption).foregroundStyle(.secondary)
        }
    }
}
