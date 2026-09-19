// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import ObjectiveC
import Observation
import VPlayerPlayback

@MainActor
protocol PlaybackPresentationMounting: AnyObject {
    func attach(_ presentation: IdentifiedPlaybackPresentation)
    func detach(_ presentation: IdentifiedPlaybackPresentation)
}

@MainActor
final class DefaultPlaybackPresentationMount: PlaybackPresentationMounting {
    func attach(_: IdentifiedPlaybackPresentation) {}
    func detach(_ presentation: IdentifiedPlaybackPresentation) {
        switch presentation.presentation {
        case let .sampleBuffer(context):
            context.detach()
        case let .avPlayer(context):
            context.detach()
        }
    }
}

@MainActor
@Observable
final class FullScreenPlayerViewModel {
    private struct PendingPauseCommand: Equatable {
        let id: UUID
        let target: Bool
    }

    private struct PendingPresentationIntent {
        let consumerGeneration: UInt64
        let lifecycle: UInt64
        let playback: UInt64
    }

    @MainActor
    private final class PresentationConsumerOwner {
        weak var model: FullScreenPlayerViewModel?

        init(_ model: FullScreenPlayerViewModel) {
            self.model = model
        }
    }

    typealias PresentationStreamProvider = @Sendable () async throws -> AsyncStream<PlaybackPresentationReplacement>
    typealias MediaInformationProvider = @Sendable () async -> AsyncStream<PlaybackMediaInformation?>

    let request: PlaybackRequest
    private let engine: any PlaybackEngine
    private let presentationController: (any PlaybackPresentationControlling)?
    private let presentationStreamProvider: PresentationStreamProvider
    private let presentationMount: any PlaybackPresentationMounting
    private let mediaInformationProvider: MediaInformationProvider
    private let settings: PlaybackSettingsStore
    private var stateTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var presentationWorkerGeneration: UInt64?
    private var activePresentationConsumerGeneration: UInt64?
    private var pendingPresentationIntent: PendingPresentationIntent?
    private var presentationSuccessorPending = false
    private var mediaInformationProviderTask: Task<Void, Never>?
    private var mediaInformationTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var presentationConsumerGeneration: UInt64 = 0
    private var activePresentationSubscriptionGeneration: UInt64?
    private var latestPresentationRevision: UInt64?
    private var desiredPaused = false
    private var pendingPauseCommands: [PendingPauseCommand] = []
    private var awaitingAuthoritativePause: Bool?
    private var acceptsAuthoritativePauseState = false
    private var started = false
    private var stopped = false

    private(set) var state: PlaybackState = .idle
    private(set) var presentation: IdentifiedPlaybackPresentation?
    private(set) var presentationMountOwnership: PresentationMountOwnership?
    private(set) var mediaInformation: PlaybackMediaInformation?
    var presentationHostMount: PlaybackPresentationHostMount {
        guard let hostMount = presentationMount as? PlaybackPresentationHostMount else {
            preconditionFailure("测试mount不具备生产UIKit host")
        }
        return hostMount
    }

    #if DEBUG
    /// 仅供生命周期测试观测，不改变 consumer 的所有权或取消语义。
    var presentationConsumerIsActiveForTesting: Bool {
        presentationTask != nil || presentationWorkerGeneration != nil ||
            activePresentationConsumerGeneration != nil
    }

    var presentationConsumerTaskForTesting: Task<Void, Never>? {
        presentationTask
    }

    static var presentationConsumerOwnerObjectAllocationForTesting: Int {
        malloc_good_size(class_getInstanceSize(PresentationConsumerOwner.self))
    }

    /// 仅供代际交接测试制造真实 AsyncStream cancellation/termination。
    func cancelPresentationConsumerForTesting() {
        presentationTask?.cancel()
    }
    #endif

    init(
        request: PlaybackRequest,
        engine: any PlaybackEngine,
        presentationController: (any PlaybackPresentationControlling)? = nil,
        presentationStreamProvider: @escaping PresentationStreamProvider,
        presentationMount: (any PlaybackPresentationMounting)? = nil,
        mediaInformationProvider: @escaping MediaInformationProvider = {
            AsyncStream<PlaybackMediaInformation?> { continuation in continuation.finish() }
        },
        settings: PlaybackSettingsStore,
        initialPresentationConsumerGeneration: UInt64 = 0
    ) {
        self.request = request
        self.engine = engine
        self.presentationController = presentationController
            ?? (engine as? any PlaybackPresentationControlling)
        self.presentationStreamProvider = presentationStreamProvider
        self.presentationMount = presentationMount ?? PlaybackPresentationHostMount()
        self.mediaInformationProvider = mediaInformationProvider
        self.settings = settings
        presentationConsumerGeneration = initialPresentationConsumerGeneration
    }

    func detachPresentationIfOwned(_ expected: PresentationMountOwnership) {
        guard presentationMountOwnership?.subscriptionGeneration == expected.subscriptionGeneration,
              presentationMountOwnership?.mountNonce == expected.mountNonce else { return }
        if let presentation {
            presentationMount.detach(presentation)
        }
        presentation = nil
        presentationMountOwnership = nil
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
            await beginPresentationLookup(lifecycle: lifecycle, playback: playback)
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
        presentationSuccessorPending = presentationController != nil
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
            let states = await engine.events()
            guard isCurrent(lifecycle: lifecycle, playback: playback) else { return }
            stateTask?.cancel()
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
            await beginPresentationLookup(lifecycle: lifecycle, playback: playback)
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
        pendingPresentationIntent = nil
        presentationSuccessorPending = false
        presentationWorkerGeneration = nil
        activePresentationConsumerGeneration = nil
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
        if let ownership = presentationMountOwnership {
            detachPresentationIfOwned(ownership)
        }
        activePresentationSubscriptionGeneration = nil
        latestPresentationRevision = nil

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

    private func beginPresentationLookup(lifecycle: UInt64, playback: UInt64) async {
        guard let presentationController else {
            presentationSuccessorPending = false
            return
        }
        let (consumerGeneration, overflow) = presentationConsumerGeneration.addingReportingOverflow(1)
        guard !overflow else {
            presentationSuccessorPending = false
            await presentationController.failPresentationControl()
            if let ownership = presentationMountOwnership {
                detachPresentationIfOwned(ownership)
            }
            return
        }
        presentationConsumerGeneration = consumerGeneration
        let intent = PendingPresentationIntent(
            consumerGeneration: consumerGeneration,
            lifecycle: lifecycle,
            playback: playback
        )
        presentationSuccessorPending = false
        guard presentationTask == nil else {
            pendingPresentationIntent = intent
            return
        }
        pendingPresentationIntent = intent
        startPresentationWorker(startingWith: consumerGeneration)
    }

    private func startPresentationWorker(startingWith workerGeneration: UInt64) {
        let provider = presentationStreamProvider
        let owner = PresentationConsumerOwner(self)
        presentationWorkerGeneration = workerGeneration
        presentationTask = Task { @MainActor in
            await Self.runPresentationWorker(
                owner: owner,
                provider: provider,
                workerGeneration: workerGeneration
            )
        }
    }

    private static func runPresentationWorker(
        owner: PresentationConsumerOwner,
        provider: PresentationStreamProvider,
        workerGeneration: UInt64
    ) async {
        defer { owner.model?.finishPresentationWorker(workerGeneration) }
        while !Task.isCancelled,
              let intent = takePendingPresentationIntent(
                owner: owner,
                workerGeneration: workerGeneration
              ) {
            await consumePresentationStream(
                for: intent,
                provider: provider,
                workerGeneration: workerGeneration,
                owner: owner
            )
        }
    }

    /// 强引用只存在于这个同步栈帧，不跨越provider或iterator.next的等待点。
    private static func takePendingPresentationIntent(
        owner: PresentationConsumerOwner,
        workerGeneration: UInt64
    ) -> PendingPresentationIntent? {
        guard let model = owner.model,
              model.presentationWorkerGeneration == workerGeneration else { return nil }
        return model.takePendingPresentationIntent()
    }

    private func takePendingPresentationIntent() -> PendingPresentationIntent? {
        guard let pending = pendingPresentationIntent else { return nil }
        pendingPresentationIntent = nil
        activePresentationConsumerGeneration = pending.consumerGeneration
        return pending
    }

    private static func consumePresentationStream(
        for intent: PendingPresentationIntent,
        provider: PresentationStreamProvider,
        workerGeneration: UInt64,
        owner: PresentationConsumerOwner
    ) async {
        var streamSubscriptionGeneration: UInt64?
        let stream: AsyncStream<PlaybackPresentationReplacement>
        do {
            stream = try await provider()
        } catch {
            return
        }

        guard presentationConsumerIsCurrent(
            owner: owner,
            intent: intent,
            workerGeneration: workerGeneration
        ) else { return }
        var iterator = stream.makeAsyncIterator()
        while !Task.isCancelled {
            // iterator可以不响应cancel；这个await栈不得持有VM或mount。
            guard let replacement = await iterator.next() else {
                finishPresentationStream(
                    owner: owner,
                    intent: intent,
                    workerGeneration: workerGeneration
                )
                return
            }
            guard presentationConsumerCanConsume(
                owner: owner,
                intent: intent,
                workerGeneration: workerGeneration
            ) else { return }
            if let expected = streamSubscriptionGeneration {
                guard replacement.subscriptionGeneration == expected else { continue }
            } else {
                streamSubscriptionGeneration = replacement.subscriptionGeneration
            }
            await consumePresentationReplacement(
                replacement,
                intent: intent,
                workerGeneration: workerGeneration,
                owner: owner
            )
        }
    }

    private static func presentationConsumerIsCurrent(
        owner: PresentationConsumerOwner,
        intent: PendingPresentationIntent,
        workerGeneration: UInt64
    ) -> Bool {
        guard !Task.isCancelled, let model = owner.model else { return false }
        return model.presentationWorkerGeneration == workerGeneration &&
            model.activePresentationConsumerGeneration == intent.consumerGeneration &&
            model.pendingPresentationIntent == nil &&
            model.isCurrent(lifecycle: intent.lifecycle, playback: intent.playback)
    }

    private static func presentationConsumerCanConsume(
        owner: PresentationConsumerOwner,
        intent: PendingPresentationIntent,
        workerGeneration: UInt64
    ) -> Bool {
        guard !Task.isCancelled, let model = owner.model,
              model.presentationWorkerGeneration == workerGeneration,
              model.activePresentationConsumerGeneration == intent.consumerGeneration,
              model.pendingPresentationIntent == nil,
              model.isCurrent(lifecycle: intent.lifecycle) else { return false }
        // retry已经预留G2后，G1的nil只结束旧stream，不先拆host；
        // G2完整目标到达时再同步决定同context换owner或异context拆A装B。
        return model.playbackGeneration == intent.playback
    }

    private static func consumePresentationReplacement(
        _ replacement: PlaybackPresentationReplacement,
        intent: PendingPresentationIntent,
        workerGeneration: UInt64,
        owner: PresentationConsumerOwner
    ) async {
        guard let model = owner.model else { return }
        await model.consumePresentationReplacement(
            replacement,
            intent: intent,
            workerGeneration: workerGeneration
        )
    }

    private static func finishPresentationStream(
        owner: PresentationConsumerOwner,
        intent: PendingPresentationIntent,
        workerGeneration: UInt64
    ) {
        guard let model = owner.model,
              model.pendingPresentationIntent == nil,
              !model.presentationSuccessorPending,
              model.presentationWorkerGeneration == workerGeneration,
              model.activePresentationConsumerGeneration == intent.consumerGeneration else { return }
        if let ownership = model.presentationMountOwnership {
            model.detachPresentationIfOwned(ownership)
        }
        model.activePresentationSubscriptionGeneration = nil
        model.latestPresentationRevision = nil
    }

    private func finishPresentationWorker(_ workerGeneration: UInt64) {
        guard presentationWorkerGeneration == workerGeneration else { return }
        activePresentationConsumerGeneration = nil
        presentationWorkerGeneration = nil
        presentationTask = nil
        if pendingPresentationIntent == nil, !presentationSuccessorPending,
           let ownership = presentationMountOwnership {
            detachPresentationIfOwned(ownership)
        }
    }

    private func consumePresentationReplacement(
        _ replacement: PlaybackPresentationReplacement,
        intent: PendingPresentationIntent,
        workerGeneration: UInt64
    ) async {
        guard isPresentationIntentCurrent(intent, workerGeneration: workerGeneration),
              let presentationController else { return }
        let changesSubscription = activePresentationSubscriptionGeneration !=
            replacement.subscriptionGeneration
        if !changesSubscription {
            guard latestPresentationRevision.map({ replacement.revision > $0 }) ?? true else {
                return
            }
        }

        let claim = await presentationController.claimPresentationMountOwnership(for: replacement)
        // claim会跨actor suspension；返回时必须复验完整intent，不能只比较consumer编号。
        guard isPresentationIntentCurrent(intent, workerGeneration: workerGeneration) else { return }
        let preparedOwnership: PresentationMountOwnership
        switch claim {
        case .claimed(let ownership):
            preparedOwnership = ownership
        case .stale:
            return
        case .exhausted:
            await presentationController.failPresentationControl()
            guard isPresentationIntentCurrent(
                intent,
                workerGeneration: workerGeneration
            ) else { return }
            if let ownership = presentationMountOwnership {
                detachPresentationIfOwned(ownership)
            }
            activePresentationSubscriptionGeneration = nil
            latestPresentationRevision = nil
            return
        }

        activePresentationSubscriptionGeneration = replacement.subscriptionGeneration
        latestPresentationRevision = replacement.revision
        if !Self.samePresentation(presentation, replacement.desired) {
            if let presentation {
                presentationMount.detach(presentation)
            }
            presentation = nil
            if let desired = replacement.desired {
                presentationMount.attach(desired)
                presentation = desired
            }
        }
        presentationMountOwnership = replacement.desired == nil ? nil : preparedOwnership
    }

    private func isPresentationIntentCurrent(
        _ intent: PendingPresentationIntent,
        workerGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled &&
            presentationWorkerGeneration == workerGeneration &&
            activePresentationConsumerGeneration == intent.consumerGeneration &&
            pendingPresentationIntent == nil &&
            !presentationSuccessorPending &&
            isCurrent(lifecycle: intent.lifecycle, playback: intent.playback)
    }

    private static func samePresentation(
        _ lhs: IdentifiedPlaybackPresentation?,
        _ rhs: IdentifiedPlaybackPresentation?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            guard lhs.identity == rhs.identity else { return false }
            switch (lhs.presentation, rhs.presentation) {
            case let (.sampleBuffer(left), .sampleBuffer(right)):
                return left === right
            case let (.avPlayer(left), .avPlayer(right)):
                return left === right
            default:
                return false
            }
        default:
            return false
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
