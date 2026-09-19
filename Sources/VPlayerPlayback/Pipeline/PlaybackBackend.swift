// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum BackendSuspendResult: Sendable, Equatable {
    case quiescent(ControlTaskRegistry.BackendQuiescenceProof)
    case requiresRetirement
}

enum BackendTeardownResult: Sendable, Equatable {
    case confirmedLocalOutputStopped
    /// backend 未能以自己的私有事实证明 retirement 完成；Registry 必须保持
    /// fail-closed，不能把错误路径推进为已清理。
    case unconfirmed
}

/// publication-sensitive backend 预拥有固定单槽；Registry 只在 lane 外读取该引用，
/// 再于 safety transaction 内通过 final slot 原子安装正式 authority。
protocol BackendPublicationReplacementAuthorityInstalling: AnyObject {
    var backendPublicationReplacementAuthoritySlot:
        ControlTaskRegistry.BackendPublicationReplacementAuthoritySlot { get }
}

protocol PlaybackBackend: OwnedPlaybackResource {
    var identity: PlaybackBackendIdentity { get }
    var presentation: PlaybackPresentation? { get }
    /// 只有 item-backed backend 提供；Registry 将它冻结进正 rate interval。
    var outputItemGeneration: UInt64? { get }
    
    func prepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws
    func reprepare(invocation: ControlTaskRegistry.BackendPrepareInvocation) async throws
    func activateOutput(invocation: ControlTaskRegistry.BackendPositiveRateInvocation) async throws
    func suspendOutput(invocation: ControlTaskRegistry.BackendSuspendInvocation) async -> BackendSuspendResult
    func retireOutput(epoch: OutputLifecycleEpoch) async -> BackendTeardownResult
}

extension PlaybackBackend {
    var outputItemGeneration: UInt64? { nil }
}
