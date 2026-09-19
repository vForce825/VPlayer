// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
@testable import VPlayerPlayback

final class BackendTestHarness: @unchecked Sendable {
    private let fakePipeline: FakeControllerPipeline
    
    var isPrepared: Bool {
        return fakePipeline.starts.count > 0
    }
    
    var clockRate: Float {
        return fakePipeline.playbackRate
    }
    
    static func sampleBuffer() -> BackendTestHarness {
        let fake = FakeControllerPipeline()
        return BackendTestHarness(fakePipeline: fake)
    }
    
    private init(fakePipeline: FakeControllerPipeline) {
        self.fakePipeline = fakePipeline
    }

    
    func prepare(initiallyPaused: Bool) async throws {
        fakePipeline.start(
            url: URL(string: "http://test")!, readinessCycle: 1,
            initiallyPaused: initiallyPaused)
        if initiallyPaused {
            fakePipeline.setPlaybackRate(0)
        }
    }
    
    func activateCurrentPermit() async {
        fakePipeline.setPlaybackRate(1.0)
    }
    
    func suspendAndConfirm() async {
        fakePipeline.setPlaybackRate(0.0)
    }
}
