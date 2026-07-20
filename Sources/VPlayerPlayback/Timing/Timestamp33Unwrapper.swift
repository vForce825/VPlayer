// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

public struct Timestamp33Unwrapper: Sendable {
    private static let modulus: Int64 = 1 << 33
    private static let halfRange: Int64 = 1 << 32
    private static let mask: UInt64 = (1 << 33) - 1

    private var lastRaw: Int64?
    private var epoch: Int64 = 0

    public init() {}

    public mutating func unwrap(raw: UInt64) -> Int64 {
        let current = Int64(raw & Self.mask)
        if let lastRaw {
            let delta = current - lastRaw
            if delta < -Self.halfRange {
                epoch += Self.modulus
            } else if delta > Self.halfRange {
                epoch -= Self.modulus
            }
        }
        lastRaw = current
        return epoch + current
    }

    public mutating func reset() {
        lastRaw = nil
        epoch = 0
    }
}
