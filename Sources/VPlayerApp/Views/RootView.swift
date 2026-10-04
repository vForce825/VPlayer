// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerPlayback

struct RootView: View {
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    private enum InitialLibraryState {
        case loading
        case ready
        case failed(String)
    }

    private let dependencies: AppDependencies
    private let focusPolicy: AcceptanceFocusPolicy
    @State private var model: AppModel
    @State private var selectedTab: AcceptanceFocusPolicy.RootTab
    @State private var initialLibraryState = InitialLibraryState.loading
    @State private var initialLibraryAttempt = 0

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let focusPolicy = AcceptanceFocusPolicy.current()
        self.focusPolicy = focusPolicy
        _model = State(initialValue: AppModel(
            repository: dependencies.repository,
            refresh: dependencies.refresh,
            libraryChanges: dependencies.libraryChanges
        ))
        _selectedTab = State(initialValue: focusPolicy.initialRootTab)
    }

    var body: some View {
        if dependencies.isLibraryAvailable {
            libraryContent
        } else {
            let detail = dependencies.libraryUnavailableDiagnostic.map { "\n\($0.summary)" } ?? ""
            ContentUnavailableView(
                "无法打开本地资料库",
                systemImage: "externaldrive.badge.xmark",
                description: Text("本地资料库依赖不可用，请重试或重新启动 VPlayer。\(detail)")
            )
            .accessibilityIdentifier("library.unavailable")
        }
    }

    private var libraryContent: some View {
        @Bindable var model = model

        return Group {
            switch initialLibraryState {
            case .loading:
                ProgressView("正在载入资料库…")
                    .accessibilityIdentifier("library.loading")
            case .ready:
                libraryTabs
            case .failed(let message):
                VStack(spacing: 28) {
                    ContentUnavailableView(
                        "无法载入资料库",
                        systemImage: "arrow.clockwise.circle",
                        description: Text(message)
                    )
                    Button("重试") {
                        initialLibraryAttempt += 1
                    }
                    .accessibilityIdentifier("library.retry")
                }
            }
        }
        .onChange(of: prefersReducedResourceUsage, initial: true) { _, preferred in
            dependencies.foregroundRefreshDriver.setPrefersReducedResourceUsage(preferred)
            dependencies.backgroundRefreshRegistrar.setPrefersReducedResourceUsage(preferred)
        }
        .task(id: initialLibraryAttempt) {
            initialLibraryState = .loading
            let opened = await dependencies.openInitialLibrary(using: model)
            guard !Task.isCancelled else { return }
            // 原始原因先转交失败页，再关闭对应的一次性提示。
            let failureMessage = model.alertMessage ?? "本地资料暂时无法读取，请重试。"
            model.dismissAlert()
            initialLibraryState = opened ? .ready : .failed(failureMessage)
        }
        .alert(model.alertTitle, isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissAlert()
                }
            }
        )) {
            Button("知道了") {
                model.dismissAlert()
            }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .fullScreenCover(item: $model.presentedPlaybackRequest) { request in
            FullScreenPlayerView(
                channelPresentation: playerChannelPresentation(for: request),
                engine: dependencies.playbackEngine,
                presentationController: dependencies.playbackPresentationController,
                presentationProvider: dependencies.playbackPresentationProvider,
                mediaInformationProvider: dependencies.playbackMediaInformationProvider,
                metricsProvider: dependencies.playbackMetricsProvider,
                acceptanceMetricsEnabled: dependencies.exposesAcceptanceMetrics,
                acceptanceStateEnabled: dependencies.exposesAcceptanceState,
                settings: dependencies.playbackSettings,
                nowPlaying: dependencies.nowPlaying
            ) {
                model.dismissPlayback()
            }
        }
    }

    private func playerChannelPresentation(
        for request: PlaybackRequest
    ) -> PlayerChannelPresentation {
        let channel = model.channels.first { $0.id == request.channelID }
        return PlayerChannelPresentation(
            request: request,
            logoURL: channel?.logoURL,
            programmes: model.programmesByChannelID[request.channelID, default: []]
        )
    }

    private var libraryTabs: some View {
        @Bindable var model = model

        return TabView(selection: $selectedTab) {
            ChannelBrowserView(
                model: model,
                browsingSettings: dependencies.channelBrowsingSettings
            )
                .tabItem {
                    Label("频道", systemImage: "play.rectangle")
                }
                .tag(AcceptanceFocusPolicy.RootTab.channels)

            SourceProfilesView(model: model)
                .tabItem {
                    Label("播放列表", systemImage: "play.square.stack")
                }
                .tag(AcceptanceFocusPolicy.RootTab.sources)

            SettingsView(
                playback: dependencies.playbackSettings,
                channelBrowsing: dependencies.channelBrowsingSettings
            )
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(AcceptanceFocusPolicy.RootTab.settings)
        }
    }
}
