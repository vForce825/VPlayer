// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 只标记归属；实际后端操作由后续Backend协议提供。
protocol OwnedPlaybackResource: AnyObject, Sendable {}

protocol PlaybackOwnedCleanupReceiving: AnyObject, Sendable {
    func performOwnedTerminalCleanup(owner: OutputTransitionOwnerTicket,
        task: ControlTaskTicket, terminalState: PlaybackState) async
}

protocol PlaybackOwnedInterruptionCleanupReceiving: PlaybackOwnedCleanupReceiving {
    func performOwnedInterruptionCleanup(owner: OutputTransitionOwnerTicket, task: ControlTaskTicket) async
}

/// 原committedCleanup槽持有唯一任务；body完成不代表Task退出，只有外部join可清尾。
final class OwnedPlaybackCleanupTask: @unchecked Sendable {
    var owner: OutputTransitionOwnerTicket
    weak var receiver: (any PlaybackOwnedCleanupReceiving)?
    var task: Task<Void, Never>?
    // 同一原Task在retained阶段只保留一个退出/升级等待点；全部由Registry CAS读写。
    var dispositionWaiter: CheckedContinuation<Void, Never>?
    var joinRequested = false
    var terminalRequested = false
    var recoveryReturnCommitted = false

    init(owner: OutputTransitionOwnerTicket, receiver: any PlaybackOwnedCleanupReceiving) {
        self.owner = owner
        self.receiver = receiver
    }
}

struct OwnedRouteMonitorResource: Sendable {
    let sessionIdentity: PlaybackSessionIdentity
    let lifecycle: UInt64
    let object: any OwnedPlaybackResource
}

struct OwnedAudioSessionLeaseResources: Sendable {
    let leaseID: UInt64
    let object: any OwnedPlaybackResource
    let monitor: OwnedRouteMonitorResource?
    var deactivation: AudioSessionDeactivationDisposition
}

struct OwnedBackendResources: Sendable {
    let identity: PlaybackBackendIdentity
    let object: any OwnedPlaybackResource
    var lifecycle: OutputLifecycleEpoch?
    var lease: OwnedAudioSessionLeaseResources
}

/// 后端、lease与monitor永远作为完整载荷转移，不接受独立可选引用。
enum OutputOwnedResourcePayload: Sendable {
    case monitor(OwnedRouteMonitorResource)
    case lease(OwnedAudioSessionLeaseResources)
    case backend(OwnedBackendResources)

    var monitorSessionIdentity: PlaybackSessionIdentity? {
        switch self {
        case .monitor(let value): value.sessionIdentity
        case .lease(let value): value.monitor?.sessionIdentity
        case .backend(let value): value.lease.monitor?.sessionIdentity
        }
    }
    func matches(_ identity: ControlResourceIdentity, sessionIdentity: PlaybackSessionIdentity) -> Bool {
        guard monitorSessionIdentity.map({ $0 == sessionIdentity }) ?? true else { return false }
        switch identity {
        case .session(let session), .context(let session, _): return sessionIdentity == session
        case .lease(let session, let leaseID): return sessionIdentity == session && lease?.leaseID == leaseID
        case .backend(let expected):
            if case .backend(let value) = self { return value.identity == expected }
            return false
        case .outputLifecycle(let expected):
            if case .backend(let value) = self { return value.lifecycle == expected && value.identity == expected.backendIdentity }
            return false
        case .monitor(let session, let lifecycle):
            if case .monitor(let value) = self { return value.sessionIdentity == session && value.lifecycle == lifecycle }
            return false
        }
    }
    var lease: OwnedAudioSessionLeaseResources? {
        get {
            switch self {
            case .monitor: nil
            case .lease(let value): value
            case .backend(let value): value.lease
            }
        }
        set {
            guard let newValue else { return }
            switch self {
            case .monitor: break
            case .lease: self = .lease(newValue)
            case .backend(var value): value.lease = newValue; self = .backend(value)
            }
        }
    }
}

struct CleanupReservationTicket: Sendable, Equatable {
    let ownerGroup: ControlTaskGroupTicket
    let workGroup: ControlTaskGroupTicket
    let nonce: UInt64
}

enum ReservedCleanupStage: Int, CaseIterable, Sendable {
    case owner, suspend, retirement, candidateCleanup, teardown, monitorStop, audioSession, leaseRelease

    var slot: ControlTaskSlot {
        switch self {
        case .owner: .committedCleanup
        case .suspend: .suspend
        case .retirement: .retirement
        case .candidateCleanup: .candidateCleanup
        case .teardown: .teardown
        case .monitorStop: .monitorStop
        case .audioSession: .audioSessionRecovery
        case .leaseRelease: .leaseRelease
        }
    }
}

struct ReservedCleanupSlot: Sendable {
    let index: Int
    let nonce: UInt64
    var consumed = false
}

/// 每条资源链仅一份；八个容量位置属于原安全池，尚未消费时没有可执行record。
struct CleanupReservation: Sendable {
    var ticket: CleanupReservationTicket
    let contextNonce: UInt64
    let terminalOwner: ControlTaskOwnerTicket
    var deactivationPhaseNonce: UInt64
    var predecessorContextNonce: UInt64
    var leaseOnlyContextNonce: UInt64
    var monitorOnlyContextNonce: UInt64
    var retainedSuccessorContextNonce: UInt64
    var consumedConversions: UInt8 = 0
    var slots: (ReservedCleanupSlot, ReservedCleanupSlot, ReservedCleanupSlot, ReservedCleanupSlot,
                ReservedCleanupSlot, ReservedCleanupSlot, ReservedCleanupSlot, ReservedCleanupSlot)
    var terminal = false

    subscript(stage: ReservedCleanupStage) -> ReservedCleanupSlot {
        get {
            switch stage {
            case .owner: slots.0
            case .suspend: slots.1
            case .retirement: slots.2
            case .candidateCleanup: slots.3
            case .teardown: slots.4
            case .monitorStop: slots.5
            case .audioSession: slots.6
            case .leaseRelease: slots.7
            }
        }
        set {
            switch stage {
            case .owner: slots.0 = newValue
            case .suspend: slots.1 = newValue
            case .retirement: slots.2 = newValue
            case .candidateCleanup: slots.3 = newValue
            case .teardown: slots.4 = newValue
            case .monitorStop: slots.5 = newValue
            case .audioSession: slots.6 = newValue
            case .leaseRelease: slots.7 = newValue
            }
        }
    }
    func task(for stage: ReservedCleanupStage) -> ControlTaskTicket {
        .init(group: ticket.ownerGroup, nonce: self[stage].nonce)
    }
    func reserves(_ index: Int) -> Bool {
        ReservedCleanupStage.allCases.contains { self[$0].index == index && !self[$0].consumed }
    }

    enum Conversion: UInt8, CaseIterable, Sendable {
        case predecessor, leaseOnly, monitorOnly, retainedSuccessor
    }
    func nonce(for conversion: Conversion) -> UInt64? {
        guard consumedConversions & (1 << conversion.rawValue) == 0 else { return nil }
        switch conversion {
        case .predecessor: return predecessorContextNonce
        case .leaseOnly: return leaseOnlyContextNonce
        case .monitorOnly: return monitorOnlyContextNonce
        case .retainedSuccessor: return retainedSuccessorContextNonce
        }
    }
    mutating func consume(_ conversion: Conversion) { consumedConversions |= 1 << conversion.rawValue }
}

struct OutputResourceOwnership: Sendable {
    var reservation: CleanupReservationTicket
    var contextNonce: UInt64
    let mediaServicesEpoch: UInt64
    let interruptionEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64
    var payload: OutputOwnedResourcePayload

    var sessionIdentity: PlaybackSessionIdentity {
        switch reservation.ownerGroup.resourceIdentity {
        case .session(let session), .context(let session, _), .lease(let session, _), .monitor(let session, _): session
        case .backend(let identity): identity.sessionIdentity
        case .outputLifecycle(let lifecycle): lifecycle.backendIdentity.sessionIdentity
        }
    }

    var snapshot: OutputResourceOwnershipSnapshot {
        let metadata: OutputResourcePayloadSnapshot
        switch payload {
        case .monitor(let monitor):
            metadata = .monitor(session: monitor.sessionIdentity, lifecycle: monitor.lifecycle)
        case .lease(let lease):
            metadata = .lease(session: sessionIdentity, leaseID: lease.leaseID,
                monitorLifecycle: lease.monitor?.lifecycle, deactivation: lease.deactivation)
        case .backend(let backend):
            metadata = .backend(identity: backend.identity, lifecycle: backend.lifecycle,
                leaseID: backend.lease.leaseID, monitorLifecycle: backend.lease.monitor?.lifecycle,
                deactivation: backend.lease.deactivation)
        }
        return .init(reservation: reservation, contextNonce: contextNonce, mediaServicesEpoch: mediaServicesEpoch,
            interruptionEpoch: interruptionEpoch, audioAdmissionFenceRevision: audioAdmissionFenceRevision, payload: metadata)
    }
}

/// 六种pending形态与Installed/Q共享同一Authority中的唯一资源载荷。
/// 此处只有固定值决策；对象接纳、阶段改变和命令安装都由registry的具名CAS提交。
enum OutputResourcePhase: Sendable, Equatable {
    case pendingLeaseAcquisition
    case pendingCreation
    case predecessorCleanup
    case pendingSuccessorLease
    case leaseOnlyCleanup
    case routeMonitorCleanup
    case installed
    case quiescentBackend
    case released
}

enum OutputDrainKind: Sendable { case interruption, reset }
enum OutputRegisteredDrainProof: Sendable, Equatable {
    case interruption(InterruptionDrainProof)
    case reset(ResetDrainProof)
}

enum OutputLeaseDisposition: Sendable, Equatable {
    case retainForSession(PlaybackSessionIdentity)
    case releaseAfterTeardown
}

enum OutputTransitionReason: Int, Sendable, Equatable {
    case pause, recovery, stop, terminal
    var releasesLease: Bool { self == .stop || self == .terminal }
}

struct OutputTransitionOwnerTicket: Sendable, Equatable {
    let identity: ControlTaskOwnerTicket
    let reason: OutputTransitionReason
}

struct OutputHandoffAdmission: Sendable {
    let owner: OutputTransitionOwnerTicket
    let startsCleanup: Bool
}

enum OutputUserControlKind: Sendable, Equatable { case pause, resume }
struct OutputUserControlRequest: Sendable, Equatable {
    let kind: OutputUserControlKind
    let sessionIdentity: PlaybackSessionIdentity
    let expectedOwner: OutputTransitionOwnerTicket?
    let contextNonce: UInt64
    let interruptionEpoch: UInt64
    let mediaServicesEpoch: UInt64
    let resetPreRouteBinding: ResetPreRouteTicketBinding?
    var explicitResumeLease: PlaybackAudioSessionLease? = nil
}
enum OutputUserControlResult: Sendable, Equatable {
    case rejected, acceptedWaiting
    case acceptedAndPrepared(ControlTaskTicket)
}
struct OutputUserControlSafetyUpdate: Sendable, Equatable {
    let userPaused: Bool
    let interruptionVeto: Bool
    let freezeGeneration: UInt64
}

struct PlaybackMediaProgressReceipt: Sendable, Equatable {
    let intervalKey: PotentiallyAudibleOutputIntervalKey
    let sessionIdentity: PlaybackSessionIdentity
    let contextNonce: UInt64
    let mediaServicesEpoch: UInt64
    let interruptionEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64
    let stableRouteCommit: StableRouteCommitIdentity
}

enum PlaybackBudgetControlAction: Sendable, Equatable {
    case resetPreRouteTimer(ResetPreRouteRecoveryDeadlineArmTicket)
    case postConfigurationTimer(PostConfigurationRouteDeadlineArmTicket)
    case mediaProgress(PlaybackMediaProgressReceipt)
    case acquisitionTimer(AudioSessionAcquisitionDeadline)
    case cleanupTimer(CleanupBudgetTicket)
    case ordinaryRouteTimer(RouteUnavailableDeadlineArmTicket)
    case reactivationTimer(AudioSessionReactivationCutoffArmTicket)
    case playbackOperationTimer(PlaybackOperationDeadlineArmTicket)
}

enum PlaybackBudgetControlResult: Sendable, Equatable {
    case rejected
    case resetPreRouteRearmed(PlaybackDeadlineRearm<ResetPreRouteRecoveryDeadlineArmTicket>)
    case postConfigurationRearmed(PlaybackDeadlineRearm<PostConfigurationRouteDeadlineArmTicket>)
    case progressCompleted
    case acquisitionRearmed(AudioSessionAcquisitionDeadline, remainingNanoseconds: UInt64,
        notAfterInstant: UInt64)
    case cleanupRearmed(CleanupBudgetTicket, remainingNanoseconds: UInt64,
        notAfterInstant: UInt64)
    case ordinaryRouteRearmed(PlaybackDeadlineRearm<RouteUnavailableDeadlineArmTicket>)
    case reactivationRearmed(PlaybackDeadlineRearm<AudioSessionReactivationCutoffArmTicket>)
    case playbackOperationRearmed(PlaybackDeadlineRearm<PlaybackOperationDeadlineArmTicket>)
}
enum OutputControlRequest: Sendable, Equatable {
    case playbackAdmission(UUID)
    case audioEventRelayLookup
    case audioRelayOverflow(recordNonce: UInt64)
    case audioSessionCall(AudioSessionBlockingCallAction)
    case registrationIngress(PlaybackAudioSessionRegistration)
    case user(OutputUserControlRequest)
    case retire(ControlTaskTicket)
    case interruptionDrain(OutputTransitionOwnerTicket)
    case suspend(OutputSuspendControlAction)
    case budget(PlaybackBudgetControlAction)
}
enum OutputControlApplication: Sendable, Equatable {
    case playbackAdmissionNeedsCleanupJoin
    case playbackAdmitted(CurrentPlaybackOperationDeadlineTicket, PlaybackOutputSafetyState, freezeGeneration: UInt64)
    case audioEventRelay(PlaybackAudioSessionEventRelay)
    case audioSessionCall(AudioSessionBlockingCallApplication)
    case registrationValidated
    case rejected
    case terminated
    case applied(OutputUserControlSafetyUpdate, OutputUserControlResult)
    case retired(followUp: ControlTaskTicket?, clearsInterruptionVeto: Bool)
    case interruptionSettled(proof: InterruptionDrainProof, followUp: ControlTaskTicket?, clearsInterruptionVeto: Bool)
    case routeSampled(freezeGeneration: UInt64, audioAdmissionFenceRevision: UInt64, gateOpen: Bool, followUp: ControlTaskTicket?)
    case routeSampleSettled(followUp: ControlTaskTicket?)
    case suspend(OutputSuspendControlResult, preservesRoute: Bool = false)
    case budget(PlaybackBudgetControlResult)
    case failed(PlaybackSafetyFailure)
}

enum PlaybackRequestAdmissionResult: Sendable, Equatable {
    case admitted(CurrentPlaybackOperationDeadlineTicket)
    case needsCleanupJoin
}

enum OutputSuspendControlAction: Sendable, Equatable {
    case timeout(OutputSuspendTicket)
    case complete(OutputQuiescenceReceipt)
}

enum OutputSuspendControlResult: Sendable, Equatable {
    case accepted
    case timedOut
    case rearmed(remainingNanoseconds: UInt64, notAfterInstant: UInt64)
}

enum OutputInterruptionDrainSettlement: Sendable, Equatable {
    case rejected
    case settled(proof: InterruptionDrainProof, followUp: ControlTaskTicket?)
}

enum OutputCreationClaimOrigin: Sendable, Equatable {
    case initial(session: PlaybackSessionIdentity, lineageNonce: UInt64)
    case replacement(OutputTransitionOwnerTicket)
}

struct InitialCreationRetryTicket: Sendable, Equatable {
    let origin: OutputCreationClaimOrigin
    let stableRouteCommitEpoch: UInt64
    let nonce: UInt64
}

enum OutputSuccessorCreationOwner: Sendable, Equatable {
    case initialRetry(InitialCreationRetryTicket)
    case replacement(OutputTransitionOwnerTicket)
}

struct OutputLeaseClaimTicket: Sendable, Equatable {
    let contextNonce: UInt64
    let nonce: UInt64
}

struct OutputSuccessorClaim: Sendable, Equatable {
    let leaseClaim: OutputLeaseClaimTicket
    let creationOwner: OutputSuccessorCreationOwner
    let stableCommit: StableRouteCommitIdentity
}

struct OutputRetainedRebaseResult: Sendable, Equatable {
    let contextNonce: UInt64
    let owner: OutputTransitionOwnerTicket?
    let stableCommit: StableRouteCommitIdentity
    let successorClaim: OutputSuccessorClaim?
}

struct OutputSuspendTicket: Sendable, Equatable {
    let task: ControlTaskTicket
    let lifecycle: OutputLifecycleEpoch
    let priorActivation: ActivationEpoch?
    let anchorInstant: UInt64
}

struct PotentiallyAudibleOutputIntervalKey: Sendable, Equatable {
    let backendObjectNonce: UInt64
    let backendIdentity: PlaybackBackendIdentity
    let outputLifecycle: OutputLifecycleEpoch
    let itemGeneration: UInt64?
    let activation: ActivationEpoch
}

struct PotentiallyAudibleOutputCloseClaim: Sendable, Equatable {
    let intervalKey: PotentiallyAudibleOutputIntervalKey
    let suspendTicket: OutputSuspendTicket
    let stopNonce: UInt64
}

struct OutputQuiescenceReceipt: Sendable, Equatable {
    let suspendTicket: OutputSuspendTicket
    let closeClaim: PotentiallyAudibleOutputCloseClaim?
    let directlyConfirmedRateZero: Bool
    let preparedPreserved: Bool
}

/// 固定ACK身份属于准确monitor；不会保存delivery闭包或等待者数组。
struct OutputMonitorDeliveryTicket: Sendable, Equatable {
    let contextNonce: UInt64
    let monitorLifecycle: UInt64
    let nonce: UInt64
}

struct OutputResourceContext: Sendable {
    var phase: OutputResourcePhase
    var contextNonce: UInt64
    var reservation: CleanupReservationTicket
    let sessionIdentity: PlaybackSessionIdentity
    var disposition: OutputLeaseDisposition
    var claimOrigin: OutputCreationClaimOrigin
    var owner: OutputTransitionOwnerTicket?
    var desiredBackendKind: PlaybackBackendKind?
    var backendObjectNonce: UInt64
    var sourceTask: ControlTaskTicket?
    var prepareTicket: PrepareTicket?
    var activation: ActivationEpoch?
    var suspend: OutputSuspendTicket?
    var suspendConfirmed = false
    var suspendRequiresRetirement = false
    var suspendPreparedPreserved = false
    var suspendTimedOut = false
    var retirement: ControlTaskTicket?
    var retiredLifecycle: OutputLifecycleEpoch?
    var retirementConfirmed = false
    var teardown: ControlTaskTicket?
    var monitorStop: ControlTaskTicket?
    var monitorStopped = false
    var relayClosing = false
    var delivery: OutputMonitorDeliveryTicket?
    var budget: CleanupBudgetTicket?
    var poisoned = false
    var interval: PotentiallyAudibleOutputIntervalKey?
    var closeClaim: PotentiallyAudibleOutputCloseClaim?
    var interruptionProof: InterruptionDrainProof?
    var resetProof: ResetDrainProof?
    // 物理veto期间的resume只保存意图；准确当前proof到达后才能消费。
    var userResumeRequested = false
    var pendingReset: MediaServicesResetRootIdentity?
    var interruptionDrainRequired = false
    var teardownRequested = false
    var mediaServicesEpoch: UInt64 = 0
    var interruptionEpoch: UInt64 = 0
    var audioAdmissionFenceRevision: UInt64 = 0
    var candidateBackendIdentity: PlaybackBackendIdentity?
    // factory准入时预留；迟到零速对象也必须用原生命周期执行真实退休，不能临时补造身份。
    var candidateLifecycleNonce: UInt64 = 0
    var pendingActivationCall: AudioSessionCallIdentity?
    var prepared = false
    var ownerIngressRevision: UInt64 = 0
    var acquisitionNoLeaseReceipt: OutputAcquisitionNoLeaseReceipt?
    var parentDeadline: CurrentPlaybackOperationDeadlineTicket?
    var resetRecoveryMandatorySuffix: UInt64
    var acquisitionDeadline: AudioSessionAcquisitionDeadline?
    var committedRelay: OutputAcquisitionCommitToken?
    var sessionReceipts: OutputSessionReceipts?
    var retainedRebase: OutputRetainedRebaseResult?
    var resetResourceBinding: OutputResetResourceBinding?
    var resetAcquisitionBinding: OutputResetAcquisitionBinding? {
        if case .acquiring(let binding) = resetResourceBinding { binding } else { nil }
    }
    var systemRecoveryBinding: SystemRecoveryLeaseBinding? {
        if case .retained(let binding) = resetResourceBinding { binding } else { nil }
    }
    var resetPreRouteBinding: ResetPreRouteTicketBinding? {
        switch resetResourceBinding {
        case .draining(let binding): binding.preRouteBinding
        case .acquiring(let binding): binding.binding
        case .retained(let binding): binding.resetPreRouteBinding
        case nil: nil
        }
    }
    var resetInheritedRouteAvailabilityConstraint: InheritedRouteAvailabilityConstraint? {
        switch resetResourceBinding {
        case .acquiring(let binding): binding.inheritedRouteAvailabilityConstraint
        case .retained(let binding): binding.inheritedRouteAvailabilityConstraint
        case .draining(let binding): binding.inheritedRouteAvailabilityConstraint
        case nil: nil
        }
    }

    init(session: PlaybackSessionIdentity, reservation: CleanupReservation, source: ControlTaskTicket,
        parent: CurrentPlaybackOperationDeadlineTicket, resetRecoveryMandatorySuffix: UInt64) {
        phase = .pendingLeaseAcquisition
        contextNonce = reservation.contextNonce
        self.reservation = reservation.ticket
        sessionIdentity = session
        disposition = .retainForSession(session)
        claimOrigin = .initial(session: session, lineageNonce: reservation.ticket.nonce)
        backendObjectNonce = reservation.contextNonce
        sourceTask = source
        parentDeadline = parent
        self.resetRecoveryMandatorySuffix = resetRecoveryMandatorySuffix
    }
}

enum OutputLeaseCleanupOwnership: Sendable {
    case owned(OwnedAudioSessionLeaseResources)
    case runner(ControlTaskTicket)
}

enum OutputMonitorCleanupOwnership: Sendable {
    case owned(OwnedRouteMonitorResource)
    case runner(ControlTaskTicket)
}

struct OutputAcquiredLease: Sendable {
    var lease: OwnedAudioSessionLeaseResources
    let proof: AcquisitionConfiguredLeaseOwnershipProof
}

struct OutputAcquisitionNoLeaseReceipt: Sendable, Equatable {
    enum Outcome: Sendable, Equatable { case canceledBeforeClaim, confirmedNoLease }
    let acquisitionTicket: ControlTaskTicket
    let outcome: Outcome
}

struct OutputConfiguredAcquisition: Sendable {
    var acquired: OutputAcquiredLease
    let processReceipt: ProcessAudioSessionConfigurationReceipt
    var configuredReceipt: ConfiguredSessionReceipt {
        .init(leaseID: acquired.lease.leaseID, processConfigurationReceiptIdentity: processReceipt.identity)
    }
}

/// relay身份引用准确acquisition，不另建可重用的数值别名。
struct OutputSessionRelayIdentity: Sendable, Equatable {
    let acquisitionTicket: ControlTaskTicket
    let sessionIdentity: PlaybackSessionIdentity
    let leaseID: UInt64
    let monitorLifecycle: UInt64
}

struct OutputAcquisitionCommitToken: Sendable, Equatable {
    let relayIdentity: OutputSessionRelayIdentity
    let contextNonce: UInt64
    let ownerEventCursor: UInt64
    let audioAdmissionFenceRevision: UInt64
}

struct OutputAcquisitionHandoff: Sendable, Equatable {
    let committed: OutputAcquisitionCommitToken
    let successorContextNonce: UInt64
    let sampler: ControlTaskTicket?
    let routeDeadline: RouteUnavailableDeadlineTicket?
    let routeObservation: RouteObservationTicket?
}

struct OutputSessionReceipts: Sendable, Equatable {
    let process: ProcessAudioSessionConfigurationReceipt
    let configured: ConfiguredSessionReceipt
    var active: ActiveSessionReceipt?
}

enum OutputAcquisitionCommitResult: Sendable, Equatable {
    case rejected
    case retry(OutputAcquisitionCommitToken)
    case committed(OutputAcquisitionHandoff)
}

/// waiting由外层acquiringWithoutLease表达；取得资源后receipt与其对应lease只能一起转移。
enum OutputAcquiredLeaseState: Sendable {
    case configuring(OutputAcquiredLease, AudioSessionConfigurationAttempt)
    case awaitingActivation(OutputConfiguredAcquisition)
    case readyToCommit(OutputReadyAcquisition)

    var lease: OwnedAudioSessionLeaseResources {
        get {
            switch self {
            case .configuring(let value, _): value.lease
            case .awaitingActivation(let value): value.acquired.lease
            case .readyToCommit(let value): value.acquired.lease
            }
        }
        set {
            switch self {
            case .configuring(var value, let attempt): value.lease = newValue; self = .configuring(value, attempt)
            case .awaitingActivation(var value): value.acquired.lease = newValue; self = .awaitingActivation(value)
            case .readyToCommit(var value): value.acquired.lease = newValue; self = .readyToCommit(value)
            }
        }
    }
}

enum OutputReadyAcquisition: Sendable {
    case ordinary(OutputConfiguredAcquisition, ActiveSessionReceipt)
    case inactive(OutputAcquiredLease, InactiveAudioSessionConfigurationReceipt)

    var acquired: OutputAcquiredLease {
        get {
            switch self {
            case .ordinary(let value, _): value.acquired
            case .inactive(let value, _): value
            }
        }
        set {
            switch self {
            case .ordinary(var value, let active): value.acquired = newValue; self = .ordinary(value, active)
            case .inactive(_, let receipt): self = .inactive(newValue, receipt)
            }
        }
    }
}

/// Authority唯一的强引用状态。各case的载荷类型封闭资源形态；不存在旁路backend/lease/monitor optional。
enum OutputResourceState: Sendable {
    case acquiringWithoutLease(OutputResourceContext)
    case acquiringLease(OutputResourceContext, OutputAcquiredLeaseState)
    case pendingCreation(OutputResourceContext, OwnedAudioSessionLeaseResources)
    case predecessorCleanup(OutputResourceContext, OwnedBackendResources)
    case pendingSuccessorLease(OutputResourceContext, OwnedAudioSessionLeaseResources)
    case leaseOnlyCleanup(OutputResourceContext, OutputLeaseCleanupOwnership)
    case routeMonitorCleanup(OutputResourceContext, OutputMonitorCleanupOwnership)
    case installed(OutputResourceContext, OwnedBackendResources)
    case quiescentBackend(OutputResourceContext, OwnedBackendResources)

    var context: OutputResourceContext {
        get {
            var value: OutputResourceContext
            switch self {
            case .acquiringWithoutLease(let context), .acquiringLease(let context, _):
                value = context; value.phase = .pendingLeaseAcquisition
            case .pendingCreation(let context, _): value = context; value.phase = .pendingCreation
            case .predecessorCleanup(let context, _): value = context; value.phase = .predecessorCleanup
            case .pendingSuccessorLease(let context, _): value = context; value.phase = .pendingSuccessorLease
            case .leaseOnlyCleanup(let context, _): value = context; value.phase = .leaseOnlyCleanup
            case .routeMonitorCleanup(let context, _): value = context; value.phase = .routeMonitorCleanup
            case .installed(let context, _): value = context; value.phase = .installed
            case .quiescentBackend(let context, _): value = context; value.phase = .quiescentBackend
            }
            return value
        }
        set {
            // 仅更新原shape的纯值责任；跨shape只能由registry具名CAS整体替换enum。
            switch self {
            case .acquiringWithoutLease: self = .acquiringWithoutLease(newValue)
            case .acquiringLease(_, let lease): self = .acquiringLease(newValue, lease)
            case .pendingCreation(_, let lease): self = .pendingCreation(newValue, lease)
            case .predecessorCleanup(_, let backend): self = .predecessorCleanup(newValue, backend)
            case .pendingSuccessorLease(_, let lease): self = .pendingSuccessorLease(newValue, lease)
            case .leaseOnlyCleanup(_, let lease): self = .leaseOnlyCleanup(newValue, lease)
            case .routeMonitorCleanup(_, let monitor): self = .routeMonitorCleanup(newValue, monitor)
            case .installed(_, let backend): self = .installed(newValue, backend)
            case .quiescentBackend(_, let backend): self = .quiescentBackend(newValue, backend)
            }
        }
    }

    var ownership: OutputResourceOwnership? {
        let payload: OutputOwnedResourcePayload
        switch self {
        case .acquiringWithoutLease, .leaseOnlyCleanup(_, .runner), .routeMonitorCleanup(_, .runner): return nil
        case .acquiringLease(_, let value): payload = .lease(value.lease)
        case .pendingCreation(_, let lease), .pendingSuccessorLease(_, let lease),
             .leaseOnlyCleanup(_, .owned(let lease)): payload = .lease(lease)
        case .predecessorCleanup(_, let backend), .installed(_, let backend), .quiescentBackend(_, let backend): payload = .backend(backend)
        case .routeMonitorCleanup(_, .owned(let monitor)): payload = .monitor(monitor)
        }
        let metadata = context
        return .init(reservation: metadata.reservation, contextNonce: metadata.contextNonce,
            mediaServicesEpoch: metadata.mediaServicesEpoch, interruptionEpoch: metadata.interruptionEpoch,
            audioAdmissionFenceRevision: metadata.audioAdmissionFenceRevision, payload: payload)
    }

    mutating func updateOwnedPayload(_ payload: OutputOwnedResourcePayload) {
        let metadata = context
        switch (self, payload) {
        case (.acquiringLease(_, var acquisition), .lease(let value)):
            acquisition.lease = value; self = .acquiringLease(metadata, acquisition)
        case (.pendingCreation, .lease(let value)): self = .pendingCreation(metadata, value)
        case (.pendingSuccessorLease, .lease(let value)): self = .pendingSuccessorLease(metadata, value)
        case (.leaseOnlyCleanup(_, .owned), .lease(let value)): self = .leaseOnlyCleanup(metadata, .owned(value))
        case (.routeMonitorCleanup(_, .owned), .monitor(let value)): self = .routeMonitorCleanup(metadata, .owned(value))
        case (.predecessorCleanup, .backend(let value)): self = .predecessorCleanup(metadata, value)
        case (.installed, .backend(let value)): self = .installed(metadata, value)
        case (.quiescentBackend, .backend(let value)): self = .quiescentBackend(metadata, value)
        default: preconditionFailure("跨shape资源转移必须使用具名CAS")
        }
    }
}

/// teardown确认后仅转出被销毁的准确backend引用；lease/monitor已由同锁CAS留在后继context。
struct OutputBackendDisposalRunner: Sendable {
    let ticket: ControlTaskTicket
    private let object: any OwnedPlaybackResource
    init(ticket: ControlTaskTicket, object: any OwnedPlaybackResource) {
        self.ticket = ticket
        self.object = object
    }
}

/// 原cleanup command领取的非权威借用；只有原票可提交结果，资源始终由Registry持有。
struct OutputBackendCleanupInvocation: Sendable {
    let task: ControlTaskTicket
    let owner: OutputTransitionOwnerTicket
    let contextNonce: UInt64
    let backend: any PlaybackBackend
    let lifecycle: OutputLifecycleEpoch?
    let suspendInvocation: ControlTaskRegistry.BackendSuspendInvocation?
}

/// 只读快照仅含身份与状态值，绝不携带SDK对象或可执行闭包。
enum OutputResourcePayloadSnapshot: Sendable {
    case monitor(session: PlaybackSessionIdentity, lifecycle: UInt64)
    case lease(session: PlaybackSessionIdentity, leaseID: UInt64, monitorLifecycle: UInt64?,
               deactivation: AudioSessionDeactivationDisposition)
    case backend(identity: PlaybackBackendIdentity, lifecycle: OutputLifecycleEpoch?, leaseID: UInt64,
                 monitorLifecycle: UInt64?, deactivation: AudioSessionDeactivationDisposition)
}

struct OutputResourceOwnershipSnapshot: Sendable {
    let reservation: CleanupReservationTicket
    let contextNonce: UInt64
    let mediaServicesEpoch: UInt64
    let interruptionEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64
    let payload: OutputResourcePayloadSnapshot
}

/// 已claim的runner准确强持有整份载荷；离开共享executor后才允许执行SDK或释放。
struct OwnedOutputResourceRunner: Sendable {
    let task: ControlTaskTicket
    let ownership: OutputResourceOwnership
}

struct AudioSessionCleanupDeactivationRequest: Sendable, Equatable {
    let reservation: CleanupReservationTicket
    let contextNonce: UInt64
    let leaseID: UInt64
    let source: AudioSessionActiveAuthority
    private let callPhaseIdentity: AudioSessionPhaseIdentity
    private let callRecordNonce: UInt64

    init?(reservation: CleanupReservationTicket, contextNonce: UInt64, leaseID: UInt64,
        source: AudioSessionActiveAuthority, call: AudioSessionCallIdentity) {
        guard call.record.group == reservation.ownerGroup else { return nil }
        self.reservation = reservation
        self.contextNonce = contextNonce
        self.leaseID = leaseID
        self.source = source
        callPhaseIdentity = call.phaseIdentity
        callRecordNonce = call.record.nonce
    }

    /// 使用原request保存的ownerGroup与原nonce还原；绝不读取当前Authority补权限。
    var call: AudioSessionCallIdentity {
        .init(record: .init(group: reservation.ownerGroup, nonce: callRecordNonce), phaseIdentity: callPhaseIdentity)
    }
}
