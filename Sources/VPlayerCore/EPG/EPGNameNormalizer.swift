// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum EPGNameNormalizer {
    public static func normalize(_ name: String) -> String {
        let compatible = name.precomposedStringWithCompatibilityMapping
        let lowercase = compatible.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let scalars = lowercase.unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func isConservativeFuzzyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLeft = normalize(lhs)
        let normalizedRight = normalize(rhs)
        guard normalizedLeft.count >= 5, normalizedRight.count >= 5 else {
            return false
        }

        let lengthDifference = abs(normalizedLeft.count - normalizedRight.count)
        guard lengthDifference <= 1 else {
            return false
        }
        if lengthDifference == 1,
           normalizedLeft.contains(normalizedRight) || normalizedRight.contains(normalizedLeft) {
            return true
        }

        return levenshteinDistanceExactlyOne(normalizedLeft, normalizedRight)
    }

    private static func levenshteinDistanceExactlyOne(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftIndex in 1...left.count {
            current[0] = leftIndex
            var rowMinimum = current[0]

            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }

            guard rowMinimum <= 1 else {
                return false
            }
            swap(&previous, &current)
        }

        return previous[right.count] == 1
    }
}
