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
    }
    func start() { guard !isClosing else { return }; model.start() }
    func close() {
        guard !isClosing else { return }
        isClosing = true
        UIApplication.shared.isIdleTimerDisabled = false
        mount.detachAll()
        let model = model
        Task { await model.stop() }
    }
}
