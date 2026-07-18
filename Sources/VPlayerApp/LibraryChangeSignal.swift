// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation

@MainActor
@Observable
final class LibraryChangeSignal {
    private(set) var generation = 0

    @ObservationIgnored
    private var continuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    func notify() {
        generation &+= 1
        for continuation in continuations.values {
            continuation.yield(generation)
        }
    }

    func changes(after observedGeneration: Int) -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuations[id] = nil
            }
        }
        if generation != observedGeneration {
            continuation.yield(generation)
        }
        return stream
    }
}
