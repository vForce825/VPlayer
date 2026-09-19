// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import Foundation

protocol PlaybackTerminalMetricsProviding: Sendable {
    func snapshot(window: Duration) -> PlaybackMetricsSnapshot
}

extension PlaybackMetrics: PlaybackTerminalMetricsProviding {}

final class DefaultAudioSessionCompletionReceiver: PlaybackAudioSessionCompletionReceiving, @unchecked Sendable {
    func receiveAudioSessionCompletion(permit: AudioSessionBlockingCallPermit, completion: AudioSessionBlockingCallCompletion) {}
}

public actor PlaybackController: PlaybackEngine, PlaybackPresentationControlling, PlaybackMetricsProviding, PlaybackMediaInformationProviding, PlaybackOwnedInterruptionCleanupReceiving {
    private let registry: ControlTaskRegistry
    private let deadlineScheduler: PlaybackDeadlineScheduler
    private let audioSessionOwner: PlaybackAudioSessionOwner
    private let routeService: PlaybackAudioRouteService?
    private let backendFactory: any PlaybackBackendFactory
    private let audioEventMonitor: SystemAudioEventMonitor?
    private let defaultReceiver: any PlaybackAudioSessionCompletionReceiving
    private let presentationRelay: PlaybackPresentationRelay
    let recoveryCoordinator: PlaybackRecoveryCoordinator
    public let watchdog: HLSPlaybackWatchdog
    
    private var controllerState = PlaybackControllerState()
    private var terminalMetricsProvider: (any PlaybackTerminalMetricsProviding)?
    private var mediaGeneration: MediaGeneration?
    private var currentMediaInformation: PlaybackMediaInformation?
    private var interruptionActive = false
    private var systemPauseRequired = false
    private var resumeVetoRequired = false
    private var resumeRequestInFlight = false
    // 同一session的终态只关闭一次presentation；恢复/切路由只clear，不占用此终态身份。
    private var finishedPresentationSession: PlaybackSessionIdentity?
    private var diagnosticStage = "init" {
        didSet {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set(diagnosticStage)
            #endif
        }
    }

    #if DEBUG
    private var beforePresentationCommitForTesting: (@Sendable () -> Void)?
    private var beforePresentationMountClaimForTesting: (@Sendable () -> Void)?
    #endif
    private var admittedRun: PlaybackRunIdentity? {
        guard case .coldStart(let admission) = registry.playbackRequestAdmissionSnapshot() else { return nil }
        return .init(sessionID: admission.identity.sessionIdentity.sessionID,
            requestID: admission.identity.sessionIdentity.requestID)
    }
    private var tuning = PlaybackTuning.default

    private static let audioSessionActivationFailure = PlaybackFailure(
        code: "audio.session.activation",
        userMessage: "无法启用音频播放，请检查播放设备后重试。"
    )

    static let routeUnavailableFailure = PlaybackFailure(
        code: "route.unavailable",
        userMessage: "音频输出路由不可用，播放已停止。"
    )

    static let watchdogHardCapacityFailure = PlaybackFailure(
        code: "hls.watchdog.capacity",
        userMessage: "播放缓冲超出限制，已停止播放。"
    )

    @MainActor
    public init() {
        let allocator = PlaybackIdentityAllocator()
        let registry = ControlTaskRegistry(allocator: allocator)
        let sdk = SystemPlaybackAudioSessionSDK(session: AVAudioSession.sharedInstance())
        let owner = try! PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        let routeService = PlaybackAudioRouteService(registry: registry, owner: owner)
        let monitor = owner.monitor
        let pipelineFactory = SystemPlaybackPipelineFactory(routeMonitor: AudioOutputRouteMonitor(service: routeService))
        let backendFactory = SystemPlaybackBackendFactory(pipelineFactory: pipelineFactory)
        let receiver = DefaultAudioSessionCompletionReceiver()
        
        self.registry = registry
        let deadlineScheduler = PlaybackDeadlineScheduler(registry: registry)
        self.deadlineScheduler = deadlineScheduler
        self.audioSessionOwner = owner
        self.routeService = routeService
        self.backendFactory = backendFactory
        self.audioEventMonitor = monitor
        self.defaultReceiver = receiver
        self.presentationRelay = PlaybackPresentationRelay(allocator: allocator)
        let recoveryCoordinator = PlaybackRecoveryCoordinator(allocator: allocator)
        self.recoveryCoordinator = recoveryCoordinator
        self.watchdog = HLSPlaybackWatchdog(recoveryCoordinator: recoveryCoordinator)
        registry.bindPlaybackRuntime(scheduler: deadlineScheduler, receiver: self)
        
        monitor.bindProductionRegistry(registry)
        monitor.start()
        recoveryCoordinator.setWatchdogRecoveryHandler { [weak self] reason, nonce in
            guard let self else { return }
            guard self.recoveryCoordinator.isCurrentNonce(nonce) else { return }
            await self.handleWatchdogRecovery(reason: reason)
        }
        routeService.setRouteCommitHandler { [weak self] commit in
            guard let self else { return }
            self.recoveryCoordinator.scheduleRecoveryTransaction { [weak self] nonce in
                guard let self else { return }
                guard self.recoveryCoordinator.isCurrentNonce(nonce) else { return }
                await self.handleRouteCommit(commit)
            }
        }
        routeService.setRouteUnavailableHandler { [weak self] in
            guard let self else { return }
            self.recoveryCoordinator.scheduleRecoveryTransaction { [weak self] nonce in
                guard let self else { return }
                guard self.recoveryCoordinator.isCurrentNonce(nonce) else { return }
                await self.handleRouteUnavailableFromService()
            }
        }
    }

    init(
        registry: ControlTaskRegistry? = nil,
        audioSessionOwner: PlaybackAudioSessionOwner? = nil,
        routeService: PlaybackAudioRouteService? = nil,
        audioEventMonitor: SystemAudioEventMonitor? = nil,
        backendFactory: (any PlaybackBackendFactory)? = nil,
        allocator: PlaybackIdentityAllocator? = nil
    ) {
        let actualRegistry = registry ?? audioSessionOwner?.registry ?? ControlTaskRegistry(allocator: allocator ?? PlaybackIdentityAllocator())
        self.registry = actualRegistry
        let deadlineScheduler = PlaybackDeadlineScheduler(registry: actualRegistry)
        self.deadlineScheduler = deadlineScheduler
        let owner = audioSessionOwner ?? (try! PlaybackAudioSessionOwner(registry: actualRegistry))
        self.audioSessionOwner = owner
        self.routeService = routeService
        let monitor = audioEventMonitor ?? owner.monitor
        self.audioEventMonitor = monitor
        self.backendFactory = backendFactory ?? SystemPlaybackBackendFactory()
        self.defaultReceiver = DefaultAudioSessionCompletionReceiver()
        self.presentationRelay = PlaybackPresentationRelay(allocator: actualRegistry.allocator)
        let recoveryCoordinator = PlaybackRecoveryCoordinator(allocator: actualRegistry.allocator)
        self.recoveryCoordinator = recoveryCoordinator
        self.watchdog = HLSPlaybackWatchdog(recoveryCoordinator: recoveryCoordinator)
        actualRegistry.bindPlaybackRuntime(scheduler: deadlineScheduler, receiver: self)
        
        monitor.bindProductionRegistry(actualRegistry)
        monitor.start()
        recoveryCoordinator.setWatchdogRecoveryHandler { [weak self] reason, nonce in
            guard let self else { return }
            guard self.recoveryCoordinator.isCurrentNonce(nonce) else { return }
            await self.handleWatchdogRecovery(reason: reason)
        }
        routeService?.setRouteCommitHandler { [weak self] commit in
            guard let self else { return }
            self.recoveryCoordinator.scheduleRecoveryTransaction { [weak self] nonce in
                guard let self else { return }
                guard self.recoveryCoordinator.isCurrentNonce(nonce) else { return }
                await self.handleRouteCommit(commit)
            }
        }
        routeService?.setRouteUnavailableHandler { [weak self] in
            guard let self else { return }
            self.recoveryCoordinator.scheduleRecoveryTransaction { [weak self] nonce in
                guard let self else { return }
                guard self.recoveryCoordinator.isCurrentNonce(nonce) else { return }
                await self.handleRouteUnavailableFromService()
            }
        }
    }

    init(
        factory: any PlaybackPipelineFactory,
        audioSessionOwner: PlaybackAudioSessionOwner? = nil,
        routeService: PlaybackAudioRouteService? = nil,
        audioEventMonitor: SystemAudioEventMonitor? = nil
    ) {
        let registry = audioSessionOwner?.registry ?? ControlTaskRegistry(allocator: PlaybackIdentityAllocator())
        let backendFactory = SystemPlaybackBackendFactory(pipelineFactory: factory)
        self.init(
            registry: registry,
            audioSessionOwner: audioSessionOwner,
            routeService: routeService,
            audioEventMonitor: audioEventMonitor,
            backendFactory: backendFactory,
            allocator: registry.allocator
        )
    }

    init(backendFactory: any PlaybackBackendFactory) {
        let allocator = PlaybackIdentityAllocator()
        let registry = ControlTaskRegistry(allocator: allocator)
        self.init(registry: registry, backendFactory: backendFactory, allocator: allocator)
    }

    public func events() -> AsyncStream<PlaybackState> {
        registry.makeStateStream()
    }

    public func presentations() throws -> AsyncStream<PlaybackPresentationReplacement> {
        do {
            return try presentationRelay.presentations()
        } catch PlaybackPresentationRelayError.identitySpaceExhausted {
            registry.failPresentationControl()
            throw PlaybackPresentationRelayError.identitySpaceExhausted
        }
    }

    public func claimPresentationMountOwnership(
        for replacement: PlaybackPresentationReplacement
    ) -> PlaybackPresentationMountClaimResult {
        #if DEBUG
        beforePresentationMountClaimForTesting?()
        #endif
        return registry.claimPresentationMountOwnership(
            for: replacement,
            relay: presentationRelay
        )
    }

    public func failPresentationControl() {
        registry.failPresentationControl()
    }

    #if DEBUG
    func setBeforePresentationCommitForTesting(_ hook: (@Sendable () -> Void)?) {
        beforePresentationCommitForTesting = hook
    }

    func setBeforePresentationMountClaimForTesting(_ hook: (@Sendable () -> Void)?) {
        beforePresentationMountClaimForTesting = hook
    }

    func setPresentationRelayDeliveryHooksForTesting(
        before: (@Sendable (UInt64, Bool) -> Void)? = nil,
        after: (@Sendable (UInt64, Bool) -> Void)? = nil
    ) {
        presentationRelay.setDeliveryHooksForTesting(before: before, after: after)
    }
    #endif

    public func playbackMediaInformation() -> AsyncStream<PlaybackMediaInformation?> {
        registry.makeMediaStream(initial: currentMediaInformation)
    }

    public func play(_ request: PlaybackRequest) async {
        diagnosticStage = "play_entry"
        recoveryCoordinator.cancelCurrentRecovery()
        await watchdog.disarm()
        // 新播放请求一进入actor就撤销旧UI所有权，不能让前驱资源排空时间延长旧画面寿命。
        if let context = registry.outputResourceContextSnapshot() {
            finishPresentation(for: context.sessionIdentity)
        } else {
            presentationRelay.finish()
        }
        // 入口时冻结身份与预算；前驱排空、SDK配置及route稳定都不能重置起点。
        let sessionIdentity: PlaybackSessionIdentity
        let parentDeadline: CurrentPlaybackOperationDeadlineTicket
        do {
            diagnosticStage = "admitting_request"
            parentDeadline = try await admitAfterJoiningCleanup(requestID: request.id)
            guard case .coldStart(let budget) = parentDeadline else { diagnosticStage = "parentDeadline_not_coldStart"; return }
            sessionIdentity = budget.identity.sessionIdentity
        } catch {
            diagnosticStage = "admit_failed"
            publish(.failed(Self.audioSessionActivationFailure))
            return
        }
        invalidateSession()
        let runIdentity = PlaybackRunIdentity(sessionID: sessionIdentity.sessionID, requestID: request.id)
        
        terminalMetricsProvider = nil
        clearMediaInformation()
        
        controllerState.request = request
        controllerState.userPaused = false
        controllerState.readinessCycle = 0
        controllerState.activeRoutePorts = nil
        publish(.preparing(request))
        
        // 1. Predecessor teardown
        diagnosticStage = "joining_cleanup"
        await joinOwnedSessionCleanup(reason: .stop)
        guard isCurrent(runIdentity) else { diagnosticStage = "predecessor_not_current"; return }
        
        // 2. Acquisition & Cold Start Deadline
        let committedHandoff: OutputAcquisitionHandoff
        do {
            diagnosticStage = "begin_acquisition"
            guard let acquisition = try registry.beginOutputAcquisition(
                admission: parentDeadline,
                resetRecoveryMandatorySuffix: 3_000_000_000
            ) else {
                diagnosticStage = "beginOutputAcquisition_failed"
                throw Self.audioSessionActivationFailure
            }
            
            let receiver = routeService ?? defaultReceiver
            guard audioSessionOwner.startAcquisition(acquisition, receiver: receiver) else {
                diagnosticStage = "startAcquisition_failed"
                _ = registry.cancelAcquisitionSession()
                throw Self.audioSessionActivationFailure
            }
            
            interruptionActive = registry.executor.safetyIngress.snapshot.interruptionState == .began
            guard let reg = audioSessionOwner.registration(for: acquisition),
                  reg.identity.sessionIdentity == sessionIdentity,
                  let resource = registry.outputResourceContextSnapshot(), resource.sessionIdentity == sessionIdentity
            else {
                diagnosticStage = "registration_lookup_failed"
                throw Self.audioSessionActivationFailure
            }
            let audioGroup = try registry.createGroup(
                resource: .monitor(session: sessionIdentity, lifecycle: reg.identity.monitorLifecycle),
                parent: resource.reservation.ownerGroup)
            let audioDrain = try registry.enqueue(group: audioGroup, slot: .systemEventRelay, policy: .safetyBypass)
            let leaseID = reg.identity.leaseID
            let lease = PlaybackAudioSessionLease(
                id: leaseID,
                generation: leaseID,
                isInterruptedAtAcquisition: interruptionActive
            )
            let audioRelay = PlaybackAudioSessionEventRelay(identity: runIdentity, lease: lease) {
                [weak self] identity, lease, key, drain in
                await self?.receiveAudioSessionEvent(key, lease: lease, identity: identity, drain: drain)
            }
            audioRelay.terminalReceiver = self
            // 先登记准确owner但不开放receiver；暴露入口后原固定ring的overflow即可同步撤权。
            guard registry.prepareAudioEventRelayBinding(audioRelay, to: audioDrain)
            else {
                diagnosticStage = "prepareAudioEventRelayBinding_failed"
                throw Self.audioSessionActivationFailure
            }
            guard registry.bindEventRelay(audioRelay, to: audioDrain) else {
                diagnosticStage = "bindEventRelay_failed"
                throw Self.audioSessionActivationFailure
            }
            let initialSafety = registry.executor.safetyIngress.snapshot
            resumeVetoRequired = initialSafety.interruptionVeto && initialSafety.interruptionState != .began
            systemPauseRequired = initialSafety.interruptionVeto
            if resumeVetoRequired { publish(.paused(request)) }

            var token: OutputAcquisitionCommitToken?
            while token == nil {
                guard isCurrent(runIdentity) else {
                    diagnosticStage = "acquisition_token_not_current"
                    // 真实SDK失败可先撤销admission；返回前只join这个session的原terminal尾部。
                    await registry.joinOwnedTerminalCleanup(session: sessionIdentity)
                    return
                }
                token = registry.outputAcquisitionCommitSnapshot()
                if token != nil { break }
                diagnosticStage = "waiting_for_token"
                // began期间保留原acquisition；ended只能继续其准确configured lease，不能重acquire。
                if let acquiring = registry.outputResourceContextSnapshot(),
                   acquiring.sessionIdentity == sessionIdentity,
                   let next = try? registry.beginOutputAcquisitionActivation(contextNonce: acquiring.contextNonce) {
                    _ = audioSessionOwner.invoke(next, receiver: receiver)
                }
                guard await registry.waitForPlaybackProgress(.acquisition(acquisition)) else {
                    diagnosticStage = "waitForPlaybackProgress_acquisition_failed"
                    return
                }
            }
            
            guard let validToken = token else {
                diagnosticStage = "validToken_nil"
                _ = registry.cancelAcquisitionSession()
                throw Self.audioSessionActivationFailure
            }
            
            var handoff: OutputAcquisitionHandoff?
            var currentToken = validToken
            for _ in 0..<50 {
                guard isCurrent(runIdentity) else {
                    diagnosticStage = "commit_not_current"
                    await registry.joinOwnedTerminalCleanup(session: sessionIdentity)
                    return
                }
                let result = try registry.commitAcquisitionRelayAndContext(currentToken)
                switch result {
                case .committed(let h):
                    handoff = h
                case .retry(let next):
                    currentToken = next
                case .rejected:
                    diagnosticStage = "commitAcquisition_rejected"
                    _ = registry.cancelAcquisitionSession()
                    throw Self.audioSessionActivationFailure
                }
                if handoff != nil { break }
            }
            
            guard let finalHandoff = handoff else {
                diagnosticStage = "finalHandoff_nil"
                _ = registry.cancelAcquisitionSession()
                throw Self.audioSessionActivationFailure
            }
            committedHandoff = finalHandoff
            
            let safety = registry.executor.safetyIngress.snapshot
            let ownerInterrupted = audioSessionOwner.isInterruptedAtAcquisition
            interruptionActive = safety.interruptionState == .began || ownerInterrupted
            // 通用suspend标记也会由旧输出teardown置位，不得将它当成新session的物理中断。
            systemPauseRequired = interruptionActive || safety.interruptionVeto
            if systemPauseRequired { advanceReadinessCycle() }
            
            if let routeService {
                routeService.bindSession(registration: reg, initialSampler: finalHandoff.sampler)
            }
        } catch {
            diagnosticStage = "acquisition_threw_\(error)"
            guard isCurrent(runIdentity) else {
                await registry.joinOwnedTerminalCleanup(session: sessionIdentity)
                return
            }
            registry.deactivateOutputEventRelays(session: sessionIdentity)
            routeService?.unbindSession()
            publish(.failed(Self.audioSessionActivationFailure))
            return
        }
        
        diagnosticStage = "calling_prepare_successor"
        await prepareSuccessor(request: request, runIdentity: runIdentity,
            contextNonce: committedHandoff.successorContextNonce, owner: nil)
    }


    private func admitAfterJoiningCleanup(requestID: UUID) async throws -> CurrentPlaybackOperationDeadlineTicket {
        while true {
            do { return try registry.admitPlaybackRequest(requestID: requestID) }
            catch ControlTaskRegistry.Failure.cleanupTailPending {
                await registry.joinAutomaticCleanupTailBeforeAdmission()
            }
        }
    }

    private func prepareSuccessor(request: PlaybackRequest, runIdentity: PlaybackRunIdentity,
        contextNonce: UInt64, owner: OutputTransitionOwnerTicket?, fromEventRelay: Bool = false,
        resetActivationNonce: UInt64? = nil) async {
        diagnosticStage = "prepare_successor_entry"
        let sessionIdentity = PlaybackSessionIdentity(sessionID: runIdentity.sessionID, requestID: runIdentity.requestID)
        // 冷启动与handoff共用真实route、factory、prepare及一次activation入口。
        do {
            var stableCommit: StableRouteCommitIdentity?
            while stableCommit == nil {
                diagnosticStage = "waiting_for_stable_commit"
                guard isCurrent(runIdentity) else { diagnosticStage = "route_not_current"; return }
                stableCommit = registry.stableRouteCommitSnapshot()
                if stableCommit != nil { break }
                guard await registry.waitForPlaybackProgress(.route(sessionIdentity)) else {
                    diagnosticStage = "waitForPlaybackProgress_route_failed"
                    return
                }
            }
            guard let stableCommit else {
                diagnosticStage = "stableCommit_nil"
                throw Self.audioSessionActivationFailure
            }
            diagnosticStage = "stable_commit_obtained"
            guard let successor = registry.outputResourceContextSnapshot() else {
                diagnosticStage = "successor_snapshot_nil"
                throw Self.audioSessionActivationFailure
            }
            guard successor.owner == owner else {
                diagnosticStage = "successor_owner_mismatch"
                throw Self.audioSessionActivationFailure
            }
            let successorNonce: UInt64
            if let resetActivationNonce {
                // reset稳定提交会换context nonce；只承接原真实activation的准确rebase，
                // 不能把任意latest context当成原completion的后继。
                guard stableCommit.authority.audioSessionActivationNonce == resetActivationNonce,
                      successor.retainedRebase?.stableCommit == stableCommit,
                      successor.retainedRebase?.contextNonce == successor.contextNonce else {
                    diagnosticStage = "resetActivationNonce_mismatch"
                    throw Self.audioSessionActivationFailure
                }
                successorNonce = successor.contextNonce
            } else {
                guard successor.contextNonce == contextNonce else {
                    diagnosticStage = "successorNonce_mismatch"
                    throw Self.audioSessionActivationFailure
                }
                successorNonce = contextNonce
            }
            if owner == nil {
                guard
                      registry.seal(successor.reservation.workGroup),
                      try registry.renewOutputCycle(contextNonce: successorNonce) != nil else {
                    diagnosticStage = "seal_or_renewOutputCycle_failed"
                    throw Self.audioSessionActivationFailure
                }
            }
            guard let rebase = try registry.rebaseRetainedOutput(contextNonce: successorNonce, stableCommit: stableCommit, owner: owner) else {
                diagnosticStage = "rebaseRetainedOutput_nil"
                throw Self.audioSessionActivationFailure
            }

            let backendIdentity: PlaybackBackendIdentity
            if let claim = rebase.successorClaim {
                diagnosticStage = "claiming_successor"
                guard let factoryTicket = try registry.claimOutputSuccessor(claim),
                      let creation = registry.outputResourceContextSnapshot(),
                      creation.sourceTask == factoryTicket,
                      let candidateID = creation.candidateBackendIdentity,
                      let kind = creation.desiredBackendKind else {
                    diagnosticStage = "claimOutputSuccessor_guards_failed"
                    throw Self.audioSessionActivationFailure
                }
                backendIdentity = candidateID
                let relay = PlaybackSessionEventRelay(identity: runIdentity) { [weak self] identity, event in
                    await self?.receivePipelineEvent(event, identity: identity, backendIdentity: candidateID)
                }
                let relayGroup = try registry.createGroup(resource: .backend(candidateID), parent: creation.reservation.workGroup)
                let relayDrain = try registry.enqueue(group: relayGroup, slot: .accounting, policy: .routeNeutral)
                guard registry.bindEventRelay(relay, to: relayDrain),
                      registry.startOutputFactoryOperation(factoryTicket, input: .init(factory: backendFactory,
                        kind: kind, identity: candidateID, request: request, tuning: tuning, relay: relay))
                else {
                    diagnosticStage = "bind_or_startOutputFactory_failed"
                    throw Self.audioSessionActivationFailure
                }
                diagnosticStage = "joining_factory"
                switch await registry.joinOutputBackendOperation(factoryTicket) {
                case .succeeded:
                    diagnosticStage = "factory_succeeded"
                case .failed(let error):
                    diagnosticStage = "factory_failed_\(error)"
                    throw error
                case .canceled:
                    diagnosticStage = "factory_canceled"
                    return
                }
            } else {
                guard try registry.reprepareQuiescentOutput(rebase) != nil,
                      let installed = registry.outputResourceContextSnapshot(),
                      let candidateID = installed.candidateBackendIdentity else {
                    diagnosticStage = "reprepareQuiescentOutput_failed"
                    throw Self.audioSessionActivationFailure
                }
                backendIdentity = candidateID
            }

            guard let installed = registry.outputResourceContextSnapshot(), installed.phase == .installed,
                  installed.candidateBackendIdentity == backendIdentity,
                  let prepareCommand = installed.sourceTask, isCurrent(runIdentity),
                  registry.startOutputPrepareOperation(prepareCommand) else {
                diagnosticStage = "startOutputPrepare_guards_failed"
                return
            }
            diagnosticStage = "joining_prepare"
            switch await registry.joinOutputBackendOperation(prepareCommand) {
            case .succeeded:
                diagnosticStage = "prepare_succeeded"
            case .failed(let error):
                diagnosticStage = "prepare_failed_\(error)"
                throw error
            case .canceled:
                diagnosticStage = "prepare_canceled"
                return
            }
            guard let prepared = registry.outputResourceContextSnapshot(),
                  prepared.contextNonce == installed.contextNonce, prepared.prepared,
                  isCurrent(runIdentity) else {
                diagnosticStage = "prepared_guards_failed"
                return
            }
            #if DEBUG
            beforePresentationCommitForTesting?()
            #endif
            guard try publishInstalledPresentation() else {
                diagnosticStage = "publishInstalledPresentation_failed"
                return
            }
            if systemPauseRequired, !controllerState.userPaused {
                publish(resumeVetoRequired ? .paused(request) : .recovering(request))
            }
            diagnosticStage = "calling_startPreparedSampleBuffer"
            registry.startPreparedSampleBuffer(contextNonce: prepared.contextNonce, backendIdentity: backendIdentity,
                readinessCycle: controllerState.readinessCycle,
                initiallyPaused: controllerState.userPaused || systemPauseRequired)
            if !controllerState.userPaused && !systemPauseRequired {
                guard let activation = try registry.beginOutputActivation(contextNonce: prepared.contextNonce),
                      registry.startOutputActivationOperation(activation) else {
                    diagnosticStage = "startOutputActivation_failed"
                    return
                }
                diagnosticStage = "joining_activation"
                switch await registry.joinOutputBackendOperation(activation) {
                case .succeeded:
                    let isHLS = registry.outputResourceContextSnapshot()?.desiredBackendKind == .hlsAVPlayer
                    if rebase.successorClaim == nil || isHLS {
                        if isHLS {
                            _ = registry.completeSampleBufferReadiness(backendIdentity)
                            recoveryCoordinator.resetRecovery.resetFinished()
                        }
                        publish(.playing(request))
                    }
                    await watchdog.arm(activationEpoch: registry.clock.nowNanoseconds, hasObservedProgress: true)
                    diagnosticStage = isHLS ? "hls_playing" : "activation_succeeded_waiting_for_pipeline"
                case .failed(let error):
                    diagnosticStage = "activation_failed_\(error)"
                    throw error
                case .canceled:
                    diagnosticStage = "activation_canceled"
                    return
                }
            } else if controllerState.userPaused { publish(.paused(request)) }
            controllerState.activeRoutePorts = stableCommit.authority.semanticIdentity?.ports
            if resetActivationNonce != nil {
                recoveryCoordinator.resetRecovery.resetFinished()
            }

        } catch let error as PlaybackCoreError {
            guard isCurrent(runIdentity) else { return }
            if fromEventRelay {
                if let context = registry.outputResourceContextSnapshot() {
                    beginOwnedBackendTerminal(context: context, terminalState: .failed(Self.failure(for: error)))
                }
                return
            }
            registry.deactivateOutputEventRelays(session: sessionIdentity)
            finishPresentation(for: sessionIdentity)
            await joinOwnedSessionCleanup(reason: .terminal, terminalState: .failed(Self.failure(for: error)))
        } catch {
            guard isCurrent(runIdentity) else { return }
            if fromEventRelay {
                if let context = registry.outputResourceContextSnapshot() {
                    beginOwnedBackendTerminal(context: context, terminalState: .failed(Self.failure(for: .demuxOpen(-1))))
                }
                return
            }
            registry.deactivateOutputEventRelays(session: sessionIdentity)
            finishPresentation(for: sessionIdentity)
            await joinOwnedSessionCleanup(reason: .terminal, terminalState: .failed(Self.failure(for: .demuxOpen(-1))))
        }
    }

    public func setPaused(_ paused: Bool) async {
        guard let request = controllerState.request else { return }
        switch registry.playbackStateSnapshot() {
        case .failed, .stopped, .idle:
            return
        case .preparing, .buffering, .recovering, .playing, .paused:
            break
        }
        
        guard let context = registry.outputResourceContextSnapshot() else { return }
        let safety = registry.executor.safetyIngress.snapshot
        let sessionIdentity = context.sessionIdentity
        guard sessionIdentity.requestID == request.id else { return }
        if !paused, resumeVetoRequired {
            controllerState.userPaused = false
            publish(.paused(request))
            guard !interruptionActive, !resumeRequestInFlight,
                  let run = admittedRun, let lease = registry.audioSessionLease(session: sessionIdentity) else { return }
            await registry.joinOwnedTerminalCleanup()
            guard isCurrent(run) else { return }
            if let retained = registry.outputResourceContextSnapshot(), let owner = retained.owner,
               owner.reason == .recovery, retained.pendingReset == nil {
                _ = try? registry.finishRetainedOutputCleanup(owner: owner)
            }
            resumeRequestInFlight = true
            if !audioSessionOwner.requestResume(for: lease) { resumeRequestInFlight = false }
            if context.phase == .pendingLeaseAcquisition, resumeRequestInFlight {
                // 此session仍由原acquisition等待者消费真实active completion，不启动第二prepare。
                resumeVetoRequired = false
                systemPauseRequired = false
            }
            return
        }
        let userControl = OutputUserControlRequest(
            kind: paused ? .pause : .resume,
            sessionIdentity: sessionIdentity,
            expectedOwner: context.owner,
            contextNonce: context.contextNonce,
            interruptionEpoch: safety.interruptionEpoch,
            mediaServicesEpoch: safety.mediaServicesEpoch,
            resetPreRouteBinding: context.resetPreRouteBinding
        )
        let controlResult = registry.performOutputUserControl(userControl)
        if case .rejected = controlResult { return }
        
        guard controllerState.userPaused != paused else { return }
        controllerState.userPaused = paused
        advanceReadinessCycle()
        if context.phase == .pendingSuccessorLease {
            publish(paused ? .paused(request) : .recovering(request))
            guard !paused, let run = admittedRun else { return }
            if context.pendingReset != nil {
                await continueResetRecovery(identity: run)
            } else if !interruptionActive, let lease = registry.audioSessionLease(session: sessionIdentity) {
                await registry.joinOwnedTerminalCleanup()
                guard isCurrent(run) else { return }
                if let owner = registry.outputResourceContextSnapshot()?.owner {
                    _ = try? registry.finishRetainedOutputCleanup(owner: owner)
                }
                resumeRequestInFlight = audioSessionOwner.requestResume(for: lease)
            }
            return
        }
        if context.phase == .installed && !context.prepared {
            // prepare在原command中继续；只折叠意图，完成CAS之后才可领取一次activation。
            publish(paused ? .paused(request) : (systemPauseRequired ? .recovering(request) : .preparing(request)))
            return
        }
        
        if paused {
            let coordinator = OutputCleanupCoordinator(registry: registry)
            guard let owner = try? coordinator.begin(contextNonce: context.contextNonce,
                reason: .pause, at: registry.clock.nowNanoseconds), owner.reason == .pause,
                let original = registry.outputResourceContextSnapshot(), let stop = original.suspend,
                registry.startOutputSuspendOperation(stop.task, owner: owner) else { return }
            guard case .succeeded = await registry.joinOutputBackendOperation(stop.task),
                  registry.finishOutputPause(owner: owner) else { return }
            await watchdog.disarm()
            registry.updatePreparedSampleBufferPause(contextNonce: original.contextNonce,
                paused: true, readinessCycle: controllerState.readinessCycle)
            publish(.paused(request))
        } else if systemPauseRequired {
            publish(.recovering(request))
        } else {
            guard let activation = try? registry.beginOutputActivation(contextNonce: context.contextNonce),
                  registry.startOutputActivationOperation(activation) else { return }
            switch await registry.joinOutputBackendOperation(activation) {
            case .succeeded:
                await watchdog.arm(activationEpoch: registry.clock.nowNanoseconds, hasObservedProgress: true)
            case .failed:
                if let context = registry.outputResourceContextSnapshot() {
                    beginOwnedBackendTerminal(context: context, terminalState: .failed(Self.audioSessionActivationFailure))
                }
                return
            case .canceled: return
            }
            registry.updatePreparedSampleBufferPause(contextNonce: context.contextNonce,
                paused: false, readinessCycle: controllerState.readinessCycle)
            publish(.preparing(request))
        }
    }

    public func stop() async {
        recoveryCoordinator.cancelCurrentRecovery()
        await watchdog.disarm()
        terminalMetricsProvider = nil
        guard controllerState.request != nil || registry.cleanupReservationSnapshot() != nil else { return }
        let presentationSession = registry.outputResourceContextSnapshot()?.sessionIdentity
        if case .coldStart(let admitted) = registry.playbackRequestAdmissionSnapshot() {
            _ = registry.cancelPlaybackRequest(admitted.identity.sessionIdentity)
        }
        invalidateSession()
        clearMediaInformation()
        controllerState.request = nil
        controllerState.userPaused = false
        controllerState.readinessCycle = 0
        controllerState.activeRoutePorts = nil
        if let presentationSession {
            finishPresentation(for: presentationSession)
        } else {
            presentationRelay.finish()
        }
        
        await joinOwnedSessionCleanup(reason: .stop)
        guard registry.playbackRequestAdmissionSnapshot() == nil, admittedRun == nil else { return }
        if case .failed = registry.playbackStateSnapshot() { return }
        
        publish(.stopped)
    }

    private func joinOwnedSessionCleanup(reason: OutputTransitionReason, terminalState: PlaybackState = .stopped) async {
        guard let reservation = registry.cleanupReservationSnapshot()?.ticket,
              case .session(let session) = reservation.ownerGroup.resourceIdentity else { return }
        await registry.joinOwnedTerminalCleanup(session: session)
        guard let context = registry.outputResourceContextSnapshot(),
              context.sessionIdentity == session, context.reservation.ownerGroup == reservation.ownerGroup,
              let owner = try? registry.beginOutputTransition(contextNonce: context.contextNonce,
                reason: reason, anchorInstant: registry.clock.nowNanoseconds, teardown: true) else { return }
        guard registry.startOwnedTerminalCleanup(owner: owner, receiver: self, terminalState: terminalState) else {
            await registry.joinOwnedTerminalCleanup(session: session)
            return
        }
        await registry.joinOwnedTerminalCleanup(session: session)
    }

    private func teardownCurrentSession(
        reason: OutputTransitionReason = .stop,
        exactOwner: OutputTransitionOwnerTicket? = nil
    ) async {
        if let context = registry.outputResourceContextSnapshot() {
            let coordinator = OutputCleanupCoordinator(registry: registry)
            let now = registry.clock.nowNanoseconds
            if let owner = exactOwner ?? (try? coordinator.begin(
                contextNonce: context.contextNonce,
                reason: reason,
                at: now,
                teardown: true
            )), registry.outputResourceContextSnapshot()?.owner == owner {
                guard await registry.joinOutputBackendOperations(owner: owner) else { return }
                _ = try? coordinator.advance(owner: owner)
                guard await registry.joinOutputEventRelays(owner: owner) else { return }
                var previousTicket: ControlTaskTicket?
                var loopCount = 0
                while registry.outputResourceContextSnapshot()?.owner == owner,
                      registry.ownedResourceSnapshot() != nil {
                    guard let ticket = try? coordinator.advance(owner: owner) else {
                        guard await registry.waitForPlaybackProgress(.cleanup(owner)) else { return }
                        continue
                    }
                    loopCount += 1
                    if loopCount > 50 { break }
                    guard let reservation = registry.cleanupReservationSnapshot() else { break }
                    // 更强stop/terminal继承原recovery/pause suspend票，不能按预留槽猜其身份。
                    if ticket == registry.outputResourceContextSnapshot()?.suspend?.task {
                        let currentContext = registry.outputResourceContextSnapshot()
                        if let stop = currentContext?.suspend,
                           let invocation = registry.claimOutputBackendCleanup(ticket, owner: owner),
                           invocation.lifecycle == stop.lifecycle,
                           let suspendInvocation = invocation.suspendInvocation {
                            let result = await invocation.backend.suspendOutput(invocation: suspendInvocation)
                            _ = registry.completeOutputSuspend(result,
                                invocation: suspendInvocation,
                                backend: invocation.backend)
                        } else {
                            break
                        }
                    } else if ticket == reservation.task(for: .retirement) {
                        if let invocation = registry.claimOutputBackendCleanup(ticket, owner: owner),
                           let lifecycle = invocation.lifecycle {
                            let result = await invocation.backend.retireOutput(epoch: lifecycle)
                            #if DEBUG
                            PlaybackDiagnosticTracker.shared.append("teardown_retire_\(result)")
                            #endif
                            guard result == .confirmedLocalOutputStopped,
                                  coordinator.completeRetirement(ticket, lifecycle: lifecycle) else {
                                #if DEBUG
                                PlaybackDiagnosticTracker.shared.append("teardown_retire_failed_or_unconfirmed")
                                #endif
                                return
                            }
                        } else {
                            break
                        }
                    } else if ticket == reservation.task(for: .teardown) {
                        if let invocation = registry.claimOutputBackendCleanup(ticket, owner: owner) {
                            _ = coordinator.completeTeardown(ticket, backend: invocation.backend.identity,
                                contextNonce: invocation.contextNonce)
                        } else {
                            break
                        }
                    } else if ticket == reservation.task(for: .monitorStop) {
                        if registry.claimStart(ticket) {
                            let monitorLifecycle: UInt64?
                            if let snap = registry.ownedResourceSnapshot() {
                                switch snap.payload {
                                case .monitor(_, let lifecycle):
                                    monitorLifecycle = lifecycle
                                case .lease(_, _, let opt, _):
                                    monitorLifecycle = opt
                                case .backend(_, _, _, let opt, _):
                                    monitorLifecycle = opt
                                }
                            } else {
                                monitorLifecycle = nil
                            }
                            guard let monitorLifecycle else { break }
                            routeService?.unbindSession()
                            _ = coordinator.completeMonitorStop(ticket, lifecycle: monitorLifecycle)
                        } else {
                            break
                        }
                    } else if ticket == reservation.task(for: .audioSession) {
                        _ = audioSessionOwner.invoke(ticket, receiver: defaultReceiver)
                        while true {
                            let snap = registry.outputResourceContextSnapshot()
                            if snap?.owner == nil || registry.cleanupReservationSnapshot() == nil { break }
                            if (try? coordinator.advance(owner: owner)) != ticket { break }
                            guard await registry.waitForPlaybackProgress(.cleanup(owner)) else { return }
                        }
                        if (try? coordinator.advance(owner: owner)) == ticket {
                            break
                        }
                    } else if ticket == reservation.task(for: .leaseRelease) {
                        if let _ = registry.claimOwnedResourceReleaseRunner(ticket) {
                            _ = registry.complete(ticket)
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                    if ticket == previousTicket {
                        break
                    }
                    previousTicket = ticket
                }
                
                if registry.ownedResourceSnapshot() == nil, let reservation = registry.cleanupReservationSnapshot() {
                    // recovery升级stop可复用未承诺槽的原owner；不能按预留槽补造另一张完成票。
                    if let originalOwnerTask = registry.outputCleanupOwnerTask(owner) {
                        _ = registry.complete(originalOwnerTask)
                    }
                    _ = registry.releaseCleanupReservation(reservation.ticket)
                }
            }
        } else {
            _ = registry.cancelAcquisitionSession()
        }
        
        routeService?.unbindSession()
    }

    public func setTuning(_ tuning: PlaybackTuning) async {
        self.tuning = tuning
        registry.updateInstalledSampleBufferTuning(tuning)
    }

    public func playbackMetricsSnapshot(window: Duration) -> PlaybackMetricsSnapshot? {
        if let real = registry.metricsProjection(window: window)
            ?? terminalMetricsProvider?.snapshot(window: window) {
            return real
        }
        #if DEBUG
        return PlaybackMetricsSnapshot.diagnosticPlaceholder()
        #else
        return nil
        #endif
    }

    func publishRouteRecovering(request: PlaybackRequest) {
        publish(.recovering(request))
    }

    func publishRouteUnavailableFailure() {
        publish(.failed(Self.routeUnavailableFailure))
    }

    func handleRouteCommit(_ commit: StableRouteCommitIdentity) async {
        recoveryCoordinator.cancelRouteUnavailableTimeout()
        guard let request = controllerState.request, let runIdentity = admittedRun, isCurrent(runIdentity) else {
            return
        }
        guard let context = registry.outputResourceContextSnapshot(), context.sessionIdentity.requestID == request.id else {
            return
        }
        let ports = commit.authority.semanticIdentity?.ports ?? []
        if ports.isEmpty {
            await handleRouteUnavailable(runIdentity: runIdentity, request: request)
            return
        }
        if context.owner != nil {
            return
        }
        guard let targetKind = commit.authority.semanticIdentity?.backend else {
            return
        }
        guard let currentKind = context.desiredBackendKind else {
            return
        }
        if targetKind != currentKind {
            await requestRouteHandoff(to: targetKind)
        } else {
            let activePorts = controllerState.activeRoutePorts
            if activePorts == nil {
                controllerState.activeRoutePorts = ports
                await resumeActiveOutputFromRouteRecovery()
            } else if activePorts != ports {
                await requestQuiescentEndpointHandoff()
            }
        }
    }

    func handleRouteUnavailableFromService() async {
        guard let request = controllerState.request, let runIdentity = admittedRun, isCurrent(runIdentity) else {
            return
        }
        await handleRouteUnavailable(runIdentity: runIdentity, request: request)
    }

    func handleRouteUnavailable(runIdentity: PlaybackRunIdentity, request: PlaybackRequest) async {
        await suspendActiveOutputForRouteUnavailable()
        recoveryCoordinator.handleRouteUnavailable(controller: self, runIdentity: runIdentity, request: request)
    }

    func suspendActiveOutputForRouteUnavailable() async {
        guard let request = controllerState.request else { return }
        publishRouteRecovering(request: request)
        controllerState.activeRoutePorts = nil
        guard let context = registry.outputResourceContextSnapshot(),
              context.owner == nil, context.phase == .installed, context.prepared else {
            return
        }
        let coordinator = OutputCleanupCoordinator(registry: registry)
        guard let owner = try? coordinator.begin(contextNonce: context.contextNonce,
            reason: .pause, at: registry.clock.nowNanoseconds), owner.reason == .pause,
            let original = registry.outputResourceContextSnapshot(), let stop = original.suspend,
            registry.startOutputSuspendOperation(stop.task, owner: owner) else {
            return
        }
        guard case .succeeded = await registry.joinOutputBackendOperation(stop.task),
              registry.finishOutputPause(owner: owner) else {
            return
        }
        registry.updatePreparedSampleBufferPause(contextNonce: original.contextNonce,
            paused: true, readinessCycle: controllerState.readinessCycle)
    }

    func resumeActiveOutputFromRouteRecovery() async {
        guard let request = controllerState.request, !controllerState.userPaused,
              let context = registry.outputResourceContextSnapshot(),
              context.owner == nil, context.phase == .installed, context.prepared else {
            return
        }
        registry.updatePreparedSampleBufferPause(contextNonce: context.contextNonce,
            paused: false, readinessCycle: controllerState.readinessCycle)
        guard let activation = try? registry.beginOutputActivation(contextNonce: context.contextNonce),
              registry.startOutputActivationOperation(activation) else {
            return
        }
        let outcome = await registry.joinOutputBackendOperation(activation)
        switch outcome {
        case .succeeded:
            publish(.playing(request))
        default:
            break
        }
    }

    func handleRouteUnavailableTimeout() async {
        if let context = registry.outputResourceContextSnapshot() {
            beginOwnedBackendTerminal(context: context, terminalState: .failed(Self.routeUnavailableFailure))
            await registry.joinOwnedTerminalCleanup(session: context.sessionIdentity)
        } else {
            publishRouteUnavailableFailure()
            await stop()
        }
    }

    func handleWatchdogRecovery(reason: HLSPlaybackWatchdog.TriggerReason) async {
        guard controllerState.request != nil, admittedRun != nil else { return }
        switch reason {
        case .playbackStalled, .bufferStarvation, .playbackBacklogExceeded:
            await requestQuiescentEndpointHandoff()
        case .prepareBacklogExceeded, .hardCapacityExceeded:
            if let context = registry.outputResourceContextSnapshot() {
                beginOwnedBackendTerminal(context: context, terminalState: .failed(Self.watchdogHardCapacityFailure))
                await registry.joinOwnedTerminalCleanup(session: context.sessionIdentity)
            } else {
                await stop()
            }
        }
    }

    func requestQuiescentEndpointHandoff() async {
        guard let request = controllerState.request, let runIdentity = admittedRun,
              let context = registry.outputResourceContextSnapshot(),
              context.sessionIdentity.requestID == request.id,
              let admission = try? registry.admitOutputQuiescentEndpointHandoff(session: context.sessionIdentity) else { return }
        guard admission.startsCleanup else { return }
        clearPresentation()
        advanceReadinessCycle()
        publish(.recovering(request))
        guard registry.startOwnedInterruptionCleanup(owner: admission.owner, receiver: self) else { return }
        await registry.joinOwnedTerminalCleanup()
        guard isCurrent(runIdentity),
              let retained = registry.outputResourceContextSnapshot(),
              retained.owner == admission.owner, retained.phase == .quiescentBackend,
              let nonce = try? registry.finishRetainedOutputCleanup(owner: admission.owner) else { return }
        await prepareSuccessor(request: request, runIdentity: runIdentity,
            contextNonce: nonce, owner: admission.owner)
    }

    func requestRouteHandoff(to kind: PlaybackBackendKind) async {
        guard let request = controllerState.request, let runIdentity = admittedRun,
              let context = registry.outputResourceContextSnapshot(),
              context.sessionIdentity.requestID == request.id,
              let admission = try? registry.admitOutputHandoff(session: context.sessionIdentity, requestedKind: kind) else { return }
        guard admission.startsCleanup else { return }
        clearPresentation()
        advanceReadinessCycle()
        publish(.recovering(request))
        guard registry.startOwnedInterruptionCleanup(owner: admission.owner, receiver: self) else { return }
        await registry.joinOwnedTerminalCleanup()
        guard isCurrent(runIdentity),
              let retained = registry.outputResourceContextSnapshot(),
              retained.owner == admission.owner, retained.phase == .pendingSuccessorLease,
              let nonce = try? registry.finishRetainedOutputCleanup(owner: admission.owner) else { return }
        routeService?.resample(reason: .routeConfigurationChange)
        await prepareSuccessor(request: request, runIdentity: runIdentity,
            contextNonce: nonce, owner: admission.owner)
    }

    private func retireRetainedBackend(owner: OutputTransitionOwnerTicket) async {
        guard let context = registry.outputResourceContextSnapshot(), context.owner == owner else { return }
        // 已无backend时不能advance到monitorStop；该排空只退休data plane，lease/monitor继续由原图持有。
        // 否则第二began/reset会遗留一张queued monitorStop，阻止原cycle退休与新proof配置。
        if context.phase == .pendingSuccessorLease || context.phase == .quiescentBackend { return }
        let coordinator = OutputCleanupCoordinator(registry: registry)
        guard await registry.joinOutputBackendOperations(owner: owner) else { return }
        _ = try? coordinator.advance(owner: owner)
        guard await registry.joinOutputEventRelays(owner: owner, pipelineOnly: true) else { return }
        while let currentPhase = registry.outputResourceContextSnapshot()?.phase,
              currentPhase != .pendingSuccessorLease && currentPhase != .quiescentBackend,
              let ticket = try? coordinator.advance(owner: owner) {
            guard let context = registry.outputResourceContextSnapshot(), context.owner == owner else { return }
            if let stop = context.suspend, stop.task == ticket {
                guard let invocation = registry.claimOutputBackendCleanup(ticket, owner: owner),
                      invocation.lifecycle == stop.lifecycle,
                      let suspendInvocation = invocation.suspendInvocation else { return }
                let result = await invocation.backend.suspendOutput(invocation: suspendInvocation)
                guard registry.completeOutputSuspend(result,
                    invocation: suspendInvocation,
                    backend: invocation.backend) else { return }
            } else if context.retirement == ticket {
                guard let invocation = registry.claimOutputBackendCleanup(ticket, owner: owner),
                      let lifecycle = invocation.lifecycle else { return }
                let result = await invocation.backend.retireOutput(epoch: lifecycle)
                #if DEBUG
                PlaybackDiagnosticTracker.shared.append("context_retire_\(result)")
                #endif
                guard result == .confirmedLocalOutputStopped,
                      coordinator.completeRetirement(ticket, lifecycle: lifecycle) else {
                    #if DEBUG
                    PlaybackDiagnosticTracker.shared.append("context_retire_failed_or_unconfirmed")
                    #endif
                    return
                }
            } else if context.teardown == ticket {
                guard let invocation = registry.claimOutputBackendCleanup(ticket, owner: owner) else { return }
                guard coordinator.completeTeardown(ticket, backend: invocation.backend.identity,
                    contextNonce: invocation.contextNonce) != nil else { return }
            } else { return }
        }
    }

    func performOwnedInterruptionCleanup(owner: OutputTransitionOwnerTicket, task: ControlTaskTicket) async {
        await retireRetainedBackend(owner: owner)
        // 原SDK退场、pipeline relay join及work终态全部完成后才可形成proof。
        guard registry.outputCleanupOwnerTask(owner) == task else { return }
        _ = registry.settleOutputInterruptionDrain(owner: owner)
        // body返回，record仍持有Task；ended/explicit-resume或stop从外部准确join。
    }

    private func continueResetRecovery(identity: PlaybackRunIdentity) async {
        guard let original = registry.outputResourceContextSnapshot(), let root = original.pendingReset,
              original.disposition != .releaseAfterTeardown, !original.poisoned else { return }
        if original.systemRecoveryBinding == nil {
            // 新reset必须封口当前cycle；此前ended(false)留下的retained owner不是本次排空证明。
            if let owner = original.owner {
                guard await registry.finishAudioEventRecoveryDisposition(owner: owner) else { return }
            }
            guard isCurrent(identity), let current = registry.outputResourceContextSnapshot(),
                  current.contextNonce == original.contextNonce, current.pendingReset == root,
                  let owner = try? registry.beginOutputTransition(contextNonce: current.contextNonce,
                reason: .recovery, anchorInstant: registry.clock.nowNanoseconds, teardown: true) else { return }
            clearPresentation()
            guard registry.startOwnedInterruptionCleanup(owner: owner, receiver: self) else { return }
        }
        // 此runner仅join pipeline；audio receiver可以等待它，不能等待terminal release runner。
        guard let cleanup = registry.outputResourceContextSnapshot()?.owner, cleanup.reason == .recovery else { return }
        guard await registry.finishAudioEventRecoveryDisposition(owner: cleanup) else { return }
        guard isCurrent(identity), let context = registry.outputResourceContextSnapshot(),
              context.owner == cleanup, context.pendingReset == root,
              context.phase == .pendingSuccessorLease else { return }
        let next: ControlTaskTicket?
        if context.systemRecoveryBinding == nil {
            let isHLS = context.desiredBackendKind == .hlsAVPlayer
            let suffix = recoveryCoordinator.resetRecovery.recordReset(at: registry.clock.nowNanoseconds, isHLS: isHLS)
            next = try? registry.beginRetainedOutputResetConfiguration(owner: cleanup,
                mandatorySuffix: suffix)
        } else {
            // 配置可在began期间完成，但真实activation必须重新经过Cell proof/epoch gate。
            next = try? registry.beginOutputResetConfigurationActivation(contextNonce: context.contextNonce)
        }
        if let next { _ = audioSessionOwner.invoke(next, receiver: audioSessionOwner) }
    }

    var currentStateForTesting: PlaybackState { registry.playbackStateSnapshot() }
    var audioSessionInterruptedForTesting: Bool { interruptionActive }
    var readinessCycleForTesting: UInt64 { controllerState.readinessCycle }

    func receiveAudioSessionEvent(
        _ key: PlaybackAudioSessionEventKey,
        lease: PlaybackAudioSessionLease,
        identity: PlaybackRunIdentity,
        drain: ControlTaskTicket
    ) async {
        guard isCurrent(identity),
              let request = controllerState.request,
              let envelope = registry.consumeAudioSessionEvent(key, run: identity, lease: lease, drain: drain)
        else { return }
        let event = envelope.event
        switch event {
        case .interruptionBegan:
            guard !interruptionActive else { return }
            interruptionActive = true
            systemPauseRequired = true
            advanceReadinessCycle()
            // framework安全事件一经当前relay确认，旧画面必须在任何cleanup join/await前失权。
            clearPresentation()
            if !controllerState.userPaused {
                publish(resumeVetoRequired ? .paused(request) : .recovering(request))
            }
            if registry.outputResourceContextSnapshot()?.systemRecoveryBinding != nil {
                // reset安全配置可以继续；新began只使原activation失效，不能取消整个配置cycle。
                await continueResetRecovery(identity: identity)
                return
            }
            if let previous = registry.outputResourceContextSnapshot(), previous.owner?.reason == .recovery {
                guard let owner = previous.owner,
                      await registry.finishAudioEventRecoveryDisposition(owner: owner) else { return }
            }
            if isCurrent(identity), let context = registry.outputResourceContextSnapshot(),
               context.owner == nil || context.owner?.reason == .recovery,
               let owner = try? OutputCleanupCoordinator(registry: registry).begin(
                contextNonce: context.contextNonce, reason: .recovery,
                at: registry.clock.nowNanoseconds, teardown: true) {
                clearPresentation()
                _ = registry.startOwnedInterruptionCleanup(owner: owner, receiver: self)
            }
        case .mediaServicesWereReset:
            systemPauseRequired = true
            advanceReadinessCycle()
            clearPresentation()
            if !controllerState.userPaused {
                publish(resumeVetoRequired ? .paused(request) : .recovering(request))
            }
            await continueResetRecovery(identity: identity)
        case let .interruptionEnded(shouldResume):
            interruptionActive = false
            resumeRequestInFlight = false
            resumeVetoRequired = !shouldResume
            systemPauseRequired = true
            if !controllerState.userPaused { publish(shouldResume ? .recovering(request) : .paused(request)) }
            if registry.outputResourceContextSnapshot()?.pendingReset != nil {
                await continueResetRecovery(identity: identity)
                return
            }
            guard let run = admittedRun, let context = registry.outputResourceContextSnapshot(),
                  let owner = context.owner, owner.reason == .recovery else { return }
            // 这里只join另一条cleanup任务；它仅join pipeline，不会等待本audio receiver。
            guard await registry.finishAudioEventRecoveryDisposition(owner: owner) else { return }
            guard isCurrent(run), registry.outputResourceContextSnapshot()?.owner == owner else { return }
            guard shouldResume, !controllerState.userPaused,
                  let lease = registry.audioSessionLease(session: context.sessionIdentity) else { return }
            _ = try? registry.finishRetainedOutputCleanup(owner: owner)
            resumeRequestInFlight = audioSessionOwner.requestResume(for: lease)
        case .explicitResumeSucceeded, .resetConfigurationSucceeded:
            resumeRequestInFlight = false
            guard systemPauseRequired, !interruptionActive,
                  let run = admittedRun, let context = registry.outputResourceContextSnapshot() else { return }
            resumeVetoRequired = false
            systemPauseRequired = false
            guard !controllerState.userPaused else { return }
            publish(.preparing(request))
            if case .pending(let pending) = registry.outputRouteObservationSnapshot(), let sampler = pending.sampler {
                _ = audioSessionOwner.sample(sampler, receiver: routeService ?? defaultReceiver)
            }
            await prepareSuccessor(request: request, runIdentity: run, contextNonce: context.contextNonce,
                owner: context.owner, fromEventRelay: true,
                resetActivationNonce: event == .resetConfigurationSucceeded ? envelope.reactivationReceipt?.activationNonce : nil)
        case .recoveryFailed:
            guard let original = registry.outputResourceContextSnapshot() else { return }
            // recovery runner只join pipeline；先等它归还原SDK责任，不能改其owner。
            // 已有release runner则由它join本receiver，绝不反向等待形成环。
            if let owner = original.owner {
                guard owner.reason == .recovery else { return }
                guard await registry.finishAudioEventRecoveryDisposition(owner: owner) else { return }
            }
            guard isCurrent(identity), let context = registry.outputResourceContextSnapshot(),
                  context.contextNonce == original.contextNonce, context.owner == original.owner else { return }
            terminalMetricsProvider = registry.terminalMetricsProjection(backendIdentity: original.candidateBackendIdentity)
            beginOwnedBackendTerminal(context: context, terminalState: .failed(Self.audioSessionActivationFailure))
        }
    }

    private func receivePipelineEvent(_ event: PlaybackPipelineEvent, identity: PlaybackRunIdentity,
        backendIdentity: PlaybackBackendIdentity) async {
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("pipeline_event_received")
        #endif
        guard isCurrent(identity) else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("pipeline_event_not_current_identity")
            #endif
            return
        }
        guard let context = registry.outputResourceContextSnapshot() else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("pipeline_event_no_context")
            #endif
            return
        }
        guard context.owner == nil else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("pipeline_event_has_owner")
            #endif
            return
        }
        guard context.phase == .installed else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("pipeline_event_phase_\(context.phase)")
            #endif
            return
        }
        guard context.candidateBackendIdentity == backendIdentity else {
            #if DEBUG
            PlaybackDiagnosticTracker.shared.set("pipeline_event_backend_mismatch")
            #endif
            return
        }
        #if DEBUG
        PlaybackDiagnosticTracker.shared.set("pipeline_event_dispatched")
        #endif
        switch event {
        case let .mediaInformation(information, generation: eventGeneration?):
            guard mediaGeneration.map({ eventGeneration >= $0 }) ?? true else { return }
            if mediaGeneration != eventGeneration {
                mediaGeneration = eventGeneration
                if currentMediaInformation != nil, information != nil {
                    publishMediaInformation(nil)
                }
            }
            publishMediaInformation(information)
        case let .mediaInformation(information, generation: nil):
            publishMediaInformation(information)
        case let .ready(eventCycle):
            let readinessResult = registry.completeSampleBufferReadiness(backendIdentity)
            guard let request = controllerState.request,
                  !controllerState.userPaused,
                  !systemPauseRequired,
                  eventCycle == controllerState.readinessCycle,
                  readinessResult else { return }
            recoveryCoordinator.resetRecovery.resetFinished()
            publish(.playing(request))
        case let .phase(phase, eventCycle):
            guard let request = controllerState.request,
                  !controllerState.userPaused,
                  !systemPauseRequired,
                  !resumeVetoRequired,
                  eventCycle == controllerState.readinessCycle else { return }
            switch phase {
            case .buffering:
                publish(.buffering(request))
            case .recovering:
                publish(.recovering(request))
            }
        case .stopped:
            beginOwnedBackendTerminal(context: context, terminalState: .stopped)
        case let .failed(error):
            terminalMetricsProvider = registry.terminalMetricsProjection(backendIdentity: backendIdentity)
            beginOwnedBackendTerminal(context: context, terminalState: .failed(Self.failure(for: error)))
        }
    }

    private func beginOwnedBackendTerminal(context: OutputResourceContext, terminalState: PlaybackState) {
        guard let owner = try? registry.beginOutputTransition(contextNonce: context.contextNonce,
            reason: .terminal, anchorInstant: registry.clock.nowNanoseconds, teardown: true) else { return }
        finishPresentation(for: context.sessionIdentity, requiring: owner)
        _ = registry.cancelPlaybackRequest(context.sessionIdentity)
        invalidateSession()
        controllerState.request = nil
        controllerState.userPaused = false
        controllerState.activeRoutePorts = nil
        clearMediaInformation()
        _ = registry.startOwnedTerminalCleanup(owner: owner, receiver: self, terminalState: terminalState)
    }

    func performOwnedTerminalCleanup(owner: OutputTransitionOwnerTicket,
        task: ControlTaskTicket, terminalState: PlaybackState) async {
        if let context = registry.outputResourceContextSnapshot(), context.owner == owner {
            // automatic fail-closed也必须先交付nil/EOF，之后才允许任何await或backend teardown。
            finishPresentation(for: context.sessionIdentity, requiring: owner)
        }
        let automaticFailure = registry.outputResourceContextSnapshot()?.poisoned == true
        if let context = registry.outputResourceContextSnapshot(), context.owner == owner,
           admittedRun?.sessionID == context.sessionIdentity.sessionID {
            _ = registry.cancelPlaybackRequest(context.sessionIdentity)
            invalidateSession()
            controllerState.request = nil
            controllerState.userPaused = false
            controllerState.activeRoutePorts = nil
            clearMediaInformation()
        }
        await teardownCurrentSession(reason: .terminal, exactOwner: owner)
        guard registry.finishOwnedCleanupResources(task, owner: owner),
              registry.playbackRequestAdmissionSnapshot() == nil, admittedRun == nil else { return }
        if !automaticFailure {
            if case .failed = registry.playbackStateSnapshot() { return }
            publish(terminalState)
        }
    }

    private func invalidateSession() {
        interruptionActive = false
        systemPauseRequired = false
        resumeVetoRequired = false
        resumeRequestInFlight = false
        if let context = registry.outputResourceContextSnapshot() {
            registry.deactivateOutputEventRelays(session: context.sessionIdentity)
        }
    }

    private func isCurrent(_ identity: PlaybackRunIdentity) -> Bool {
        guard admittedRun == identity,
              case .coldStart(let admission) = registry.playbackRequestAdmissionSnapshot() else { return false }
        return admission.identity.sessionIdentity == PlaybackSessionIdentity(
            sessionID: identity.sessionID, requestID: identity.requestID)
    }

    private func advanceReadinessCycle() {
        if controllerState.readinessCycle < UInt64.max {
            controllerState.readinessCycle += 1
        }
    }

    private func publish(_ newState: PlaybackState) {
        registry.publishState(newState)
    }

    private func publishInstalledPresentation() throws -> Bool {
        switch try registry.commitInstalledPresentation(to: presentationRelay) {
        case .committed:
            return true
        case .supersededBySafety:
            return false
        }
    }

    private func clearPresentation() {
        do {
            try presentationRelay.replace(with: nil)
        } catch PlaybackPresentationRelayError.identitySpaceExhausted {
            registry.failPresentationControl()
        } catch {}
    }

    private func finishPresentation(
        for session: PlaybackSessionIdentity,
        requiring owner: OutputTransitionOwnerTicket? = nil
    ) {
        guard finishedPresentationSession != session else { return }
        if let owner {
            guard let context = registry.outputResourceContextSnapshot(),
                  context.sessionIdentity == session,
                  context.owner == owner else { return }
        }
        finishedPresentationSession = session
        presentationRelay.finish()
    }

    private func publishMediaInformation(_ information: PlaybackMediaInformation?) {
        currentMediaInformation = information
        registry.publishMediaInformation(information)
    }

    private func clearMediaInformation() {
        guard currentMediaInformation != nil || mediaGeneration != nil else { return }
        mediaGeneration = nil
        publishMediaInformation(nil)
    }

    static func failure(for error: PlaybackCoreError) -> PlaybackFailure {
        let mapped = switch error {
        case .unsupportedProtocol:
            PlaybackFailure(code: "protocol.unsupported", userMessage: "不支持此播放协议，请使用 HTTP 或 HTTPS 地址。")
        case .demuxOpen:
            PlaybackFailure(code: "demux.open", userMessage: "无法打开频道流，请检查地址和网络后重试。")
        case .demuxRead:
            PlaybackFailure(code: "demux.read", userMessage: "读取频道流失败，请检查网络后重试。")
        case .networkTimeout:
            PlaybackFailure(code: "network.timeout", userMessage: "连接频道超时，请检查网络后重试。")
        case .unsupportedVideoCodec:
            PlaybackFailure(code: "video.codec", userMessage: "不支持此频道的视频编码，请尝试其他频道。")
        case .unsupportedAudioCodec:
            PlaybackFailure(code: "audio.codec", userMessage: "不支持此频道的音频编码，请尝试其他频道。")
        case .videoFormatDescription:
            PlaybackFailure(code: "video.format", userMessage: "无法解析视频格式，请尝试其他频道。")
        case .hardwareDecoderUnavailable:
            PlaybackFailure(code: "video.hardware", userMessage: "硬件视频解码器不可用，请稍后重试。")
        case .videoDecoderTransitionTimeout:
            PlaybackFailure(
                code: "video.decoder-timeout",
                userMessage: "视频解码器响应超时，请稍后重试。",
                diagnosticCode: "video.decoder-transition.timeout"
            )
        case let .videoDecode(status):
            PlaybackFailure(
                code: "video.decode",
                userMessage: "视频解码失败，请尝试其他频道。",
                diagnosticCode: "video.decode.status.\(status)"
            )
        case let .videoSampleBuffer(reason):
            PlaybackFailure(
                code: "video.sample-buffer",
                userMessage: "视频帧处理失败，请稍后重试。",
                diagnosticCode: "video.sample-buffer.reason.\(safeRendererReason(reason))"
            )
        case let .videoRendererFailed(reason):
            PlaybackFailure(
                code: "video.renderer",
                userMessage: "视频输出失败，请稍后重试。",
                diagnosticCode: "video.renderer.reason.\(safeRendererReason(reason))"
            )
        case .audioFormatDescription:
            PlaybackFailure(code: "audio.format", userMessage: "无法解析音频格式，请尝试其他频道。")
        case let .audioFallbackDecode(status):
            PlaybackFailure(
                code: "audio.decode",
                userMessage: "音频解码失败，请尝试其他频道。",
                diagnosticCode: "audio.decode.status.\(status)"
            )
        case let .audioRendererFailed(reason):
            PlaybackFailure(
                code: "audio.renderer",
                userMessage: "音频输出失败，请检查播放设备后重试。",
                diagnosticCode: "audio.renderer.reason.\(safeRendererReason(reason))"
            )
        case .renderTextureMapping:
            PlaybackFailure(code: "video.texture", userMessage: "视频纹理处理失败，请稍后重试。")
        case .metalCommand:
            PlaybackFailure(code: "metal.command", userMessage: "视频渲染失败，请稍后重试。")
        case .cancelled:
            PlaybackFailure(code: "playback.cancelled", userMessage: "播放已取消，请重新选择频道。")
        case .controlEventCapacityExceeded:
            PlaybackFailure(code: "playback.control-capacity", userMessage: "播放控制事件超出安全容量，播放已停止。")
        }
        return PlaybackFailure(
            code: mapped.code,
            userMessage: mapped.userMessage,
            diagnosticCode: mapped.diagnosticCode,
            retryDisposition: error.retryDisposition
        )
    }

    private static func safeRendererReason(_ reason: String) -> String {
        guard !reason.isEmpty, reason.utf8.count <= 128,
              reason.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45...46, 48...58, 65...90, 95, 97...122:
                      true
                  default:
                      false
                  }
              }) else { return "unknown" }
        return reason
    }
}
