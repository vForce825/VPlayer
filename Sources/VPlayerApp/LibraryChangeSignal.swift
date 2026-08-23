// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation
import VPlayerCore

@MainActor
@Observable
final class LibraryChangeSignal {
    enum ReloadScope: Equatable, Sendable {
        case full
        case refreshes([UUID: Set<RefreshResource>])
    }

    struct RefreshCompletionClaim: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct RefreshKey: Hashable {
        let profileID: UUID
        let resource: RefreshResource
    }

    private struct RefreshCompletionClaimState {
        let profileID: UUID
        let resources: Set<RefreshResource>
        var pendingResources: Set<RefreshResource> = []
    }

    private typealias RefreshStartObserver = (UUID, RefreshResource) -> Bool

    private(set) var generation = 0

    @ObservationIgnored
    private var continuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    @ObservationIgnored
    private var refreshStartObservers: [UUID: RefreshStartObserver] = [:]

    @ObservationIgnored
    private var latestFullReloadGeneration = 0

    @ObservationIgnored
    private var latestRefreshGeneration: [UUID: [RefreshResource: Int]] = [:]

    @ObservationIgnored
    private var refreshCompletionClaims: [UUID: RefreshCompletionClaimState] = [:]

    @ObservationIgnored
    private var refreshCompletionClaimByKey: [RefreshKey: UUID] = [:]

    func notify() {
        generation &+= 1
        latestFullReloadGeneration = generation
        yieldGeneration()
    }

    func notify(profileID: UUID, resource: RefreshResource) {
        let key = RefreshKey(profileID: profileID, resource: resource)
        if let claimID = refreshCompletionClaimByKey[key],
           var claim = refreshCompletionClaims[claimID] {
            claim.pendingResources.insert(resource)
            refreshCompletionClaims[claimID] = claim
            return
        }
        recordRefreshChanges(profileID: profileID, resources: [resource])
    }

    func claimPersistedRefreshes(
        profileID: UUID,
        resources: Set<RefreshResource>
    ) -> RefreshCompletionClaim {
        let claim = RefreshCompletionClaim(id: UUID())
        refreshCompletionClaims[claim.id] = RefreshCompletionClaimState(
            profileID: profileID,
            resources: resources
        )
        for resource in resources {
            refreshCompletionClaimByKey[RefreshKey(
                profileID: profileID,
                resource: resource
            )] = claim.id
        }
        return claim
    }

    func releasePersistedRefreshes(
        _ claim: RefreshCompletionClaim,
        publishesPendingChanges: Bool
    ) {
        stopClaimingPersistedRefreshes(claim)
        guard let state = refreshCompletionClaims.removeValue(forKey: claim.id) else { return }
        publishPendingRefreshChanges(from: state, ifRequested: publishesPendingChanges)
    }

    /// Stops intercepting new terminal callbacks while retaining callbacks
    /// already captured by the claim. The owner can now reload a stable
    /// boundary and later either discard or republish the captured changes.
    func stopClaimingPersistedRefreshes(_ claim: RefreshCompletionClaim) {
        guard let state = refreshCompletionClaims[claim.id] else { return }
        for resource in state.resources {
            let key = RefreshKey(profileID: state.profileID, resource: resource)
            if refreshCompletionClaimByKey[key] == claim.id {
                refreshCompletionClaimByKey[key] = nil
            }
        }
    }

    private func publishPendingRefreshChanges(
        from state: RefreshCompletionClaimState,
        ifRequested publishesPendingChanges: Bool
    ) {
        guard publishesPendingChanges, !state.pendingResources.isEmpty else { return }

        var unclaimedResources: Set<RefreshResource> = []
        for resource in state.pendingResources {
            let key = RefreshKey(profileID: state.profileID, resource: resource)
            if let nextClaimID = refreshCompletionClaimByKey[key],
               var nextClaim = refreshCompletionClaims[nextClaimID] {
                nextClaim.pendingResources.insert(resource)
                refreshCompletionClaims[nextClaimID] = nextClaim
            } else {
                unclaimedResources.insert(resource)
            }
        }
        if !unclaimedResources.isEmpty {
            recordRefreshChanges(
                profileID: state.profileID,
                resources: unclaimedResources
            )
        }
    }

    private func recordRefreshChanges(
        profileID: UUID,
        resources: Set<RefreshResource>
    ) {
        guard !resources.isEmpty else { return }
        generation &+= 1
        for resource in resources {
            latestRefreshGeneration[profileID, default: [:]][resource] = generation
        }
        yieldGeneration()
    }

    func reloadScope(after observedGeneration: Int) -> ReloadScope {
        guard latestFullReloadGeneration <= observedGeneration else {
            return .full
        }
        var resourcesByProfile: [UUID: Set<RefreshResource>] = [:]
        for (profileID, resourceGenerations) in latestRefreshGeneration {
            for (resource, resourceGeneration) in resourceGenerations
            where resourceGeneration > observedGeneration {
                resourcesByProfile[profileID, default: []].insert(resource)
            }
        }
        return .refreshes(resourcesByProfile)
    }

    private func yieldGeneration() {
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
