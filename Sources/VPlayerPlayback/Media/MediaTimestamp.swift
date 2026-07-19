// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public struct MediaRational: Sendable, Hashable {
    public let num: Int32
    public let den: Int32

    public init?(num: Int32, den: Int32) {
        guard num > 0, den > 0 else { return nil }
        self.num = num
        self.den = den
    }

    public func cmTime(forFFmpegValue value: Int64) -> CMTime {
        guard value != Int64.min else { return .invalid }

        let commonScale = greatestCommonDivisor(UInt64(num), UInt64(den))
        let numeratorFactor = Int64(UInt64(num) / commonScale)
        var remainingDenominator = UInt64(den) / commonScale
        let magnitude = value < 0 ? UInt64(-value) : UInt64(value)
        let timestampCancellation = greatestCommonDivisor(magnitude, remainingDenominator)
        let reducedValue = value / Int64(timestampCancellation)
        remainingDenominator /= timestampCancellation

        let (exactValue, overflowed) = reducedValue.multipliedReportingOverflow(
            by: numeratorFactor
        )
        guard !overflowed, let timescale = Int32(exactly: remainingDenominator) else {
            return .invalid
        }
        return CMTime(value: exactValue, timescale: timescale)
    }
}

private func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var a = lhs
    var b = rhs
    while b != 0 {
        let remainder = a % b
        a = b
        b = remainder
    }
    return a
}
