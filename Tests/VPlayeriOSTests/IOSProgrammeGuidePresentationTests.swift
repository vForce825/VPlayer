// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayer
@testable import VPlayerCore

final class IOSProgrammeGuidePresentationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text + "+08:00")!
    }

    private func programme(_ id: String, _ start: String, _ stop: String) -> Programme {
        Programme(id: id, xmltvChannelID: "fixture", start: date(start), stop: date(stop),
            title: id, subtitle: nil, summary: nil, categories: [])
    }

    func testTimeRangeUsesTwoDigitTwentyFourHourTimesWithoutRepeatedDates() {
        let item = programme("morning", "2026-10-14T08:00:00", "2026-10-14T08:45:00")
        XCTAssertEqual(IOSProgrammeGuidePresentation.timeRange(for: item, calendar: calendar), "08:00 – 08:45")
    }

    func testGroupsSortedFutureProgrammesByDayAndOmitsExpiredOrInvalidIntervals() {
        let current = programme("current", "2026-10-14T19:30:00", "2026-10-14T20:30:00")
        let next = programme("next", "2026-10-14T20:30:00", "2026-10-14T21:15:00")
        let tomorrow = programme("tomorrow", "2026-10-15T00:30:00", "2026-10-15T01:15:00")
        let expired = programme("expired", "2026-10-14T18:00:00", "2026-10-14T19:30:00")
        let invalid = programme("invalid", "2026-10-14T20:30:00", "2026-10-14T20:00:00")
        let subject = IOSProgrammeGuidePresentation(programmes: [tomorrow, next, expired, invalid, current],
            at: date("2026-10-14T20:12:00"), calendar: calendar)
        XCTAssertEqual(subject.days.map(\.title), ["今天 · 10月14日", "明天 · 10月15日"])
        XCTAssertEqual(subject.days.flatMap(\.rows).map(\.id), ["current", "next", "tomorrow"])
        XCTAssertTrue(subject.hasCurrent)
        XCTAssertTrue(subject.hasUpcoming)
        XCTAssertEqual(subject.days[0].rows[0].remainingText, "还剩 18 分钟")
        XCTAssertEqual(subject.days[0].rows[0].progress ?? 0, 0.7, accuracy: 0.001)
        XCTAssertTrue(subject.days[0].rows[1].isNext)
        XCTAssertNil(subject.days[0].rows[1].progress)
    }

    func testExactProgrammeBoundarySelectsNewCurrentOnceAndNeverKeepsFinishedProgramme() {
        let old = programme("old", "2026-10-14T19:30:00", "2026-10-14T20:30:00")
        let current = programme("current", "2026-10-14T20:30:00", "2026-10-14T21:00:00")
        let next = programme("next", "2026-10-14T21:00:00", "2026-10-14T21:30:00")
        let subject = IOSProgrammeGuidePresentation(programmes: [old, current, next],
            at: current.start, calendar: calendar)
        let rows = subject.days.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.id), ["current", "next"])
        XCTAssertTrue(rows[0].isCurrent)
        XCTAssertEqual(rows[0].progress, 0)
        XCTAssertEqual(rows[0].remainingText, "还剩 30 分钟")
        XCTAssertTrue(rows[1].isNext)
    }

    func testMidnightAndNewYearAreExplicitWithoutRepeatingDateOnEveryRow() {
        let current = programme("cross-midnight", "2026-12-31T23:30:00", "2027-01-01T00:30:00")
        let next = programme("next", "2027-01-01T00:30:00", "2027-01-01T01:00:00")
        let subject = IOSProgrammeGuidePresentation(programmes: [current, next],
            at: date("2026-12-31T23:45:00"), calendar: calendar)
        XCTAssertEqual(subject.days[0].rows[0].timeRange, "23:30 – 次日 00:30")
        XCTAssertEqual(subject.days[1].title, "明天 · 2027年1月1日")
        let afterMidnight = IOSProgrammeGuidePresentation(programmes: [current, next],
            at: date("2027-01-01T00:15:00"), calendar: calendar)
        XCTAssertEqual(afterMidnight.days[0].title, "昨天 · 2026年12月31日")
        XCTAssertTrue(afterMidnight.days[0].rows[0].isCurrent)
    }

    func testIntervalsLongerThanOneDayShowActualEndDate() {
        let item = programme("long", "2026-12-31T23:30:00", "2027-01-02T00:30:00")
        XCTAssertEqual(IOSProgrammeGuidePresentation.timeRange(for: item, calendar: calendar),
            "23:30 – 2027年1月2日 00:30")
    }

    func testTimesAndDayBoundariesUseTheSameCalendarTimeZone() {
        let item = programme("morning", "2026-10-14T07:30:00", "2026-10-14T08:30:00")
        XCTAssertEqual(IOSProgrammeGuidePresentation.timeRange(for: item, calendar: calendar), "07:30 – 08:30")
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(IOSProgrammeGuidePresentation.timeRange(for: item, calendar: utc), "23:30 – 次日 00:30")
        let subject = IOSProgrammeGuidePresentation(programmes: [item],
            at: date("2026-10-14T07:45:00"), calendar: utc)
        XCTAssertEqual(subject.days.first?.title, "今天 · 10月13日")
    }

    func testScheduleGapAndEmptyScheduleKeepCurrentAndUpcomingStatesDistinct() {
        let next = programme("next", "2026-10-14T20:30:00", "2026-10-14T21:00:00")
        let subject = IOSProgrammeGuidePresentation(programmes: [next],
            at: date("2026-10-14T20:12:00"), calendar: calendar)
        XCTAssertFalse(subject.hasCurrent)
        XCTAssertTrue(subject.hasUpcoming)
        XCTAssertTrue(subject.days[0].rows[0].isNext)
        XCTAssertNil(subject.days[0].rows[0].remainingText)
        let empty = IOSProgrammeGuidePresentation(programmes: [], at: next.start, calendar: calendar)
        XCTAssertFalse(empty.hasCurrent)
        XCTAssertFalse(empty.hasUpcoming)
        XCTAssertTrue(empty.days.isEmpty)
    }
}
