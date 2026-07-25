// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

/// Serialises picture-setting changes onto the playback engine. The rows can be
/// pressed faster than the engine applies a change, and both settings reach the
/// same pipeline, so they share one chain rather than racing each other.
@MainActor
final class PlaybackAlgorithmSelectionController {
    private let engine: any PlaybackEngine
    private var task: Task<Void, Never>?

    init(engine: any PlaybackEngine) {
        self.engine = engine
    }

    func select(_ algorithm: DeinterlaceAlgorithm) {
        enqueue { engine in await engine.setDeinterlaceAlgorithm(algorithm) }
    }

    func apply(_ tuning: PlaybackTuning) {
        enqueue { engine in await engine.setTuning(tuning) }
    }

    private func enqueue(
        _ operation: @escaping @Sendable (any PlaybackEngine) async -> Void
    ) {
        let predecessor = task
        let engine = engine
        task = Task {
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation(engine)
        }
    }
}

/// The algorithm rows themselves, shared by the settings tab and the sheet the
/// player raises mid-playback so both switch algorithms identically.
struct DeinterlaceAlgorithmRows: View {
    @Bindable var playback: PlaybackSettingsStore
    let focusNamespace: Namespace.ID
    private let focusPolicy = AcceptanceFocusPolicy.current()

    var body: some View {
        algorithmRow(
            title: "Apple Temporal（默认）",
            algorithm: .appleTemporal,
            identifier: "settings.deinterlace.apple"
        )
        algorithmRow(
            title: "Metal YADIF 2x",
            algorithm: .metalYADIF2x,
            identifier: "settings.deinterlace.yadif"
        )
    }

    private func algorithmRow(
        title: String,
        algorithm: DeinterlaceAlgorithm,
        identifier: String
    ) -> some View {
        Button {
            playback.deinterlaceAlgorithm = algorithm
        } label: {
            SettingsSelectionLabel(
                title: title,
                isSelected: playback.deinterlaceAlgorithm == algorithm
            )
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(playback.deinterlaceAlgorithm == algorithm ? .isSelected : [])
        .prefersDefaultFocus(
            focusPolicy.settingsControl(for: playback.deinterlaceAlgorithm) == algorithm,
            in: focusNamespace
        )
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

    static func videoBufferTitle(_ seconds: Double) -> String {
        let formatted = seconds == seconds.rounded()
            ? String(Int(seconds))
            : String(format: "%.1f", seconds)
        return seconds == PlaybackTuning.default.videoBufferSeconds
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

    static func title(_ frames: Int) -> String {
        frames == PlaybackTuning.default.deinterlaceBufferFrames
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

/// Raised over playback, where only the picture settings make sense — channel
/// browsing preferences belong to the settings tab, not to a running stream.
struct PlaybackSettingsView: View {
    @Bindable var settings: PlaybackSettingsStore
    @Namespace private var settingsFocus
    private let focusPolicy = AcceptanceFocusPolicy.current()

    init(settings: PlaybackSettingsStore) {
        self.settings = settings
    }

    var body: some View {
        Group {
            if focusPolicy.isEnabled {
                content
                    .focusScope(settingsFocus)
            } else {
                content
            }
        }
    }

    private var content: some View {
        NavigationStack {
            List {
                Section("反交错") {
                    DeinterlaceAlgorithmRows(playback: settings, focusNamespace: settingsFocus)
                }
                Section("视频缓冲") {
                    PlaybackBufferRows(playback: settings)
                }
                Section("反交错缓冲") {
                    DeinterlaceBufferRows(playback: settings)
                }
            }
            .navigationTitle("设置")
        }
    }
}
