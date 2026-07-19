// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import QuartzCore

public struct VideoRenderDecision: Sendable, Equatable {
    public enum Action: UInt8, Sendable, Equatable {
        case noFrame
        case waiting
        case presented
        case repeated
        case skippedInFlight
        case renderFailed
    }

    public let action: Action
    public let sourceAccessUnitID: UInt64?
    public let sequenceNumber: UInt64?
    public let droppedFrameCount: Int

    public init(
        action: Action,
        sourceAccessUnitID: UInt64?,
        sequenceNumber: UInt64?,
        droppedFrameCount: Int
    ) {
        self.action = action
        self.sourceAccessUnitID = sourceAccessUnitID
        self.sequenceNumber = sequenceNumber
        self.droppedFrameCount = droppedFrameCount
    }
}

public protocol VideoRendering: AnyObject {
    func enqueue(_ frame: VideoPresentationFrame)
    func flush(to generation: MediaGeneration)
    func draw(
        targetMediaTime: CMTime,
        drawable: any CAMetalDrawable
    ) -> VideoRenderDecision
}

protocol VideoPresentationTimingResetting: AnyObject {
    func resetPresentationTiming()
}
