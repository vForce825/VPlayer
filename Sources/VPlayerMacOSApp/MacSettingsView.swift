// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import SwiftUI
import VPlayerPlayback

struct MacSettingsView: View {
    let dependencies: AppDependencies
    @State private var showsLicenses = false
    var body: some View {
        TabView {
            MacPlaybackSettingsForm(settings: dependencies.playbackSettings)
                .tabItem { Label("播放", systemImage: "play.rectangle") }
            browsing.tabItem { Label("频道", systemImage: "list.bullet") }
            about.tabItem { Label("关于", systemImage: "info.circle") }
        }.padding(20).frame(width: 520, height: 390)
        .sheet(isPresented: $showsLicenses) {
            VStack(alignment: .leading, spacing: 16) {
                Text("开源许可与第三方声明").font(.title2.bold())
                ScrollView {
                    Text(licenseText).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("完成") { showsLicenses = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 700, height: 520)
        }
    }
    private var licenseText: String {
        ["THIRD_PARTY_NOTICES", "LICENSE", "LICENSE.APPSTORE-EXCEPTION"].compactMap { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
    private var browsing: some View {
        @Bindable var settings = dependencies.channelBrowsingSettings
        return Form {
            Picker("频道排列", selection: $settings.grouping) {
                Text("按播放列表分组").tag(ChannelGrouping.playlistGroups)
                Text("按播放列表顺序").tag(ChannelGrouping.playlistOrder)
            }
            Text("关闭分组后，频道按照播放列表中的原始顺序显示。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
    private var about: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.tv.fill").font(.system(size: 46)).foregroundStyle(.tint)
            Text("VPlayer").font(.title.bold())
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1") · macOS 27")
                .foregroundStyle(.secondary)
            Text("播放源、频道和节目单保存在本机，VPlayer 不提供直播内容。")
                .font(.caption).multilineTextAlignment(.center)
            Link("源代码与开源许可", destination: URL(string: "https://github.com/vForce825/VPlayer")!)
            Button("查看开源许可与第三方声明") { showsLicenses = true }
            Text("本软件部分基于 Independent JPEG Group 的工作。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding()
    }
}

struct MacPlaybackSettingsForm: View {
    @Bindable var settings: PlaybackSettingsStore
    @State private var selection: BufferSelection?

    private enum BufferSelection: String, Identifiable {
        case video = "视频缓冲"
        case deinterlace = "反交错缓冲"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                summary(.video, value: PlaybackBufferRows.videoBufferTitle(settings.videoBufferSeconds),
                    identifier: "settings.buffer.video.current")
                summary(.deinterlace, value: DeinterlaceBufferRows.title(settings.deinterlaceBufferFrames),
                    identifier: "settings.buffer.deinterlace.current")
            }
            .formStyle(.grouped)
            .frame(height: 130)
            Text("修改立即用于当前播放，并保存到本机的所有频道。")
                .font(.caption).foregroundStyle(.secondary)
            Button("恢复播放默认设置") { settings.restoreDefaults() }
                .disabled(settings.tuning == .default)
                .accessibilityIdentifier("settings.playback.reset")
            Text("恢复为视频缓冲 \(PlaybackBufferRows.videoBufferTitle(PlaybackTuning.default.videoBufferSeconds, marksDefault: false))、反交错缓冲 \(DeinterlaceBufferRows.title(PlaybackTuning.default.deinterlaceBufferFrames, marksDefault: false))。仅恢复播放设置。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .frame(height: 300)
        .popover(item: $selection) { choice in
            VStack(spacing: 12) {
                HStack {
                    Text(choice.rawValue).font(.headline)
                    Spacer()
                    Button("完成") { selection = nil }
                        .accessibilityIdentifier("settings.buffer.options.done")
                }
                VStack(alignment: .leading, spacing: 12) {
                    switch choice {
                    case .video:
                        PlaybackBufferRows(playback: settings)
                        explanation(PlaybackSettingsExplanation.videoBuffer)
                    case .deinterlace:
                        DeinterlaceBufferRows(playback: settings)
                        explanation(PlaybackSettingsExplanation.deinterlaceBuffer)
                        Text("帧率增强").font(.headline)
                        explanation(PlaybackSettingsExplanation.frameRateEnhancement)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(width: 390)
        }
    }

    private func summary(_ choice: BufferSelection, value: String, identifier: String) -> some View {
        Button { selection = choice } label: {
            HStack {
                Text(choice.rawValue)
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.rawValue)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
