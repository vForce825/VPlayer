// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public struct PlaybackAudioSessionLease: Hashable, Sendable {
    public let id: UInt64
    public let generation: UInt64
    public let isInterruptedAtAcquisition: Bool

    public init(
        id: UInt64,
        generation: UInt64,
        isInterruptedAtAcquisition: Bool = false
    ) {
        self.id = id
        self.generation = generation
        self.isInterruptedAtAcquisition = isInterruptedAtAcquisition
    }
}

public enum PlaybackAudioSessionRecoveryFailureStage: String, Sendable, Equatable {
    case mediaServicesResetConfiguration
    case mediaServicesResetActivation
    case interruptionReactivation
    case eventRelayCapacity
}

public enum PlaybackAudioSessionEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case explicitResumeSucceeded
    case resetConfigurationSucceeded
    case mediaServicesWereReset
    case recoveryFailed(stage: PlaybackAudioSessionRecoveryFailureStage)
}

/// system分支的身份由唯一Cell原回调发行；owner诊断不能冒充system入口回执。
struct PlaybackAudioSessionEventEnvelope: Sendable {
    let event: PlaybackAudioSessionEvent
    let systemReceipt: PlaybackSystemSafetyReceipt?
    var reactivationReceipt: AudioSessionReactivationCompletionReceipt? = nil
}

/// relay固定24字节key；系统key来自原Cell receipt，activation只引用原Authority登记nonce。
struct PlaybackAudioSessionEventKey: Sendable, Equatable {
    let event: PlaybackAudioSessionEvent
    let revisionOrActivationNonce: UInt64
    let eventEpoch: UInt64

    init?(envelope: PlaybackAudioSessionEventEnvelope) {
        event = envelope.event
        switch envelope.event {
        case .interruptionBegan, .interruptionEnded, .mediaServicesWereReset:
            guard let key = envelope.systemReceipt?.key else { return nil }
            let expected: PlaybackAudioSessionEvent
            switch key.kind {
            case .interruptionBegan: expected = .interruptionBegan
            case .interruptionEnded(let resume): expected = .interruptionEnded(shouldResume: resume)
            case .mediaServicesReset: expected = .mediaServicesWereReset
            }
            guard expected == event else { return nil }
            revisionOrActivationNonce = key.revision
            eventEpoch = key.eventEpoch
        case .explicitResumeSucceeded, .resetConfigurationSucceeded:
            // 无receipt的纯诊断不能取得Registry activation消费权。
            if let receipt = envelope.reactivationReceipt { revisionOrActivationNonce = receipt.activationNonce }
            else { revisionOrActivationNonce = 0 }
            eventEpoch = 0
        case .recoveryFailed:
            revisionOrActivationNonce = 0
            eventEpoch = 0
        }
    }
}


struct PlaybackControllerState: Sendable {
    var request: PlaybackRequest?
    var userPaused: Bool
    var readinessCycle: UInt64
    var activeRoutePorts: PlaybackRoutePorts?

    init(
        request: PlaybackRequest? = nil,
        userPaused: Bool = false,
        readinessCycle: UInt64 = 0,
        activeRoutePorts: PlaybackRoutePorts? = nil
    ) {
        self.request = request
        self.userPaused = userPaused
        self.readinessCycle = readinessCycle
        self.activeRoutePorts = activeRoutePorts
    }
}
