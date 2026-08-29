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

public enum PlaybackReadinessCloseReason: UInt8, Sendable, Equatable, CaseIterable {
    case flush
    case buffering
    case pause
    case discontinuity
    case audioReplacement
    case displayModeSwitch
    case audioGap
}

public final class PlaybackReadinessGate {
    private struct AudioSnapshot {
        let firstPTS: CMTime
        let contiguousDuration: CMTime
    }

    private struct VideoSnapshot {
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
    private var audioOnlyOpen = false

    public private(set) var isOpen = false
    public private(set) var cycleID: UInt64
    // A renderer replacement or presentation interruption is still the same
    // media timeline. Its next anchor may advance, but must never rewind the
    // shared A/V clock and replay retained history.
    private(set) var minimumRecoveryAnchorPTS: CMTime?
    // Diagnostics only: indexed by `PlaybackReadinessCloseReason.rawValue`, so a
    // flapping gate can be attributed to the caller that keeps closing it.
    public private(set) var closeReasonCounts = [UInt64](
        repeating: 0,
        count: PlaybackReadinessCloseReason.allCases.count
    )

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

    public func setMaximumAnchorLag(_ lag: CMTime) {
        guard lag.isNumeric, CMTimeCompare(lag, .zero) > 0 else { return }
        maximumAnchorLag = lag
    }

    public func updateAudio(
        firstPTS: CMTime,
        contiguousDuration: CMTime,
        isContiguous: Bool
    ) {
        // The pipeline publishes a valid snapshot only after its audio renderer
        // reports that it can start. An invalid/non-contiguous update therefore
        // clears both renderer readiness and the usable audio timeline here.
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

    /// Opens the shared clock for a session that has no video timeline. Audio
    /// readiness still needs the same rate-one anchor as the A/V path; the
    /// absence of video only removes the frame-coverage veto.
    @discardableResult
    func openAudioOnly(firstPTS: CMTime) -> Bool {
        guard !isOpen,
              !waitingForDisplayModeEnd,
              firstPTS.isNumeric else { return isOpen }
        let anchorPTS: CMTime
        if let floor = minimumRecoveryAnchorPTS {
            guard let audio else { return false }
            let audioEnd = CMTimeAdd(audio.firstPTS, audio.contiguousDuration)
            guard audioEnd.isNumeric,
                  CMTimeCompare(floor, audioEnd) < 0 else { return false }
            anchorPTS = CMTimeCompare(firstPTS, floor) >= 0 ? firstPTS : floor
        } else {
            anchorPTS = firstPTS
        }
        let openingCycle = cycleID
        guard prepareAnchorVeto?(anchorPTS) != false,
              cycleID == openingCycle,
              !isOpen,
              !waitingForDisplayModeEnd else { return false }
        let anchorHostTime = CMTimeAdd(
            hostTimeProvider(),
            CMTime(value: 100, timescale: 1_000)
        )
        guard anchorHostTime.isNumeric else { return false }
        clock.anchor(mediaTime: anchorPTS, atHostTime: anchorHostTime, rate: 1)
        minimumRecoveryAnchorPTS = nil
        audioOnlyOpen = true
        isOpen = true
        return true
    }

    /// Updates count-only video availability. This can keep an already-open
    /// gate healthy, but cannot establish initial readiness because it carries
    /// no frame durations with which to prove audio interval coverage.
    public func updateVideo(firstPTS: CMTime, readyFrameCount: Int) {
        guard firstPTS.isNumeric, readyFrameCount >= 0 else {
            if isOpen {
                close(.buffering)
            } else {
                video = nil
            }
            return
        }
        video = VideoSnapshot(readyFrameCount: readyFrameCount, frames: nil)
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
        guard valid.count == frames.count, !valid.isEmpty else {
            if isOpen {
                close(.buffering)
            } else {
                video = nil
            }
            return
        }
        video = VideoSnapshot(
            readyFrameCount: valid.count,
            frames: valid
        )
        reevaluate()
    }

    public func close(_ reason: PlaybackReadinessCloseReason) {
        close(reason, preservingTimeline: true)
    }

    /// Closes readiness and clears the monotonic recovery floor because the
    /// caller is starting a genuinely new media timeline.
    public func closeForTimelineReset(_ reason: PlaybackReadinessCloseReason) {
        close(reason, preservingTimeline: false)
    }

    private func close(
        _ reason: PlaybackReadinessCloseReason,
        preservingTimeline: Bool
    ) {
        if preservingTimeline {
            if isOpen {
                let currentTime = clock.currentTime
                if currentTime.isNumeric {
                    if let floor = minimumRecoveryAnchorPTS {
                        if CMTimeCompare(currentTime, floor) > 0 {
                            minimumRecoveryAnchorPTS = currentTime
                        }
                    } else {
                        minimumRecoveryAnchorPTS = currentTime
                    }
                }
            }
        } else {
            minimumRecoveryAnchorPTS = nil
        }
        let slot = Int(reason.rawValue)
        if closeReasonCounts.indices.contains(slot) {
            closeReasonCounts[slot] &+= 1
        }
        clock.pause()
        isOpen = false
        audioOnlyOpen = false
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
        minimumRecoveryAnchorPTS = nil
        audioOnlyOpen = false
        isOpen = true
        return true
    }

    // The renderer buffers only a bounded span of decoded video. Anchoring
    // further behind the newest frame than that makes every arriving frame
    // overflow the presentation queue before the clock ever reaches it, which
    // costs frames for as long as playback runs. `commonReadyPTS` is otherwise
    // free to land anywhere back to the oldest retained audio — measured anchor
    // lags ranged from 0.4 s to 1.8 s across runs of the same stream.
    // Sits just inside the renderer's buffered span: far enough back to give the
    // clock real runway before it can overtake the decoder, close enough that the
    // queue never overflows. Derived from the configured buffer length, so
    // lengthening the buffer lengthens the usable anchor window with it.
    private var maximumAnchorLag = PlaybackTuning.default.maximumAnchorLag

    private func reevaluate() {
        if isOpen {
            if !canRemainOpen() { close(.buffering) }
            return
        }
        _ = attemptOpen()
    }

    // Staying open deliberately does not re-apply startup interval coverage.
    // Anchoring trims the pipeline's retained windows back to the anchor point,
    // and video output legitimately leads the audio ingest edge on a live
    // stream. Requiring every subsequent snapshot to retain the original common
    // interval would flap the gate while playback is healthy. A genuine stall
    // still closes it: non-contiguous audio and an empty video window are handled
    // by `updateAudio`/`updateVideo`, and the frame-count floor below catches
    // video starvation.
    private func canRemainOpen() -> Bool {
        if audioOnlyOpen {
            guard let audio else { return false }
            return CMTimeAdd(audio.firstPTS, audio.contiguousDuration).isNumeric
        }
        guard let audio, let video,
              video.readyFrameCount >= requiredVideoFrameCount else { return false }
        return CMTimeAdd(audio.firstPTS, audio.contiguousDuration).isNumeric
    }

    private func commonReadyPTS() -> CMTime? {
        guard let audio, let video,
              video.readyFrameCount >= requiredVideoFrameCount,
              let frames = video.frames else { return nil }
        let audioEnd = CMTimeAdd(audio.firstPTS, audio.contiguousDuration)
        guard audioEnd.isNumeric else { return nil }
        let coveredFrames = frames.filter { frame in
            let end = CMTimeAdd(frame.presentationTimeStamp, frame.duration)
            return CMTimeCompare(end, audio.firstPTS) > 0
                && CMTimeCompare(end, audioEnd) <= 0
        }
        guard coveredFrames.count >= requiredVideoFrameCount,
              let oldestCoveredFrame = coveredFrames.first else { return nil }

        var commonPTS = CMTimeCompare(
            audio.firstPTS,
            oldestCoveredFrame.presentationTimeStamp
        ) >= 0 ? audio.firstPTS : oldestCoveredFrame.presentationTimeStamp
        if let newest = coveredFrames.last?.presentationTimeStamp {
            let latestUsefulAnchor = CMTimeSubtract(newest, maximumAnchorLag)
            if latestUsefulAnchor.isNumeric,
               CMTimeCompare(latestUsefulAnchor, commonPTS) > 0 {
                commonPTS = latestUsefulAnchor
            }
        }
        if let minimumRecoveryAnchorPTS,
           CMTimeCompare(minimumRecoveryAnchorPTS, commonPTS) > 0 {
            commonPTS = minimumRecoveryAnchorPTS
        }
        guard commonPTS.isNumeric,
              CMTimeCompare(commonPTS, audioEnd) < 0 else { return nil }
        let readyFrameCount = coveredFrames.lazy.filter { frame in
            CMTimeCompare(
                CMTimeAdd(frame.presentationTimeStamp, frame.duration),
                commonPTS
            ) > 0
        }.count
        guard readyFrameCount >= requiredVideoFrameCount else { return nil }
        return commonPTS
    }
}
