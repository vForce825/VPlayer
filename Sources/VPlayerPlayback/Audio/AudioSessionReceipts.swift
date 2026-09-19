// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

struct ProcessAudioSessionConfigurationReceipt: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let mediaServicesEpoch: UInt64
        let configurationGeneration: UInt64
        let receiptNonce: UInt64
    }
    let identity: Identity
    let actualPolicy: AudioSessionActualPolicy
    let preferredFailureReason: AudioSessionFixedFailure?
    let multichannelCapability: Bool
    let planDigest: PreferredAudioSessionConfigurationPlan
    let attemptLineage: AudioSessionConfigurationAttempt
}
struct ConfiguredSessionReceipt: Sendable, Equatable {
    let leaseID: UInt64
    let processConfigurationReceiptIdentity: ProcessAudioSessionConfigurationReceipt.Identity
}
struct ActiveSessionReceipt: Sendable, Equatable {
    let leaseID: UInt64
    let configurationGeneration: UInt64
    let interruptionEpoch: UInt64
    let activationNonce: UInt64
}
struct InactiveAudioSessionConfigurationReceipt: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let mediaServicesEpoch: UInt64
        let attemptNonce: UInt64
        let receiptNonce: UInt64
    }
    let identity: Identity
    let actualPolicy: AudioSessionActualPolicy
    let preferredFailureReason: AudioSessionFixedFailure?
    let planDigest: PreferredAudioSessionConfigurationPlan
    let attemptLineage: AudioSessionConfigurationAttempt
    let multichannelCapability: Bool
}
struct AudioSessionCallIdentity: Sendable, Equatable {
    let record: ControlTaskTicket
    let phaseIdentity: AudioSessionPhaseIdentity
    // phaseNonce指向该record冻结的完整purpose；终态前不得复用。
}
struct AudioSessionCanceledBeforeClaimProof: Sendable, Equatable {
    let callIdentity: AudioSessionCallIdentity
}
enum AudioSessionActivationTerminalOutcome: Sendable, Equatable {
    case notInvoked(AudioSessionCanceledBeforeClaimProof)
    case returnedFailure(AudioSessionCallIdentity, AudioSessionFixedFailure)
    case returnedSuccess(AudioSessionCallIdentity)
}
enum AudioSessionInactiveProof: Sendable, Equatable {
    // 只由真实握手且没有继承active责任时签发。
    case reservation(AcquisitionConfiguredLeaseOwnershipProof)
    case activationNotInvoked(AudioSessionCanceledBeforeClaimProof)
    case activationReturnedFailure(AudioSessionCallIdentity, AudioSessionFixedFailure)
    case interruption(InterruptionDrainProof)
}
enum AudioSessionActiveAuthority: Sendable, Equatable {
    case activeReceipt(ActiveSessionReceipt, AudioSessionPhaseIdentity)
    case returnedSuccess(AudioSessionCallIdentity)
}
enum AudioSessionDeactivationResult: Sendable, Equatable {
    case succeeded
    case failed(AudioSessionFixedFailure)
}
enum AudioSessionDeactivationDisposition: Sendable, Equatable {
    case confirmedInactive(AudioSessionInactiveProof)
    case awaitingActivationOutcome(AudioSessionCallIdentity)
    case requiresDeactivate(AudioSessionActiveAuthority)
    case deactivationInFlight(AudioSessionCallIdentity)
    case invalidatedByMediaServicesReset(mediaServicesEpoch: UInt64)
    case deactivationSettled(AudioSessionCallIdentity, AudioSessionDeactivationResult)
}
