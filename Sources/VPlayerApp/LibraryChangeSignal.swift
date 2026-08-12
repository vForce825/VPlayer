// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation
import VPlayerCore

@MainActor
@Observable
final class LibraryChangeSignal {
    private typealias RefreshStartObserver = (UUID, RefreshResource) -> Bool

    private(set) var generation = 0

    @ObservationIgnored
    private var continuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    @ObservationIgnored
    private var refreshStartObservers: [UUID: RefreshStartObserver] = [:]

    func notify() {
        generation &+= 1
        for continuation in continuations.values {
            continuation.yield(generation)
        }
    }

    func notifyRefreshStarted(profileID: UUID, resource: RefreshResource) {
        let staleObserverIDs = refreshStartObservers.compactMap { id, observer in
            observer(profileID, resource) ? nil : id
        }
        for id in staleObserverIDs {
            refreshStartObservers[id] = nil
        }
    }

    /// Returning false unregisters an observer whose weakly held owner is gone.
    func observeRefreshStarts(
        _ observer: @escaping (UUID, RefreshResource) -> Bool
    ) {
        refreshStartObservers[UUID()] = observer
    }

    func changes(after observedGeneration: Int) -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
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
