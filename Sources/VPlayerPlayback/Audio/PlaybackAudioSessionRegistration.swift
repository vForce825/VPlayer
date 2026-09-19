// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

struct PlaybackAudioSessionRegistrationIdentity: Sendable, Equatable {
    let acquisition: ControlTaskTicket
    let leaseID: UInt64
    let monitorLifecycle: UInt64
    var sessionIdentity: PlaybackSessionIdentity {
        switch acquisition.group.resourceIdentity {
        case .session(let session), .context(let session, _), .lease(let session, _), .monitor(let session, _): session
        case .backend(let backend): backend.sessionIdentity
        case .outputLifecycle(let lifecycle): lifecycle.backendIdentity.sessionIdentity
        }
    }
}

/// 只保存不可变原身份和盐；accumulator、relay、closing及stopped仍由唯一资源context持有。
final class PlaybackAudioSessionRegistration: OwnedPlaybackResource, Equatable, @unchecked Sendable {
    static func == (lhs: PlaybackAudioSessionRegistration, rhs: PlaybackAudioSessionRegistration) -> Bool { lhs === rhs }
    let identity: PlaybackAudioSessionRegistrationIdentity
    let salt: AudioSessionEndpointSalt
    private weak var registry: ControlTaskRegistry?

    init(identity: PlaybackAudioSessionRegistrationIdentity, salt: AudioSessionEndpointSalt,
        registry: ControlTaskRegistry) {
        self.identity = identity
        self.salt = salt
        self.registry = registry
    }

    /// Task7的底层通知解析器接入此入口；旧handle不能改变新session的安全状态。
    func receiveRoute(_ ingress: PlaybackRouteIngress) {
        registry?.executor.safetyIngress.receiveRegisteredRoute(ingress, registration: self)
    }

    func stop(_ task: ControlTaskTicket) -> Bool {
        registry?.stopAudioSessionRegistration(self, task: task) ?? false
    }
}

/// 固定32字节；不提供诊断、反射或持久化中的原始表示。
struct AudioSessionEndpointSalt: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var first: UInt64 = 0
    private var second: UInt64 = 0
    private var third: UInt64 = 0
    private var fourth: UInt64 = 0

    static func make(using sdk: any PlaybackAudioSessionSDK) -> Self? {
        var value = Self()
        guard withUnsafeMutableBytes(of: &value, { sdk.fillRandomBytes($0) }) else { return nil }
        return value
    }
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum AudioSessionDataSourceEvidence: Sendable {
    case missing
    case integer(Int64)
    case invalid
}

/// 只在lane投影期间借用；原始SDK对象和标识永不进入Cell。
struct AudioSessionRouteEndpoint: @unchecked Sendable {
    let uid: NSString
    let portType: NSString
    let dataSource: AudioSessionDataSourceEvidence
}

protocol AudioSessionRouteSnapshot: AnyObject, Sendable {
    var endpointCount: Int { get }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint
}
