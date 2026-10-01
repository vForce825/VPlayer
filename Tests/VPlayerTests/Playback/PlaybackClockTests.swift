// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class PlaybackClockTests: XCTestCase {
    @MainActor
    func testSimulatorOutputAuthorizationPreservesScheduledSDKStart() async throws {
#if targetEnvironment(simulator)
        // 只检查真实 SDK 的时钟语义；无 renderer、无媒体、无 HDMI 延迟测量。
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let clock = RenderSynchronizerClock(synchronizer: synchronizer)
        let hostClock = CMClockGetHostTimeClock()
        let beginHostTime = CMClockGetTime(hostClock)
        let futureHostTime = CMTimeAdd(beginHostTime, CMTime(value: 500, timescale: 1_000))
        let anchorMediaTime = CMTime(value: 10, timescale: 1)
        clock.anchor(mediaTime: anchorMediaTime, atHostTime: futureHostTime, rate: 0)
        clock.setRate(1)
        defer { clock.pause() }

        var samples: [(label: String, host: CMTime, media: CMTime)] = []
        func sample(_ label: String) {
            samples.append((label, CMClockGetTime(hostClock), clock.currentTime))
        }
        sample("立即")
        try await Task.sleep(nanoseconds: 100_000_000)
        sample("约100ms")
        try await Task.sleep(nanoseconds: 500_000_000)
        sample("约600ms")
        for value in samples {
            print(String(format: "SDK时钟探针 %@：实际host经过=%.6fs，媒体时间=%.6fs，速率=%.1f",
                value.label, CMTimeSubtract(value.host, beginHostTime).seconds,
                value.media.seconds, synchronizer.rate))
        }
        let last = try XCTUnwrap(samples.last)
        XCTAssertTrue(last.media.isNumeric && last.media.seconds.isFinite)
        let expectedWithLead = anchorMediaTime.seconds + CMTimeSubtract(last.host, futureHostTime).seconds
        let difference = last.media.seconds - expectedWithLead
        XCTAssertEqual(difference, 0, accuracy: 0.1,
                       "启用输出必须保留未来启动时刻，不能提前开始媒体时钟")
        print(String(format: "SDK时钟验证：相对预定启动轨迹的差值=%.6fs", difference))
#else
        throw XCTSkip("SDK时钟探针只允许在模拟器运行")
#endif
    }

    func testOutputAuthorizationPreservesPendingAnchorMediaAndFutureHostTime() throws {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        var anchors: [(CMTime, CMTime, Float)] = []
        let clock = RenderSynchronizerClock(
            synchronizer: synchronizer,
            currentTime: { .zero },
            pause: {},
            anchor: { anchors.append(($0, $1, $2)) },
            hostTime: { .zero }
        )
        let mediaTime = CMTime(value: 10, timescale: 1)
        let futureHostTime = CMTime(value: 500, timescale: 1_000)
        clock.anchor(mediaTime: mediaTime, atHostTime: futureHostTime, rate: 0)
        clock.setRate(1)

        XCTAssertEqual(anchors.count, 2)
        let authorized = try XCTUnwrap(anchors.last)
        XCTAssertEqual(authorized.0, mediaTime)
        XCTAssertEqual(authorized.1, futureHostTime)
        XCTAssertEqual(authorized.2, 1)

        // 后续调速不能重新回到起播锚点。
        clock.setRate(2)
        XCTAssertEqual(anchors.count, 2)
    }

    func testPausingOutputCancelsPendingStartAnchorBeforeNextAuthorization() {
        for useZeroRate in [false, true] {
            let synchronizer = AVSampleBufferRenderSynchronizer()
            var anchors: [(CMTime, CMTime, Float)] = []
            let clock = RenderSynchronizerClock(
                synchronizer: synchronizer,
                currentTime: { .zero },
                pause: {},
                anchor: { anchors.append(($0, $1, $2)) }
            )
            clock.anchor(mediaTime: .zero, atHostTime: .zero, rate: 0)
            if useZeroRate {
                clock.setRate(0)
            } else {
                clock.pause()
            }
            clock.setRate(1)

            XCTAssertEqual(anchors.count, 1)
        }
    }

    func testDelayedOutputAuthorizationReschedulesExpiredStartWithOriginalLead() throws {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        var anchors: [(CMTime, CMTime, Float)] = []
        var hostTime = CMTime.zero
        let clock = RenderSynchronizerClock(
            synchronizer: synchronizer,
            currentTime: { .zero },
            pause: {},
            anchor: { anchors.append(($0, $1, $2)) },
            hostTime: { hostTime }
        )
        clock.anchor(
            mediaTime: CMTime(value: 10, timescale: 1),
            atHostTime: CMTime(value: 500, timescale: 1_000),
            rate: 0
        )
        hostTime = CMTime(value: 1, timescale: 1)
        clock.setRate(1)

        let authorized = try XCTUnwrap(anchors.last)
        XCTAssertEqual(authorized.0, CMTime(value: 10, timescale: 1))
        XCTAssertEqual(authorized.1, CMTime(value: 1_500, timescale: 1_000))
        XCTAssertEqual(authorized.2, 1)
    }

    func test稳态微调每次使用最新媒体和host映射而不复用起播锚点() {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        var media = CMTime(value: 9, timescale: 1)
        var host = CMTime(value: 99, timescale: 1)
        var anchors: [(media: CMTime, host: CMTime, rate: Float)] = []
        let clock = RenderSynchronizerClock(
            synchronizer: synchronizer,
            currentTime: { media },
            pause: {},
            anchor: { anchors.append(($0, $1, $2)) },
            hostTime: { host },
            rateMapping: { .init(media: media, host: host) }
        )
        // 首次仍消费真实pending future start；其媒体/host映射不能被稳态调节复用。
        clock.anchor(mediaTime: CMTime(value: 10, timescale: 1),
                     atHostTime: CMTime(value: 100, timescale: 1), rate: 0)
        clock.setRate(1)
        XCTAssertEqual(anchors.map(\.media), [CMTime(value: 10, timescale: 1), CMTime(value: 10, timescale: 1)])
        XCTAssertEqual(anchors.map(\.host), [CMTime(value: 100, timescale: 1), CMTime(value: 100, timescale: 1)])
        XCTAssertEqual(anchors.map(\.rate), [0, 1])

        media = CMTime(value: 20, timescale: 1)
        host = CMTime(value: 110, timescale: 1)
        clock.setRate(0.999)
        media = CMTime(value: 24_995, timescale: 1_000)
        host = CMTime(value: 115, timescale: 1)
        clock.setRate(1.001)
        // 每次注入新的系统一致映射，不允许复用上一轮或起播映射。
        media = CMTime(value: 30_007, timescale: 1_000)
        host = CMTime(value: 120, timescale: 1)
        clock.setRate(1)

        let steadyChanges = Array(anchors.dropFirst(2))
        XCTAssertEqual(steadyChanges.count, 3)
        XCTAssertEqual(steadyChanges.map(\.media), [
            CMTime(value: 20, timescale: 1),
            CMTime(value: 24_995, timescale: 1_000),
            CMTime(value: 30_007, timescale: 1_000)
        ])
        XCTAssertEqual(steadyChanges.map(\.host), [
            CMTime(value: 110, timescale: 1),
            CMTime(value: 115, timescale: 1),
            CMTime(value: 120, timescale: 1)
        ])
        XCTAssertEqual(steadyChanges.map(\.rate), [0.999, 1.001, 1])
        clock.setRate(1)
        clock.setRate(2)
        clock.setRate(1)
        XCTAssertEqual(anchors.count, 5,
                       "相同速率和非micro速率转换保留原路径，不重复建立稳态映射")
        // 这里只验证SDK调用参数，不证明真实时钟没有相位缺口或声学停顿。
    }

    func test暂停或归零撤销稳态微调使下一次正速率沿原启动路径() {
        for useZeroRate in [false, true] {
            let synchronizer = AVSampleBufferRenderSynchronizer()
            var media = CMTime(value: 9, timescale: 1)
            var host = CMTime(value: 99, timescale: 1)
            var anchors: [(CMTime, CMTime, Float)] = []
            let clock = RenderSynchronizerClock(
                synchronizer: synchronizer,
                currentTime: { media },
                pause: {},
                anchor: { anchors.append(($0, $1, $2)) },
                hostTime: { host },
                rateMapping: { .init(media: media, host: host) }
            )
            clock.anchor(mediaTime: CMTime(value: 10, timescale: 1),
                         atHostTime: CMTime(value: 100, timescale: 1), rate: 0)
            clock.setRate(1)
            media = CMTime(value: 20, timescale: 1)
            host = CMTime(value: 110, timescale: 1)
            clock.setRate(0.999)
            XCTAssertEqual(anchors.count, 3, "取消前必须真正进入稳态micro映射路径")
            let countBeforeCancellation = anchors.count
            if useZeroRate {
                clock.setRate(0)
            } else {
                clock.pause()
            }
            media = CMTime(value: 30, timescale: 1)
            host = CMTime(value: 120, timescale: 1)
            clock.setRate(1)
            XCTAssertEqual(anchors.count, countBeforeCancellation,
                           "0→1不能沿用暂停前的requestedRate或稳态映射")
            synchronizer.rate = 0
        }
    }

    func test一致映射以实际旧倍率投影当前时刻包括读取期间的推进() throws {
        // 旧锚点可以很早；50ms 虚拟抢占发生后，应只投影一次这段时间。
        let mapping = try XCTUnwrap(RenderSynchronizerClock.hostMapping(
            relativeRate: 0.9997,
            mediaAnchor: CMTime(value: 10, timescale: 1),
            hostAnchor: CMTime(value: 100, timescale: 1),
            currentHost: CMTime(value: 1_300_050, timescale: 1_000)
        ))
        XCTAssertEqual(mapping.host, CMTime(value: 1_300_050, timescale: 1_000))
        XCTAssertEqual(mapping.media.seconds, 10 + 1_200.05 * 0.9997, accuracy: 0.000001,
                       "投影使用实际旧倍率；新倍率不能重算旧锚点以来的历史")
    }

    func test一致映射拒绝无效倍率时间和负媒体位置() {
        for rate in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(RenderSynchronizerClock.hostMapping(
                relativeRate: rate, mediaAnchor: .zero, hostAnchor: .zero, currentHost: .zero))
        }
        for invalid in [CMTime.invalid, .indefinite, .positiveInfinity] {
            XCTAssertNil(RenderSynchronizerClock.hostMapping(
                relativeRate: 1, mediaAnchor: invalid, hostAnchor: .zero, currentHost: .zero))
            XCTAssertNil(RenderSynchronizerClock.hostMapping(
                relativeRate: 1, mediaAnchor: .zero, hostAnchor: invalid, currentHost: .zero))
            XCTAssertNil(RenderSynchronizerClock.hostMapping(
                relativeRate: 1, mediaAnchor: .zero, hostAnchor: .zero, currentHost: invalid))
        }
        XCTAssertNil(RenderSynchronizerClock.hostMapping(
            relativeRate: 1, mediaAnchor: .zero, hostAnchor: CMTime(value: 10, timescale: 1),
            currentHost: CMTime(value: 9, timescale: 1)))
        XCTAssertNil(RenderSynchronizerClock.hostMapping(
            relativeRate: 1, mediaAnchor: CMTime(value: 10, timescale: 1), hostAnchor: .zero,
            currentHost: CMTime(value: -1, timescale: 1)))
    }

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

    func testRenderSynchronizerClockOwnsCallerSynchronizerAndUsesInjectedActions() {
        let synchronizer = AVSampleBufferRenderSynchronizer()
        var pauses = 0
        var anchors: [(CMTime, CMTime, Float)] = []
        let subject = RenderSynchronizerClock(
            synchronizer: synchronizer,
            currentTime: { CMTime(value: 11, timescale: 2) },
            pause: { pauses += 1 },
            anchor: { anchors.append(($0, $1, $2)) }
        )

        XCTAssertTrue(subject.synchronizer === synchronizer)
        XCTAssertEqual(subject.currentTime, CMTime(value: 11, timescale: 2))
        subject.pause()
        subject.anchor(
            mediaTime: CMTime(value: 9, timescale: 1),
            atHostTime: CMTime(value: 101, timescale: 1),
            rate: 1
        )

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
        // readiness只准备共同时间锚；正rate由backend的显式activation许可驱动。
        XCTAssertEqual(clock.anchors.first?.rate, 0)
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

    func pause() {
        pauseCount += 1
        order?("pause")
    }

    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float) {
        order?("anchor")
        anchors.append(.init(mediaTime: mediaTime, hostTime: hostTime, rate: rate))
    }

    func setRate(_ rate: Float) {
        // Mock setRate
    }
}

final class PlaybackAudioSupplyClockPolicyTests: XCTestCase {
    func testSlowProducerKeepsAcceptedAudioAheadOfHardwareClockForTwentyMinutes() {
        var policy = PlaybackAudioSupplyClockPolicy()
        let result = simulate(
            SupplyScenario(duration: 1_200, producerPPM: -180),
            policy: &policy
        )

        // 取消全部倍率决策时，虚拟播放末段的批首余量约为 -134ms。
        XCTAssertGreaterThan(result.minimumLead, 0.1,
                             "每次成功接受音频仍必须保住下一批到达前的连续覆盖")
        XCTAssertLessThan(result.maximumLead, 0.65,
                          "补偿应维持有界余量，不能持续以最大减速积累直播延迟")
        assertBoundedDecisions(result, duration: 1_200)
    }

    func testSlowerProducerKeepsAcceptedAudioAheadOfHardwareClockForThirtyMinutes() {
        var policy = PlaybackAudioSupplyClockPolicy()
        let result = simulate(
            SupplyScenario(duration: 1_800, producerPPM: -300),
            policy: &policy
        )

        // 取消全部倍率决策时，虚拟播放末段的批首余量约为 -494ms。
        XCTAssertGreaterThan(result.minimumLead, 0.1,
                             "数百 ppm 的输入偏差不能在长播放中耗尽音频覆盖")
        XCTAssertLessThan(result.maximumLead, 0.65)
        assertBoundedDecisions(result, duration: 1_800)
    }

    func testStableSupplyWithJitterAndSegmentBurstDoesNotChaseEveryAccessUnit() {
        var policy = PlaybackAudioSupplyClockPolicy()
        var scenario = SupplyScenario(duration: 1_200, producerPPM: 0)
        scenario.hardwarePPM = 0
        scenario.jitterAmplitude = 0.012
        scenario.segmentBurst = 120..<125
        let result = simulate(scenario, policy: &policy)

        XCTAssertGreaterThan(result.minimumLead, 0.1)
        XCTAssertGreaterThan(result.finalLead, 0.15)
        XCTAssertLessThan(result.finalLead, 0.45,
                          "五秒突发之后应恢复正常余量，不能误认为永久输入加速")
        assertBoundedDecisions(result, duration: 1_200)
    }

    func testResetDiscardsPreviousTimelinePhaseBeforeNewSupplyObservations() {
        var reusedPolicy = PlaybackAudioSupplyClockPolicy()
        _ = simulate(
            SupplyScenario(duration: 1_200, producerPPM: -300),
            policy: &reusedPolicy
        )
        reusedPolicy.reset()

        var nextScenario = SupplyScenario(duration: 600, producerPPM: 0)
        nextScenario.hardwarePPM = 0
        nextScenario.mediaOrigin = 7
        nextScenario.monotonicOrigin = 5_000
        let afterReset = simulate(nextScenario, policy: &reusedPolicy)
        var freshPolicy = PlaybackAudioSupplyClockPolicy()
        let fresh = simulate(nextScenario, policy: &freshPolicy)

        XCTAssertEqual(afterReset.minimumLead, fresh.minimumLead, accuracy: 0.000_001)
        XCTAssertEqual(afterReset.finalLead, fresh.finalLead, accuracy: 0.000_001)
        XCTAssertEqual(afterReset.decisions.count, fresh.decisions.count,
                       "重置后的新时间线必须与全新策略具有相同的实际调速行为")
        for (reused, new) in zip(afterReset.decisions, fresh.decisions) {
            XCTAssertEqual(reused.elapsed, new.elapsed, accuracy: 0.000_001)
            XCTAssertEqual(reused.multiplier, new.multiplier, accuracy: 0.000_001)
        }
    }

    private struct SupplyScenario {
        let duration: TimeInterval
        let producerPPM: Double
        var hardwarePPM: Double = 60
        var initialLead: TimeInterval = 0.25
        var targetLead: TimeInterval = 0.3
        var mediaOrigin: TimeInterval = 20_000
        var monotonicOrigin: TimeInterval = 1_000
        var jitterAmplitude: TimeInterval = 0
        var segmentBurst: Range<TimeInterval>?
    }

    private struct RateDecision {
        let elapsed: TimeInterval
        let multiplier: Float
    }

    private struct SupplyResult {
        var minimumLead: TimeInterval
        var maximumLead: TimeInterval
        var finalLead: TimeInterval
        var decisions: [RateDecision] = []
    }

    private func simulate(
        _ scenario: SupplyScenario,
        policy: inout PlaybackAudioSupplyClockPolicy
    ) -> SupplyResult {
        // 只替代真实等待及硬件时钟；倍率决策始终来自生产策略。
        // 每批三个相邻 32ms AU，共享相同交付时刻，保留真实输入的批次锯齿。
        let frameDuration = 0.032
        let batchDuration = 0.096
        let producerGain = 1 + scenario.producerPPM / 1_000_000
        let hardwareGain = 1 + scenario.hardwarePPM / 1_000_000
        let batchCount = Int(scenario.duration * producerGain / batchDuration)
        let jitterPattern: [Double] = [-1, -0.5, 0, 0.5, 1, 0.5, 0, -0.5]
        var acceptedEnd = scenario.mediaOrigin + scenario.initialLead
        var clockTime = scenario.mediaOrigin
        var elapsed: TimeInterval = 0
        var multiplier: Float = 1
        var result = SupplyResult(
            minimumLead: scenario.initialLead,
            maximumLead: scenario.initialLead,
            finalLead: scenario.initialLead
        )

        func acceptDecision(_ decision: Float?, at observationTime: TimeInterval) {
            guard let decision else { return }
            multiplier = decision
            result.decisions.append(RateDecision(elapsed: observationTime,
                                                 multiplier: decision))
        }

        acceptDecision(policy.observe(
            acceptedEnd: mediaTime(acceptedEnd),
            clockTime: mediaTime(clockTime),
            monotonicTime: scenario.monotonicOrigin,
            targetLead: mediaTime(scenario.targetLead)
        ), at: 0)

        for batch in 1...batchCount {
            let scheduledArrival = Double(batch) * batchDuration / producerGain
            var arrival = scheduledArrival
                + jitterPattern[batch % jitterPattern.count] * scenario.jitterAmplitude
            if let burst = scenario.segmentBurst, burst.contains(scheduledArrival) {
                // 将这一段媒体提前成一个 HLS 突发，之后等待正常输入继续。
                arrival = burst.lowerBound
            }
            arrival = max(elapsed, arrival)
            clockTime += (arrival - elapsed) * hardwareGain * Double(multiplier)
            elapsed = arrival

            // 检查旧覆盖在下一批到达前是否耗尽，而非仅检查新入队后的余量。
            result.minimumLead = min(result.minimumLead, acceptedEnd - clockTime)
            for _ in 0..<3 {
                acceptedEnd += frameDuration
                acceptDecision(policy.observe(
                    acceptedEnd: mediaTime(acceptedEnd),
                    clockTime: mediaTime(clockTime),
                    monotonicTime: scenario.monotonicOrigin + elapsed,
                    targetLead: mediaTime(scenario.targetLead)
                ), at: elapsed)
            }
            result.maximumLead = max(result.maximumLead, acceptedEnd - clockTime)
        }
        result.finalLead = acceptedEnd - clockTime
        return result
    }

    private func assertBoundedDecisions(
        _ result: SupplyResult,
        duration: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for decision in result.decisions {
            XCTAssertTrue(decision.multiplier.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(decision.multiplier, 0.998 - 0.000_001,
                                       file: file, line: line)
            XCTAssertLessThanOrEqual(decision.multiplier, 1.002 + 0.000_001,
                                    file: file, line: line)
        }
        // 不能把每个 AU 或交付抖动直接转换成调速；也计入重复返回的倍率。
        XCTAssertLessThanOrEqual(result.decisions.count, Int(duration / 2) + 4,
                                "调速决策不应持续追随每个交付批次", file: file, line: line)
        for (previous, current) in zip(result.decisions, result.decisions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(current.elapsed - previous.elapsed, 0.95,
                                        "同批 AU 不能连续触发调速", file: file, line: line)
        }
    }

    private func mediaTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }
}
