// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct FullScreenPlayerView: View {
    private enum FailureControl: Hashable {
        case retry
        case back
        case settings
    }

    @State private var model: FullScreenPlayerViewModel
    @State private var showsSettings = false
    @State private var isClosing = false
    #if DEBUG
    @State private var acceptanceMetricsJSON = "{}"
    #endif
    @FocusState private var failureFocus: FailureControl?
    private let settings: PlaybackSettingsStore
    private let metricsProvider: AppDependencies.PlaybackMetricsProvider
    private let acceptanceMetricsEnabled: Bool
    private let onDismiss: () -> Void

    init(
        request: PlaybackRequest,
        engine: any PlaybackEngine,
        presentationProvider: @escaping FullScreenPlayerViewModel.PresentationProvider,
        metricsProvider: @escaping AppDependencies.PlaybackMetricsProvider,
        acceptanceMetricsEnabled: Bool,
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
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack {
            if let context = model.presentationContext {
                MetalPlayerView(context: context)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("player-full-screen")
                .allowsHitTesting(false)
                .focusable(false)

            #if DEBUG
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
            }
        }
        .task { model.start() }
        #if DEBUG
        .task { await publishAcceptanceMetrics() }
        #endif
        .onDisappear { Task { await model.stop() } }
        .onPlayPauseCommand(perform: model.togglePause)
        .onExitCommand(perform: close)
        .sheet(isPresented: $showsSettings) {
            PlaybackSettingsView(
                settings: settings,
                onAlgorithmChange: model.selectAlgorithm
            )
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

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        Task {
            await model.stop()
            onDismiss()
        }
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
