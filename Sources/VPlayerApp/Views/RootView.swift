// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI

struct RootView: View {
    private let dependencies: AppDependencies
    @State private var model: AppModel

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: AppModel(
            repository: dependencies.repository,
            refresh: dependencies.refresh,
            libraryChanges: dependencies.libraryChanges
        ))
    }

    var body: some View {
        @Bindable var model = model

        TabView {
            ChannelBrowserView(model: model)
                .tabItem {
                    Label("频道", systemImage: "play.rectangle")
                }

            SourceProfilesView(model: model)
                .tabItem {
                    Label("数据源", systemImage: "externaldrive.connected.to.line.below")
                }

            PlaybackSettingsView(settings: dependencies.playbackSettings)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
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
            PlaybackPlaceholderView(request: request) {
                model.dismissPlayback()
            }
        }
    }
}
