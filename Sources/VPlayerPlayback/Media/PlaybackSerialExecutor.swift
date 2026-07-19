// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Dispatch

public final class PlaybackSerialExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    public init(label: String = "org.vplayer.playback.media") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: key, value: 1)
    }

    public func submit(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    public var isIsolated: Bool {
        DispatchQueue.getSpecific(key: key) == 1
    }
}
