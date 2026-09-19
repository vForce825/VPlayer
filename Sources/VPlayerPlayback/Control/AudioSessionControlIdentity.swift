// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

// 纯值不授予签发权限；drain proof只能由资源收敛CAS签发。
struct AudioSessionActivationInvocationIdentity: Sendable, Equatable {
    private let issuer: UInt64
    private let sequence: UInt64

    // 只在安装新的合法激活事务时签发；登记、重放或claim不得自动补票。
    init(allocator: PlaybackIdentityAllocator) throws {
        sequence = try allocator.next(in: .audioSessionActivationInvocation)
        guard let issuer = allocator.issuerIdentity else { throw PlaybackIdentityAllocationError.identitySpaceExhausted }
        self.issuer = issuer
    }

    func wasIssued(by allocator: PlaybackIdentityAllocator) -> Bool { issuer == allocator.issuerIdentity }
    func isLater(than previous: Self) -> Bool { issuer == previous.issuer && sequence > previous.sequence }
}

struct MediaServicesResetRootIdentity: Sendable, Equatable {
    let resetTicket: UInt64
    let mediaServicesEpoch: UInt64
}
struct RetainedAudioSessionResourceShape: Sendable, Equatable {
    let sessionIdentity: PlaybackSessionIdentity
    let leaseID: UInt64
    let monitorLifecycle: UInt64
    let contextNonce: UInt64
}
enum ResetDrainedResourceShape: Sendable, Equatable {
    case noResources
    case retainedSuccessor(RetainedAudioSessionResourceShape)
}
enum InterruptionDrainedResourceShape: Sendable, Equatable {
    case noResources
    case retainedSuccessor(RetainedAudioSessionResourceShape)
    case quiescentBackend(PlaybackBackendIdentity, RetainedAudioSessionResourceShape)
}
struct ResetDrainProof: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let root: MediaServicesResetRootIdentity
        let proofNonce: UInt64
    }
    let identity: Identity
    let parentProofNonce: UInt64?
    let drainedSessionIdentity: PlaybackSessionIdentity?
    let resultingResourceShape: ResetDrainedResourceShape
    let currentConfigurationGeneration: UInt64
}
struct SystemRecoveryIncarnation: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let root: MediaServicesResetRootIdentity
        let incarnationNonce: UInt64
        let sessionIdentity: PlaybackSessionIdentity
    }
    let identity: Identity
    let drainProof: ResetDrainProof
    let baseConfigurationGeneration: UInt64
    let configurationPlan: PreferredAudioSessionConfigurationPlan
    let outerDeadlineTicket: PlaybackProgressBudgetTicket.Identity
    let resetPreRouteDeadlineTicket: ResetPreRouteRecoveryDeadlineTicket
    let inheritedRouteAvailabilityConstraint: InheritedRouteAvailabilityConstraint?
}
enum ConfigurationTransitionIdentity: Sendable, Equatable {
    case reset(SystemRecoveryIncarnation.Identity)
}
struct SystemRecoveryLeaseBinding: Sendable, Equatable {
    let incarnation: SystemRecoveryIncarnation
    var resetDrainProof: ResetDrainProof { incarnation.drainProof }
    var configurationPlan: PreferredAudioSessionConfigurationPlan { incarnation.configurationPlan }
    let inactiveConfigurationReceipt: InactiveAudioSessionConfigurationReceipt?
    var outerDeadlineTicket: PlaybackProgressBudgetTicket.Identity { incarnation.outerDeadlineTicket }
    var resetPreRouteDeadlineTicket: ResetPreRouteRecoveryDeadlineTicket { incarnation.resetPreRouteDeadlineTicket }
    let resetPreRouteBinding: ResetPreRouteTicketBinding
    var inheritedRouteAvailabilityConstraint: InheritedRouteAvailabilityConstraint? { incarnation.inheritedRouteAvailabilityConstraint }
    let configurationState: AudioSessionConfigurationProgress
}
struct AcquisitionConfiguredLeaseOwnershipProof: Sendable, Equatable {
    let acquisitionTicket: ControlTaskTicket
    let sessionIdentity: PlaybackSessionIdentity
    let leaseID: UInt64
    let contextNonce: UInt64
    let ownershipNonce: UInt64
}
struct InterruptionDrainProof: Sendable, Equatable {
    let sessionIdentity: PlaybackSessionIdentity
    let configuredGeneration: UInt64
    let interruptionEpoch: UInt64
    let contextNonce: UInt64
    let retiredOutputLifecycleEpoch: OutputLifecycleEpoch?
    let resultingResourceShape: InterruptionDrainedResourceShape
    let proofNonce: UInt64
}
struct ResetPostConfigurationProof: Sendable, Equatable {
    let incarnationIdentity: SystemRecoveryIncarnation.Identity
    let resetDrainProofIdentity: ResetDrainProof.Identity
    let retainedContextNonce: UInt64
    let leaseID: UInt64
    let committedGeneration: UInt64
    let postConfigurationStageIdentity: UInt64
    let proofNonce: UInt64
}
enum AudioSessionActivationPurpose: Sendable, Equatable {
    case activateAcquiredConfiguredGeneration(sessionIdentity: PlaybackSessionIdentity,
        committedGeneration: UInt64, acquisitionOwnershipProof: AcquisitionConfiguredLeaseOwnershipProof)
    case commitResetConfiguration(incarnation: SystemRecoveryIncarnation.Identity,
        baseGeneration: UInt64, receiptIdentity: InactiveAudioSessionConfigurationReceipt.Identity)
    case reactivateConfiguredGeneration(sessionIdentity: PlaybackSessionIdentity,
        configurationTransitionIdentity: ConfigurationTransitionIdentity?, committedGeneration: UInt64,
        reactivationAttempt: AudioSessionReactivationAttemptTicket)
}
struct AudioSessionPhaseIdentity: Sendable, Equatable {
    let owner: ControlTaskOwnerTicket
    let sessionIdentity: PlaybackSessionIdentity
    let leaseID: UInt64
    let contextNonce: UInt64
    let mediaServicesEpoch: UInt64
    let phaseNonce: UInt64
}
enum AudioSessionPhasePolicy: Sendable, Equatable {
    case configureAcquisition(acquisitionTicket: ControlTaskTicket, ownershipNonce: UInt64,
        configurationAttemptNonce: UInt64, step: AudioSessionConfigurationStep)
    case configureInactive(incarnation: SystemRecoveryIncarnation.Identity,
        resetDrainProof: ResetDrainProof.Identity, configurationAttemptNonce: UInt64,
        step: AudioSessionConfigurationStep)
    case activate(purpose: AudioSessionActivationPurpose, interruptionEpoch: UInt64,
        audioAdmissionFenceRevision: UInt64, invocationIdentity: AudioSessionActivationInvocationIdentity)
}
struct RegisteredAudioSessionPhase: Sendable, Equatable {
    var identity: AudioSessionPhaseIdentity
    var policy: AudioSessionPhasePolicy
    var configurationAttempt: AudioSessionConfigurationAttempt
    var parent: PlaybackProgressBudgetTicket.Identity
    var resetBinding: ResetPreRouteTicketBinding?
    var incarnation: SystemRecoveryIncarnation?
    var reactivationState: AudioSessionReactivationBudgetState?
    var reactivationBudget: AudioSessionReactivationBudgetTicket? { reactivationState?.ticket }

    /// 只检查已完成配置与对应receipt纯字段一致性；不是当前epoch/proof/context授权。
    var hasConsistentActivationConfiguration: Bool {
        guard case .complete(let policy, let failure, let capability) = configurationProgress,
              case .activate(let purpose, _, _, _) = self.policy else { return false }
        switch purpose {
        case .commitResetConfiguration:
            guard let receipt = inactiveReceipt else { return false }
            return receipt.actualPolicy == policy && receipt.preferredFailureReason == failure &&
                receipt.multichannelCapability == capability && receipt.attemptLineage == configurationAttempt &&
                receipt.planDigest == configurationAttempt.plan
        case .activateAcquiredConfiguredGeneration, .reactivateConfiguredGeneration:
            guard let receipt = processReceipt else { return false }
            return receipt.actualPolicy == policy && receipt.preferredFailureReason == failure &&
                receipt.multichannelCapability == capability && receipt.attemptLineage == configurationAttempt &&
                receipt.planDigest == configurationAttempt.plan
        }
    }

    /// 自包含引用一致不意味着此root/proof仍登记于当前Authority。
    var hasConsistentResetReferences: Bool {
        guard let incarnation, let binding = resetBinding else { return false }
        return incarnation.identity.sessionIdentity == identity.sessionIdentity &&
            incarnation.drainProof.identity.root == incarnation.identity.root &&
            incarnation.configurationPlan == configurationAttempt.plan && incarnation.outerDeadlineTicket == parent &&
            binding.rootIdentity == incarnation.identity.root && binding.ticketIdentity == incarnation.resetPreRouteDeadlineTicket.identity &&
            binding.ticketIdentity.sessionIdentity == identity.sessionIdentity && binding.ticketIdentity.parentOperationTicketIdentity == parent
    }

    var hasConsistentConfiguredReceiptReferences: Bool {
        guard let process = processReceipt, let configured = configuredReceipt else { return false }
        return configured.leaseID == identity.leaseID && configured.processConfigurationReceiptIdentity == process.identity
    }

    var hasConsistentConfigurationProofReferences: Bool {
        switch policy {
        case .configureAcquisition(let ticket, let nonce, let attempt, _):
            guard let proof = acquisitionOwnershipProof else { return false }
            return proof.acquisitionTicket == ticket && proof.ownershipNonce == nonce &&
                proof.sessionIdentity == identity.sessionIdentity && proof.leaseID == identity.leaseID &&
                proof.contextNonce == identity.contextNonce && attempt == configurationAttempt.nonce
        case .configureInactive(let reference, let proof, let attempt, _):
            guard hasConsistentResetReferences, let incarnation else { return false }
            return incarnation.identity == reference && incarnation.drainProof.identity == proof &&
                reference.root == proof.root && attempt == configurationAttempt.nonce
        case .activate: return false
        }
    }

    var hasConsistentConfigurationStep: Bool {
        let step: AudioSessionConfigurationStep
        switch policy {
        case .configureAcquisition(_, _, _, let value), .configureInactive(_, _, _, let value): step = value
        case .activate: return false
        }
        switch (step, configurationProgress) {
        case (.longFormCategoryAttempt, .awaitingLongForm),
             (.defaultCategoryFallbackAttempt, .awaitingFallback),
             (.multichannelCapability, .awaitingMultichannel): return true
        default: return false
        }
    }

    var hasConsistentActivationProofReferences: Bool {
        guard case .activate(let purpose, let epoch, _, let invocation) = policy else { return false }
        switch purpose {
        case .activateAcquiredConfiguredGeneration(let session, let generation, let proof):
            return hasConsistentConfiguredReceiptReferences && processReceipt?.identity.configurationGeneration == generation &&
                session == identity.sessionIdentity && proof == acquisitionOwnershipProof && proof.sessionIdentity == session &&
                proof.leaseID == identity.leaseID && proof.contextNonce == identity.contextNonce
        case .commitResetConfiguration(let reference, let base, let receiptIdentity):
            guard hasConsistentResetReferences, let incarnation, let receipt = inactiveReceipt else { return false }
            return incarnation.identity == reference && incarnation.baseConfigurationGeneration == base &&
                incarnation.drainProof.currentConfigurationGeneration == base && receipt.identity == receiptIdentity &&
                receipt.identity.attemptNonce == configurationAttempt.nonce && receipt.planDigest == incarnation.configurationPlan
        case .reactivateConfiguredGeneration(let session, let transition, let generation, let attempt):
            guard hasConsistentConfiguredReceiptReferences, let budget = reactivationBudget,
                  processReceipt?.identity.configurationGeneration == generation,
                  session == identity.sessionIdentity, budget.identity.sessionIdentity == session,
                  budget.identity == attempt.reactivationBudgetIdentity, budget.committedGeneration == generation,
                  budget.parentOperationTicketIdentity == parent, attempt.interruptionEpoch == epoch,
                  attempt.attemptNonce == invocation, attempt.reactivationProof == currentReactivationProof,
                  attempt.retainedContextNonce == identity.contextNonce else { return false }
            switch (transition, attempt.reactivationProof) {
            case (nil, .interruption(let proof)):
                return budget.postConfigurationStageIdentity == nil && proof.sessionIdentity == session &&
                    proof.configuredGeneration == generation && proof.contextNonce == identity.contextNonce
            case (.reset(let reference), .resetPostConfiguration(let proof)):
                return hasConsistentResetReferences && incarnation?.identity == reference && proof.incarnationIdentity == reference &&
                    proof.resetDrainProofIdentity == incarnation?.drainProof.identity && proof.retainedContextNonce == identity.contextNonce &&
                    proof.leaseID == identity.leaseID && proof.committedGeneration == generation &&
                    proof.postConfigurationStageIdentity == budget.postConfigurationStageIdentity
            default: return false
            }
        }
    }
    var configurationProgress: AudioSessionConfigurationProgress
    // Task5负责计算有效边界；4b只消费本CAS确认的生存状态。
    var permitsFurtherCalls: Bool
    var acquisitionOwnershipProof: AcquisitionConfiguredLeaseOwnershipProof?
    var processReceipt: ProcessAudioSessionConfigurationReceipt?
    var configuredReceipt: ConfiguredSessionReceipt?
    var inactiveReceipt: InactiveAudioSessionConfigurationReceipt?
    var currentReactivationProof: AudioSessionReactivationProof? = nil
}

enum OutputControlRecordRetirement: Sendable, Equatable {
    case rejected
    case retired(followUp: ControlTaskTicket?)
}
