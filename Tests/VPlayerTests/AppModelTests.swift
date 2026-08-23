// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Observation
import XCTest
@testable import VPlayer
@testable import VPlayerCore
@testable import VPlayerPlayback

@MainActor
final class AppModelTests: XCTestCase {
    func testReloadIssuesOneProgrammeQueryRegardlessOfChannelCount() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channelCount = 200
        let channels = (0..<channelCount).map { index in
            makeChannel(
                profileID: profile.id,
                url: "https://example.test/live/\(index)",
                tvgID: "epg-\(index)",
                order: index
            )
        }
        let epgChannels = (0..<channelCount).map { index in
            EPGChannel(id: "epg-\(index)", displayNames: ["Channel \(index)"], iconURL: nil)
        }
        let repository = RepositorySpy(
            profiles: [profile],
            activeProfileID: profile.id,
            channels: [profile.id: channels],
            epgChannels: [profile.id: epgChannels]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()

        let snapshot = await repository.snapshot()
        // The whole point of batching: query count must not scale with the
        // playlist size, which is what made large IPTV sources unusable.
        XCTAssertEqual(model.channels.count, channelCount)
        XCTAssertEqual(snapshot.programmeBatchRequests.count, 1)
        XCTAssertTrue(snapshot.programmeRequests.isEmpty)
        XCTAssertEqual(
            snapshot.programmeBatchRequests.first?.xmltvChannelIDs.count,
            channelCount
        )
    }

    func testLargeLibraryPresentationPreparationYieldsMainActorAndBuildsSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_787_486_400)
        let profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: now
        )
        let channelCount = 10_000
        let channels = (0..<channelCount).reversed().map { index in
            makeChannel(
                profileID: profile.id,
                url: "https://example.test/live/\(index)",
                tvgID: "epg-\(index)",
                order: index
            )
        }
        let matches = Dictionary(uniqueKeysWithValues: channels.map { channel in
            (
                channel.id,
                EPGMatchResult.matched(
                    xmltvChannelID: channel.tvgID!,
                    method: .exactID
                )
            )
        })
        let programmesByXMLTVChannelID = Dictionary(uniqueKeysWithValues: (0..<channelCount).map {
            index in
            let programme = Programme(
                id: "programme-\(index)",
                xmltvChannelID: "epg-\(index)",
                start: now.addingTimeInterval(-600),
                stop: now.addingTimeInterval(600),
                title: "Programme \(index)",
                subtitle: nil,
                summary: nil,
                categories: []
            )
            return (programme.xmltvChannelID, [programme])
        })
        let playingChannel = channels[channelCount / 2]
        let playbackRequest = PlaybackRequest(
            sourceProfileID: profile.id,
            channelID: playingChannel.id,
            streamURL: playingChannel.streamURL,
            title: playingChannel.displayName
        )
        var mainActorHeartbeatRan = false
        Task { @MainActor in
            mainActorHeartbeatRan = true
        }

        let snapshot = try await AppModel.makeLibraryPresentationSnapshot(
            channels: channels,
            matches: matches,
            programmesByXMLTVChannelID: programmesByXMLTVChannelID,
            sortsChannels: true,
            indexesPlaybackChannels: true
        )

        XCTAssertTrue(mainActorHeartbeatRan)
        XCTAssertEqual(snapshot.channels.first?.order, 0)
        XCTAssertEqual(snapshot.channels.last?.order, channelCount - 1)
        XCTAssertEqual(snapshot.programmesByChannelID.count, channelCount)
        XCTAssertEqual(
            snapshot.programmesByChannelID[playingChannel.id]?.first?.title,
            "Programme \(playingChannel.order)"
        )
        XCTAssertEqual(
            snapshot.playbackChannelIdentities[playingChannel.id],
            AppModel.PlaybackChannelIdentity(
                sourceProfileID: playbackRequest.sourceProfileID,
                streamURL: playbackRequest.streamURL,
                title: playbackRequest.title
            )
        )
    }

    func testReloadReportsEPGWhoseProgrammesAllEndedAndClearsItOnceCoverageReachesNow() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channel = makeChannel(profileID: profile.id, url: "https://active.test/live", tvgID: "epg", order: 0)
        let staleStop = now.addingTimeInterval(-3 * 24 * 3_600)
        let stale = Programme(
            id: "stale",
            xmltvChannelID: "epg",
            start: staleStop.addingTimeInterval(-1_800),
            stop: staleStop,
            title: "Ended three days ago",
            subtitle: nil,
            summary: nil,
            categories: []
        )
        let repository = RepositorySpy(
            profiles: [profile],
            activeProfileID: profile.id,
            channels: [profile.id: [channel]],
            epgChannels: [profile.id: [EPGChannel(id: "epg", displayNames: ["Channel 0"], iconURL: nil)]],
            programmes: [profile.id: [stale]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()

        // The window query returns nothing, so without coverage the screens
        // could only show empty schedules with no explanation.
        XCTAssertTrue(model.programmesByChannelID[channel.id, default: []].isEmpty)
        XCTAssertEqual(model.staleEPGCoverageEnd, staleStop)

        let current = Programme(
            id: "current",
            xmltvChannelID: "epg",
            start: now.addingTimeInterval(-900),
            stop: now.addingTimeInterval(900),
            title: "On air",
            subtitle: nil,
            summary: nil,
            categories: []
        )
        await repository.replaceProgrammes([stale, current], profileID: profile.id)
        await model.reload()

        XCTAssertEqual(model.programmesByChannelID[channel.id], [current])
        XCTAssertNil(model.staleEPGCoverageEnd)
    }

    func testReloadWithoutAnyEPGProgrammesReportsNoStaleCoverage() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channel = makeChannel(profileID: profile.id, url: "https://active.test/live", tvgID: "epg", order: 0)
        let repository = RepositorySpy(
            profiles: [profile],
            activeProfileID: profile.id,
            channels: [profile.id: [channel]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()

        // "Never fetched" is already spelled out by the refresh status; a
        // staleness note on top of it would only be noise.
        XCTAssertEqual(model.epgProgrammeCount, 0)
        XCTAssertNil(model.staleEPGCoverageEnd)
    }

    func testReloadUsesOnlyActiveProfileAndLoadsMatchedProgrammesInRequiredWindow() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let inactive = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Inactive", now: now)
        let active = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Active", now: now)
        let inactiveChannel = makeChannel(profileID: inactive.id, url: "https://inactive.test/live", tvgID: "inactive", order: 0)
        let activeChannel = makeChannel(profileID: active.id, url: "https://active.test/rtp/239.1.1.1", tvgID: "active-epg", order: 0)
        let current = Programme(
            id: "current",
            xmltvChannelID: "active-epg",
            start: now.addingTimeInterval(-900),
            stop: now.addingTimeInterval(900),
            title: "Current",
            subtitle: nil,
            summary: nil,
            categories: []
        )
        let repository = RepositorySpy(
            profiles: [inactive, active],
            activeProfileID: active.id,
            channels: [inactive.id: [inactiveChannel], active.id: [activeChannel]],
            epgChannels: [active.id: [EPGChannel(id: "active-epg", displayNames: ["Active"], iconURL: nil)]],
            programmes: [active.id: [current]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()

        XCTAssertEqual(model.profiles, [inactive, active])
        XCTAssertEqual(model.activeProfile, active)
        XCTAssertEqual(model.channels, [activeChannel])
        XCTAssertEqual(model.epgProgrammeCount, 1)
        XCTAssertEqual(model.programmesByChannelID[activeChannel.id], [current])
        XCTAssertEqual(model.matchedEPGChannelID(for: activeChannel), "active-epg")
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.programmeBatchRequests, [
            .init(
                profileID: active.id,
                xmltvChannelIDs: ["active-epg"],
                overlapping: now.addingTimeInterval(-3_600)..<now.addingTimeInterval(24 * 3_600)
            )
        ])
        XCTAssertTrue(snapshot.programmeRequests.isEmpty)
        XCTAssertFalse(snapshot.programmeBatchRequests.contains { $0.profileID == inactive.id })
        XCTAssertFalse(model.isLoading)
    }

    func testSelectionRejectsUDPButAllowsHTTPRelayWhosePathContainsRTP() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let udp = makeChannel(profileID: profile.id, url: "udp://239.1.1.1:5000", tvgID: nil, order: 0)
        let relay = makeChannel(profileID: profile.id, url: "https://relay.test/rtp/239.1.1.1:5000", tvgID: nil, order: 1)
        let model = AppModel(
            repository: RepositorySpy(
                profiles: [profile],
                channels: [profile.id: [udp, relay]]
            ),
            refresh: { _, _, _ in [] },
            now: { now }
        )

        await model.reload()
        model.select(channel: udp)
        XCTAssertEqual(model.alertMessage, "首版暂不支持组播地址")
        XCTAssertNil(model.presentedPlaybackRequest)

        model.dismissAlert()
        model.select(channel: relay)
        XCTAssertNil(model.alertMessage)
        XCTAssertEqual(model.presentedPlaybackRequest?.streamURL, relay.streamURL)
        XCTAssertEqual(model.presentedPlaybackRequest?.channelID, relay.id)
    }

    func testSavingAndClearingManualMappingReloadsTheMatchedProgrammes() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channel = makeChannel(profileID: profile.id, url: "https://example.test/live", tvgID: "automatic", order: 0)
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [channel]],
            epgChannels: [profile.id: [
                EPGChannel(id: "automatic", displayNames: ["Automatic"], iconURL: nil),
                EPGChannel(id: "manual", displayNames: ["Manual"], iconURL: nil),
            ]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()
        await model.saveMapping(channel: channel, xmltvChannelID: "manual")
        XCTAssertEqual(model.matchedEPGChannelID(for: channel), "manual")
        await model.saveMapping(channel: channel, xmltvChannelID: nil)
        XCTAssertEqual(model.matchedEPGChannelID(for: channel), "automatic")
        let snapshot = await repository.snapshot()
        XCTAssertNil(snapshot.manualMappings[profile.id]?[channel.id])
    }

    func testManualRefreshDispatchesOnlyRequestedResource() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let probe = RefreshCallProbe()
        let model = AppModel(
            repository: RepositorySpy(profiles: [profile]),
            refresh: { profileID, resources, trigger in
                await probe.record(profileID: profileID, resources: resources, trigger: trigger)
                return resources.map { RefreshOutcome(resource: $0, succeeded: true, message: nil) }
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .epg)

        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.profileID, profile.id)
        XCTAssertEqual(calls.first?.resources, [.epg])
        guard case .manual? = calls.first?.trigger else {
            return XCTFail("Expected a manual refresh")
        }
    }

    func testEmptyManualRefreshOutcomeSynthesizesGenericFailureOverlay() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { profileID, _, _ in
                try? await repository.recordAttempt(
                    profileID: profileID,
                    resource: .playlist,
                    at: now
                )
                return []
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        _ = await model.reload()

        let repositorySnapshot = await repository.snapshot()
        XCTAssertEqual(repositorySnapshot.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新未完成，请稍后重试。")
        XCTAssertEqual(model.activeProfile?.m3uStatus.state, .failed)
    }

    func testWrongResourceManualRefreshOutcomeSynthesizesRequestedResourceFailureOverlay() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { profileID, _, _ in
                try? await repository.recordAttempt(
                    profileID: profileID,
                    resource: .playlist,
                    at: now
                )
                return [RefreshOutcome(resource: .epg, succeeded: true, message: nil)]
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        _ = await model.reload()

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新未完成，请稍后重试。")
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .never)
    }

    func testOlderManualRefreshFailureCannotOverrideBlockedNewerAttempt() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: now
                )
            },
            now: { now }
        )

        await model.reload()
        let older = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 1)
        let newer = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 2)

        await gate.release(resource: .playlist, ordinal: 1, result: .failure("older failure"))
        await older.value
        _ = await model.reload()

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)

        await gate.release(resource: .playlist, ordinal: 2, result: .success)
        await newer.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)

        try await repository.recordFailure(
            profileID: profile.id,
            resource: .playlist,
            summary: "later terminal truth",
            at: now.addingTimeInterval(60)
        )
        _ = await model.reload()
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "later terminal truth")
    }

    func testCancelledOlderManualRefreshCannotOverrideBlockedNewerAttempt() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: now
                )
            },
            now: { now }
        )

        await model.reload()
        let older = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 1)
        let newer = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 2)

        older.cancel()
        await gate.release(resource: .playlist, ordinal: 1, result: .cancellation)
        await older.value
        _ = await model.reload()

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)

        await gate.release(resource: .playlist, ordinal: 2, result: .success)
        await newer.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
    }

    func testOlderEmptyAndWrongResourceResultsCannotOverrideNewerAttempts() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: now
                )
            },
            now: { now }
        )

        await model.reload()
        for (resource, staleResult) in [
            (RefreshResource.playlist, AppModelConcurrentRefreshGate.Result.empty),
            (RefreshResource.epg, AppModelConcurrentRefreshGate.Result.wrongResource),
        ] {
            let older = Task { await model.refresh(profileID: profile.id, resource: resource) }
            await gate.waitUntilStarted(resource: resource, ordinal: 1)
            let newer = Task { await model.refresh(profileID: profile.id, resource: resource) }
            await gate.waitUntilStarted(resource: resource, ordinal: 2)

            await gate.release(resource: resource, ordinal: 1, result: staleResult)
            await older.value
            _ = await model.reload()

            let state = resource == .playlist
                ? model.profiles.first?.m3uStatus.state
                : model.profiles.first?.epgStatus.state
            XCTAssertEqual(state, .refreshing)

            await gate.release(resource: resource, ordinal: 2, result: .success)
            await newer.value
        }
    }

    func testProfileDisappearanceRevokesSuspendedManualRefreshAttempt() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: now
                )
            },
            now: { now }
        )

        await model.reload()
        let suspended = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 1)
        try await repository.deleteProfile(id: profile.id)
        _ = await model.reload()

        var reappeared = profile
        reappeared.m3uStatus = ResourceRefreshStatus(lastAttemptAt: now, state: .refreshing)
        await repository.replaceProfiles([reappeared], activeProfileID: profile.id)
        _ = await model.reload()

        await gate.release(resource: .playlist, ordinal: 1, result: .failure("revoked failure"))
        await suspended.value

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)
    }

    func testManualRefreshAttemptGenerationsAreIndependentAcrossResources() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: now
                )
            },
            now: { now }
        )

        await model.reload()
        let oldPlaylist = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 1)
        let epg = Task { await model.refresh(profileID: profile.id, resource: .epg) }
        await gate.waitUntilStarted(resource: .epg, ordinal: 1)
        let newPlaylist = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 2)

        await gate.release(resource: .epg, ordinal: 1, result: .failure("epg failure"))
        await epg.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .failed)

        await gate.release(resource: .playlist, ordinal: 1, result: .failure("old playlist failure"))
        await oldPlaylist.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .failed)

        await gate.release(resource: .playlist, ordinal: 2, result: .success)
        await newPlaylist.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .failed)
    }

    func testReloadCapturedBeforeSameResourceAttemptPreservesActiveRefreshingMetadata() async {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let oldAttemptAt = startedAt.addingTimeInterval(-300)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: startedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: oldAttemptAt,
            state: .failed,
            errorSummary: "old playlist failure"
        )
        let channel = makeChannel(
            profileID: profile.id,
            url: "https://example.test/live",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [channel]]
        )
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: startedAt
                )
            },
            now: { startedAt }
        )

        await model.reload()
        await repository.gateNextChannelRead()
        let staleReload = Task { await model.reload() }
        await repository.waitUntilChannelReadIsBlocked()
        let refresh = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 1)

        await repository.releaseChannelRead()
        let staleReloadSucceeded = await staleReload.value

        XCTAssertTrue(staleReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertEqual(model.activeProfile?.m3uStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(model.activeProfile?.m3uStatus.state, .refreshing)

        await gate.release(resource: .playlist, ordinal: 1, result: .success)
        await refresh.value
    }

    func testReloadPreservesCrossResourceAttemptWhileAcceptingOtherResourceSnapshot() async throws {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let playlistSuccessAt = startedAt.addingTimeInterval(-60)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: startedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: startedAt.addingTimeInterval(-600),
            state: .failed,
            errorSummary: "old playlist failure"
        )
        profile.epgStatus = ResourceRefreshStatus(
            lastAttemptAt: startedAt.addingTimeInterval(-300),
            state: .failed,
            errorSummary: "old epg failure"
        )
        let channel = makeChannel(
            profileID: profile.id,
            url: "https://example.test/live",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [channel]]
        )
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: startedAt
                )
            },
            now: { startedAt }
        )

        await model.reload()
        try await repository.recordSuccess(
            profileID: profile.id,
            resource: .playlist,
            at: playlistSuccessAt
        )
        await repository.gateNextChannelRead()
        let capturedReload = Task { await model.reload() }
        await repository.waitUntilChannelReadIsBlocked()
        let epgRefresh = Task { await model.refresh(profileID: profile.id, resource: .epg) }
        await gate.waitUntilStarted(resource: .epg, ordinal: 1)

        await repository.releaseChannelRead()
        let capturedReloadSucceeded = await capturedReload.value

        XCTAssertTrue(capturedReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastSuccessAt, playlistSuccessAt)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertEqual(model.profiles.first?.epgStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.epgStatus.errorSummary)

        await gate.release(resource: .epg, ordinal: 1, result: .success)
        await epgRefresh.value
    }

    func testReloadStartedBeforeCancellationOverlayCannotClearOrOverwriteIt() async throws {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: startedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: startedAt.addingTimeInterval(-300),
            state: .failed,
            errorSummary: "stale terminal failure"
        )
        let channel = makeChannel(
            profileID: profile.id,
            url: "https://example.test/live",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [channel]]
        )
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: startedAt
                )
            },
            now: { startedAt }
        )

        await model.reload()
        await repository.gateNextChannelRead()
        let staleReload = Task { await model.reload() }
        await repository.waitUntilChannelReadIsBlocked()
        let cancelledRefresh = Task {
            await model.refresh(profileID: profile.id, resource: .playlist)
        }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 1)
        cancelledRefresh.cancel()
        await gate.release(resource: .playlist, ordinal: 1, result: .cancellation)
        await cancelledRefresh.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。")

        await repository.releaseChannelRead()
        let staleReloadSucceeded = await staleReload.value

        XCTAssertTrue(staleReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。")
        XCTAssertEqual(model.activeProfile?.m3uStatus.errorSummary, "刷新已取消。")

        try await repository.recordFailure(
            profileID: profile.id,
            resource: .playlist,
            summary: "persisted terminal truth",
            at: startedAt.addingTimeInterval(60)
        )
        _ = await model.reload()

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "persisted terminal truth")
        XCTAssertEqual(model.activeProfile?.m3uStatus.errorSummary, "persisted terminal truth")
    }

    func testManualRefreshKeepsReturnedFailureTerminalWhenFailurePersistenceFails() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(
            profiles: [profile],
            failsRecordFailure: true
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { now }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await coordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)

        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertNotNil(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertEqual(model.activeProfile?.m3uStatus.state, .failed)

        let laterReloadSucceeded = await model.reload()
        XCTAssertTrue(laterReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertNotNil(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertEqual(model.activeProfile?.m3uStatus.state, .failed)
    }

    func testRealCoordinatorFailureOverlaySurvivesOldTerminalRepositoryTruth() async {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let priorAt = startedAt.addingTimeInterval(-600)
        let scenarios: [(name: String, status: ResourceRefreshStatus)] = [
            (
                "succeeded",
                ResourceRefreshStatus(
                    lastAttemptAt: priorAt,
                    lastSuccessAt: priorAt,
                    state: .succeeded
                )
            ),
            (
                "failed",
                ResourceRefreshStatus(
                    lastAttemptAt: priorAt,
                    state: .failed,
                    errorSummary: "prior terminal failure"
                )
            )
        ]

        for scenario in scenarios {
            let clock = AppModelTestClock(startedAt)
            var profile = makeProfile(
                id: "00000000-0000-0000-0000-000000000001",
                name: "Source",
                now: startedAt
            )
            profile.m3uStatus = scenario.status
            let repository = RepositorySpy(
                profiles: [profile],
                failsRecordAttempt: true,
                failsRecordFailure: true
            )
            let coordinator = RefreshCoordinator(
                repository: repository,
                downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
                now: { clock.value }
            )
            let model = AppModel(
                repository: repository,
                refresh: { profileID, resources, trigger in
                    await coordinator.refresh(
                        profileID: profileID,
                        resources: resources,
                        trigger: trigger
                    )
                },
                now: { clock.value }
            )

            await model.reload()
            await model.refresh(profileID: profile.id, resource: .playlist)
            let currentFailure = model.profiles.first?.m3uStatus.errorSummary

            let snapshot = await repository.snapshot()
            XCTAssertEqual(snapshot.profiles.first?.m3uStatus, scenario.status, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed, scenario.name)
            XCTAssertNotNil(currentFailure, scenario.name)
            XCTAssertNotEqual(currentFailure, scenario.status.errorSummary, scenario.name)

            clock.value = startedAt.addingTimeInterval(3_600)
            let firstLaterReloadSucceeded = await model.reload()
            let secondLaterReloadSucceeded = await model.reload()
            XCTAssertTrue(firstLaterReloadSucceeded, scenario.name)
            XCTAssertTrue(secondLaterReloadSucceeded, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, currentFailure, scenario.name)
            XCTAssertEqual(model.activeProfile?.m3uStatus.lastAttemptAt, startedAt, scenario.name)
        }
    }

    func testNewerPlaylistLifecycleSuccessAutomaticallySupersedesFaultedManualOverlay() async throws {
        let firstStartedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let secondStartedAt = firstStartedAt.addingTimeInterval(60)
        let persistedAttemptID = UUID()
        let clock = AppModelTestClock(firstStartedAt)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: firstStartedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: firstStartedAt,
            state: .failed,
            errorSummary: "persisted P",
            attemptID: persistedAttemptID
        )
        let oldChannel = makeChannel(
            profileID: profile.id,
            url: "https://example.test/old",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [oldChannel]],
            failsRecordAttempt: true,
            failsRecordFailure: true
        )
        let changes = LibraryChangeSignal()
        let firstCoordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { clock.value }
        )
        let secondDownloader = AppModelRefreshDownloader(
            payload: Data("""
            #EXTM3U
            #EXTINF:-1,New lifecycle
            https://example.test/new-lifecycle
            """.utf8),
            gatesCompletion: true
        )
        let secondCoordinator = RefreshCoordinator(
            repository: repository,
            downloader: secondDownloader,
            now: { clock.value },
            onPersistedOutcome: { _, _ in
                await MainActor.run { changes.notify() }
            }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await firstCoordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            libraryChanges: changes,
            now: { clock.value }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        let firstAttemptID = try XCTUnwrap(model.profiles.first?.m3uStatus.attemptID)
        let firstFailure = try XCTUnwrap(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertNotEqual(firstAttemptID, persistedAttemptID)
        XCTAssertNotEqual(firstFailure, "persisted P")
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, firstStartedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        var snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus, profile.m3uStatus)

        let oldTruthReloaded = await model.reload()
        XCTAssertTrue(oldTruthReloaded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.attemptID, firstAttemptID)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, firstFailure)

        await repository.setRefreshPersistenceFaults(
            recordAttempt: false,
            recordFailure: false
        )
        clock.value = secondStartedAt
        let secondRefresh = Task {
            await secondCoordinator.refresh(
                profileID: profile.id,
                resources: [.playlist],
                trigger: .foreground
            )
        }
        await secondDownloader.waitUntilStarted()
        snapshot = await repository.snapshot()
        let secondAttemptID = try XCTUnwrap(snapshot.profiles.first?.m3uStatus.attemptID)
        XCTAssertNotEqual(secondAttemptID, firstAttemptID)
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus.lastAttemptAt, secondStartedAt)
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus.state, .refreshing)

        await repository.gateNextProfileRead()
        let automaticReload = expectation(description: "newer playlist truth is applied automatically")
        withObservationTracking {
            _ = model.profiles.first?.m3uStatus
        } onChange: {
            automaticReload.fulfill()
        }
        await secondDownloader.releaseCompletion()
        let secondOutcomes = await secondRefresh.value
        await repository.waitUntilProfileReadIsBlocked()
        XCTAssertEqual(model.profiles.first?.m3uStatus.attemptID, firstAttemptID)
        await repository.releaseProfileRead()
        await fulfillment(of: [automaticReload], timeout: 2)

        XCTAssertEqual(secondOutcomes.first?.attemptID, secondAttemptID)
        XCTAssertEqual(secondOutcomes.first?.succeeded, true)
        XCTAssertEqual(model.profiles.first?.m3uStatus.attemptID, secondAttemptID)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, secondStartedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastSuccessAt, secondStartedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertEqual(model.activeProfile?.m3uStatus, model.profiles.first?.m3uStatus)
        XCTAssertEqual(
            model.channels.map(\.streamURL),
            [URL(string: "https://example.test/new-lifecycle")!]
        )
        snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus, model.profiles.first?.m3uStatus)
        XCTAssertEqual(snapshot.playlistInstallCount, 1)
        XCTAssertEqual(
            snapshot.events.filter { $0 == .success(profile.id, .playlist) }.count,
            1
        )

        let explicitReloaded = await model.reload()
        XCTAssertTrue(explicitReloaded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.attemptID, secondAttemptID)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertEqual(
            model.channels.map(\.streamURL),
            [URL(string: "https://example.test/new-lifecycle")!]
        )
    }

    func testNewerEPGLifecycleFailureAutomaticallySupersedesOnlyMatchingOverlay() async throws {
        let firstStartedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let secondStartedAt = firstStartedAt.addingTimeInterval(60)
        let clock = AppModelTestClock(firstStartedAt)
        var active = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Active",
            now: firstStartedAt
        )
        var inactive = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Inactive",
            now: firstStartedAt
        )
        active.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: firstStartedAt.addingTimeInterval(-300),
            state: .failed,
            errorSummary: "active old playlist",
            attemptID: UUID()
        )
        active.epgStatus = ResourceRefreshStatus(
            lastAttemptAt: firstStartedAt.addingTimeInterval(-300),
            state: .failed,
            errorSummary: "active old EPG",
            attemptID: UUID()
        )
        inactive.epgStatus = ResourceRefreshStatus(
            lastAttemptAt: firstStartedAt.addingTimeInterval(-300),
            state: .failed,
            errorSummary: "inactive old EPG",
            attemptID: UUID()
        )
        let repository = RepositorySpy(
            profiles: [active, inactive],
            activeProfileID: active.id,
            failsRecordAttempt: true,
            failsRecordFailure: true
        )
        let changes = LibraryChangeSignal()
        let firstCoordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { clock.value }
        )
        let secondDownloader = AppModelRefreshDownloader(
            error: .cannotConnectToHost,
            gatesCompletion: true
        )
        let secondCoordinator = RefreshCoordinator(
            repository: repository,
            downloader: secondDownloader,
            now: { clock.value },
            onPersistedOutcome: { _, _ in
                await MainActor.run { changes.notify() }
            }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await firstCoordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            libraryChanges: changes,
            now: { clock.value }
        )

        await model.reload()
        await model.refresh(profileID: active.id, resource: .epg)
        await model.refresh(profileID: active.id, resource: .playlist)
        await model.refresh(profileID: inactive.id, resource: .epg)
        let activeEPGOverlay = try XCTUnwrap(
            model.profiles.first { $0.id == active.id }?.epgStatus
        )
        let activePlaylistOverlay = try XCTUnwrap(
            model.profiles.first { $0.id == active.id }?.m3uStatus
        )
        let inactiveEPGOverlay = try XCTUnwrap(
            model.profiles.first { $0.id == inactive.id }?.epgStatus
        )
        XCTAssertEqual(activeEPGOverlay.lastAttemptAt, firstStartedAt)
        XCTAssertEqual(activePlaylistOverlay.lastAttemptAt, firstStartedAt)
        XCTAssertEqual(inactiveEPGOverlay.lastAttemptAt, firstStartedAt)
        XCTAssertNotNil(activeEPGOverlay.attemptID)
        XCTAssertNotNil(activePlaylistOverlay.attemptID)
        XCTAssertNotNil(inactiveEPGOverlay.attemptID)

        var snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles.first { $0.id == active.id }?.epgStatus, active.epgStatus)
        XCTAssertEqual(snapshot.profiles.first { $0.id == active.id }?.m3uStatus, active.m3uStatus)
        XCTAssertEqual(snapshot.profiles.first { $0.id == inactive.id }?.epgStatus, inactive.epgStatus)

        await repository.setRefreshPersistenceFaults(
            recordAttempt: false,
            recordFailure: false
        )
        clock.value = secondStartedAt
        let secondRefresh = Task {
            await secondCoordinator.refresh(
                profileID: active.id,
                resources: [.epg],
                trigger: .background
            )
        }
        await secondDownloader.waitUntilStarted()
        snapshot = await repository.snapshot()
        let secondAttemptID = try XCTUnwrap(
            snapshot.profiles.first { $0.id == active.id }?.epgStatus.attemptID
        )
        XCTAssertNotEqual(secondAttemptID, activeEPGOverlay.attemptID)
        XCTAssertEqual(
            snapshot.profiles.first { $0.id == active.id }?.epgStatus.state,
            .refreshing
        )

        await repository.gateNextProfileRead()
        let automaticReload = expectation(description: "newer EPG truth is applied automatically")
        withObservationTracking {
            _ = model.profiles.first { $0.id == active.id }?.epgStatus
        } onChange: {
            automaticReload.fulfill()
        }
        await secondDownloader.releaseCompletion()
        let secondOutcomes = await secondRefresh.value
        await repository.waitUntilProfileReadIsBlocked()
        XCTAssertEqual(
            model.profiles.first { $0.id == active.id }?.epgStatus.attemptID,
            activeEPGOverlay.attemptID
        )
        await repository.releaseProfileRead()
        await fulfillment(of: [automaticReload], timeout: 2)

        let terminalMessage = try XCTUnwrap(secondOutcomes.first?.message)
        XCTAssertEqual(secondOutcomes.first?.attemptID, secondAttemptID)
        XCTAssertEqual(secondOutcomes.first?.succeeded, false)
        XCTAssertEqual(
            model.profiles.first { $0.id == active.id }?.epgStatus.attemptID,
            secondAttemptID
        )
        XCTAssertEqual(
            model.profiles.first { $0.id == active.id }?.epgStatus.lastAttemptAt,
            secondStartedAt
        )
        XCTAssertEqual(model.profiles.first { $0.id == active.id }?.epgStatus.state, .failed)
        XCTAssertEqual(
            model.profiles.first { $0.id == active.id }?.epgStatus.errorSummary,
            terminalMessage
        )
        XCTAssertEqual(model.activeProfile?.epgStatus.attemptID, secondAttemptID)
        XCTAssertEqual(
            model.profiles.first { $0.id == active.id }?.m3uStatus,
            activePlaylistOverlay
        )
        XCTAssertEqual(
            model.profiles.first { $0.id == inactive.id }?.epgStatus,
            inactiveEPGOverlay
        )
        snapshot = await repository.snapshot()
        XCTAssertEqual(
            snapshot.profiles.first { $0.id == active.id }?.epgStatus,
            model.profiles.first { $0.id == active.id }?.epgStatus
        )
        XCTAssertEqual(snapshot.profiles.first { $0.id == active.id }?.m3uStatus, active.m3uStatus)
        XCTAssertEqual(snapshot.profiles.first { $0.id == inactive.id }?.epgStatus, inactive.epgStatus)

        let explicitReloaded = await model.reload()
        XCTAssertTrue(explicitReloaded)
        XCTAssertEqual(model.profiles.first { $0.id == active.id }?.epgStatus.attemptID, secondAttemptID)
        XCTAssertEqual(
            model.profiles.first { $0.id == active.id }?.m3uStatus,
            activePlaylistOverlay
        )
        XCTAssertEqual(
            model.profiles.first { $0.id == inactive.id }?.epgStatus,
            inactiveEPGOverlay
        )
    }

    func testReloadLetsNewerDifferentFlightRefreshingSupersedeTerminalOverlay() async throws {
        let firstStartedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let secondStartedAt = firstStartedAt.addingTimeInterval(60)
        let clock = AppModelTestClock(firstStartedAt)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: firstStartedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: firstStartedAt.addingTimeInterval(-60),
            state: .failed,
            errorSummary: "old truth",
            attemptID: UUID()
        )
        let repository = RepositorySpy(
            profiles: [profile],
            failsRecordAttempt: true,
            failsRecordFailure: true
        )
        let firstCoordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { clock.value }
        )
        let secondDownloader = AppModelRefreshDownloader(
            payload: Data("""
            #EXTM3U
            #EXTINF:-1,Second flight
            https://example.test/second-flight
            """.utf8),
            gatesCompletion: true
        )
        let secondCoordinator = RefreshCoordinator(
            repository: repository,
            downloader: secondDownloader,
            now: { clock.value }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await firstCoordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            now: { clock.value }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        let firstAttemptID = try XCTUnwrap(model.profiles.first?.m3uStatus.attemptID)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)

        await repository.setRefreshPersistenceFaults(
            recordAttempt: false,
            recordFailure: false
        )
        clock.value = secondStartedAt
        let secondRefresh = Task {
            await secondCoordinator.refresh(
                profileID: profile.id,
                resources: [.playlist],
                trigger: .foreground
            )
        }
        await secondDownloader.waitUntilStarted()
        let refreshingSnapshot = await repository.snapshot()
        let secondAttemptID = try XCTUnwrap(refreshingSnapshot.profiles.first?.m3uStatus.attemptID)
        XCTAssertNotEqual(secondAttemptID, firstAttemptID)
        XCTAssertEqual(refreshingSnapshot.profiles.first?.m3uStatus.lastAttemptAt, secondStartedAt)
        XCTAssertEqual(refreshingSnapshot.profiles.first?.m3uStatus.state, .refreshing)

        let refreshingReloaded = await model.reload()

        XCTAssertTrue(refreshingReloaded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.attemptID, secondAttemptID)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, secondStartedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertEqual(model.activeProfile?.m3uStatus, model.profiles.first?.m3uStatus)

        await secondDownloader.releaseCompletion()
        let secondOutcomes = await secondRefresh.value
        XCTAssertEqual(secondOutcomes.first?.attemptID, secondAttemptID)
        XCTAssertEqual(secondOutcomes.first?.succeeded, true)
        let terminalReloaded = await model.reload()
        XCTAssertTrue(terminalReloaded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.attemptID, secondAttemptID)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
    }

    func testReloadKeepsTerminalOverlayOverSameFlightRefreshingTruth() async throws {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: startedAt
        )
        let repository = RepositorySpy(
            profiles: [profile],
            failsRecordFailure: true
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { startedAt }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await coordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            now: { startedAt }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        let overlayStatus = try XCTUnwrap(model.profiles.first?.m3uStatus)
        let snapshot = await repository.snapshot()
        XCTAssertNotNil(overlayStatus.attemptID)
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus.attemptID, overlayStatus.attemptID)
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertEqual(overlayStatus.state, .failed)
        XCTAssertNotNil(overlayStatus.errorSummary)

        let explicitReloaded = await model.reload()

        XCTAssertTrue(explicitReloaded)
        XCTAssertEqual(model.profiles.first?.m3uStatus, overlayStatus)
        XCTAssertEqual(model.activeProfile?.m3uStatus, overlayStatus)
    }

    func testBackToBackFaultedCoordinatorFlightsKeepTheSecondFailureOverlay() async {
        let firstStartedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let secondStartedAt = firstStartedAt.addingTimeInterval(60)
        let priorAt = firstStartedAt.addingTimeInterval(-600)
        let clock = AppModelTestClock(firstStartedAt)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: firstStartedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: priorAt,
            lastSuccessAt: priorAt,
            state: .succeeded
        )
        let repository = RepositorySpy(
            profiles: [profile],
            failsRecordAttempt: true,
            failsRecordFailure: true
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { clock.value }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await coordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            now: { clock.value }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        let firstFailure = model.profiles.first?.m3uStatus.errorSummary
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, firstStartedAt)
        XCTAssertNotNil(firstFailure)

        clock.value = secondStartedAt
        await model.refresh(profileID: profile.id, resource: .playlist)
        let secondFailure = model.profiles.first?.m3uStatus.errorSummary
        let laterReloadSucceeded = await model.reload()

        XCTAssertTrue(laterReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, secondStartedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertNotNil(secondFailure)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, secondFailure)
        XCTAssertEqual(model.activeProfile?.m3uStatus.lastAttemptAt, secondStartedAt)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus, profile.m3uStatus)
    }

    func testFaultedCoordinatorFlightKeepsOverlayWhenModelBaselineLagsRepositoryTerminal() async {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let priorAt = startedAt.addingTimeInterval(-600)
        var modelBaseline = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: startedAt
        )
        modelBaseline.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: priorAt.addingTimeInterval(-60),
            state: .failed,
            errorSummary: "model baseline"
        )
        var repositoryTerminal = modelBaseline
        repositoryTerminal.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: priorAt,
            lastSuccessAt: priorAt,
            state: .succeeded
        )
        let repository = RepositorySpy(
            profiles: [modelBaseline],
            failsRecordAttempt: true,
            failsRecordFailure: true
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { startedAt }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await coordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            now: { startedAt }
        )

        await model.reload()
        await repository.replaceProfiles([repositoryTerminal], activeProfileID: repositoryTerminal.id)
        await model.refresh(profileID: modelBaseline.id, resource: .playlist)
        let currentFailure = model.profiles.first?.m3uStatus.errorSummary
        let laterReloadSucceeded = await model.reload()

        XCTAssertTrue(laterReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertNotNil(currentFailure)
        XCTAssertNotEqual(currentFailure, modelBaseline.m3uStatus.errorSummary)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, currentFailure)
        XCTAssertEqual(model.activeProfile?.m3uStatus.lastAttemptAt, startedAt)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles.first?.m3uStatus, repositoryTerminal.m3uStatus)
    }

    func testSynthesizedFailureOverlaysSurviveOldTerminalRepositoryTruth() async {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let priorAt = startedAt.addingTimeInterval(-600)
        let scenarios: [(name: String, status: ResourceRefreshStatus, outcomes: [RefreshOutcome])] = [
            (
                "empty over succeeded",
                ResourceRefreshStatus(
                    lastAttemptAt: priorAt,
                    lastSuccessAt: priorAt,
                    state: .succeeded
                ),
                []
            ),
            (
                "wrong resource over failed",
                ResourceRefreshStatus(
                    lastAttemptAt: priorAt,
                    state: .failed,
                    errorSummary: "prior terminal failure"
                ),
                [RefreshOutcome(resource: .epg, succeeded: true, message: nil)]
            )
        ]

        for scenario in scenarios {
            var profile = makeProfile(
                id: "00000000-0000-0000-0000-000000000001",
                name: "Source",
                now: startedAt
            )
            profile.m3uStatus = scenario.status
            let repository = RepositorySpy(profiles: [profile])
            let model = AppModel(
                repository: repository,
                refresh: { _, _, _ in scenario.outcomes },
                now: { startedAt }
            )

            await model.reload()
            await model.refresh(profileID: profile.id, resource: .playlist)
            let laterReloadSucceeded = await model.reload()
            XCTAssertTrue(laterReloadSucceeded, scenario.name)

            XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed, scenario.name)
            XCTAssertEqual(
                model.profiles.first?.m3uStatus.errorSummary,
                "刷新未完成，请稍后重试。",
                scenario.name
            )
            XCTAssertEqual(model.activeProfile?.m3uStatus.lastAttemptAt, startedAt, scenario.name)
        }
    }

    func testCurrentCancellationOverlaySurvivesOldTerminalRepositoryTruth() async {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let priorAt = startedAt.addingTimeInterval(-600)
        let clock = AppModelTestClock(startedAt)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: startedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: priorAt,
            lastSuccessAt: priorAt,
            state: .succeeded
        )
        let repository = RepositorySpy(profiles: [profile])
        let gate = AppModelConcurrentRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await gate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: clock.value,
                    recordsAttempt: false
                )
            },
            now: { clock.value }
        )

        await model.reload()
        let refresh = Task { await model.refresh(profileID: profile.id, resource: .playlist) }
        await gate.waitUntilStarted(resource: .playlist, ordinal: 1)
        refresh.cancel()
        await gate.release(resource: .playlist, ordinal: 1, result: .cancellation)
        await refresh.value

        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。")
        clock.value = startedAt.addingTimeInterval(3_600)
        let firstLaterReloadSucceeded = await model.reload()
        let secondLaterReloadSucceeded = await model.reload()
        XCTAssertTrue(firstLaterReloadSucceeded)
        XCTAssertTrue(secondLaterReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, startedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。")
        XCTAssertEqual(model.activeProfile?.m3uStatus.lastAttemptAt, startedAt)
    }

    func testJoinedOlderFlightSuccessReplacesManualCancellationOverlay() async {
        let flightStartedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let manualStartedAt = flightStartedAt.addingTimeInterval(60)
        let priorAt = flightStartedAt.addingTimeInterval(-600)
        let scenarios: [(name: String, loadModelAfterFlightStarts: Bool)] = [
            ("refreshing baseline", true),
            ("prior terminal baseline", false)
        ]

        for scenario in scenarios {
            let clock = AppModelTestClock(flightStartedAt)
            var profile = makeProfile(
                id: "00000000-0000-0000-0000-000000000001",
                name: "Source",
                now: flightStartedAt
            )
            profile.m3uStatus = ResourceRefreshStatus(
                lastAttemptAt: priorAt,
                state: .failed,
                errorSummary: "prior terminal failure"
            )
            let repository = RepositorySpy(profiles: [profile])
            let downloader = AppModelRefreshDownloader(
                payload: Data("""
                #EXTM3U
                #EXTINF:-1,Joined flight
                https://example.test/joined
                """.utf8),
                gatesCompletion: true
            )
            let (waiterRegistrations, waiterRegistrationContinuation) = AsyncStream.makeStream(
                of: RefreshCoordinator.WaiterRegistration.self,
                bufferingPolicy: .unbounded
            )
            defer { waiterRegistrationContinuation.finish() }
            var waiterRegistrationIterator = waiterRegistrations.makeAsyncIterator()
            let coordinator = RefreshCoordinator(
                repository: repository,
                downloader: downloader,
                now: { clock.value },
                waiterRegistrationObserver: { registration in
                    waiterRegistrationContinuation.yield(registration)
                }
            )
            let model = AppModel(
                repository: repository,
                refresh: { profileID, resources, trigger in
                    await coordinator.refresh(
                        profileID: profileID,
                        resources: resources,
                        trigger: trigger
                    )
                },
                now: { clock.value }
            )

            if !scenario.loadModelAfterFlightStarts {
                await model.reload()
            }
            let originalWaiter = Task {
                await coordinator.refresh(
                    profileID: profile.id,
                    resources: [.playlist],
                    trigger: .foreground
                )
            }
            await downloader.waitUntilStarted()
            guard let originalRegistration = await waiterRegistrationIterator.next() else {
                XCTFail("Missing original waiter registration", file: #filePath, line: #line)
                return
            }
            XCTAssertEqual(originalRegistration.profileID, profile.id, scenario.name)
            XCTAssertEqual(originalRegistration.resource, .playlist, scenario.name)
            XCTAssertEqual(originalRegistration.waiterCount, 1, scenario.name)
            let inFlightSnapshot = await repository.snapshot()
            XCTAssertEqual(inFlightSnapshot.profiles.first?.m3uStatus.state, .refreshing, scenario.name)
            XCTAssertEqual(
                inFlightSnapshot.events.filter { $0 == .attempt(profile.id, .playlist) }.count,
                1,
                scenario.name
            )

            if scenario.loadModelAfterFlightStarts {
                await model.reload()
                XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing, scenario.name)
                XCTAssertEqual(
                    model.profiles.first?.m3uStatus.lastAttemptAt,
                    flightStartedAt,
                    scenario.name
                )
            } else {
                XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed, scenario.name)
            }

            clock.value = manualStartedAt
            let manualWaiter = Task {
                await model.refresh(profileID: profile.id, resource: .playlist)
            }
            await eventually {
                model.profiles.first?.m3uStatus.lastAttemptAt == manualStartedAt
                    && model.profiles.first?.m3uStatus.state == .refreshing
            }
            guard let joinedRegistration = await waiterRegistrationIterator.next() else {
                XCTFail("Missing joined waiter registration", file: #filePath, line: #line)
                return
            }
            XCTAssertEqual(joinedRegistration.profileID, profile.id, scenario.name)
            XCTAssertEqual(joinedRegistration.resource, .playlist, scenario.name)
            XCTAssertEqual(joinedRegistration.flightID, originalRegistration.flightID, scenario.name)
            XCTAssertEqual(joinedRegistration.waiterCount, 2, scenario.name)
            manualWaiter.cancel()
            await manualWaiter.value

            XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, manualStartedAt, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。", scenario.name)
            XCTAssertEqual(
                model.profiles.first?.m3uStatus.attemptID,
                originalRegistration.flightID,
                scenario.name
            )

            await downloader.releaseCompletion()
            let originalOutcomes = await originalWaiter.value
            XCTAssertEqual(originalOutcomes.first?.succeeded, true, scenario.name)
            XCTAssertEqual(originalOutcomes.first?.attemptID, originalRegistration.flightID, scenario.name)
            let successSnapshot = await repository.snapshot()
            XCTAssertEqual(successSnapshot.profiles.first?.m3uStatus.state, .succeeded, scenario.name)
            XCTAssertEqual(
                successSnapshot.profiles.first?.m3uStatus.lastSuccessAt,
                flightStartedAt,
                scenario.name
            )
            XCTAssertEqual(
                successSnapshot.events.filter { $0 == .attempt(profile.id, .playlist) }.count,
                1,
                scenario.name
            )
            XCTAssertEqual(
                successSnapshot.events.filter { $0 == .success(profile.id, .playlist) }.count,
                1,
                scenario.name
            )

            let firstReloadSucceeded = await model.reload()
            let secondReloadSucceeded = await model.reload()
            XCTAssertTrue(firstReloadSucceeded, scenario.name)
            XCTAssertTrue(secondReloadSucceeded, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.lastSuccessAt, flightStartedAt, scenario.name)
            XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary, scenario.name)
            XCTAssertEqual(model.activeProfile?.m3uStatus.state, .succeeded, scenario.name)
        }
    }

    func testJoinedOlderFlightFailureReplacesManualCancellationOverlay() async {
        let flightStartedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let manualStartedAt = flightStartedAt.addingTimeInterval(60)
        let clock = AppModelTestClock(flightStartedAt)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: flightStartedAt
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: flightStartedAt.addingTimeInterval(-600),
            state: .failed,
            errorSummary: "prior terminal failure"
        )
        let repository = RepositorySpy(profiles: [profile])
        let downloader = AppModelRefreshDownloader(
            payload: Data("not an m3u".utf8),
            gatesCompletion: true
        )
        let (waiterRegistrations, waiterRegistrationContinuation) = AsyncStream.makeStream(
            of: RefreshCoordinator.WaiterRegistration.self,
            bufferingPolicy: .unbounded
        )
        defer { waiterRegistrationContinuation.finish() }
        var waiterRegistrationIterator = waiterRegistrations.makeAsyncIterator()
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: downloader,
            now: { clock.value },
            waiterRegistrationObserver: { registration in
                waiterRegistrationContinuation.yield(registration)
            }
        )
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, trigger in
                await coordinator.refresh(
                    profileID: profileID,
                    resources: resources,
                    trigger: trigger
                )
            },
            now: { clock.value }
        )

        await model.reload()
        let originalWaiter = Task {
            await coordinator.refresh(
                profileID: profile.id,
                resources: [.playlist],
                trigger: .foreground
            )
        }
        await downloader.waitUntilStarted()
        guard let originalRegistration = await waiterRegistrationIterator.next() else {
            XCTFail("Missing original waiter registration", file: #filePath, line: #line)
            return
        }
        XCTAssertEqual(originalRegistration.profileID, profile.id)
        XCTAssertEqual(originalRegistration.resource, .playlist)
        XCTAssertEqual(originalRegistration.waiterCount, 1)
        clock.value = manualStartedAt
        let manualWaiter = Task {
            await model.refresh(profileID: profile.id, resource: .playlist)
        }
        await eventually {
            model.profiles.first?.m3uStatus.lastAttemptAt == manualStartedAt
                && model.profiles.first?.m3uStatus.state == .refreshing
        }
        guard let joinedRegistration = await waiterRegistrationIterator.next() else {
            XCTFail("Missing joined waiter registration", file: #filePath, line: #line)
            return
        }
        XCTAssertEqual(joinedRegistration.profileID, profile.id)
        XCTAssertEqual(joinedRegistration.resource, .playlist)
        XCTAssertEqual(joinedRegistration.flightID, originalRegistration.flightID)
        XCTAssertEqual(joinedRegistration.waiterCount, 2)
        manualWaiter.cancel()
        await manualWaiter.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。")
        XCTAssertEqual(model.profiles.first?.m3uStatus.attemptID, originalRegistration.flightID)

        await downloader.releaseCompletion()
        let originalOutcomes = await originalWaiter.value
        let terminalMessage = originalOutcomes.first?.message
        XCTAssertEqual(originalOutcomes.first?.succeeded, false)
        XCTAssertNotNil(terminalMessage)
        XCTAssertNotEqual(terminalMessage, "刷新已取消。")
        XCTAssertEqual(originalOutcomes.first?.attemptID, originalRegistration.flightID)

        let firstReloadSucceeded = await model.reload()
        let secondReloadSucceeded = await model.reload()
        XCTAssertTrue(firstReloadSucceeded)
        XCTAssertTrue(secondReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, flightStartedAt)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, terminalMessage)
        XCTAssertEqual(model.activeProfile?.m3uStatus.errorSummary, terminalMessage)
    }

    func testManualRefreshTerminalOverlayKeepsOriginalCompletionTimeAcrossLaterReloads() async {
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = AppModelTestClock(startedAt)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: startedAt)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                try? await repository.recordAttempt(
                    profileID: profileID,
                    resource: .playlist,
                    at: clock.value
                )
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: true, message: nil)
                }
            },
            now: { clock.value }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        let originalCompletion = model.profiles.first?.m3uStatus.lastSuccessAt
        XCTAssertEqual(originalCompletion, startedAt)
        clock.value = startedAt.addingTimeInterval(3_600)

        let laterReloadSucceeded = await model.reload()

        XCTAssertTrue(laterReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastSuccessAt, originalCompletion)
        XCTAssertEqual(model.activeProfile?.m3uStatus.lastSuccessAt, originalCompletion)
    }

    func testWinningOverlappingReloadAppliesTerminalOverlayWhenRefreshReloadIsSuperseded() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                try? await repository.recordAttempt(
                    profileID: profileID,
                    resource: .playlist,
                    at: now
                )
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: false, message: "returned failure")
                }
            },
            now: { now }
        )

        await model.reload()
        await repository.gateNextProfileRead()
        let refreshTask = Task {
            await model.refresh(profileID: profile.id, resource: .playlist)
        }
        await repository.waitUntilProfileReadIsBlocked()

        let winningReloadSucceeded = await model.reload()
        await repository.releaseProfileRead()
        await refreshTask.value

        XCTAssertTrue(winningReloadSucceeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "returned failure")
        XCTAssertEqual(model.activeProfile?.m3uStatus.state, .failed)
    }

    func testTerminalRepositoryTruthClearsRefreshOverlaysForBothResources() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let terminalAt = now.addingTimeInterval(60)
        let nextAttemptAt = terminalAt.addingTimeInterval(60)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                for resource in resources {
                    try? await repository.recordAttempt(
                        profileID: profileID,
                        resource: resource,
                        at: now
                    )
                }
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: false, message: "overlay failure")
                }
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        await model.refresh(profileID: profile.id, resource: .epg)
        try await repository.recordSuccess(
            profileID: profile.id,
            resource: .playlist,
            at: terminalAt
        )
        try await repository.recordFailure(
            profileID: profile.id,
            resource: .epg,
            summary: "persisted failure",
            at: terminalAt
        )

        _ = await model.reload()
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertEqual(model.profiles.first?.m3uStatus.lastSuccessAt, terminalAt)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.epgStatus.errorSummary, "persisted failure")

        try await repository.recordAttempt(
            profileID: profile.id,
            resource: .playlist,
            at: nextAttemptAt
        )
        try await repository.recordAttempt(
            profileID: profile.id,
            resource: .epg,
            at: nextAttemptAt
        )
        _ = await model.reload()

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .refreshing)
    }

    func testMissingProfileClearsTerminalOverlayBeforeSameIdentityReappears() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                try? await repository.recordAttempt(
                    profileID: profileID,
                    resource: .playlist,
                    at: now
                )
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: false, message: "overlay failure")
                }
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        try await repository.deleteProfile(id: profile.id)
        _ = await model.reload()
        XCTAssertTrue(model.profiles.isEmpty)

        var reappeared = profile
        reappeared.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: now.addingTimeInterval(60),
            state: .refreshing
        )
        await repository.replaceProfiles([reappeared], activeProfileID: profile.id)
        _ = await model.reload()

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)
    }

    func testNewManualAttemptClearsOlderTerminalOverlayBeforeItCompletes() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let refreshGate = AppModelManualRefreshGate()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await refreshGate.outcomes(
                    repository: repository,
                    profileID: profileID,
                    resources: resources,
                    now: now
                )
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)

        let secondRefresh = Task {
            await model.refresh(profileID: profile.id, resource: .playlist)
        }
        await refreshGate.waitUntilSecondAttemptStarts()
        _ = await model.reload()

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .refreshing)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)

        await refreshGate.releaseSecondAttempt()
        await secondRefresh.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
    }

    func testManualRefreshKeepsTerminalRepositoryTruthOverReturnedOutcome() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                try? await repository.recordSuccess(
                    profileID: profileID,
                    resource: .playlist,
                    at: now
                )
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: false, message: "stale returned failure")
                }
            },
            now: { now }
        )

        await model.reload()
        await model.refresh(profileID: profile.id, resource: .playlist)

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertNil(model.profiles.first?.m3uStatus.errorSummary)
        XCTAssertEqual(model.activeProfile?.m3uStatus.state, .succeeded)
    }

    func testRefreshStatusPresentationUsesStateSpecificTimestampsAndExactChineseLabels() {
        let attempt = Date(timeIntervalSince1970: 2_000_000_000)
        let success = Date(timeIntervalSince1970: 1_900_000_000)
        let never = ResourceRefreshStatus(
            lastAttemptAt: attempt,
            lastSuccessAt: success,
            state: .never
        )
        let refreshing = ResourceRefreshStatus(
            lastAttemptAt: attempt,
            lastSuccessAt: success,
            state: .refreshing
        )
        let succeeded = ResourceRefreshStatus(
            lastAttemptAt: attempt,
            lastSuccessAt: success,
            state: .succeeded
        )
        let failed = ResourceRefreshStatus(
            lastAttemptAt: attempt,
            lastSuccessAt: success,
            state: .failed,
            errorSummary: "failed"
        )
        let attemptText = attempt.formatted(date: .abbreviated, time: .shortened)
        let successText = success.formatted(date: .abbreviated, time: .shortened)

        XCTAssertNil(ResourceRefreshStatusPresentation.timestamp(for: never))
        XCTAssertEqual(ResourceRefreshStatusPresentation.text(for: never), "尚未刷新")
        XCTAssertEqual(ResourceRefreshStatusPresentation.timestamp(for: refreshing), attempt)
        XCTAssertEqual(
            ResourceRefreshStatusPresentation.text(for: refreshing),
            "正在刷新 · \(attemptText)"
        )
        XCTAssertEqual(ResourceRefreshStatusPresentation.timestamp(for: succeeded), success)
        XCTAssertEqual(
            ResourceRefreshStatusPresentation.text(for: succeeded),
            "刷新成功 · \(successText)"
        )
        XCTAssertEqual(ResourceRefreshStatusPresentation.timestamp(for: failed), attempt)
        XCTAssertEqual(
            ResourceRefreshStatusPresentation.text(for: failed),
            "刷新失败 · \(attemptText)"
        )
        XCTAssertFalse(ResourceRefreshStatusPresentation.text(for: failed).contains(successText))
    }

    func testAutomaticRefreshStartSignalUpdatesStatusWithoutReloadingLibrary() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: now
        )
        profile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: now.addingTimeInterval(-600),
            lastSuccessAt: now.addingTimeInterval(-3_600),
            state: .failed,
            errorSummary: "playlist failure"
        )
        profile.epgStatus = ResourceRefreshStatus(
            lastAttemptAt: now.addingTimeInterval(-600),
            lastSuccessAt: now.addingTimeInterval(-3_600),
            state: .succeeded
        )
        let repository = RepositorySpy(profiles: [profile])
        let changes = LibraryChangeSignal()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            now: { now }
        )

        await model.reload()
        let profileReadsBeforeStart = await repository.snapshot().profileLookupCount

        changes.notifyRefreshStarted(profileID: profile.id, resource: .epg)
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(model.profiles.first?.m3uStatus, profile.m3uStatus)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .refreshing)
        XCTAssertEqual(model.profiles.first?.epgStatus.lastAttemptAt, now)
        XCTAssertNil(model.profiles.first?.epgStatus.errorSummary)
        XCTAssertEqual(model.activeProfile?.epgStatus.state, .refreshing)
        XCTAssertEqual(changes.generation, 0)
        let profileReadsAfterStart = await repository.snapshot().profileLookupCount
        XCTAssertEqual(profileReadsAfterStart, profileReadsBeforeStart)
    }

    func testPersistenceTerminalSignalReloadsVisibleChannelsWithoutManualUIAction() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let oldChannel = makeChannel(profileID: profile.id, url: "https://example.test/old", tvgID: nil, order: 0)
        let refreshedChannel = makeChannel(profileID: profile.id, url: "https://example.test/new", tvgID: nil, order: 0)
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [oldChannel]]
        )
        let changes = LibraryChangeSignal()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            now: { now }
        )
        let downloader = AppModelRefreshDownloader(
            payload: Data("""
            #EXTM3U
            #EXTINF:-1,Refreshed
            https://example.test/new
            """.utf8)
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: downloader,
            now: { now },
            onPersistedOutcome: { _, _ in
                await MainActor.run { changes.notify() }
            }
        )

        await model.reload()
        _ = await coordinator.refresh(profileID: profile.id, resources: [.playlist], trigger: .foreground)
        await eventually { model.channels.map(\.streamURL) == [refreshedChannel.streamURL] }

        XCTAssertEqual(model.channels.map(\.streamURL), [refreshedChannel.streamURL])
    }

    func testEPGPersistenceTerminalSignalUpdatesProgrammesWithoutRereadingChannels() async {
        let now = Date(timeIntervalSince1970: 1_787_486_400)
        let profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: now
        )
        let channel = makeChannel(
            profileID: profile.id,
            url: "https://example.test/live",
            tvgID: "epg",
            order: 0
        )
        let oldProgramme = Programme(
            id: "old",
            xmltvChannelID: "epg",
            start: now.addingTimeInterval(-600),
            stop: now.addingTimeInterval(600),
            title: "Old EPG",
            subtitle: nil,
            summary: nil,
            categories: []
        )
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [channel]],
            epgChannels: [
                profile.id: [
                    EPGChannel(id: "epg", displayNames: ["Channel"], iconURL: nil)
                ]
            ],
            programmes: [profile.id: [oldProgramme]]
        )
        let changes = LibraryChangeSignal()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            now: { now }
        )
        let downloader = AppModelRefreshDownloader(
            payload: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <tv>
              <channel id="epg"><display-name>Channel</display-name></channel>
              <programme channel="epg" start="20260823110000 +0000" stop="20260823130000 +0000">
                <title>Refreshed EPG</title>
              </programme>
            </tv>
            """.utf8)
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: downloader,
            now: { now },
            onPersistedOutcome: { profileID, outcome in
                await MainActor.run {
                    changes.notify(profileID: profileID, resource: outcome.resource)
                }
            }
        )

        await model.reload()
        let channelReadsBeforeRefresh = await repository.snapshot().channelLookupCount

        let outcomes = await coordinator.refresh(
            profileID: profile.id,
            resources: [.epg],
            trigger: .foreground
        )
        await eventually {
            model.programmesByChannelID[channel.id]?.first?.title == "Refreshed EPG"
        }

        let snapshot = await repository.snapshot()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.resource, .epg)
        XCTAssertEqual(outcomes.first?.succeeded, true)
        XCTAssertNil(outcomes.first?.message)
        XCTAssertNotNil(outcomes.first?.attemptID)
        XCTAssertEqual(snapshot.channelLookupCount, channelReadsBeforeRefresh)
        XCTAssertEqual(model.channels, [channel])
        XCTAssertEqual(model.programmesByChannelID[channel.id]?.map(\.title), ["Refreshed EPG"])
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .succeeded)
    }

    func testLargePersistedPlaylistRefreshPublishesTenThousandChannelsWithOneChannelRead() async {
        let now = Date(timeIntervalSince1970: 1_787_486_400)
        let profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: now
        )
        let oldChannel = makeChannel(
            profileID: profile.id,
            url: "https://example.test/old",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [oldChannel]]
        )
        let changes = LibraryChangeSignal()
        let (processedChanges, processedChangeContinuation) = AsyncStream.makeStream(
            of: AppModel.ProcessedLibraryChange.self,
            bufferingPolicy: .unbounded
        )
        defer { processedChangeContinuation.finish() }
        var processedChangeIterator = processedChanges.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            libraryChangeProcessed: { processing in
                processedChangeContinuation.yield(processing)
            },
            now: { now }
        )

        let channelCount = 10_000
        var playlistLines = ["#EXTM3U"]
        playlistLines.reserveCapacity(channelCount * 2 + 1)
        for index in 0..<channelCount {
            playlistLines.append(
                "#EXTINF:-1 tvg-id=\"epg-\(index)\" group-title=\"Group \(index % 100)\",Channel \(index)"
            )
            playlistLines.append("https://example.test/live/\(index)")
        }
        let downloader = AppModelRefreshDownloader(
            payload: Data(playlistLines.joined(separator: "\n").utf8)
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: downloader,
            now: { now },
            onPersistedOutcome: { profileID, outcome in
                await MainActor.run {
                    changes.notify(profileID: profileID, resource: outcome.resource)
                }
            }
        )

        await model.reload()
        let channelReadsBeforeRefresh = await repository.snapshot().channelLookupCount

        let outcomes = await coordinator.refresh(
            profileID: profile.id,
            resources: [.playlist],
            trigger: .foreground
        )
        let processing = await processedChangeIterator.next()

        let snapshot = await repository.snapshot()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.resource, .playlist)
        XCTAssertEqual(outcomes.first?.succeeded, true)
        XCTAssertEqual(processing?.generation, changes.generation)
        XCTAssertEqual(processing?.reloadApplied, true)
        XCTAssertEqual(snapshot.playlistInstallCount, 1)
        XCTAssertEqual(snapshot.channelLookupCount, channelReadsBeforeRefresh + 1)
        XCTAssertEqual(model.channels.count, channelCount)
        XCTAssertEqual(model.channels.first?.displayName, "Channel 0")
        XCTAssertEqual(model.channels.first?.order, 0)
        XCTAssertEqual(model.channels.last?.displayName, "Channel 9999")
        XCTAssertEqual(model.channels.last?.order, channelCount - 1)
    }

    func testPersistenceTerminalSignalReloadsVisibleFailureStatus() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let changes = LibraryChangeSignal()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            now: { now }
        )
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: AppModelRefreshDownloader(error: .cannotConnectToHost),
            now: { now },
            onPersistedOutcome: { _, _ in
                await MainActor.run { changes.notify() }
            }
        )

        await model.reload()
        _ = await coordinator.refresh(profileID: profile.id, resources: [.playlist], trigger: .background)
        await eventually { model.profiles.first?.m3uStatus.state == .failed }

        XCTAssertNotNil(model.profiles.first?.m3uStatus.errorSummary)
    }

    func testCancelledManualRefreshAutomaticallyReconcilesTerminalNotificationStartedBeforeOverlay() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let scenarios: [(name: String, payload: Data?, error: URLError.Code?, state: RefreshState)] = [
            (
                "success",
                Data("""
                #EXTM3U
                #EXTINF:-1,Refreshed
                https://example.test/refreshed
                """.utf8),
                nil,
                .succeeded
            ),
            ("failure", nil, .cannotConnectToHost, .failed),
        ]

        for scenario in scenarios {
            let profile = makeProfile(
                id: "00000000-0000-0000-0000-000000000001",
                name: "Source",
                now: now
            )
            let repository = RepositorySpy(profiles: [profile])
            let changes = LibraryChangeSignal()
            let persistedOutcomeGate = AppModelPersistedOutcomeGate()
            let downloader = AppModelRefreshDownloader(
                payload: scenario.payload,
                error: scenario.error,
                gatesCompletion: true
            )
            let coordinator = RefreshCoordinator(
                repository: repository,
                downloader: downloader,
                now: { now },
                onPersistedOutcome: { _, _ in
                    await MainActor.run { changes.notify() }
                    await persistedOutcomeGate.suspend()
                }
            )
            let model = AppModel(
                repository: repository,
                refresh: { profileID, resources, trigger in
                    await coordinator.refresh(
                        profileID: profileID,
                        resources: resources,
                        trigger: trigger
                    )
                },
                libraryChanges: changes,
                now: { now }
            )

            await model.reload()
            let manualRefresh = Task {
                await model.refresh(profileID: profile.id, resource: .playlist)
            }
            await downloader.waitUntilStarted()
            await repository.gateNextProfileRead()
            await downloader.releaseCompletion()
            await persistedOutcomeGate.waitUntilSuspended()
            await repository.waitUntilProfileReadIsBlocked()
            manualRefresh.cancel()
            await manualRefresh.value
            let persistedTerminal = await repository.snapshot().profiles.first?.m3uStatus
            XCTAssertNotNil(model.profiles.first?.m3uStatus.attemptID, scenario.name)
            XCTAssertEqual(
                model.profiles.first?.m3uStatus.attemptID,
                persistedTerminal?.attemptID,
                scenario.name
            )

            await persistedOutcomeGate.release()
            await repository.releaseProfileRead()
            await eventually {
                model.profiles.first?.m3uStatus.state == scenario.state
                    && model.profiles.first?.m3uStatus.errorSummary != "刷新已取消。"
            }
            XCTAssertEqual(model.profiles.first?.m3uStatus.state, scenario.state, scenario.name)
            XCTAssertEqual(model.activeProfile?.m3uStatus.state, scenario.state, scenario.name)
            let snapshot = await repository.snapshot()
            XCTAssertEqual(snapshot.profiles.first?.m3uStatus.state, scenario.state, scenario.name)
        }
    }

    func testCancelledLifecycleReloadOccursOnlyAfterTerminalFailureIsPersisted() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let changes = LibraryChangeSignal()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            now: { now }
        )
        let downloader = AppModelRefreshDownloader(gatesCancellation: true)
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: downloader,
            now: { now },
            onPersistedOutcome: { _, _ in
                await MainActor.run { changes.notify() }
            }
        )

        await model.reload()
        let lifecycleTask = Task {
            await coordinator.refresh(profileID: profile.id, resources: [.playlist], trigger: .background)
        }
        await downloader.waitUntilStarted()
        lifecycleTask.cancel()
        let promptOutcomes = await lifecycleTask.value
        let promptOutcome = try XCTUnwrap(promptOutcomes.first)
        XCTAssertEqual(promptOutcome.message, "刷新已取消。")
        await downloader.waitUntilCancellationIsBlocked()

        XCTAssertEqual(changes.generation, 0)
        XCTAssertNotEqual(model.profiles.first?.m3uStatus.state, .refreshing)

        await downloader.releaseCancellation()
        await eventually { model.profiles.first?.m3uStatus.state == .failed }

        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。")
        let snapshot = await repository.snapshot()
        XCTAssertFalse(snapshot.profileReadPlaylistStates.contains(.refreshing))
    }

    func testLibraryChangeObservationDoesNotRetainModelAndStaleReloadCannotOverwriteNewerState() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let oldChannel = makeChannel(profileID: profile.id, url: "https://example.test/old", tvgID: nil, order: 0)
        let newestChannel = makeChannel(profileID: profile.id, url: "https://example.test/newest", tvgID: nil, order: 0)
        let repository = RepositorySpy(profiles: [profile], channels: [profile.id: [oldChannel]])
        let changes = LibraryChangeSignal()
        var model: AppModel? = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            now: { now }
        )
        weak let weakModel = model

        await model?.reload()
        await repository.gateNextChannelRead()
        changes.notify()
        await repository.waitUntilChannelReadIsBlocked()
        await repository.replaceChannels(profileID: profile.id, channels: [newestChannel])
        await model?.reload()
        await repository.releaseChannelRead()
        await eventually { model?.channels == [newestChannel] && model?.isLoading == false }
        XCTAssertEqual(model?.channels, [newestChannel])

        model = nil
        await eventually { weakModel == nil }
        XCTAssertNil(weakModel)
    }

    func testInitialLoadSettleWaitsForWinningReloadAfterCallerIsSuperseded() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Source",
            now: now
        )
        let channel = makeChannel(
            profileID: profile.id,
            url: "https://example.test/live",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [channel]]
        )
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextChannelRead()
        let supersededReload = Task { await model.reload() }
        await repository.waitUntilChannelReadIsBlocked()

        await repository.gateNextProfileRead()
        let winningReload = Task { await model.reload() }
        await repository.waitUntilProfileReadIsBlocked()
        await repository.releaseChannelRead()
        let supersededReloadApplied = await supersededReload.value
        XCTAssertFalse(supersededReloadApplied)

        let settleProbe = LibraryReloadSettleProbe()
        let settle = Task {
            await model.waitForLibraryReloadsToSettle()
            await settleProbe.recordCompletion()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        let settledBeforeWinningReload = await settleProbe.isComplete
        XCTAssertFalse(settledBeforeWinningReload)

        await repository.releaseProfileRead()
        let winningReloadApplied = await winningReload.value
        XCTAssertTrue(winningReloadApplied)
        await settle.value
        let settledAfterWinningReload = await settleProbe.isComplete
        XCTAssertTrue(settledAfterWinningReload)
    }

    func testLibraryChangeNotificationsDuringReloadCoalesceToOneLatestFollowUp() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channel = makeChannel(profileID: profile.id, url: "https://example.test/live", tvgID: nil, order: 0)
        let repository = RepositorySpy(profiles: [profile], channels: [profile.id: [channel]])
        let changes = LibraryChangeSignal()
        let (processedChanges, processedChangeContinuation) = AsyncStream.makeStream(
            of: AppModel.ProcessedLibraryChange.self,
            bufferingPolicy: .unbounded
        )
        defer { processedChangeContinuation.finish() }
        var processedChangeIterator = processedChanges.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
            libraryChangeProcessed: { processing in
                processedChangeContinuation.yield(processing)
            },
            now: { now }
        )

        await model.reload()
        await repository.gateNextChannelRead()
        changes.notify()
        await repository.waitUntilChannelReadIsBlocked()

        await repository.gateNextChannelRead()
        for _ in 0..<1_000 {
            changes.notify()
        }
        let newestGeneration = changes.generation
        await repository.releaseChannelRead()
        await repository.waitUntilChannelReadIsBlocked()

        var snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileLookupCount, 3)

        await repository.releaseChannelRead()
        var newestProcessing: AppModel.ProcessedLibraryChange?
        while let processing = await processedChangeIterator.next() {
            if processing.generation == newestGeneration {
                newestProcessing = processing
                break
            }
        }
        XCTAssertEqual(newestProcessing?.generation, newestGeneration)
        XCTAssertEqual(newestProcessing?.reloadApplied, true)
        snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileLookupCount, 3)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.channels, [channel])
    }

    func testLibraryChangeStreamCatchesUpAndBuffersOnlyNewestGeneration() async {
        let changes = LibraryChangeSignal()
        changes.notify()
        let stream = changes.changes(after: 0)
        var iterator = stream.makeAsyncIterator()

        let catchUpGeneration = await iterator.next()
        XCTAssertEqual(catchUpGeneration, 1)

        for _ in 0..<1_000 {
            changes.notify()
        }
        let newestGeneration = await iterator.next()
        XCTAssertEqual(newestGeneration, changes.generation)
        XCTAssertEqual(newestGeneration, 1_001)
    }

    func testBufferedRefreshSignalsPreserveEveryResourceSinceLastProcessedGeneration() async {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let changes = LibraryChangeSignal()
        let stream = changes.changes(after: 0)
        var iterator = stream.makeAsyncIterator()

        changes.notify(profileID: profileID, resource: .epg)
        changes.notify(profileID: profileID, resource: .playlist)

        let newestGeneration = await iterator.next()
        XCTAssertEqual(newestGeneration, 2)
        XCTAssertEqual(
            changes.reloadScope(after: 0),
            .refreshes([profileID: [.playlist, .epg]])
        )
        XCTAssertEqual(
            changes.reloadScope(after: 1),
            .refreshes([profileID: [.playlist]])
        )
    }

    func testPersistedRefreshClaimCoalescesPendingResourcesOrDiscardsThemAfterLocalReload() {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let changes = LibraryChangeSignal()
        let publishedClaim = changes.claimPersistedRefreshes(
            profileID: profileID,
            resources: [.playlist, .epg]
        )

        changes.notify(profileID: profileID, resource: .epg)
        changes.notify(profileID: profileID, resource: .playlist)
        XCTAssertEqual(changes.generation, 0)

        changes.releasePersistedRefreshes(
            publishedClaim,
            publishesPendingChanges: true
        )
        XCTAssertEqual(changes.generation, 1)
        XCTAssertEqual(
            changes.reloadScope(after: 0),
            .refreshes([profileID: [.playlist, .epg]])
        )

        let discardedClaim = changes.claimPersistedRefreshes(
            profileID: profileID,
            resources: [.epg]
        )
        changes.notify(profileID: profileID, resource: .epg)
        changes.releasePersistedRefreshes(
            discardedClaim,
            publishesPendingChanges: false
        )
        XCTAssertEqual(changes.generation, 1)
    }

    func testCreateRetryIdentityUpdatesCommittedProfileWhenInputChanges() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )

        let attemptID = UUID()
        await repository.setReadFailure(true)
        let firstCreateSucceeded = await model.create(input: input, attemptID: attemptID)
        let changedInput = SourceProfileInput(
            name: "Changed while retrying",
            m3uURLString: "https://example.test/changed.m3u",
            epgURLString: input.epgURLString,
            m3uRefreshInterval: .hourly,
            epgRefreshInterval: .daily
        )
        let retryCreateSucceeded = await model.create(input: changedInput, attemptID: attemptID)
        XCTAssertFalse(firstCreateSucceeded)
        XCTAssertFalse(retryCreateSucceeded)
        var snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileCreateCount, 1)
        XCTAssertEqual(snapshot.profileUpdateCount, 1)
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Changed while retrying"])
        XCTAssertEqual(model.profiles.map(\.name), ["Changed while retrying"])
        XCTAssertEqual(model.alertTitle, "操作失败")

        await repository.setReadFailure(false)
        let reconciledCreateSucceeded = await model.create(input: changedInput, attemptID: attemptID)
        XCTAssertTrue(reconciledCreateSucceeded)
        snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileCreateCount, 1)
        XCTAssertEqual(snapshot.profileUpdateCount, 2)
    }

    func testCreatedProfileFetchesBothResourcesWithoutWaitingForTheScheduler() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let probe = RefreshCallProbe()
        let model = AppModel(
            repository: RepositorySpy(profiles: []),
            refresh: { profileID, resources, trigger in
                await probe.record(profileID: profileID, resources: resources, trigger: trigger)
                return resources.map { RefreshOutcome(resource: $0, succeeded: true, message: nil) }
            },
            now: { now }
        )
        // 仅手动 is never due, so without the fetch that saving starts the
        // playlist would stay empty until the user pressed 立即刷新 twice.
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )

        let created = await model.create(input: input, attemptID: UUID())
        XCTAssertTrue(created)
        let createdID = try XCTUnwrap(model.profiles.first?.id)

        await probe.waitForCalls(count: 1)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.resources, [.playlist, .epg])
        XCTAssertTrue(calls.allSatisfy { $0.profileID == createdID })
    }

    func testCreatedProfileAutomaticBatchConsumesPersistedSignalsAndReloadsChannelsOnce() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let changes = LibraryChangeSignal()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                if resources.contains(.playlist) {
                    await repository.replaceChannels(
                        profileID: profileID,
                        channels: [
                            Channel(
                                sourceProfileID: profileID,
                                displayName: "Refreshed",
                                streamURL: URL(string: "https://example.test/refreshed")!,
                                tvgID: nil,
                                tvgName: nil,
                                logoURL: nil,
                                groupTitle: nil,
                                attributes: [:],
                                order: 0
                            )
                        ]
                    )
                }
                var outcomes: [RefreshOutcome] = []
                for resource in resources {
                    let attemptID = UUID()
                    try? await repository.recordSuccess(
                        profileID: profileID,
                        resource: resource,
                        at: now,
                        attemptID: attemptID
                    )
                    let outcome = RefreshOutcome(
                        resource: resource,
                        succeeded: true,
                        message: nil,
                        attemptID: attemptID
                    )
                    outcomes.append(outcome)
                    await MainActor.run {
                        changes.notify(profileID: profileID, resource: resource)
                    }
                }
                return outcomes
            },
            libraryChanges: changes,
            now: { now }
        )
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )

        let created = await model.create(input: input, attemptID: UUID())
        XCTAssertTrue(created)
        await eventually {
            model.channels.map(\.displayName) == ["Refreshed"]
        }
        await model.waitForLibraryReloadsToSettle()

        let snapshot = await repository.snapshot()
        XCTAssertEqual(changes.generation, 0)
        XCTAssertEqual(snapshot.channelLookupCount, 2)
        XCTAssertEqual(model.channels.map(\.displayName), ["Refreshed"])
        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .succeeded)
        XCTAssertEqual(model.profiles.first?.epgStatus.state, .succeeded)
    }

    func testForegroundCompletionDuringAutomaticBatchReloadIsNotConsumedByFinishedClaim() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let changes = LibraryChangeSignal()
        let automaticRefreshGate = AppModelAsyncGate()
        await automaticRefreshGate.arm()
        let model = AppModel(
            repository: repository,
            refresh: { profileID, resources, _ in
                await repository.replaceChannels(
                    profileID: profileID,
                    channels: [
                        Channel(
                            sourceProfileID: profileID,
                            displayName: "Automatic batch",
                            streamURL: URL(string: "https://example.test/automatic-batch")!,
                            tvgID: nil,
                            tvgName: nil,
                            logoURL: nil,
                            groupTitle: nil,
                            attributes: [:],
                            order: 0
                        )
                    ]
                )
                var outcomes: [RefreshOutcome] = []
                for resource in resources {
                    let outcome = RefreshOutcome(
                        resource: resource,
                        succeeded: true,
                        message: nil,
                        attemptID: UUID()
                    )
                    outcomes.append(outcome)
                    await MainActor.run {
                        changes.notify(profileID: profileID, resource: resource)
                    }
                }
                await automaticRefreshGate.suspendIfArmed()
                return outcomes
            },
            libraryChanges: changes,
            now: { now }
        )
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )

        let created = await model.create(input: input, attemptID: UUID())
        XCTAssertTrue(created)
        let profileID = try XCTUnwrap(model.profiles.first?.id)
        await automaticRefreshGate.waitUntilSuspended()
        await repository.gateNextChannelRead()
        await automaticRefreshGate.release()
        await repository.waitUntilChannelReadIsBlocked()

        let foregroundChannel = Channel(
            sourceProfileID: profileID,
            displayName: "Foreground completion",
            streamURL: URL(string: "https://example.test/foreground-completion")!,
            tvgID: nil,
            tvgName: nil,
            logoURL: nil,
            groupTitle: nil,
            attributes: [:],
            order: 0
        )
        await repository.replaceChannels(
            profileID: profileID,
            channels: [foregroundChannel]
        )
        changes.notify(profileID: profileID, resource: .playlist)
        XCTAssertEqual(changes.generation, 1)

        await repository.releaseChannelRead()
        await eventually {
            model.channels == [foregroundChannel]
        }
        await model.waitForLibraryReloadsToSettle()

        XCTAssertEqual(model.channels, [foregroundChannel])
        let snapshot = await repository.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.channelLookupCount, 3)
    }

    func testAutomaticBatchDoesNotRetainModelAndReleasesClaimWhenRefreshIgnoresCancellation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let changes = LibraryChangeSignal()
        let refreshGate = AppModelAsyncGate()
        await refreshGate.arm()
        var model: AppModel? = AppModel(
            repository: repository,
            refresh: { _, resources, _ in
                await refreshGate.suspendIfArmed()
                return resources.map {
                    RefreshOutcome(resource: $0, succeeded: true, message: nil)
                }
            },
            libraryChanges: changes,
            now: { now }
        )
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )

        let created = await model?.create(input: input, attemptID: UUID())
        XCTAssertEqual(created, true)
        let profileID = try XCTUnwrap(model?.profiles.first?.id)
        await refreshGate.waitUntilSuspended()
        weak let weakModel = model
        model = nil
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertNil(weakModel)
        changes.notify(profileID: profileID, resource: .playlist)
        XCTAssertEqual(changes.generation, 1)
        await refreshGate.release()
    }

    func testEditedProfileRefetchesOnlyTheResourceWhoseAddressChanged() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let probe = RefreshCallProbe()
        let model = AppModel(
            repository: RepositorySpy(profiles: [profile], activeProfileID: profile.id),
            refresh: { profileID, resources, trigger in
                await probe.record(profileID: profileID, resources: resources, trigger: trigger)
                return resources.map { RefreshOutcome(resource: $0, succeeded: true, message: nil) }
            },
            now: { now }
        )
        func input(epgURLString: String) -> SourceProfileInput {
            SourceProfileInput(
                name: "Renamed",
                m3uURLString: profile.m3uURL.absoluteString,
                epgURLString: epgURLString,
                m3uRefreshInterval: .daily,
                epgRefreshInterval: .daily
            )
        }

        await model.reload()
        // Renaming and rescheduling leave the imported content valid; a new EPG
        // address does not, and its stored success timestamp would otherwise
        // keep the scheduler quiet for a whole day.
        let renamed = await model.update(
            profileID: profile.id,
            input: input(epgURLString: profile.epgURL.absoluteString)
        )
        XCTAssertTrue(renamed)
        let retargeted = await model.update(
            profileID: profile.id,
            input: input(epgURLString: "https://example.test/another-epg.xml")
        )
        XCTAssertTrue(retargeted)

        await probe.waitForCalls(count: 1)
        let calls = await probe.calls
        XCTAssertEqual(calls.map(\.resources), [[.epg]])
        XCTAssertEqual(calls.first?.profileID, profile.id)
    }

    func testCancellingCreateAttemptAllowsIntentionalIdenticalCreationFromNewSheet() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )

        let firstAttemptID = UUID()
        await repository.setReadFailure(true)
        _ = await model.create(input: input, attemptID: firstAttemptID)
        model.cancelCreateAttempt(firstAttemptID)
        _ = await model.create(input: input, attemptID: UUID())

        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileCreateCount, 2)
        XCTAssertEqual(snapshot.profiles.count, 2)
        XCTAssertEqual(Set(snapshot.profiles.map(\.name)), ["Created"])
    }

    func testUpdateAndDeleteClearPendingCreateAttemptOwnership() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )
        let attemptID = UUID()

        await repository.setReadFailure(true)
        _ = await model.create(input: input, attemptID: attemptID)
        let firstID = try XCTUnwrap(model.profiles.first?.id)
        _ = await model.update(profileID: firstID, input: input)
        _ = await model.create(input: input, attemptID: attemptID)
        var snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileCreateCount, 2)

        let secondID = try XCTUnwrap(snapshot.profiles.last?.id)
        _ = await model.delete(profileID: secondID)
        _ = await model.create(input: input, attemptID: attemptID)
        snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileCreateCount, 3)
        XCTAssertFalse(snapshot.profiles.contains { $0.id == secondID })
    }

    func testExternalDeletionReconciledByReloadClearsPendingCreateAttempt() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )
        let attemptID = UUID()

        await repository.setReadFailure(true)
        _ = await model.create(input: input, attemptID: attemptID)
        let createdID = try XCTUnwrap(model.profiles.first?.id)
        try await repository.deleteProfile(id: createdID)
        await repository.setReadFailure(false)
        let reloadSucceeded = await model.reload()
        XCTAssertTrue(reloadSucceeded)

        await repository.setReadFailure(true)
        _ = await model.create(input: input, attemptID: attemptID)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileCreateCount, 2)
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertNotEqual(snapshot.profiles.first?.id, createdID)
    }

    func testCreateDoesNotReportSuccessWhenCreatedProfileDisappearsDuringReload() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )

        await repository.gateNextProfileRead()
        let creation = Task { await model.create(input: input, attemptID: UUID()) }
        await repository.waitUntilProfileReadIsBlocked()
        let blockedSnapshot = await repository.snapshot()
        let createdID = try XCTUnwrap(blockedSnapshot.profiles.first?.id)
        try await repository.deleteProfile(id: createdID)
        await repository.releaseProfileRead()

        let creationSucceeded = await creation.value
        XCTAssertFalse(creationSucceeded)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertEqual(model.alertTitle, "操作失败")
    }

    func testDismissDuringSuspendedCreateCannotInstallPendingAttemptAfterward() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let repository = RepositorySpy(profiles: [])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })
        let input = SourceProfileInput(
            name: "Created",
            m3uURLString: "https://example.test/playlist.m3u",
            epgURLString: "https://example.test/epg.xml",
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual
        )
        let attemptID = UUID()

        await repository.gateNextCreate()
        let dismissedCreation = Task { await model.create(input: input, attemptID: attemptID) }
        await repository.waitUntilCreateIsBlocked()
        model.cancelCreateAttempt(attemptID)
        await repository.setReadFailure(true)
        await repository.releaseCreate()
        let dismissedCreationSucceeded = await dismissedCreation.value
        XCTAssertFalse(dismissedCreationSucceeded)

        await repository.setReadFailure(false)
        _ = await model.create(input: input, attemptID: attemptID)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileCreateCount, 2)
    }

    func testGenericReloadWaitsForGatedActivationReconciliation() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "First",
            now: now
        )
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let secondChannel = makeChannel(
            profileID: second.id,
            url: "https://example.test/second",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id,
            channels: [second.id: [secondChannel]]
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextActivation()
        let activation = Task { await model.activate(profileID: second.id) }
        let acquiredActivationEvent = await laneEventIterator.next()
        XCTAssertEqual(
            acquiredActivationEvent,
            .acquired(.activate(second.id))
        )
        await repository.waitUntilActivationIsBlocked()

        let reload = Task { await model.reload() }
        let reloadWaitingEvent = await laneEventIterator.next()
        XCTAssertEqual(reloadWaitingEvent, .reloadWaiting)

        await repository.releaseActivation()
        let activationSucceeded = await activation.value
        let reloadApplied = await reload.value
        XCTAssertTrue(activationSucceeded)
        XCTAssertTrue(reloadApplied)

        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.activeProfileID, second.id)
        XCTAssertEqual(model.activeProfile, second)
        XCTAssertEqual(model.channels, [secondChannel])
    }

    func testGenericReloadWaitsForGatedActiveDeletionReconciliation() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "First",
            now: now
        )
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let secondChannel = makeChannel(
            profileID: second.id,
            url: "https://example.test/second",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id,
            channels: [second.id: [secondChannel]]
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextDeletion()
        let deletion = Task { await model.delete(profileID: first.id) }
        let acquiredDeletionEvent = await laneEventIterator.next()
        XCTAssertEqual(
            acquiredDeletionEvent,
            .acquired(.delete(first.id))
        )
        await repository.waitUntilDeletionIsBlocked()

        let reload = Task { await model.reload() }
        let reloadWaitingEvent = await laneEventIterator.next()
        XCTAssertEqual(reloadWaitingEvent, .reloadWaiting)

        await repository.releaseDeletion()
        let deletionSucceeded = await deletion.value
        let reloadApplied = await reload.value
        XCTAssertTrue(deletionSucceeded)
        XCTAssertTrue(reloadApplied)

        let snapshot = await repository.snapshot()
        XCTAssertFalse(snapshot.profiles.contains { $0.id == first.id })
        XCTAssertEqual(snapshot.activeProfileID, second.id)
        XCTAssertFalse(model.profiles.contains { $0.id == first.id })
        XCTAssertEqual(model.activeProfile, second)
        XCTAssertEqual(model.channels, [secondChannel])
    }

    func testSuccessfulActivationsPersistAndReconcileInInvocationOrder() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let third = makeProfile(id: "00000000-0000-0000-0000-000000000003", name: "Third", now: now)
        let thirdChannel = makeChannel(
            profileID: third.id,
            url: "https://example.test/third",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [first, second, third],
            activeProfileID: first.id,
            channels: [third.id: [thirdChannel]]
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextActivation()
        let firstActivation = Task { await model.activate(profileID: second.id) }
        let acquiredFirstActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredFirstActivation, .acquired(.activate(second.id)))
        await repository.waitUntilActivationIsBlocked()

        let secondActivation = Task { await model.activate(profileID: third.id) }
        let queuedSecondActivation = await laneEventIterator.next()
        XCTAssertEqual(queuedSecondActivation, .queued(.activate(third.id)))
        await repository.releaseActivation()

        let firstActivationSucceeded = await firstActivation.value
        let secondActivationSucceeded = await secondActivation.value
        XCTAssertTrue(firstActivationSucceeded)
        XCTAssertTrue(secondActivationSucceeded)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.operationEvents, [
            .activationStarted(second.id),
            .activationStarted(third.id),
        ])
        XCTAssertEqual(snapshot.activeProfileID, third.id)
        XCTAssertEqual(model.activeProfile, third)
        XCTAssertEqual(model.channels, [thirdChannel])
    }

    func testActivationThenDeletionPersistAndReconcileInInvocationOrder() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextActivation()
        let activation = Task { await model.activate(profileID: second.id) }
        let acquiredActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredActivation, .acquired(.activate(second.id)))
        await repository.waitUntilActivationIsBlocked()

        let deletion = Task { await model.delete(profileID: second.id) }
        let queuedDeletion = await laneEventIterator.next()
        XCTAssertEqual(queuedDeletion, .queued(.delete(second.id)))
        await repository.releaseActivation()

        let activationSucceeded = await activation.value
        let deletionSucceeded = await deletion.value
        XCTAssertTrue(activationSucceeded)
        XCTAssertTrue(deletionSucceeded)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.operationEvents, [
            .activationStarted(second.id),
            .deletionStarted(second.id),
        ])
        XCTAssertFalse(snapshot.profiles.contains { $0.id == second.id })
        XCTAssertEqual(snapshot.activeProfileID, first.id)
        XCTAssertFalse(model.profiles.contains { $0.id == second.id })
        XCTAssertEqual(model.activeProfile, first)
    }

    func testInactiveDeletionAlsoQueuesBehindActivation() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let inactive = makeProfile(id: "00000000-0000-0000-0000-000000000003", name: "Inactive", now: now)
        let secondChannel = makeChannel(
            profileID: second.id,
            url: "https://example.test/second",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [first, second, inactive],
            activeProfileID: first.id,
            channels: [second.id: [secondChannel]]
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextActivation()
        let activation = Task { await model.activate(profileID: second.id) }
        let acquiredActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredActivation, .acquired(.activate(second.id)))
        await repository.waitUntilActivationIsBlocked()

        let deletion = Task { await model.delete(profileID: inactive.id) }
        let queuedDeletion = await laneEventIterator.next()
        XCTAssertEqual(queuedDeletion, .queued(.delete(inactive.id)))
        await repository.releaseActivation()

        let activationSucceeded = await activation.value
        let deletionSucceeded = await deletion.value
        XCTAssertTrue(activationSucceeded)
        XCTAssertTrue(deletionSucceeded)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.operationEvents, [
            .activationStarted(second.id),
            .deletionStarted(inactive.id),
        ])
        XCTAssertFalse(snapshot.profiles.contains { $0.id == inactive.id })
        XCTAssertEqual(snapshot.activeProfileID, second.id)
        XCTAssertEqual(model.activeProfile, second)
        XCTAssertEqual(model.channels, [secondChannel])
    }

    func testCancellingQueuedActivationSkipsItsWriteAndGrantsFollowingMutation() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let third = makeProfile(id: "00000000-0000-0000-0000-000000000003", name: "Third", now: now)
        let repository = RepositorySpy(
            profiles: [first, second, third],
            activeProfileID: first.id
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextActivation()
        let firstActivation = Task { await model.activate(profileID: second.id) }
        let acquiredFirstActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredFirstActivation, .acquired(.activate(second.id)))
        await repository.waitUntilActivationIsBlocked()

        let cancelledActivation = Task { await model.activate(profileID: third.id) }
        let queuedCancelledActivation = await laneEventIterator.next()
        XCTAssertEqual(queuedCancelledActivation, .queued(.activate(third.id)))
        let finalActivation = Task { await model.activate(profileID: first.id) }
        let queuedFinalActivation = await laneEventIterator.next()
        XCTAssertEqual(queuedFinalActivation, .queued(.activate(first.id)))

        cancelledActivation.cancel()
        let cancelledEvent = await laneEventIterator.next()
        XCTAssertEqual(cancelledEvent, .cancelled(.activate(third.id)))
        let cancelledActivationSucceeded = await cancelledActivation.value
        XCTAssertFalse(cancelledActivationSucceeded)
        await repository.releaseActivation()

        let firstActivationSucceeded = await firstActivation.value
        let finalActivationSucceeded = await finalActivation.value
        XCTAssertTrue(firstActivationSucceeded)
        XCTAssertTrue(finalActivationSucceeded)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.operationEvents, [
            .activationStarted(second.id),
            .activationStarted(first.id),
        ])
        XCTAssertEqual(snapshot.activeProfileID, first.id)
        XCTAssertEqual(model.activeProfile, first)
    }

    func testActivationCancelledBeforeEnqueueNeverWrites() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        let activation = Task { await model.activate(profileID: second.id) }
        activation.cancel()

        let cancelledEvent = await laneEventIterator.next()
        XCTAssertEqual(cancelledEvent, .cancelled(.activate(second.id)))
        let activationSucceeded = await activation.value
        XCTAssertFalse(activationSucceeded)
        let snapshot = await repository.snapshot()
        XCTAssertTrue(snapshot.operationEvents.isEmpty)
        XCTAssertEqual(snapshot.activeProfileID, first.id)
    }

    func testActivationCancelledAsItIsGrantedSkipsWriteAndReleasesFollowingMutation() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let third = makeProfile(id: "00000000-0000-0000-0000-000000000003", name: "Third", now: now)
        let repository = RepositorySpy(
            profiles: [first, second, third],
            activeProfileID: first.id
        )
        let grantCanceller = MutationGrantCanceller(
            target: .activate(third.id)
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: {
                laneEventContinuation.yield($0)
                grantCanceller.observe($0)
            },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextActivation()
        let firstActivation = Task { await model.activate(profileID: second.id) }
        let acquiredFirstActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredFirstActivation, .acquired(.activate(second.id)))
        await repository.waitUntilActivationIsBlocked()

        let cancelledActivation = Task { await model.activate(profileID: third.id) }
        grantCanceller.task = cancelledActivation
        let queuedCancelledActivation = await laneEventIterator.next()
        XCTAssertEqual(queuedCancelledActivation, .queued(.activate(third.id)))
        let finalActivation = Task { await model.activate(profileID: first.id) }
        let queuedFinalActivation = await laneEventIterator.next()
        XCTAssertEqual(queuedFinalActivation, .queued(.activate(first.id)))

        await repository.releaseActivation()
        let firstActivationSucceeded = await firstActivation.value
        let cancelledActivationSucceeded = await cancelledActivation.value
        let finalActivationSucceeded = await finalActivation.value

        XCTAssertTrue(firstActivationSucceeded)
        XCTAssertFalse(cancelledActivationSucceeded)
        XCTAssertTrue(finalActivationSucceeded)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.operationEvents, [
            .activationStarted(second.id),
            .activationStarted(first.id),
        ])
        XCTAssertEqual(snapshot.activeProfileID, first.id)
        XCTAssertEqual(model.activeProfile, first)
    }

    func testCancelledReloadWaitingForMutationLeavesNoIdleWaiterLeak() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextActivation()
        let activation = Task { await model.activate(profileID: second.id) }
        let acquiredActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredActivation, .acquired(.activate(second.id)))
        await repository.waitUntilActivationIsBlocked()

        let cancelledReload = Task { await model.reload() }
        let reloadWaitingEvent = await laneEventIterator.next()
        XCTAssertEqual(reloadWaitingEvent, .reloadWaiting)
        cancelledReload.cancel()
        let cancelledReloadApplied = await cancelledReload.value
        XCTAssertFalse(cancelledReloadApplied)

        await repository.releaseActivation()
        let activationSucceeded = await activation.value
        XCTAssertTrue(activationSucceeded)
        let finalReloadApplied = await model.reload()
        XCTAssertTrue(finalReloadApplied)
        XCTAssertEqual(model.activeProfile, second)
    }

    func testCancellationAfterActivationWriteStillCompletesReconciliationBeforeRelease() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let secondChannel = makeChannel(
            profileID: second.id,
            url: "https://example.test/second",
            tvgID: nil,
            order: 0
        )
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id,
            channels: [second.id: [secondChannel]]
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: { now }
        )
        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)

        await repository.gateNextChannelRead()
        let activation = Task { await model.activate(profileID: second.id) }
        let acquiredActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredActivation, .acquired(.activate(second.id)))
        await repository.waitUntilChannelReadIsBlocked()
        activation.cancel()

        let reload = Task { await model.reload() }
        let reloadWaitingEvent = await laneEventIterator.next()
        XCTAssertEqual(reloadWaitingEvent, .reloadWaiting)
        await repository.releaseChannelRead()

        let activationSucceeded = await activation.value
        let reloadApplied = await reload.value
        XCTAssertTrue(activationSucceeded)
        XCTAssertTrue(reloadApplied)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.activeProfileID, second.id)
        XCTAssertEqual(model.activeProfile, second)
        XCTAssertEqual(model.channels, [secondChannel])
    }

    func testActivationWriteFailureRestoresCompleteActiveBoundState() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [second],
            now: now
        )

        await fixture.repository.failNextActivation()
        let activationSucceeded = await fixture.model.activate(profileID: second.id)

        XCTAssertFalse(activationSucceeded)
        assertCompleteActiveBoundState(fixture)
        XCTAssertEqual(fixture.model.profiles, [fixture.activeProfile, second])
        XCTAssertEqual(fixture.model.alertTitle, "操作失败")
        XCTAssertNotNil(fixture.model.alertMessage)
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, fixture.activeProfile.id)
        XCTAssertEqual(repositorySnapshot.profiles, [fixture.activeProfile, second])
        XCTAssertEqual(repositorySnapshot.channels[fixture.activeProfile.id], fixture.channels)
        XCTAssertEqual(repositorySnapshot.epgChannels[fixture.activeProfile.id], fixture.epgChannels)
        XCTAssertEqual(repositorySnapshot.programmes[fixture.activeProfile.id], fixture.programmes)
        XCTAssertEqual(
            repositorySnapshot.manualMappings[fixture.activeProfile.id],
            [fixture.manualChannel.id: "manual"]
        )
    }

    func testActiveDeletionWriteFailureRestoresCompleteActiveBoundStateAndProfiles() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [second],
            now: now
        )

        await fixture.repository.failNextDeletion()
        let deletionSucceeded = await fixture.model.delete(profileID: fixture.activeProfile.id)

        XCTAssertFalse(deletionSucceeded)
        assertCompleteActiveBoundState(fixture)
        XCTAssertEqual(fixture.model.profiles, [fixture.activeProfile, second])
        XCTAssertEqual(fixture.model.alertTitle, "操作失败")
        XCTAssertNotNil(fixture.model.alertMessage)
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, fixture.activeProfile.id)
        XCTAssertEqual(repositorySnapshot.profiles, [fixture.activeProfile, second])
        XCTAssertEqual(repositorySnapshot.channels[fixture.activeProfile.id], fixture.channels)
        XCTAssertEqual(repositorySnapshot.epgChannels[fixture.activeProfile.id], fixture.epgChannels)
        XCTAssertEqual(repositorySnapshot.programmes[fixture.activeProfile.id], fixture.programmes)
        XCTAssertEqual(
            repositorySnapshot.manualMappings[fixture.activeProfile.id],
            [fixture.manualChannel.id: "manual"]
        )
    }

    func testFailedActivationThenSuccessfulActivationUsesFIFOAndClearsOlderError() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let third = makeProfile(
            id: "00000000-0000-0000-0000-000000000003",
            name: "Third",
            now: now
        )
        let thirdChannel = makeChannel(
            profileID: third.id,
            url: "https://example.test/third",
            tvgID: nil,
            order: 0
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [second, third],
            additionalChannels: [third.id: [thirdChannel]],
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: now
        )

        await fixture.repository.failNextActivation()
        await fixture.repository.gateNextActivation()
        let firstActivation = Task {
            await fixture.model.activate(profileID: second.id)
        }
        let acquiredFirstActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredFirstActivation, .acquired(.activate(second.id)))
        await fixture.repository.waitUntilActivationIsBlocked()

        let secondActivation = Task {
            await fixture.model.activate(profileID: third.id)
        }
        let queuedSecondActivation = await laneEventIterator.next()
        XCTAssertEqual(queuedSecondActivation, .queued(.activate(third.id)))

        await fixture.repository.releaseActivation()
        let firstActivationSucceeded = await firstActivation.value
        let secondActivationSucceeded = await secondActivation.value

        XCTAssertFalse(firstActivationSucceeded)
        XCTAssertTrue(secondActivationSucceeded)
        XCTAssertEqual(fixture.model.activeProfile, third)
        XCTAssertEqual(fixture.model.channels, [thirdChannel])
        XCTAssertTrue(fixture.model.epgChannels.isEmpty)
        XCTAssertTrue(fixture.model.programmesByChannelID.isEmpty)
        XCTAssertNil(fixture.model.matchedEPGChannelID(for: thirdChannel))
        XCTAssertNil(fixture.model.manualEPGChannelID(for: thirdChannel))
        XCTAssertNil(fixture.model.presentedPlaybackRequest)
        XCTAssertFalse(fixture.model.isLoading)
        XCTAssertNil(fixture.model.alertMessage)
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, third.id)
        XCTAssertEqual(repositorySnapshot.profiles, [fixture.activeProfile, second, third])
    }

    func testGenericReloadWaitsForPostWriteActivationReloadBeforeApplyingNewerTruth() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let third = makeProfile(
            id: "00000000-0000-0000-0000-000000000003",
            name: "Third",
            now: now
        )
        let thirdChannel = makeChannel(
            profileID: third.id,
            url: "https://example.test/third",
            tvgID: nil,
            order: 0
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [second, third],
            additionalChannels: [third.id: [thirdChannel]],
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: now
        )

        await fixture.repository.gateNextChannelRead()
        let activation = Task {
            await fixture.model.activate(profileID: second.id)
        }
        let acquiredActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredActivation, .acquired(.activate(second.id)))
        await fixture.repository.waitUntilChannelReadIsBlocked()

        await fixture.repository.replaceProfiles(
            [fixture.activeProfile, second, third],
            activeProfileID: third.id
        )
        let reload = Task { await fixture.model.reload() }
        let reloadWaitingEvent = await laneEventIterator.next()
        XCTAssertEqual(reloadWaitingEvent, .reloadWaiting)

        await fixture.repository.releaseChannelRead()
        let activationSucceeded = await activation.value
        let reloadApplied = await reload.value

        XCTAssertTrue(activationSucceeded)
        XCTAssertTrue(reloadApplied)
        XCTAssertEqual(fixture.model.activeProfile, third)
        XCTAssertEqual(fixture.model.channels, [thirdChannel])
        XCTAssertFalse(fixture.model.isLoading)
        XCTAssertNil(fixture.model.alertMessage)
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, third.id)
    }

    func testGenericReloadWaitsForPostWriteDeletionReloadBeforeApplyingRepositoryTruth() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let secondChannel = makeChannel(
            profileID: second.id,
            url: "https://example.test/second",
            tvgID: nil,
            order: 0
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [second],
            additionalChannels: [second.id: [secondChannel]],
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: now
        )

        await fixture.repository.gateNextChannelRead()
        let deletion = Task {
            await fixture.model.delete(profileID: fixture.activeProfile.id)
        }
        let acquiredDeletion = await laneEventIterator.next()
        XCTAssertEqual(acquiredDeletion, .acquired(.delete(fixture.activeProfile.id)))
        await fixture.repository.waitUntilChannelReadIsBlocked()

        let reload = Task { await fixture.model.reload() }
        let reloadWaitingEvent = await laneEventIterator.next()
        XCTAssertEqual(reloadWaitingEvent, .reloadWaiting)

        await fixture.repository.releaseChannelRead()
        let deletionSucceeded = await deletion.value
        let reloadApplied = await reload.value

        XCTAssertTrue(deletionSucceeded)
        XCTAssertTrue(reloadApplied)
        XCTAssertEqual(fixture.model.profiles, [second])
        XCTAssertEqual(fixture.model.activeProfile, second)
        XCTAssertEqual(fixture.model.channels, [secondChannel])
        XCTAssertFalse(fixture.model.isLoading)
        XCTAssertNil(fixture.model.alertMessage)
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, second.id)
    }

    func testActivationWaitsForMaskedReloadBeforeCapturingFailureSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [second],
            now: now
        )
        let (activationStarts, activationStartContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        defer { activationStartContinuation.finish() }
        var activationStartIterator = activationStarts.makeAsyncIterator()

        await fixture.repository.gateNextChannelRead()
        let reload = Task { await fixture.model.reload() }
        await fixture.repository.waitUntilChannelReadIsBlocked()
        assertCompleteActiveBoundState(fixture)

        await fixture.repository.failNextActivation()
        await fixture.repository.gateNextActivation()
        let activation = Task {
            activationStartContinuation.yield()
            return await fixture.model.activate(profileID: second.id)
        }
        _ = await activationStartIterator.next()

        await fixture.repository.releaseChannelRead()
        let reloadApplied = await reload.value
        XCTAssertTrue(reloadApplied)
        await fixture.repository.waitUntilActivationIsBlocked()
        let blockedSnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(
            blockedSnapshot.operationEvents,
            [.channelReadReleased, .activationStarted(second.id)]
        )

        await fixture.repository.releaseActivation()
        let activationSucceeded = await activation.value

        XCTAssertFalse(activationSucceeded)
        assertCompleteActiveBoundState(fixture)
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, fixture.activeProfile.id)
    }

    func testOrdinaryReloadKeepsMatchingPlaybackPresentedWhileReadIsGated() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [],
            now: now
        )
        let requestAtStart = try XCTUnwrap(fixture.model.presentedPlaybackRequest)

        await fixture.repository.gateNextChannelRead()
        let reload = Task { await fixture.model.reload() }
        await fixture.repository.waitUntilChannelReadIsBlocked()

        XCTAssertEqual(fixture.model.presentedPlaybackRequest, requestAtStart)
        XCTAssertEqual(fixture.model.presentedPlaybackRequest?.id, requestAtStart.id)

        await fixture.repository.releaseChannelRead()
        let reloadApplied = await reload.value
        XCTAssertTrue(reloadApplied)
        XCTAssertEqual(fixture.model.presentedPlaybackRequest, requestAtStart)
        XCTAssertEqual(fixture.model.presentedPlaybackRequest?.id, requestAtStart.id)
    }

    func testOrdinaryReloadKeepsLoadedChannelsAndProgrammesUsableWhileReadIsGated() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [],
            now: now
        )

        await fixture.repository.gateNextChannelRead()
        let reload = Task { await fixture.model.reload() }
        await fixture.repository.waitUntilChannelReadIsBlocked()

        XCTAssertFalse(fixture.model.isLoading)
        XCTAssertEqual(fixture.model.activeProfile, fixture.activeProfile)
        XCTAssertEqual(fixture.model.channels, fixture.channels)
        XCTAssertEqual(fixture.model.epgChannels, fixture.epgChannels)
        XCTAssertEqual(
            fixture.model.programmesByChannelID,
            fixture.programmesByChannelID
        )
        fixture.model.dismissPlayback()
        fixture.model.select(channel: fixture.automaticChannel)
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.channelID,
            fixture.automaticChannel.id
        )

        await fixture.repository.releaseChannelRead()
        let reloadApplied = await reload.value
        XCTAssertTrue(reloadApplied)
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.channelID,
            fixture.automaticChannel.id
        )
    }

    func testReloadKeepsPlaybackSelectedAfterPresentationPreparationWhenSnapshotContainsIt() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let presentationGate = AppModelAsyncGate()
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [],
            beforeLibraryPresentationApply: {
                await presentationGate.suspendIfArmed()
            },
            now: now
        )
        fixture.model.dismissPlayback()
        fixture.model.select(channel: fixture.automaticChannel)
        await fixture.repository.replaceChannels(
            profileID: fixture.activeProfile.id,
            channels: [fixture.manualChannel]
        )
        await presentationGate.arm()

        let reload = Task { await fixture.model.reload() }
        await presentationGate.waitUntilSuspended()
        fixture.model.dismissPlayback()
        fixture.model.select(channel: fixture.manualChannel)
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.channelID,
            fixture.manualChannel.id
        )
        await presentationGate.release()

        let reloadApplied = await reload.value
        XCTAssertTrue(reloadApplied)
        XCTAssertEqual(fixture.model.channels, [fixture.manualChannel])
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.channelID,
            fixture.manualChannel.id
        )
    }

    func testOrdinaryReloadClearsChannelSelectedDuringReadWhenNewSnapshotRemovedIt() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [],
            now: now
        )
        await fixture.repository.replaceChannels(
            profileID: fixture.activeProfile.id,
            channels: [fixture.manualChannel]
        )
        await fixture.repository.gateNextChannelRead()

        let reload = Task { await fixture.model.reload() }
        await fixture.repository.waitUntilChannelReadIsBlocked()
        fixture.model.dismissPlayback()
        fixture.model.select(channel: fixture.automaticChannel)
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.channelID,
            fixture.automaticChannel.id
        )

        await fixture.repository.releaseChannelRead()
        let reloadApplied = await reload.value

        XCTAssertTrue(reloadApplied)
        XCTAssertEqual(fixture.model.channels, [fixture.manualChannel])
        XCTAssertNil(fixture.model.presentedPlaybackRequest)
    }

    func testSelectionFromStaleCardUsesCurrentChannelSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [],
            now: now
        )
        let renamedChannel = Channel(
            sourceProfileID: fixture.activeProfile.id,
            displayName: "Renamed Channel",
            streamURL: fixture.automaticChannel.streamURL,
            tvgID: fixture.automaticChannel.tvgID,
            tvgName: fixture.automaticChannel.tvgName,
            logoURL: fixture.automaticChannel.logoURL,
            groupTitle: fixture.automaticChannel.groupTitle,
            attributes: fixture.automaticChannel.attributes,
            order: fixture.automaticChannel.order
        )
        await fixture.repository.replaceChannels(
            profileID: fixture.activeProfile.id,
            channels: [renamedChannel, fixture.manualChannel]
        )
        let reloadApplied = await fixture.model.reload()
        XCTAssertTrue(reloadApplied)

        fixture.model.dismissPlayback()
        fixture.model.select(channel: fixture.automaticChannel)

        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.channelID,
            renamedChannel.id
        )
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.streamURL,
            renamedChannel.streamURL
        )
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest?.title,
            renamedChannel.displayName
        )
    }

    func testOrdinaryReloadDoesNotRestorePlaybackDismissedWhileReadIsGated() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [],
            now: now
        )

        await fixture.repository.gateNextChannelRead()
        let reload = Task { await fixture.model.reload() }
        await fixture.repository.waitUntilChannelReadIsBlocked()
        XCTAssertNotNil(fixture.model.presentedPlaybackRequest)

        fixture.model.dismissPlayback()
        await fixture.repository.releaseChannelRead()

        let reloadApplied = await reload.value
        XCTAssertTrue(reloadApplied)
        XCTAssertNil(fixture.model.presentedPlaybackRequest)
    }

    func testOrdinaryReloadClearsPlaybackAfterGatedReadFindsChangedURL() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [],
            now: now
        )
        let changedChannel = makeChannel(
            profileID: fixture.activeProfile.id,
            url: "https://example.test/changed",
            tvgID: fixture.manualChannel.tvgID,
            order: fixture.manualChannel.order
        )
        await fixture.repository.replaceChannels(
            profileID: fixture.activeProfile.id,
            channels: [fixture.automaticChannel, changedChannel]
        )
        await fixture.repository.gateNextChannelRead()

        let reload = Task { await fixture.model.reload() }
        await fixture.repository.waitUntilChannelReadIsBlocked()
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest,
            fixture.playbackRequest
        )

        await fixture.repository.releaseChannelRead()
        let reloadApplied = await reload.value
        XCTAssertTrue(reloadApplied)
        XCTAssertNil(fixture.model.presentedPlaybackRequest)
    }

    func testReloadCarriesPlaybackOnlyWhenLoadedChannelIdentityAndURLStillMatch() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "First",
            now: now
        )
        let foreign = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Foreign",
            now: now
        )
        let channel = makeChannel(
            profileID: first.id,
            url: "https://example.test/original",
            tvgID: nil,
            order: 0
        )
        let changedStreamURL = try XCTUnwrap(URL(string: "https://example.test/changed"))
        let repository = RepositorySpy(
            profiles: [first, foreign],
            activeProfileID: first.id,
            channels: [first.id: [channel]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        let initialReloadApplied = await model.reload()
        XCTAssertTrue(initialReloadApplied)
        model.select(channel: channel)
        await repository.replaceChannels(profileID: first.id, channels: [])
        let staleChannelReloadApplied = await model.reload()
        XCTAssertTrue(staleChannelReloadApplied)
        XCTAssertNil(model.presentedPlaybackRequest)

        await repository.replaceChannels(profileID: first.id, channels: [channel])
        let restoredChannelReloadApplied = await model.reload()
        XCTAssertTrue(restoredChannelReloadApplied)
        model.presentedPlaybackRequest = PlaybackRequest(
            sourceProfileID: foreign.id,
            channelID: channel.id,
            streamURL: channel.streamURL,
            title: channel.displayName
        )
        let foreignRequestReloadApplied = await model.reload()
        XCTAssertTrue(foreignRequestReloadApplied)
        XCTAssertNil(model.presentedPlaybackRequest)

        model.presentedPlaybackRequest = PlaybackRequest(
            sourceProfileID: first.id,
            channelID: channel.id,
            streamURL: changedStreamURL,
            title: channel.displayName
        )
        let changedURLReloadApplied = await model.reload()
        XCTAssertTrue(changedURLReloadApplied)
        XCTAssertNil(model.presentedPlaybackRequest)
    }

    func testConsecutiveActivationFailuresUseFIFOAndPresentLatestError() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let second = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Second",
            now: now
        )
        let third = makeProfile(
            id: "00000000-0000-0000-0000-000000000003",
            name: "Third",
            now: now
        )
        let (laneEvents, laneEventContinuation) = AsyncStream.makeStream(
            of: AppModel.ActiveMutationLaneEvent.self,
            bufferingPolicy: .unbounded
        )
        defer { laneEventContinuation.finish() }
        var laneEventIterator = laneEvents.makeAsyncIterator()
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [second, third],
            mutationLaneEvent: { laneEventContinuation.yield($0) },
            now: now
        )

        await fixture.repository.failNextActivation()
        await fixture.repository.gateNextActivation()
        let firstActivation = Task {
            await fixture.model.activate(profileID: second.id)
        }
        let acquiredFirstActivation = await laneEventIterator.next()
        XCTAssertEqual(acquiredFirstActivation, .acquired(.activate(second.id)))
        await fixture.repository.waitUntilActivationIsBlocked()

        await fixture.repository.failNextActivation()
        let secondActivation = Task {
            await fixture.model.activate(profileID: third.id)
        }
        let queuedSecondActivation = await laneEventIterator.next()
        XCTAssertEqual(queuedSecondActivation, .queued(.activate(third.id)))

        await fixture.repository.releaseActivation()
        let firstActivationSucceeded = await firstActivation.value
        let secondActivationSucceeded = await secondActivation.value

        XCTAssertFalse(firstActivationSucceeded)
        XCTAssertFalse(secondActivationSucceeded)
        assertCompleteActiveBoundState(fixture)
        XCTAssertNotNil(fixture.model.alertMessage)
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, fixture.activeProfile.id)
    }

    func testInactiveDeletionWriteFailureDoesNotDisturbActiveBoundState() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let inactive = makeProfile(
            id: "00000000-0000-0000-0000-000000000002",
            name: "Inactive",
            now: now
        )
        let fixture = try await makeLoadedActiveBoundFixture(
            additionalProfiles: [inactive],
            now: now
        )

        await fixture.repository.failNextDeletion()
        let deletionSucceeded = await fixture.model.delete(profileID: inactive.id)

        XCTAssertFalse(deletionSucceeded)
        assertCompleteActiveBoundState(fixture)
        XCTAssertEqual(fixture.model.profiles, [fixture.activeProfile, inactive])
        let repositorySnapshot = await fixture.repository.snapshot()
        XCTAssertEqual(repositorySnapshot.activeProfileID, fixture.activeProfile.id)
        XCTAssertEqual(repositorySnapshot.profiles, [fixture.activeProfile, inactive])
    }

    func testDeleteAndActivateClearUnsafeActiveStateWhenReloadFails() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let firstChannel = makeChannel(profileID: first.id, url: "https://example.test/first", tvgID: nil, order: 0)
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id,
            channels: [first.id: [firstChannel]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()
        model.select(channel: firstChannel)
        await repository.setReadFailure(true)
        let activationSucceeded = await model.activate(profileID: second.id)
        XCTAssertFalse(activationSucceeded)
        XCTAssertEqual(model.activeProfile?.id, second.id)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.presentedPlaybackRequest)

        let deletionSucceeded = await model.delete(profileID: second.id)
        XCTAssertFalse(deletionSucceeded)
        XCTAssertFalse(model.profiles.contains { $0.id == second.id })
        XCTAssertNil(model.activeProfile)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.presentedPlaybackRequest)
    }

    func testRefreshReconcilesOutcomeLocallyWhenRepositoryReloadFails() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let repository = RepositorySpy(profiles: [profile])
        let model = AppModel(
            repository: repository,
            refresh: { _, resources, _ in
                resources.map { RefreshOutcome(resource: $0, succeeded: false, message: "测试刷新失败。") }
            },
            now: { now }
        )

        await model.reload()
        await repository.setReadFailure(true)
        await model.refresh(profileID: profile.id, resource: .playlist)

        XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed)
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "测试刷新失败。")
        XCTAssertNotEqual(model.profiles.first?.m3uStatus.state, .refreshing)
    }

    func testMappingSaveRejectsChannelRemovedFromRepositoryWhileSheetWasOpen() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channel = makeChannel(profileID: profile.id, url: "https://example.test/live", tvgID: nil, order: 0)
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profile.id: [channel]],
            epgChannels: [profile.id: [EPGChannel(id: "manual", displayNames: ["Manual"], iconURL: nil)]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()
        await repository.replaceChannels(profileID: profile.id, channels: [])
        let succeeded = await model.saveMapping(channel: channel, xmltvChannelID: "manual")

        let snapshot = await repository.snapshot()
        XCTAssertFalse(succeeded)
        XCTAssertNil(snapshot.manualMappings[profile.id]?[channel.id])
        XCTAssertEqual(model.alertTitle, "操作失败")
        XCTAssertNotNil(model.alertMessage)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testMappingSaveRechecksMembershipAtAtomicWriteBoundary() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channel = makeChannel(profileID: profile.id, url: "https://example.test/live", tvgID: nil, order: 0)
        let repository = RepositorySpy(profiles: [profile], channels: [profile.id: [channel]])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()
        await repository.gateNextMappingWrite()
        let save = Task { await model.saveMapping(channel: channel, xmltvChannelID: "manual") }
        await repository.waitUntilMappingWriteIsBlocked()
        await repository.replaceChannels(profileID: profile.id, channels: [])
        await repository.releaseMappingWrite()

        let saveSucceeded = await save.value
        XCTAssertFalse(saveSucceeded)
        let snapshot = await repository.snapshot()
        XCTAssertNil(snapshot.manualMappings[profile.id]?[channel.id])
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(model.alertTitle, "操作失败")
    }

    func testChannelBrowserUsesLoadingStateWheneverActiveDataIsMasked() {
        XCTAssertEqual(
            ChannelBrowserContentState.resolve(
                isLoading: true,
                hasActiveProfile: false,
                hasChannels: false
            ),
            .loading
        )
    }

    func testActivationMasksOldChannelsImmediatelyAndSelectionRejectsStaleOrForeignChannels() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "First", now: now)
        let second = makeProfile(id: "00000000-0000-0000-0000-000000000002", name: "Second", now: now)
        let firstChannel = makeChannel(profileID: first.id, url: "https://example.test/first", tvgID: nil, order: 0)
        let secondChannel = makeChannel(profileID: second.id, url: "https://example.test/second", tvgID: nil, order: 0)
        let repository = RepositorySpy(
            profiles: [first, second],
            activeProfileID: first.id,
            channels: [first.id: [firstChannel], second.id: [secondChannel]]
        )
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()
        model.select(channel: firstChannel)
        XCTAssertNotNil(model.presentedPlaybackRequest)
        await repository.gateNextActivation()
        let activation = Task { await model.activate(profileID: second.id) }
        await repository.waitUntilActivationIsBlocked()

        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.presentedPlaybackRequest)
        model.select(channel: firstChannel)
        XCTAssertNil(model.presentedPlaybackRequest)
        model.select(channel: secondChannel)
        XCTAssertNil(model.presentedPlaybackRequest)

        await repository.releaseActivation()
        let activationSucceeded = await activation.value
        XCTAssertTrue(activationSucceeded)
        XCTAssertEqual(model.channels, [secondChannel])
    }

    func testProtocolAlertUsesPlaybackTitleWhileReloadErrorsUseOperationTitle() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let udp = makeChannel(profileID: profile.id, url: "udp://239.1.1.1:5000", tvgID: nil, order: 0)
        let repository = RepositorySpy(profiles: [profile], channels: [profile.id: [udp]])
        let model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { now })

        await model.reload()
        model.select(channel: udp)
        XCTAssertEqual(model.alertTitle, "无法播放")
        XCTAssertEqual(model.alertMessage, "首版暂不支持组播地址")

        await repository.setReadFailure(true)
        await model.reload()
        XCTAssertEqual(model.alertTitle, "操作失败")
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private struct LoadedActiveBoundFixture {
        let repository: RepositorySpy
        let model: AppModel
        let activeProfile: SourceProfile
        let channels: [Channel]
        let epgChannels: [EPGChannel]
        let programmes: [Programme]
        let programmesByChannelID: [String: [Programme]]
        let automaticChannel: Channel
        let manualChannel: Channel
        let playbackRequest: PlaybackRequest
    }

    private func makeLoadedActiveBoundFixture(
        additionalProfiles: [SourceProfile],
        additionalChannels: [UUID: [Channel]] = [:],
        mutationLaneEvent: (@MainActor @Sendable (AppModel.ActiveMutationLaneEvent) -> Void)? = nil,
        beforeLibraryPresentationApply: @escaping @Sendable () async -> Void = {},
        now: Date
    ) async throws -> LoadedActiveBoundFixture {
        let active = makeProfile(
            id: "00000000-0000-0000-0000-000000000001",
            name: "Active",
            now: now
        )
        let automaticChannel = makeChannel(
            profileID: active.id,
            url: "https://example.test/automatic",
            tvgID: "automatic",
            order: 0
        )
        let manualChannel = makeChannel(
            profileID: active.id,
            url: "https://example.test/manual",
            tvgID: "unmatched",
            order: 1
        )
        let epgChannels = [
            EPGChannel(id: "automatic", displayNames: ["Automatic"], iconURL: nil),
            EPGChannel(id: "manual", displayNames: ["Manual"], iconURL: nil),
        ]
        let programmes = [
            Programme(
                id: "manual-current",
                xmltvChannelID: "manual",
                start: now.addingTimeInterval(-600),
                stop: now.addingTimeInterval(600),
                title: "Manual Current",
                subtitle: nil,
                summary: nil,
                categories: []
            ),
            Programme(
                id: "manual-next",
                xmltvChannelID: "manual",
                start: now.addingTimeInterval(600),
                stop: now.addingTimeInterval(1_200),
                title: "Manual Next",
                subtitle: nil,
                summary: nil,
                categories: []
            ),
        ]
        var channels = additionalChannels
        channels[active.id] = [automaticChannel, manualChannel]
        let repository = RepositorySpy(
            profiles: [active] + additionalProfiles,
            activeProfileID: active.id,
            channels: channels,
            epgChannels: [active.id: epgChannels],
            programmes: [active.id: programmes],
            manualMappings: [active.id: [manualChannel.id: "manual"]]
        )
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            mutationLaneEvent: mutationLaneEvent,
            beforeLibraryPresentationApply: beforeLibraryPresentationApply,
            now: { now }
        )

        let loaded = await model.reload()
        XCTAssertTrue(loaded)
        let programmesByChannelID = [
            automaticChannel.id: [],
            manualChannel.id: programmes,
        ]
        XCTAssertEqual(model.programmesByChannelID, programmesByChannelID)
        model.select(channel: manualChannel)
        let playbackRequest = try XCTUnwrap(model.presentedPlaybackRequest)

        return LoadedActiveBoundFixture(
            repository: repository,
            model: model,
            activeProfile: active,
            channels: [automaticChannel, manualChannel],
            epgChannels: epgChannels,
            programmes: programmes,
            programmesByChannelID: programmesByChannelID,
            automaticChannel: automaticChannel,
            manualChannel: manualChannel,
            playbackRequest: playbackRequest
        )
    }

    private func assertCompleteActiveBoundState(
        _ fixture: LoadedActiveBoundFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(fixture.model.activeProfile, fixture.activeProfile, file: file, line: line)
        XCTAssertEqual(fixture.model.channels, fixture.channels, file: file, line: line)
        XCTAssertEqual(fixture.model.epgChannels, fixture.epgChannels, file: file, line: line)
        XCTAssertEqual(
            fixture.model.programmesByChannelID,
            fixture.programmesByChannelID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.model.matchedEPGChannelID(for: fixture.automaticChannel),
            "automatic",
            file: file,
            line: line
        )
        XCTAssertNil(
            fixture.model.manualEPGChannelID(for: fixture.automaticChannel),
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.model.matchedEPGChannelID(for: fixture.manualChannel),
            "manual",
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.model.manualEPGChannelID(for: fixture.manualChannel),
            "manual",
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.model.presentedPlaybackRequest,
            fixture.playbackRequest,
            file: file,
            line: line
        )
        XCTAssertFalse(fixture.model.isLoading, file: file, line: line)
    }

    private func makeProfile(id: String, name: String, now: Date) -> SourceProfile {
        SourceProfile(
            id: UUID(uuidString: id)!,
            name: name,
            m3uURL: URL(string: "https://example.test/playlist.m3u")!,
            epgURL: URL(string: "https://example.test/epg.xml")!,
            m3uRefreshInterval: .manual,
            epgRefreshInterval: .manual,
            m3uStatus: ResourceRefreshStatus(),
            epgStatus: ResourceRefreshStatus(),
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeChannel(
        profileID: UUID,
        url: String,
        tvgID: String?,
        order: Int
    ) -> Channel {
        Channel(
            sourceProfileID: profileID,
            displayName: "Channel \(order)",
            streamURL: URL(string: url)!,
            tvgID: tvgID,
            tvgName: nil,
            logoURL: nil,
            groupTitle: "Group",
            attributes: [:],
            order: order
        )
    }
}

private actor RefreshCallProbe {
    struct Call: Sendable {
        let profileID: UUID
        let resources: Set<RefreshResource>
        let trigger: RefreshTrigger
    }

    private(set) var calls: [Call] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(profileID: UUID, resources: Set<RefreshResource>, trigger: RefreshTrigger) {
        calls.append(Call(profileID: profileID, resources: resources, trigger: trigger))
        let satisfied = waiters.filter { $0.count <= calls.count }
        waiters.removeAll { $0.count <= calls.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    /// Join point for refreshes the model starts on its own, which no caller
    /// awaits.
    func waitForCalls(count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count: count, continuation: continuation))
        }
    }
}

private actor AppModelAsyncGate {
    private var isArmed = false
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arm() {
        isArmed = true
    }

    func suspendIfArmed() async {
        guard isArmed else { return }
        isArmed = false
        isSuspended = true
        for waiter in suspensionWaiters {
            waiter.resume()
        }
        suspensionWaiters = []
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
        isSuspended = false
    }
}

@MainActor
private final class MutationGrantCanceller {
    let target: AppModel.ActiveMutationLaneEvent.Operation
    var task: Task<Bool, Never>?

    init(target: AppModel.ActiveMutationLaneEvent.Operation) {
        self.target = target
    }

    func observe(_ event: AppModel.ActiveMutationLaneEvent) {
        guard event == .acquired(target) else { return }
        task?.cancel()
    }
}

private final class AppModelTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        storedValue = value
    }

    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private actor AppModelManualRefreshGate {
    private var invocationCount = 0
    private var secondAttemptStarted = false
    private var secondAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondAttemptRelease: CheckedContinuation<Void, Never>?

    func outcomes(
        repository: RepositorySpy,
        profileID: UUID,
        resources: Set<RefreshResource>,
        now: Date
    ) async -> [RefreshOutcome] {
        invocationCount += 1
        for resource in resources {
            try? await repository.recordAttempt(
                profileID: profileID,
                resource: resource,
                at: now
            )
        }
        guard invocationCount > 1 else {
            return resources.map {
                RefreshOutcome(resource: $0, succeeded: false, message: "first failure")
            }
        }

        secondAttemptStarted = true
        for waiter in secondAttemptWaiters {
            waiter.resume()
        }
        secondAttemptWaiters = []
        await withCheckedContinuation { continuation in
            secondAttemptRelease = continuation
        }
        for resource in resources {
            try? await repository.recordSuccess(
                profileID: profileID,
                resource: resource,
                at: now
            )
        }
        return resources.map {
            RefreshOutcome(resource: $0, succeeded: true, message: nil)
        }
    }

    func waitUntilSecondAttemptStarts() async {
        guard !secondAttemptStarted else { return }
        await withCheckedContinuation { continuation in
            secondAttemptWaiters.append(continuation)
        }
    }

    func releaseSecondAttempt() {
        secondAttemptRelease?.resume()
        secondAttemptRelease = nil
    }
}

private actor AppModelConcurrentRefreshGate {
    enum Result: Sendable {
        case success
        case failure(String)
        case cancellation
        case empty
        case wrongResource
    }

    private struct Key: Hashable, Sendable {
        let resource: RefreshResource
        let ordinal: Int
    }

    private var invocationCounts: [RefreshResource: Int] = [:]
    private var started: Set<Key> = []
    private var startWaiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
    private var resultWaiters: [Key: CheckedContinuation<Result, Never>] = [:]
    private var pendingResults: [Key: Result] = [:]

    func outcomes(
        repository: RepositorySpy,
        profileID: UUID,
        resources: Set<RefreshResource>,
        now: Date,
        recordsAttempt: Bool = true
    ) async -> [RefreshOutcome] {
        guard let resource = resources.first else { return [] }
        let ordinal = invocationCounts[resource, default: 0] + 1
        invocationCounts[resource] = ordinal
        let key = Key(resource: resource, ordinal: ordinal)
        let attemptAt = now.addingTimeInterval(TimeInterval(ordinal))
        if recordsAttempt {
            try? await repository.recordAttempt(
                profileID: profileID,
                resource: resource,
                at: attemptAt
            )
        }

        started.insert(key)
        for waiter in startWaiters.removeValue(forKey: key) ?? [] {
            waiter.resume()
        }
        let result = await withCheckedContinuation { continuation in
            if let pendingResult = pendingResults.removeValue(forKey: key) {
                continuation.resume(returning: pendingResult)
            } else {
                resultWaiters[key] = continuation
            }
        }

        switch result {
        case .success:
            try? await repository.recordSuccess(
                profileID: profileID,
                resource: resource,
                at: attemptAt
            )
            return [RefreshOutcome(resource: resource, succeeded: true, message: nil)]
        case let .failure(message):
            return [RefreshOutcome(resource: resource, succeeded: false, message: message)]
        case .cancellation:
            return [RefreshOutcome(resource: resource, succeeded: false, message: "刷新已取消。")]
        case .empty:
            return []
        case .wrongResource:
            let wrongResource: RefreshResource = resource == .playlist ? .epg : .playlist
            return [RefreshOutcome(resource: wrongResource, succeeded: true, message: nil)]
        }
    }

    func waitUntilStarted(resource: RefreshResource, ordinal: Int) async {
        let key = Key(resource: resource, ordinal: ordinal)
        guard !started.contains(key) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func release(resource: RefreshResource, ordinal: Int, result: Result) {
        let key = Key(resource: resource, ordinal: ordinal)
        if let waiter = resultWaiters.removeValue(forKey: key) {
            waiter.resume(returning: result)
        } else {
            pendingResults[key] = result
        }
    }
}

private actor AppModelPersistedOutcomeGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        for waiter in suspensionWaiters {
            waiter.resume()
        }
        suspensionWaiters = []
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor LibraryReloadSettleProbe {
    private(set) var isComplete = false

    func recordCompletion() {
        isComplete = true
    }
}

private actor AppModelRefreshDownloader: RemoteResourceDownloading {
    private let payload: Data?
    private let error: URLError.Code?
    private let gatesCancellation: Bool
    private let gatesCompletion: Bool
    private var isStarted = false
    private var isCancellationBlocked = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationRelease: CheckedContinuation<Void, Never>?
    private var completionRelease: CheckedContinuation<Void, Never>?

    init(
        payload: Data? = nil,
        error: URLError.Code? = nil,
        gatesCancellation: Bool = false,
        gatesCompletion: Bool = false
    ) {
        self.payload = payload
        self.error = error
        self.gatesCancellation = gatesCancellation
        self.gatesCompletion = gatesCompletion
    }

    func download(_ request: RemoteResourceRequest) async throws -> DownloadedResource {
        isStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters = []

        if gatesCompletion {
            await withCheckedContinuation { continuation in
                completionRelease = continuation
            }
        }

        if gatesCancellation {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch is CancellationError {
                isCancellationBlocked = true
                for waiter in cancellationBlockedWaiters {
                    waiter.resume()
                }
                cancellationBlockedWaiters = []
                await withCheckedContinuation { continuation in
                    cancellationRelease = continuation
                }
                throw CancellationError()
            }
        }
        if let error {
            throw URLError(error)
        }
        guard let payload else {
            throw URLError(.resourceUnavailable)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelRefreshDownloader-\(UUID().uuidString)")
        try payload.write(to: url, options: .atomic)
        _ = request
        return DownloadedResource(temporaryFileURL: url, byteCount: Int64(payload.count))
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationIsBlocked() async {
        guard !isCancellationBlocked else { return }
        await withCheckedContinuation { continuation in
            cancellationBlockedWaiters.append(continuation)
        }
    }

    func releaseCancellation() {
        cancellationRelease?.resume()
        cancellationRelease = nil
    }

    func releaseCompletion() {
        completionRelease?.resume()
        completionRelease = nil
    }
}
