// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class PlaybackClockTests: XCTestCase {
    func testPublicReadinessInitializerAcceptsOriginalVoidPrepareAnchorClosure() {
        let clock = FakePlaybackClock()
        var prepared: [CMTime] = []
        let prepareAnchor: (CMTime) -> Void = { prepared.append($0) }
        let gate = PlaybackReadinessGate(
            clock: clock,
            hostClock: CMClockGetHostTimeClock(),
            prepareAnchor: prepareAnchor
        )
        gate.configure(requiredVideoFrameCount: 1)
        gate.updateAudio(
            firstPTS: .zero,
            contiguousDuration: CMTime(value: 1, timescale: 4),
            isContiguous: true
        )
        gate.updateVideo(frames: frames(firstPTS: .zero, count: 1))

        XCTAssertEqual(prepared, [.zero])
        XCTAssertTrue(gate.isOpen)
    }

    func testRenderSynchronizerClockOwnsCallerSynchronizerAndUsesInjectedExactTimeConversion() {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        var convertedHostTimes: [CMTime] = []
        var pauses = 0
        var anchors: [(CMTime, CMTime, Float)] = []
        let subject = RenderSynchronizerClock(
            synchronizer: synchronizer,
            currentTime: { CMTime(value: 11, timescale: 2) },
            convertHostTime: {
                convertedHostTimes.append($0)
                return CMTime(value: 7, timescale: 1)
            },
            pause: { pauses += 1 },
            anchor: { anchors.append(($0, $1, $2)) }
        )

        XCTAssertTrue(subject.synchronizer === synchronizer)
        XCTAssertEqual(subject.currentTime, CMTime(value: 11, timescale: 2))
        XCTAssertEqual(
            subject.mediaTime(forHostTime: CMTime(value: 100, timescale: 1)),
            CMTime(value: 7, timescale: 1)
        )
        subject.pause()
        subject.anchor(
            mediaTime: CMTime(value: 9, timescale: 1),
            atHostTime: CMTime(value: 101, timescale: 1),
            rate: 1
        )

        XCTAssertEqual(convertedHostTimes, [CMTime(value: 100, timescale: 1)])
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors.first?.0, CMTime(value: 9, timescale: 1))
        XCTAssertEqual(anchors.first?.1, CMTime(value: 101, timescale: 1))
        XCTAssertEqual(anchors.first?.2, 1)
    }

    func testReadinessOpensWhenAnActualVideoFrameIsFullyCoveredByReadyAudio() {
        let harness = makeGate(requiredVideoCount: 1)
        harness.gate.updateVideo(frames: frames(firstPTS: time(3), count: 1))
        harness.gate.updateAudio(
            firstPTS: time(3),
            contiguousDuration: CMTime(value: 39_999, timescale: 1_000_000),
            isContiguous: true
        )
        XCTAssertFalse(harness.gate.isOpen)
        XCTAssertTrue(harness.clock.anchors.isEmpty)

        harness.gate.updateAudio(
            firstPTS: time(3),
            contiguousDuration: CMTime(value: 1, timescale: 25),
            isContiguous: true
        )
        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(harness.clock.anchors.count, 1)
    }

    func testReadinessOpensWhenAudioStartsInsideAFrameAndCoversItsEnd() {
        let harness = makeGate(requiredVideoCount: 1)
        harness.gate.updateVideo(frames: frames(firstPTS: .zero, count: 1))
        harness.gate.updateAudio(
            firstPTS: CMTime(value: 1, timescale: 100),
            contiguousDuration: CMTime(value: 3, timescale: 100),
            isContiguous: true
        )

        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(
            harness.clock.anchors.first?.mediaTime,
            CMTime(value: 1, timescale: 100)
        )
    }

    func testVideoSummaryCannotOpenWithoutActualFrameIntervals() {
        let harness = makeGate(requiredVideoCount: 1)
        harness.gate.updateAudio(
            firstPTS: time(3),
            contiguousDuration: time(10),
            isContiguous: true
        )
        harness.gate.updateVideo(firstPTS: time(3), readyFrameCount: 100)

        XCTAssertFalse(harness.gate.isOpen)
        XCTAssertTrue(harness.clock.anchors.isEmpty)
    }

    func testReadinessDoesNotCapObservedAVTimestampSeparation() {
        let harness = makeGate(requiredVideoCount: 1)
        harness.gate.updateAudio(
            firstPTS: .zero,
            contiguousDuration: CMTime(value: 126, timescale: 25),
            isContiguous: true
        )
        harness.gate.updateVideo(frames: frames(firstPTS: time(5), count: 1))

        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(harness.clock.anchors.map(\.mediaTime), [time(5)])
    }

    func testRequiredVideoCountOneAndThreeUseExactBoundaries() {
        for required in [1, 3] {
            let harness = makeGate(requiredVideoCount: required)
            harness.gate.updateAudio(
                firstPTS: time(1),
                contiguousDuration: CMTime(value: 1, timescale: 4),
                isContiguous: true
            )
            harness.gate.updateVideo(frames: frames(firstPTS: time(1), count: required - 1))
            XCTAssertFalse(harness.gate.isOpen)
            harness.gate.updateVideo(frames: frames(firstPTS: time(1), count: required))
            XCTAssertTrue(harness.gate.isOpen)
        }
    }

    func testInvalidOrGappedAudioNeverOpens() {
        let invalidDurations = [CMTime.invalid, .indefinite, CMTime(value: -1, timescale: 1)]
        for duration in invalidDurations {
            let harness = makeGate(requiredVideoCount: 1)
            harness.gate.updateVideo(frames: frames(firstPTS: time(1), count: 1))
            harness.gate.updateAudio(firstPTS: time(1), contiguousDuration: duration, isContiguous: true)
            XCTAssertFalse(harness.gate.isOpen)
        }

        let gapped = makeGate(requiredVideoCount: 1)
        gapped.gate.updateVideo(frames: frames(firstPTS: time(1), count: 1))
        gapped.gate.updateAudio(
            firstPTS: time(1),
            contiguousDuration: CMTime(value: 1, timescale: 1),
            isContiguous: false
        )
        XCTAssertFalse(gapped.gate.isOpen)
    }

    func testInvalidOrGappedAudioClosesAnOpenGateAndRequiresFreshReadiness() {
        let invalidUpdates: [(CMTime, Bool)] = [
            (CMTime.invalid, true),
            (CMTime(value: 1, timescale: 1), false),
        ]
        for (duration, isContiguous) in invalidUpdates {
            let harness = makeGate(requiredVideoCount: 1)
            makeReady(harness.gate, audioPTS: time(1), videoPTS: time(1))
            let cycleBeforeInvalidation = harness.gate.cycleID
            let pausesBeforeInvalidation = harness.clock.pauseCount

            harness.gate.updateAudio(
                firstPTS: time(2),
                contiguousDuration: duration,
                isContiguous: isContiguous
            )

            XCTAssertFalse(harness.gate.isOpen)
            XCTAssertEqual(harness.gate.cycleID, cycleBeforeInvalidation + 1)
            XCTAssertEqual(harness.clock.pauseCount, pausesBeforeInvalidation + 1)
            harness.gate.updateAudio(
                firstPTS: time(3),
                contiguousDuration: CMTime(value: 1, timescale: 4),
                isContiguous: true
            )
            XCTAssertFalse(harness.gate.isOpen)
            harness.gate.updateVideo(frames: frames(firstPTS: time(3), count: 1))
            XCTAssertTrue(harness.gate.isOpen)
        }
    }

    func testCommonPTSUsesExactMaxAndPrepareRunsBeforeHostNowPlus100MillisecondAnchor() {
        var order: [String] = []
        let clock = FakePlaybackClock(order: { order.append($0) })
        let gate = PlaybackReadinessGate(
            clock: clock,
            hostTime: { CMTime(value: 100, timescale: 1) },
            prepareAnchorVeto: {
                order.append("prepare")
                XCTAssertEqual($0, CMTime(value: 10_001, timescale: 1_000))
                return true
            }
        )
        gate.configure(requiredVideoFrameCount: 1)
        gate.updateAudio(
            firstPTS: CMTime(value: 10_000, timescale: 1_000),
            contiguousDuration: CMTime(value: 251, timescale: 1_000),
            isContiguous: true
        )
        gate.updateVideo(frames: frames(
            firstPTS: CMTime(value: 10_001, timescale: 1_000),
            count: 1
        ))

        XCTAssertEqual(order.suffix(2), ["prepare", "anchor"])
        XCTAssertEqual(clock.anchors.first?.mediaTime, CMTime(value: 10_001, timescale: 1_000))
        XCTAssertEqual(clock.anchors.first?.hostTime, CMTime(value: 100_100, timescale: 1_000))
        XCTAssertEqual(clock.anchors.first?.rate, 1)
    }

    func testGateRequiresACommonIntervalWithFullPostIntersectionReadiness() {
        let nonOverlapping = makeGate(requiredVideoCount: 1)
        nonOverlapping.gate.updateAudio(
            firstPTS: time(10),
            contiguousDuration: CMTime(value: 1, timescale: 2),
            isContiguous: true
        )
        nonOverlapping.gate.updateVideo(frames: [
            PlaybackReadinessVideoFrame(
                presentationTimeStamp: .zero,
                duration: CMTime(value: 1, timescale: 25)
            ),
        ])
        XCTAssertFalse(nonOverlapping.gate.isOpen)
        XCTAssertTrue(nonOverlapping.clock.anchors.isEmpty)

        let clippedAudio = makeGate(requiredVideoCount: 1)
        clippedAudio.gate.updateAudio(
            firstPTS: time(1),
            contiguousDuration: CMTime(value: 1, timescale: 4),
            isContiguous: true
        )
        clippedAudio.gate.updateVideo(frames: [
            PlaybackReadinessVideoFrame(
                presentationTimeStamp: CMTime(value: 31, timescale: 25),
                duration: CMTime(value: 1, timescale: 25)
            ),
        ])
        XCTAssertFalse(clippedAudio.gate.isOpen)
        XCTAssertTrue(clippedAudio.clock.anchors.isEmpty)

        let overlapping = makeGate(requiredVideoCount: 2)
        overlapping.gate.updateAudio(
            firstPTS: .zero,
            contiguousDuration: CMTime(value: 1, timescale: 2),
            isContiguous: true
        )
        overlapping.gate.updateVideo(frames: [
            PlaybackReadinessVideoFrame(
                presentationTimeStamp: CMTime(value: 1, timescale: 5),
                duration: CMTime(value: 1, timescale: 25)
            ),
            PlaybackReadinessVideoFrame(
                presentationTimeStamp: CMTime(value: 6, timescale: 25),
                duration: CMTime(value: 1, timescale: 25)
            ),
        ])
        XCTAssertTrue(overlapping.gate.isOpen)
        XCTAssertEqual(overlapping.clock.anchors.map(\.mediaTime), [CMTime(value: 1, timescale: 5)])
    }

    func testPrepareAnchorCanVetoOpeningWithoutRateOrOpenState() {
        let clock = FakePlaybackClock()
        var prepared: [CMTime] = []
        let gate = PlaybackReadinessGate(
            clock: clock,
            hostTime: { .zero },
            prepareAnchorVeto: {
                prepared.append($0)
                return false
            }
        )
        gate.configure(requiredVideoFrameCount: 1)
        gate.updateAudio(
            firstPTS: .zero,
            contiguousDuration: CMTime(value: 1, timescale: 4),
            isContiguous: true
        )
        gate.updateVideo(frames: [
            PlaybackReadinessVideoFrame(
                presentationTimeStamp: .zero,
                duration: CMTime(value: 1, timescale: 25)
            ),
        ])

        XCTAssertEqual(prepared, [.zero])
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(clock.anchors.isEmpty)
    }

    func testGateAnchorsOncePerCycleAndEveryCloseReasonPausesThenAllowsFreshCycle() {
        let reasons: [PlaybackReadinessCloseReason] = [
            .flush, .buffering, .pause, .discontinuity, .audioReplacement, .audioGap,
        ]
        for reason in reasons {
            let harness = makeGate(requiredVideoCount: 1)
            makeReady(harness.gate, audioPTS: time(1), videoPTS: time(1))
            makeReady(harness.gate, audioPTS: time(2), videoPTS: time(2))
            XCTAssertEqual(harness.clock.anchors.count, 1)
            let priorCycle = harness.gate.cycleID

            harness.gate.close(reason)
            XCTAssertFalse(harness.gate.isOpen)
            XCTAssertEqual(harness.gate.cycleID, priorCycle + 1)
            XCTAssertGreaterThanOrEqual(harness.clock.pauseCount, 1)
            makeReady(harness.gate, audioPTS: time(3), videoPTS: time(3))
            XCTAssertEqual(harness.clock.anchors.count, 2)
        }
    }

    func testSameTimelineRecoveryNeverAnchorsBeforeTheClockAtClose() {
        let harness = makeGate(requiredVideoCount: 1)
        makeReady(harness.gate, audioPTS: .zero, videoPTS: .zero)
        harness.clock.currentTime = time(5)

        harness.gate.close(.audioReplacement)
        makeReady(harness.gate, audioPTS: .zero, videoPTS: time(5))

        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(harness.clock.anchors.map(\.mediaTime), [.zero, time(5)])
    }

    func testAudioGapClosePreservesSameTimelineRecoveryFloor() {
        let harness = makeGate(requiredVideoCount: 1)
        makeReady(harness.gate, audioPTS: .zero, videoPTS: .zero)
        harness.clock.currentTime = time(5)

        harness.gate.close(.audioGap)
        makeReady(harness.gate, audioPTS: .zero, videoPTS: time(5))

        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(harness.clock.anchors.map(\.mediaTime), [.zero, time(5)])
        XCTAssertEqual(harness.gate.closeReasonCounts.count, 7)
        XCTAssertEqual(
            harness.gate.closeReasonCounts[Int(PlaybackReadinessCloseReason.audioGap.rawValue)],
            1
        )
    }

    func testTimelineResetAllowsAnEarlierAnchorForTheNewEpoch() {
        let harness = makeGate(requiredVideoCount: 1)
        makeReady(harness.gate, audioPTS: time(10), videoPTS: time(10))
        harness.clock.currentTime = time(12)

        harness.gate.closeForTimelineReset(.discontinuity)
        makeReady(harness.gate, audioPTS: .zero, videoPTS: .zero)

        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(harness.clock.anchors.map(\.mediaTime), [time(10), .zero])
    }

    func testDisplayModeClosePreservesSnapshotAndReopensWithOneFreshAnchor() {
        let harness = makeGate(requiredVideoCount: 3)
        makeReady(harness.gate, audioPTS: time(2), videoPTS: time(3), videoCount: 3)
        XCTAssertEqual(harness.clock.anchors.count, 1)

        harness.gate.close(.displayModeSwitch)
        XCTAssertFalse(harness.gate.isOpen)
        XCTAssertTrue(harness.gate.reopenAfterDisplayModeSwitch())
        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(harness.clock.anchors.map(\.mediaTime), [time(3), time(3)])
        XCTAssertFalse(harness.gate.reopenAfterDisplayModeSwitch())
        XCTAssertEqual(harness.clock.anchors.count, 2)
    }

    func testDisplayModeCloseCannotReopenFromReadinessUpdatesBeforeSwitchEnd() {
        let harness = makeGate(requiredVideoCount: 1)
        makeReady(harness.gate, audioPTS: time(1), videoPTS: time(1))
        harness.gate.close(.displayModeSwitch)

        makeReady(harness.gate, audioPTS: time(4), videoPTS: time(5))

        XCTAssertFalse(harness.gate.isOpen)
        XCTAssertEqual(harness.clock.anchors.map(\.mediaTime), [time(1)])
        XCTAssertTrue(harness.gate.reopenAfterDisplayModeSwitch())
        XCTAssertEqual(harness.clock.anchors.map(\.mediaTime), [time(1), time(5)])
    }

    func testCycleIdentityNeverWraps() {
        let clock = FakePlaybackClock()
        let gate = PlaybackReadinessGate(
            clock: clock,
            hostTime: { .zero },
            prepareAnchorVeto: nil,
            initialCycleID: UInt64.max - 1
        )
        gate.close(.flush)
        XCTAssertEqual(gate.cycleID, UInt64.max)
        gate.close(.buffering)
        XCTAssertEqual(gate.cycleID, UInt64.max)
    }

    func testRunningGateSurvivesSnapshotsWithoutTheirOriginalCommonInterval() {
        let harness = makeGate(requiredVideoCount: 2)
        harness.gate.updateAudio(
            firstPTS: time(1),
            contiguousDuration: CMTime(value: 1, timescale: 2),
            isContiguous: true
        )
        harness.gate.updateVideo(frames: frames(firstPTS: time(1), count: 2))
        XCTAssertTrue(harness.gate.isOpen)
        let openCycle = harness.gate.cycleID
        let pausesWhenOpened = harness.clock.pauseCount

        // Live steady state: anchoring trims the pipeline's retained windows back
        // to the anchor, and video output legitimately leads the audio ingest
        // edge. It must not close the gate merely because the newest snapshot no
        // longer contains the complete interval that established readiness.
        for step in 0..<40 {
            let base = CMTimeAdd(time(1), CMTime(value: Int64(step) * 24, timescale: 1_000))
            harness.gate.updateAudio(
                firstPTS: base,
                contiguousDuration: CMTime(value: 120, timescale: 1_000),
                isContiguous: true
            )
            harness.gate.updateVideo(
                firstPTS: CMTimeAdd(base, CMTime(value: 100, timescale: 1_000)),
                readyFrameCount: 6
            )
        }

        XCTAssertTrue(harness.gate.isOpen)
        XCTAssertEqual(harness.gate.cycleID, openCycle)
        XCTAssertEqual(harness.clock.pauseCount, pausesWhenOpened)
    }

    func testRunningGateStillClosesWhenTheVideoWindowStarves() {
        let harness = makeGate(requiredVideoCount: 2)
        harness.gate.updateAudio(
            firstPTS: time(1),
            contiguousDuration: CMTime(value: 1, timescale: 2),
            isContiguous: true
        )
        harness.gate.updateVideo(frames: frames(firstPTS: time(1), count: 2))
        XCTAssertTrue(harness.gate.isOpen)
        let openCycle = harness.gate.cycleID

        harness.gate.updateVideo(frames: frames(firstPTS: time(1), count: 1))

        XCTAssertFalse(harness.gate.isOpen)
        XCTAssertEqual(harness.gate.cycleID, openCycle + 1)
    }

    private func makeGate(requiredVideoCount: Int) -> GateHarness {
        let clock = FakePlaybackClock()
        let gate = PlaybackReadinessGate(
            clock: clock,
            hostTime: { CMTime(value: 100, timescale: 1) },
            prepareAnchorVeto: nil
        )
        gate.configure(requiredVideoFrameCount: requiredVideoCount)
        return GateHarness(gate: gate, clock: clock)
    }

    private func makeReady(
        _ gate: PlaybackReadinessGate,
        audioPTS: CMTime,
        videoPTS: CMTime,
        videoCount: Int = 1
    ) {
        gate.updateAudio(
            firstPTS: audioPTS,
            contiguousDuration: CMTime(value: 10, timescale: 1),
            isContiguous: true
        )
        gate.updateVideo(frames: frames(firstPTS: videoPTS, count: videoCount))
    }

    private func frames(firstPTS: CMTime, count: Int) -> [PlaybackReadinessVideoFrame] {
        (0..<count).map { index in
            PlaybackReadinessVideoFrame(
                presentationTimeStamp: CMTimeAdd(
                    firstPTS,
                    CMTime(value: Int64(index), timescale: 25)
                ),
                duration: CMTime(value: 1, timescale: 25)
            )
        }
    }

    func testAnchorLeadTimePolicyComputesAccurateLatencyForHDMIAndBluetooth() {
        let hdmiLeadTime = PlaybackAnchorLeadTimePolicy.compute(
            outputLatency: 0.015,
            ioBufferDuration: 0.010
        )
        // 25ms + 100ms margin = 125ms
        XCTAssertEqual(hdmiLeadTime.seconds, 0.125, accuracy: 0.001)

        let bluetoothLeadTime = PlaybackAnchorLeadTimePolicy.compute(
            outputLatency: 0.200,
            ioBufferDuration: 0.020
        )
        // 220ms + 100ms margin = 320ms
        XCTAssertEqual(bluetoothLeadTime.seconds, 0.320, accuracy: 0.001)

        let airPlayLeadTime = PlaybackAnchorLeadTimePolicy.compute(
            outputLatency: 0.500,
            ioBufferDuration: 0.050
        )
        // 550ms + 100ms margin = 650ms
        XCTAssertEqual(airPlayLeadTime.seconds, 0.650, accuracy: 0.001)

        let zeroLeadTime = PlaybackAnchorLeadTimePolicy.compute(
            outputLatency: 0,
            ioBufferDuration: 0
        )
        XCTAssertEqual(zeroLeadTime.seconds, 0.100, accuracy: 0.001)
    }

    func testPlaybackReadinessGateUsesConfiguredAnchorLeadTime() {
        let clock = FakePlaybackClock()
        let currentHostTime = CMTime(value: 1_000, timescale: 1_000)
        let gate = PlaybackReadinessGate(
            clock: clock,
            hostTime: { currentHostTime },
            prepareAnchorVeto: nil
        )
        gate.configure(requiredVideoFrameCount: 1)
        let customLeadTime = CMTime(value: 350, timescale: 1_000)
        gate.setAnchorLeadTime(customLeadTime)

        gate.updateVideo(frames: frames(firstPTS: .zero, count: 1))
        gate.updateAudio(
            firstPTS: .zero,
            contiguousDuration: CMTime(value: 1, timescale: 25),
            isContiguous: true
        )

        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(clock.anchors.count, 1)
        XCTAssertEqual(
            clock.anchors.first?.hostTime,
            CMTime(value: 1_350, timescale: 1_000)
        )
    }

    private func time(_ seconds: Int64) -> CMTime {
        CMTime(value: seconds, timescale: 1)
    }
}

private struct GateHarness {
    let gate: PlaybackReadinessGate
    let clock: FakePlaybackClock
}

private final class FakePlaybackClock: PlaybackClock {
    struct Anchor {
        let mediaTime: CMTime
        let hostTime: CMTime
        let rate: Float
    }

    private let order: ((String) -> Void)?
    var currentTime: CMTime = .zero
    var pauseCount = 0
    var anchors: [Anchor] = []

    init(order: ((String) -> Void)? = nil) {
        self.order = order
    }

    func mediaTime(forHostTime hostTime: CMTime) -> CMTime { hostTime }

    func pause() {
        pauseCount += 1
        order?("pause")
    }

    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        order?("anchor")
        anchors.append(.init(mediaTime: mediaTime, hostTime: hostTime, rate: rate))
    }
}
