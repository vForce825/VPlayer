// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

enum ResourceRefreshStatusPresentation {
    static func timestamp(for status: ResourceRefreshStatus) -> Date? {
        switch status.state {
        case .never:
            nil
        case .refreshing, .failed:
            status.lastAttemptAt
        case .succeeded:
            status.lastSuccessAt
        }
    }

    static func text(for status: ResourceRefreshStatus) -> String {
        let label = switch status.state {
        case .never: "尚未刷新"
        case .refreshing: "正在刷新"
        case .succeeded: "刷新成功"
        case .failed: "刷新失败"
        }
        guard let date = timestamp(for: status) else { return label }
        return "\(label) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct SourceProfilesView: View {
    /// One shared column grid keeps the playlist header and its indented
    /// resource rows aligned, so the hierarchy survives being read from across
    /// a room rather than resting on font sizes alone.
    private enum Metrics {
        static let iconColumn: CGFloat = 52
        static let columnSpacing: CGFloat = 24
        static let childIndent = iconColumn + columnSpacing
        static let ruleWidth: CGFloat = 4
        static let ruleLeading = (iconColumn - ruleWidth) / 2
        static let cardPadding: CGFloat = 36
        static let cardCornerRadius: CGFloat = 28
    }

    @Bindable var model: AppModel
    @State private var editedProfile: SourceProfile?
    @State private var isAdding = false
    @State private var pendingDeletion: SourceProfile?
    @FocusState private var focusedControl: AcceptanceFocusPolicy.SourceControl?
    private let focusPolicy = AcceptanceFocusPolicy.current()

    var body: some View {
        focusedContent
        #if DEBUG
        .overlay {
            if AcceptanceSourcePrefill.isActive() {
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("source.acceptance.epg-programme-count")
                    .accessibilityValue(String(model.epgProgrammeCount))
                    .allowsHitTesting(false)
                    .focusable(false)
            }
        }
        #endif
        .fullScreenCover(isPresented: $isAdding, onDismiss: focusAfterAdding) {
            SourceProfileEditorView(model: model, profile: nil)
        }
        .fullScreenCover(item: $editedProfile) { profile in
            SourceProfileEditorView(model: model, profile: profile)
        }
        .confirmationDialog(
            "删除“\(pendingDeletion?.name ?? "")”？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let profile = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    await model.delete(profileID: profile.id)
                }
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("已导入的频道和节目单会一并移除。")
        }
    }

    @ViewBuilder
    private var focusedContent: some View {
        if let initialControl = focusPolicy.initialSourceControl,
           model.profiles.isEmpty {
            content
                .defaultFocus($focusedControl, initialControl)
        } else {
            content
        }
    }

    private var content: some View {
        NavigationStack {
            Group {
                if model.profiles.isEmpty && !model.isLoading {
                    emptyState
                } else {
                    profileList
                }
            }
            .navigationTitle("播放列表")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "play.square.stack")
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
            Text("还没有播放列表")
                .font(.title2.bold())
            Text("添加 M3U 播放列表和 EPG 节目单地址，即可开始观看频道。")
                .font(.callout)
                .foregroundStyle(.secondary)
            addButton
                .padding(.top, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // A List would wrap every row in one focus card, which hides the text a row
    // shares with its buttons and makes neighbouring buttons indistinguishable
    // once the row lights up. Plain buttons on a static card each carry their
    // own focus instead.
    private var profileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                addButton
                    // The remote only crosses between controls that overlap
                    // along the axis it travels, and this button sits at the
                    // leading edge while every card control below it is
                    // trailing-aligned. Widening the row into a focus section
                    // puts the whole width in the remote's path, so pressing
                    // down leaves the button instead of dead-ending on it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                ForEach(model.profiles) { profile in
                    profileCard(profile)
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
        }
    }

    private func profileCard(_ profile: SourceProfile) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            profileHeader(profile)
            VStack(alignment: .leading, spacing: 24) {
                resourceStatus(
                    title: "频道列表",
                    systemImage: "list.bullet.rectangle",
                    status: profile.m3uStatus,
                    refreshIdentifier: "source.refresh.playlist",
                    statusIdentifier: "source.status.playlist",
                    focusTarget: .playlistRefresh
                ) {
                    await model.refresh(profileID: profile.id, resource: .playlist)
                }
                resourceStatus(
                    title: "节目单（EPG）",
                    systemImage: "calendar",
                    status: profile.epgStatus,
                    refreshIdentifier: "source.refresh.epg",
                    statusIdentifier: "source.status.epg",
                    focusTarget: .epgRefresh,
                    // Coverage is only loaded for the active playlist, so the
                    // note belongs to that card alone.
                    note: model.activeProfile?.id == profile.id
                        ? model.staleEPGCoverageEnd.map(EPGCoverageNotice.text(staleCoverageEnd:))
                        : nil
                ) {
                    await model.refresh(profileID: profile.id, resource: .epg)
                }
            }
            .padding(.leading, Metrics.childIndent)
            // One rule spanning both rows ties them to the playlist above.
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: Metrics.ruleWidth)
                    .padding(.leading, Metrics.ruleLeading)
            }
        }
        .padding(Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var addButton: some View {
        Button {
            isAdding = true
        } label: {
            Label("添加播放列表", systemImage: "plus")
        }
        .accessibilityIdentifier("source.add")
        .focused($focusedControl, equals: .add)
    }

    private func focusAfterAdding() {
        guard let target = focusPolicy.sourceControlAfterEditorDismissal else { return }
        Task {
            await Task.yield()
            guard !model.profiles.isEmpty else { return }
            focusedControl = target
        }
    }

    private func profileHeader(_ profile: SourceProfile) -> some View {
        let isActive = model.activeProfile?.id == profile.id
        return HStack(alignment: .center, spacing: Metrics.columnSpacing) {
            Image(systemName: isActive ? "play.square.stack.fill" : "play.square.stack")
                .font(.title2)
                .foregroundStyle(isActive ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: Metrics.iconColumn)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text(profile.name)
                        .font(.title3.bold())
                    if isActive {
                        activeBadge(profile)
                    }
                }
                Text(displayedM3UURL(for: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Metrics.columnSpacing)
            if !isActive {
                Button("设为当前") {
                    Task {
                        await model.activate(profileID: profile.id)
                    }
                }
                .accessibilityIdentifier("source.activate.\(profile.id.uuidString)")
            }
            Button {
                editedProfile = profile
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .accessibilityIdentifier("source.edit.\(profile.id.uuidString)")

            Button(role: .destructive) {
                pendingDeletion = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
            .accessibilityIdentifier("source.delete.\(profile.id.uuidString)")
        }
        // Each row of the card is one focus section spanning the card width, so
        // the remote steps between rows on any vertical press rather than only
        // where two controls happen to line up.
        .focusSection()
    }

    private func activeBadge(_ profile: SourceProfile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .accessibilityLabel("当前播放列表")
                .accessibilityIdentifier(activeIdentifier(profile))
            Text("当前使用")
        }
        .font(.caption.bold())
        .foregroundStyle(.green)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(.green.opacity(0.18)))
    }

    private func displayedM3UURL(for profile: SourceProfile) -> String {
        #if DEBUG
        if AcceptanceSourcePrefill.isActive() {
            return "Protected URL configured"
        }
        #endif
        return profile.m3uURL.absoluteString
    }

    private func resourceStatus(
        title: String,
        systemImage: String,
        status: ResourceRefreshStatus,
        refreshIdentifier: String,
        statusIdentifier: String,
        focusTarget: AcceptanceFocusPolicy.SourceControl,
        note: String? = nil,
        refresh: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: Metrics.columnSpacing) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.iconColumn)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout)
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor(for: status))
                        .frame(width: 12, height: 12)
                    Text(ResourceRefreshStatusPresentation.text(for: status))
                        .font(.caption)
                        .foregroundStyle(status.state == .failed ? .red : .secondary)
                        .accessibilityIdentifier(statusIdentifier)
                }
                if let error = status.errorSummary {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("\(statusIdentifier).note")
                }
            }
            Spacer(minLength: Metrics.columnSpacing)
            Button(status.state == .refreshing ? "刷新中…" : "立即刷新") {
                Task {
                    await refresh()
                }
            }
            .disabled(status.state == .refreshing)
            .accessibilityIdentifier(refreshIdentifier)
            .focused($focusedControl, equals: focusTarget)
        }
        .focusSection()
    }

    private func statusColor(for status: ResourceRefreshStatus) -> Color {
        switch status.state {
        case .never: .gray
        case .refreshing: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }

    private func activeIdentifier(_ profile: SourceProfile) -> String {
        profile.name == "测试播放列表" ? "source.active.seeded" : "source.active.\(profile.id.uuidString)"
    }
}
