// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// One reservation in the existing process ledger. The final reference, including
/// detached immutable facts/receipt aliases, releases the original reservation.
final class HLSApplicationLifetimeCharge: @unchecked Sendable {
    let reservedBytes: Int
    private let ledger: HLSDeliveryApplicationChargeLedger
    private let reservation: PlaybackApplicationChargeReservation

    init(bytes: Int, ledger: HLSDeliveryApplicationChargeLedger = .shared) throws {
        self.ledger = ledger
        reservedBytes = bytes
        reservation = try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: bytes)
    }

    deinit { ledger.release(reservation) }
}

/// Prepaid transport domain. Local leases partition its existing application
/// reservation, including immutable protection bytes and final transfer aliases.
/// This does not claim an aggregate bound on opaque URLSession/Network buffers.
final class HLSProxyBudget: @unchecked Sendable {
    static let domainBytes = 32 * 1_024 * 1_024
    // An application retention policy, not an SDK callback-size guarantee.
    // Ordinary CFNetwork callbacks coalesce beyond 256 KiB. One admitted body
    // window covers up to 1 MiB while the unchanged domain still caps all users.
    static let transferBufferBytes = 1_024 * 1_024
    static let maximumTransfers = 8
    static let maximumConnections = 16
    private let charge: HLSApplicationLifetimeCharge
    private let lock = NSLock()
    private var bytes = 128 * 1_024
    private var transfers = 0
    private var connections = 0

    init(ledger: HLSDeliveryApplicationChargeLedger = .shared) throws {
        charge = try HLSApplicationLifetimeCharge(bytes: Self.domainBytes, ledger: ledger)
    }

    final class Lease: @unchecked Sendable {
        private let budget: HLSProxyBudget
        private let bytes: Int
        private let kind: Int
        fileprivate init(budget: HLSProxyBudget, bytes: Int, kind: Int) {
            self.budget = budget; self.bytes = bytes; self.kind = kind
        }
        deinit { budget.release(bytes: bytes, kind: kind) }

        func reserveBodyEnvelope(responseLength: Int64?) throws -> BodyEnvelope {
            guard kind == 1, responseLength.map({ $0 >= 0 }) ?? true else { throw HLSSourceError.network }
            let maximum = Int(min(responseLength ?? Int64(HLSProxyBudget.transferBufferBytes),
                Int64(HLSProxyBudget.transferBufferBytes)))
            // Pay for the complete original callback and a conservative separate
            // native-send alias before URLSession may deliver any body callback.
            let retention = try budget.reserve(bytes: 2 * maximum)
            return BodyEnvelope(maximumCallbackBytes: maximum, retention: retention)
        }
    }

    final class BodyEnvelope: @unchecked Sendable {
        let maximumCallbackBytes: Int
        private let retention: Lease
        fileprivate init(maximumCallbackBytes: Int, retention: Lease) {
            self.maximumCallbackBytes = maximumCallbackBytes; self.retention = retention
        }
        func accepts(_ bytes: Int) -> Bool { bytes >= 0 && bytes <= maximumCallbackBytes }
    }

    var usage: (bytes: Int, transfers: Int, connections: Int) {
        lock.withLock { (bytes, transfers, connections) }
    }
    func admitTransfer() throws -> Lease { try reserve(bytes: 512 * 1_024, kind: 1) }
    func admitConnection() throws -> Lease { try reserve(bytes: 64 * 1_024, kind: 2) }
    func reserve(bytes: Int) throws -> Lease { try reserve(bytes: bytes, kind: 0) }

    private func reserve(bytes: Int, kind: Int) throws -> Lease {
        try lock.withLock {
            guard bytes >= 0, bytes <= Self.domainBytes - self.bytes,
                  kind != 1 || transfers < Self.maximumTransfers,
                  kind != 2 || connections < Self.maximumConnections else {
                throw LoopbackHTTPReservationError.hardCapacityExceeded
            }
            self.bytes += bytes
            if kind == 1 { transfers += 1 }
            if kind == 2 { connections += 1 }
            return Lease(budget: self, bytes: bytes, kind: kind)
        }
    }

    private func release(bytes: Int, kind: Int) {
        lock.withLock {
            precondition(self.bytes >= bytes)
            self.bytes -= bytes
            if kind == 1 { precondition(transfers > 0); transfers -= 1 }
            if kind == 2 { precondition(connections > 0); connections -= 1 }
        }
    }
}
