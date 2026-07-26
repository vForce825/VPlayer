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

/// Decides when the transport controls may fade away over live video.
///
/// Controls stay pinned whenever the viewer still needs them on screen — while
/// preparing, paused, or stopped — and only auto-hide during steady playback so
/// a static overlay never sits on the panel indefinitely.
enum PlayerControlsVisibilityPolicy {
    static let idleTimeout = Duration.seconds(5)

    static func staysVisible(for state: PlaybackState) -> Bool {
        switch state {
        case .playing:
            false
        case .idle, .preparing, .paused, .stopped, .failed:
            true
        }
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

    private struct ControlsAutoHideKey: Equatable {
        let wake: Int
        let pinned: Bool
    }

    @State private var model: FullScreenPlayerViewModel
    @State private var showsSettings = false
    @State private var isClosing = false
    @State private var controlsIdleHidden = false
    @State private var controlsWakeCount = 0
    #if DEBUG
    @State private var acceptanceMetricsJSON = "unavailable"
    #endif
    @FocusState private var failureFocus: FailureControl?
    private let settings: PlaybackSettingsStore
    private let metricsProvider: AppDependencies.PlaybackMetricsProvider
    private let acceptanceMetricsEnabled: Bool
    private let acceptanceStateEnabled: Bool
    private let onDismiss: () -> Void

    init(
        request: PlaybackRequest,
        engine: any PlaybackEngine,
        presentationProvider: @escaping FullScreenPlayerViewModel.PresentationProvider,
        metricsProvider: @escaping AppDependencies.PlaybackMetricsProvider,
        acceptanceMetricsEnabled: Bool,
        acceptanceStateEnabled: Bool,
        settings: PlaybackSettingsStore,
        onDismiss: @escaping () -> Void
    ) {
        _model = State(initialValue: FullScreenPlayerViewModel(
            request: request,
            engine: engine,
            presentationProvider: presentationProvider,
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

            statusOverlay

            if let notice = model.visibleNotice {
                PlayerNoticeBanner(notice: notice)
                    .transition(.opacity)
            }

            if !hasFailure {
                PlayerControlsOverlay(
                    title: model.request.title,
                    isPaused: model.isPaused,
                    onBack: close,
                    onPlayPause: model.togglePause,
                    onSettings: { showsSettings = true }
                )
                // Faded rather than removed so the focus engine keeps a target
                // and the controls stay reachable to the remote at any moment.
                .opacity(controlsAreVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: controlsAreVisible)
            }
        }
        .onMoveCommand { _ in
            controlsWakeCount &+= 1
        }
        .task(id: ControlsAutoHideKey(
            wake: controlsWakeCount,
            pinned: controlsArePinned
        )) {
            await runControlsAutoHide()
        }
        .task { model.start() }
        .onChange(of: model.state, initial: true) { _, state in
            UIApplication.shared.isIdleTimerDisabled =
                PlaybackIdleTimerPolicy.isDisabled(for: state)
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
        .onPlayPauseCommand(perform: model.togglePause)
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

    private var hasFailure: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var controlsArePinned: Bool {
        PlayerControlsVisibilityPolicy.staysVisible(for: model.state)
    }

    private var controlsAreVisible: Bool {
        controlsArePinned || !controlsIdleHidden
    }

    /// Re-shows the controls, then fades them out again after an idle period of
    /// uninterrupted playback. Restarted whenever the viewer moves on the remote
    /// or playback leaves the steady playing state.
    private func runControlsAutoHide() async {
        controlsIdleHidden = false
        guard !controlsArePinned else { return }
        do {
            try await Task.sleep(for: PlayerControlsVisibilityPolicy.idleTimeout)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        controlsIdleHidden = true
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
