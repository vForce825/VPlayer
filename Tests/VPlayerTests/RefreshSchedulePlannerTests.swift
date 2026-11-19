// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerCore

final class RefreshSchedulePlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testDueResourcesUsesEachResourcesOwnIntervalAndLastSuccess() {
        let profile = profile(
            m3uInterval: .sixHours,
            epgInterval: .daily,
            m3uLastSuccess: now.addingTimeInterval(-7 * 3_600),
            epgLastSuccess: now.addingTimeInterval(-3_600)
        )

        XCTAssertEqual(
            RefreshSchedulePlanner().dueResources(for: profile, now: now),
            [.playlist]
        )
    }

    func testManualResourceIsNeverDueEvenWithoutASuccess() {
        let profile = profile(
            m3uInterval: .manual,
            epgInterval: .manual,
            m3uLastSuccess: nil,
            epgLastSuccess: nil
        )

        XCTAssertEqual(
            RefreshSchedulePlanner().dueResources(for: profile, now: now),
            []
        )
    }

    func testNeverSuccessfulNonManualResourceIsImmediatelyDue() {
        let profile = profile(
            m3uInterval: .hourly,
            epgInterval: .manual,
            m3uLastSuccess: nil,
            epgLastSuccess: nil
        )

        XCTAssertEqual(
            RefreshSchedulePlanner().dueResources(for: profile, now: now),
            [.playlist]
        )
    }

    func testNextBackgroundDateUsesEarliestIndependentResourceCandidate() throws {
        let profile = profile(
            m3uInterval: .sixHours,
            epgInterval: .daily,
            m3uLastSuccess: now.addingTimeInterval(-2 * 3_600),
            epgLastSuccess: now.addingTimeInterval(-3_600)
        )

        let date = try XCTUnwrap(
            RefreshSchedulePlanner().nextBackgroundDate(for: [profile], now: now)
        )

        XCTAssertEqual(date, now.addingTimeInterval(4 * 3_600))
    }

    func testNextBackgroundDateClampsDueCandidateToFifteenMinutesFromNow() throws {
        let profile = profile(
            m3uInterval: .sixHours,
            epgInterval: .manual,
            m3uLastSuccess: now.addingTimeInterval(-7 * 3_600),
            epgLastSuccess: nil
        )

        let date = try XCTUnwrap(
            RefreshSchedulePlanner().nextBackgroundDate(for: [profile], now: now)
        )

        XCTAssertEqual(date, now.addingTimeInterval(15 * 60))
    }

    func testNextBackgroundDateUsesFifteenMinuteCandidateForNeverSuccessfulResource() throws {
        let profile = profile(
            m3uInterval: .hourly,
            epgInterval: .manual,
            m3uLastSuccess: nil,
            epgLastSuccess: nil
        )

        let date = try XCTUnwrap(
            RefreshSchedulePlanner().nextBackgroundDate(for: [profile], now: now)
        )

        XCTAssertEqual(date, now.addingTimeInterval(15 * 60))
    }

    func testNextBackgroundDateReturnsNilWhenEveryResourceIsManual() {
        let profile = profile(
            m3uInterval: .manual,
            epgInterval: .manual,
            m3uLastSuccess: nil,
            epgLastSuccess: nil
        )

        XCTAssertNil(RefreshSchedulePlanner().nextBackgroundDate(for: [profile], now: now))
    }

    func testDueBatchDeduplicatesEachResourceURLAndRetainsOtherURLs() {
        let first = profile(m3uInterval: .hourly, epgInterval: .hourly, m3uLastSuccess: nil, epgLastSuccess: nil)
        var shared = first
        shared = SourceProfile(id: UUID(), name: "共享源", m3uURL: first.m3uURL, epgURL: first.epgURL,
            m3uRefreshInterval: .hourly, epgRefreshInterval: .hourly,
            m3uStatus: .init(), epgStatus: .init(), createdAt: now, updatedAt: now)
        var separatePlaylist = shared
        separatePlaylist = SourceProfile(id: UUID(), name: "独立列表", m3uURL: URL(string: "https://other.test/list.m3u")!,
            epgURL: first.epgURL, m3uRefreshInterval: .hourly, epgRefreshInterval: .hourly,
            m3uStatus: .init(), epgStatus: .init(), createdAt: now, updatedAt: now)
        let batch = RefreshSchedulePlanner().dueRefreshes(for: [first, shared, separatePlaylist], now: now)
        XCTAssertEqual(batch.map(\.profileID), [first.id, separatePlaylist.id])
        XCTAssertEqual(batch.map(\.resources), [[.playlist, .epg], [.playlist]])
    }

    func testNotDueOrManualProfileDoesNotSuppressAnotherProfilesDueSharedURL() {
        let manual = profile(m3uInterval: .manual, epgInterval: .manual, m3uLastSuccess: nil, epgLastSuccess: nil)
        let due = SourceProfile(id: UUID(), name: "需刷新", m3uURL: manual.m3uURL, epgURL: manual.epgURL,
            m3uRefreshInterval: .hourly, epgRefreshInterval: .hourly,
            m3uStatus: .init(), epgStatus: .init(), createdAt: now, updatedAt: now)
        let batch = RefreshSchedulePlanner().dueRefreshes(for: [manual, due], now: now)
        XCTAssertEqual(batch.map(\.profileID), [due.id])
        XCTAssertEqual(batch.first?.resources, [.playlist, .epg])
    }

    func testFailedResourceAppliesExponentialFailureCooldownAnchoredOnLastAttempt() {
        let planner = RefreshSchedulePlanner()
        // 连续失败 1 次 -> 15m，2 次 -> 30m，3 次 -> 1h，4 次 -> 2h，7 次 -> 受 6h 周期封顶
        let expectations: [(failures: Int, interval: RefreshInterval, expectedCooldown: TimeInterval)] = [
            (0, .sixHours, 15 * 60),
            (1, .sixHours, 15 * 60),
            (2, .sixHours, 30 * 60),
            (3, .sixHours, 60 * 60),
            (4, .sixHours, 120 * 60),
            (3, .hourly, 60 * 60),
            (5, .hourly, 60 * 60),
            (7, .sixHours, 6 * 3_600)
        ]

        for item in expectations {
            var testProfile = profile(
                m3uInterval: item.interval,
                epgInterval: .manual,
                m3uLastSuccess: nil,
                epgLastSuccess: nil
            )
            testProfile.m3uStatus = ResourceRefreshStatus(
                lastAttemptAt: now.addingTimeInterval(-(item.expectedCooldown - 1)),
                lastSuccessAt: nil,
                state: .failed,
                errorSummary: "下载失败",
                consecutiveFailureCount: item.failures
            )
            XCTAssertEqual(
                planner.dueResources(for: testProfile, now: now),
                [],
                "failures=\(item.failures) interval=\(item.interval) 冷却期内不应重复触发"
            )

            testProfile.m3uStatus.lastAttemptAt = now.addingTimeInterval(-item.expectedCooldown)
            XCTAssertEqual(
                planner.dueResources(for: testProfile, now: now),
                [.playlist],
                "failures=\(item.failures) interval=\(item.interval) 冷却到期后应恢复调度"
            )
        }
    }

    func testNextBackgroundDateRespectsFailureCooldownBeyondFifteenMinutes() throws {
        let planner = RefreshSchedulePlanner()
        var failingProfile = profile(
            m3uInterval: .sixHours,
            epgInterval: .manual,
            m3uLastSuccess: nil,
            epgLastSuccess: nil
        )
        let attemptAt = now.addingTimeInterval(-5 * 60)
        failingProfile.m3uStatus = ResourceRefreshStatus(
            lastAttemptAt: attemptAt,
            lastSuccessAt: nil,
            state: .failed,
            errorSummary: "失败",
            consecutiveFailureCount: 3
        )

        let nextDate = try XCTUnwrap(planner.nextBackgroundDate(for: [failingProfile], now: now))
        XCTAssertEqual(nextDate, attemptAt.addingTimeInterval(60 * 60))

        // 若正常刷新周期比失败冷却更晚，仍保持正常周期不提前触发。
        failingProfile.m3uStatus.lastSuccessAt = now.addingTimeInterval(-2 * 3_600)
        let normalLaterDate = try XCTUnwrap(planner.nextBackgroundDate(for: [failingProfile], now: now))
        XCTAssertEqual(normalLaterDate, now.addingTimeInterval(4 * 3_600))
    }

    private func profile(
        m3uInterval: RefreshInterval,
        epgInterval: RefreshInterval,
        m3uLastSuccess: Date?,
        epgLastSuccess: Date?
    ) -> SourceProfile {
        SourceProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Test",
            m3uURL: URL(string: "https://example.com/playlist.m3u")!,
            epgURL: URL(string: "https://example.com/epg.xml")!,
            m3uRefreshInterval: m3uInterval,
            epgRefreshInterval: epgInterval,
            m3uStatus: ResourceRefreshStatus(lastSuccessAt: m3uLastSuccess),
            epgStatus: ResourceRefreshStatus(lastSuccessAt: epgLastSuccess),
            createdAt: now,
            updatedAt: now
        )
    }
}
