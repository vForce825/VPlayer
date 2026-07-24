// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI

struct RootView: View {
    private let dependencies: AppDependencies
    private let focusPolicy: AcceptanceFocusPolicy
    @State private var model: AppModel
    @State private var selectedTab: AcceptanceFocusPolicy.RootTab

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

        return TabView(selection: $selectedTab) {
            ChannelBrowserView(model: model)
                .tabItem {
                    Label("频道", systemImage: "play.rectangle")
                }
                .tag(AcceptanceFocusPolicy.RootTab.channels)

            SourceProfilesView(model: model)
                .tabItem {
                    Label("数据源", systemImage: "externaldrive.connected.to.line.below")
                }
                .tag(AcceptanceFocusPolicy.RootTab.sources)

            PlaybackSettingsView(settings: dependencies.playbackSettings)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(AcceptanceFocusPolicy.RootTab.settings)
        }
        .task {
            await dependencies.prepare()
            guard !Task.isCancelled else { return }
            await model.reload()
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
}
