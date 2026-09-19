// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

struct AudioSessionReactivationBudgetTicket: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let sessionIdentity: PlaybackSessionIdentity
        let recoveryLineageIdentity: UInt64
        let budgetNonce: UInt64
    }
    let identity: Identity
    let committedGeneration: UInt64
    let parentOperationTicketIdentity: PlaybackProgressBudgetTicket.Identity
    let postConfigurationStageIdentity: UInt64?
    let mandatorySuffix: UInt64
    let activationCutoffEffectiveElapsed: UInt64
}
enum AudioSessionReactivationProof: Sendable, Equatable {
    case interruption(InterruptionDrainProof)
    case resetPostConfiguration(ResetPostConfigurationProof)
}
struct AudioSessionReactivationAttemptTicket: Sendable, Equatable {
    let reactivationBudgetIdentity: AudioSessionReactivationBudgetTicket.Identity
    let reactivationProof: AudioSessionReactivationProof
    let interruptionEpoch: UInt64
    let retainedContextNonce: UInt64
    let attemptNonce: AudioSessionActivationInvocationIdentity
}

enum AudioSessionReactivationBasePhase: Sendable, Equatable {
    case awaitingActivation, activatedAwaitingFirstProgress
}

struct AudioSessionReactivationFreezeCauses: OptionSet, Sendable, Equatable {
    let rawValue: UInt8
    static let systemInterruption = Self(rawValue: 1 << 0)
    static let routeUnavailable = Self(rawValue: 1 << 1)
    static let userPause = Self(rawValue: 1 << 2)
    var activationBlocked: Bool { !intersection([.systemInterruption, .userPause]).isEmpty }
}

struct AudioSessionReactivationCutoffArmTicket: Sendable, Equatable {
    let reactivationBudgetIdentity: AudioSessionReactivationBudgetTicket.Identity
    let reactivationAttemptIdentity: AudioSessionActivationInvocationIdentity
    let parentFreezeGeneration: UInt64
    let activationCutoffEffectiveElapsed: UInt64
    let armNonce: UInt64
}

/// 唯一恢复状态仅引用原parent预算；不存在第二份累计值或runningSince。
struct AudioSessionReactivationBudgetState: Sendable, Equatable {
    let ticket: AudioSessionReactivationBudgetTicket
    var basePhase: AudioSessionReactivationBasePhase
    var freezeCauses: AudioSessionReactivationFreezeCauses
    var cutoffArmTicket: AudioSessionReactivationCutoffArmTicket?
}
