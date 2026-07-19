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

    var profiles: [SourceProfile] = []
    var activeProfile: SourceProfile?
    var channels: [Channel] = []
    var epgChannels: [EPGChannel] = []
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
    private var pendingCreation: PendingCreation?
    private var activeCreationAttemptIDs: Set<UUID> = []
    private var cancelledCreationAttemptIDs: Set<UUID> = []
    private var terminalRefreshOverlays: [RefreshKey: TerminalRefreshOverlay] = [:]
    private var manualRefreshAttempts: [RefreshKey: ManualRefreshAttempt] = [:]
    @ObservationIgnored private var activeReloadIDs: Set<UUID> = []
    @ObservationIgnored private var reloadCompletionWaiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]
    @ObservationIgnored private var refreshReconciliationTasks: [
        RefreshKey: RefreshReconciliationTask
    ] = [:]
    @ObservationIgnored private var libraryChangeTask: Task<Void, Never>?
    @ObservationIgnored private var alertKind = AlertKind.operation

    init(
        repository: any LibraryRepository,
        refresh: @escaping Refresh,
        libraryChanges: LibraryChangeSignal? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.refreshResources = refresh
        self.now = now
        if let libraryChanges {
            let observedGeneration = libraryChanges.generation
            libraryChangeTask = Task { @MainActor [weak self, weak libraryChanges] in
                guard let libraryChanges else { return }
                for await _ in libraryChanges.changes(after: observedGeneration) {
                    guard !Task.isCancelled else { return }
                    await self?.reload()
                }
            }
        }
    }

    deinit {
        libraryChangeTask?.cancel()
        for reconciliation in refreshReconciliationTasks.values {
            reconciliation.task.cancel()
        }
    }

    @discardableResult
    func reload() async -> Bool {
        let currentReloadID = UUID()
        activeReloadIDs.insert(currentReloadID)
        defer { completeReload(currentReloadID) }
        let terminalRefreshOverlayIDsAtStart = terminalRefreshOverlays.mapValues(\.id)
        reloadID = currentReloadID
        isLoading = true
        clearActiveBoundState()

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
                    matches: [:],
                    manualMappings: [:],
                    programmes: [:],
                    terminalRefreshOverlayIDsAtStart: terminalRefreshOverlayIDsAtStart
                )
            }

            async let channelLoad = repository.channels(profileID: loadedActiveProfile.id)
            async let epgChannelLoad = repository.epgChannels(profileID: loadedActiveProfile.id)
            let (loadedChannels, loadedEPGChannels) = try await (channelLoad, epgChannelLoad)
            try Task.checkCancellation()

            var matches: [String: EPGMatchResult] = [:]
            var manualMappings: [String: String] = [:]
            var programmes: [String: [Programme]] = [:]
            let windowStart = now().addingTimeInterval(-3_600)
            let windowEnd = windowStart.addingTimeInterval(25 * 3_600)

            for channel in loadedChannels {
                try Task.checkCancellation()
                let manualMapping = try await repository.manualMapping(
                    profileID: loadedActiveProfile.id,
                    channelID: channel.id
                )
                if let manualMapping {
                    manualMappings[channel.id] = manualMapping.xmltvChannelID
                }
                let match = EPGMatcher.match(
                    channel: channel,
                    epgChannels: loadedEPGChannels,
                    manualMapping: manualMapping
                )
                matches[channel.id] = match
                guard let xmltvChannelID = match.xmltvChannelID else { continue }
                programmes[channel.id] = try await repository.programmes(
                    profileID: loadedActiveProfile.id,
                    xmltvChannelID: xmltvChannelID,
                    overlapping: windowStart..<windowEnd
                )
            }

            return apply(
                reloadID: currentReloadID,
                profiles: loadedProfiles,
                activeProfile: loadedActiveProfile,
                channels: loadedChannels.sorted { ($0.order, $0.id) < ($1.order, $1.id) },
                epgChannels: loadedEPGChannels,
                matches: matches,
                manualMappings: manualMappings,
                programmes: programmes,
                terminalRefreshOverlayIDsAtStart: terminalRefreshOverlayIDsAtStart
            )
        } catch is CancellationError {
            finishLoading(reloadID: currentReloadID)
            return false
        } catch {
            guard reloadID == currentReloadID else { return false }
            presentOperationMessage("无法读取数据，请稍后重试。")
            finishLoading(reloadID: currentReloadID)
            return false
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
                presentOperationMessage("数据源已保存，但界面未能重新读取。请重试；再次保存不会重复创建。")
                return false
            }
            guard !cancelledCreationAttemptIDs.contains(attemptID) else {
                pendingCreation = nil
                return false
            }
            guard profiles.contains(where: { $0.id == createdProfile.id }) else {
                pendingCreation = nil
                presentOperationMessage("数据源已保存，但已无法在资料库中找到。请重新添加。")
                return false
            }
            if pendingCreation?.attemptID == attemptID {
                pendingCreation = nil
            }
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
            try await repository.updateProfile(id: profileID, input: validatedInput, now: updatedAt)
            clearPendingCreation(profileID: profileID)
            reconcileUpdatedProfile(id: profileID, input: validatedInput, updatedAt: updatedAt)
            guard await reload() else {
                reconcileUpdatedProfile(id: profileID, input: validatedInput, updatedAt: updatedAt)
                presentOperationMessage("更改已保存，但界面未能重新读取。请稍后重试。")
                return false
            }
            return true
        } catch {
            presentOperationError(error)
            return false
        }
    }

    @discardableResult
    func delete(profileID: UUID) async -> Bool {
        let deletedActiveProfile = activeProfile?.id == profileID
        let previousActiveProfile = activeProfile
        if deletedActiveProfile {
            beginActiveTransition(to: nil)
        }
        do {
            try await repository.deleteProfile(id: profileID)
            clearPendingCreation(profileID: profileID)
            profiles.removeAll { $0.id == profileID }
            if deletedActiveProfile {
                clearActiveBoundState()
            }
            guard await reload() else {
                profiles.removeAll { $0.id == profileID }
                if deletedActiveProfile {
                    clearActiveBoundState()
                }
                presentOperationMessage("数据源已删除，但界面未能重新读取。请稍后重试。")
                return false
            }
            return true
        } catch {
            if deletedActiveProfile {
                activeProfile = previousActiveProfile
                isLoading = false
            }
            presentOperationError(error)
            return false
        }
    }

    @discardableResult
    func activate(profileID: UUID) async -> Bool {
        let previousActiveProfile = activeProfile
        beginActiveTransition(to: profiles.first { $0.id == profileID })
        do {
            try await repository.setActiveProfile(id: profileID)
            guard await reload() else {
                activeProfile = profiles.first { $0.id == profileID }
                clearChannelState()
                presentOperationMessage("当前数据源已切换，但频道未能重新读取。请稍后重试。")
                return false
            }
            return true
        } catch {
            activeProfile = previousActiveProfile
            isLoading = false
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
              channels.contains(where: {
                  $0.id == channel.id && $0.sourceProfileID == activeProfile.id
              }) else {
            presentedPlaybackRequest = nil
            return
        }
        switch StreamProtocolPolicy.evaluate(channel.streamURL) {
        case .allowed:
            alertMessage = nil
            presentedPlaybackRequest = PlaybackRequest(
                sourceProfileID: channel.sourceProfileID,
                channelID: channel.id,
                streamURL: channel.streamURL,
                title: channel.displayName
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

    private func apply(
        reloadID currentReloadID: UUID,
        profiles: [SourceProfile],
        activeProfile: SourceProfile?,
        channels: [Channel],
        epgChannels: [EPGChannel],
        matches: [String: EPGMatchResult],
        manualMappings: [String: String],
        programmes: [String: [Programme]],
        terminalRefreshOverlayIDsAtStart: [RefreshKey: UUID]
    ) -> Bool {
        guard reloadID == currentReloadID else { return false }
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
        self.matchByChannelID = matches
        self.manualMappingByChannelID = manualMappings
        self.programmesByChannelID = programmes
        if let pendingCreation,
           !profiles.contains(where: { $0.id == pendingCreation.profile.id }) {
            self.pendingCreation = nil
        }
        finishLoading(reloadID: currentReloadID)
        return true
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
        switch error {
        case SourceProfileValidationError.emptyName:
            presentOperationMessage("请输入数据源名称。")
        case SourceProfileValidationError.invalidURL(field: .m3u):
            presentOperationMessage("请输入有效的 M3U 地址。")
        case SourceProfileValidationError.invalidURL(field: .epg):
            presentOperationMessage("请输入有效的 EPG 地址。")
        case SourceProfileValidationError.unsupportedURL(field: .m3u):
            presentOperationMessage("M3U 地址仅支持 HTTP 或 HTTPS。")
        case SourceProfileValidationError.unsupportedURL(field: .epg):
            presentOperationMessage("EPG 地址仅支持 HTTP 或 HTTPS。")
        default:
            presentOperationMessage("操作失败，请稍后重试。")
        }
    }

    private func beginActiveTransition(to profile: SourceProfile?) {
        reloadID = UUID()
        isLoading = true
        activeProfile = profile
        clearChannelState()
    }

    private func clearActiveBoundState() {
        activeProfile = nil
        clearChannelState()
    }

    private func clearChannelState() {
        channels = []
        epgChannels = []
        matchByChannelID = [:]
        manualMappingByChannelID = [:]
        programmesByChannelID = [:]
        presentedPlaybackRequest = nil
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
        while let reloadID, activeReloadIDs.contains(reloadID) {
            await waitForReloadCompletion(reloadID)
        }
        guard !Task.isCancelled,
              terminalRefreshOverlays[key]?.id == overlayID else {
            finishRefreshReconciliation(key: key, id: reconciliationID)
            return
        }
        _ = await reload()
        finishRefreshReconciliation(key: key, id: reconciliationID)
    }

    private func waitForReloadCompletion(_ id: UUID) async {
        guard activeReloadIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            reloadCompletionWaiters[id, default: []].append(continuation)
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
}
