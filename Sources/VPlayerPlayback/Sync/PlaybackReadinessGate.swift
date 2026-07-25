// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public struct PlaybackReadinessVideoFrame: Sendable, Equatable {
    public let presentationTimeStamp: CMTime
    public let duration: CMTime

    public init(presentationTimeStamp: CMTime, duration: CMTime) {
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
    }
}

public enum PlaybackReadinessCloseReason: UInt8, Sendable, Equatable {
    case flush
    case buffering
    case pause
    case discontinuity
    case audioReplacement
    case displayModeSwitch
}

public final class PlaybackReadinessGate {
    private struct AudioSnapshot {
        let firstPTS: CMTime
        let contiguousDuration: CMTime
    }

    private struct VideoSnapshot {
        let firstPTS: CMTime
        let readyFrameCount: Int
        let frames: [PlaybackReadinessVideoFrame]?
    }

    private let clock: PlaybackClock
    private let hostTimeProvider: () -> CMTime
    private let prepareAnchorVeto: ((CMTime) -> Bool)?
    private var requiredVideoFrameCount = 1
    private var audio: AudioSnapshot?
    private var video: VideoSnapshot?
    private var waitingForDisplayModeEnd = false

    public private(set) var isOpen = false
    public private(set) var cycleID: UInt64
    // Diagnostics only: indexed by `PlaybackReadinessCloseReason.rawValue`, so a
    // flapping gate can be attributed to the caller that keeps closing it.
    public private(set) var closeReasonCounts = [UInt64](repeating: 0, count: 6)

    public convenience init(
        clock: PlaybackClock,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        prepareAnchor: ((CMTime) -> Void)? = nil
    ) {
        self.init(
            clock: clock,
            hostTime: { CMClockGetTime(hostClock) },
            prepareAnchorVeto: prepareAnchor.map { prepare in
                { time in
                    prepare(time)
                    return true
                }
            }
        )
    }

    convenience init(
        clock: PlaybackClock,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        prepareAnchorVeto: @escaping (CMTime) -> Bool
    ) {
        self.init(
            clock: clock,
            hostTime: { CMClockGetTime(hostClock) },
            prepareAnchorVeto: prepareAnchorVeto
        )
    }

    init(
        clock: PlaybackClock,
        hostTime: @escaping () -> CMTime,
        prepareAnchorVeto: ((CMTime) -> Bool)?,
        initialCycleID: UInt64 = 0
    ) {
        self.clock = clock
        hostTimeProvider = hostTime
        self.prepareAnchorVeto = prepareAnchorVeto
        cycleID = initialCycleID
        clock.pause()
    }

    public func configure(requiredVideoFrameCount: Int) {
        self.requiredVideoFrameCount = max(1, requiredVideoFrameCount)
        _ = attemptOpen()
    }

    public func updateAudio(
        firstPTS: CMTime,
        contiguousDuration: CMTime,
        isContiguous: Bool
    ) {
        guard isContiguous,
              firstPTS.isNumeric,
              contiguousDuration.isNumeric,
              CMTimeCompare(contiguousDuration, .zero) >= 0 else {
            if isOpen {
                close(isContiguous ? .buffering : .discontinuity)
            } else {
                audio = nil
            }
            return
        }
        audio = AudioSnapshot(firstPTS: firstPTS, contiguousDuration: contiguousDuration)
        reevaluate()
    }

    public func updateVideo(firstPTS: CMTime, readyFrameCount: Int) {
        guard firstPTS.isNumeric, readyFrameCount >= 0 else {
            if isOpen {
                close(.buffering)
            } else {
                video = nil
            }
            return
        }
        video = VideoSnapshot(firstPTS: firstPTS, readyFrameCount: readyFrameCount, frames: nil)
        reevaluate()
    }

    public func updateVideo(frames: [PlaybackReadinessVideoFrame]) {
        let valid = frames.filter { frame in
            guard frame.presentationTimeStamp.isNumeric,
                  frame.duration.isNumeric,
                  CMTimeCompare(frame.duration, .zero) > 0 else { return false }
            return CMTimeAdd(frame.presentationTimeStamp, frame.duration).isNumeric
        }.sorted {
            CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
        }
        guard valid.count == frames.count, let first = valid.first else {
            if isOpen {
                close(.buffering)
            } else {
                video = nil
            }
            return
        }
        video = VideoSnapshot(
            firstPTS: first.presentationTimeStamp,
            readyFrameCount: valid.count,
            frames: valid
        )
        reevaluate()
    }

    public func close(_ reason: PlaybackReadinessCloseReason) {
        let slot = Int(reason.rawValue)
        if closeReasonCounts.indices.contains(slot) {
            closeReasonCounts[slot] &+= 1
        }
        clock.pause()
        isOpen = false
        if cycleID < UInt64.max {
            cycleID += 1
        }
        if reason == .displayModeSwitch {
            waitingForDisplayModeEnd = true
        } else {
            audio = nil
            video = nil
            waitingForDisplayModeEnd = false
        }
    }

    @discardableResult
    public func reopenAfterDisplayModeSwitch() -> Bool {
        guard waitingForDisplayModeEnd else { return false }
        waitingForDisplayModeEnd = false
        return attemptOpen()
    }

    @discardableResult
    private func attemptOpen() -> Bool {
        guard !isOpen,
              !waitingForDisplayModeEnd,
              let commonPTS = commonReadyPTS() else {
            return false
        }
        let openingCycle = cycleID
        guard prepareAnchorVeto?(commonPTS) != false,
              cycleID == openingCycle,
              !isOpen,
              !waitingForDisplayModeEnd,
              commonReadyPTS() == commonPTS else { return false }
        let anchorHostTime = CMTimeAdd(
            hostTimeProvider(),
            CMTime(value: 100, timescale: 1_000)
        )
        guard anchorHostTime.isNumeric else { return false }
        clock.anchor(mediaTime: commonPTS, atHostTime: anchorHostTime, rate: 1)
        isOpen = true
        return true
    }

    // Opening waits for this much buffered audio past the anchor so the first
    // anchor does not start out starved.
    private static let startupAudioRunway = CMTime(value: 1, timescale: 4)
    // The renderer buffers only a bounded span of decoded video. Anchoring
    // further behind the newest frame than that makes every arriving frame
    // overflow the presentation queue before the clock ever reaches it, which
    // costs frames for as long as playback runs. `commonReadyPTS` is otherwise
    // free to land anywhere back to the oldest retained audio — measured anchor
    // lags ranged from 0.4 s to 1.8 s across runs of the same stream.
    // Sits just inside the renderer's one-second span: far enough back to give
    // the clock real runway before it can overtake the decoder, close enough
    // that the queue never overflows. Halving it traded overflow drops for twice
    // as many re-anchors, which cost more frames than they saved.
    private static let maximumAnchorLag = CMTime(value: 3, timescale: 4)

    private func reevaluate() {
        if isOpen {
            if !canRemainOpen() { close(.buffering) }
            return
        }
        _ = attemptOpen()
    }

    // Staying open deliberately drops the startup runway requirement. Anchoring
    // trims the pipeline's retained windows back to the anchor point, and video
    // output legitimately leads the audio ingest edge on a live stream, so a
    // healthy running pipeline sits *below* the startup threshold nearly all the
    // time. Re-applying it on every audio packet closed the gate ~10x/second;
    // each close paused the clock and the following reopen flushed the renderer
    // and re-anchored, which is what cut live playback to a few frames/second.
    // A genuine stall still closes the gate: non-contiguous audio and an empty
    // video window are handled by `updateAudio`/`updateVideo` directly, and the
    // frame-count floor below catches video starvation.
    private func canRemainOpen() -> Bool {
        guard let audio, let video,
              video.readyFrameCount >= requiredVideoFrameCount else { return false }
        return CMTimeAdd(audio.firstPTS, audio.contiguousDuration).isNumeric
    }

    private func commonReadyPTS() -> CMTime? {
        guard let audio, let video,
              video.readyFrameCount >= requiredVideoFrameCount else { return nil }
        let audioEnd = CMTimeAdd(audio.firstPTS, audio.contiguousDuration)
        guard audioEnd.isNumeric else { return nil }
        var commonPTS = CMTimeCompare(audio.firstPTS, video.firstPTS) >= 0
            ? audio.firstPTS
            : video.firstPTS
        if let newest = video.frames?.last?.presentationTimeStamp {
            let latestUsefulAnchor = CMTimeSubtract(newest, Self.maximumAnchorLag)
            let runwayLimit = CMTimeSubtract(audioEnd, Self.startupAudioRunway)
            if latestUsefulAnchor.isNumeric,
               runwayLimit.isNumeric,
               CMTimeCompare(latestUsefulAnchor, commonPTS) > 0 {
                commonPTS = CMTimeCompare(latestUsefulAnchor, runwayLimit) <= 0
                    ? latestUsefulAnchor
                    : runwayLimit
            }
        }
        guard commonPTS.isNumeric,
              CMTimeCompare(commonPTS, audioEnd) < 0,
              CMTimeCompare(
                  CMTimeSubtract(audioEnd, commonPTS),
                  Self.startupAudioRunway
              ) >= 0 else { return nil }
        if let frames = video.frames {
            let overlappingCount = frames.filter { frame in
                let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
                return CMTimeCompare(end, commonPTS) > 0
                    && CMTimeCompare(frame.presentationTimeStamp, audioEnd) < 0
            }.count
            guard overlappingCount >= requiredVideoFrameCount else { return nil }
        } else {
            guard CMTimeCompare(video.firstPTS, audioEnd) < 0 else { return nil }
        }
        return commonPTS
    }
}
