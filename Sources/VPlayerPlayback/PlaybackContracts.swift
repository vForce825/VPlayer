// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import VPlayerCore

public enum PlaybackFoundation { public static let contractVersion = 1 }

public struct PlaybackRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceProfileID: UUID
    public let channelID: String
    public let streamURL: URL
    public let title: String

    public init(sourceProfileID: UUID, channelID: String, streamURL: URL, title: String) {
        self.id = UUID()
        self.sourceProfileID = sourceProfileID
        self.channelID = channelID
        self.streamURL = streamURL
        self.title = title
    }

    public init(channel: Channel) {
        self.init(
            sourceProfileID: channel.sourceProfileID,
            channelID: channel.id,
            streamURL: channel.streamURL,
            title: channel.displayName
        )
    }
}

public struct PlaybackFailure: Error, Equatable, Sendable {
    public let code: String
    public let userMessage: String
    public let diagnosticCode: String?

    public init(
        code: String,
        userMessage: String,
        diagnosticCode: String? = nil
    ) {
        self.code = code
        self.userMessage = userMessage
        self.diagnosticCode = diagnosticCode
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing(PlaybackRequest)
    case playing(PlaybackRequest)
    case paused(PlaybackRequest)
    case stopped
    case failed(PlaybackFailure)
}

public struct PlaybackNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: String
    public let duration: Duration
    public let isFocusStealing: Bool

    public init(id: String, message: String, duration: Duration, isFocusStealing: Bool) {
        self.id = id
        self.message = message
        self.duration = duration
        self.isFocusStealing = isFocusStealing
    }
}

public protocol PlaybackEngine: Actor {
    func events() -> AsyncStream<PlaybackState>
    func notices() -> AsyncStream<PlaybackNotice>
    func play(_ request: PlaybackRequest) async
    func setPaused(_ paused: Bool) async
    func stop() async
    func setDeinterlaceAlgorithm(_ algorithm: DeinterlaceAlgorithm) async
    func setTuning(_ tuning: PlaybackTuning) async
}

public extension PlaybackEngine {
    func setTuning(_ tuning: PlaybackTuning) async {}
}

public enum DeinterlaceAlgorithm: String, Codable, CaseIterable, Sendable {
    case appleTemporal
    case metalYADIF2x
}

/// The buffering knobs that decide how much slack the pipeline keeps between the
/// decoder and the display.
///
/// These were constants scattered across the presentation queue, the readiness
/// gate and the deinterlacer, which made them impossible to change without a
/// rebuild — and easy to get wrong: the deinterlacer's bound was raised in its
/// designated initialiser while the initialiser the app actually calls kept its
/// own default, so the app ran on the old value. Gathering them here means one
/// value reaches every user of it.
public struct PlaybackTuning: Sendable, Equatable {
    /// How much decoded video the pipeline keeps ahead of the display.
    ///
    /// This is a *duration* rather than a frame count on purpose: the
    /// field-rate deinterlace routes emit two frames per input frame, so a
    /// frame-count bound silently halves for interlaced content — which is
    /// exactly the material that needs the buffer most.
    public static let videoBufferSecondsChoices: [Double] = [0.5, 1, 2, 4]
    /// How many deinterlace inputs may wait for the GPU before work is shed.
    /// Shedding here starts the cascade on a live stream: the lost field pair
    /// puts video behind the clock, a live source cannot be caught up, and the
    /// re-anchor that follows costs a whole window of frames.
    public static let deinterlaceBufferFramesChoices: [Int] = [4, 8, 12, 16]

    public static let `default` = PlaybackTuning()

    public let videoBufferSeconds: Double
    public let deinterlaceBufferFrames: Int

    public init(
        videoBufferSeconds: Double = 1,
        deinterlaceBufferFrames: Int = 8
    ) {
        self.videoBufferSeconds = Self.videoBufferSecondsChoices.contains(videoBufferSeconds)
            ? videoBufferSeconds
            : 1
        self.deinterlaceBufferFrames = Self.deinterlaceBufferFramesChoices
            .contains(deinterlaceBufferFrames)
            ? deinterlaceBufferFrames
            : 8
    }

    public var videoBufferHorizon: CMTime {
        CMTime(seconds: videoBufferSeconds, preferredTimescale: 1_000)
    }

    /// Guards against pathological timestamps only — normal operation is bounded
    /// by the horizon. Scaled with the horizon so raising the buffer does not run
    /// into a frame bound that was sized for a shorter one.
    public var videoBufferFrameCeiling: Int {
        max(24, Int((120 * videoBufferSeconds).rounded()))
    }

    /// The floor the decode session's output pixel-buffer pool is held at.
    ///
    /// Derived rather than configured: it is a count of the buffers this
    /// pipeline provably has checked out at once — the in-flight submission
    /// window, YADIF's pending queue plus its three-frame reference window, and
    /// the presentation frames not yet released. Left at the default the pool
    /// ages buffers out and reallocates them under load, and an IOSurface
    /// allocation is far too expensive to repeat per frame.
    public var decoderOutputPoolFloor: Int {
        deinterlaceBufferFrames + 16
    }

    /// Undecoded access units allowed to queue ahead of the decoder before the
    /// pipeline skips to the next random-access point.
    ///
    /// Derived rather than configured: this queue exists to absorb bursts, and
    /// queueing more than the presentation buffer can hold only adds latency to
    /// frames that the horizon will trim anyway. Its real job is to bound the
    /// damage when decode falls behind — the alternative is unbounded growth on
    /// a live source that never slows down to let the decoder catch up.
    public var decodeSubmissionQueueDepth: Int {
        max(8, Int((videoBufferSeconds * 16).rounded()))
    }

    /// How far behind the newest decoded frame the clock may be anchored.
    ///
    /// Derived rather than configured: anchoring further back than the buffer
    /// spans makes every arriving frame overflow before the clock reaches it,
    /// for as long as playback runs, so this is only meaningful relative to the
    /// buffer. Three quarters leaves the clock real runway before it can overtake
    /// the decoder while staying inside the span. Halving the fraction traded
    /// overflow drops for twice as many re-anchors, which cost more.
    public var maximumAnchorLag: CMTime {
        CMTime(seconds: videoBufferSeconds * 0.75, preferredTimescale: 1_000)
    }
}
