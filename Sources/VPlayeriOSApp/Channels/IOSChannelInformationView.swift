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
    @State private var selectedTab: InformationTab = .overview

    private enum InformationTab: String, CaseIterable, Identifiable {
        case overview = "概览"
        case programmes = "节目单"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                channelHeading
                Picker("频道信息内容", selection: $selectedTab) {
                    ForEach(InformationTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("channel.info.tabs")
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                TimelineView(.periodic(from: .now, by: reducedResourceUsage ? 120 : 30)) { tick in
                    let programmes = model.programmesByChannelID[channel.id, default: []]
                    let guide = IOSProgrammeGuidePresentation(programmes: programmes, at: tick.date)
                    List {
                        switch selectedTab {
                        case .overview:
                            currentProgrammeSummary(guide: guide)
                            streamInformation
                            matchedProgrammeInformation
                            originalSourceFields
                        case .programmes:
                            if guide.days.isEmpty {
                                ContentUnavailableView("暂无节目单", systemImage: "list.bullet.rectangle",
                                    description: Text("请在“概览”中检查节目单匹配，或在“播放列表”中刷新节目单。"))
                                    .listRowBackground(Color.clear)
                            } else {
                                IOSProgrammeSections(guide: guide)
                            }
                        }
                    }
                    .id(selectedTab)
                    .accessibilityIdentifier(selectedTab == .overview ? "channel.info.overview" : "channel.info.programmes")
                    .listSectionSpacing(.compact)
                    .contentMargins(.top, 8, for: .scrollContent)
                    .scrollEdgeEffectStyle(.hard, for: .top)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("频道信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
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

    private var channelHeading: some View {
        HStack(spacing: 12) {
            ChannelLogoView(url: channel.logoURL, imagePadding: 4, placeholderVerticalPadding: 8)
                .frame(width: 48, height: 44)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.displayName).font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("channel.info.name")
                let group = originalValue(channel.groupTitle) ?? ChannelSectionBuilder.ungroupedTitle
                if let profile = model.profiles.first(where: { $0.id == channel.sourceProfileID }) {
                    Text("\(profile.name) · \(group)")
                        .accessibilityLabel("播放列表，\(profile.name)，分组，\(group)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(group).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func currentProgrammeSummary(guide: IOSProgrammeGuidePresentation) -> some View {
        Section {
            if let current = guide.days.lazy.flatMap(\.rows).first(where: \.isCurrent) {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("正在播出").font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            currentProgrammeTime(current.timeRange)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("正在播出").font(.caption).foregroundStyle(.secondary)
                            currentProgrammeTime(current.timeRange)
                        }
                    }
                    Text(current.programme.title).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("channel.info.current.title")
                    if let progress = current.progress {
                        ProgressView(value: progress).tint(.accentColor)
                            .accessibilityLabel("节目播出进度")
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("暂无当前节目").foregroundStyle(.secondary)
                    .accessibilityIdentifier("channel.info.current.empty")
            }
        }
    }

    private func currentProgrammeTime(_ timeRange: String) -> some View {
        Text(timeRange).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            .accessibilityLabel("播出时间，\(timeRange.replacingOccurrences(of: " – ", with: " 至 "))")
            .accessibilityIdentifier("channel.info.current.time")
    }

    private var streamInformation: some View {
        Section("播放链接") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("频道播放地址").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = channel.streamURL.absoluteString
                        copiedStreamURL = true
                    } label: {
                        Label(copiedStreamURL ? "已复制" : "复制", systemImage: "doc.on.doc")
                            .font(.caption)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedStreamURL ? "已复制播放链接" : "复制播放链接")
                    .accessibilityIdentifier("channel.info.copy")
                }
                Text(channel.streamURL.absoluteString)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("channel.info.stream-url")
            }
            .padding(.vertical, 4)
        }
    }

    private var matchedProgrammeInformation: some View {
        Section("节目单匹配结果") {
            if let id = model.matchedEPGChannelID(for: channel) {
                let name = model.epgChannels.first(where: { $0.id == id })?.displayNames
                    .first(where: { originalValue($0) != nil }) ?? "未提供名称"
                informationField("节目单频道", value: name, identifier: "channel.info.epg.name")
                informationField("频道 ID", value: id, identifier: "channel.info.epg.id")
                informationField("匹配方式", value: model.manualEPGChannelID(for: channel) == id ? "手动映射" : "自动匹配",
                    identifier: "channel.info.epg.method")
            } else {
                Text("尚未匹配节目单频道").foregroundStyle(.secondary)
                    .accessibilityIdentifier("channel.info.epg.unmatched")
            }
            Button("设置 EPG") { showsMapping = true }
                .accessibilityIdentifier("channel.info.mapping")
        }
    }

    private var originalSourceFields: some View {
        Section("播放源原始字段") {
            informationField("EPG ID", value: originalValue(channel.tvgID) ?? "未提供",
                identifier: "channel.info.source.epg-id")
            informationField("EPG 名称", value: originalValue(channel.tvgName) ?? "未提供",
                identifier: "channel.info.source.epg-name")
        }
    }

    private func informationField(_ title: String, value: String, identifier: String) -> some View {
        LabeledContent(title) {
            Text(value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
    }

    private func originalValue(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
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
