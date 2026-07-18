// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerCore

@MainActor
final class RefreshCoordinatorTests: XCTestCase {
    private let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
    private let now = Date(timeIntervalSince1970: 8_000)

    func testPlaylistSuccessAndMalformedEPGHaveIndependentOutcomesAndSnapshots() async throws {
        let profile = makeProfile()
        let originalPlaylist = [channel(name: "Original")]
        let originalEPG = [EPGChannel(id: "old", displayNames: ["Old"], iconURL: nil)]
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profileID: originalPlaylist],
            epgChannels: [profileID: originalEPG]
        )
        let downloader = FakeRemoteDownloader(data: [
            .playlist: validPlaylist(name: "Replacement"),
            .epg: Data("<tv><channel".utf8)
        ])
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.epg, .playlist],
            trigger: .manual
        )

        XCTAssertEqual(outcomes.map(\.resource), [.playlist, .epg])
        XCTAssertEqual(outcomes.map(\.succeeded), [true, false])
        XCTAssertNil(outcomes[0].message)
        XCTAssertNotNil(outcomes[1].message)

        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.channels[profileID]?.map(\.displayName), ["Replacement"])
        XCTAssertEqual(snapshot.epgChannels[profileID], originalEPG)
        XCTAssertEqual(snapshot.playlistInstallCount, 1)
        XCTAssertEqual(snapshot.epgInstallCount, 0)
        let updated = try XCTUnwrap(snapshot.profiles.first)
        XCTAssertEqual(updated.m3uStatus.state, .succeeded)
        XCTAssertEqual(updated.m3uStatus.lastSuccessAt, now)
        XCTAssertEqual(updated.epgStatus.state, .failed)
        XCTAssertEqual(updated.epgStatus.lastSuccessAt, profile.epgStatus.lastSuccessAt)
        XCTAssertEqual(
            snapshot.events.filter { $0.resource == .playlist },
            [
                .attempt(profileID, .playlist),
                .installPlaylist(profileID),
                .success(profileID, .playlist)
            ]
        )
        XCTAssertEqual(
            snapshot.events.filter { $0.resource == .epg },
            [
                .attempt(profileID, .epg),
                .failure(profileID, .epg, try XCTUnwrap(updated.epgStatus.errorSummary))
            ]
        )
        await assertTemporaryDownloadsWereDeleted(downloader)
    }

    func testBothMalformedResourcesPreserveBothLastKnownGoodSnapshots() async {
        let profile = makeProfile()
        let originalPlaylist = [channel(name: "Original")]
        let originalEPG = [EPGChannel(id: "old", displayNames: ["Old"], iconURL: nil)]
        let repository = RepositorySpy(
            profiles: [profile],
            channels: [profileID: originalPlaylist],
            epgChannels: [profileID: originalEPG]
        )
        let downloader = FakeRemoteDownloader(data: [
            .playlist: Data("not an m3u".utf8),
            .epg: Data("not xml".utf8)
        ])
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.playlist, .epg],
            trigger: .foreground
        )

        XCTAssertEqual(outcomes.map(\.succeeded), [false, false])
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.channels[profileID], originalPlaylist)
        XCTAssertEqual(snapshot.epgChannels[profileID], originalEPG)
        XCTAssertEqual(snapshot.playlistInstallCount, 0)
        XCTAssertEqual(snapshot.epgInstallCount, 0)
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.lastSuccessAt, profile.m3uStatus.lastSuccessAt)
        XCTAssertEqual(snapshot.profiles[0].epgStatus.lastSuccessAt, profile.epgStatus.lastSuccessAt)
        await assertTemporaryDownloadsWereDeleted(downloader)
    }

    func testPlaylistCommitSaveFailureCannotActivateNewSnapshotWithFailedStatus() async {
        let original = [channel(name: "Original")]
        let repository = RepositorySpy(
            profiles: [makeProfile()],
            channels: [profileID: original],
            failedRefreshCommits: [.playlist]
        )
        let downloader = FakeRemoteDownloader(
            data: [.playlist: validPlaylist(name: "Replacement")]
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.playlist],
            trigger: .manual
        )

        XCTAssertEqual(outcomes.map(\.succeeded), [false])
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.channels[profileID], original)
        XCTAssertEqual(snapshot.playlistInstallCount, 0)
        XCTAssertEqual(snapshot.events.filter { $0 == .success(profileID, .playlist) }.count, 0)
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.state, .failed)
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.lastSuccessAt, makeProfile().m3uStatus.lastSuccessAt)
        await assertTemporaryDownloadsWereDeleted(downloader)
    }

    func testEPGCommitSaveFailureCannotActivateNewSnapshotWithFailedStatus() async {
        let original = [EPGChannel(id: "original", displayNames: ["Original"], iconURL: nil)]
        let repository = RepositorySpy(
            profiles: [makeProfile()],
            epgChannels: [profileID: original],
            failedRefreshCommits: [.epg]
        )
        let downloader = FakeRemoteDownloader(data: [.epg: validEPG()])
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.epg],
            trigger: .manual
        )

        XCTAssertEqual(outcomes.map(\.succeeded), [false])
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.epgChannels[profileID], original)
        XCTAssertEqual(snapshot.epgInstallCount, 0)
        XCTAssertEqual(snapshot.events.filter { $0 == .success(profileID, .epg) }.count, 0)
        XCTAssertEqual(snapshot.profiles[0].epgStatus.state, .failed)
        XCTAssertEqual(snapshot.profiles[0].epgStatus.lastSuccessAt, makeProfile().epgStatus.lastSuccessAt)
        await assertTemporaryDownloadsWereDeleted(downloader)
    }

    func testRecordFailureSaveFaultReturnsSanitizedFailureWithoutActivatingSnapshot() async throws {
        let sensitiveURL = URL(string: "https://user:pass@example.test/list?token=secret")!
        let original = [channel(name: "Original")]
        let repository = RepositorySpy(
            profiles: [makeProfile(m3uURL: sensitiveURL)],
            channels: [profileID: original],
            failedRefreshCommits: [.playlist],
            failsRecordFailure: true
        )
        let downloader = FakeRemoteDownloader(
            data: [.playlist: validPlaylist(name: "Replacement")]
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.playlist],
            trigger: .manual
        )

        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertFalse(outcome.succeeded)
        let message = try XCTUnwrap(outcome.message)
        XCTAssertTrue(message.contains("https://example.test/list"))
        XCTAssertFalse(message.contains("secret"))
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.channels[profileID], original)
        XCTAssertEqual(snapshot.playlistInstallCount, 0)
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.state, .refreshing)
        XCTAssertEqual(snapshot.events.filter { $0 == .success(profileID, .playlist) }.count, 0)
        await assertTemporaryDownloadsWereDeleted(downloader)
    }

    func testSimultaneousSameProfileResourceRefreshesShareOneInFlightTask() async {
        let repository = RepositorySpy(profiles: [makeProfile()])
        let downloader = FakeRemoteDownloader(
            data: [.playlist: validPlaylist(name: "One")],
            delay: .milliseconds(100)
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)
        let id = profileID

        async let first = coordinator.refresh(
            profileID: id,
            resources: [.playlist],
            trigger: .manual
        )
        async let second = coordinator.refresh(
            profileID: id,
            resources: [.playlist],
            trigger: .background
        )
        let results = await (first, second)
        let playlistInvocationCount = await downloader.invocationCount(for: .playlist)

        XCTAssertEqual(results.0, results.1)
        XCTAssertEqual(playlistInvocationCount, 1)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.events.filter { $0 == .attempt(profileID, .playlist) }.count, 1)
        XCTAssertEqual(snapshot.events.filter { $0 == .success(profileID, .playlist) }.count, 1)
        await assertTemporaryDownloadsWereDeleted(downloader)
    }

    func testCancellingSoleWaiterReturnsPromptlyAndCancelsSharedWork() async throws {
        let repository = RepositorySpy(profiles: [makeProfile()])
        let downloader = FakeRemoteDownloader(
            data: [.playlist: validPlaylist(name: "Unused")],
            isSuspended: true
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)
        let completion = OutcomeProbe()
        let caller = Task {
            let outcomes = await coordinator.refresh(
                profileID: profileID,
                resources: [.playlist],
                trigger: .manual
            )
            await completion.record(outcomes)
        }
        await waitUntil { await downloader.invocationCount(for: .playlist) == 1 }

        caller.cancel()

        await waitUntil(timeout: .milliseconds(250)) { await completion.value != nil }
        let completedOutcomes = await completion.value
        let promptOutcome = try XCTUnwrap(completedOutcomes?.first)
        XCTAssertFalse(promptOutcome.succeeded)
        XCTAssertEqual(promptOutcome.message, "刷新已取消。")
        await waitUntil { await downloader.cancellationCount(for: .playlist) == 1 }
        await waitUntil {
            let snapshot = await repository.snapshot()
            return snapshot.events.contains {
                if case .failure(self.profileID, .playlist, _) = $0 { return true }
                return false
            }
        }

        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.playlistInstallCount, 0)
        XCTAssertEqual(snapshot.events.filter { $0 == .attempt(profileID, .playlist) }.count, 1)
        XCTAssertEqual(snapshot.events.filter { $0 == .success(profileID, .playlist) }.count, 0)
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.state, .failed)
        await assertTemporaryDownloadsWereDeleted(downloader)
        _ = await caller.result
    }

    func testRefreshArrivingWhileCancelledFlightDrainsStartsFreshWork() async throws {
        let repository = RepositorySpy(profiles: [makeProfile()])
        let downloader = FakeRemoteDownloader(
            data: [.playlist: validPlaylist(name: "Retry")],
            isSuspended: true,
            cancellationDelay: .milliseconds(150)
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)
        let firstCompletion = OutcomeProbe()
        let retryCompletion = OutcomeProbe()
        let first = Task {
            let outcomes = await coordinator.refresh(
                profileID: profileID,
                resources: [.playlist],
                trigger: .manual
            )
            await firstCompletion.record(outcomes)
        }
        await waitUntil { await downloader.invocationCount(for: .playlist) == 1 }
        first.cancel()
        await waitUntil(timeout: .milliseconds(250)) { await firstCompletion.value != nil }

        let retry = Task {
            let outcomes = await coordinator.refresh(
                profileID: profileID,
                resources: [.playlist],
                trigger: .manual
            )
            await retryCompletion.record(outcomes)
        }
        try await Task.sleep(for: .milliseconds(50))
        let invocationCountWhileDraining = await downloader.invocationCount(for: .playlist)
        let prematureRetryOutcomes = await retryCompletion.value
        XCTAssertEqual(invocationCountWhileDraining, 1)
        XCTAssertNil(prematureRetryOutcomes)

        await waitUntil { await downloader.invocationCount(for: .playlist) == 2 }
        await downloader.resume(.playlist)
        await waitUntil { await retryCompletion.value != nil }

        let firstOutcomes = await firstCompletion.value
        let retryOutcomes = await retryCompletion.value
        XCTAssertEqual(firstOutcomes?.first?.succeeded, false)
        XCTAssertEqual(firstOutcomes?.first?.message, "刷新已取消。")
        XCTAssertEqual(retryOutcomes?.first?.succeeded, true)
        XCTAssertNil(retryOutcomes?.first?.message)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.playlistInstallCount, 1)
        XCTAssertEqual(snapshot.events.filter { $0 == .attempt(profileID, .playlist) }.count, 2)
        XCTAssertEqual(snapshot.events.filter { $0 == .success(profileID, .playlist) }.count, 1)
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.state, .succeeded)
        let cancellationCount = await downloader.cancellationCount(for: .playlist)
        XCTAssertEqual(cancellationCount, 1)
        await assertTemporaryDownloadsWereDeleted(downloader)
        _ = await first.result
        _ = await retry.result
    }

    func testCancellingOneOfTwoWaitersDoesNotCancelSharedWork() async throws {
        let repository = RepositorySpy(profiles: [makeProfile()])
        let downloader = FakeRemoteDownloader(
            data: [.playlist: validPlaylist(name: "Shared")],
            isSuspended: true
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)
        let firstCompletion = OutcomeProbe()
        let secondCompletion = OutcomeProbe()
        let first = Task {
            let outcomes = await coordinator.refresh(
                profileID: profileID,
                resources: [.playlist],
                trigger: .manual
            )
            await firstCompletion.record(outcomes)
        }
        await waitUntil { await downloader.invocationCount(for: .playlist) == 1 }
        let second = Task {
            let outcomes = await coordinator.refresh(
                profileID: profileID,
                resources: [.playlist],
                trigger: .background
            )
            await secondCompletion.record(outcomes)
        }
        try await Task.sleep(for: .milliseconds(30))

        first.cancel()

        await waitUntil(timeout: .milliseconds(250)) { await firstCompletion.value != nil }
        let firstOutcomes = await firstCompletion.value
        let cancelledOutcome = try XCTUnwrap(firstOutcomes?.first)
        XCTAssertFalse(cancelledOutcome.succeeded)
        XCTAssertEqual(cancelledOutcome.message, "刷新已取消。")
        let prematureSecondOutcomes = await secondCompletion.value
        let invocationCount = await downloader.invocationCount(for: .playlist)
        let cancellationCount = await downloader.cancellationCount(for: .playlist)
        XCTAssertNil(prematureSecondOutcomes)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(cancellationCount, 0)

        await downloader.resume(.playlist)
        await waitUntil { await secondCompletion.value != nil }
        let secondOutcomes = await secondCompletion.value
        let successfulOutcome = try XCTUnwrap(secondOutcomes?.first)
        XCTAssertTrue(successfulOutcome.succeeded)
        XCTAssertNil(successfulOutcome.message)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.playlistInstallCount, 1)
        XCTAssertEqual(snapshot.events.filter { $0 == .attempt(profileID, .playlist) }.count, 1)
        XCTAssertEqual(snapshot.events.filter { $0 == .success(profileID, .playlist) }.count, 1)
        XCTAssertEqual(snapshot.events.compactMap(\.resource).filter { $0 == .playlist }.count, 3)
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.state, .succeeded)
        await assertTemporaryDownloadsWereDeleted(downloader)
        _ = await first.result
        _ = await second.result
    }

    func testPlaylistAndEPGUseIndependentInFlightKeys() async {
        let repository = RepositorySpy(profiles: [makeProfile()])
        let downloader = FakeRemoteDownloader(
            data: [
                .playlist: validPlaylist(name: "One"),
                .epg: validEPG()
            ],
            delay: .milliseconds(50)
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.epg, .playlist],
            trigger: .background
        )
        let playlistInvocationCount = await downloader.invocationCount(for: .playlist)
        let epgInvocationCount = await downloader.invocationCount(for: .epg)

        XCTAssertEqual(outcomes.map(\.succeeded), [true, true])
        XCTAssertEqual(playlistInvocationCount, 1)
        XCTAssertEqual(epgInvocationCount, 1)
        await assertTemporaryDownloadsWereDeleted(downloader)
    }

    func testUnsupportedProfileURLFailsOnceWithoutCallingDownloader() async {
        let profile = makeProfile(m3uURL: URL(string: "ftp://receiver.local/list.m3u")!)
        let repository = RepositorySpy(profiles: [profile])
        let downloader = FakeRemoteDownloader(data: [.playlist: validPlaylist(name: "Unused")])
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.playlist],
            trigger: .manual
        )
        let playlistInvocationCount = await downloader.invocationCount(for: .playlist)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].succeeded)
        XCTAssertEqual(playlistInvocationCount, 0)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profileLookupCount, 1)
        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(snapshot.events.first, .attempt(profileID, .playlist))
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.state, .failed)
    }

    func testFailureSummaryUsesRedactedURLAndNeverLeaksCredentials() async throws {
        let sensitiveURL = URL(
            string: "https://user:pass@example.test/path?token=secret#fragment"
        )!
        let repository = RepositorySpy(profiles: [makeProfile(m3uURL: sensitiveURL)])
        let downloader = FakeRemoteDownloader(
            data: [:],
            failures: [.playlist: .connection]
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.playlist],
            trigger: .manual
        )
        let outcome = try XCTUnwrap(outcomes.first)

        let message = try XCTUnwrap(outcome.message)
        XCTAssertTrue(message.contains("https://example.test/path"))
        XCTAssertFalse(message.contains("user"))
        XCTAssertFalse(message.contains("pass"))
        XCTAssertFalse(message.contains("token"))
        XCTAssertFalse(message.contains("secret"))
        XCTAssertLessThanOrEqual(message.count, 240)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.errorSummary, message)
    }

    func testLongFailureSummaryIsDeterministicallyCappedAt240Characters() async throws {
        let path = String(repeating: "a", count: 400)
        let url = URL(string: "https://example.test/\(path)?token=secret")!
        let repository = RepositorySpy(profiles: [makeProfile(m3uURL: url)])
        let downloader = FakeRemoteDownloader(
            data: [:],
            failures: [.playlist: .connection]
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.playlist],
            trigger: .manual
        )
        let outcome = try XCTUnwrap(outcomes.first)

        let message = try XCTUnwrap(outcome.message)
        XCTAssertEqual(message.count, 240)
        XCTAssertFalse(message.contains("token"))
        XCTAssertFalse(message.contains("secret"))
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles[0].m3uStatus.errorSummary, message)
    }

    func testCancellationBecomesTerminalFailureWithoutGenericErrorText() async throws {
        let repository = RepositorySpy(profiles: [makeProfile()])
        let downloader = FakeRemoteDownloader(
            data: [:],
            failures: [.epg: .cancelled]
        )
        let coordinator = makeCoordinator(repository: repository, downloader: downloader)

        let outcomes = await coordinator.refresh(
            profileID: profileID,
            resources: [.epg],
            trigger: .manual
        )
        let outcome = try XCTUnwrap(outcomes.first)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.message, "刷新已取消。")
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.profiles[0].epgStatus.state, .failed)
        XCTAssertEqual(snapshot.profiles[0].epgStatus.errorSummary, "刷新已取消。")
    }

    private func makeCoordinator(
        repository: RepositorySpy,
        downloader: FakeRemoteDownloader
    ) -> RefreshCoordinator {
        let fixedNow = now
        return RefreshCoordinator(
            repository: repository,
            downloader: downloader,
            now: { fixedNow }
        )
    }

    private func makeProfile(
        m3uURL: URL = URL(string: "https://example.test/list.m3u")!,
        epgURL: URL = URL(string: "https://example.test/guide.xml")!
    ) -> SourceProfile {
        SourceProfile(
            id: profileID,
            name: "Home",
            m3uURL: m3uURL,
            epgURL: epgURL,
            m3uRefreshInterval: .sixHours,
            epgRefreshInterval: .daily,
            m3uStatus: ResourceRefreshStatus(
                lastAttemptAt: Date(timeIntervalSince1970: 1_000),
                lastSuccessAt: Date(timeIntervalSince1970: 2_000),
                state: .succeeded
            ),
            epgStatus: ResourceRefreshStatus(
                lastAttemptAt: Date(timeIntervalSince1970: 3_000),
                lastSuccessAt: Date(timeIntervalSince1970: 4_000),
                state: .succeeded
            ),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 4_000)
        )
    }

    private func channel(name: String) -> Channel {
        Channel(
            sourceProfileID: profileID,
            displayName: name,
            streamURL: URL(string: "https://stream.example/\(name)")!,
            tvgID: nil,
            tvgName: nil,
            logoURL: nil,
            groupTitle: nil,
            attributes: [:],
            order: 0
        )
    }

    private func validPlaylist(name: String) -> Data {
        Data(
            """
            #EXTM3U
            #EXTINF:-1,\(name)
            https://stream.example/live
            """.utf8
        )
    }

    private func validEPG() -> Data {
        Data(
            """
            <tv>
              <channel id="news"><display-name>News</display-name></channel>
            </tv>
            """.utf8
        )
    }

    private func assertTemporaryDownloadsWereDeleted(
        _ downloader: FakeRemoteDownloader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let files = await downloader.producedFiles()
        XCTAssertFalse(files.isEmpty, file: file, line: line)
        XCTAssertTrue(
            files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            file: file,
            line: line
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor FakeRemoteDownloader: RemoteResourceDownloading {
    enum Failure: Sendable {
        case connection
        case cancelled
    }

    private let data: [RefreshResource: Data]
    private let failures: [RefreshResource: Failure]
    private let delay: Duration?
    private let isSuspended: Bool
    private let cancellationDelay: Duration?
    private var invocationCounts: [RefreshResource: Int] = [:]
    private var cancellationCounts: [RefreshResource: Int] = [:]
    private var resumedResources: Set<RefreshResource> = []
    private var files: [URL] = []

    init(
        data: [RefreshResource: Data],
        failures: [RefreshResource: Failure] = [:],
        delay: Duration? = nil,
        isSuspended: Bool = false,
        cancellationDelay: Duration? = nil
    ) {
        self.data = data
        self.failures = failures
        self.delay = delay
        self.isSuspended = isSuspended
        self.cancellationDelay = cancellationDelay
    }

    func download(_ request: RemoteResourceRequest) async throws -> DownloadedResource {
        invocationCounts[request.resource, default: 0] += 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeRemoteDownloader-\(UUID().uuidString)")
        try Data("partial".utf8).write(to: url, options: .atomic)
        files.append(url)
        do {
            if let delay {
                try await Task.sleep(for: delay)
            }
            while isSuspended, !resumedResources.contains(request.resource) {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch is CancellationError {
            cancellationCounts[request.resource, default: 0] += 1
            if let cancellationDelay {
                await Task.detached {
                    try? await Task.sleep(for: cancellationDelay)
                }.value
            }
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        switch failures[request.resource] {
        case .connection:
            try? FileManager.default.removeItem(at: url)
            throw LeakyDownloadError(
                description: "could not load \(request.url.absoluteString) token=secret"
            )
        case .cancelled:
            try? FileManager.default.removeItem(at: url)
            throw RemoteDownloadError.cancelled
        case nil:
            break
        }
        guard let payload = data[request.resource] else {
            try? FileManager.default.removeItem(at: url)
            throw URLError(.resourceUnavailable)
        }
        try payload.write(to: url, options: .atomic)
        return DownloadedResource(temporaryFileURL: url, byteCount: Int64(payload.count))
    }

    func invocationCount(for resource: RefreshResource) -> Int {
        invocationCounts[resource, default: 0]
    }

    func cancellationCount(for resource: RefreshResource) -> Int {
        cancellationCounts[resource, default: 0]
    }

    func resume(_ resource: RefreshResource) {
        resumedResources.insert(resource)
    }

    func producedFiles() -> [URL] {
        files
    }
}

private actor OutcomeProbe {
    private(set) var value: [RefreshOutcome]?

    func record(_ outcomes: [RefreshOutcome]) {
        value = outcomes
    }
}

private struct LeakyDownloadError: Error, CustomStringConvertible, Sendable {
    let description: String
}

private extension RepositorySpy.Event {
    var resource: RefreshResource? {
        switch self {
        case .installPlaylist:
            .playlist
        case .installEPG:
            .epg
        case let .attempt(_, resource),
             let .success(_, resource),
             let .failure(_, resource, _):
            resource
        }
    }
}
