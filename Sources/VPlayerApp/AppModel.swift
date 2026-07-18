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
    }

    @discardableResult
    func reload() async -> Bool {
        let currentReloadID = UUID()
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
                    programmes: [:]
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
                programmes: programmes
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
    func create(input: SourceProfileInput) async -> Bool {
        do {
            let validatedInput = try input.validated()
            let createdProfile: SourceProfile
            if let pendingCreation, pendingCreation.input == validatedInput {
                createdProfile = pendingCreation.profile
            } else {
                createdProfile = try await repository.createProfile(validatedInput, now: now())
                pendingCreation = PendingCreation(input: validatedInput, profile: createdProfile)
            }
            reconcileCreatedProfile(createdProfile)
            guard await reload() else {
                reconcileCreatedProfile(createdProfile)
                presentOperationMessage("数据源已保存，但界面未能重新读取。请重试；再次保存不会重复创建。")
                return false
            }
            pendingCreation = nil
            return true
        } catch {
            presentOperationError(error)
            return false
        }
    }

    @discardableResult
    func update(profileID: UUID, input: SourceProfileInput) async -> Bool {
        do {
            let validatedInput = try input.validated()
            let updatedAt = now()
            try await repository.updateProfile(id: profileID, input: validatedInput, now: updatedAt)
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
            if pendingCreation?.profile.id == profileID {
                pendingCreation = nil
            }
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
        markRefreshing(profileID: profileID, resource: resource)
        let outcomes = await refreshResources(profileID, [resource], .manual)
        reconcileRefreshOutcome(
            profileID: profileID,
            resource: resource,
            outcome: outcomes.first { $0.resource == resource }
        )
        guard !Task.isCancelled else { return }
        _ = await reload()
    }

    func saveMapping(channel: Channel, xmltvChannelID: String?) async {
        guard activeProfile?.id == channel.sourceProfileID else {
            presentOperationMessage("当前数据源已更改，请重试。")
            return
        }
        do {
            try await repository.setManualMapping(
                profileID: channel.sourceProfileID,
                channelID: channel.id,
                xmltvChannelID: xmltvChannelID
            )
            await reload()
        } catch {
            presentOperationError(error)
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
        programmes: [String: [Programme]]
    ) -> Bool {
        guard reloadID == currentReloadID else { return false }
        self.profiles = profiles
        self.activeProfile = activeProfile
        self.channels = channels
        self.epgChannels = epgChannels
        self.matchByChannelID = matches
        self.manualMappingByChannelID = manualMappings
        self.programmesByChannelID = programmes
        finishLoading(reloadID: currentReloadID)
        return true
    }

    private func finishLoading(reloadID currentReloadID: UUID) {
        guard reloadID == currentReloadID else { return }
        isLoading = false
    }

    private func markRefreshing(profileID: UUID, resource: RefreshResource) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        switch resource {
        case .playlist:
            profiles[index].m3uStatus.lastAttemptAt = now()
            profiles[index].m3uStatus.state = .refreshing
            profiles[index].m3uStatus.errorSummary = nil
        case .epg:
            profiles[index].epgStatus.lastAttemptAt = now()
            profiles[index].epgStatus.state = .refreshing
            profiles[index].epgStatus.errorSummary = nil
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
        outcome: RefreshOutcome?
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let completedAt = now()
        func update(_ status: inout ResourceRefreshStatus) {
            if outcome?.succeeded == true {
                status.lastSuccessAt = completedAt
                status.state = .succeeded
                status.errorSummary = nil
            } else {
                status.state = .failed
                status.errorSummary = outcome?.message ?? "刷新未完成，请稍后重试。"
            }
        }
        switch resource {
        case .playlist:
            update(&profiles[index].m3uStatus)
        case .epg:
            update(&profiles[index].epgStatus)
        }
        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

    private func presentOperationMessage(_ message: String) {
        alertKind = .operation
        alertMessage = message
    }
}

private extension AppModel {
    enum AlertKind {
        case playback
        case operation
    }

    struct PendingCreation {
        let input: ValidatedSourceProfileInput
        let profile: SourceProfile
    }
}
