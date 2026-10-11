// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import SwiftUI
import VPlayerCore

struct MacSourceManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var editing: SourceProfile?
    @State private var adding = false
    @State private var deleting: SourceProfile?
    var body: some View {
        NavigationStack {
            Group {
                if model.profiles.isEmpty {
                    ContentUnavailableView("暂无播放列表", systemImage: "play.square.stack",
                        description: Text("添加 HTTP 或 HTTPS 的 M3U 和 XMLTV 地址。"))
                } else {
                    List {
                        ForEach(model.profiles) { profile in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(profile.name).font(.headline)
                                    if profile.id == model.activeProfile?.id { Text("当前使用").font(.caption).foregroundStyle(.tint) }
                                    Spacer()
                                    Button("使用") { Task { _ = await model.activate(profileID: profile.id) } }
                                        .disabled(profile.id == model.activeProfile?.id || model.isLoading)
                                    Button("编辑") { editing = profile }
                                    Button("删除", role: .destructive) { deleting = profile }
                                }
                                Text(RedactedURL.string(profile.m3uURL)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("频道：\(ResourceRefreshStatusPresentation.text(for: profile.m3uStatus))")
                                        Text("节目单：\(ResourceRefreshStatusPresentation.text(for: profile.epgStatus))")
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Menu("刷新") {
                                        Button("刷新频道") { Task { await model.refresh(profileID: profile.id, resource: .playlist) } }
                                        Button("刷新节目单") { Task { await model.refresh(profileID: profile.id, resource: .epg) } }
                                    }.disabled(model.isLoading)
                                }
                            }.padding(.vertical, 10)
                        }
                    }
                }
            }
            .navigationTitle("播放列表")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("添加播放列表", systemImage: "plus") { adding = true }
                }
            }
        }
        .frame(width: 760, height: 520)
        .sheet(item: $editing) { MacSourceEditorView(model: model, profile: $0) }
        .sheet(isPresented: $adding) { MacSourceEditorView(model: model, profile: nil) }
        .confirmationDialog("删除播放列表？", isPresented: Binding(get: { deleting != nil },
            set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting {
                Button("删除“\(deleting.name)”", role: .destructive) {
                    Task { _ = await model.delete(profileID: deleting.id) }; self.deleting = nil
                }
            }
        } message: { Text("该播放列表的频道和节目单会从本机资料库移除。") }
        .alert(model.alertTitle, isPresented: Binding(get: { model.alertMessage != nil },
            set: { if !$0 { model.dismissAlert() } })) {
            Button("知道了") { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
    }
}

struct MacSourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let profile: SourceProfile?
    @State private var name: String
    @State private var playlistURL: String
    @State private var epgURL: String
    @State private var playlistInterval: RefreshInterval
    @State private var epgInterval: RefreshInterval
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var attempt = UUID()
    init(model: AppModel, profile: SourceProfile?) {
        self.model = model; self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _playlistURL = State(initialValue: profile?.m3uURL.absoluteString ?? "")
        _epgURL = State(initialValue: profile?.epgURL.absoluteString ?? "")
        _playlistInterval = State(initialValue: profile?.m3uRefreshInterval ?? .sixHours)
        _epgInterval = State(initialValue: profile?.epgRefreshInterval ?? .daily)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(profile == nil ? "添加播放列表" : "编辑播放列表", systemImage: "play.square.stack").font(.title2.bold())
            Text("VPlayer 会导入 M3U 频道和 XMLTV 节目单，并按设定的频率刷新。")
                .foregroundStyle(.secondary)
            Form {
                TextField("名称", text: $name).accessibilityIdentifier("source.editor.name")
                TextField("M3U 地址", text: $playlistURL).accessibilityIdentifier("source.editor.m3u")
                TextField("EPG 地址", text: $epgURL).accessibilityIdentifier("source.editor.epg")
                intervalPicker("频道刷新频率", selection: $playlistInterval)
                intervalPicker("节目单刷新频率", selection: $epgInterval)
            }
            Text("播放列表与节目单地址均须为 HTTP 或 HTTPS。地址仅保存在本机。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityElement(children: .ignore).accessibilityLabel(errorMessage)
                    .accessibilityIdentifier("source.editor.error")
            }
            HStack {
                Spacer()
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                    .accessibilityIdentifier("source.editor.cancel")
                Button(isSaving ? "保存中…" : "保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(isSaving).accessibilityIdentifier("source.editor.save")
            }
        }.padding(28).frame(width: 620)
        .interactiveDismissDisabled(isSaving)
        .onDisappear { if profile == nil { model.cancelCreateAttempt(attempt) } }
    }
    private func intervalPicker(_ title: String, selection: Binding<RefreshInterval>) -> some View {
        Picker(title, selection: selection) {
            ForEach(RefreshInterval.allCases, id: \.rawValue) { value in Text(value.macLabel).tag(value) }
        }
    }
    private func cancel() { if profile == nil { model.cancelCreateAttempt(attempt) }; dismiss() }
    private func save() {
        let input = SourceProfileInput(name: name, m3uURLString: playlistURL, epgURLString: epgURL,
            m3uRefreshInterval: playlistInterval, epgRefreshInterval: epgInterval)
        do { _ = try input.validated() }
        catch { errorMessage = SourceProfileValidationMessage.text(for: error) ?? "请检查输入内容。"; return }
        errorMessage = nil; isSaving = true
        Task {
            var failure: String?
            let saved: Bool
            if let profile { saved = await model.update(profileID: profile.id, input: input) { failure = $0 } }
            else { saved = await model.create(input: input, attemptID: attempt) { failure = $0 } }
            isSaving = false
            if saved { dismiss() } else { errorMessage = failure ?? "保存失败，请重试。" }
        }
    }
}

private extension RefreshInterval {
    var macLabel: String {
        switch self {
        case .manual: "仅手动"
        case .hourly: "每小时"
        case .sixHours: "每 6 小时"
        case .twelveHours: "每 12 小时"
        case .daily: "每天"
        }
    }
}
