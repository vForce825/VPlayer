// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 对 Registry 已登记 suspend operation 的固定槽投影；自身不创建 Task。
/// 并发 caller 由 Registry 原 runner 的 Task 终态通道 join；此投影没有 continuation。
@MainActor
final class OutputPlayerStopTask {
    private let suspendTaskNonce: UInt64
    private let registryIssuerIdentity: UInt64
    private let itemGeneration: UInt64
    private let closeStopNonce: UInt64?
    private var completedReceiptIdentity: AVPlayerQuiescenceReceiptIdentity?
    private var terminalError: AVPlayerItemCoordinatorFailure?

    init(item: AVPlayerItemInstanceIdentity,
         registryIssuerIdentity: UInt64,
         suspendTicket: OutputSuspendTicket,
         closeClaim: PotentiallyAudibleOutputCloseClaim?) {
        precondition(item.outputLifecycleEpoch == suspendTicket.lifecycle)
        suspendTaskNonce = suspendTicket.task.nonce
        self.registryIssuerIdentity = registryIssuerIdentity
        itemGeneration = item.itemGeneration
        closeStopNonce = closeClaim?.stopNonce
    }

    func value(item: AVPlayerItemInstanceIdentity,
               suspendTicket: OutputSuspendTicket,
               closeClaim: PotentiallyAudibleOutputCloseClaim?) async throws
        -> AVPlayerQuiescenceReceipt {
        guard item.itemGeneration == itemGeneration,
              item.outputLifecycleEpoch == suspendTicket.lifecycle,
              matches(suspendTicket: suspendTicket, closeClaim: closeClaim) else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        if let completedReceiptIdentity {
            return AVPlayerQuiescenceReceipt(identity: completedReceiptIdentity,
                item: item, suspendTicket: suspendTicket,
                priorActivationEpoch: suspendTicket.priorActivation,
                stopNonce: closeClaim?.stopNonce, closeClaim: closeClaim,
                directlyConfirmedRateZero: true)
        }
        if let terminalError { throw terminalError }
        throw AVPlayerItemCoordinatorFailure.operationInFlight
    }

    func value(registryIssuerIdentity: UInt64,
               suspendTicket: OutputSuspendTicket,
               closeClaim: PotentiallyAudibleOutputCloseClaim?) async throws
        -> AVPlayerQuiescenceReceipt {
        guard registryIssuerIdentity == self.registryIssuerIdentity else {
            throw AVPlayerItemCoordinatorFailure.operationInFlight
        }
        // issuer 域加 task nonce 唯一冻结完整票，跨 Registry 的数值碰撞不能 join。
        // 仅补存不能从原票恢复的 item generation，避免清理后保留完整 request。
        return try await value(item: .init(outputLifecycleEpoch: suspendTicket.lifecycle,
                                   itemGeneration: itemGeneration),
                        suspendTicket: suspendTicket, closeClaim: closeClaim)
    }

    func matches(suspendTicket: OutputSuspendTicket,
                 closeClaim: PotentiallyAudibleOutputCloseClaim?) -> Bool {
        suspendTaskNonce == suspendTicket.task.nonce
            && closeStopNonce == closeClaim?.stopNonce
    }

    func complete(_ result: Result<AVPlayerQuiescenceReceipt, AVPlayerItemCoordinatorFailure>) {
        guard completedReceiptIdentity == nil, terminalError == nil else { return }
        switch result {
        case .success(let receipt): completedReceiptIdentity = receipt.identity
        case .failure(let error): terminalError = error
        }
    }

    var receiptIdentity: AVPlayerQuiescenceReceiptIdentity? {
        completedReceiptIdentity
    }
}
