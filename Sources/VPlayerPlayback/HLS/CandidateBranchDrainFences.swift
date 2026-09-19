// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 候选分支排空围栏。每个候选只持有至多一个 compressed gate 和一个 PCM-consumer gate 的排空围栏；
/// 围栏由对应 gate 在 close 时签发，携带准确 admission identity、lastIssuedLeaseSequence 与 expectedOutstandingCount。
/// loser cleanup 只关闭自己的 compressed/PCM 订阅，不碰共享 decoder。
struct CandidateBranchDrainFences: Sendable, Hashable {
    let compressed: AudioServiceBranchDrainFence?
    let pcmConsumer: PCMConsumerDrainFence?

    init(
        compressed: AudioServiceBranchDrainFence? = nil,
        pcmConsumer: PCMConsumerDrainFence? = nil
    ) {
        self.compressed = compressed
        self.pcmConsumer = pcmConsumer
    }

    var isEmpty: Bool {
        compressed == nil && pcmConsumer == nil
    }

    func isDrained(
        semantic: AudioServiceSemanticCoordinator?
    ) -> Bool {
        if let compressed, let semantic {
            guard semantic.isDrained(compressed) else { return false }
        }
        if let pcmConsumer, let semantic {
            guard semantic.isDrained(pcmConsumer) else { return false }
        }
        return true
    }

    @discardableResult
    func retire(
        semantic: AudioServiceSemanticCoordinator?
    ) -> Bool {
        var success = true
        if let compressed, let semantic {
            if !semantic.retireAudioServiceGate(compressed) {
                success = false
            }
        }
        if let pcmConsumer, let semantic {
            if !semantic.retirePCMSubscription(pcmConsumer) {
                success = false
            }
        }
        return success
    }
}
