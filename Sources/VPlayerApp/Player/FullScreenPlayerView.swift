// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
import VPlayerPlayback

enum FullScreenPlayerLifecyclePolicy {
    static func shouldStopOnDisappear(isPresentingSettings: Bool) -> Bool {
        !isPresentingSettings
    }
}

/// Decides when the transport controls and channel information card are mounted
/// and whether they are pinned or owned by the single playback auto-hide task.
enum PlayerControlsVisibilityPolicy {
    enum Mode: Equatable, Sendable {
        case hidden
        case pinned
        case timed
    }

    static let idleTimeout = Duration.seconds(3)

    static func mode(for state: PlaybackState) -> Mode {
        switch state {
        case .idle, .preparing, .paused:
            .pinned
        case .playing:
            .timed
        case .stopped, .failed:
            .hidden
        }
    }

    static func mountsOverlays(for state: PlaybackState) -> Bool {
        mountsOverlays(for: mode(for: state))
    }

    static func mountsOverlays(for mode: Mode) -> Bool {
        mode != .hidden
    }

    static func staysVisible(for state: PlaybackState) -> Bool {
        mode(for: state) == .pinned
    }
}

enum PlayerControlsVisibilityEvent: Equatable, Sendable {
    case stateChanged(PlayerControlsVisibilityPolicy.Mode)
    case userInteraction
    case mediaInformationBecameAvailable
    case timeoutCompleted(PlayerControlsAutoHideKey)
}

struct PlayerControlsAutoHideKey: Equatable, Sendable {
    let mode: PlayerControlsVisibilityPolicy.Mode
    let wakeRevision: UInt64
}

struct PlayerControlsVisibilityState: Equatable, Sendable {
    private(set) var mode: PlayerControlsVisibilityPolicy.Mode
    private(set) var wakeRevision: UInt64
    private(set) var isVisible: Bool

    init(
        mode: PlayerControlsVisibilityPolicy.Mode,
        wakeRevision: UInt64 = 0
    ) {
        self.mode = mode
        self.wakeRevision = wakeRevision
        isVisible = mode != .hidden
    }

    var key: PlayerControlsAutoHideKey {
        PlayerControlsAutoHideKey(mode: mode, wakeRevision: wakeRevision)
    }

    mutating func apply(_ event: PlayerControlsVisibilityEvent) {
        switch event {
        case let .stateChanged(nextMode):
            guard mode != nextMode else { return }
            mode = nextMode
            isVisible = nextMode != .hidden
        case .userInteraction, .mediaInformationBecameAvailable:
            guard mode == .timed else { return }
            isVisible = true
            wakeRevision &+= 1
        case let .timeoutCompleted(completedKey):
            guard mode == .timed, key == completedKey else { return }
            isVisible = false
        }
    }
}

enum PlayerControlsAutoHidePolicy {
    static func shouldSleep(for key: PlayerControlsAutoHideKey) -> Bool {
        key.mode == .timed
    }

    static func shouldHide(
        after key: PlayerControlsAutoHideKey,
        current: PlayerControlsAutoHideKey
    ) -> Bool {
        key.mode == .timed && key == current
    }
}

enum PlayerControlsCommandPolicy {
    static func handlePlayPause(
        wake: () -> Void,
        toggle: () -> Void
    ) {
        wake()
        toggle()
    }
}

/// Keeps tvOS from treating uninterrupted video watching as user inactivity.
/// Paused, stopped, and failed playback deliberately return control to the
/// system so the app cannot suppress the screen saver indefinitely.
enum PlaybackIdleTimerPolicy {
    static func isDisabled(for state: PlaybackState) -> Bool {
        switch state {
        case .preparing, .playing:
            true
        case .idle, .paused, .stopped, .failed:
            false
        }
    }
}

struct FullScreenPlayerView: View {
    private enum FailureControl: Hashable {
        case retry
        case back
        case settings
    }

    @State private var model: FullScreenPlayerViewModel
    @State private var showsSettings = false
    @State private var isClosing = false
    @State private var controlsVisibility = PlayerControlsVisibilityState(mode: .pinned)
    #if DEBUG
    @State private var acceptanceMetricsJSON = "unavailable"
    #endif
    @FocusState private var failureFocus: FailureControl?
    private let channelPresentation: PlayerChannelPresentation
    private let settings: PlaybackSettingsStore
    private let metricsProvider: AppDependencies.PlaybackMetricsProvider
    private let acceptanceMetricsEnabled: Bool
    private let acceptanceStateEnabled: Bool
    private let onDismiss: () -> Void

    init(
        channelPresentation: PlayerChannelPresentation,
        engine: any PlaybackEngine,
        presentationProvider: @escaping FullScreenPlayerViewModel.PresentationProvider,
        mediaInformationProvider: @escaping FullScreenPlayerViewModel.MediaInformationProvider,
        metricsProvider: @escaping AppDependencies.PlaybackMetricsProvider,
        acceptanceMetricsEnabled: Bool,
        acceptanceStateEnabled: Bool,
        settings: PlaybackSettingsStore,
        onDismiss: @escaping () -> Void
    ) {
        self.channelPresentation = channelPresentation
        _model = State(initialValue: FullScreenPlayerViewModel(
            request: channelPresentation.request,
            engine: engine,
            presentationProvider: presentationProvider,
            mediaInformationProvider: mediaInformationProvider,
            settings: settings
        ))
        self.settings = settings
        self.metricsProvider = metricsProvider
        self.acceptanceMetricsEnabled = acceptanceMetricsEnabled
        self.acceptanceStateEnabled = acceptanceStateEnabled
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack {
            // fullScreenCover is transparent on tvOS. Keep an opaque backing
            // below Metal even after its context exists, because the drawable
            // has no video content until the first frame is presented.
            Color.black.ignoresSafeArea()

            if let context = model.presentationContext {
                MetalPlayerView(context: context)
                    .ignoresSafeArea()
            }

            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("player-full-screen")
                .allowsHitTesting(false)
                .focusable(false)

            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("player-controls-visibility")
                .accessibilityValue(controlsVisibility.isVisible ? "visible" : "hidden")
                .allowsHitTesting(false)
                .focusable(false)

            #if DEBUG
            if acceptanceStateEnabled {
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("player-acceptance-state")
                    .accessibilityValue(
                        AcceptancePlaybackStatePresentation(state: model.state).value
                    )
                    .allowsHitTesting(false)
                    .focusable(false)
            }

            if acceptanceMetricsEnabled {
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("player-acceptance-metrics")
                    .accessibilityValue(acceptanceMetricsJSON)
                    .allowsHitTesting(false)
                    .focusable(false)
            }
            #endif

            if shouldMountTransportOverlays {
                PlayerChannelInfoOverlay(
                    presentation: channelPresentation,
                    mediaInformation: model.mediaInformation
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 36)
                .padding(.trailing, 56)
                .opacity(controlsAreVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: controlsAreVisible)
            }

            statusOverlay

            if let notice = model.visibleNotice {
                PlayerNoticeBanner(notice: notice)
                    .transition(.opacity)
            }

            if shouldMountTransportOverlays {
                PlayerControlsOverlay(
                    isPaused: model.isPaused,
                    onBack: close,
                    onPlayPause: model.togglePause,
                    onSettings: { showsSettings = true },
                    onInteraction: wakeControls
                )
                .opacity(controlsAreVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: controlsAreVisible)
            }
        }
        .onMoveCommand { _ in
            wakeControls()
        }
        .task(id: controlsAutoHideKey) {
            await runControlsAutoHide(for: controlsAutoHideKey)
        }
        .task { model.start() }
        .onChange(of: model.state, initial: true) { _, state in
            controlsVisibility.apply(
                .stateChanged(PlayerControlsVisibilityPolicy.mode(for: state))
            )
            UIApplication.shared.isIdleTimerDisabled =
                PlaybackIdleTimerPolicy.isDisabled(for: state)
        }
        .onChange(of: model.mediaInformation) { oldValue, newValue in
            guard oldValue == nil, newValue != nil, controlsVisibilityMode == .timed else {
                return
            }
            wakeControls()
        }
        #if DEBUG
        .task { await publishAcceptanceMetrics() }
        #endif
        .onDisappear {
            guard FullScreenPlayerLifecyclePolicy.shouldStopOnDisappear(
                isPresentingSettings: showsSettings
            ) else { return }
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await model.stop() }
        }
        .onPlayPauseCommand {
            PlayerControlsCommandPolicy.handlePlayPause(
                wake: wakeControls,
                toggle: model.togglePause
            )
        }
        .onExitCommand(perform: close)
        .sheet(isPresented: $showsSettings) {
            PlaybackSettingsView(settings: settings)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.state {
        case .idle, .preparing:
            ProgressView("正在准备播放…")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player-preparing")
                .padding(24)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case let .failed(failure):
            VStack(spacing: 20) {
                Text(failure.userMessage)
                HStack {
                    Button("重试", action: model.retry)
                        .accessibilityIdentifier("player-retry")
                        .focused($failureFocus, equals: .retry)
                    Button("返回", action: close)
                        .focused($failureFocus, equals: .back)
                    Button("播放设置") { showsSettings = true }
                        .focused($failureFocus, equals: .settings)
                }
                .defaultFocus($failureFocus, .retry)
            }
            .padding(32)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
            .onAppear { failureFocus = .retry }
        case .playing, .paused, .stopped:
            EmptyView()
        }
    }

    private var controlsVisibilityMode: PlayerControlsVisibilityPolicy.Mode {
        controlsVisibility.mode
    }

    private var shouldMountTransportOverlays: Bool {
        PlayerControlsVisibilityPolicy.mountsOverlays(for: controlsVisibilityMode)
    }

    private var controlsAutoHideKey: PlayerControlsAutoHideKey {
        controlsVisibility.key
    }

    private var controlsAreVisible: Bool {
        controlsVisibility.isVisible
    }

    private func wakeControls() {
        controlsVisibility.apply(.userInteraction)
    }

    /// Re-shows the controls, then fades them out again after an idle period of
    /// uninterrupted playback. Restarted whenever the viewer moves on the remote
    /// or playback leaves the steady playing state.
    private func runControlsAutoHide(for key: PlayerControlsAutoHideKey) async {
        guard PlayerControlsAutoHidePolicy.shouldSleep(for: key) else { return }
        do {
            try await Task.sleep(for: PlayerControlsVisibilityPolicy.idleTimeout)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        controlsVisibility.apply(.timeoutCompleted(key))
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        // Return to the channel list immediately. Engine teardown continues in
        // the background (also driven by onDisappear) so a hung network stop
        // never makes the Back button feel frozen.
        onDismiss()
        Task { await model.stop() }
    }

    #if DEBUG
    private func publishAcceptanceMetrics() async {
        guard acceptanceMetricsEnabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while !Task.isCancelled {
            if let snapshot = await metricsProvider(.seconds(60)),
               let data = try? encoder.encode(snapshot),
               let json = String(data: data, encoding: .utf8) {
                acceptanceMetricsJSON = json
            } else {
                acceptanceMetricsJSON = "unavailable"
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
    #endif
}
