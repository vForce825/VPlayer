// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore

struct SourceProfileEditorM3UFieldPresentation: Equatable {
    static let protectedValue = "Protected URL configured"

    let displayedValue: String
    let isProtected: Bool

    init(rawValue: String, protectsValue: Bool) {
        isProtected = protectsValue
        displayedValue = protectsValue ? Self.protectedValue : rawValue
    }
}

struct SourceProfileEditorFocusPolicy {
    enum Target: Hashable {
        case save
    }

    let initialTarget: Target?

    init(protectsAcceptanceSourceValue: Bool) {
        initialTarget = protectsAcceptanceSourceValue ? .save : nil
    }

}

struct SourceProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let profile: SourceProfile?

    @State private var name: String
    @State private var m3uURLString: String
    @State private var epgURLString: String
    @State private var m3uRefreshInterval: RefreshInterval
    @State private var epgRefreshInterval: RefreshInterval
    @State private var validationMessage: String?
    @State private var isSaving = false
    @State private var createAttemptID: UUID
    @FocusState private var focusedTarget: SourceProfileEditorFocusPolicy.Target?
    private let protectsAcceptanceSourceValue: Bool
    private let focusPolicy: SourceProfileEditorFocusPolicy

    init(model: AppModel, profile: SourceProfile?) {
        self.model = model
        self.profile = profile
        #if DEBUG
        let acceptancePrefill = profile == nil ? AcceptanceSourcePrefill.current() : nil
        let initialName = profile?.name ?? acceptancePrefill?.name ?? ""
        let initialM3U = profile?.m3uURL.absoluteString ?? acceptancePrefill?.m3uURLString ?? ""
        let initialEPG = profile?.epgURL.absoluteString ?? acceptancePrefill?.epgURLString ?? ""
        let protectsAcceptanceSourceValue = acceptancePrefill != nil
        #else
        let initialName = profile?.name ?? ""
        let initialM3U = profile?.m3uURL.absoluteString ?? ""
        let initialEPG = profile?.epgURL.absoluteString ?? ""
        let protectsAcceptanceSourceValue = false
        #endif
        self.protectsAcceptanceSourceValue = protectsAcceptanceSourceValue
        focusPolicy = SourceProfileEditorFocusPolicy(
            protectsAcceptanceSourceValue: protectsAcceptanceSourceValue
        )
        _name = State(initialValue: initialName)
        _m3uURLString = State(initialValue: initialM3U)
        _epgURLString = State(initialValue: initialEPG)
        _m3uRefreshInterval = State(initialValue: profile?.m3uRefreshInterval ?? .sixHours)
        _epgRefreshInterval = State(initialValue: profile?.epgRefreshInterval ?? .daily)
        _createAttemptID = State(initialValue: UUID())
    }

    var body: some View {
        Group {
            if let initialTarget = focusPolicy.initialTarget {
                editor
                    .defaultFocus($focusedTarget, initialTarget)
                    .task {
                        await Task.yield()
                        focusedTarget = initialTarget
                    }
            } else {
                editor
            }
        }
        .onDisappear {
            guard profile == nil else { return }
            model.cancelCreateAttempt(createAttemptID)
        }
    }

    private var editor: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 64) {
                sidebar
                    .frame(maxWidth: 560, alignment: .topLeading)
                form
            }
            .padding(.vertical, 48)
        }
        // fullScreenCover on tvOS has no opaque backdrop of its own; without
        // this the presenting screen bleeds through the editor.
        .background(.thickMaterial, ignoresSafeAreaEdges: .all)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(.tint)
            Text(profile == nil ? "添加播放列表" : "编辑播放列表")
                .font(.title.bold())
            Text("填写 M3U 播放列表与 EPG 节目单地址，保存后 VPlayer 会导入频道和节目信息，并按设定的频率自动刷新。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("source.editor.error")
            }
            Spacer()
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("播放列表名称", text: $name)
                    .accessibilityIdentifier("source.editor.name")
                m3uURLField
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                epgURLField
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("基本信息")
            } footer: {
                Text("地址仅支持 HTTP 或 HTTPS。")
            }

            Section {
                Picker("频道列表", selection: $m3uRefreshInterval) {
                    refreshIntervalOptions
                }
                Picker("节目单（EPG）", selection: $epgRefreshInterval) {
                    refreshIntervalOptions
                }
            } header: {
                Text("自动刷新")
            } footer: {
                Text("除自动刷新外，也可以随时在播放列表页手动刷新。")
            }

            Section {
                saveButton
                Button("取消") { cancel() }
                    .accessibilityIdentifier("source.editor.cancel")
            }
        }
    }

    private var saveButton: some View {
        Button(isSaving ? "保存中…" : "保存") { save() }
            .disabled(isSaving)
            .accessibilityIdentifier("source.editor.save")
            .focused($focusedTarget, equals: .save)
    }

    @ViewBuilder
    private var m3uURLField: some View {
        let m3uFieldPresentation = SourceProfileEditorM3UFieldPresentation(
            rawValue: m3uURLString,
            protectsValue: protectsAcceptanceSourceValue
        )
        if m3uFieldPresentation.isProtected {
            TextField("M3U 地址", text: .constant(m3uFieldPresentation.displayedValue))
                .disabled(true)
                .accessibilityIdentifier("source.editor.m3u")
        } else {
            TextField("M3U 地址", text: $m3uURLString)
                .accessibilityIdentifier("source.editor.m3u")
        }
    }

    @ViewBuilder
    private var epgURLField: some View {
        let epgFieldPresentation = SourceProfileEditorM3UFieldPresentation(
            rawValue: epgURLString,
            protectsValue: protectsAcceptanceSourceValue
        )
        if epgFieldPresentation.isProtected {
            TextField("EPG 地址", text: .constant(epgFieldPresentation.displayedValue))
                .disabled(true)
                .accessibilityIdentifier("source.editor.epg")
        } else {
            TextField("EPG 地址", text: $epgURLString)
                .accessibilityIdentifier("source.editor.epg")
        }
    }

    @ViewBuilder
    private var refreshIntervalOptions: some View {
        ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
            Text(interval.label).tag(interval)
        }
    }

    private var input: SourceProfileInput {
        SourceProfileInput(
            name: name,
            m3uURLString: m3uURLString,
            epgURLString: epgURLString,
            m3uRefreshInterval: m3uRefreshInterval,
            epgRefreshInterval: epgRefreshInterval
        )
    }

    private func save() {
        do {
            _ = try input.validated()
        } catch {
            validationMessage = validationMessage(for: error)
            return
        }

        validationMessage = nil
        isSaving = true
        let input = input
        Task {
            let succeeded: Bool
            if let profile {
                succeeded = await model.update(profileID: profile.id, input: input)
            } else {
                succeeded = await model.create(input: input, attemptID: createAttemptID)
            }
            guard !Task.isCancelled else { return }
            isSaving = false
            if succeeded {
                dismiss()
            }
        }
    }

    private func cancel() {
        if profile == nil {
            model.cancelCreateAttempt(createAttemptID)
        }
        dismiss()
    }

    private func validationMessage(for error: any Error) -> String {
        SourceProfileValidationMessage.text(for: error) ?? "请检查输入内容。"
    }
}

private extension RefreshInterval {
    var label: String {
        switch self {
        case .manual: "仅手动"
        case .hourly: "每小时"
        case .sixHours: "每 6 小时"
        case .twelveHours: "每 12 小时"
        case .daily: "每天"
        }
    }
}
