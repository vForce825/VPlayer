// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import VPlayerCore

struct IOSProgrammeGuidePresentation {
    struct Row: Identifiable {
        let programme: Programme
        let timeRange: String
        let isCurrent: Bool
        let isNext: Bool
        let progress: Double?
        let remainingText: String?
        var id: String { programme.id }
        var accessibilityPrefix: String {
            isCurrent ? "programme.current" : isNext ? "programme.next" : "programme.\(id)"
        }
    }

    struct Day: Identifiable {
        let date: Date
        let title: String
        let rows: [Row]
        var id: Date { date }
    }

    let days: [Day]
    let hasCurrent: Bool
    let hasUpcoming: Bool

    init(programmes: [Programme], at date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let ordered = programmes.filter { $0.stop > $0.start }.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        let current = ChannelProgrammePresentation.resolve(programmes: ordered, at: date)
        let upcoming = ordered.filter { $0.start >= date && $0.id != current.current?.id }
        hasCurrent = current.current != nil
        hasUpcoming = !upcoming.isEmpty
        let visible = (current.current.map { [$0] } ?? []) + upcoming
        let rows = visible.map { programme in
            let isCurrent = programme.id == current.current?.id
            let remainingMinutes = max(1, Int(ceil(programme.stop.timeIntervalSince(date) / 60)))
            return Row(programme: programme, timeRange: Self.timeRange(for: programme, calendar: calendar),
                isCurrent: isCurrent, isNext: programme.id == current.next?.id,
                progress: isCurrent ? current.progress : nil,
                remainingText: isCurrent ? "还剩 \(remainingMinutes) 分钟" : nil)
        }
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.programme.start) }
        days = grouped.keys.sorted().map { day in
            Day(date: day, title: Self.dayTitle(day, relativeTo: date, calendar: calendar),
                rows: grouped[day, default: []])
        }
    }

    static func timeRange(for programme: Programme, calendar: Calendar) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .omitted,
            locale: Locale(identifier: "zh_CN"), calendar: calendar, timeZone: calendar.timeZone)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        let start = programme.start.formatted(style)
        let stop = programme.stop.formatted(style)
        if calendar.isDate(programme.start, inSameDayAs: programme.stop) {
            return "\(start) – \(stop)"
        }
        let followingDay = calendar.date(byAdding: .day, value: 1, to: programme.start)
        if followingDay.map({ calendar.isDate($0, inSameDayAs: programme.stop) }) == true {
            return "\(start) – 次日 \(stop)"
        }
        return "\(start) – \(dateText(programme.stop, relativeTo: programme.start, calendar: calendar)) \(stop)"
    }

    private static func dayTitle(_ day: Date, relativeTo date: Date, calendar: Calendar) -> String {
        let label: String?
        if calendar.isDate(day, inSameDayAs: date) { label = "今天" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: date),
                calendar.isDate(day, inSameDayAs: tomorrow) { label = "明天" }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: date),
                calendar.isDate(day, inSameDayAs: yesterday) { label = "昨天" }
        else { label = nil }
        let dateText = dateText(day, relativeTo: date, calendar: calendar)
        return label.map { "\($0) · \(dateText)" } ?? dateText
    }

    private static func dateText(_ date: Date, relativeTo reference: Date, calendar: Calendar) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .omitted,
            locale: Locale(identifier: "zh_CN"), calendar: calendar, timeZone: calendar.timeZone)
            .month(.wide).day(.defaultDigits)
        if calendar.component(.year, from: date) != calendar.component(.year, from: reference) {
            return date.formatted(style.year())
        }
        return date.formatted(style)
    }
}
