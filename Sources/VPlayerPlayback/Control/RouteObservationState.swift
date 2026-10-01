// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

struct RouteObservationReasons: OptionSet, Sendable, Equatable {
    let rawValue: UInt16
    static let initialAuthoritativeSampleRequired = Self(rawValue: 1 << 8)
}

/// Task7消费同一固定值；此处不实现getter、stability计时或通知执行。
struct PendingRouteObservation: Sendable, Equatable {
    var ticket: RouteObservationTicket?
    var ordinaryDeadlineState: OrdinaryRouteDeadlineState?
    var deadline: RouteUnavailableDeadlineTicket? { ordinaryDeadlineState?.ticket }
    var sampler: ControlTaskTicket?
    var firstEventObservedInstant: UInt64? = nil
    var latestNotificationRevision: UInt64 = 0
    var latestObservation: PlaybackRouteIngress?
    var reasons: RouteObservationReasons
    var topologyChangeHint: Bool
    var outputConfigurationChanged: Bool
    var sampleInFlight = false
    var resamplePending = false
}

struct OrdinaryRouteDeadlineState: Sendable, Equatable {
    let ticket: RouteUnavailableDeadlineTicket
    var armNonce: UInt64
    var arm: RouteUnavailableDeadlineArmTicket { .init(ticketIdentity: ticket.identity, armNonce: armNonce) }
}

struct OutputRouteSampleClaim: Sendable, Equatable {
    let source: ControlTaskTicket
    let observation: RouteObservationTicket
    let authority: PlaybackRouteAuthorityIdentity
}

/// 唯一getter事实；通知hint不能写入，none不伪造任何端点身份。
enum OutputAuthoritativeRoute: Sendable, Equatable {
    case unknown
    case none
    case available(PlaybackRouteSemanticIdentity)
    var semantic: PlaybackRouteSemanticIdentity? {
        if case .available(let value) = self { return value }
        return nil
    }
}

enum OutputRouteSampleResult: Sendable, Equatable {
    case none
    case available(PlaybackRouteSemanticIdentity)
}

/// 同一次授权 SDK 样本的固定时序值；不参与端点、后端或稳定票的身份比较。
struct AudioSessionRouteOutputTiming: Sendable, Equatable {
    static let zero = Self(outputLatency: 0, ioBufferDuration: 0)
    let outputLatency: Double
    let ioBufferDuration: Double

    init(outputLatency: Double, ioBufferDuration: Double) {
        self.outputLatency = outputLatency.isFinite && outputLatency >= 0 ? outputLatency : 0
        self.ioBufferDuration = ioBufferDuration.isFinite && ioBufferDuration >= 0 ? ioBufferDuration : 0
    }
}

/// lane只交此固定值；最终token/incarnation只由最新样本的同一次completion CAS生成。
enum AudioSessionRouteSampleEvidence: Sendable, Equatable {
    case none
    case available(
        ports: PlaybackRoutePorts,
        endpointFingerprint: SessionEndpointFingerprint,
        outputTiming: AudioSessionRouteOutputTiming = .zero
    )
    case invalid
}

/// 完整权威字段封装于authority；revisionAtArm即authority.routeObservationRevision。
struct RouteStabilityTicket: Sendable, Equatable {
    let observation: RouteObservationTicket
    let authority: PlaybackRouteAuthorityIdentity
    let source: ControlTaskTicket
    let anchorInstant: UInt64
    let deadlineInstant: UInt64
    let nonce: UInt64
}

struct OutputRouteStabilityCandidate: Sendable, Equatable {
    struct Arm: Sendable, Equatable {
        let deadlineInstant: UInt64
        let nonce: UInt64
    }
    let source: ControlTaskTicket
    let observation: RouteObservationTicket
    let authority: PlaybackRouteAuthorityIdentity
    let firstMatchingSampleInstant: UInt64
    let boundary: OutputRouteAvailabilityBoundary
    var arm: Arm?
    let outputTiming: AudioSessionRouteOutputTiming

    init(
        source: ControlTaskTicket,
        observation: RouteObservationTicket,
        authority: PlaybackRouteAuthorityIdentity,
        firstMatchingSampleInstant: UInt64,
        boundary: OutputRouteAvailabilityBoundary,
        arm: Arm?,
        outputTiming: AudioSessionRouteOutputTiming = .zero
    ) {
        self.source = source
        self.observation = observation
        self.authority = authority
        self.firstMatchingSampleInstant = firstMatchingSampleInstant
        self.boundary = boundary
        self.arm = arm
        self.outputTiming = outputTiming
    }

    // 完整票从同一登记候选和准确arm事实投影，不重复持有第二份authority。
    var stabilityTicket: RouteStabilityTicket? {
        arm.map { .init(observation: observation, authority: authority, source: source,
            anchorInstant: firstMatchingSampleInstant, deadlineInstant: $0.deadlineInstant, nonce: $0.nonce) }
    }
}

enum OutputRouteAvailabilityBoundary: Sendable, Equatable {
    case ordinary(RouteUnavailableDeadlineTicket)
    case postConfiguration(ConfigurationTransitionIdentity, stageIdentity: UInt64)
}

enum RouteObservationState: Sendable, Equatable {
    case open(PlaybackRouteAuthorityIdentity)
    case pending(PendingRouteObservation)

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}
