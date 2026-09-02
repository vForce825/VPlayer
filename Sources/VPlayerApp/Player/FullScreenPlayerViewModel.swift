// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation
import VPlayerPlayback

@MainActor
@Observable
final class FullScreenPlayerViewModel {
    private struct PendingPauseCommand: Equatable {
        let id: UUID
        let target: Bool
    }

    typealias PresentationProvider = @Sendable () async -> PlaybackPresentationContext?
    typealias MediaInformationProvider = @Sendable () async -> AsyncStream<PlaybackMediaInformation?>

    let request: PlaybackRequest
    private let engine: any PlaybackEngine
    private let presentationProvider: PresentationProvider
    private let mediaInformationProvider: MediaInformationProvider
    private let settings: PlaybackSettingsStore
    private var stateTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var mediaInformationProviderTask: Task<Void, Never>?
    private var mediaInformationTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var desiredPaused = false
    private var pendingPauseCommands: [PendingPauseCommand] = []
    private var awaitingAuthoritativePause: Bool?
    private var acceptsAuthoritativePauseState = false
    private var started = false
    private var stopped = false

    private(set) var state: PlaybackState = .idle
    private(set) var presentationContext: PlaybackPresentationContext?
    private(set) var mediaInformation: PlaybackMediaInformation?

    init(
        request: PlaybackRequest,
        engine: any PlaybackEngine,
        presentationProvider: @escaping PresentationProvider,
        mediaInformationProvider: @escaping MediaInformationProvider = {
            AsyncStream<PlaybackMediaInformation?> { continuation in
                continuation.finish()
            }
        },
        settings: PlaybackSettingsStore
    ) {
        self.request = request
        self.engine = engine
        self.presentationProvider = presentationProvider
        self.mediaInformationProvider = mediaInformationProvider
        self.settings = settings
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    func start() {
        guard !started, !stopped else { return }
        resetMediaInformation()
        resetPauseIntent()
        started = true
        playbackGeneration &+= 1
        let lifecycle = lifecycleGeneration
        let playback = playbackGeneration
        playbackTask = Task { [weak self] in
            guard let self else { return }
            let states = await engine.events()
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            stateTask = Task { [weak self] in
                for await state in states {
                    guard let self,
                          !Task.isCancelled,
                          isCurrent(lifecycle: lifecycle) else { return }
                    self.apply(state)
                }
            }
            await engine.play(request)
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            beginMediaInformationSubscription(
                lifecycle: lifecycle,
                playback: playback
            )
            beginPresentationLookup(lifecycle: lifecycle, playback: playback)
        }
    }

    func togglePause() {
        switch state {
        case .playing, .paused:
            break
        case .idle, .preparing, .buffering, .recovering, .stopped, .failed:
            return
        }
        desiredPaused.toggle()
        let command = PendingPauseCommand(id: UUID(), target: desiredPaused)
        pendingPauseCommands.append(command)
        awaitingAuthoritativePause = nil
        let predecessor = pauseTask
        let lifecycle = lifecycleGeneration
        let playback = playbackGeneration
        let engine = engine
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self,
                  isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            await engine.setPaused(command.target)
            retirePauseCommand(
                command,
                lifecycle: lifecycle,
                playback: playback
            )
        }
        pauseTask = task
    }

    func retry() {
        guard !stopped,
              case let .failed(failure) = state,
              failure.retryDisposition == .retrySameRequest else { return }
        resetMediaInformation()
        playbackGeneration &+= 1
        resetPauseIntent()
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
            beginMediaInformationSubscription(
                lifecycle: lifecycle,
                playback: playback
            )
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

        let playback = playbackTask
        let presentation = presentationTask
        let pause = pauseTask
        let states = stateTask
        let mediaInformationProvider = mediaInformationProviderTask
        let mediaInformation = mediaInformationTask
        playback?.cancel()
        presentation?.cancel()
        mediaInformationProvider?.cancel()
        mediaInformation?.cancel()
        pause?.cancel()
        states?.cancel()
        playbackTask = nil
        presentationTask = nil
        mediaInformationProviderTask = nil
        mediaInformationTask = nil
        resetPauseIntent()
        stateTask = nil
        self.mediaInformation = nil
        state = .stopped
        presentationContext?.detach()
        presentationContext = nil

        let engine = engine
        let task = Task {
            await playback?.value
            await pause?.value
            await states?.value
            await mediaInformation?.value
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

    private func beginMediaInformationSubscription(
        lifecycle: UInt64,
        playback: UInt64
    ) {
        let provider = mediaInformationProvider
        mediaInformationProviderTask = Task { [weak self] in
            let mediaStream = await provider()
            guard let self,
                  isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            mediaInformationTask = Task { [weak self] in
                for await information in mediaStream {
                    guard let self,
                          !Task.isCancelled,
                          isCurrent(lifecycle: lifecycle, playback: playback) else { return }
                    self.mediaInformation = information
                }
            }
        }
    }

    private func isCurrent(lifecycle: UInt64, playback: UInt64? = nil) -> Bool {
        guard !Task.isCancelled,
              !stopped,
              lifecycleGeneration == lifecycle else { return false }
        return playback.map { playbackGeneration == $0 } ?? true
    }

    private func apply(_ newState: PlaybackState) {
        state = newState
        switch newState {
        case .preparing, .buffering, .recovering:
            acceptsAuthoritativePauseState = true
        case .playing:
            applyAuthoritativePauseState(false)
        case .paused:
            applyAuthoritativePauseState(true)
        case .stopped, .failed:
            resetPauseIntent()
            if case .failed = newState {
                resetMediaInformation()
            }
        case .idle:
            break
        }
    }

    private func applyAuthoritativePauseState(_ paused: Bool) {
        guard acceptsAuthoritativePauseState,
              pendingPauseCommands.isEmpty else { return }
        if let awaitingAuthoritativePause {
            guard awaitingAuthoritativePause == paused else { return }
            self.awaitingAuthoritativePause = nil
        }
        desiredPaused = paused
    }

    private func retirePauseCommand(
        _ command: PendingPauseCommand,
        lifecycle: UInt64,
        playback: UInt64
    ) {
        guard isCurrent(lifecycle: lifecycle, playback: playback),
              let commandIndex = pendingPauseCommands.firstIndex(where: {
                  $0.id == command.id
              }) else { return }
        pendingPauseCommands.remove(at: commandIndex)
        if pendingPauseCommands.isEmpty {
            awaitingAuthoritativePause = command.target
        }
    }

    private func resetPauseIntent() {
        pauseTask?.cancel()
        pauseTask = nil
        desiredPaused = false
        pendingPauseCommands.removeAll()
        awaitingAuthoritativePause = nil
        acceptsAuthoritativePauseState = false
    }

    private func resetMediaInformation() {
        mediaInformationProviderTask?.cancel()
        mediaInformationProviderTask = nil
        mediaInformationTask?.cancel()
        mediaInformationTask = nil
        mediaInformation = nil
    }

}
