// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// One prepaid, coalescing release signal and one monotonic deadline timer per
/// logical compressed rendition. It contains no graph, writer or media reference.
final class WriterCapacityWakeup: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: any PlaybackMonotonicClock
    private let timer: any PlaybackDeadlineTimer
    private let charge: HLSCompressedAudioApplicationReservation
    private var revision: UInt64 = 0
    private var cancelled = false
    private var deadline: UInt64?
    private var waiter: CheckedContinuation<Bool, Error>?

    static func make(ledger: HLSDeliveryApplicationChargeLedger = .shared,
                     clock: (any PlaybackMonotonicClock)? = nil) throws -> WriterCapacityWakeup {
        // Fixed class/lock/timer, two closures, one continuation and async frame
        // allowance; this is separate from source payload and shared input caps.
        let charge = try HLSCompressedAudioApplicationReservation.reserve(bytes: 8_192, ledger: ledger)
        return .init(clock: clock ?? DispatchPlaybackMonotonicClock(), charge: charge)
    }
    private init(clock: any PlaybackMonotonicClock, charge: HLSCompressedAudioApplicationReservation) {
        self.clock = clock; self.charge = charge
        timer = clock.makeDeadlineTimer(deliveryQueue: .global(qos: .userInitiated))
        timer.schedule(notAfterInstant: nil)
        timer.setEventHandler { [weak self, charge] in
            withExtendedLifetime(charge) { self?.deadlineReached() }
        }
        timer.activate()
    }
    deinit { timer.cancel() }
    var currentRevision: UInt64 { lock.withLock { revision } }
#if DEBUG
    var isWaitingForTesting: Bool { lock.withLock { waiter != nil } }
#endif
    func makeDeadline() throws -> UInt64 {
        let value = clock.nowNanoseconds.addingReportingOverflow(5_000_000_000)
        guard !value.overflow else { throw SegmentedFMP4WriterFailure.arithmeticOverflow }
        return value.partialValue
    }
    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Error>? in
            guard !cancelled else { return nil }
            if revision < UInt64.max { revision += 1 } else { cancelled = true }
            let value = waiter; waiter = nil; deadline = nil
            timer.schedule(notAfterInstant: nil)
            return value
        }
        continuation?.resume(returning: true)
    }
    func wait(after observed: UInt64, until limit: UInt64) async throws -> Bool {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Bool, Error>? = lock.withLock {
                    guard !cancelled else { return .failure(CancellationError()) }
                    guard clock.nowNanoseconds < limit else { return .success(false) }
                    guard revision == observed else { return .success(true) }
                    guard waiter == nil else { return .failure(SegmentedFMP4WriterFailure.illegalState) }
                    waiter = continuation; deadline = limit
                    timer.schedule(notAfterInstant: limit)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Error>? in
            cancelled = true
            let value = waiter; waiter = nil; deadline = nil
            timer.schedule(notAfterInstant: nil)
            return value
        }
        timer.cancel()
        continuation?.resume(throwing: CancellationError())
    }
    private func deadlineReached() {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Error>? in
            guard let deadline, waiter != nil, !cancelled else { return nil }
            guard clock.nowNanoseconds >= deadline else {
                timer.schedule(notAfterInstant: deadline); return nil
            }
            let value = waiter; waiter = nil; self.deadline = nil
            timer.schedule(notAfterInstant: nil)
            return value
        }
        continuation?.resume(returning: false)
    }
}
