// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation
import UIKit
import VPlayerPlayback

/// Root-owned playback lifetime. SwiftUI presentation disappearance is not a
/// playback command; an explicit close is the only UI path that retires it.
@MainActor
@Observable
final class IOSPlaybackSession: Identifiable {
    let presentation: PlayerChannelPresentation
    let model: FullScreenPlayerViewModel
    let mount: PlaybackPresentationHostMount
    let settings: PlaybackSettingsStore
    let pictureInPicture: IOSPictureInPictureCoordinator
    let host: IOSPlaybackHostController
    var isFullScreenPresented = true
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    private(set) var isClosing = false
    var id: UUID { presentation.request.id }

    init(presentation: PlayerChannelPresentation, dependencies: AppDependencies) {
        self.presentation = presentation
        settings = dependencies.playbackSettings
        let mount = PlaybackPresentationHostMount()
        self.mount = mount
        model = FullScreenPlayerViewModel(request: presentation.request,
            engine: dependencies.playbackEngine,
            presentationController: dependencies.playbackPresentationController,
            presentationStreamProvider: dependencies.playbackPresentationProvider,
            presentationMount: mount,
            mediaInformationProvider: dependencies.playbackMediaInformationProvider,
            settings: dependencies.playbackSettings, nowPlaying: dependencies.nowPlaying,
            channelPresentation: presentation)
        pictureInPicture = IOSPictureInPictureCoordinator(target: model)
        host = IOSPlaybackHostController(pictureInPicture: pictureInPicture)
        mount.connect(to: host)
        pictureInPicture.onStarted = { [weak self] in self?.isFullScreenPresented = false }
        pictureInPicture.onStopped = { [weak self] in self?.close() }
        pictureInPicture.onRestore = { [weak self] completion in
            guard let self, !self.isClosing else { completion(false); return }
            self.restoreFullScreen(completion: completion)
        }
    }
    func start() {
        guard !isClosing, !hasStarted else { return }
        hasStarted = true
        model.start()
        observePlaybackState()
    }
    private func observePlaybackState() {
        guard !isClosing else { return }
        if model.hasStoppedCurrentRequest { close(); return }
        withObservationTracking {
            pictureInPicture.update(state: model.state, paused: model.isPaused)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlaybackState() }
        }
    }
    func showFullScreen() {
        guard !isClosing else { return }
        isFullScreenPresented = true
        pictureInPicture.stopForRestoration()
    }
    private func restoreFullScreen(completion: @escaping @MainActor (Bool) -> Void) {
        restoreTask?.cancel()
        isFullScreenPresented = true
        restoreTask = Task { @MainActor [weak self] in
            for _ in 0..<100 {
                guard !Task.isCancelled, let self, !self.isClosing else { completion(false); return }
                if self.host.isViewLoaded, let window = self.host.view.window,
                   !window.isHidden, !self.host.view.isHidden {
                    completion(true)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { completion(false); return }
            }
            completion(false)
        }
    }
    func close() {
        guard !isClosing else { return }
        isClosing = true
        restoreTask?.cancel()
        restoreTask = nil
        pictureInPicture.close()
        isFullScreenPresented = false
        UIApplication.shared.isIdleTimerDisabled = false
        mount.detachAll()
        let model = model
        Task { await model.stop() }
    }
}
