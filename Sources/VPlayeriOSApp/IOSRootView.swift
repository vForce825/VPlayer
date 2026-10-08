// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import VPlayerCore
import VPlayerPlayback

struct IOSRootView: View {
    let dependencies: AppDependencies
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResourceUsage
    @State private var model: AppModel
    @State private var session: IOSPlaybackSession?
    @State private var libraryReady = false
    @State private var libraryFailure: String?
    @State private var loadAttempt = 0

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: AppModel(repository: dependencies.repository,
            refresh: dependencies.refresh, libraryChanges: dependencies.libraryChanges))
    }
    var body: some View {
        Group {
            if libraryReady {
                TabView {
                    IOSChannelBrowserView(model: model, browsingSettings: dependencies.channelBrowsingSettings)
                        .tabItem { Label("频道", systemImage: "play.rectangle") }
                    IOSSourceProfilesView(model: model)
                        .tabItem { Label("播放列表", systemImage: "play.square.stack") }
                    IOSSettingsView(playback: dependencies.playbackSettings,
                                    channelBrowsing: dependencies.channelBrowsingSettings)
                        .tabItem { Label("设置", systemImage: "gearshape") }
                }
            } else if let libraryFailure {
                VStack(spacing: 20) {
                    ContentUnavailableView("无法载入资料库", systemImage: "arrow.clockwise.circle",
                        description: Text(libraryFailure))
                    Button("重试") { loadAttempt += 1 }
                }
            } else { ProgressView("正在载入资料库…") }
        }
        .task(id: loadAttempt) {
            libraryFailure = nil
            let success = await dependencies.openInitialLibrary(using: model)
            guard !Task.isCancelled else { return }
            libraryReady = success
            if !success { libraryFailure = model.alertMessage ?? "本地资料暂时无法读取，请重试。" }
            model.dismissAlert()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { dependencies.foregroundRefreshDriver.activate() }
            else { dependencies.foregroundRefreshDriver.deactivate() }
        }
        .onChange(of: reducedResourceUsage, initial: true) { _, value in
            dependencies.foregroundRefreshDriver.setPrefersReducedResourceUsage(value)
        }
        .onChange(of: model.presentedPlaybackRequest) { _, request in replaceSession(for: request) }
        .alert(model.alertTitle, isPresented: Binding(get: { model.alertMessage != nil },
            set: { if !$0 { model.dismissAlert() } })) {
            Button("知道了") { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .fullScreenCover(item: $session) { active in
            IOSFullScreenPlayerView(session: active) { model.dismissPlayback() }
                .interactiveDismissDisabled()
        }
    }
    private func replaceSession(for request: PlaybackRequest?) {
        guard session?.id != request?.id else { return }
        let previous = session
        if let request {
            let channel = model.channels.first { $0.id == request.channelID }
            session = IOSPlaybackSession(presentation: PlayerChannelPresentation(request: request,
                logoURL: channel?.logoURL,
                programmes: model.programmesByChannelID[request.channelID, default: []]),
                dependencies: dependencies)
        } else { session = nil }
        previous?.close()
    }
}
