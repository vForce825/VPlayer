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
                }
                ForEach(model.profiles) { profile in
                    Section {
                        Button {
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
                        Text(SourceProfileURLPresentation.m3uURL(profile: profile, protectsAcceptanceValue: false))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        refreshRow(profile, resource: .playlist, title: "频道列表", status: profile.m3uStatus)
                        refreshRow(profile, resource: .epg, title: "节目单（EPG）", status: profile.epgStatus)
                        HStack {
                            Button("编辑") { editedProfile = profile }
                            Spacer()
                            Button("删除", role: .destructive) { pendingDeletion = profile }
                        }
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
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(ResourceRefreshStatusPresentation.text(for: status))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh(profileID: profile.id, resource: resource) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(status.state == .refreshing)
            .accessibilityLabel("刷新\(title)")
            .accessibilityIdentifier(resource == .playlist ? "source.refresh.playlist" : "source.refresh.epg")
        }
    }
}
