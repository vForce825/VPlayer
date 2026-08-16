// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// The scan mode confirmed by the playback pipeline for the current media
/// generation.  This is deliberately separate from the diagnostic scan
/// classifier so the application only sees the two user-facing modes.
public enum PlaybackScanMode: Sendable, Equatable {
    case progressive
    case interlaced
}

/// Stable media facts suitable for presentation to a viewer.
public struct PlaybackMediaInformation: Sendable, Equatable {
    public let width: Int32
    public let height: Int32
    public let scanMode: PlaybackScanMode
    public let sourceFrameRate: MediaRational?
    public let outputFrameRate: Double?
    public let isSmoothMotionEnhanced: Bool

    public init(
        width: Int32,
        height: Int32,
        scanMode: PlaybackScanMode,
        sourceFrameRate: MediaRational?,
        outputFrameRate: Double?,
        isSmoothMotionEnhanced: Bool
    ) {
        self.width = width
        self.height = height
        self.scanMode = scanMode
        self.sourceFrameRate = sourceFrameRate
        self.outputFrameRate = outputFrameRate
        self.isSmoothMotionEnhanced = isSmoothMotionEnhanced
    }
}

/// Supplies the latest product-level media snapshot.  The stream always
/// starts with `nil`; lifecycle transitions and media-generation changes also
/// publish `nil` before a replacement snapshot is available.
public protocol PlaybackMediaInformationProviding: Actor {
    func playbackMediaInformation() -> AsyncStream<PlaybackMediaInformation?>
}
