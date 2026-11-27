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
        if let epochSeconds = raw.utf8.withContiguousStorageIfAvailable({ Self.parseModernEpochSeconds(utf8: $0) }) ?? nil {
            return Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        }
        return try parseFallback(raw)
    }

    func parseEpochSeconds(utf8: UnsafeBufferPointer<UInt8>) throws -> Int64 {
        if let fast = Self.parseModernEpochSeconds(utf8: utf8) {
            return fast
        }
        let raw = String(decoding: utf8, as: UTF8.self)
        return Int64(try parseFallback(raw).timeIntervalSince1970)
    }

    /// Zero-allocation ASCII fast path for modern proleptic Gregorian timestamps (`year >= 1583`).
    /// Returns `nil` for pre-1583 dates, non-ASCII bytes, or invalid inputs so callers can either
    /// skip invalid programmes or delegate to `parseFallback` for exact error/Julian-boundary behavior.
    static func parseModernEpochSeconds(utf8: UnsafeBufferPointer<UInt8>) -> Int64? {
        let count = utf8.count
        var start = 0
        var end = count
        while start < end, isASCIIWhitespace(utf8[start]) { start += 1 }
        while end > start, isASCIIWhitespace(utf8[end - 1]) { end -= 1 }
        guard end - start >= 14 else { return nil }
        // Bail out to Foundation fallback if non-ASCII whitespace or characters surround the stamp.
        if utf8[start] >= 0x80 || utf8[end - 1] >= 0x80 { return nil }

        var digits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        for offset in 0..<14 {
            let byte = utf8[start + offset]
            guard byte >= 48, byte <= 57 else { return nil }
            let d = Int(byte - 48)
            switch offset {
            case 0: digits.0 = d
            case 1: digits.1 = d
            case 2: digits.2 = d
            case 3: digits.3 = d
            case 4: digits.4 = d
            case 5: digits.5 = d
            case 6: digits.6 = d
            case 7: digits.7 = d
            case 8: digits.8 = d
            case 9: digits.9 = d
            case 10: digits.10 = d
            case 11: digits.11 = d
            case 12: digits.12 = d
            default: digits.13 = d
            }
        }

        let year = digits.0 * 1_000 + digits.1 * 100 + digits.2 * 10 + digits.3
        guard year >= 1_583, year <= 9_999 else { return nil }
        let month = digits.4 * 10 + digits.5
        let day = digits.6 * 10 + digits.7
        let hour = digits.8 * 10 + digits.9
        let minute = digits.10 * 10 + digits.11
        let second = digits.12 * 10 + digits.13
        guard (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }
        let maxDay = daysInGregorianMonth(year: year, month: month)
        guard day >= 1, day <= maxDay else { return nil }

        let secondsFromGMT: Int
        var pos = start + 14
        if pos == end {
            secondsFromGMT = 0
        } else {
            guard isASCIIWhitespace(utf8[pos]) else { return nil }
            while pos < end, isASCIIWhitespace(utf8[pos]) { pos += 1 }
            let zoneLen = end - pos
            if zoneLen == 1, utf8[pos] == 0x5A { // 'Z'
                secondsFromGMT = 0
            } else if zoneLen == 5 {
                let signByte = utf8[pos]
                guard signByte == 43 || signByte == 45 else { return nil }
                let zh1 = utf8[pos + 1]
                let zh2 = utf8[pos + 2]
                let zm1 = utf8[pos + 3]
                let zm2 = utf8[pos + 4]
                guard zh1 >= 48, zh1 <= 57, zh2 >= 48, zh2 <= 57,
                      zm1 >= 48, zm1 <= 57, zm2 >= 48, zm2 <= 57 else {
                    return nil
                }
                let zoneHour = Int(zh1 - 48) * 10 + Int(zh2 - 48)
                let zoneMinute = Int(zm1 - 48) * 10 + Int(zm2 - 48)
                guard (0...23).contains(zoneHour), (0...59).contains(zoneMinute) else {
                    return nil
                }
                let magnitude = (zoneHour * 60 + zoneMinute) * 60
                guard magnitude <= 18 * 3_600 else { return nil }
                secondsFromGMT = signByte == 45 ? -magnitude : magnitude
            } else {
                return nil
            }
        }

        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let monthIndex = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let daysSinceUnixEpoch = era * 146_097 + dayOfEra - 719_468
        return Int64(daysSinceUnixEpoch) * 86_400
            + Int64(hour * 3_600 + minute * 60 + second - secondsFromGMT)
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func parseFallback(_ raw: String) throws -> Date {
        let pieces = trimmedASCIIOrFoundation(raw)
            .split(whereSeparator: \.isWhitespace)
        guard pieces.count == 1 || pieces.count == 2 else {
            throw XMLTVTimeError.invalid(raw)
        }

        let stampUTF8 = pieces[0].utf8
        guard stampUTF8.count == 14 else {
            throw XMLTVTimeError.invalid(raw)
        }
        var stampBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var stampIndex = 0
        for byte in stampUTF8 {
            guard byte >= 48, byte <= 57 else {
                throw XMLTVTimeError.invalid(raw)
            }
            let digit = Int(byte - 48)
            switch stampIndex {
            case 0: stampBytes.0 = digit
            case 1: stampBytes.1 = digit
            case 2: stampBytes.2 = digit
            case 3: stampBytes.3 = digit
            case 4: stampBytes.4 = digit
            case 5: stampBytes.5 = digit
            case 6: stampBytes.6 = digit
            case 7: stampBytes.7 = digit
            case 8: stampBytes.8 = digit
            case 9: stampBytes.9 = digit
            case 10: stampBytes.10 = digit
            case 11: stampBytes.11 = digit
            case 12: stampBytes.12 = digit
            default: stampBytes.13 = digit
            }
            stampIndex += 1
        }

        let year = stampBytes.0 * 1_000 + stampBytes.1 * 100 + stampBytes.2 * 10 + stampBytes.3
        let month = stampBytes.4 * 10 + stampBytes.5
        let day = stampBytes.6 * 10 + stampBytes.7
        let hour = stampBytes.8 * 10 + stampBytes.9
        let minute = stampBytes.10 * 10 + stampBytes.11
        let second = stampBytes.12 * 10 + stampBytes.13
        guard (1...9_999).contains(year),
              (1...12).contains(month),
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
            let zoneUTF8 = pieces[1].utf8
            guard zoneUTF8.count == 5 else {
                throw XMLTVTimeError.invalid(raw)
            }
            var idx = zoneUTF8.startIndex
            let signByte = zoneUTF8[idx]
            guard signByte == 43 || signByte == 45 else {
                throw XMLTVTimeError.invalid(raw)
            }
            idx = zoneUTF8.index(after: idx)
            let zh1 = zoneUTF8[idx]; idx = zoneUTF8.index(after: idx)
            let zh2 = zoneUTF8[idx]; idx = zoneUTF8.index(after: idx)
            let zm1 = zoneUTF8[idx]; idx = zoneUTF8.index(after: idx)
            let zm2 = zoneUTF8[idx]
            guard zh1 >= 48, zh1 <= 57, zh2 >= 48, zh2 <= 57,
                  zm1 >= 48, zm1 <= 57, zm2 >= 48, zm2 <= 57 else {
                throw XMLTVTimeError.invalid(raw)
            }

            let zoneHour = Int(zh1 - 48) * 10 + Int(zh2 - 48)
            let zoneMinute = Int(zm1 - 48) * 10 + Int(zm2 - 48)
            guard (0...23).contains(zoneHour), (0...59).contains(zoneMinute) else {
                throw XMLTVTimeError.invalid(raw)
            }

            let magnitude = (zoneHour * 60 + zoneMinute) * 60
            guard magnitude <= 18 * 3_600 else {
                throw XMLTVTimeError.invalid(raw)
            }
            secondsFromGMT = signByte == 45 ? -magnitude : magnitude
        }

        if year >= 1_583 {
            let maxDay = Self.daysInGregorianMonth(year: year, month: month)
            guard day >= 1, day <= maxDay else {
                throw XMLTVTimeError.invalid(raw)
            }
            let adjustedYear = year - (month <= 2 ? 1 : 0)
            let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
            let yearOfEra = adjustedYear - era * 400
            let monthIndex = month + (month > 2 ? -3 : 9)
            let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let daysSinceUnixEpoch = era * 146_097 + dayOfEra - 719_468
            let epochSeconds = Int64(daysSinceUnixEpoch) * 86_400
                + Int64(hour * 3_600 + minute * 60 + second - secondsFromGMT)
            return Date(timeIntervalSince1970: TimeInterval(epochSeconds))
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

    private func trimmedASCIIOrFoundation(_ value: String) -> String {
        let utf8 = value.utf8
        guard let first = utf8.first, let last = utf8.last else { return value }
        if (0x21...0x7E).contains(first), (0x21...0x7E).contains(last) {
            return value
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func daysInGregorianMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            let isLeap = (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0)
            return isLeap ? 29 : 28
        default:
            return 0
        }
    }
}
