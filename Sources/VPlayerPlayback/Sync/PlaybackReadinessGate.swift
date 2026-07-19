// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

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
    }

    private let clock: PlaybackClock
    private let hostTimeProvider: () -> CMTime
    private let prepareAnchor: ((CMTime) -> Void)?
    private var requiredVideoFrameCount = 1
    private var audio: AudioSnapshot?
    private var video: VideoSnapshot?
    private var waitingForDisplayModeEnd = false

    public private(set) var isOpen = false
    public private(set) var cycleID: UInt64

    public convenience init(
        clock: PlaybackClock,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        prepareAnchor: ((CMTime) -> Void)? = nil
    ) {
        self.init(
            clock: clock,
            hostTime: { CMClockGetTime(hostClock) },
            prepareAnchor: prepareAnchor
        )
    }

    init(
        clock: PlaybackClock,
        hostTime: @escaping () -> CMTime,
        prepareAnchor: ((CMTime) -> Void)?,
        initialCycleID: UInt64 = 0
    ) {
        self.clock = clock
        hostTimeProvider = hostTime
        self.prepareAnchor = prepareAnchor
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
        _ = attemptOpen()
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
        video = VideoSnapshot(firstPTS: firstPTS, readyFrameCount: readyFrameCount)
        _ = attemptOpen()
    }

    public func close(_ reason: PlaybackReadinessCloseReason) {
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
              let audio,
              let video,
              video.readyFrameCount >= requiredVideoFrameCount,
              CMTimeCompare(audio.contiguousDuration, CMTime(value: 1, timescale: 4)) >= 0 else {
            return false
        }
        let commonPTS = CMTimeCompare(audio.firstPTS, video.firstPTS) >= 0
            ? audio.firstPTS
            : video.firstPTS
        guard commonPTS.isNumeric else { return false }
        prepareAnchor?(commonPTS)
        let anchorHostTime = CMTimeAdd(
            hostTimeProvider(),
            CMTime(value: 100, timescale: 1_000)
        )
        guard anchorHostTime.isNumeric else { return false }
        clock.anchor(mediaTime: commonPTS, atHostTime: anchorHostTime, rate: 1)
        isOpen = true
        return true
    }
}
