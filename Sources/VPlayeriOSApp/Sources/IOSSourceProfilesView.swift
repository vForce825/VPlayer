// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct IOSSourceProfilesView: View {
    @Bindable var model: AppModel
    @State private var isAdding = false
    @State private var editedProfile: SourceProfile?
    @State private var pendingDeletion: SourceProfile?

    var body: some View {
        NavigationStack {
            List {
                if let warning = model.recoveryWarningMessage {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                if model.profiles.isEmpty {
                    ContentUnavailableView("还没有播放列表", systemImage: "play.square.stack",
                        description: Text("添加 M3U 和 EPG 地址，即可开始观看。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(model.profiles) { profile in
                    Section {
                        Button {
                            guard profile.id != model.activeProfile?.id else { return }
                            Task { _ = await model.activate(profileID: profile.id) }
                        } label: {
                            HStack {
                                Text(profile.name).font(.headline)
                                Spacer()
                                if model.activeProfile?.id == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .disabled(model.isLoading)
                        Text(SourceProfileURLPresentation.m3uURL(profile: profile, protectsAcceptanceValue: false))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        refreshRow(profile, resource: .playlist, title: "频道列表", status: profile.m3uStatus)
                        refreshRow(profile, resource: .epg, title: "节目单（EPG）", status: profile.epgStatus)
                        HStack {
                            Button { editedProfile = profile } label: {
                                Text("编辑")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("source.edit.\(profile.id.uuidString)")
                            Spacer()
                            Button(role: .destructive) { pendingDeletion = profile } label: {
                                Text("删除")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("source.delete.\(profile.id.uuidString)")
                        }
                        // Automatic buttons in a List share the row's tap action.
                        // Keep these two controls independent, including their hit regions.
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("播放列表")
            .toolbar {
                Button { isAdding = true } label: { Label("添加", systemImage: "plus") }
                    .accessibilityIdentifier("source.add")
            }
        }
        .sheet(isPresented: $isAdding) { IOSSourceProfileEditorView(model: model, profile: nil) }
        .sheet(item: $editedProfile) { IOSSourceProfileEditorView(model: model, profile: $0) }
        .confirmationDialog("删除“\(pendingDeletion?.name ?? "")”？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let profile = pendingDeletion else { return }
                pendingDeletion = nil
                Task { _ = await model.delete(profileID: profile.id) }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { Text("已导入的频道和节目单会一并移除。") }
    }

    private func refreshRow(_ profile: SourceProfile, resource: RefreshResource,
                            title: String, status: ResourceRefreshStatus) -> some View {
        let staleNote: String? = resource == .epg && model.activeProfile?.id == profile.id
            ? model.staleEPGCoverageEnd.map(EPGCoverageNotice.text(staleCoverageEnd:))
            : nil
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(ResourceRefreshStatusPresentation.text(for: status))
                    .font(.caption)
                    .foregroundStyle(status.state == .failed ? .red : .secondary)
                if let error = status.errorSummary, !error.isEmpty {
                    let parts = NetworkFailure.splitUserMessage(error)
                    Text(parts.headline)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    if let detail = parts.diagnostic {
                        Text("诊断详情：\(detail)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let staleNote {
                    Text(staleNote)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { Task { await model.refresh(profileID: profile.id, resource: resource) } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(status.state == .refreshing || model.isLoading)
            .accessibilityLabel("刷新\(title)")
            .accessibilityIdentifier(resource == .playlist ? "source.refresh.playlist" : "source.refresh.epg")
        }
    }
}
