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

private actor AppModelRefreshDownloader: RemoteResourceDownloading {
    private let payload: Data?
    private let error: URLError.Code?
    private let gatesCancellation: Bool
    private var isStarted = false
    private var isCancellationBlocked = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationRelease: CheckedContinuation<Void, Never>?

    init(
        payload: Data? = nil,
        error: URLError.Code? = nil,
        gatesCancellation: Bool = false
    ) {
        self.payload = payload
        self.error = error
        self.gatesCancellation = gatesCancellation
    }

    func download(_ request: RemoteResourceRequest) async throws -> DownloadedResource {
        isStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters = []

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
}
