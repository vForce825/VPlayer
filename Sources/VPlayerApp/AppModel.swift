// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation
import VPlayerCore
import VPlayerPlayback

@MainActor
@Observable
final class AppModel {
    typealias Refresh = @Sendable (
        UUID,
        Set<RefreshResource>,
        RefreshTrigger
    ) async -> [RefreshOutcome]

    struct ProcessedLibraryChange: Equatable, Sendable {
        let generation: Int
        let reloadApplied: Bool
    }

    private struct EPGMatchingSnapshot: Sendable {
        let matches: [String: EPGMatchResult]
        let scopedManualMappings: [String: String]
        let matchedXMLTVChannelIDs: Set<String>
    }

    enum ActiveMutationLaneEvent: Equatable, Sendable {
        enum Operation: Equatable, Sendable {
            case activate(UUID)
            case delete(UUID)
        }

        case acquired(Operation)
        case queued(Operation)
        case cancelled(Operation)
        case released(Operation)
        case reloadWaiting
    }

    typealias LibraryChangeProcessed = @Sendable (ProcessedLibraryChange) -> Void

    var profiles: [SourceProfile] = []
    var activeProfile: SourceProfile?
    var channels: [Channel] = []
    var epgChannels: [EPGChannel] = []
    var epgProgrammeCount = 0
    /// Set only when the stored EPG holds programmes that all ended before the
    /// reload, so screens can say so instead of showing empty schedules.
    var staleEPGCoverageEnd: Date?
    var programmesByChannelID: [String: [Programme]] = [:]
    var presentedPlaybackRequest: PlaybackRequest?
    var alertMessage: String?
    var isLoading = false

    var alertTitle: String {
        alertKind == .playback ? "无法播放" : "操作失败"
    }

    private let repository: any LibraryRepository
    private let refreshResources: Refresh
    private let now: @Sendable () -> Date
    private var matchByChannelID: [String: EPGMatchResult] = [:]
    private var manualMappingByChannelID: [String: String] = [:]
    private var reloadID: UUID?
    private var activeTransition: ActiveTransition?
    private var pendingCreation: PendingCreation?
    private var activeCreationAttemptIDs: Set<UUID> = []
    private var cancelledCreationAttemptIDs: Set<UUID> = []
    private var terminalRefreshOverlays: [RefreshKey: TerminalRefreshOverlay] = [:]
    private var manualRefreshAttempts: [RefreshKey: ManualRefreshAttempt] = [:]
    @ObservationIgnored private var activeReloadIDs: Set<UUID> = []
    /// Distinguishes a successfully loaded, legitimately empty library from the
    /// default empty presentation state left behind by a failed first read.
    @ObservationIgnored private var hasAppliedLibrarySnapshot = false
    @ObservationIgnored private var reloadCompletionWaiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]
    @ObservationIgnored private let mutationLaneEvent: (@MainActor @Sendable (
        ActiveMutationLaneEvent
    ) -> Void)?
    @ObservationIgnored private var activeMutationLease: ActiveMutationLease?
    @ObservationIgnored private var queuedActiveMutations: [ActiveMutationWaiter] = []
    @ObservationIgnored private var mutationLaneIdleWaiters: [MutationLaneIdleWaiter] = []
    @ObservationIgnored private var refreshReconciliationTasks: [
        RefreshKey: RefreshReconciliationTask
    ] = [:]
    @ObservationIgnored private var automaticRefreshTasks: [
        RefreshKey: AutomaticRefreshTask
    ] = [:]
    @ObservationIgnored private var libraryChangeTask: Task<Void, Never>?
    @ObservationIgnored private var alertKind = AlertKind.operation

    init(
        repository: any LibraryRepository,
        refresh: @escaping Refresh,
        libraryChanges: LibraryChangeSignal? = nil,
        libraryChangeProcessed: LibraryChangeProcessed? = nil,
        mutationLaneEvent: (@MainActor @Sendable (ActiveMutationLaneEvent) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.refreshResources = refresh
        self.mutationLaneEvent = mutationLaneEvent
        self.now = now
        if let libraryChanges {
            let observedGeneration = libraryChanges.generation
            libraryChangeTask = Task { @MainActor [weak self, weak libraryChanges] in
                guard let libraryChanges else { return }
                for await generation in libraryChanges.changes(after: observedGeneration) {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    let reloadApplied = await self.reload()
                    libraryChangeProcessed?(ProcessedLibraryChange(
                        generation: generation,
                        reloadApplied: reloadApplied
                    ))
                }
            }
        }
    }

    deinit {
        libraryChangeTask?.cancel()
        for reconciliation in refreshReconciliationTasks.values {
            reconciliation.task.cancel()
        }
        for automaticRefresh in automaticRefreshTasks.values {
            automaticRefresh.task.cancel()
        }
    }

    @discardableResult
    func reload() async -> Bool {
        while true {
            guard await waitForActiveMutationLaneIdle() else { return false }
            guard activeMutationLease == nil, queuedActiveMutations.isEmpty else { continue }
            return await reloadOutcome() == .applied
        }
    }

    private func reloadOutcome() async -> ReloadOutcome {
        let currentReloadID = UUID()
        activeReloadIDs.insert(currentReloadID)
        defer { completeReload(currentReloadID) }
        let terminalRefreshOverlayIDsAtStart = terminalRefreshOverlays.mapValues(\.id)
        activeTransition = nil
        reloadID = currentReloadID
        // A background M3U/EPG refresh can hold the repository actor while it
        // installs a large snapshot. Keep a previously loaded channel library
        // visible and selectable until the replacement is complete; only the
        // first load needs to mask the empty UI with a spinner.
        isLoading = activeProfile == nil || channels.isEmpty

        do {
            let loadedProfiles = try await repository.profiles()
            try Task.checkCancellation()
            let loadedActiveProfile = try await repository.activeProfile()
            try Task.checkCancellation()

            guard let loadedActiveProfile else {
                return apply(
                    reloadID: currentReloadID,
                    profiles: loadedProfiles,
                    activeProfile: nil,
                    channels: [],
                    epgChannels: [],
                    epgProgrammeCount: 0,
                    epgCoverageEnd: nil,
                    matches: [:],
                    manualMappings: [:],
                    programmes: [:],
                    terminalRefreshOverlayIDsAtStart: terminalRefreshOverlayIDsAtStart
                )
            }

            async let channelLoad = repository.channels(profileID: loadedActiveProfile.id)
            async let epgChannelLoad = repository.epgChannels(profileID: loadedActiveProfile.id)
            async let epgProgrammeCountLoad = repository.epgProgrammeCount(
                profileID: loadedActiveProfile.id
            )
            async let epgCoverageEndLoad = repository.epgCoverageEnd(
                profileID: loadedActiveProfile.id
            )
            let (
                loadedChannels,
                loadedEPGChannels,
                loadedEPGProgrammeCount,
                loadedEPGCoverageEnd
            ) = try await (
                channelLoad,
                epgChannelLoad,
                epgProgrammeCountLoad,
                epgCoverageEndLoad
            )
            try Task.checkCancellation()

            let windowStart = now().addingTimeInterval(-3_600)
            let windowEnd = windowStart.addingTimeInterval(25 * 3_600)

            let manualMappings = try await repository.manualMappings(
                profileID: loadedActiveProfile.id
            )
            try Task.checkCancellation()

            // Unicode normalization and fuzzy matching are CPU work, not UI
            // work. Build one reusable EPG index and match the whole playlist
            // away from MainActor so focus and remote input stay responsive.
            let matching = try await Self.makeEPGMatchingSnapshot(
                channels: loadedChannels,
                epgChannels: loadedEPGChannels,
                manualMappings: manualMappings
            )
            try Task.checkCancellation()

            let programmesByXMLTVChannelID = try await repository.programmes(
                profileID: loadedActiveProfile.id,
                xmltvChannelIDs: matching.matchedXMLTVChannelIDs,
                overlapping: windowStart..<windowEnd
            )
            try Task.checkCancellation()

            var programmes: [String: [Programme]] = [:]
            for channel in loadedChannels {
                guard let xmltvChannelID = matching.matches[channel.id]?.xmltvChannelID else {
                    continue
                }
                programmes[channel.id] = programmesByXMLTVChannelID[xmltvChannelID] ?? []
            }

            return apply(
                reloadID: currentReloadID,
                profiles: loadedProfiles,
                activeProfile: loadedActiveProfile,
                channels: loadedChannels.sorted { ($0.order, $0.id) < ($1.order, $1.id) },
                epgChannels: loadedEPGChannels,
                epgProgrammeCount: loadedEPGProgrammeCount,
                epgCoverageEnd: loadedEPGCoverageEnd,
                matches: matching.matches,
                manualMappings: matching.scopedManualMappings,
                programmes: programmes,
                terminalRefreshOverlayIDsAtStart: terminalRefreshOverlayIDsAtStart
            )
        } catch is CancellationError {
            guard reloadID == currentReloadID else { return .superseded }
            finishLoading(reloadID: currentReloadID)
            return .failedWhileCurrent
        } catch {
            guard reloadID == currentReloadID else { return .superseded }
            presentOperationMessage("无法读取数据，请稍后重试。")
            finishLoading(reloadID: currentReloadID)
            return .failedWhileCurrent
        }
    }

    private nonisolated static func makeEPGMatchingSnapshot(
        channels: [Channel],
        epgChannels: [EPGChannel],
        manualMappings: [String: String]
    ) async throws -> EPGMatchingSnapshot {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let matches = try EPGMatcher.matches(
                channels: channels,
                epgChannels: epgChannels,
                manualMappingsByChannelID: manualMappings,
                cancellationCheck: { try Task.checkCancellation() }
            )
            try Task.checkCancellation()

            // Scope to the loaded playlist so stale overrides for channels that
            // are no longer present stay out of the presented state.
            var scopedManualMappings: [String: String] = [:]
            scopedManualMappings.reserveCapacity(min(channels.count, manualMappings.count))
            for channel in channels {
                if let xmltvChannelID = manualMappings[channel.id] {
                    scopedManualMappings[channel.id] = xmltvChannelID
                }
            }
            return EPGMatchingSnapshot(
                matches: matches,
                scopedManualMappings: scopedManualMappings,
                matchedXMLTVChannelIDs: Set(matches.values.compactMap(\.xmltvChannelID))
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    @discardableResult
    func create(input: SourceProfileInput, attemptID: UUID) async -> Bool {
        activeCreationAttemptIDs.insert(attemptID)
        defer {
            activeCreationAttemptIDs.remove(attemptID)
            cancelledCreationAttemptIDs.remove(attemptID)
        }
        do {
            let validatedInput = try input.validated()
            let createdProfile: SourceProfile
            if let pendingCreation, pendingCreation.attemptID == attemptID {
                let updatedAt = now()
                try await repository.updateProfile(
                    id: pendingCreation.profile.id,
                    input: validatedInput,
                    now: updatedAt
                )
                createdProfile = Self.updatedProfile(
                    pendingCreation.profile,
                    input: validatedInput,
                    updatedAt: updatedAt
                )
            } else {
                createdProfile = try await repository.createProfile(validatedInput, now: now())
            }
            guard !cancelledCreationAttemptIDs.contains(attemptID) else {
                reconcileCreatedProfile(createdProfile)
                _ = await reload()
                return false
            }
            pendingCreation = PendingCreation(attemptID: attemptID, profile: createdProfile)
            reconcileCreatedProfile(createdProfile)
            guard await reload() else {
                guard !cancelledCreationAttemptIDs.contains(attemptID) else {
                    pendingCreation = nil
                    return false
                }
                reconcileCreatedProfile(createdProfile)
                presentOperationMessage("播放列表已保存，但界面未能重新读取。请重试；再次保存不会重复创建。")
                return false
            }
            guard !cancelledCreationAttemptIDs.contains(attemptID) else {
                pendingCreation = nil
                return false
            }
            guard profiles.contains(where: { $0.id == createdProfile.id }) else {
                pendingCreation = nil
                presentOperationMessage("播放列表已保存，但已无法在资料库中找到。请重新添加。")
                return false
            }
            if pendingCreation?.attemptID == attemptID {
                pendingCreation = nil
            }
            startAutomaticRefresh(
                profileID: createdProfile.id,
                resources: Set(RefreshResource.allCases)
            )
            return true
        } catch {
            presentOperationError(error)
            return false
        }
    }

    func cancelCreateAttempt(_ attemptID: UUID) {
        if activeCreationAttemptIDs.contains(attemptID) {
            cancelledCreationAttemptIDs.insert(attemptID)
        }
        if pendingCreation?.attemptID == attemptID {
            pendingCreation = nil
        }
    }

    @discardableResult
    func update(profileID: UUID, input: SourceProfileInput) async -> Bool {
        do {
            let validatedInput = try input.validated()
            let updatedAt = now()
            let retargetedResources = Self.retargetedResources(
                by: validatedInput,
                comparedTo: profiles.first { $0.id == profileID }
            )
            try await repository.updateProfile(id: profileID, input: validatedInput, now: updatedAt)
            clearPendingCreation(profileID: profileID)
            reconcileUpdatedProfile(id: profileID, input: validatedInput, updatedAt: updatedAt)
            guard await reload() else {
                reconcileUpdatedProfile(id: profileID, input: validatedInput, updatedAt: updatedAt)
                presentOperationMessage("更改已保存，但界面未能重新读取。请稍后重试。")
                return false
            }
            startAutomaticRefresh(profileID: profileID, resources: retargetedResources)
            return true
        } catch {
            presentOperationError(error)
            return false
        }
    }

    @discardableResult
    func delete(profileID: UUID) async -> Bool {
        guard let mutationLease = await acquireActiveMutationLease(
            for: .delete(profileID)
        ) else {
            return false
        }
        defer { releaseActiveMutationLease(mutationLease) }
        await waitForWinningReloadCompletion()
        guard !Task.isCancelled else {
            mutationLaneEvent?(.cancelled(mutationLease.operation))
            return false
        }
        clearOperationAlert()
        let deletedActiveProfile = activeProfile?.id == profileID
        let activeTransition = deletedActiveProfile ? beginActiveTransition(to: nil) : nil
        do {
            try await repository.deleteProfile(id: profileID)
            clearPendingCreation(profileID: profileID)
            profiles.removeAll { $0.id == profileID }
            if deletedActiveProfile {
                clearActiveBoundState()
            }
            switch await postWriteReloadOutcome() {
            case .applied:
                return true
            case .failedWhileCurrent:
                profiles.removeAll { $0.id == profileID }
                if deletedActiveProfile {
                    clearActiveBoundState()
                }
                presentOperationMessage("播放列表已删除，但界面未能重新读取。请稍后重试。")
                return false
            case .superseded:
                return false
            }
        } catch is CancellationError {
            if let activeTransition {
                guard restoreActiveBoundState(ifOwnedBy: activeTransition) else {
                    return false
                }
            }
            return false
        } catch {
            if let activeTransition {
                guard restoreActiveBoundState(ifOwnedBy: activeTransition) else {
                    return false
                }
            }
            presentOperationError(error)
            return false
        }
    }

    @discardableResult
    func activate(profileID: UUID) async -> Bool {
        guard let mutationLease = await acquireActiveMutationLease(
            for: .activate(profileID)
        ) else {
            return false
        }
        defer { releaseActiveMutationLease(mutationLease) }
        await waitForWinningReloadCompletion()
        guard !Task.isCancelled else {
            mutationLaneEvent?(.cancelled(mutationLease.operation))
            return false
        }
        clearOperationAlert()
        let activeTransition = beginActiveTransition(
            to: profiles.first { $0.id == profileID }
        )
        do {
            try await repository.setActiveProfile(id: profileID)
            switch await postWriteReloadOutcome() {
            case .applied:
                return true
            case .failedWhileCurrent:
                activeProfile = profiles.first { $0.id == profileID }
                clearChannelState()
                presentOperationMessage("当前播放列表已切换，但频道未能重新读取。请稍后重试。")
                return false
            case .superseded:
                return false
            }
        } catch is CancellationError {
            guard restoreActiveBoundState(ifOwnedBy: activeTransition) else {
                return false
            }
            return false
        } catch {
            guard restoreActiveBoundState(ifOwnedBy: activeTransition) else {
                return false
            }
            presentOperationError(error)
            return false
        }
    }

    func refresh(profileID: UUID, resource: RefreshResource) async {
        let key = RefreshKey(profileID: profileID, resource: resource)
        let attempt = ManualRefreshAttempt(
            id: UUID(),
            startedAt: now()
        )
        manualRefreshAttempts[key] = attempt
        markRefreshing(
            profileID: profileID,
            resource: resource,
            startedAt: attempt.startedAt
        )
        let outcomes = await refreshResources(profileID, [resource], .manual)
        guard manualRefreshAttempts[key]?.id == attempt.id else { return }
        let outcome = outcomes.first { $0.resource == resource } ?? RefreshOutcome(
            resource: resource,
            succeeded: false,
            message: "刷新未完成，请稍后重试。"
        )
        let completedAt = now()
        reconcileRefreshOutcome(
            profileID: profileID,
            resource: resource,
            outcome: outcome,
            completedAt: completedAt
        )
        terminalRefreshOverlays[key] = TerminalRefreshOverlay(
            id: UUID(),
            startedAt: attempt.startedAt,
            expectedAttemptID: outcome.attemptID,
            outcome: outcome,
            completedAt: completedAt
        )
        let overlayID = terminalRefreshOverlays[key]?.id
        manualRefreshAttempts[key] = nil
        let reconciliationTask: Task<Void, Never>?
        if let overlayID, outcome.attemptID != nil || !Task.isCancelled {
            reconciliationTask = scheduleRefreshReconciliation(key: key, overlayID: overlayID)
        } else {
            reconciliationTask = nil
        }
        guard !Task.isCancelled else { return }
        await reconciliationTask?.value
    }

    /// Fetches resources the user has just pointed somewhere new. A freshly
    /// saved playlist has no channels and no programmes yet, and the schedulers
    /// cannot close that gap: the foreground driver only sweeps once a minute,
    /// and a resource set to 仅手动 is never due at all.
    private func startAutomaticRefresh(profileID: UUID, resources: Set<RefreshResource>) {
        for resource in RefreshResource.allCases where resources.contains(resource) {
            let key = RefreshKey(profileID: profileID, resource: resource)
            let automaticRefreshID = UUID()
            cancelAutomaticRefresh(for: key)
            automaticRefreshTasks[key] = AutomaticRefreshTask(
                id: automaticRefreshID,
                task: Task { @MainActor [weak self] in
                    await self?.refresh(profileID: profileID, resource: resource)
                    self?.finishAutomaticRefresh(key: key, id: automaticRefreshID)
                }
            )
        }
    }

    private func cancelAutomaticRefresh(for key: RefreshKey) {
        automaticRefreshTasks.removeValue(forKey: key)?.task.cancel()
    }

    private func finishAutomaticRefresh(key: RefreshKey, id: UUID) {
        guard automaticRefreshTasks[key]?.id == id else { return }
        automaticRefreshTasks[key] = nil
    }

    /// The resources whose remote address changed, so their imported content no
    /// longer describes what the profile points at.
    private static func retargetedResources(
        by input: ValidatedSourceProfileInput,
        comparedTo profile: SourceProfile?
    ) -> Set<RefreshResource> {
        guard let profile else { return [] }
        var resources: Set<RefreshResource> = []
        if profile.m3uURL != input.m3uURL {
            resources.insert(.playlist)
        }
        if profile.epgURL != input.epgURL {
            resources.insert(.epg)
        }
        return resources
    }

    @discardableResult
    func saveMapping(channel: Channel, xmltvChannelID: String?) async -> Bool {
        guard isCurrentMappingTarget(channel) else {
            await rejectStaleMappingTarget()
            return false
        }
        do {
            let persisted = try await repository.setManualMappingIfCurrentChannel(
                profileID: channel.sourceProfileID,
                channelID: channel.id,
                xmltvChannelID: xmltvChannelID
            )
            guard persisted else {
                await rejectStaleMappingTarget()
                return false
            }
            guard await reload() else {
                presentOperationMessage("映射已保存，但界面未能重新读取。请稍后重试。")
                return false
            }
            return true
        } catch {
            presentOperationError(error)
            _ = await reload()
            presentOperationMessage("无法保存映射，请刷新频道后重试。")
            return false
        }
    }

    func select(channel: Channel) {
        guard !isLoading,
              let activeProfile,
              channel.sourceProfileID == activeProfile.id,
              let currentChannel = channels.first(where: {
                  $0.id == channel.id && $0.sourceProfileID == activeProfile.id
              }) else {
            presentedPlaybackRequest = nil
            return
        }
        switch StreamProtocolPolicy.evaluate(currentChannel.streamURL) {
        case .allowed:
            alertMessage = nil
            presentedPlaybackRequest = PlaybackRequest(
                sourceProfileID: currentChannel.sourceProfileID,
                channelID: currentChannel.id,
                streamURL: currentChannel.streamURL,
                title: currentChannel.displayName
            )
        case let .rejected(rejection):
            presentedPlaybackRequest = nil
            alertKind = .playback
            alertMessage = rejection.userMessage
        }
    }

    func matchedEPGChannelID(for channel: Channel) -> String? {
        matchByChannelID[channel.id]?.xmltvChannelID
    }

    func manualEPGChannelID(for channel: Channel) -> String? {
        manualMappingByChannelID[channel.id]
    }

    func dismissAlert() {
        alertMessage = nil
    }

    func dismissPlayback() {
        presentedPlaybackRequest = nil
    }

    /// Waits for the reload that currently owns presentation state, including
    /// a newer reload that superseded the caller's request. Startup uses this
    /// before allowing foreground refreshes to begin.
    @discardableResult
    func waitForLibraryReloadsToSettle() async -> Bool {
        await waitForWinningReloadCompletion()
        return hasAppliedLibrarySnapshot
    }

    private func apply(
        reloadID currentReloadID: UUID,
        profiles: [SourceProfile],
        activeProfile: SourceProfile?,
        channels: [Channel],
        epgChannels: [EPGChannel],
        epgProgrammeCount: Int,
        epgCoverageEnd: Date?,
        matches: [String: EPGMatchResult],
        manualMappings: [String: String],
        programmes: [String: [Programme]],
        terminalRefreshOverlayIDsAtStart: [RefreshKey: UUID]
    ) -> ReloadOutcome {
        guard reloadID == currentReloadID else { return .superseded }
        var profiles = profiles
        invalidateManualRefreshAttempts(missingFrom: profiles)
        reconcileActiveManualRefreshAttempts(in: &profiles)
        reconcileTerminalRefreshOverlays(
            in: &profiles,
            presentAtReloadStart: terminalRefreshOverlayIDsAtStart
        )
        self.profiles = profiles
        if let activeProfile,
           let reconciledActiveProfile = profiles.first(where: { $0.id == activeProfile.id }) {
            self.activeProfile = reconciledActiveProfile
        } else {
            self.activeProfile = activeProfile
        }
        self.channels = channels
        self.epgChannels = epgChannels
        self.epgProgrammeCount = epgProgrammeCount
        self.staleEPGCoverageEnd = EPGCoverageNotice.staleCoverageEnd(
            coverageEnd: epgCoverageEnd,
            programmeCount: epgProgrammeCount,
            now: now()
        )
        self.matchByChannelID = matches
        self.manualMappingByChannelID = manualMappings
        self.programmesByChannelID = programmes
        hasAppliedLibrarySnapshot = true
        let loadedPlaybackStillMatches = presentedPlaybackRequest.map { request in
            self.activeProfile?.id == request.sourceProfileID
                && channels.contains(where: {
                    $0.id == request.channelID
                        && $0.sourceProfileID == request.sourceProfileID
                        && $0.streamURL == request.streamURL
                        && $0.displayName == request.title
                })
        } ?? false
        if !loadedPlaybackStillMatches {
            presentedPlaybackRequest = nil
        }
        if let pendingCreation,
           !profiles.contains(where: { $0.id == pendingCreation.profile.id }) {
            self.pendingCreation = nil
        }
        finishLoading(reloadID: currentReloadID)
        return .applied
    }

    private func finishLoading(reloadID currentReloadID: UUID) {
        guard reloadID == currentReloadID else { return }
        isLoading = false
    }

    private func markRefreshing(
        profileID: UUID,
        resource: RefreshResource,
        startedAt: Date
    ) {
        let key = RefreshKey(profileID: profileID, resource: resource)
        cancelRefreshReconciliation(for: key)
        terminalRefreshOverlays[key] = nil
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        switch resource {
        case .playlist:
            profiles[index].m3uStatus.lastAttemptAt = startedAt
            profiles[index].m3uStatus.state = .refreshing
            profiles[index].m3uStatus.errorSummary = nil
            profiles[index].m3uStatus.attemptID = nil
        case .epg:
            profiles[index].epgStatus.lastAttemptAt = startedAt
            profiles[index].epgStatus.state = .refreshing
            profiles[index].epgStatus.errorSummary = nil
            profiles[index].epgStatus.attemptID = nil
        }
        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

    private func presentOperationError(_ error: any Error) {
        presentOperationMessage(
            SourceProfileValidationMessage.text(for: error) ?? "操作失败，请稍后重试。"
        )
    }

    private func beginActiveTransition(to profile: SourceProfile?) -> ActiveTransition {
        let previousState: ActiveBoundStateSnapshot
        if let activeTransition,
           reloadID == activeTransition.id {
            previousState = activeTransition.previousState
        } else {
            previousState = captureActiveBoundState()
        }
        let transition = ActiveTransition(
            id: UUID(),
            previousState: previousState
        )
        activeTransition = transition
        reloadID = transition.id
        isLoading = true
        activeProfile = profile
        clearChannelState()
        return transition
    }

    private func captureActiveBoundState() -> ActiveBoundStateSnapshot {
        ActiveBoundStateSnapshot(
            activeProfile: activeProfile,
            channels: channels,
            epgChannels: epgChannels,
            epgProgrammeCount: epgProgrammeCount,
            staleEPGCoverageEnd: staleEPGCoverageEnd,
            matchByChannelID: matchByChannelID,
            manualMappingByChannelID: manualMappingByChannelID,
            programmesByChannelID: programmesByChannelID,
            presentedPlaybackRequest: presentedPlaybackRequest
        )
    }

    private func ownsActiveTransition(_ transition: ActiveTransition) -> Bool {
        reloadID == transition.id && activeTransition?.id == transition.id
    }

    @discardableResult
    private func restoreActiveBoundState(ifOwnedBy transition: ActiveTransition) -> Bool {
        guard ownsActiveTransition(transition) else { return false }
        activeProfile = transition.previousState.activeProfile
        channels = transition.previousState.channels
        epgChannels = transition.previousState.epgChannels
        epgProgrammeCount = transition.previousState.epgProgrammeCount
        staleEPGCoverageEnd = transition.previousState.staleEPGCoverageEnd
        matchByChannelID = transition.previousState.matchByChannelID
        manualMappingByChannelID = transition.previousState.manualMappingByChannelID
        programmesByChannelID = transition.previousState.programmesByChannelID
        presentedPlaybackRequest = transition.previousState.presentedPlaybackRequest
        isLoading = false
        activeTransition = nil
        return true
    }

    private func clearActiveBoundState(preservingPlayback: Bool = false) {
        activeProfile = nil
        clearChannelState(preservingPlayback: preservingPlayback)
    }

    private func clearChannelState(preservingPlayback: Bool = false) {
        channels = []
        epgChannels = []
        epgProgrammeCount = 0
        staleEPGCoverageEnd = nil
        matchByChannelID = [:]
        manualMappingByChannelID = [:]
        programmesByChannelID = [:]
        if !preservingPlayback {
            presentedPlaybackRequest = nil
        }
    }

    private func reconcileCreatedProfile(_ profile: SourceProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    private func clearPendingCreation(profileID: UUID) {
        guard pendingCreation?.profile.id == profileID else { return }
        pendingCreation = nil
    }

    private static func updatedProfile(
        _ profile: SourceProfile,
        input: ValidatedSourceProfileInput,
        updatedAt: Date
    ) -> SourceProfile {
        var profile = profile
        profile.name = input.name
        profile.m3uURL = input.m3uURL
        profile.epgURL = input.epgURL
        profile.m3uRefreshInterval = input.m3uRefreshInterval
        profile.epgRefreshInterval = input.epgRefreshInterval
        profile.updatedAt = updatedAt
        return profile
    }

    private func reconcileUpdatedProfile(
        id: UUID,
        input: ValidatedSourceProfileInput,
        updatedAt: Date
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = input.name
        profiles[index].m3uURL = input.m3uURL
        profiles[index].epgURL = input.epgURL
        profiles[index].m3uRefreshInterval = input.m3uRefreshInterval
        profiles[index].epgRefreshInterval = input.epgRefreshInterval
        profiles[index].updatedAt = updatedAt
        if activeProfile?.id == id {
            activeProfile = profiles[index]
        }
    }

    private func reconcileRefreshOutcome(
        profileID: UUID,
        resource: RefreshResource,
        outcome: RefreshOutcome,
        completedAt: Date
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        switch resource {
        case .playlist:
            Self.applyRefreshOutcome(
                outcome,
                completedAt: completedAt,
                to: &profiles[index].m3uStatus
            )
        case .epg:
            Self.applyRefreshOutcome(
                outcome,
                completedAt: completedAt,
                to: &profiles[index].epgStatus
            )
        }
        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

    private func reconcileActiveManualRefreshAttempts(in profiles: inout [SourceProfile]) {
        for (key, attempt) in manualRefreshAttempts {
            guard let index = profiles.firstIndex(where: { $0.id == key.profileID }) else {
                continue
            }
            switch key.resource {
            case .playlist:
                profiles[index].m3uStatus.lastAttemptAt = attempt.startedAt
                profiles[index].m3uStatus.state = .refreshing
                profiles[index].m3uStatus.errorSummary = nil
                profiles[index].m3uStatus.attemptID = nil
            case .epg:
                profiles[index].epgStatus.lastAttemptAt = attempt.startedAt
                profiles[index].epgStatus.state = .refreshing
                profiles[index].epgStatus.errorSummary = nil
                profiles[index].epgStatus.attemptID = nil
            }
        }
    }

    private func reconcileTerminalRefreshOverlays(
        in profiles: inout [SourceProfile],
        presentAtReloadStart overlayIDsAtReloadStart: [RefreshKey: UUID]
    ) {
        for key in Array(terminalRefreshOverlays.keys) {
            guard let overlay = terminalRefreshOverlays[key],
                  let index = profiles.firstIndex(where: { $0.id == key.profileID }) else {
                terminalRefreshOverlays[key] = nil
                continue
            }
            let persistedStatus = switch key.resource {
            case .playlist: profiles[index].m3uStatus
            case .epg: profiles[index].epgStatus
            }
            if overlayIDsAtReloadStart[key] == overlay.id,
               Self.persistedStatusSupersedesTerminalOverlay(
                   persistedStatus,
                   expectedAttemptID: overlay.expectedAttemptID,
                   orFreshSince: overlay.startedAt
               ) {
                terminalRefreshOverlays[key] = nil
                continue
            }
            switch key.resource {
            case .playlist:
                profiles[index].m3uStatus.lastAttemptAt = overlay.startedAt
                Self.applyRefreshOutcome(
                    overlay.outcome,
                    completedAt: overlay.completedAt,
                    to: &profiles[index].m3uStatus
                )
            case .epg:
                profiles[index].epgStatus.lastAttemptAt = overlay.startedAt
                Self.applyRefreshOutcome(
                    overlay.outcome,
                    completedAt: overlay.completedAt,
                    to: &profiles[index].epgStatus
                )
            }
        }
    }

    private static func persistedStatusSupersedesTerminalOverlay(
        _ status: ResourceRefreshStatus,
        expectedAttemptID: UUID?,
        orFreshSince startedAt: Date
    ) -> Bool {
        if let persistedAttemptID = status.attemptID {
            if let expectedAttemptID, persistedAttemptID == expectedAttemptID {
                return status.state == .succeeded || status.state == .failed
            }
            return status.lastAttemptAt.map { $0 > startedAt } ?? false
        }
        guard status.state == .succeeded || status.state == .failed else { return false }
        return switch status.state {
        case .succeeded:
            status.lastSuccessAt.map { $0 >= startedAt } ?? false
        case .failed:
            status.lastAttemptAt.map { $0 >= startedAt } ?? false
        case .never, .refreshing:
            false
        }
    }

    private static func applyRefreshOutcome(
        _ outcome: RefreshOutcome,
        completedAt: Date,
        to status: inout ResourceRefreshStatus
    ) {
        status.attemptID = outcome.attemptID
        if outcome.succeeded {
            status.lastSuccessAt = completedAt
            status.state = .succeeded
            status.errorSummary = nil
        } else {
            status.state = .failed
            status.errorSummary = outcome.message ?? "刷新未完成，请稍后重试。"
        }
    }

    private func invalidateManualRefreshAttempts(missingFrom profiles: [SourceProfile]) {
        let loadedProfileIDs = Set(profiles.map(\.id))
        for key in Array(manualRefreshAttempts.keys)
        where !loadedProfileIDs.contains(key.profileID) {
            manualRefreshAttempts[key] = nil
        }
    }

    private func scheduleRefreshReconciliation(
        key: RefreshKey,
        overlayID: UUID
    ) -> Task<Void, Never> {
        cancelRefreshReconciliation(for: key)
        let reconciliationID = UUID()
        let task = Task { @MainActor [weak self] in
            await Task.yield()
            await self?.performScheduledRefreshReconciliation(
                key: key,
                overlayID: overlayID,
                reconciliationID: reconciliationID
            )
        }
        refreshReconciliationTasks[key] = RefreshReconciliationTask(
            id: reconciliationID,
            task: task
        )
        return task
    }

    private func cancelRefreshReconciliation(for key: RefreshKey) {
        refreshReconciliationTasks.removeValue(forKey: key)?.task.cancel()
    }

    private func finishRefreshReconciliation(key: RefreshKey, id: UUID) {
        guard refreshReconciliationTasks[key]?.id == id else { return }
        refreshReconciliationTasks[key] = nil
    }

    fileprivate func performScheduledRefreshReconciliation(
        key: RefreshKey,
        overlayID: UUID,
        reconciliationID: UUID
    ) async {
        await waitForWinningReloadCompletion()
        guard !Task.isCancelled,
              terminalRefreshOverlays[key]?.id == overlayID else {
            finishRefreshReconciliation(key: key, id: reconciliationID)
            return
        }
        _ = await reload()
        finishRefreshReconciliation(key: key, id: reconciliationID)
    }

    private func acquireActiveMutationLease(
        for operation: ActiveMutationLaneEvent.Operation
    ) async -> ActiveMutationLease? {
        let lease = ActiveMutationLease(id: UUID(), operation: operation)
        let cancelQueuedMutation: @MainActor @Sendable () -> Void = { [weak self] in
            self?.cancelQueuedActiveMutation(id: lease.id)
        }
        let granted = await withTaskCancellationHandler(
            operation: {
                guard !Task.isCancelled else {
                    mutationLaneEvent?(.cancelled(operation))
                    return false
                }
                return await withCheckedContinuation { continuation in
                    if activeMutationLease == nil {
                        activeMutationLease = lease
                        mutationLaneEvent?(.acquired(operation))
                        continuation.resume(returning: true)
                    } else {
                        queuedActiveMutations.append(ActiveMutationWaiter(
                            lease: lease,
                            continuation: continuation
                        ))
                        mutationLaneEvent?(.queued(operation))
                    }
                }
            },
            onCancel: {
                Task { @MainActor in
                    cancelQueuedMutation()
                }
            }
        )
        guard granted else { return nil }
        guard !Task.isCancelled else {
            mutationLaneEvent?(.cancelled(operation))
            releaseActiveMutationLease(lease)
            return nil
        }
        return lease
    }

    private func cancelQueuedActiveMutation(id: UUID) {
        guard let index = queuedActiveMutations.firstIndex(where: { $0.lease.id == id }) else {
            return
        }
        let waiter = queuedActiveMutations.remove(at: index)
        mutationLaneEvent?(.cancelled(waiter.lease.operation))
        waiter.continuation.resume(returning: false)
    }

    private func releaseActiveMutationLease(_ lease: ActiveMutationLease) {
        guard activeMutationLease?.id == lease.id else { return }
        mutationLaneEvent?(.released(lease.operation))
        if queuedActiveMutations.isEmpty {
            activeMutationLease = nil
            let waiters = mutationLaneIdleWaiters
            mutationLaneIdleWaiters = []
            for waiter in waiters {
                waiter.continuation.resume(returning: true)
            }
        } else {
            let waiter = queuedActiveMutations.removeFirst()
            activeMutationLease = waiter.lease
            mutationLaneEvent?(.acquired(waiter.lease.operation))
            waiter.continuation.resume(returning: true)
        }
    }

    private func waitForActiveMutationLaneIdle() async -> Bool {
        while activeMutationLease != nil || !queuedActiveMutations.isEmpty {
            let waiterID = UUID()
            let cancelIdleWait: @MainActor @Sendable () -> Void = { [weak self] in
                self?.cancelMutationLaneIdleWaiter(id: waiterID)
            }
            let reachedIdle = await withTaskCancellationHandler(
                operation: {
                    guard !Task.isCancelled else { return false }
                    return await withCheckedContinuation { continuation in
                        guard activeMutationLease != nil || !queuedActiveMutations.isEmpty else {
                            continuation.resume(returning: true)
                            return
                        }
                        mutationLaneIdleWaiters.append(MutationLaneIdleWaiter(
                            id: waiterID,
                            continuation: continuation
                        ))
                        mutationLaneEvent?(.reloadWaiting)
                    }
                },
                onCancel: {
                    Task { @MainActor in
                        cancelIdleWait()
                    }
                }
            )
            guard reachedIdle, !Task.isCancelled else { return false }
        }
        return !Task.isCancelled
    }

    private func cancelMutationLaneIdleWaiter(id: UUID) {
        guard let index = mutationLaneIdleWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = mutationLaneIdleWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func postWriteReloadOutcome() async -> ReloadOutcome {
        let reconciliation = Task { @MainActor [self] in
            await reloadOutcome()
        }
        return await reconciliation.value
    }

    private func waitForReloadCompletion(_ id: UUID) async {
        guard activeReloadIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            reloadCompletionWaiters[id, default: []].append(continuation)
        }
    }

    private func waitForWinningReloadCompletion() async {
        while let reloadID, activeReloadIDs.contains(reloadID) {
            await waitForReloadCompletion(reloadID)
        }
    }

    private func completeReload(_ id: UUID) {
        activeReloadIDs.remove(id)
        for waiter in reloadCompletionWaiters.removeValue(forKey: id) ?? [] {
            waiter.resume()
        }
    }

    private func presentOperationMessage(_ message: String) {
        alertKind = .operation
        alertMessage = message
    }

    private func clearOperationAlert() {
        guard alertKind == .operation else { return }
        alertMessage = nil
    }

    private func isCurrentMappingTarget(_ channel: Channel) -> Bool {
        !isLoading
            && activeProfile?.id == channel.sourceProfileID
            && channels.contains(where: {
                $0.id == channel.id && $0.sourceProfileID == channel.sourceProfileID
            })
    }

    private func rejectStaleMappingTarget() async {
        _ = await reload()
        presentOperationMessage("频道列表已更改，请重新选择频道后再保存映射。")
    }
}

fileprivate extension AppModel {
    enum AlertKind {
        case playback
        case operation
    }

    struct PendingCreation {
        let attemptID: UUID
        let profile: SourceProfile
    }

    struct ActiveTransition {
        let id: UUID
        let previousState: ActiveBoundStateSnapshot
    }

    struct ActiveMutationLease {
        let id: UUID
        let operation: ActiveMutationLaneEvent.Operation
    }

    struct ActiveMutationWaiter {
        let lease: ActiveMutationLease
        let continuation: CheckedContinuation<Bool, Never>
    }

    struct MutationLaneIdleWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    enum ReloadOutcome {
        case applied
        case failedWhileCurrent
        case superseded
    }

    struct ActiveBoundStateSnapshot {
        let activeProfile: SourceProfile?
        let channels: [Channel]
        let epgChannels: [EPGChannel]
        let epgProgrammeCount: Int
        let staleEPGCoverageEnd: Date?
        let matchByChannelID: [String: EPGMatchResult]
        let manualMappingByChannelID: [String: String]
        let programmesByChannelID: [String: [Programme]]
        let presentedPlaybackRequest: PlaybackRequest?
    }

    struct RefreshKey: Hashable, Sendable {
        let profileID: UUID
        let resource: RefreshResource
    }

    struct ManualRefreshAttempt {
        let id: UUID
        let startedAt: Date
    }

    struct TerminalRefreshOverlay {
        let id: UUID
        let startedAt: Date
        let expectedAttemptID: UUID?
        let outcome: RefreshOutcome
        let completedAt: Date
    }

    struct RefreshReconciliationTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    struct AutomaticRefreshTask {
        let id: UUID
        let task: Task<Void, Never>
    }
}
