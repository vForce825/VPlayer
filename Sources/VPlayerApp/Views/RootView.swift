// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI

struct RootView: View {
    private enum InitialLibraryState {
        case loading
        case ready
        case failed
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
            // Every repository call fails in this state, so an explicit
            // explanation beats a generic retry alert on each screen.
            ContentUnavailableView(
                "无法打开本地资料库",
                systemImage: "externaldrive.badge.xmark",
                description: Text("设备存储不可用，可能是空间不足或权限受限。请释放存储空间后重新启动 VPlayer。")
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
            case .failed:
                VStack(spacing: 28) {
                    ContentUnavailableView(
                        "无法载入资料库",
                        systemImage: "arrow.clockwise.circle",
                        description: Text("本地资料暂时无法读取，请重试。")
                    )
                    Button("重试") {
                        initialLibraryAttempt += 1
                    }
                    .accessibilityIdentifier("library.retry")
                }
            }
        }
        .task(id: initialLibraryAttempt) {
            initialLibraryState = .loading
            let opened = await dependencies.openInitialLibrary(using: model)
            guard !Task.isCancelled else { return }
            // A failed repository read also raises the model's generic alert.
            // Bootstrap owns this persistent retry screen, so avoid presenting
            // two competing failure affordances; successful retry also clears
            // any stale alert from the preceding attempt.
            model.dismissAlert()
            initialLibraryState = opened ? .ready : .failed
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
                request: request,
                engine: dependencies.playbackEngine,
                presentationProvider: dependencies.playbackPresentationProvider,
                metricsProvider: dependencies.playbackMetricsProvider,
                acceptanceMetricsEnabled: dependencies.exposesAcceptanceMetrics,
                acceptanceStateEnabled: dependencies.exposesAcceptanceState,
                settings: dependencies.playbackSettings
            ) {
                model.dismissPlayback()
            }
        }
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
