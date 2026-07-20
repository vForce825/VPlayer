// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public struct FrameCadenceEstimator: Sendable {
    private static let maximumSampleCount = 7
    private static let minimumDuration = CMTime(value: 1, timescale: 240)
    private static let maximumDuration = CMTime(value: 1, timescale: 10)

    private var trustedDeltas: [CMTime] = []

    public init() {}

    public var medianFrameDuration: CMTime? {
        guard !trustedDeltas.isEmpty else { return nil }
        let sorted = trustedDeltas.sorted { lhs, rhs in
            CMTimeCompare(lhs, rhs) < 0
        }
        return sorted[sorted.count / 2]
    }

    public mutating func appendTrustedDelta(_ delta: CMTime) {
        guard Self.isEligible(delta) else { return }
        trustedDeltas.append(delta)
        if trustedDeltas.count > Self.maximumSampleCount {
            trustedDeltas.removeFirst(trustedDeltas.count - Self.maximumSampleCount)
        }
    }

    public mutating func reset() {
        trustedDeltas.removeAll(keepingCapacity: true)
    }

    static func isEligible(_ duration: CMTime) -> Bool {
        duration.isNumeric
            && CMTimeCompare(duration, minimumDuration) >= 0
            && CMTimeCompare(duration, maximumDuration) <= 0
    }
}
