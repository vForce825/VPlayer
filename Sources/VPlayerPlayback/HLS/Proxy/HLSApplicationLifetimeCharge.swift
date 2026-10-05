// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Synchronization

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
    // An application-created byte window, not a URLSession buffer-size claim.
    static let transferBufferBytes = 32 * 1_024
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

        func reserveBodyEnvelope() throws -> BodyEnvelope {
            guard kind == 1 else { throw HLSSourceError.network }
            let maximum = HLSProxyBudget.transferBufferBytes
            // Reserve before bytes(for:) starts: fixed app window plus a
            // conservative separate native-send alias. The SDK's AsyncBytes
            // implementation remains opaque and outside this app-owned domain.
            let retention = try budget.reserve(bytes: 2 * maximum)
            return BodyEnvelope(maximumWindowBytes: maximum, retention: retention)
        }
    }

    final class BodyEnvelope: @unchecked Sendable {
        let maximumWindowBytes: Int
        private let retention: Lease
        fileprivate init(maximumWindowBytes: Int, retention: Lease) {
            self.maximumWindowBytes = maximumWindowBytes; self.retention = retention
        }
    }

    /// One fixed allocation, filled by the sole async reader. No Data append,
    /// payload resize, or upstream Data callback crosses this ownership boundary.
    final class ReadWindow: @unchecked Sendable {
        let envelope: BodyEnvelope
        private let storage: UnsafeMutablePointer<UInt8>
        var capacity: Int { envelope.maximumWindowBytes }
        init(envelope: BodyEnvelope) {
            self.envelope = envelope
            storage = .allocate(capacity: envelope.maximumWindowBytes)
        }
        deinit { storage.deallocate() }
        func store(_ byte: UInt8, at index: Int) {
            precondition(index >= 0 && index < capacity)
            storage[index] = byte
        }
        func borrow(offset: Int = 0, count: Int) -> Borrow {
            precondition(offset >= 0 && count > 0 && count <= capacity && offset <= capacity - count)
            return Borrow(window: self, offset: offset, count: count)
        }
        func send(offset: Int = 0, count: Int, to connection: HLSProxyConnection) async throws {
            let borrow = borrow(offset: offset, count: count)
            let result: Result<Void, any Error>
            do { try await submit(borrow, to: connection); result = .success(()) }
            catch { result = .failure(error) }
            // The send callback alone does not prove Data's backing alias ended.
            // This join also handles Foundation copying tiny values inline.
            await borrow.waitForRelease()
            try result.get()
        }
        private func submit(_ borrow: Borrow, to connection: HLSProxyConnection) async throws {
            var bytes: Data? = borrow.makeData()
            defer { bytes = nil }
            try await connection.sendBytes(bytes!, retaining: envelope)
        }
        final class Borrow: @unchecked Sendable {
            private let window: ReadWindow
            private let offset: Int
            private let count: Int
            private let lock = NSLock()
            private var released = false, madeData = false
            private var waiter: CheckedContinuation<Void, Never>?
            fileprivate init(window: ReadWindow, offset: Int, count: Int) {
                self.window = window; self.offset = offset; self.count = count
            }
            func makeData() -> Data {
                lock.withLock { precondition(!madeData); madeData = true }
                // Borrow retains window/lease; neither retains Data, so no cycle.
                return Data(bytesNoCopy: window.storage.advanced(by: offset), count: count,
                    deallocator: .custom { [self] _, _ in release() })
            }
            private func release() {
                let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    guard !released else { return nil }
                    released = true; defer { waiter = nil }; return waiter
                }
                pending?.resume()
            }
            func waitForRelease() async {
                await withCheckedContinuation { continuation in
                    let done = lock.withLock { () -> Bool in
                        if released { return true }
                        precondition(waiter == nil); waiter = continuation; return false
                    }
                    if done { continuation.resume() }
                }
            }
        }
    }

    /// A single producer and consumer share one fixed allocation. Published
    /// cells are immutable until the consumer returns their physical-send credit.
    /// No queue of Data values exists; each direction has at most one waiter.
    final class BytePipe: @unchecked Sendable {
        let window: ReadWindow
        private let written = Atomic<UInt64>(0)
        private let consumed = Atomic<UInt64>(0)
        private let readerWaiting = Atomic<Bool>(false)
        private let lock = NSLock()
        private var completion: Result<Void, any Error>?
        private var aborted: (any Error)?
        private var dataWaiter: CheckedContinuation<Void, Never>?
        private var spaceWaiter: CheckedContinuation<Void, Never>?
        init(envelope: BodyEnvelope) { window = ReadWindow(envelope: envelope) }
        func isFull(at position: UInt64) -> Bool {
            let read = consumed.load(ordering: .acquiring)
            precondition(position >= read)
            precondition(position - read <= UInt64(window.capacity))
            return position - read == UInt64(window.capacity)
        }
        func publish(_ byte: UInt8, at position: UInt64) throws {
            guard position < UInt64(Int64.max) else { throw HLSSourceError.byteLimit }
            precondition(!isFull(at: position))
            window.store(byte, at: Int(position % UInt64(window.capacity)))
            // SC publication + waiting-flag check pairs with SC flag registration
            // + publication recheck below. Acquire/release alone permits both
            // sides to read old values and lose the sole empty-to-nonempty wake.
            written.store(position + 1, ordering: .sequentiallyConsistent)
            if readerWaiting.load(ordering: .sequentiallyConsistent) { wakeDataWaiter() }
        }
        func waitForSpace(at position: UInt64) async throws {
            while true {
                let ready = try lock.withLock { () -> Bool in
                    if let aborted { throw aborted }
                    if let completion { try completion.get(); throw HLSSourceError.retired }
                    return !isFull(at: position)
                }
                if ready { return }
                await withCheckedContinuation { continuation in
                    let settled = lock.withLock { () -> Bool in
                        if aborted != nil || completion != nil || !isFull(at: position) { return true }
                        precondition(spaceWaiter == nil); spaceWaiter = continuation; return false
                    }
                    if settled { continuation.resume() }
                }
                // An abort wake is not capacity credit. In particular, it can
                // beat Task.cancel() on the other executor; recheck here before
                // allowing another iterator read/publication into a full ring.
            }
        }
        func nextSpan(at position: UInt64) async throws -> (offset: Int, count: Int)? {
            while true {
                try Task.checkCancellation()
                try lock.withLock { if let aborted { throw aborted } }
                let end = written.load(ordering: .sequentiallyConsistent)
                precondition(end >= position && end - position <= UInt64(window.capacity))
                if end > position {
                    let offset = Int(position % UInt64(window.capacity))
                    return (offset, min(Int(end - position), window.capacity - offset))
                }
                let terminal = lock.withLock { completion }
                if let terminal {
                    // EOF may have arrived after the first publication load.
                    // Observe the final committed bytes before declaring empty.
                    if written.load(ordering: .sequentiallyConsistent) > position { continue }
                    try terminal.get(); return nil
                }
                await withCheckedContinuation { continuation in
                    let ready = lock.withLock { () -> Bool in
                        readerWaiting.store(true, ordering: .sequentiallyConsistent)
                        if aborted != nil || completion != nil || written.load(ordering: .sequentiallyConsistent) > position {
                            readerWaiting.store(false, ordering: .sequentiallyConsistent); return true
                        }
                        precondition(dataWaiter == nil); dataWaiter = continuation; return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }
        func releaseThrough(_ position: UInt64) {
            precondition(position >= consumed.load(ordering: .relaxed) && position <= written.load(ordering: .acquiring))
            consumed.store(position, ordering: .releasing)
            // Paired registration rechecks under this same lock. No per-byte
            // producer lock is needed: this notification is once per sent span.
            let pending = lock.withLock { defer { spaceWaiter = nil }; return spaceWaiter }
            pending?.resume()
        }
        func finish(_ result: Result<Void, any Error>) {
            let pending = lock.withLock { () -> (CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Never>?) in
                if completion == nil { completion = result }
                readerWaiting.store(false, ordering: .sequentiallyConsistent)
                defer { dataWaiter = nil; spaceWaiter = nil }; return (dataWaiter, spaceWaiter)
            }
            pending.0?.resume(); pending.1?.resume()
        }
        func abort(_ error: any Error) {
            lock.withLock { if aborted == nil { aborted = error } }
            finish(.failure(error))
        }
        private func wakeDataWaiter() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                readerWaiting.store(false, ordering: .sequentiallyConsistent)
                defer { dataWaiter = nil }; return dataWaiter
            }
            pending?.resume()
        }
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
