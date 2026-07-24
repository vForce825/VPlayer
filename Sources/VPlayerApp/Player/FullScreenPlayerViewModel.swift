// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation
import VPlayerPlayback

@MainActor
@Observable
final class FullScreenPlayerViewModel {
    typealias PresentationProvider = @Sendable () async -> PlaybackPresentationContext?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    let request: PlaybackRequest
    private let engine: any PlaybackEngine
    private let presentationProvider: PresentationProvider
    private let settings: PlaybackSettingsStore
    private let sleep: Sleep
    private var stateTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var algorithmTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var noticeDismissalTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var algorithmRevision: UInt64 = 0
    private var started = false
    private var stopped = false

    private(set) var state: PlaybackState = .idle
    private(set) var visibleNotice: PlaybackNotice?
    private(set) var presentationContext: PlaybackPresentationContext?

    init(
        request: PlaybackRequest,
        engine: any PlaybackEngine,
        presentationProvider: @escaping PresentationProvider,
        settings: PlaybackSettingsStore,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.request = request
        self.engine = engine
        self.presentationProvider = presentationProvider
        self.settings = settings
        self.sleep = sleep
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        playbackGeneration &+= 1
        let lifecycle = lifecycleGeneration
        let playback = playbackGeneration
        playbackTask = Task { [weak self] in
            guard let self else { return }
            let states = await engine.events()
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            let notices = await engine.notices()
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            stateTask = Task { [weak self] in
                for await state in states {
                    guard let self,
                          !Task.isCancelled,
                          isCurrent(lifecycle: lifecycle) else { return }
                    self.state = state
                }
            }
            noticeTask = Task { [weak self] in
                for await notice in notices {
                    guard let self,
                          !Task.isCancelled,
                          isCurrent(lifecycle: lifecycle) else { return }
                    self.present(notice)
                }
            }
            let algorithm = scheduleAlgorithm(
                settings.deinterlaceAlgorithm,
                lifecycle: lifecycle
            )
            await algorithm.value
            if let latestAlgorithm = algorithmTask {
                await latestAlgorithm.value
            }
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            await engine.play(request)
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            beginPresentationLookup(lifecycle: lifecycle, playback: playback)
        }
    }

    func togglePause() {
        let target: Bool
        switch state {
        case .playing:
            target = true
        case .paused:
            target = false
        case .idle, .preparing, .stopped, .failed:
            return
        }
        let predecessor = pauseTask
        let lifecycle = lifecycleGeneration
        let engine = engine
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self, isCurrent(lifecycle: lifecycle) else { return }
            await engine.setPaused(target)
        }
        pauseTask = task
    }

    func retry() {
        guard !stopped else { return }
        playbackGeneration &+= 1
        let lifecycle = lifecycleGeneration
        let playback = playbackGeneration
        let predecessor = playbackTask
        predecessor?.cancel()
        playbackTask = Task { [weak self] in
            await predecessor?.value
            guard let self,
                  isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            await engine.play(request)
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            beginPresentationLookup(lifecycle: lifecycle, playback: playback)
        }
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard !stopped else { return }
        stopped = true
        lifecycleGeneration &+= 1
        playbackGeneration &+= 1
        algorithmRevision &+= 1

        let playback = playbackTask
        let presentation = presentationTask
        let algorithm = algorithmTask
        let pause = pauseTask
        let states = stateTask
        let notices = noticeTask
        playback?.cancel()
        presentation?.cancel()
        algorithm?.cancel()
        pause?.cancel()
        states?.cancel()
        notices?.cancel()
        noticeDismissalTask?.cancel()
        playbackTask = nil
        presentationTask = nil
        algorithmTask = nil
        pauseTask = nil
        stateTask = nil
        noticeTask = nil
        noticeDismissalTask = nil
        visibleNotice = nil
        presentationContext?.detach()
        presentationContext = nil

        let engine = engine
        let task = Task {
            await playback?.value
            await algorithm?.value
            await pause?.value
            await states?.value
            await notices?.value
            await engine.stop()
        }
        stopTask = task
        await task.value
    }

    private func beginPresentationLookup(lifecycle: UInt64, playback: UInt64) {
        presentationTask?.cancel()
        let provider = presentationProvider
        presentationTask = Task { @MainActor [weak self] in
            let context = await provider()
            guard let self,
                  isCurrent(lifecycle: lifecycle, playback: playback) else {
                return
            }
            presentationContext = context
        }
    }

    private func scheduleAlgorithm(
        _ algorithm: DeinterlaceAlgorithm,
        lifecycle: UInt64
    ) -> Task<Void, Never> {
        algorithmRevision &+= 1
        let revision = algorithmRevision
        let predecessor = algorithmTask
        let engine = engine
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self,
                  isCurrent(lifecycle: lifecycle),
                  algorithmRevision == revision else { return }
            await engine.setDeinterlaceAlgorithm(algorithm)
        }
        algorithmTask = task
        return task
    }

    private func isCurrent(lifecycle: UInt64, playback: UInt64? = nil) -> Bool {
        guard !Task.isCancelled,
              !stopped,
              lifecycleGeneration == lifecycle else { return false }
        return playback.map { playbackGeneration == $0 } ?? true
    }

    private func present(_ notice: PlaybackNotice) {
        if visibleNotice?.id == notice.id { return }
        noticeDismissalTask?.cancel()
        visibleNotice = notice
        noticeDismissalTask = Task { [weak self] in
            do {
                try await self?.sleep(notice.duration)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  visibleNotice?.id == notice.id else { return }
            visibleNotice = nil
        }
    }
}
