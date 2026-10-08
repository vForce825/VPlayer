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
    @State private var showsSettings = false
    @State private var controls = PlayerControlsVisibilityState(mode: .pinned)
    private var model: FullScreenPlayerViewModel { session.model }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            IOSPlaybackHostView(session: session).ignoresSafeArea()
            Color.clear.contentShape(Rectangle()).onTapGesture { controls.apply(.userInteraction) }
            status
            VStack {
                HStack {
                    Button { session.close(); onClose() } label: {
                        Image(systemName: "chevron.down").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("关闭播放").accessibilityIdentifier("player-back")
                    Text(session.presentation.request.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button { session.pictureInPicture.start() } label: {
                        Image(systemName: "pip.enter").frame(width: 44, height: 44)
                    }
                    .disabled(!session.pictureInPicture.isPossible)
                    .accessibilityLabel("画中画").accessibilityIdentifier("player-pip")
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape").frame(width: 44, height: 44)
                    }.accessibilityLabel("播放设置").accessibilityIdentifier("player-settings")
                }
                .padding(.horizontal, 8).background(.black.opacity(0.55))
                Spacer()
                if controls.isVisible {
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
                            controls.apply(.userInteraction)
                            model.togglePause()
                        } label: {
                            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                                .font(.title).frame(width: 60, height: 52)
                        }
                        .accessibilityLabel(model.isPaused ? "播放" : "暂停")
                        .accessibilityIdentifier("player-play-pause")
                    }
                    .padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.bottom, 16)
                }
            }
            .foregroundStyle(.white)
        }
        .accessibilityIdentifier("player-full-screen")
        #if DEBUG
        .onAppear { IOSPlaybackRouteDiagnostics.record("cover-appeared") }
        .onDisappear { IOSPlaybackRouteDiagnostics.record("cover-disappeared") }
        #endif
        .task { session.start() }
        .task(id: controls.key) {
            let key = controls.key
            guard PlayerControlsAutoHidePolicy.shouldSleep(for: key) else { return }
            do { try await Task.sleep(for: PlayerControlsVisibilityPolicy.idleTimeout) }
            catch { return }
            guard !Task.isCancelled else { return }
            controls.apply(.timeoutCompleted(key))
        }
        .onChange(of: model.state, initial: true) { _, state in
            controls.apply(.stateChanged(PlayerControlsVisibilityPolicy.mode(for: state)))
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                List {
                    Section("视频缓冲") { PlaybackBufferRows(playback: session.settings) }
                    Section("反交错缓冲") { DeinterlaceBufferRows(playback: session.settings) }
                }
                .navigationTitle("播放设置")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsSettings = false }
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
                    Button("重试") { model.retry() }.accessibilityIdentifier("player-retry")
                }
            }
            .padding(24).foregroundStyle(.white)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        case .playing, .paused, .stopped: EmptyView()
        }
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active &&
            PlaybackIdleTimerPolicy.isDisabled(for: model.state)
    }
}
