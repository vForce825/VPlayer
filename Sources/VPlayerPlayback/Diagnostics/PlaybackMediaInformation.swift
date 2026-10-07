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
    public let scanMode: PlaybackScanMode?
    public let sourceFrameRate: MediaRational?
    public let outputFrameRate: Double?
    public let isSmoothMotionEnhanced: Bool
    /// Probe facts describe the source before an output graph exists. They grant
    /// no readiness/activation authority and never claim a transformed frame rate.
    public let isSourceProbe: Bool

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
        self.isSourceProbe = false
    }

    public init(sourceWidth: Int32, sourceHeight: Int32, scanMode: PlaybackScanMode?,
                sourceFrameRate: MediaRational?) {
        self.width = sourceWidth
        self.height = sourceHeight
        self.scanMode = scanMode
        self.sourceFrameRate = sourceFrameRate
        self.outputFrameRate = nil
        self.isSmoothMotionEnhanced = false
        self.isSourceProbe = true
    }
}

/// Supplies the latest product-level media snapshot.  The stream always
/// starts with `nil`; lifecycle transitions and media-generation changes also
/// publish `nil` before a replacement snapshot is available.
public protocol PlaybackMediaInformationProviding: Actor {
    func playbackMediaInformation() -> AsyncStream<PlaybackMediaInformation?>
}

/// The callback marks this play attempt's admitted metadata-clear boundary. It
/// runs before source/output preparation and may only schedule subscription work;
/// callers must fence it against stop/retry without awaiting playback readiness.
public protocol PlaybackMediaInformationPreparing: PlaybackEngine {
    func play(_ request: PlaybackRequest,
              afterMediaInformationReset: @escaping @Sendable () async -> Void) async
}

/// A prepared HLS graph owns one immutable value, including a valid audio-only
/// nil. Its output lifecycle is distinct from the demuxer's media generation.
struct PlaybackPreparedMediaInformation: Sendable, Equatable {
    let lifecycle: OutputLifecycleEpoch
    let information: PlaybackMediaInformation?
}

/// Notifications run on the existing owned backend task, outside Registry locks.
/// Receivers only validate and publish; they must never join the notifying task.
protocol PlaybackBackendMediaInformationReceiving: AnyObject, Sendable {
    func updateProbedSourceMediaInformation(_ information: PlaybackMediaInformation,
        source: ResolvedPlaybackSource, invocation: ControlTaskRegistry.BackendPrepareInvocation) async
    func refreshPreparedMediaInformation(for lifecycle: OutputLifecycleEpoch) async
    func invalidatePreparedMediaInformation(for lifecycle: OutputLifecycleEpoch) async
    func updateNativeMediaInformation(for lifecycle: OutputLifecycleEpoch, activation: ActivationEpoch?, invalidated: Bool) async
}

extension PlaybackBackendMediaInformationReceiving {
    func updateNativeMediaInformation(for lifecycle: OutputLifecycleEpoch, activation: ActivationEpoch?, invalidated: Bool) async {
        if invalidated { await invalidatePreparedMediaInformation(for: lifecycle) }
        else { await refreshPreparedMediaInformation(for: lifecycle) }
    }
}
