// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayer
@testable import VPlayerCore
@testable import VPlayerPlayback

@MainActor
final class AppModelTests: XCTestCase {
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
        XCTAssertEqual(model.programmesByChannelID[activeChannel.id], [current])
        XCTAssertEqual(model.matchedEPGChannelID(for: activeChannel), "active-epg")
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.programmeRequests, [
            .init(
                profileID: active.id,
                xmltvChannelID: "active-epg",
                overlapping: now.addingTimeInterval(-3_600)..<now.addingTimeInterval(24 * 3_600)
            )
        ])
        XCTAssertFalse(snapshot.programmeRequests.contains { $0.profileID == inactive.id })
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
            let coordinator = RefreshCoordinator(
                repository: repository,
                downloader: downloader,
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
            for _ in 0..<10 { await Task.yield() }
            manualWaiter.cancel()
            await manualWaiter.value

            XCTAssertEqual(model.profiles.first?.m3uStatus.lastAttemptAt, manualStartedAt, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.state, .failed, scenario.name)
            XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。", scenario.name)

            await downloader.releaseCompletion()
            let originalOutcomes = await originalWaiter.value
            XCTAssertEqual(originalOutcomes.first?.succeeded, true, scenario.name)
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
        let coordinator = RefreshCoordinator(
            repository: repository,
            downloader: downloader,
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
        let originalWaiter = Task {
            await coordinator.refresh(
                profileID: profile.id,
                resources: [.playlist],
                trigger: .foreground
            )
        }
        await downloader.waitUntilStarted()
        clock.value = manualStartedAt
        let manualWaiter = Task {
            await model.refresh(profileID: profile.id, resource: .playlist)
        }
        await eventually {
            model.profiles.first?.m3uStatus.lastAttemptAt == manualStartedAt
                && model.profiles.first?.m3uStatus.state == .refreshing
        }
        for _ in 0..<10 { await Task.yield() }
        manualWaiter.cancel()
        await manualWaiter.value
        XCTAssertEqual(model.profiles.first?.m3uStatus.errorSummary, "刷新已取消。")

        await downloader.releaseCompletion()
        let originalOutcomes = await originalWaiter.value
        let terminalMessage = originalOutcomes.first?.message
        XCTAssertEqual(originalOutcomes.first?.succeeded, false)
        XCTAssertNotNil(terminalMessage)
        XCTAssertNotEqual(terminalMessage, "刷新已取消。")

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

    func testLibraryChangeNotificationsDuringReloadCoalesceToOneLatestFollowUp() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = makeProfile(id: "00000000-0000-0000-0000-000000000001", name: "Source", now: now)
        let channel = makeChannel(profileID: profile.id, url: "https://example.test/live", tvgID: nil, order: 0)
        let repository = RepositorySpy(profiles: [profile], channels: [profile.id: [channel]])
        let changes = LibraryChangeSignal()
        let model = AppModel(
            repository: repository,
            refresh: { _, _, _ in [] },
            libraryChanges: changes,
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
        await repository.releaseChannelRead()
        await repository.waitUntilChannelReadIsBlocked()

        var snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileLookupCount, 3)

        await repository.gateNextChannelRead()
        await repository.releaseChannelRead()
        try await Task.sleep(for: .milliseconds(100))
        snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileLookupCount, 3)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.channels, [channel])

        if snapshot.profileLookupCount > 3 {
            await repository.releaseChannelRead()
        }
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
        await repository.gateNextActivation()
        let activation = Task { await model.activate(profileID: second.id) }
        await repository.waitUntilActivationIsBlocked()

        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.channels.isEmpty)
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

    func record(profileID: UUID, resources: Set<RefreshResource>, trigger: RefreshTrigger) {
        calls.append(Call(profileID: profileID, resources: resources, trigger: trigger))
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
