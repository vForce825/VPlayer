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
    @State private var sessionBox = IOSActivePlaybackSessionBox()
    @State private var libraryReady = false
    @State private var libraryFailure: String?
    @State private var loadAttempt = 0
    private var session: IOSPlaybackSession? { sessionBox.session }
    private var miniBarSession: IOSPlaybackSession? {
        guard let active = session, !active.isClosing, !active.isFullScreenPresented else { return nil }
        return active
    }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: AppModel(repository: dependencies.repository,
            refresh: dependencies.refresh, libraryChanges: dependencies.libraryChanges))
    }
    var body: some View {
        Group {
            if libraryReady {
                TabView {
                    IOSChannelBrowserView(
                        model: model,
                        browsingSettings: dependencies.channelBrowsingSettings,
                        onSelectChannel: selectFromBrowser
                    )
                        .tabItem { Label("频道", systemImage: "play.rectangle") }
                    IOSSourceProfilesView(model: model)
                        .tabItem { Label("播放列表", systemImage: "play.square.stack") }
                    IOSSettingsView(playback: dependencies.playbackSettings,
                                    channelBrowsing: dependencies.channelBrowsingSettings)
                        .tabItem { Label("设置", systemImage: "gearshape") }
                }
                .tabViewBottomAccessory(isEnabled: miniBarSession != nil) {
                    if let active = miniBarSession {
                        IOSMiniPlayerBar(session: active) {
                            active.close()
                            model.dismissPlayback()
                        }
                    }
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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.maintainProgrammeWindow()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                dependencies.foregroundRefreshDriver.activate()
            case .inactive, .background:
                dependencies.foregroundRefreshDriver.deactivate()
                dependencies.backgroundRefreshRegistrar.scheduleNext()
            @unknown default:
                dependencies.foregroundRefreshDriver.deactivate()
                dependencies.backgroundRefreshRegistrar.scheduleNext()
            }
        }
        .onChange(of: reducedResourceUsage, initial: true) { _, value in
            dependencies.foregroundRefreshDriver.setPrefersReducedResourceUsage(value)
            dependencies.backgroundRefreshRegistrar.setPrefersReducedResourceUsage(value)
        }
        .onChange(of: currentPlayerPresentation) { _, presentation in
            if let presentation { session?.updatePresentation(presentation) }
        }
        .onChange(of: model.presentedPlaybackRequest) { _, request in replaceSession(for: request) }
        .onChange(of: session?.isClosing) { _, closing in
            if closing == true { model.dismissPlayback() }
        }
        .alert(model.alertTitle, isPresented: Binding(
            get: { model.alertMessage != nil && session?.isFullScreenPresented != true },
            set: { if !$0 { model.dismissAlert() } }
        )) {
            Button("知道了") { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .fullScreenCover(isPresented: fullScreenBinding) {
            Group {
                if let active = session {
                    IOSFullScreenPlayerView(session: active, library: model,
                        browsingSettings: dependencies.channelBrowsingSettings) {
                            guard model.presentedPlaybackRequest?.id == active.id else { return }
                            model.dismissPlayback()
                        }
                        .id(active.id)
                }
            }
            .overlay(alignment: .topLeading) {
                IOSPlaybackOrientationPreference(playback: dependencies.playbackSettings, sessionBox: sessionBox)
                    .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
            .interactiveDismissDisabled()
            #if DEBUG
            .overlay(alignment: .topLeading) { routeProbe(identifier: "ios.playback.route.presented") }
            #endif
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { routeProbe() }
        #endif
    }
    #if DEBUG
    @ViewBuilder private func routeProbe(identifier: String = "ios.playback.route") -> some View {
        if IOSPlaybackRouteDiagnostics.isEnabled {
            IOSPlaybackRouteProbe(identifier: identifier) {
                IOSPlaybackRouteDiagnostics.snapshot(request: model.presentedPlaybackRequest,
                    session: session, isLoading: model.isLoading)
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
    }
    #endif
    private var currentPlayerPresentation: PlayerChannelPresentation? {
        guard let request = model.presentedPlaybackRequest else { return nil }
        let channel = model.channels.first { $0.id == request.channelID }
        return PlayerChannelPresentation(
            request: request, logoURL: channel?.logoURL,
            programmes: model.programmesByChannelID[request.channelID, default: []]
        )
    }

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
    private func selectFromBrowser(_ channel: Channel) {
        let action = IOSChannelBrowserSelectionPolicy.resolve(
            channel: channel,
            activeSessionProfileID: session?.presentation.request.sourceProfileID,
            activeSessionChannelID: session?.presentation.request.channelID,
            isSessionClosing: session?.isClosing ?? false,
            isFullScreenPresented: session?.isFullScreenPresented ?? false,
            hasPresentedPlaybackRequest: model.presentedPlaybackRequest != nil
        )
        switch action {
        case .restoreFullScreen:
            session?.showFullScreen()
        case let .rejectPreservingPlayback(message):
            model.presentPlaybackRejection(message)
        case .selectInModel:
            model.select(channel: channel)
        }
    }

    private func replaceSession(for request: PlaybackRequest?) {
        #if DEBUG
        IOSPlaybackRouteDiagnostics.record("request-change:\(request != nil)")
        #endif
        guard session?.id != request?.id else { return }
        let previous = session
        if let request {
            let channel = model.channels.first { $0.id == request.channelID }
            let next = IOSPlaybackSession(presentation: PlayerChannelPresentation(request: request,
                logoURL: channel?.logoURL,
                programmes: model.programmesByChannelID[request.channelID, default: []]),
                dependencies: dependencies)
            let appModel = model
            next.onPrepareForFullScreenRestore = { [weak appModel] in
                appModel?.dismissAlert()
            }
            sessionBox.session = next
        } else { sessionBox.session = nil }
        #if DEBUG
        IOSPlaybackRouteDiagnostics.replaceSession(id: session?.id)
        #endif
        previous?.close()
    }
}

enum IOSMiniPlayerAction: Equatable {
    case playPause(isPaused: Bool)
    case retry
    case loading
    case none

    static func resolve(
        state: PlaybackState,
        isPaused: Bool,
        canControlPlayback: Bool
    ) -> Self {
        if case let .failed(failure) = state {
            return PlayerFailureActionPolicy.showsRetry(for: failure) ? .retry : .none
        }
        if canControlPlayback {
            return .playPause(isPaused: isPaused)
        }
        switch state {
        case .idle, .preparing, .buffering, .recovering:
            return .loading
        case .playing, .paused, .stopped, .failed:
            return .none
        }
    }
}

private struct IOSMiniPlayerBar: View {
    let session: IOSPlaybackSession
    let onClose: () -> Void

    private var isFailed: Bool {
        if case .failed = session.model.state { return true }
        return false
    }

    private var action: IOSMiniPlayerAction {
        IOSMiniPlayerAction.resolve(
            state: session.model.state,
            isPaused: session.model.isPaused,
            canControlPlayback: session.model.canControlPlayback
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { session.showFullScreen() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "play.rectangle")
                        .foregroundStyle(isFailed ? .orange : .primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.presentation.request.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if isFailed {
                            Text("播放失败")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if DEBUG
            .accessibilityIdentifier("player-mini-resume")
            #endif

            switch action {
            case let .playPause(isPaused):
                Button { session.model.togglePause() } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPaused ? "播放" : "暂停")
            case .retry:
                Button { session.model.retry() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重试")
                .accessibilityIdentifier("player-mini-retry")
            case .loading:
                ProgressView()
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("正在加载播放")
            case .none:
                EmptyView()
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭播放")
            .accessibilityIdentifier("player-mini-close")
        }
        .padding(.horizontal, 12)
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
    let identifier: String
    let snapshot: @MainActor () -> String
    func makeUIView(context: Context) -> IOSPlaybackRouteProbeView {
        let view = IOSPlaybackRouteProbeView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
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
