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
        let model = AppModel(repository: RepositorySpy(profiles: [profile]), refresh: { _, _, _ in [] }, now: { now })

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
