// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Retains the original resolved source/facts owner through physical graph
/// retirement. The generated graph never resolves or probes a second time.
protocol HLSGeneratedSourceContext: AnyObject, Sendable {
    var plan: HLSPlaybackPlan { get }
    var facts: HLSCompatibilityFacts { get }
    var isCurrent: Bool { get }
    /// True only when the original Registry-owned preparing/active scope accepted delivery.
    func requestNewGeneration() -> Bool
    /// Records exact request+format rejection before failed prepare becomes observable.
    func requestCompatibleAudioGeneration() -> Bool
}

extension HLSGeneratedSourceContext {
    func requestNewGeneration() -> Bool { false }
    func requestCompatibleAudioGeneration() -> Bool { false }
}
