// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation

/// The synchronous metrics boundary retains only two scalar counters, never an
/// AVFoundation log, event, URL, error, or a history of snapshots.
struct AVPlayerLogScalarSnapshot: Sendable, Equatable {
    let accessEventCount: Int
    let errorEventCount: Int
    static let empty = Self(accessEventCount: 0, errorEventCount: 0)
}

/// One physical reader and one coalesced pending refresh, including across item
/// replacement. Invalidating an installation does not pretend that a suspended
/// SDK read has completed or admit another physical reader beside it.
final class AVPlayerLogSnapshotCache: @unchecked Sendable {
    struct Scope: Sendable, Equatable {
        let item: AVPlayerItemInstanceIdentity
        let objectIdentity: ObjectIdentifier
        let installation: UUID
    }

    struct Ticket: Sendable, Equatable {
        let scope: Scope
        fileprivate let identity: UUID
    }

    private let lock = NSLock()
    private var scope: Scope?
    private var value: AVPlayerLogScalarSnapshot = .empty
    private var inFlight: Ticket?
    private var refreshPending = false
    /// Covers the one queued MainActor wake and the entire lifetime of its worker.
    private var workerScheduled = false
    private var wake: (@MainActor @Sendable () -> Void)?

    func installWake(_ wake: @escaping @MainActor @Sendable () -> Void) {
        let action = lock.withLock { () -> (@MainActor @Sendable () -> Void)? in
            self.wake = wake
            return scheduleLocked()
        }
        enqueue(action)
    }

    func activate(item: AVPlayerItemInstanceIdentity, objectIdentity: ObjectIdentifier) {
        let action = lock.withLock { () -> (@MainActor @Sendable () -> Void)? in
            scope = .init(item: item, objectIdentity: objectIdentity, installation: UUID())
            value = .empty
            refreshPending = true
            return scheduleLocked()
        }
        enqueue(action)
    }

    func requestRefresh(item: AVPlayerItemInstanceIdentity, objectIdentity: ObjectIdentifier) {
        let action = lock.withLock { () -> (@MainActor @Sendable () -> Void)? in
            guard scope?.item == item, scope?.objectIdentity == objectIdentity else { return nil }
            refreshPending = true
            return scheduleLocked()
        }
        enqueue(action)
    }

    func snapshot(item: AVPlayerItemInstanceIdentity,
                  objectIdentity: ObjectIdentifier) -> AVPlayerLogScalarSnapshot {
        lock.withLock {
            guard scope?.item == item, scope?.objectIdentity == objectIdentity else { return .empty }
            return value
        }
    }

    func beginRefresh() -> Ticket? {
        lock.withLock {
            guard inFlight == nil else { return nil }
            guard refreshPending, let scope else {
                workerScheduled = false
                return nil
            }
            refreshPending = false
            workerScheduled = true
            let ticket = Ticket(scope: scope, identity: UUID())
            inFlight = ticket
            return ticket
        }
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.withLock { scope == ticket.scope && inFlight == ticket }
    }

    @discardableResult
    func complete(_ ticket: Ticket, snapshot: AVPlayerLogScalarSnapshot) -> Bool {
        lock.withLock {
            guard inFlight == ticket else { return false }
            inFlight = nil
            guard scope == ticket.scope else { return false }
            value = snapshot
            return true
        }
    }

    /// Admission failed before any SDK read. Keep the request for the next
    /// notification/metrics sample, without spinning or allocating a retry task.
    func deferRefresh() {
        lock.withLock {
            guard inFlight == nil else { return }
            workerScheduled = false
        }
    }

    func invalidate() {
        lock.withLock {
            scope = nil
            value = .empty
            refreshPending = false
            // The old SDK read and its one physical worker remain owned until return.
        }
    }


#if DEBUG
    func inspectPreparationAllocations(_ body: (String, UnsafeRawPointer, Int) -> Void) {
        let objects: [(String, AnyObject)] = [
            ("owned/scalar async log cache", self), ("owned/scalar async log cache lock", lock)
        ]
        for (role, object) in objects {
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
            body(role, pointer, malloc_size(pointer))
        }
    }
#endif

    private func scheduleLocked() -> (@MainActor @Sendable () -> Void)? {
        guard refreshPending, !workerScheduled, let wake else { return nil }
        workerScheduled = true
        return wake
    }

    private func enqueue(_ action: (@MainActor @Sendable () -> Void)?) {
        guard let action else { return }
        DispatchQueue.main.async { action() }
    }
}
