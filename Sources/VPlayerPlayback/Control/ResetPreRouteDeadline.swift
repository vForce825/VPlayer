// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

struct ResetPreRouteRecoveryDeadlineTicket: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let lineageIdentity: UInt64
        let sessionIdentity: PlaybackSessionIdentity
        let parentOperationTicketIdentity: PlaybackProgressBudgetTicket.Identity
        let nonce: UInt64
    }
    let identity: Identity
}
struct ResetPreRouteTicketBinding: Sendable, Equatable {
    let rootIdentity: MediaServicesResetRootIdentity
    let ticketIdentity: ResetPreRouteRecoveryDeadlineTicket.Identity
    let bindingNonce: UInt64
}

struct ResetPreRouteRecoveryDeadlineArmTicket: Sendable, Equatable {
    let ticketIdentity: ResetPreRouteRecoveryDeadlineTicket.Identity
    let boundaryEffectiveElapsed: UInt64
    let freezeGeneration: UInt64
    let armNonce: UInt64
}

/// 唯一有效边界状态；root binding只引用ticket，不复制本状态。
struct ResetPreRouteRecoveryDeadlineState: Sendable, Equatable {
    let ticketIdentity: ResetPreRouteRecoveryDeadlineTicket.Identity
    var mandatorySuffix: UInt64
    var boundaryEffectiveElapsed: UInt64
    var accumulatedEffectiveTime: UInt64
    var runningSince: UInt64?
    var freezeGeneration: UInt64
    var deadlineArm: ResetPreRouteRecoveryDeadlineArmTicket?

    func effectiveElapsed(at instant: UInt64) -> UInt64? {
        guard let runningSince else { return accumulatedEffectiveTime }
        guard instant >= runningSince else { return nil }
        let (elapsed, overflow) = accumulatedEffectiveTime.addingReportingOverflow(instant - runningSince)
        return overflow ? nil : elapsed
    }

    func checkedEffectiveElapsed(at instant: UInt64) throws -> UInt64 {
        guard let elapsed = effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
        return elapsed
    }
}

struct OutputResetAcquisitionAdmission: Sendable, Equatable {
    let proof: ResetDrainProof
    let mandatorySuffix: UInt64
    let inheritedRouteAvailabilityConstraint: InheritedRouteAvailabilityConstraint?
}

struct OutputResetAcquisitionBinding: Sendable, Equatable {
    let proof: ResetDrainProof
    let preRouteTicket: ResetPreRouteRecoveryDeadlineTicket
    let binding: ResetPreRouteTicketBinding
    let inheritedRouteAvailabilityConstraint: InheritedRouteAvailabilityConstraint?
}
enum OutputResetResourceBinding: Sendable, Equatable {
    case draining(OutputResetDrainingBinding)
    case acquiring(OutputResetAcquisitionBinding)
    case retained(SystemRecoveryLeaseBinding)
}
struct OutputResetDrainingBinding: Sendable, Equatable {
    let preRouteBinding: ResetPreRouteTicketBinding
    let inheritedRouteAvailabilityConstraint: InheritedRouteAvailabilityConstraint?
}
struct RouteUnavailableDeadlineTicket: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let sessionIdentity: PlaybackSessionIdentity
        let monitorLifecycle: UInt64
        let mediaServicesEpochAtCreation: UInt64
        let deadlineAnchorInstant: UInt64
        let deadlineNonce: UInt64
    }
    let identity: Identity
    let deadlineInstant: UInt64
}
struct RouteUnavailableDeadlineArmTicket: Sendable, Equatable {
    let ticketIdentity: RouteUnavailableDeadlineTicket.Identity
    let armNonce: UInt64
}
struct InheritedRouteAvailabilityConstraint: Sendable, Equatable {
    struct OrdinaryAbsolute: Sendable, Equatable {
        let ticketIdentity: RouteUnavailableDeadlineTicket.Identity
        let deadlineInstant: UInt64
        let timerArmIdentity: UInt64
    }
    struct CarriedPostConfigurationStage: Sendable, Equatable {
        let originStageIdentity: UInt64
        let sourceTransitionIdentity: ConfigurationTransitionIdentity
        let sourceStageIdentity: UInt64
        let parentOperationTicketIdentity: PlaybackProgressBudgetTicket.Identity
        let remainingEffectiveTime: UInt64
        let freezeGeneration: UInt64
    }
    let ordinaryAbsolute: OrdinaryAbsolute?
    let carriedPostConfigurationStage: CarriedPostConfigurationStage?
}
struct RouteObservationTicket: Sendable, Equatable {
    let sessionIdentity: PlaybackSessionIdentity
    let monitorLifecycle: UInt64
    let mediaServicesEpoch: UInt64
    let interruptionEpoch: UInt64
    let audioSessionConfigurationGeneration: UInt64
    let audioSessionActivationNonce: UInt64
    let configurationTransitionIdentity: ConfigurationTransitionIdentity?
    let observationNonce: UInt64
}
struct PostConfigurationRouteBudget: Sendable, Equatable {
    let configurationTransitionIdentity: ConfigurationTransitionIdentity
    let stageIdentity: UInt64
    let carriedStageLineageIdentity: UInt64?
    let configurationGeneration: UInt64
    let parentOperationDeadline: PlaybackProgressBudgetTicket.Identity
    let inheritedRouteAvailabilityConstraint: InheritedRouteAvailabilityConstraint?
    let maximumEffectiveDuration: UInt64
    var accumulatedEffectiveTime: UInt64
    let attemptNonce: UInt64
}

struct PostConfigurationRouteState: Sendable, Equatable {
    var budget: PostConfigurationRouteBudget
    var runningSince: UInt64?
    var freezeGeneration: UInt64

    func effectiveElapsed(at instant: UInt64) -> UInt64? {
        guard let runningSince else { return budget.accumulatedEffectiveTime }
        guard instant >= runningSince else { return nil }
        let (elapsed, overflow) = budget.accumulatedEffectiveTime.addingReportingOverflow(instant - runningSince)
        return overflow ? nil : elapsed
    }

    func checkedEffectiveElapsed(at instant: UInt64) throws -> UInt64 {
        guard let elapsed = effectiveElapsed(at: instant) else { throw PlaybackSafetyFailure.clockOverflow }
        return elapsed
    }
}

struct PostConfigurationRouteDeadlineArmTicket: Sendable, Equatable {
    let configurationTransitionIdentity: ConfigurationTransitionIdentity
    let stageIdentity: UInt64
    let configurationGeneration: UInt64
    let parentOperationTicketIdentity: PlaybackProgressBudgetTicket.Identity
    let attemptNonce: UInt64
    let freezeGeneration: UInt64
}
