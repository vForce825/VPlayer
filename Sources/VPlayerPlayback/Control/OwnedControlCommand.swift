// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

struct PlaybackStateSubscription: Sendable {
    let token: UInt64
    let continuation: AsyncStream<PlaybackState>.Continuation
}

struct PlaybackMediaSubscription: Sendable {
    let token: UInt64
    let continuation: AsyncStream<PlaybackMediaInformation?>.Continuation
}

enum PlaybackBackendOperationResult: Sendable {
    case succeeded
    case failed(PlaybackCoreError)
    case canceled
}

/// 只有具名backend操作，不能接受任意closure或扩张任务池。
final class OwnedPlaybackBackendOperation: @unchecked Sendable {
    struct FactoryInput: Sendable {
        let factory: any PlaybackBackendFactory
        let kind: PlaybackBackendKind
        let identity: PlaybackBackendIdentity
        let request: PlaybackRequest
        let tuning: PlaybackTuning
        let relay: PlaybackSessionEventRelay
    }
    enum Operation: Sendable {
        case factory(FactoryInput)
        case prepare
        case activation
        case suspend
        var slot: ControlTaskSlot {
            switch self { case .factory: .factory; case .prepare: .prepare; case .activation: .activation; case .suspend: .suspend }
        }
    }
    let operation: Operation
    var task: Task<Void, Never>?
    var result: PlaybackBackendOperationResult?
    var factoryResult: OwnedFactoryResult?
    init(operation: Operation) { self.operation = operation }
}

enum ControlResourceIdentity: Sendable, Equatable {
    case session(PlaybackSessionIdentity)
    case backend(PlaybackBackendIdentity)
    case outputLifecycle(OutputLifecycleEpoch)
    case lease(session: PlaybackSessionIdentity, leaseID: UInt64)
    case monitor(session: PlaybackSessionIdentity, lifecycle: UInt64)
    case context(session: PlaybackSessionIdentity, nonce: UInt64)
}
struct ControlTaskOwnerTicket: Sendable, Equatable {
    let resourceIdentity: ControlResourceIdentity
    let nonce: UInt64
}
struct ControlTaskGroupTicket: Sendable, Equatable {
    let resourceIdentity: ControlResourceIdentity
    let ownerTicket: ControlTaskOwnerTicket
    let nonce: UInt64
}
struct ControlTaskTicket: Sendable, Equatable {
    let group: ControlTaskGroupTicket
    let nonce: UInt64
}

/// 仅在完整票通过自洽性校验后冻结；投影不查询当前 Registry，也不丢弃 parent 自身资源。
struct FrozenControlTaskGroupTicket: Sendable {
    private let resource: ControlResourceIdentity
    private let ownerNonce: UInt64
    private let groupNonce: UInt64

    init(_ ticket: ControlTaskGroupTicket) throws {
        guard ticket.resourceIdentity == ticket.ownerTicket.resourceIdentity else {
            throw ControlTaskRegistry.Failure.invalidGroup
        }
        resource = ticket.resourceIdentity
        ownerNonce = ticket.ownerTicket.nonce
        groupNonce = ticket.nonce
    }

    var ticket: ControlTaskGroupTicket {
        .init(resourceIdentity: resource,
            ownerTicket: .init(resourceIdentity: resource, nonce: ownerNonce), nonce: groupNonce)
    }
}
enum ControlTaskSlot: Sendable, Equatable {
    case acquire, factory, prepare, candidateItem, probe, activation, accounting, audioSessionRecovery
    case sampler, cancel, suspend, retirement, candidateCleanup, committedCleanup, teardown, monitorStop, leaseRelease, systemEventRelay

    var requiredPolicy: ControlGatePolicy {
        switch self {
        case .acquire, .accounting: .routeNeutral
        case .factory, .prepare, .candidateItem, .probe: .routeSpeculativeRateZero
        case .activation: .activationRequiresOpen
        case .audioSessionRecovery: .audioSession
        case .sampler, .cancel, .suspend, .retirement, .candidateCleanup, .committedCleanup,
             .teardown, .monitorStop, .leaseRelease, .systemEventRelay: .safetyBypass
        }
    }
}
enum ControlGatePolicy: Sendable, Equatable {
    case activationRequiresOpen, safetyBypass, routeSpeculativeRateZero, routeNeutral, audioSession
}
enum ControlTaskTerminal: Sendable, Equatable { case canceled, completed }
enum ControlTaskPhase: Sendable, Equatable {
    case queued, running, cancelRequested, terminal(ControlTaskTerminal)
}

struct ControlSystemSafetySnapshot: Sendable, Equatable {
    let mediaServicesEpoch: UInt64
    let interruptionEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64
    init(_ snapshot: PlaybackSafetySnapshot) {
        mediaServicesEpoch = snapshot.mediaServicesEpoch
        interruptionEpoch = snapshot.interruptionEpoch
        audioAdmissionFenceRevision = snapshot.audioAdmissionFenceRevision
    }
}

enum ControlCommandSafetySnapshot: Sendable, Equatable {
    case cleanupOwnership
    // lease reservation跨route/interruption继续，由事务取消或media-services reset终止。
    case reservation(mediaServicesEpoch: UInt64)
    case system(ControlSystemSafetySnapshot)
    case speculative(ControlSystemSafetySnapshot, PlaybackRouteSemanticIdentity?)
}

/// call的原票和phase已经由同一record保存；这里只存不可变的物理终态。
enum OwnedAudioSessionActivationResult: Sendable {
    case notInvoked
    case returnedFailure(AudioSessionFixedFailure)
    case returnedSuccess
}

/// 仅在原 owner 相等后去掉重复 owner；独立 session/lease/context/epoch 保持原值。
struct FrozenCommandAudioPhase: Sendable {
    private let session: PlaybackSessionIdentity
    private let lease: UInt64
    private let context: UInt64
    private let mediaServices: UInt64
    private let nonce: UInt64

    fileprivate init(_ phase: AudioSessionPhaseIdentity, owner: ControlTaskOwnerTicket) throws {
        guard phase.owner == owner else { throw ControlTaskRegistry.Failure.invalidGroup }
        session = phase.sessionIdentity; lease = phase.leaseID; context = phase.contextNonce
        mediaServices = phase.mediaServicesEpoch; nonce = phase.phaseNonce
    }
    fileprivate func phase(owner: ControlTaskOwnerTicket) -> AudioSessionPhaseIdentity {
        .init(owner: owner, sessionIdentity: session, leaseID: lease, contextNonce: context,
              mediaServicesEpoch: mediaServices, phaseNonce: nonce)
    }
}

struct FrozenCommandAudioCall: Sendable {
    private let group: FrozenControlTaskGroupTicket
    private let nonce: UInt64
    private let phase: FrozenCommandAudioPhase
    fileprivate init(_ call: AudioSessionCallIdentity) throws {
        group = try FrozenControlTaskGroupTicket(call.record.group)
        nonce = call.record.nonce
        phase = try .init(call.phaseIdentity, owner: call.record.group.ownerTicket)
    }
    fileprivate var call: AudioSessionCallIdentity {
        let original = group.ticket
        return .init(record: .init(group: original, nonce: nonce),
                     phaseIdentity: phase.phase(owner: original.ownerTicket))
    }
}

enum FrozenCommandActiveAuthority: Sendable {
    case receipt(ActiveSessionReceipt, AudioSessionPhaseIdentity)
    case success(FrozenCommandAudioCall)
    fileprivate init(_ value: AudioSessionActiveAuthority) throws {
        switch value {
        case .activeReceipt(let receipt, let phase): self = .receipt(receipt, phase)
        case .returnedSuccess(let call): self = .success(try .init(call))
        }
    }
    fileprivate var value: AudioSessionActiveAuthority {
        switch self {
        case .receipt(let receipt, let phase): .activeReceipt(receipt, phase)
        case .success(let frozen): .returnedSuccess(frozen.call)
        }
    }
}

/// acquisition 是独立旧票；只合并该票自己已经比较相等的 group 资源。
struct FrozenCommandAcquisitionProof: Sendable {
    private let group: FrozenControlTaskGroupTicket
    private let taskNonce: UInt64
    private let session: PlaybackSessionIdentity
    private let lease: UInt64
    private let context: UInt64
    private let ownership: UInt64
    fileprivate init(_ value: AcquisitionConfiguredLeaseOwnershipProof) throws {
        group = try .init(value.acquisitionTicket.group)
        taskNonce = value.acquisitionTicket.nonce; session = value.sessionIdentity
        lease = value.leaseID; context = value.contextNonce; ownership = value.ownershipNonce
    }
    fileprivate var value: AcquisitionConfiguredLeaseOwnershipProof {
        .init(acquisitionTicket: .init(group: group.ticket, nonce: taskNonce), sessionIdentity: session,
            leaseID: lease, contextNonce: context, ownershipNonce: ownership)
    }
}

struct FrozenCommandInterruptionProof: Sendable {
    private enum Shape: Sendable {
        case none
        case retained(lease: UInt64, monitor: UInt64)
        case quiescent(PlaybackBackendIdentity, lease: UInt64, monitor: UInt64)
    }
    private let session: PlaybackSessionIdentity
    private let generation: UInt64
    private let epoch: UInt64
    private let context: UInt64
    private let retired: OutputLifecycleEpoch?
    private let shape: Shape
    private let nonce: UInt64
    fileprivate init(_ value: InterruptionDrainProof) throws {
        session = value.sessionIdentity; generation = value.configuredGeneration
        epoch = value.interruptionEpoch; context = value.contextNonce
        retired = value.retiredOutputLifecycleEpoch; nonce = value.proofNonce
        switch value.resultingResourceShape {
        case .noResources: shape = .none
        case .retainedSuccessor(let retained):
            guard retained.sessionIdentity == session, retained.contextNonce == context else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            shape = .retained(lease: retained.leaseID, monitor: retained.monitorLifecycle)
        case .quiescentBackend(let backend, let retained):
            guard retained.sessionIdentity == session, retained.contextNonce == context else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            shape = .quiescent(backend, lease: retained.leaseID, monitor: retained.monitorLifecycle)
        }
    }
    fileprivate var value: InterruptionDrainProof {
        let result: InterruptionDrainedResourceShape
        switch shape {
        case .none: result = .noResources
        case .retained(let lease, let monitor):
            result = .retainedSuccessor(.init(sessionIdentity: session, leaseID: lease,
                monitorLifecycle: monitor, contextNonce: context))
        case .quiescent(let backend, let lease, let monitor):
            result = .quiescentBackend(backend, .init(sessionIdentity: session, leaseID: lease,
                monitorLifecycle: monitor, contextNonce: context))
        }
        return .init(sessionIdentity: session, configuredGeneration: generation, interruptionEpoch: epoch,
            contextNonce: context, retiredOutputLifecycleEpoch: retired, resultingResourceShape: result, proofNonce: nonce)
    }
}

enum FrozenCommandInactiveProof: Sendable {
    case reservation(FrozenCommandAcquisitionProof)
    case notInvoked(FrozenCommandAudioCall)
    case failure(FrozenCommandAudioCall, AudioSessionFixedFailure)
    case interruption(FrozenCommandInterruptionProof)
    fileprivate init(_ proof: AudioSessionInactiveProof) throws {
        switch proof {
        case .reservation(let value): self = .reservation(try .init(value))
        case .activationNotInvoked(let value): self = .notInvoked(try .init(value.callIdentity))
        case .activationReturnedFailure(let call, let failure): self = .failure(try .init(call), failure)
        case .interruption(let value): self = .interruption(try .init(value))
        }
    }
    fileprivate var value: AudioSessionInactiveProof {
        switch self {
        case .reservation(let proof): .reservation(proof.value)
        case .notInvoked(let call): .activationNotInvoked(.init(callIdentity: call.call))
        case .failure(let call, let failure): .activationReturnedFailure(call.call, failure)
        case .interruption(let proof): .interruption(proof.value)
        }
    }
}

enum FrozenCommandDeactivationDisposition: Sendable {
    case inactive(FrozenCommandInactiveProof)
    case awaiting(FrozenCommandAudioCall)
    case active(FrozenCommandActiveAuthority)
    case inFlight(FrozenCommandAudioCall)
    case reset(UInt64)
    case settled(FrozenCommandAudioCall, AudioSessionDeactivationResult)
    fileprivate init(_ value: AudioSessionDeactivationDisposition) throws {
        switch value {
        case .confirmedInactive(let proof): self = .inactive(try .init(proof))
        case .awaitingActivationOutcome(let call): self = .awaiting(try .init(call))
        case .requiresDeactivate(let source): self = .active(try .init(source))
        case .deactivationInFlight(let call): self = .inFlight(try .init(call))
        case .invalidatedByMediaServicesReset(let epoch): self = .reset(epoch)
        case .deactivationSettled(let call, let result): self = .settled(try .init(call), result)
        }
    }
    fileprivate var value: AudioSessionDeactivationDisposition {
        switch self {
        case .inactive(let proof): .confirmedInactive(proof.value)
        case .awaiting(let call): .awaitingActivationOutcome(call.call)
        case .active(let source): .requiresDeactivate(source.value)
        case .inFlight(let call): .deactivationInFlight(call.call)
        case .reset(let epoch): .invalidatedByMediaServicesReset(mediaServicesEpoch: epoch)
        case .settled(let call, let result): .deactivationSettled(call.call, result)
        }
    }
}

struct FrozenCommandLease: Sendable {
    private let leaseID: UInt64
    private let object: any OwnedPlaybackResource
    private let monitor: OwnedRouteMonitorResource?
    private let disposition: FrozenCommandDeactivationDisposition
    fileprivate init(_ lease: OwnedAudioSessionLeaseResources) throws {
        leaseID = lease.leaseID; object = lease.object; monitor = lease.monitor
        disposition = try .init(lease.deactivation)
    }
    fileprivate var value: OwnedAudioSessionLeaseResources {
        .init(leaseID: leaseID, object: object, monitor: monitor, deactivation: disposition.value)
    }
}

/// backend 专用 lease 不保留已经与 backend 比较过的 monitor.session。
struct FrozenCommandBackendLease: Sendable {
    private let leaseID: UInt64
    private let object: any OwnedPlaybackResource
    private let monitorLifecycle: UInt64
    private let monitorObject: any OwnedPlaybackResource
    private let disposition: FrozenCommandDeactivationDisposition
    fileprivate init(_ value: OwnedAudioSessionLeaseResources, session: PlaybackSessionIdentity) throws {
        guard let monitor = value.monitor, monitor.sessionIdentity == session else {
            throw ControlTaskRegistry.Failure.invalidGroup
        }
        leaseID = value.leaseID; object = value.object
        monitorLifecycle = monitor.lifecycle; monitorObject = monitor.object
        disposition = try .init(value.deactivation)
    }
    fileprivate func value(session: PlaybackSessionIdentity) -> OwnedAudioSessionLeaseResources {
        .init(leaseID: leaseID, object: object,
            monitor: .init(sessionIdentity: session, lifecycle: monitorLifecycle, object: monitorObject),
            deactivation: disposition.value)
    }
}

enum FrozenCommandResourcePayload: Sendable {
    case monitor(OwnedRouteMonitorResource)
    case lease(FrozenCommandLease)
    case backend(PlaybackBackendIdentity, any OwnedPlaybackResource, outputNonce: UInt64?, FrozenCommandBackendLease)
    fileprivate init(_ payload: OutputOwnedResourcePayload) throws {
        switch payload {
        case .monitor(let value): self = .monitor(value)
        case .lease(let value): self = .lease(try .init(value))
        case .backend(let value):
            guard value.lifecycle == nil || value.lifecycle?.backendIdentity == value.identity else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            self = .backend(value.identity, value.object, outputNonce: value.lifecycle?.outputNonce,
                try .init(value.lease, session: value.identity.sessionIdentity))
        }
    }
    fileprivate var value: OutputOwnedResourcePayload {
        switch self {
        case .monitor(let value): .monitor(value)
        case .lease(let value): .lease(value.value)
        case .backend(let identity, let object, let outputNonce, let lease):
            .backend(.init(identity: identity, object: object,
                lifecycle: outputNonce.map { .init(backendIdentity: identity, outputNonce: $0) },
                lease: lease.value(session: identity.sessionIdentity)))
        }
    }
}

/// workGroup 已与 command 自身原 group 比较；ownerGroup 的独立 resource 不被合并。
struct FrozenCommandOwnedResource: Sendable {
    private let owner: FrozenControlTaskGroupTicket
    private let reservationNonce: UInt64
    private let context: UInt64
    private let mediaServices: UInt64
    private let interruption: UInt64
    private let fence: UInt64
    private let payload: FrozenCommandResourcePayload
    fileprivate init(_ value: OutputResourceOwnership, workGroup: ControlTaskGroupTicket) throws {
        guard value.reservation.workGroup == workGroup else { throw ControlTaskRegistry.Failure.invalidGroup }
        owner = try .init(value.reservation.ownerGroup)
        reservationNonce = value.reservation.nonce; context = value.contextNonce
        mediaServices = value.mediaServicesEpoch; interruption = value.interruptionEpoch
        fence = value.audioAdmissionFenceRevision; payload = try .init(value.payload)
    }
    fileprivate func value(workGroup: ControlTaskGroupTicket) -> OutputResourceOwnership {
        .init(reservation: .init(ownerGroup: owner.ticket, workGroup: workGroup, nonce: reservationNonce),
              contextNonce: context, mediaServicesEpoch: mediaServices, interruptionEpoch: interruption,
              audioAdmissionFenceRevision: fence, payload: payload.value)
    }
}

struct FrozenCommandDeactivation: Sendable {
    private let workGroup: FrozenControlTaskGroupTicket
    private let reservationNonce: UInt64
    private let context: UInt64
    private let lease: UInt64
    private let source: FrozenCommandActiveAuthority
    private let phase: FrozenCommandAudioPhase
    fileprivate init(_ value: AudioSessionCleanupDeactivationRequest, task: ControlTaskTicket) throws {
        guard value.call.record == task, value.reservation.ownerGroup == task.group else {
            throw ControlTaskRegistry.Failure.invalidGroup
        }
        workGroup = try .init(value.reservation.workGroup)
        reservationNonce = value.reservation.nonce; context = value.contextNonce; lease = value.leaseID
        source = try .init(value.source)
        phase = try .init(value.call.phaseIdentity, owner: task.group.ownerTicket)
    }
    fileprivate func request(task: ControlTaskTicket) -> AudioSessionCleanupDeactivationRequest? {
        .init(reservation: .init(ownerGroup: task.group, workGroup: workGroup.ticket, nonce: reservationNonce),
              contextNonce: context, leaseID: lease, source: source.value,
              call: .init(record: task, phaseIdentity: phase.phase(owner: task.group.ownerTicket)))
    }
}

/// 只删除 reactivation 与本 command phase/policy 中已完整比对的重复字段。
/// proof 自带的旧 epoch、context、独立 backend 等字段仍原样保存，不扩成当前性校验。
enum FrozenCommandActivationPurpose: Sendable {
    case acquired(PlaybackSessionIdentity, UInt64, AcquisitionConfiguredLeaseOwnershipProof)
    case reset(SystemRecoveryIncarnation.Identity, UInt64, InactiveAudioSessionConfigurationReceipt.Identity)
    case reactivation(ConfigurationTransitionIdentity?, generation: UInt64,
        recoveryLineage: UInt64, budgetNonce: UInt64, AudioSessionReactivationProof)

    fileprivate init(_ purpose: AudioSessionActivationPurpose, phase: AudioSessionPhaseIdentity,
                     epoch: UInt64, invocation: AudioSessionActivationInvocationIdentity) throws {
        switch purpose {
        case .activateAcquiredConfiguredGeneration(let session, let generation, let proof):
            self = .acquired(session, generation, proof)
        case .commitResetConfiguration(let incarnation, let generation, let receipt):
            self = .reset(incarnation, generation, receipt)
        case .reactivateConfiguredGeneration(let session, let transition, let generation, let attempt):
            guard session == phase.sessionIdentity,
                  attempt.reactivationBudgetIdentity.sessionIdentity == session,
                  attempt.retainedContextNonce == phase.contextNonce,
                  attempt.interruptionEpoch == epoch, attempt.attemptNonce == invocation else {
                throw ControlTaskRegistry.Failure.invalidGroup
            }
            self = .reactivation(transition, generation: generation,
                recoveryLineage: attempt.reactivationBudgetIdentity.recoveryLineageIdentity,
                budgetNonce: attempt.reactivationBudgetIdentity.budgetNonce, attempt.reactivationProof)
        }
    }
    fileprivate func value(phase: AudioSessionPhaseIdentity, epoch: UInt64,
                           invocation: AudioSessionActivationInvocationIdentity) -> AudioSessionActivationPurpose {
        switch self {
        case .acquired(let session, let generation, let proof):
            .activateAcquiredConfiguredGeneration(sessionIdentity: session, committedGeneration: generation,
                acquisitionOwnershipProof: proof)
        case .reset(let incarnation, let generation, let receipt):
            .commitResetConfiguration(incarnation: incarnation, baseGeneration: generation, receiptIdentity: receipt)
        case .reactivation(let transition, let generation, let lineage, let nonce, let proof):
            .reactivateConfiguredGeneration(sessionIdentity: phase.sessionIdentity,
                configurationTransitionIdentity: transition, committedGeneration: generation,
                reactivationAttempt: .init(reactivationBudgetIdentity: .init(sessionIdentity: phase.sessionIdentity,
                    recoveryLineageIdentity: lineage, budgetNonce: nonce), reactivationProof: proof,
                    interruptionEpoch: epoch, retainedContextNonce: phase.contextNonce, attemptNonce: invocation))
        }
    }
}

enum FrozenCommandAudioPolicy: Sendable {
    case configureAcquisition(ControlTaskTicket, UInt64, UInt64, AudioSessionConfigurationStep)
    case configureInactive(SystemRecoveryIncarnation.Identity, ResetDrainProof.Identity, UInt64, AudioSessionConfigurationStep)
    case activate(FrozenCommandActivationPurpose, UInt64, UInt64, AudioSessionActivationInvocationIdentity)
    fileprivate init(_ policy: AudioSessionPhasePolicy, phase: AudioSessionPhaseIdentity) throws {
        switch policy {
        case .configureAcquisition(let ticket, let ownership, let attempt, let step):
            self = .configureAcquisition(ticket, ownership, attempt, step)
        case .configureInactive(let incarnation, let proof, let attempt, let step):
            self = .configureInactive(incarnation, proof, attempt, step)
        case .activate(let purpose, let epoch, let fence, let invocation):
            self = .activate(try .init(purpose, phase: phase, epoch: epoch, invocation: invocation), epoch, fence, invocation)
        }
    }
    fileprivate func value(phase: AudioSessionPhaseIdentity) -> AudioSessionPhasePolicy {
        switch self {
        case .configureAcquisition(let ticket, let ownership, let attempt, let step):
            .configureAcquisition(acquisitionTicket: ticket, ownershipNonce: ownership,
                configurationAttemptNonce: attempt, step: step)
        case .configureInactive(let incarnation, let proof, let attempt, let step):
            .configureInactive(incarnation: incarnation, resetDrainProof: proof,
                configurationAttemptNonce: attempt, step: step)
        case .activate(let purpose, let epoch, let fence, let invocation):
            .activate(purpose: purpose.value(phase: phase, epoch: epoch, invocation: invocation),
                interruptionEpoch: epoch, audioAdmissionFenceRevision: fence, invocationIdentity: invocation)
        }
    }
}

enum OwnedControlCommandPayload: Sendable {
    case backendOperation(OwnedPlaybackBackendOperation)
    case eventDrain(OwnedPlaybackEventDrain)
    case controllerCleanup(OwnedPlaybackCleanupTask)
    case audio(FrozenCommandAudioPhase, FrozenCommandAudioPolicy, OwnedAudioSessionActivationResult?)
    case deactivation(FrozenCommandDeactivation, AudioSessionDeactivationResult?)
    case resource(FrozenCommandOwnedResource)
    case factoryResult(OwnedFactoryResult)
}

enum OwnedFactoryResult: Sendable {
    case candidate(PlaybackBackendIdentity, contextNonce: UInt64, object: any OwnedPlaybackResource)
    case noObject(contextNonce: UInt64)

    var contextNonce: UInt64 {
        switch self {
        case .candidate(_, let nonce, _), .noObject(let nonce): nonce
        }
    }
}

/// phase调用、清理停用与资源结果互斥；对象只能经准确所有权CAS转交。
struct OwnedPostIngressControlCommand: Sendable {
    private let frozenGroup: FrozenControlTaskGroupTicket
    private let taskNonce: UInt64
    var controlTaskTicket: ControlTaskTicket { .init(group: frozenGroup.ticket, nonce: taskNonce) }
    var resourceIdentity: ControlResourceIdentity { controlTaskTicket.group.resourceIdentity }
    var ownerTicket: ControlTaskOwnerTicket { controlTaskTicket.group.ownerTicket }
    var groupTicket: ControlTaskGroupTicket { controlTaskTicket.group }
    let slot: ControlTaskSlot
    let safetySnapshot: ControlCommandSafetySnapshot
    let gatePolicy: ControlGatePolicy
    var phase: ControlTaskPhase = .queued
    var resultInvalidated = false
    var resultClaimed = false
    var activationResponsibilityTransferred = false
    var payload: OwnedControlCommandPayload?

    init(controlTaskTicket: ControlTaskTicket,
         slot: ControlTaskSlot, safetySnapshot: ControlCommandSafetySnapshot, gatePolicy: ControlGatePolicy,
         audioPhaseIdentity: AudioSessionPhaseIdentity? = nil, audioPolicy: AudioSessionPhasePolicy? = nil) throws {
        frozenGroup = try FrozenControlTaskGroupTicket(controlTaskTicket.group)
        taskNonce = controlTaskTicket.nonce
        self.slot = slot
        self.safetySnapshot = safetySnapshot
        self.gatePolicy = gatePolicy
        if let audioPhaseIdentity, let audioPolicy {
            payload = .audio(try .init(audioPhaseIdentity, owner: controlTaskTicket.group.ownerTicket),
                try .init(audioPolicy, phase: audioPhaseIdentity), nil)
        }
    }

    var audioPhaseIdentity: AudioSessionPhaseIdentity? {
        if case .audio(let identity, _, _) = payload { identity.phase(owner: ownerTicket) } else { nil }
    }
    var audioPolicy: AudioSessionPhasePolicy? {
        if case .audio(let identity, let policy, _) = payload {
            policy.value(phase: identity.phase(owner: ownerTicket))
        } else { nil }
    }
    var activationOutcome: AudioSessionActivationTerminalOutcome? {
        get {
            guard case .audio(let identity, _, let result) = payload, let result else { return nil }
            let call = AudioSessionCallIdentity(record: controlTaskTicket, phaseIdentity: identity.phase(owner: ownerTicket))
            switch result {
            case .notInvoked: return .notInvoked(.init(callIdentity: call))
            case .returnedFailure(let failure): return .returnedFailure(call, failure)
            case .returnedSuccess: return .returnedSuccess(call)
            }
        }
        set {
            guard case .audio(let identity, let policy, _) = payload else { return }
            guard let newValue else { payload = .audio(identity, policy, nil); return }
            let expected = AudioSessionCallIdentity(record: controlTaskTicket, phaseIdentity: identity.phase(owner: ownerTicket))
            let call: AudioSessionCallIdentity
            let result: OwnedAudioSessionActivationResult
            switch newValue {
            case .notInvoked(let proof): call = proof.callIdentity; result = .notInvoked
            case .returnedFailure(let value, let failure): call = value; result = .returnedFailure(failure)
            case .returnedSuccess(let value): call = value; result = .returnedSuccess
            }
            // 拒绝错票；不能把caller的另一call规范化为本record的准确物理结果。
            guard call == expected else { return }
            payload = .audio(identity, policy, result)
        }
    }
    var ownedResult: OutputResourceOwnership? {
        if case .resource(let value) = payload { value.value(workGroup: groupTicket) } else { nil }
    }
    mutating func installOwnedResult(_ ownership: OutputResourceOwnership) throws {
        payload = .resource(try .init(ownership, workGroup: groupTicket))
    }
    mutating func installDeactivation(_ request: AudioSessionCleanupDeactivationRequest) throws {
        payload = .deactivation(try .init(request, task: controlTaskTicket), nil)
    }
    mutating func completeDeactivation(_ result: AudioSessionDeactivationResult) {
        guard case .deactivation(let original, _) = payload else { return }
        payload = .deactivation(original, result)
    }
    var factoryResult: OwnedFactoryResult? {
        switch payload {
        case .factoryResult(let value): value
        case .backendOperation(let runner): runner.factoryResult
        default: nil
        }
    }
    var backendOperation: OwnedPlaybackBackendOperation? {
        if case .backendOperation(let runner) = payload { runner } else { nil }
    }
    mutating func clearFactoryResultKeepingOperation() {
        if let runner = backendOperation { runner.factoryResult = nil } else { payload = nil }
    }
    var deactivationRequest: AudioSessionCleanupDeactivationRequest? {
        if case .deactivation(let value, _) = payload { value.request(task: controlTaskTicket) } else { nil }
    }
    var deactivationOutcome: AudioSessionDeactivationResult? {
        if case .deactivation(_, let value) = payload { value } else { nil }
    }
}
