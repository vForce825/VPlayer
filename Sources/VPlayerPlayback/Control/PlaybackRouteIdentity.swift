// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// session随机salt下的去标识化完整端点证据；不是最终可提交的topology incarnation。
struct SessionEndpointFingerprint: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var first: UInt64 = 0
    private var second: UInt64 = 0
    private var third: UInt64 = 0
    private var fourth: UInt64 = 0
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func precedes(_ other: Self) -> Bool {
        // 四个原始字节段按大端数值比较，严格保持32字节的首异顺序及相等非先于语义。
        if first != other.first { return first.bigEndian < other.first.bigEndian }
        if second != other.second { return second.bigEndian < other.second.bigEndian }
        if third != other.third { return third.bigEndian < other.third.bigEndian }
        if fourth != other.fourth { return fourth.bigEndian < other.fourth.bigEndian }
        return false
    }
}

enum PlaybackBackendKind: Sendable, Equatable {
    case sampleBuffer
    case hlsAVPlayer
}

public struct PlaybackRoutePorts: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let hdmi = Self(rawValue: 1 << 0)
    public static let airPlay = Self(rawValue: 1 << 1)
    public static let bluetooth = Self(rawValue: 1 << 2)
    public static let builtIn = Self(rawValue: 1 << 3)
    public static let other = Self(rawValue: 1 << 4)
}

struct OutputConfigurationIncarnation: Sendable, Equatable {
    private let value: UInt64

    init(rawValue: UInt64) {
        value = rawValue
    }
}

struct EndpointTopologyToken: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let value: UInt64

    init(rawValue: UInt64) {
        value = rawValue
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<(label: String?, value: Any)>())
    }
}

struct PlaybackRouteSemanticIdentity: Sendable, Equatable {
    let ports: PlaybackRoutePorts
    let backend: PlaybackBackendKind
    let outputConfigurationIncarnation: OutputConfigurationIncarnation
    let endpointTopologyToken: EndpointTopologyToken
}

/// 交接/稳定提交的准确权威投影，不是另一份system状态机。
struct PlaybackRouteAuthorityIdentity: Sendable, Equatable {
    let sessionIdentity: PlaybackSessionIdentity
    let monitorLifecycle: UInt64
    let mediaServicesEpoch: UInt64
    let interruptionEpoch: UInt64
    let audioSessionConfigurationGeneration: UInt64
    let audioSessionActivationNonce: UInt64
    let audioAdmissionFenceRevision: UInt64
    let routeObservationRevision: UInt64
    let semanticIdentity: PlaybackRouteSemanticIdentity?
    let configurationTransitionIdentity: ConfigurationTransitionIdentity?
    let postConfigurationStageIdentity: UInt64?
    // nil准确表示system phase不是open，不能据generation相等猜测已开放。
    let systemOpenConfigurationGeneration: UInt64?
}

struct StableRouteCommitIdentity: Sendable, Equatable {
    let epoch: UInt64
    let authority: PlaybackRouteAuthorityIdentity

    func exactlyMatches(_ current: PlaybackRouteAuthorityIdentity, observationGateOpen: Bool) -> Bool {
        observationGateOpen && current.semanticIdentity != nil && authority == current &&
            current.systemOpenConfigurationGeneration == current.audioSessionConfigurationGeneration
    }
}
