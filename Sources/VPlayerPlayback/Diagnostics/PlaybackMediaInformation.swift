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

/// Resolved container/manifest category, independent of the selected output path.
public enum PlaybackSourceCategory: String, Sendable, Equatable {
    case direct
    case hlsMedia = "hls-media"
    case hlsMaster = "hls-master"
}

/// What the application actually does to the current AirPlay output. Passthrough
/// describes the native/proxy application path, not the receiver's decoding or
/// a claim of bit-perfect audio. Generated output is classified only after the
/// installed branches have produced the all-track playable prefix.
public enum PlaybackAirPlayOutputMode: Sendable, Equatable {
    case passthrough
    case remux
    case audioTranscode
    case videoTranscode
    case mixedTranscode

    static func generated(video: PlaybackOutputTrackProcessing?, audio: PlaybackOutputTrackProcessing?) -> Self? {
        guard let video, let audio, video != .absent || audio != .absent else { return nil }
        switch (video == .transcoded, audio == .transcoded) {
        case (false, false): return .remux
        case (false, true): return .audioTranscode
        case (true, false): return .videoTranscode
        case (true, true): return .mixedTranscode
        }
    }
}

/// Absence is confirmed from selected tracks; nil means a branch is not known.
/// These are runtime branch facts, never the planner's proposed codec policy.
enum PlaybackOutputTrackProcessing: Sendable, Equatable {
    case absent
    case copied
    case transcoded
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
    public private(set) var sourceCategory: PlaybackSourceCategory?
    /// The actual planner result; neither readiness nor an output-codec claim.
    public private(set) var plannedTransport: HLSPlaybackPlan.Transport?
    public private(set) var airPlayOutputMode: PlaybackAirPlayOutputMode?
    /// A confirmed audio-only output carries an output mode but no video facts.
    public let isAudioOnly: Bool

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
        self.sourceCategory = nil
        self.plannedTransport = nil
        self.airPlayOutputMode = nil
        self.isAudioOnly = false
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
        self.sourceCategory = nil
        self.plannedTransport = nil
        self.airPlayOutputMode = nil
        self.isAudioOnly = false
    }

    public init(audioOnlyAirPlayOutputMode: PlaybackAirPlayOutputMode) {
        width = 0
        height = 0
        scanMode = nil
        sourceFrameRate = nil
        outputFrameRate = nil
        isSmoothMotionEnhanced = false
        isSourceProbe = false
        sourceCategory = nil
        plannedTransport = nil
        airPlayOutputMode = audioOnlyAirPlayOutputMode
        isAudioOnly = true
    }

    func withAirPlayOutputMode(_ mode: PlaybackAirPlayOutputMode) -> Self {
        var value = self
        value.airPlayOutputMode = mode
        return value
    }

    func withSourceRouting(category: PlaybackSourceCategory?, transport: HLSPlaybackPlan.Transport?) -> Self {
        var value = self
        value.sourceCategory = category
        value.plannedTransport = transport
        return value
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

/// A prepared HLS graph owns one immutable, lifecycle-bound snapshot. Confirmed
/// audio-only output has a mode without video facts; nil clears invalidated facts.
/// Its output lifecycle is distinct from the demuxer's media generation.
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
