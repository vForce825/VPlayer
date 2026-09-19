// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct PlaybackCallbackDepth: Sendable {
    private(set) var value: UInt64
    mutating func enter() -> Bool {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { return false }
        value = next
        return true
    }
    mutating func leave() -> Bool {
        let (next, underflow) = value.subtractingReportingOverflow(1)
        guard !underflow else { return false }
        value = next
        return true
    }
}

enum PlaybackSafetyFailure: Error, Sendable, Equatable {
    case identitySpaceExhausted, callbackDepthOverflow, invalidEvidence, clockOverflow
}

enum PlaybackInterruptionState: Sendable, Equatable {
    case inactive, began, ended(shouldResume: Bool)
}

enum PlaybackSystemSafetyEvent: Sendable, Equatable {
    case mediaServicesReset
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
}

/// 仅记录原回调已经线性化的固定身份；不是再次调用SDK或清除veto的许可。
struct PlaybackSystemSafetyEventKey: Sendable, Equatable {
    let kind: PlaybackSystemSafetyEvent
    let revision: UInt64
    let eventEpoch: UInt64
}

struct PlaybackSystemSafetyReceipt: Sendable, Equatable {
    // 原Cell fold锁内签发key；完整receipt不重复保存key已经包含的事件/epoch。
    let key: PlaybackSystemSafetyEventKey
    private let otherEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64

    var event: PlaybackSystemSafetyEvent { key.kind }
    var revision: UInt64 { key.revision }
    var mediaServicesEpoch: UInt64 {
        if case .mediaServicesReset = event { return key.eventEpoch }
        return otherEpoch
    }
    var interruptionEpoch: UInt64 {
        if case .mediaServicesReset = event { return otherEpoch }
        return key.eventEpoch
    }

    init(event: PlaybackSystemSafetyEvent, revision: UInt64, mediaServicesEpoch: UInt64,
        interruptionEpoch: UInt64, audioAdmissionFenceRevision: UInt64) {
        if case .mediaServicesReset = event {
            key = .init(kind: event, revision: revision, eventEpoch: mediaServicesEpoch)
            otherEpoch = interruptionEpoch
        } else {
            key = .init(kind: event, revision: revision, eventEpoch: interruptionEpoch)
            otherEpoch = mediaServicesEpoch
        }
        self.audioAdmissionFenceRevision = audioAdmissionFenceRevision
    }
}

struct PendingResetIngress: Sendable, Equatable {
    let rootIdentity: UInt64
    let mediaServicesEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64
    let ingressInstant: UInt64
}

struct ResetPreRouteClockFold: Sendable, Equatable {
    let windowStartInstant: UInt64
    var effectiveNanoseconds: UInt64 = 0
    var lastIngressInstant: UInt64
    var frozen: Bool
    var freezeGeneration: UInt64 = 0

    mutating func advance(to instant: UInt64, frozen: Bool, freezeGeneration: UInt64) throws {
        guard instant >= lastIngressInstant else { throw PlaybackSafetyFailure.clockOverflow }
        if !self.frozen {
            let (total, overflow) = effectiveNanoseconds.addingReportingOverflow(instant - lastIngressInstant)
            guard !overflow else { throw PlaybackSafetyFailure.clockOverflow }
            effectiveNanoseconds = total
        }
        lastIngressInstant = instant
        self.frozen = frozen
        self.freezeGeneration = freezeGeneration
    }
}

struct PendingSystemSafetyIngress: Sendable, Equatable {
    // 只属于尚未消费窗口；apply后随pending整体复位，不能当latest state。
    var firstInterruptionBeganIngressInstant: UInt64?
    var interruptionBeganObserved: Bool { firstInterruptionBeganIngressInstant != nil }
    var firstUndrainedResetIngressInstant: UInt64?
    var latestResetIngress: PendingResetIngress?
    var latestInterruptionState: PlaybackInterruptionState = .inactive
    var resetPreRouteClockFold: ResetPreRouteClockFold?
    // 已有parent消费此窗口；首次派生票只使用上面的首reset窗口。
    var interruptionClockFold: ResetPreRouteClockFold?
    var throughRevision: UInt64 = 0
}

struct PlaybackOutputSafetyState: Sendable, Equatable {
    var outputPermitPresent = false
    var readinessOpen = false
    var routeObservationGateOpen = false
    var suspendRequired = false
    var activationCancellationRequired = false
    var speculativePreparationParked = false

    mutating func revokeForUserPause() {
        // 用户pause不是route失效；仍在进行的rate-0 prepare及真实stable commit继续有效。
        outputPermitPresent = false
        readinessOpen = false
        suspendRequired = true
        activationCancellationRequired = true
    }

    mutating func revokeForSafety() {
        outputPermitPresent = false
        readinessOpen = false
        routeObservationGateOpen = false
        suspendRequired = true
        activationCancellationRequired = true
        speculativePreparationParked = true
    }
}

struct PlaybackRouteIngress: Sendable, Equatable {
    let sessionIdentity: PlaybackSessionIdentity
    let monitorLifecycle: UInt64
    let notificationRevision: UInt64
    var reasonBits: UInt8
    var topologyChangeHint: Bool
    var outputConfigurationChanged: Bool
    // nil保留未知，不转为空端口集合。
    let observedRoute: PlaybackRouteSemanticIdentity?
}

struct PlaybackSafetySnapshot: Sendable, Equatable {
    var output = PlaybackOutputSafetyState()
    var outputPermitPresent: Bool { output.outputPermitPresent }
    var readinessOpen: Bool { output.readinessOpen }
    var routeObservationGateOpen: Bool { output.routeObservationGateOpen }
    var suspendRequired: Bool { output.suspendRequired }
    var drainScheduled = false
    var safetyIngressPending = false
    var callbackDepth: UInt64 = 0
    var throughRevision: UInt64 = 0
    var ownerSystemEventRevision: UInt64 = 0
    var mediaServicesEpoch: UInt64 = 0
    var interruptionEpoch: UInt64 = 0
    var audioAdmissionFenceRevision: UInt64 = 0
    var interruptionState: PlaybackInterruptionState = .inactive
    var interruptionVeto = false
    var userPaused = false
    var activationCancellationRequired: Bool { output.activationCancellationRequired }
    var speculativePreparationParked: Bool { output.speculativePreparationParked }
    var freezeGeneration: UInt64 = 0
    var failure: PlaybackSafetyFailure?
    // 首次fail-closed在原Cell锁内采样；后续失败与延迟终态都不得覆盖。
    var firstFailureInstant: UInt64?
    var system = PendingSystemSafetyIngress()
    var route: PlaybackRouteIngress?
    var firstRouteEventObservedInstant: UInt64?
}

enum PlaybackControlOperationDescriptor: Sendable, Equatable {
    case resourceOwnership, cleanupOwnership, drain
    case factoryAdmission, prepareAdmission, selectionAdmission, probeAdmission, activationAdmission, positiveRateAdmission
}

enum PlaybackSafetyBarrierResult<Value> {
    case retry
    case rejected
    case performed(Value)
}
