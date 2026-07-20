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
    @Bindable var model: AppModel
    @State private var editedProfile: SourceProfile?
    @State private var isAdding = false
    @State private var pendingDeletion: SourceProfile?

    var body: some View {
        NavigationStack {
            List {
                if model.profiles.isEmpty && !model.isLoading {
                    ContentUnavailableView(
                        "还没有数据源",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("添加后即可刷新频道列表和 EPG。")
                    )
                }

                ForEach(model.profiles) { profile in
                    Section {
                        profileHeader(profile)
                        resourceStatus(
                            title: "播放列表",
                            status: profile.m3uStatus,
                            refreshIdentifier: "source.refresh.playlist"
                        ) {
                            await model.refresh(profileID: profile.id, resource: .playlist)
                        }
                        resourceStatus(
                            title: "EPG",
                            status: profile.epgStatus,
                            refreshIdentifier: "source.refresh.epg"
                        ) {
                            await model.refresh(profileID: profile.id, resource: .epg)
                        }
                        HStack {
                            Button("编辑") {
                                editedProfile = profile
                            }
                            .accessibilityIdentifier("source.edit.\(profile.id.uuidString)")

                            Button("删除", role: .destructive) {
                                pendingDeletion = profile
                            }
                            .accessibilityIdentifier("source.delete.\(profile.id.uuidString)")
                        }
                    }
                }
            }
            .navigationTitle("数据源")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAdding = true
                    } label: {
                        Label("添加数据源", systemImage: "plus")
                    }
                    .accessibilityIdentifier("source.add")
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            SourceProfileEditorView(model: model, profile: nil)
        }
        .sheet(item: $editedProfile) { profile in
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
        }
    }

    private func profileHeader(_ profile: SourceProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name)
                    .font(.headline)
                Text(displayedM3UURL(for: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.activeProfile?.id == profile.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("当前数据源")
                    .accessibilityIdentifier(activeIdentifier(profile))
            } else {
                Button("设为当前") {
                    Task {
                        await model.activate(profileID: profile.id)
                    }
                }
                .accessibilityIdentifier("source.activate.\(profile.id.uuidString)")
            }
        }
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
        status: ResourceRefreshStatus,
        refreshIdentifier: String,
        refresh: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                Text(ResourceRefreshStatusPresentation.text(for: status))
                    .font(.caption)
                    .foregroundStyle(status.state == .failed ? .red : .secondary)
                if let error = status.errorSummary {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button(status.state == .refreshing ? "刷新中…" : "立即刷新") {
                Task {
                    await refresh()
                }
            }
            .disabled(status.state == .refreshing)
            .accessibilityIdentifier(refreshIdentifier)
        }
    }

    private func activeIdentifier(_ profile: SourceProfile) -> String {
        profile.name == "测试数据源" ? "source.active.seeded" : "source.active.\(profile.id.uuidString)"
    }
}
