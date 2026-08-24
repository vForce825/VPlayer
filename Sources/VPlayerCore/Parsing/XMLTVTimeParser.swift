// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum XMLTVTimeError: Error, Equatable, Sendable {
    case invalid(String)
}

public struct XMLTVTimeParser: Sendable {
    public init() {}

    public func parse(_ raw: String) throws -> Date {
        let pieces = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard pieces.count == 1 || pieces.count == 2 else {
            throw XMLTVTimeError.invalid(raw)
        }

        let stamp = Array(pieces[0].utf8)
        guard stamp.count == 14, stamp.allSatisfy({ (48...57).contains($0) }) else {
            throw XMLTVTimeError.invalid(raw)
        }

        func decimal(_ range: Range<Int>) -> Int {
            stamp[range].reduce(0) { result, byte in
                result * 10 + Int(byte - 48)
            }
        }

        let year = decimal(0..<4)
        let month = decimal(4..<6)
        let day = decimal(6..<8)
        let hour = decimal(8..<10)
        let minute = decimal(10..<12)
        let second = decimal(12..<14)
        guard (1...9_999).contains(year),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second)
        else {
            throw XMLTVTimeError.invalid(raw)
        }

        let secondsFromGMT: Int
        if pieces.count == 1 || pieces[1] == "Z" {
            secondsFromGMT = 0
        } else {
            let zone = Array(pieces[1].utf8)
            guard zone.count == 5,
                  zone[0] == 43 || zone[0] == 45,
                  zone[1...].allSatisfy({ (48...57).contains($0) })
            else {
                throw XMLTVTimeError.invalid(raw)
            }

            let zoneHour = Int(zone[1] - 48) * 10 + Int(zone[2] - 48)
            let zoneMinute = Int(zone[3] - 48) * 10 + Int(zone[4] - 48)
            guard (0...23).contains(zoneHour), (0...59).contains(zoneMinute) else {
                throw XMLTVTimeError.invalid(raw)
            }

            let magnitude = (zoneHour * 60 + zoneMinute) * 60
            secondsFromGMT = zone[0] == 45 ? -magnitude : magnitude
        }

        guard let timeZone = TimeZone(secondsFromGMT: secondsFromGMT) else {
            throw XMLTVTimeError.invalid(raw)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let date = calendar.date(from: components) else {
            throw XMLTVTimeError.invalid(raw)
        }

        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == second
        else {
            throw XMLTVTimeError.invalid(raw)
        }
        return date
    }
}
