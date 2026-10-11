// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayer
@testable import VPlayerCore

@MainActor
final class AppModelProgrammeWindowTests: XCTestCase {
    func testNextDayReloadsLocalProgrammesWithManualSubscriptionsAndPreservesPlayback() async {
        let fixture = Fixture()
        await fixture.model.reload()
        fixture.model.select(channel: fixture.channel)
        let request = fixture.model.presentedPlaybackRequest
        XCTAssertEqual(fixture.model.programmesByChannelID[fixture.channel.id]?.map(\.title), ["今天"])

        fixture.clock.advance(25.5 * 3_600)
        let refreshed = await fixture.model.refreshProgrammeWindowIfNeeded()

        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.model.programmesByChannelID[fixture.channel.id]?.map(\.title), ["明天"])
        XCTAssertEqual(fixture.model.presentedPlaybackRequest, request)
        XCTAssertEqual(fixture.model.channels, [fixture.channel])
        let snapshot = await fixture.repository.snapshot()
        XCTAssertEqual(snapshot.programmeBatchRequests.count, 2)
        XCTAssertEqual(snapshot.channelLookupCount, 1, "滚动窗口无需重载频道列表")
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertNil(fixture.model.alertMessage)
    }

    func testWindowRollsHourlyAndDoesNotRepeatReadsOnEveryTick() async {
        let fixture = Fixture()
        await fixture.model.reload()
        fixture.clock.advance(3_599)
        let beforeHour = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertFalse(beforeHour)
        fixture.clock.advance(1)
        let atHour = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertTrue(atHour)
        let sameTick = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertFalse(sameTick)
        let snapshot = await fixture.repository.snapshot()
        XCTAssertEqual(snapshot.programmeBatchRequests.count, 2)
        XCTAssertEqual(snapshot.programmeBatchRequests.last?.overlapping,
                       fixture.clock.date.addingTimeInterval(-3_600)..<fixture.clock.date.addingTimeInterval(24 * 3_600))
    }

    func testClockMovingBackwardsReloadsTheEarlierWindow() async {
        let fixture = Fixture()
        fixture.clock.advance(26 * 3_600)
        await fixture.model.reload()
        fixture.clock.advance(-26 * 3_600)
        let refreshed = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.model.programmesByChannelID[fixture.channel.id]?.first?.title, "今天")
    }

    func testFailedWindowReadPreservesPresentationAndCanRetryImmediately() async {
        let fixture = Fixture()
        await fixture.model.reload()
        let previous = fixture.model.programmesByChannelID
        fixture.clock.advance(26 * 3_600)
        await fixture.repository.setReadFailure(true)
        let failed = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertFalse(failed)
        XCTAssertEqual(fixture.model.programmesByChannelID, previous)
        XCTAssertNil(fixture.model.alertMessage, "自动本地重读失败不能反复弹窗")
        await fixture.repository.setReadFailure(false)
        let retried = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertTrue(retried)
        XCTAssertEqual(fixture.model.programmesByChannelID[fixture.channel.id]?.first?.title, "明天")
    }

    func testForegroundMaintenanceChecksImmediatelyAndStopsOnCancellation() async {
        let fixture = Fixture()
        await fixture.model.reload()
        fixture.clock.advance(26 * 3_600)
        let task = Task { await fixture.model.maintainProgrammeWindow() }
        for _ in 0..<200 {
            if fixture.model.programmesByChannelID[fixture.channel.id]?.first?.title == "明天" { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.model.programmesByChannelID[fixture.channel.id]?.first?.title, "明天")
        task.cancel()
        await task.value
        let snapshot = await fixture.repository.snapshot()
        XCTAssertEqual(snapshot.programmeBatchRequests.count, 2)
    }

    func testWindowCheckDoesNotSupersedeAnInFlightFullReload() async {
        let fixture = Fixture()
        await fixture.model.reload()
        fixture.clock.advance(26 * 3_600)
        await fixture.repository.gateNextChannelRead()
        let task = Task { await fixture.model.reload() }
        await fixture.repository.waitUntilChannelReadIsBlocked()
        let skipped = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertFalse(skipped)
        await fixture.repository.releaseChannelRead()
        let loaded = await task.value
        XCTAssertTrue(loaded)
        let refreshed = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertFalse(refreshed, "完整重载已经更新窗口时间")
        XCTAssertEqual(fixture.model.programmesByChannelID[fixture.channel.id]?.first?.title, "明天")
    }

    func testWindowCheckWaitsForInitialLibraryLoad() async {
        let fixture = Fixture()
        let refreshed = await fixture.model.refreshProgrammeWindowIfNeeded()
        XCTAssertFalse(refreshed)
        let snapshot = await fixture.repository.snapshot()
        XCTAssertEqual(snapshot.profileLookupCount, 0)
    }

    @MainActor
    private struct Fixture {
        let clock = WindowClock(Date(timeIntervalSince1970: 2_000_000_000))
        let repository: RepositorySpy
        let model: AppModel
        let channel: Channel

        init() {
            let date = clock.date
            let profile = SourceProfile(
                id: UUID(), name: "测试源",
                m3uURL: URL(string: "https://example.test/list.m3u")!,
                epgURL: URL(string: "https://example.test/guide.xml")!,
                m3uRefreshInterval: .manual, epgRefreshInterval: .manual,
                m3uStatus: ResourceRefreshStatus(), epgStatus: ResourceRefreshStatus(),
                createdAt: date, updatedAt: date
            )
            channel = Channel(
                sourceProfileID: profile.id, displayName: "新闻",
                streamURL: URL(string: "https://example.test/live")!, tvgID: "news",
                tvgName: nil, logoURL: nil, groupTitle: nil, attributes: [:], order: 0
            )
            let programmes = [("今天", 0.0), ("明天", 25.0)].map { title, hour in
                Programme(id: title, xmltvChannelID: "news",
                    start: date.addingTimeInterval(hour * 3_600),
                    stop: date.addingTimeInterval((hour + 2) * 3_600),
                    title: title, subtitle: nil, summary: nil, categories: [])
            }
            repository = RepositorySpy(
                profiles: [profile], activeProfileID: profile.id,
                channels: [profile.id: [channel]],
                epgChannels: [profile.id: [EPGChannel(id: "news", displayNames: ["新闻"], iconURL: nil)]],
                programmes: [profile.id: programmes]
            )
            let clock = clock
            model = AppModel(repository: repository, refresh: { _, _, _ in
                XCTFail("窗口更新不应发起网络刷新")
                return []
            }, now: { clock.date })
        }
    }
}

private final class WindowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}
