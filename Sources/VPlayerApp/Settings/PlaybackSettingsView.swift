// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

/// Serialises picture-setting changes onto the playback engine. The rows can be
/// pressed faster than the engine applies a change, so they share one chain
/// rather than racing each other.
@MainActor
final class PlaybackTuningSelectionController {
    private weak var engine: (any PlaybackEngine)?
    private var task: Task<Void, Never>?

    init(engine: any PlaybackEngine) {
        self.engine = engine
    }

    func apply(_ tuning: PlaybackTuning) {
        enqueue { engine in await engine.setTuning(tuning) }
    }

    private func enqueue(
        _ operation: @escaping @Sendable (any PlaybackEngine) async -> Void
    ) {
        let predecessor = task
        task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, let engine = self?.engine else { return }
            await operation(engine)
        }
    }
}

/// The buffering rows, shared by the settings tab and the sheet the player raises
/// mid-playback. Both buffers are expressed in the unit that actually bounds
/// them — the video buffer in seconds, so it does not silently halve when a
/// field-rate deinterlace route doubles the output frame rate.
struct PlaybackBufferRows: View {
    @Bindable var playback: PlaybackSettingsStore

    var body: some View {
        ForEach(PlaybackTuning.videoBufferSecondsChoices, id: \.self) { seconds in
            Button {
                playback.videoBufferSeconds = seconds
            } label: {
                SettingsSelectionLabel(
                    title: Self.videoBufferTitle(seconds),
                    isSelected: playback.videoBufferSeconds == seconds
                )
            }
            .accessibilityLabel(Self.videoBufferTitle(seconds))
            .accessibilityIdentifier("settings.buffer.video.\(Self.identifierSuffix(seconds))")
            .accessibilityAddTraits(playback.videoBufferSeconds == seconds ? .isSelected : [])
        }
    }

    static func videoBufferTitle(_ seconds: Double, marksDefault: Bool = true) -> String {
        let formatted = seconds == seconds.rounded()
            ? String(Int(seconds))
            : String(format: "%.1f", seconds)
        return marksDefault && seconds == PlaybackTuning.default.videoBufferSeconds
            ? "\(formatted) 秒（默认）"
            : "\(formatted) 秒"
    }

    /// Accessibility identifiers cannot carry a decimal point without reading as a
    /// path separator in the acceptance harness, so `0.5` becomes `0_5`.
    static func identifierSuffix(_ seconds: Double) -> String {
        Self.videoBufferTitle(seconds)
            .prefix { $0.isNumber || $0 == "." }
            .replacingOccurrences(of: ".", with: "_")
    }
}

/// Split out from `PlaybackBufferRows` so the deinterlace buffer sits under its
/// own heading: it counts frames waiting for the GPU, not seconds of video.
struct DeinterlaceBufferRows: View {
    @Bindable var playback: PlaybackSettingsStore

    var body: some View {
        ForEach(PlaybackTuning.deinterlaceBufferFramesChoices, id: \.self) { frames in
            Button {
                playback.deinterlaceBufferFrames = frames
            } label: {
                SettingsSelectionLabel(
                    title: Self.title(frames),
                    isSelected: playback.deinterlaceBufferFrames == frames
                )
            }
            .accessibilityLabel(Self.title(frames))
            .accessibilityIdentifier("settings.buffer.deinterlace.\(frames)")
            .accessibilityAddTraits(playback.deinterlaceBufferFrames == frames ? .isSelected : [])
        }
    }

    static func title(_ frames: Int, marksDefault: Bool = true) -> String {
        marksDefault && frames == PlaybackTuning.default.deinterlaceBufferFrames
            ? "\(frames) 帧（默认）"
            : "\(frames) 帧"
    }
}

struct SettingsSelectionLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        }
    }
}

/// A compact settings row. The choices live one navigation level deeper so the
/// root settings screen stays short even as more tuning values are added.
struct SettingsSummaryLink<Destination: View>: View {
    let title: String
    let value: String
    let identifier: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }
}

enum PlaybackSettingsExplanation {
    static let videoBuffer = "较短的缓冲可减少等待和直播延迟；供帧或网络波动时，可尝试增大缓冲以改善稳定性。修改立即应用，并保存到本机的所有频道。"
    static let deinterlaceBuffer = "控制等待反交错处理的视频帧数。较大的缓冲可容纳更多处理波动，也会增加内存占用。修改立即应用，并保存到本机的所有频道。"
    static let frameRateEnhancement = "支持的隔行片源会自动进行反交错处理，例如从 25 fps 增强到 50 fps，让运动画面更流畅。是否启用取决于片源和播放路径，缓冲大小不控制帧率增强。"
}

struct VideoBufferSelectionView: View {
    @Bindable var playback: PlaybackSettingsStore

    var body: some View {
        List {
            Section {
                PlaybackBufferRows(playback: playback)
            } footer: {
                Text(PlaybackSettingsExplanation.videoBuffer)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("视频缓冲")
    }
}

struct DeinterlaceBufferSelectionView: View {
    @Bindable var playback: PlaybackSettingsStore

    var body: some View {
        List {
            Section {
                DeinterlaceBufferRows(playback: playback)
            } footer: {
                Text(PlaybackSettingsExplanation.deinterlaceBuffer)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("帧率增强") {
                Text(PlaybackSettingsExplanation.frameRateEnhancement)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("反交错缓冲")
    }
}

/// 三端设置首页和播放中设置共用相同的入口、说明与恢复范围。
struct PlaybackSettingsSections: View {
    @Bindable var playback: PlaybackSettingsStore

    var body: some View {
        Section {
            SettingsSummaryLink(
                title: "视频缓冲",
                value: PlaybackBufferRows.videoBufferTitle(playback.videoBufferSeconds),
                identifier: "settings.buffer.video.current"
            ) {
                VideoBufferSelectionView(playback: playback)
            }
            SettingsSummaryLink(
                title: "反交错缓冲",
                value: DeinterlaceBufferRows.title(playback.deinterlaceBufferFrames),
                identifier: "settings.buffer.deinterlace.current"
            ) {
                DeinterlaceBufferSelectionView(playback: playback)
            }
        } header: {
            Text("播放")
        } footer: {
            Text("修改立即用于当前播放，并保存到本机的所有频道。")
        }
    }
}

struct PlaybackSettingsResetSection: View {
    @Bindable var playback: PlaybackSettingsStore

    var body: some View {
        Section {
            Button("恢复播放默认设置") { playback.restoreDefaults() }
                .disabled(playback.tuning == .default)
                .accessibilityIdentifier("settings.playback.reset")
        } footer: {
            Text("恢复为视频缓冲 \(PlaybackBufferRows.videoBufferTitle(PlaybackTuning.default.videoBufferSeconds, marksDefault: false))、反交错缓冲 \(DeinterlaceBufferRows.title(PlaybackTuning.default.deinterlaceBufferFrames, marksDefault: false))。仅恢复播放设置。")
        }
    }
}

/// Raised over playback, where only the picture settings make sense — channel
/// browsing preferences belong to the settings tab, not to a running stream.
struct PlaybackSettingsView: View {
    @Bindable var settings: PlaybackSettingsStore

    init(settings: PlaybackSettingsStore) {
        self.settings = settings
    }

    var body: some View {
        NavigationStack {
            List {
                PlaybackSettingsSections(playback: settings)
                PlaybackSettingsResetSection(playback: settings)
            }
            .navigationTitle("播放设置")
        }
    }
}
