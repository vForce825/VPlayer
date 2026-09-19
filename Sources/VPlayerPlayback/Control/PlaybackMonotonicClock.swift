// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Darwin
import ObjectiveC

/// 计时器只接受其所属clock域内的绝对时刻；nil表示撤销当前排期但保留timer实例。
protocol PlaybackDeadlineTimer: AnyObject, Sendable {
    func setEventHandler(_ handler: @escaping @Sendable () -> Void)
    func schedule(notAfterInstant: UInt64?)
    func activate()
    func cancel()
}

/// 读时钟与创建timer必须由同一对象实现，禁止把测试原点误当作Dispatch uptime。
protocol PlaybackMonotonicClock: AnyObject, Sendable {
    var nowNanoseconds: UInt64 { get }
    func makeDeadlineTimer(deliveryQueue: DispatchQueue) -> any PlaybackDeadlineTimer
}

final class DispatchPlaybackMonotonicClock: PlaybackMonotonicClock, @unchecked Sendable {
    static var deadlineTimerObjectAllocationBytes: Int {
        malloc_good_size(class_getInstanceSize(DispatchPlaybackDeadlineTimer.self))
    }
    /// 实际clock与唯一timer wrapper本体，Dispatch source由Registry同一reservation另计。
    static var fixedObjectAllocationBytes: Int {
        malloc_good_size(class_getInstanceSize(DispatchPlaybackMonotonicClock.self)) +
            deadlineTimerObjectAllocationBytes
    }
    static var deadlineTimerAdapterFixedValueBytes: Int {
        DispatchPlaybackDeadlineTimer.fixedValueStorageBytes
    }

    var nowNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }

    func makeDeadlineTimer(deliveryQueue: DispatchQueue) -> any PlaybackDeadlineTimer {
        DispatchPlaybackDeadlineTimer(deliveryQueue: deliveryQueue)
    }
}

private final class DispatchPlaybackDeadlineTimer: PlaybackDeadlineTimer, @unchecked Sendable {
    /// wrapper本身仅常驻一份source引用；handler保存在source，不重复缓存。
    static var fixedValueStorageBytes: Int { MemoryLayout<any DispatchSourceTimer>.stride }

    private let source: any DispatchSourceTimer

    init(deliveryQueue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: deliveryQueue)
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func schedule(notAfterInstant: UInt64?) {
        guard let notAfterInstant else {
            source.schedule(deadline: .distantFuture)
            return
        }
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: notAfterInstant),
            leeway: .nanoseconds(0))
    }

    func activate() { source.activate() }
    func cancel() { source.cancel() }
}
