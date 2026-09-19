// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

/// 门面不保存资源、phase或第二套匹配决策；全部转换委托原registry的具体同锁CAS。
struct OutputCleanupCoordinator: Sendable {
    let registry: ControlTaskRegistry

    func begin(contextNonce: UInt64, reason: OutputTransitionReason, at instant: UInt64,
        teardown: Bool = false, sourceActivation: ActivationEpoch? = nil) throws -> OutputTransitionOwnerTicket? {
        try registry.beginOutputTransition(contextNonce: contextNonce, reason: reason,
            anchorInstant: instant, teardown: teardown, sourceActivation: sourceActivation)
    }

    func advance(owner: OutputTransitionOwnerTicket) throws -> ControlTaskTicket? {
        try registry.advanceOutputCleanup(owner: owner)
    }

    func completeSuspend(_ receipt: OutputQuiescenceReceipt) -> Bool {
        registry.completeOutputSuspend(receipt)
    }

    func completeRetirement(_ ticket: ControlTaskTicket, lifecycle: OutputLifecycleEpoch) -> Bool {
        registry.completeOutputRetirement(ticket, lifecycle: lifecycle)
    }

    func completeTeardown(_ ticket: ControlTaskTicket, backend: PlaybackBackendIdentity,
        contextNonce: UInt64) -> OutputBackendDisposalRunner? {
        registry.completeOutputTeardown(ticket, backendIdentity: backend, contextNonce: contextNonce)
    }

    func completeMonitorStop(_ ticket: ControlTaskTicket, lifecycle: UInt64) -> Bool {
        registry.completeOutputMonitorStop(ticket, monitorLifecycle: lifecycle)
    }
}
