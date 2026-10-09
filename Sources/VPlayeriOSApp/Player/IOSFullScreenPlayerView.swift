// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import SwiftUI
import UIKit
import VPlayerPlayback

struct IOSFullScreenPlayerView: View {
    @Bindable var session: IOSPlaybackSession
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
    @State private var showsSettings = false
    @State private var controls = IOSPlayerControlsVisibility()
    private var model: FullScreenPlayerViewModel { session.model }
    private var allowsAutoHide: Bool {
        IOSPlayerControlsVisibility.allowsAutoHide(state: model.state,
            isPresentingSettings: showsSettings, isVoiceOverRunning: isVoiceOverRunning,
            isSceneActive: scenePhase == .active,
            hasPlaybackMessage: session.pictureInPicture.message != nil)
    }
    // Pin immediately when presentation conditions change, including before
    // onChange invalidates a previously scheduled timeout.
    private var areControlsVisible: Bool { controls.isVisible || !allowsAutoHide }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            IOSPlaybackHostView(session: session).ignoresSafeArea()
            // This is a sibling behind the controls, not a gesture on their
            // ancestor: a transport/settings tap cannot also toggle the bars.
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .onTapGesture { controls.backgroundTapped() }
                .accessibilityHidden(true)
            status
            if areControlsVisible {
                VStack {
                    HStack {
                        Button { close() } label: {
                            Image(systemName: "chevron.down").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("关闭播放").accessibilityIdentifier("player-back")
                        Text(session.presentation.request.title).font(.headline).lineLimit(1)
                        Spacer()
                        Button {
                            controls.userInteracted()
                            session.pictureInPicture.start()
                        } label: {
                            Image(systemName: "pip.enter").frame(width: 44, height: 44)
                        }
                        .disabled(!session.pictureInPicture.isPossible)
                        .accessibilityLabel("画中画").accessibilityIdentifier("player-pip")
                        Button {
                            controls.userInteracted()
                            showsSettings = true
                        } label: {
                            Image(systemName: "gearshape").frame(width: 44, height: 44)
                        }.accessibilityLabel("播放设置").accessibilityIdentifier("player-settings")
                    }
                    .padding(.horizontal, 8).background(.black.opacity(0.55))
                    .contentShape(Rectangle())
                    .onTapGesture { controls.userInteracted() }
                    Spacer()
                    VStack(spacing: 12) {
                        if let message = session.pictureInPicture.message {
                            Text(message).font(.caption).accessibilityIdentifier("player-pip-message")
                        }
                        Text(PlaybackMediaInformationPresentation(information: model.mediaInformation).visualText)
                            .font(.caption)
                        if let output = PlaybackMediaInformationPresentation(information: model.mediaInformation).airPlayOutputText {
                            Text(output).font(.caption)
                        }
                        Button {
                            controls.userInteracted()
                            model.togglePause()
                        } label: {
                            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                                .font(.title).frame(width: 60, height: 52)
                        }
                        .accessibilityLabel(model.isPaused ? "播放" : "暂停")
                        .accessibilityIdentifier("player-play-pause")
                    }
                    .padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                    .onTapGesture { controls.userInteracted() }
                    .padding(.bottom, 16)
                }
                .foregroundStyle(.white)
            }
        }
        .toolbarVisibility(areControlsVisible ? .visible : .hidden, for: .statusBar)
        // Preserve individual control labels/actions. VoiceOver pins the bars,
        // and its escape gesture remains an explicit, accessible close action.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-full-screen")
        .accessibilityAction(.escape) { close() }
        #if DEBUG
        .accessibilityValue(IOSPlaybackRouteDiagnostics.isEnabled ? "session=\(session.id.uuidString)" : "")
        .onAppear { IOSPlaybackRouteDiagnostics.record("cover-appeared") }
        .onDisappear { IOSPlaybackRouteDiagnostics.record("cover-disappeared") }
        #endif
        .task { session.start() }
        .task(id: controls.timeoutToken) {
            guard let token = controls.timeoutToken else { return }
            do { try await Task.sleep(for: IOSPlayerControlsVisibility.idleTimeout) }
            catch { return }
            guard !Task.isCancelled else { return }
            controls.timeoutCompleted(token)
        }
        .onChange(of: allowsAutoHide, initial: true) { _, allowed in
            controls.setAutoHideAllowed(allowed)
        }
        .onAppear { controls.setAutoHideAllowed(allowsAutoHide) }
        .onChange(of: model.state, initial: true) { _, _ in updateIdleTimer() }
        .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
        .onDisappear {
            controls.setAutoHideAllowed(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                List {
                    Section("视频缓冲") { PlaybackBufferRows(playback: session.settings) }
                    Section("反交错缓冲") { DeinterlaceBufferRows(playback: session.settings) }
                }
                .navigationTitle("播放设置")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            controls.userInteracted()
                            showsSettings = false
                        }
                        .accessibilityIdentifier("player.settings.done")
                    }
                }
            }
        }
    }
    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle, .preparing: ProgressView("正在准备播放…").tint(.white)
        case .buffering: ProgressView("正在缓冲…").tint(.white)
        case .recovering: ProgressView("正在恢复播放…").tint(.white)
        case let .failed(failure):
            VStack(spacing: 16) {
                Text(failure.userMessage)
                if PlayerFailureActionPolicy.showsRetry(for: failure) {
                    Button("重试") {
                        controls.userInteracted()
                        model.retry()
                    }.accessibilityIdentifier("player-retry")
                }
            }
            .padding(24).foregroundStyle(.white)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        case .playing, .paused, .stopped: EmptyView()
        }
    }
    private func close() {
        session.close()
        onClose()
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active &&
            PlaybackIdleTimerPolicy.isDisabled(for: model.state)
    }
}

/// iOS presentation-only state. The view owns a single cancellation-aware task;
/// its token also rejects late completions across hide/show and pinned periods.
/// Playback/session ownership and the tvOS visibility policy are independent.
struct IOSPlayerControlsVisibility: Equatable, Sendable {
    static let idleTimeout = Duration.seconds(3)
    private(set) var isVisible = true
    private var autoHideAllowed = false
    private var revision: UInt64 = 0
    var timeoutToken: UInt64? { autoHideAllowed && isVisible ? revision : nil }

    static func allowsAutoHide(state: PlaybackState, isPresentingSettings: Bool,
                              isVoiceOverRunning: Bool, isSceneActive: Bool,
                              hasPlaybackMessage: Bool) -> Bool {
        guard case .playing = state else { return false }
        return !isPresentingSettings && !isVoiceOverRunning && isSceneActive && !hasPlaybackMessage
    }

    mutating func setAutoHideAllowed(_ allowed: Bool) {
        guard autoHideAllowed != allowed else { return }
        autoHideAllowed = allowed
        isVisible = true
        revision &+= 1
    }

    mutating func backgroundTapped() {
        guard autoHideAllowed else { return }
        isVisible.toggle()
        revision &+= 1
    }

    mutating func userInteracted() {
        isVisible = true
        revision &+= 1
    }

    mutating func timeoutCompleted(_ token: UInt64) {
        guard timeoutToken == token else { return }
        isVisible = false
    }
}
