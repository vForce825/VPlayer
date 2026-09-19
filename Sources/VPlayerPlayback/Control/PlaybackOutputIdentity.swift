// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

// 本文件只表示已签发身份；创建方必须使用共享checked allocator的对应域。
// session/backend/intent/prepare/outputLifecycle/activation分别使用同名域，禁止从零自增。
public struct PlaybackSessionIdentity: Sendable, Hashable {
    public let sessionID: UInt64
    public let requestID: UUID

    public init(sessionID: UInt64, requestID: UUID) {
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public struct PlaybackBackendIdentity: Sendable, Hashable {
    public let sessionIdentity: PlaybackSessionIdentity
    public let backendGeneration: UInt64

    public init(sessionIdentity: PlaybackSessionIdentity, backendGeneration: UInt64) {
        self.sessionIdentity = sessionIdentity
        self.backendGeneration = backendGeneration
    }
}

struct PlaybackIntentRevision: Sendable, Equatable {
    let rawValue: UInt64
}

struct PrepareTicket: Sendable, Equatable {
    let backendIdentity: PlaybackBackendIdentity
    let stableRouteCommitEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64
    let prepareNonce: UInt64
}

public struct OutputLifecycleEpoch: Sendable, Hashable {
    public let backendIdentity: PlaybackBackendIdentity
    public let outputNonce: UInt64

    public init(backendIdentity: PlaybackBackendIdentity, outputNonce: UInt64) {
        self.backendIdentity = backendIdentity
        self.outputNonce = outputNonce
    }
}

struct ActivationEpoch: Sendable, Equatable {
    let outputLifecycleEpoch: OutputLifecycleEpoch
    let audioAdmissionFenceRevision: UInt64
    let activationNonce: UInt64
}
