// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
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
        .onChange(of: session?.isClosing) { _, closing in
            if closing == true { model.dismissPlayback() }
        }
        .safeAreaInset(edge: .bottom) {
            if let active = session, !active.isClosing, !active.isFullScreenPresented {
                HStack(spacing: 14) {
                    Button { active.showFullScreen() } label: {
                        Label(active.presentation.request.title, systemImage: "play.rectangle")
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #if DEBUG
                    .accessibilityIdentifier("player-mini-resume")
                    #endif
                    Button { active.model.togglePause() } label: {
                        Image(systemName: active.model.isPaused ? "play.fill" : "pause.fill")
                    }.accessibilityLabel(active.model.isPaused ? "播放" : "暂停")
                    Button { active.close(); model.dismissPlayback() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭播放")
                }
                .padding().background(.regularMaterial)
            }
        }
        .alert(model.alertTitle, isPresented: Binding(get: { model.alertMessage != nil },
            set: { if !$0 { model.dismissAlert() } })) {
            Button("知道了") { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .fullScreenCover(isPresented: fullScreenBinding) {
            if let active = session {
                IOSFullScreenPlayerView(session: active) { model.dismissPlayback() }
                    .id(active.id)
                    .interactiveDismissDisabled()
                    #if DEBUG
                    .overlay(alignment: .topLeading) { routeProbe }
                    #endif
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { routeProbe }
        #endif
    }
    #if DEBUG
    @ViewBuilder private var routeProbe: some View {
        if IOSPlaybackRouteDiagnostics.isEnabled {
            IOSPlaybackRouteProbe {
                IOSPlaybackRouteDiagnostics.snapshot(request: model.presentedPlaybackRequest,
                    session: session, isLoading: model.isLoading)
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
    }
    #endif
    private var fullScreenBinding: Binding<Bool> {
        let owner = session
        return Binding(get: {
            let value = owner?.isFullScreenPresented ?? false
            #if DEBUG
            IOSPlaybackRouteDiagnostics.readBinding(ownerID: owner?.id, value: value)
            #endif
            return value
        }, set: { value in
            #if DEBUG
            IOSPlaybackRouteDiagnostics.record("binding-write:\(value):current=\(session?.id == owner?.id)")
            #endif
            guard session?.id == owner?.id else { return }
            owner?.isFullScreenPresented = value
        })
    }
    private func replaceSession(for request: PlaybackRequest?) {
        #if DEBUG
        IOSPlaybackRouteDiagnostics.record("request-change:\(request != nil)")
        #endif
        guard session?.id != request?.id else { return }
        let previous = session
        if let request {
            let channel = model.channels.first { $0.id == request.channelID }
            session = IOSPlaybackSession(presentation: PlayerChannelPresentation(request: request,
                logoURL: channel?.logoURL,
                programmes: model.programmesByChannelID[request.channelID, default: []]),
                dependencies: dependencies)
        } else { session = nil }
        #if DEBUG
        IOSPlaybackRouteDiagnostics.replaceSession(id: session?.id)
        #endif
        previous?.close()
    }
}

#if DEBUG
/// Test-only values, deliberately not observable: inspecting a failed route must
/// not add SwiftUI dependencies or cause a second presentation attempt.
@MainActor
enum IOSPlaybackRouteDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-ui-playback-route-diagnostics") &&
        AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments).mode == .seededFixture
    private static var events: [String] = []
    private static var currentSessionID: UUID?
    private static var bindingReads = 0
    private static var staleBindingReads = 0
    private static var lastBindingValue = false
    private static var lastBindingOwnerMatches = true

    static func record(_ event: @autoclosure () -> String) {
        guard isEnabled else { return }
        events.append(event())
        if events.count > 12 { events.removeFirst(events.count - 12) }
    }
    static func replaceSession(id: UUID?) {
        guard isEnabled else { return }
        currentSessionID = id
        record("session-replaced:\(id != nil)")
    }
    static func readBinding(ownerID: UUID?, value: Bool) {
        guard isEnabled else { return }
        bindingReads = min(bindingReads + 1, 1_000_000)
        lastBindingOwnerMatches = ownerID == currentSessionID
        if !lastBindingOwnerMatches { staleBindingReads = min(staleBindingReads + 1, 1_000_000) }
        lastBindingValue = value
    }
    static func snapshot(request: PlaybackRequest?, session: IOSPlaybackSession?, isLoading: Bool) -> String {
        "request=\(request != nil) session=\(session != nil) matching=\(request?.id == session?.id) " +
            "loading=\(isLoading) closing=\(session?.isClosing ?? false) " +
            "fullScreen=\(session?.isFullScreenPresented ?? false) " +
            "binding=\(lastBindingValue) ownerMatches=\(lastBindingOwnerMatches) " +
            "reads=\(bindingReads) staleReads=\(staleBindingReads) " +
            "events=[\(events.joined(separator: ","))]"
    }
}

/// The getter runs only when accessibility queries it, outside SwiftUI's body
/// evaluation. The closure reads the root's live State storage, not a session
/// captured while the initial library screen is loading.
private struct IOSPlaybackRouteProbe: UIViewRepresentable {
    let snapshot: @MainActor () -> String
    func makeUIView(context: Context) -> IOSPlaybackRouteProbeView {
        let view = IOSPlaybackRouteProbeView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "ios.playback.route"
        view.accessibilityLabel = "Playback route diagnostics"
        view.snapshot = snapshot
        return view
    }
    func updateUIView(_ view: IOSPlaybackRouteProbeView, context: Context) {
        view.snapshot = snapshot
    }
    static func dismantleUIView(_ view: IOSPlaybackRouteProbeView, coordinator: ()) {
        view.snapshot = nil
    }
}

private final class IOSPlaybackRouteProbeView: UIView {
    var snapshot: (@MainActor () -> String)?
    override var accessibilityValue: String? {
        get {
            let statusBar: String
            if let manager = window?.windowScene?.statusBarManager {
                statusBar = manager.isStatusBarHidden ? "hidden" : "visible"
            } else {
                statusBar = "unknown"
            }
            return snapshot.map { $0() + " statusBar=\(statusBar)" }
        }
        set {}
    }
}
#endif
