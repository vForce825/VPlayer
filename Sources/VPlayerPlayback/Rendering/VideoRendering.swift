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
    /// Reported for every display-link callback, including ones the driver goes
    /// on to discard, so the cadence measured here is CoreAnimation's own.
    func recordDisplayLinkCallback(targetPresentationTimestamp: CFTimeInterval)
    /// The panel's own refresh rate, as reported by the screen the layer is on.
    /// Callback gaps only mean something measured against it.
    func recordDisplayRefreshRate(framesPerSecond: Double)
}

public extension VideoRendering {
    func recordDisplayLinkCallback(targetPresentationTimestamp: CFTimeInterval) {}
    func recordDisplayRefreshRate(framesPerSecond: Double) {}
}

protocol VideoPresentationTimingResetting: AnyObject {
    func resetPresentationTiming()
}
