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
        guard let stamp = pieces.first, stamp.count == 14 else {
            throw XMLTVTimeError.invalid(raw)
        }
        let zone = pieces.count > 1 ? String(pieces[1]) : "+0000"
        let normalizedZone = zone == "Z" ? "+0000" : zone
        guard normalizedZone.range(of: #"^[+-]\d{4}$"#, options: .regularExpression) != nil else {
            throw XMLTVTimeError.invalid(raw)
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        guard let date = formatter.date(from: "\(stamp) \(normalizedZone)") else {
            throw XMLTVTimeError.invalid(raw)
        }
        return date
    }
}
