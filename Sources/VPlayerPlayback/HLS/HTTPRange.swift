// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum HTTPRangeSelection: Equatable, Sendable {
    case single(Range<Int>)
    case ignoreAndServeFull
    case unsatisfied
}

enum HTTPRangeError: Error, Equatable {
    case invalidSyntax
    case arithmeticOverflow
}

enum HTTPRange {
    static func parse(_ value: String, resourceLength: Int) throws -> HTTPRangeSelection {
        guard resourceLength >= 0, value.hasPrefix("bytes=") else { throw HTTPRangeError.invalidSyntax }
        let list = value.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
        guard !list.isEmpty, list.allSatisfy({ !$0.isEmpty }) else { throw HTTPRangeError.invalidSyntax }
        var selections: [Range<Int>?] = []
        selections.reserveCapacity(list.count)
        for rawMember in list {
            let member = Substring(String(rawMember).trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
            guard !member.isEmpty, !member.contains(" "), !member.contains("\t") else {
                throw HTTPRangeError.invalidSyntax
            }
            let pieces = member.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw HTTPRangeError.invalidSyntax }
            if pieces[0].isEmpty {
                let suffix = try decimal(pieces[1])
                guard suffix > 0, resourceLength > 0 else { selections.append(nil); continue }
                let width = Int(min(suffix, UInt64(resourceLength)))
                selections.append((resourceLength - width)..<resourceLength)
            } else {
                let first = try decimal(pieces[0])
                let last = pieces[1].isEmpty ? nil : try decimal(pieces[1])
                if let last, first > last { throw HTTPRangeError.invalidSyntax }
                guard first < UInt64(resourceLength) else { selections.append(nil); continue }
                let lower = Int(first)
                let upper: Int
                if let last {
                    upper = Int(min(last, UInt64(resourceLength - 1))) + 1
                } else {
                    upper = resourceLength
                }
                selections.append(lower..<upper)
            }
        }
        if selections.count > 1 {
            return selections.contains(where: { $0 != nil }) ? .ignoreAndServeFull : .unsatisfied
        }
        return selections[0].map(HTTPRangeSelection.single) ?? .unsatisfied
    }

    private static func decimal(_ value: Substring) throws -> UInt64 {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = UInt64(value) else {
            throw HTTPRangeError.invalidSyntax
        }
        return parsed
    }
}
