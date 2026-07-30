// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch
import Foundation

public final class PlaybackSerialExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()
    private let busyLock = NSLock()
    private var busyNanosecondsTotal: UInt64 = 0

    public init(label: String = "org.vplayer.playback.media") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: key, value: 1)
    }

    public func submit(_ operation: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            measure(operation)
        }
    }

    func submit(
        after delay: DispatchTimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            measure(operation)
        }
    }

    private func measure(_ operation: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        busyLock.withLock { busyNanosecondsTotal &+= elapsed }
    }

    /// Wall time spent running work items. Against elapsed time this says whether
    /// a caller waiting on this executor is waiting because the executor is
    /// genuinely saturated, or only because it is queued behind a handful of
    /// items — which decides whether the fix is less work or less coupling.
    public var busyNanoseconds: UInt64 {
        busyLock.withLock { busyNanosecondsTotal }
    }

    public var isIsolated: Bool {
        DispatchQueue.getSpecific(key: key) == 1
    }
}
