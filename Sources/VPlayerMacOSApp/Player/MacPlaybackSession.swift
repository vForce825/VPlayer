// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI
import VPlayerPlayback

@MainActor
@Observable
final class MacPlaybackSession {
    let overlay = MacPlayerOverlayState()
    let model: FullScreenPlayerViewModel
    let host: PlaybackPresentationHostController
    let mount: PlaybackPresentationHostMount
    let pictureInPicture: MacPictureInPictureCoordinator
    private(set) var presentation: PlayerChannelPresentation
    var onStopped: (() -> Void)?
    private(set) var isClosing = false
    private var hasStarted = false
    private var activity: NSObjectProtocol?
    private var closeTask: Task<Void, Never>?

    init(presentation: PlayerChannelPresentation, dependencies: AppDependencies) {
        self.presentation = presentation
        let mount = PlaybackPresentationHostMount()
        self.mount = mount
        host = PlaybackPresentationHostController()
        model = FullScreenPlayerViewModel(request: presentation.request, engine: dependencies.playbackEngine,
            presentationController: dependencies.playbackPresentationController,
            presentationStreamProvider: dependencies.playbackPresentationProvider,
            presentationMount: mount, mediaInformationProvider: dependencies.playbackMediaInformationProvider,
            settings: dependencies.playbackSettings, nowPlaying: dependencies.nowPlaying, channelPresentation: presentation)
        pictureInPicture = MacPictureInPictureCoordinator(target: model)
        host.onPresentationMounted = { [weak self] presentation, _ in
            guard let self, !self.isClosing else { return }
            guard let view = self.host.children.first?.view else { return }
            self.pictureInPicture.install(videoView: view, identity: presentation.identity)
        }
        host.onPresentationUnmounted = { [weak self] identity in self?.pictureInPicture.retire(identity: identity) }
        pictureInPicture.onRestore = { [weak self] completion in
            guard let self, !self.isClosing else { completion(false); return }
            NSApp.activate()
            self.host.view.window?.makeKeyAndOrderFront(nil)
            completion(self.host.view.window != nil)
        }
        mount.connect(to: host)
    }
    func start() {
        guard !hasStarted, !isClosing else { return }
        hasStarted = true
        model.start()
        observePlaybackState()
    }
    func updatePresentation(_ presentation: PlayerChannelPresentation) {
        guard !isClosing, presentation.request.id == model.request.id else { return }
        self.presentation = presentation
        model.updateChannelPresentation(presentation)
    }
    func togglePictureInPicture() {
        if pictureInPicture.isActive { pictureInPicture.stopForRestoration() }
        else { pictureInPicture.start() }
    }
    private func observePlaybackState() {
        guard !isClosing else { return }
        if model.hasStoppedCurrentRequest {
            onStopped?()
            Task { await close() }
            return
        }
        withObservationTracking {
            pictureInPicture.update(state: model.state, paused: model.isPaused)
            updateActivity()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlaybackState() }
        }
    }
    private func updateActivity() {
        let playing: Bool
        switch model.state { case .playing: playing = true; default: playing = false }
        if playing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "正在播放直播频道")
        } else if !playing, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        isClosing = true
        overlay.cancel()
        onStopped = nil
        pictureInPicture.close()
        host.onPresentationMounted = nil
        host.onPresentationUnmounted = nil
        mount.detachAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        let model = model
        let task = Task { await model.stop() }
        closeTask = task
        await task.value
    }
}

struct MacPlaybackHostView: NSViewControllerRepresentable {
    let session: MacPlaybackSession
    func makeNSViewController(context: Context) -> PlaybackPresentationHostController {
        session.mount.connect(to: session.host)
        return session.host
    }
    func updateNSViewController(_ controller: PlaybackPresentationHostController, context: Context) {
        session.mount.connect(to: controller)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: PlaybackPresentationHostController,
        context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .init(width: 640, height: 360))
    }
    static func dismantleNSViewController(_ controller: PlaybackPresentationHostController, coordinator: ()) {
        // 宿主和播放会话独立存活，视图重排不会停止直播或切断画中画。
    }
}
