// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Foundation
@testable import VPlayerPlayback

final class ManualPlaybackClock: PlaybackMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64
    private weak var deadlineTimer1: ManualPlaybackDeadlineTimer?
    private weak var deadlineTimer2: ManualPlaybackDeadlineTimer?
    private var timerDeliveryCount = 0
    private var handlerInstallationCount = 0

    init(nowNanoseconds: UInt64) {
        instant = nowNanoseconds
    }

    convenience init(_ nowNanoseconds: UInt64) {
        self.init(nowNanoseconds: nowNanoseconds)
    }

    var nowNanoseconds: UInt64 {
        lock.withLock { instant }
    }

    func set(nowNanoseconds: UInt64) {
        let (d1, d2) = lock.withLock { () -> (ManualPlaybackDeadlineTimer.Delivery?, ManualPlaybackDeadlineTimer.Delivery?) in
            instant = nowNanoseconds
            return prepareDeliveriesLocked(force: false)
        }
        d1?.enqueue()
        d2?.enqueue()
    }

    func read() -> UInt64 { nowNanoseconds }

    func set(_ value: UInt64) {
        set(nowNanoseconds: value)
    }

    var deadlineTimerDeliveryCount: Int { lock.withLock { timerDeliveryCount } }
    var deadlineTimerHandlerInstallationCount: Int { lock.withLock { handlerInstallationCount } }
    var hasScheduledDeadlineTimer: Bool {
        lock.withLock { deadlineTimer1?.notAfterInstant != nil || deadlineTimer2?.notAfterInstant != nil }
    }

    func fireDeadlineTimerEarly() {
        let (d1, d2) = lock.withLock { prepareDeliveriesLocked(force: true) }
        d1?.enqueue()
        d2?.enqueue()
    }

    func advance(nanoseconds: UInt64) {
        let (d1, d2) = lock.withLock { () -> (ManualPlaybackDeadlineTimer.Delivery?, ManualPlaybackDeadlineTimer.Delivery?) in
            let (advanced, overflow) = instant.addingReportingOverflow(nanoseconds)
            precondition(!overflow, "测试时钟不能回绕")
            instant = advanced
            return prepareDeliveriesLocked(force: false)
        }
        d1?.enqueue()
        d2?.enqueue()
    }

    func makeDeadlineTimer(deliveryQueue: DispatchQueue) -> any PlaybackDeadlineTimer {
        let timer = ManualPlaybackDeadlineTimer(clock: self, deliveryQueue: deliveryQueue)
        lock.withLock {
            if deadlineTimer1 == nil {
                deadlineTimer1 = timer
            } else if deadlineTimer2 == nil {
                deadlineTimer2 = timer
            } else {
                preconditionFailure("每个测试clock只允许两个有界deadline scheduler")
            }
        }
        return timer
    }

    fileprivate func configure(_ timer: ManualPlaybackDeadlineTimer,
        handler: (@Sendable () -> Void)? = nil, notAfterInstant: UInt64?? = nil,
        activate: Bool = false, cancel: Bool = false) {
        let (d1, d2) = lock.withLock { () -> (ManualPlaybackDeadlineTimer.Delivery?, ManualPlaybackDeadlineTimer.Delivery?) in
            guard (deadlineTimer1 === timer || deadlineTimer2 === timer), !timer.cancelled else { return (nil, nil) }
            if let handler {
                timer.handler = handler
                handlerInstallationCount += 1
            }
            if let notAfterInstant { timer.notAfterInstant = notAfterInstant }
            if activate { timer.active = true }
            if cancel {
                timer.cancelled = true
                timer.notAfterInstant = nil
                return (nil, nil)
            }
            return prepareDeliveriesLocked(force: false)
        }
        d1?.enqueue()
        d2?.enqueue()
    }

    private func prepareDeliveriesLocked(force: Bool) -> (ManualPlaybackDeadlineTimer.Delivery?, ManualPlaybackDeadlineTimer.Delivery?) {
        var d1: ManualPlaybackDeadlineTimer.Delivery?
        var d2: ManualPlaybackDeadlineTimer.Delivery?
        
        if let timer = deadlineTimer1, timer.active, !timer.cancelled,
           let deadline = timer.notAfterInstant, force || deadline <= instant,
           let handler = timer.handler {
            timer.notAfterInstant = nil
            timerDeliveryCount += 1
            d1 = .init(queue: timer.deliveryQueue, handler: handler)
        }
        
        if let timer = deadlineTimer2, timer.active, !timer.cancelled,
           let deadline = timer.notAfterInstant, force || deadline <= instant,
           let handler = timer.handler {
            timer.notAfterInstant = nil
            timerDeliveryCount += 1
            d2 = .init(queue: timer.deliveryQueue, handler: handler)
        }
        
        return (d1, d2)
    }
}

private final class ManualPlaybackDeadlineTimer: PlaybackDeadlineTimer, @unchecked Sendable {
    struct Delivery: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: @Sendable () -> Void
        func enqueue() { queue.async(execute: handler) }
    }

    private let clock: ManualPlaybackClock
    fileprivate let deliveryQueue: DispatchQueue
    fileprivate var handler: (@Sendable () -> Void)?
    fileprivate var notAfterInstant: UInt64?
    fileprivate var active = false
    fileprivate var cancelled = false

    init(clock: ManualPlaybackClock, deliveryQueue: DispatchQueue) {
        self.clock = clock
        self.deliveryQueue = deliveryQueue
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        clock.configure(self, handler: handler)
    }

    func schedule(notAfterInstant: UInt64?) {
        clock.configure(self, notAfterInstant: .some(notAfterInstant))
    }

    func activate() { clock.configure(self, activate: true) }
    func cancel() { clock.configure(self, cancel: true) }
}
