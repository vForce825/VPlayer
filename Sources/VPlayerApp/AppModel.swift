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

    private let repository: any LibraryRepository
    private let refreshResources: Refresh
    private let now: @Sendable () -> Date
    private var matchByChannelID: [String: EPGMatchResult] = [:]
    private var reloadID: UUID?

    init(
        repository: any LibraryRepository,
        refresh: @escaping Refresh,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.refreshResources = refresh
        self.now = now
    }

    func reload() async {
        let currentReloadID = UUID()
        reloadID = currentReloadID
        isLoading = true

        do {
            let loadedProfiles = try await repository.profiles()
            try Task.checkCancellation()
            let loadedActiveProfile = try await repository.activeProfile()
            try Task.checkCancellation()

            guard let loadedActiveProfile else {
                apply(
                    reloadID: currentReloadID,
                    profiles: loadedProfiles,
                    activeProfile: nil,
                    channels: [],
                    epgChannels: [],
                    matches: [:],
                    programmes: [:]
                )
                return
            }

            async let channelLoad = repository.channels(profileID: loadedActiveProfile.id)
            async let epgChannelLoad = repository.epgChannels(profileID: loadedActiveProfile.id)
            let (loadedChannels, loadedEPGChannels) = try await (channelLoad, epgChannelLoad)
            try Task.checkCancellation()

            var matches: [String: EPGMatchResult] = [:]
            var programmes: [String: [Programme]] = [:]
            let windowStart = now().addingTimeInterval(-3_600)
            let windowEnd = windowStart.addingTimeInterval(25 * 3_600)

            for channel in loadedChannels {
                try Task.checkCancellation()
                let manualMapping = try await repository.manualMapping(
                    profileID: loadedActiveProfile.id,
                    channelID: channel.id
                )
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

            apply(
                reloadID: currentReloadID,
                profiles: loadedProfiles,
                activeProfile: loadedActiveProfile,
                channels: loadedChannels.sorted { ($0.order, $0.id) < ($1.order, $1.id) },
                epgChannels: loadedEPGChannels,
                matches: matches,
                programmes: programmes
            )
        } catch is CancellationError {
            finishLoading(reloadID: currentReloadID)
        } catch {
            guard reloadID == currentReloadID else { return }
            alertMessage = "无法读取数据，请稍后重试。"
            finishLoading(reloadID: currentReloadID)
        }
    }

    @discardableResult
    func create(input: SourceProfileInput) async -> Bool {
        do {
            _ = try await repository.createProfile(input.validated(), now: now())
            await reload()
            return true
        } catch {
            presentOperationError(error)
            return false
        }
    }

    @discardableResult
    func update(profileID: UUID, input: SourceProfileInput) async -> Bool {
        do {
            try await repository.updateProfile(id: profileID, input: input.validated(), now: now())
            await reload()
            return true
        } catch {
            presentOperationError(error)
            return false
        }
    }

    func delete(profileID: UUID) async {
        do {
            try await repository.deleteProfile(id: profileID)
            await reload()
        } catch {
            presentOperationError(error)
        }
    }

    func activate(profileID: UUID) async {
        do {
            try await repository.setActiveProfile(id: profileID)
            await reload()
        } catch {
            presentOperationError(error)
        }
    }

    func refresh(profileID: UUID, resource: RefreshResource) async {
        markRefreshing(profileID: profileID, resource: resource)
        _ = await refreshResources(profileID, [resource], .manual)
        guard !Task.isCancelled else { return }
        await reload()
    }

    func saveMapping(channel: Channel, xmltvChannelID: String?) async {
        guard activeProfile?.id == channel.sourceProfileID else {
            alertMessage = "当前数据源已更改，请重试。"
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
            alertMessage = rejection.userMessage
        }
    }

    func matchedEPGChannelID(for channel: Channel) -> String? {
        matchByChannelID[channel.id]?.xmltvChannelID
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
        programmes: [String: [Programme]]
    ) {
        guard reloadID == currentReloadID else { return }
        self.profiles = profiles
        self.activeProfile = activeProfile
        self.channels = channels
        self.epgChannels = epgChannels
        self.matchByChannelID = matches
        self.programmesByChannelID = programmes
        finishLoading(reloadID: currentReloadID)
    }

    private func finishLoading(reloadID currentReloadID: UUID) {
        guard reloadID == currentReloadID else { return }
        isLoading = false
    }

    private func markRefreshing(profileID: UUID, resource: RefreshResource) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        switch resource {
        case .playlist:
            profiles[index].m3uStatus.state = .refreshing
            profiles[index].m3uStatus.errorSummary = nil
        case .epg:
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
            alertMessage = "请输入数据源名称。"
        case SourceProfileValidationError.invalidURL(field: .m3u):
            alertMessage = "请输入有效的 M3U 地址。"
        case SourceProfileValidationError.invalidURL(field: .epg):
            alertMessage = "请输入有效的 EPG 地址。"
        case SourceProfileValidationError.unsupportedURL(field: .m3u):
            alertMessage = "M3U 地址仅支持 HTTP 或 HTTPS。"
        case SourceProfileValidationError.unsupportedURL(field: .epg):
            alertMessage = "EPG 地址仅支持 HTTP 或 HTTPS。"
        default:
            alertMessage = "操作失败，请稍后重试。"
        }
    }
}
