// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct IOSSourceProfileEditorView: View {
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
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("播放列表名称", text: $name).accessibilityIdentifier("source.editor.name")
                    TextField("M3U 地址", text: $playlistURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("source.editor.m3u")
                    TextField("EPG 地址", text: $epgURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("source.editor.epg")
                }
                Section("自动刷新") {
                    intervalPicker("频道列表", selection: $playlistInterval)
                    intervalPicker("节目单（EPG）", selection: $epgInterval)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("source.editor.error")
                }
            }
            .navigationTitle(profile == nil ? "添加播放列表" : "编辑播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if profile == nil { model.cancelCreateAttempt(attempt) }
                        dismiss()
                    }.accessibilityIdentifier("source.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存", action: save)
                        .disabled(isSaving).accessibilityIdentifier("source.editor.save")
                }
            }
        }
        .onDisappear { if profile == nil { model.cancelCreateAttempt(attempt) } }
    }

    private func intervalPicker(_ title: String, selection: Binding<RefreshInterval>) -> some View {
        Picker(title, selection: selection) {
            ForEach(RefreshInterval.allCases, id: \.rawValue) { value in
                Text(intervalTitle(value)).tag(value)
            }
        }
    }
    private func intervalTitle(_ value: RefreshInterval) -> String {
        switch value {
        case .manual: "仅手动"
        case .hourly: "每小时"
        case .sixHours: "每 6 小时"
        case .twelveHours: "每 12 小时"
        case .daily: "每天"
        }
    }
    private func save() {
        let input = SourceProfileInput(name: name, m3uURLString: playlistURL, epgURLString: epgURL,
            m3uRefreshInterval: playlistInterval, epgRefreshInterval: epgInterval)
        do { _ = try input.validated() }
        catch { errorMessage = SourceProfileValidationMessage.text(for: error) ?? "请检查输入内容。"; return }
        errorMessage = nil; isSaving = true
        Task {
            let saved: Bool
            if let profile { saved = await model.update(profileID: profile.id, input: input) }
            else { saved = await model.create(input: input, attemptID: attempt) }
            guard !Task.isCancelled else { return }
            isSaving = false
            if saved { dismiss() }
        }
    }
}
