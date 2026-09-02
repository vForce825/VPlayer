// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import CryptoKit
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

private struct NativeVideoFrameSnapshot: Equatable {
    let token: Int64
    let abiVersion: UInt32
    let structSize: UInt32
    let width: Int32
    let height: Int32
    let hasLuma: Bool
    let hasChromaB: Bool
    let hasChromaR: Bool
    let lumaStride: Int32
    let chromaBStride: Int32
    let chromaRStride: Int32
    let firstLuma: UInt8?
    let firstChromaB: UInt8?
    let firstChromaR: UInt8?
}

private final class NativeVideoFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NativeVideoFrameSnapshot] = []

    func record(_ frame: VPFFVideoFrame) {
        lock.withLock {
            storage.append(NativeVideoFrameSnapshot(
                token: frame.pts,
                abiVersion: frame.abi_version,
                structSize: frame.struct_size,
                width: frame.width,
                height: frame.height,
                hasLuma: frame.luma != nil,
                hasChromaB: frame.chroma_b != nil,
                hasChromaR: frame.chroma_r != nil,
                lumaStride: frame.luma_stride,
                chromaBStride: frame.chroma_b_stride,
                chromaRStride: frame.chroma_r_stride,
                firstLuma: frame.luma?.pointee,
                firstChromaB: frame.chroma_b?.pointee,
                firstChromaR: frame.chroma_r?.pointee
            ))
        }
    }

    var frames: [NativeVideoFrameSnapshot] { lock.withLock { storage } }
}

private func recordNativeVideoFrame(
    context: UnsafeMutableRawPointer?,
    frame: UnsafePointer<VPFFVideoFrame>?
) {
    guard let context, let frame else { return }
    Unmanaged<NativeVideoFrameRecorder>
        .fromOpaque(context)
        .takeUnretainedValue()
        .record(frame.pointee)
}

private final class CapturedReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (BorrowedFFmpegVideoFrame) -> Void)?

    var receiver: (@Sendable (BorrowedFFmpegVideoFrame) -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class FakeFFmpegVideoDecoderHandle: FFmpegVideoDecoderHandle, @unchecked Sendable {
    private let condition = NSCondition()
    private var pushedTokens: [Int64] = []
    private var storedPushResult = FFmpegVideoPushResult.success
    private var pushHook: (@Sendable (Int64) -> FFmpegVideoPushResult)?
    private var destroyHook: (@Sendable () -> Void)?
    private var blockNextPush = false
    private var blockedPushCanReturn = false
    private var pushInProgress = false
    private var destroyedWhilePushWasInProgress = false
    private var destructionCount = 0

    var pushResult: FFmpegVideoPushResult {
        get { condition.withLock { storedPushResult } }
        set { condition.withLock { storedPushResult = newValue } }
    }

    var tokens: [Int64] { condition.withLock { pushedTokens } }

    var destroyCount: Int { condition.withLock { destructionCount } }

    var hadConcurrentDestroy: Bool {
        condition.withLock { destroyedWhilePushWasInProgress }
    }

    func arrangeBlockedPush() {
        condition.withLock {
            blockNextPush = true
            blockedPushCanReturn = false
        }
    }

    func waitUntilPushStarts(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !pushInProgress {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseBlockedPush() {
        condition.withLock {
            blockedPushCanReturn = true
            condition.broadcast()
        }
    }

    func handlePush(with hook: @escaping @Sendable (Int64) -> FFmpegVideoPushResult) {
        condition.withLock { pushHook = hook }
    }

    func handleDestroy(with hook: @escaping @Sendable () -> Void) {
        condition.withLock { destroyHook = hook }
    }

    func push(_ bytes: UnsafeRawBufferPointer, token: Int64) -> FFmpegVideoPushResult {
        condition.lock()
        pushedTokens.append(token)
        if blockNextPush {
            blockNextPush = false
            pushInProgress = true
            condition.broadcast()
            while !blockedPushCanReturn { condition.wait() }
            pushInProgress = false
        }
        let result = storedPushResult
        let hook = pushHook
        condition.unlock()
        return hook?(token) ?? result
    }

    func flush() {}
    func destroy() {
        let hook = condition.withLock {
            destructionCount += 1
            destroyedWhilePushWasInProgress =
                destroyedWhilePushWasInProgress || pushInProgress
            return destroyHook
        }
        hook?()
    }
}

private struct FakeFFmpegVideoDecoderAPI: FFmpegVideoDecoderAPI {
    let captured: CapturedReceiver
    let handle: FakeFFmpegVideoDecoderHandle

    func create(
        extradata: Data,
        threadCount: Int32,
        receiver: @escaping @Sendable (BorrowedFFmpegVideoFrame) -> Void
    ) throws -> any FFmpegVideoDecoderHandle {
        captured.receiver = receiver
        return handle
    }
}

private func deliverTestFrame(
    token: Int64,
    to receiver: (@Sendable (BorrowedFFmpegVideoFrame) -> Void)?
) {
    var pixels = [UInt8](repeating: 0, count: 16 * 8 * 2)
    pixels.withUnsafeMutableBufferPointer { buffer in
        receiver?(BorrowedFFmpegVideoFrame(
            luma: UnsafePointer(buffer.baseAddress),
            chromaB: UnsafePointer(buffer.baseAddress),
            chromaR: UnsafePointer(buffer.baseAddress),
            lumaStride: 16,
            chromaBStride: 8,
            chromaRStride: 8,
            width: 16,
            height: 8,
            token: token,
            isInterlaced: true,
            topFieldFirst: true,
            range: .video,
            abiVersion: VPFF_VIDEO_DECODER_ABI_VERSION,
            structSize: UInt32(MemoryLayout<VPFFVideoFrame>.size)
        ))
    }
}

final class FFmpegVideoDecoderTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 2)

    func testFFmpegConfigureTransitionReturnsWhileNativeQueueIsBlocked() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.transition")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.transition.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let queueBlocked = expectation(description: "native submission queue blocked")
        let transitionReturned = expectation(description: "transition call returned")
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        queue.async {
            queueBlocked.fulfill()
            releaseQueue.wait()
        }
        wait(for: [queueBlocked], timeout: 2)

        let token = VideoDecoderTransitionToken()
        let format = try makeFormat(fieldCount: 2)
        let targetGeneration = generation
        executor.submit {
            decoder.transition(.configure(
                token: token,
                format: format,
                generation: targetGeneration
            ))
            transitionReturned.fulfill()
        }
        wait(for: [transitionReturned], timeout: 2)
        XCTAssertTrue(events.events.isEmpty)

        releaseQueue.signal()
        queue.sync {}
        drain(executor)

        XCTAssertEqual(events.events, [
            .transition(token: token, outcome: .completed),
        ])
    }

    func testFFmpegDrainAndInvalidateReturnsWhileQueueBlockedThenFlushesAndDestroys() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.drain")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.drain.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        decoder.transition(.configure(
            token: VideoDecoderTransitionToken(),
            format: try makeFormat(fieldCount: 2),
            generation: generation
        ))
        queue.sync {}
        drain(executor)

        let queueBlocked = expectation(description: "native submission queue blocked")
        let transitionReturned = expectation(description: "drain transition returned")
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        queue.async {
            queueBlocked.fulfill()
            releaseQueue.wait()
        }
        wait(for: [queueBlocked], timeout: 2)

        let token = VideoDecoderTransitionToken()
        executor.submit {
            decoder.transition(.drainAndInvalidate(token: token))
            transitionReturned.fulfill()
        }
        wait(for: [transitionReturned], timeout: 2)
        XCTAssertEqual(handle.tokens, [])
        XCTAssertEqual(handle.destroyCount, 0)

        releaseQueue.signal()
        queue.sync {}
        drain(executor)

        XCTAssertEqual(handle.tokens, [0])
        XCTAssertEqual(handle.destroyCount, 1)
        XCTAssertEqual(events.events.filter {
            if case let .transition(eventToken, _) = $0 { return eventToken == token }
            return false
        }, [
            .transition(token: token, outcome: .completed),
        ])
    }

    func testFFmpegCompletionIsProducedOnlyWhenPushEntersAUsableFrame() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.disposition")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.disposition.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let configurationToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: configurationToken,
            format: try makeFormat(fieldCount: 2),
            generation: generation
        ))
        queue.sync {}
        drain(executor)

        handle.handlePush { token in
            if handle.tokens.count == 1 {
                deliverTestFrame(token: token, to: captured.receiver)
            }
            return .success
        }
        try decoder.decode(makeAccessUnit(id: 17), flags: [])
        try decoder.decode(makeAccessUnit(id: 18), flags: [])
        queue.sync {}
        drain(executor)

        let identity = VideoDecoderEventIdentity(
            generation: generation,
            transitionToken: configurationToken
        )
        XCTAssertEqual(events.events, [
            .transition(token: configurationToken, outcome: .completed),
            .frame(accessUnitID: 17, identity: identity),
            .completed(accessUnitID: 17, identity: identity, disposition: .produced),
            .completed(accessUnitID: 18, identity: identity, disposition: .noFrame),
        ])
    }

    func testFFmpegPushFailureCompletesNoFrameEvenAfterSynchronousOutput() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.failure-disposition")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.failure-disposition.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let configurationToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: configurationToken,
            format: try makeFormat(fieldCount: 2),
            generation: generation
        ))
        queue.sync {}
        drain(executor)
        handle.handlePush { token in
            deliverTestFrame(token: token, to: captured.receiver)
            return FFmpegVideoPushResult(status: -123, failureToken: token)
        }

        try decoder.decode(makeAccessUnit(id: 19), flags: [])
        queue.sync {}
        drain(executor)

        let identity = VideoDecoderEventIdentity(
            generation: generation,
            transitionToken: configurationToken
        )
        XCTAssertEqual(events.events, [
            .transition(token: configurationToken, outcome: .completed),
            .frame(accessUnitID: 19, identity: identity),
            .submissionFailure(.badData(-123), identity: identity),
            .completed(accessUnitID: 19, identity: identity, disposition: .noFrame),
        ])
    }

    func testFFmpegPushFailureAfterConcurrentTransitionCompletesCancelledExactlyOnce() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.failure-transition")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.failure-transition.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let configurationToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: configurationToken,
            format: try makeFormat(fieldCount: 2),
            generation: generation
        ))
        queue.sync {}
        drain(executor)

        handle.pushResult = FFmpegVideoPushResult(status: -123, failureToken: nil)
        handle.arrangeBlockedPush()
        try decoder.decode(makeAccessUnit(id: 20), flags: [])
        XCTAssertTrue(handle.waitUntilPushStarts(timeout: 2))

        let invalidationToken = VideoDecoderTransitionToken()
        decoder.transition(.invalidate(token: invalidationToken))
        handle.releaseBlockedPush()
        queue.sync {}
        drain(executor)

        let identity = VideoDecoderEventIdentity(
            generation: generation,
            transitionToken: configurationToken
        )
        XCTAssertEqual(events.events, [
            .transition(token: configurationToken, outcome: .completed),
            .completed(accessUnitID: 20, identity: identity, disposition: .cancelled),
            .transition(token: invalidationToken, outcome: .completed),
        ])
    }

    func testFFmpegReorderedOldAUFrameMakesTheCurrentPushProduced() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.reordered")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.reordered.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let configurationToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: configurationToken,
            format: try makeFormat(fieldCount: 2),
            generation: generation
        ))
        queue.sync {}
        drain(executor)
        handle.handlePush { _ in
            let tokens = handle.tokens
            if tokens.count == 2 {
                deliverTestFrame(token: tokens[0], to: captured.receiver)
            }
            return .success
        }

        try decoder.decode(makeAccessUnit(id: 21), flags: [])
        try decoder.decode(makeAccessUnit(id: 22), flags: [])
        queue.sync {}
        drain(executor)

        let identity = VideoDecoderEventIdentity(
            generation: generation,
            transitionToken: configurationToken
        )
        XCTAssertEqual(events.events, [
            .transition(token: configurationToken, outcome: .completed),
            .completed(accessUnitID: 21, identity: identity, disposition: .noFrame),
            .frame(accessUnitID: 21, identity: identity),
            .completed(accessUnitID: 22, identity: identity, disposition: .produced),
        ])
    }

    func testLegalYUV420PFixtureIsDeterministicAndDeliveredByLiveBridge() throws {
        let bytes = try fixture(named: "h264-yuv420p-one-frame.h264")
        XCTAssertEqual(bytes.count, 56)
        XCTAssertEqual(
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "0a8085c35f8aff2549edcfc89ffb692519928ab70f8bb45895e736347f342367"
        )

        let recorder = NativeVideoFrameRecorder()
        let decoder = try makeNativeDecoder(threadCount: 1, recorder: recorder)
        defer { vp_ffmpeg_video_decoder_destroy(decoder) }

        var failureToken: Int64 = 99
        var hasFailureToken: UInt8 = 99
        let pushStatus = bytes.withUnsafeBytes { raw in
            vp_ffmpeg_video_decoder_push(
                decoder,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                100,
                &failureToken,
                &hasFailureToken
            )
        }
        XCTAssertEqual(pushStatus, 0)
        XCTAssertEqual(failureToken, 0)
        XCTAssertEqual(hasFailureToken, 0)

        failureToken = 99
        hasFailureToken = 99
        let drainStatus = vp_ffmpeg_video_decoder_push(
            decoder, nil, 0, 0, &failureToken, &hasFailureToken
        )
        XCTAssertEqual(drainStatus, 0)
        XCTAssertEqual(failureToken, 0)
        XCTAssertEqual(hasFailureToken, 0)
        XCTAssertEqual(recorder.frames.count, 1)
        let frame = try XCTUnwrap(recorder.frames.first)
        XCTAssertEqual(frame.token, 100)
        XCTAssertEqual(frame.abiVersion, VPFF_VIDEO_DECODER_ABI_VERSION)
        XCTAssertEqual(frame.structSize, UInt32(MemoryLayout<VPFFVideoFrame>.size))
        XCTAssertEqual(frame.width, 16)
        XCTAssertEqual(frame.height, 16)
        XCTAssertTrue(frame.hasLuma)
        XCTAssertTrue(frame.hasChromaB)
        XCTAssertTrue(frame.hasChromaR)
        XCTAssertGreaterThanOrEqual(frame.lumaStride, 16)
        XCTAssertGreaterThanOrEqual(frame.chromaBStride, 8)
        XCTAssertGreaterThanOrEqual(frame.chromaRStride, 8)
        XCTAssertEqual(frame.firstLuma, 81)
        XCTAssertEqual(frame.firstChromaB, 90)
        XCTAssertEqual(frame.firstChromaR, 240)
    }

    func testThreadedDrainDeliversLegalFrameBeforeReportingLaterHigh10Token() throws {
        let legal = try fixture(named: "h264-yuv420p-one-frame.h264")
        let high10 = try fixture(named: "h264-high10-one-frame.h264")
        let recorder = NativeVideoFrameRecorder()
        let decoder = try makeNativeDecoder(threadCount: 3, recorder: recorder)
        defer { vp_ffmpeg_video_decoder_destroy(decoder) }

        var failureToken: Int64 = 0
        var hasFailureToken: UInt8 = 0
        let legalStatus = legal.withUnsafeBytes { raw in
            vp_ffmpeg_video_decoder_push(
                decoder,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                100,
                &failureToken,
                &hasFailureToken
            )
        }
        XCTAssertEqual(legalStatus, 0)
        XCTAssertEqual(failureToken, 0)
        XCTAssertEqual(hasFailureToken, 0)

        let high10Status = high10.withUnsafeBytes { raw in
            vp_ffmpeg_video_decoder_push(
                decoder,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                200,
                &failureToken,
                &hasFailureToken
            )
        }
        XCTAssertEqual(high10Status, 0)
        XCTAssertEqual(failureToken, 0)
        XCTAssertEqual(hasFailureToken, 0)

        let drainStatus = vp_ffmpeg_video_decoder_push(
            decoder, nil, 0, 0, &failureToken, &hasFailureToken
        )
        XCTAssertEqual(drainStatus, Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT))
        XCTAssertEqual(failureToken, 200)
        XCTAssertEqual(hasFailureToken, 1)
        XCTAssertEqual(recorder.frames.map(\.token), [100])
    }

    func testRawHigh10FailureTokensRequireAPositivePTS() throws {
        let high10 = try fixture(named: "h264-high10-one-frame.h264")
        for (token, expectedToken) in [
            (Int64(41), Int64(41)),
            (Int64(0), nil),
            (Int64(-7), nil),
            (Int64.min, nil),
        ] {
            let recorder = NativeVideoFrameRecorder()
            let decoder = try makeNativeDecoder(threadCount: 1, recorder: recorder)
            defer { vp_ffmpeg_video_decoder_destroy(decoder) }

            var failureToken: Int64 = 99
            var hasFailureToken: UInt8 = 99
            var status = high10.withUnsafeBytes { raw in
                vp_ffmpeg_video_decoder_push(
                    decoder,
                    raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    raw.count,
                    token,
                    &failureToken,
                    &hasFailureToken
                )
            }
            if status == 0 {
                status = vp_ffmpeg_video_decoder_push(
                    decoder, nil, 0, 0, &failureToken, &hasFailureToken
                )
            }

            XCTAssertEqual(
                status,
                Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                "token \(token)"
            )
            XCTAssertEqual(hasFailureToken, expectedToken == nil ? 0 : 1, "token \(token)")
            XCTAssertEqual(failureToken, expectedToken ?? 0, "token \(token)")
            XCTAssertTrue(recorder.frames.isEmpty, "token \(token)")
        }
    }

    func testLiveSwiftAdapterRetainsOnlyPositiveNativeFailureTokens() throws {
        let high10 = try fixture(named: "h264-high10-one-frame.h264")
        for (token, expectedToken) in [
            (Int64(41), Int64(41)),
            (Int64(0), nil),
            (Int64.min, nil),
        ] {
            let handle = try LiveFFmpegVideoDecoderAPI().create(
                extradata: Data(),
                threadCount: 1,
                receiver: { _ in XCTFail("High10 must not reach the Swift callback") }
            )
            defer { handle.destroy() }

            var result = high10.withUnsafeBytes { handle.push($0, token: token) }
            if result.status == 0 {
                result = Data().withUnsafeBytes { handle.push($0, token: 0) }
            }
            XCTAssertEqual(
                result,
                FFmpegVideoPushResult(
                    status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                    failureToken: expectedToken
                ),
                "token \(token)"
            )
        }
    }

    func testLiveSwiftAdapterNormalizesNativeFailureTokenSentinels() {
        for (token, hasFailureToken, expectedToken) in [
            (Int64(41), UInt8(1), Int64(41)),
            (Int64(0), UInt8(1), nil),
            (Int64.min, UInt8(1), nil),
            (Int64(41), UInt8(0), nil),
        ] as [(Int64, UInt8, Int64?)] {
            XCTAssertEqual(
                FFmpegVideoPushResult.liveBridge(
                    status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                    failureToken: token,
                    hasFailureToken: hasFailureToken
                ),
                FFmpegVideoPushResult(
                    status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                    failureToken: expectedToken
                )
            )
        }
    }

    func testNilFailureTokenOutputIsRejectedWithoutConsumingInput() throws {
        let bytes = try fixture(named: "h264-yuv420p-one-frame.h264")
        let recorder = NativeVideoFrameRecorder()
        let decoder = try makeNativeDecoder(threadCount: 1, recorder: recorder)
        defer { vp_ffmpeg_video_decoder_destroy(decoder) }
        var hasFailureToken: UInt8 = 99

        let invalidStatus = bytes.withUnsafeBytes { raw in
            vp_ffmpeg_video_decoder_push(
                decoder,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                301,
                nil,
                &hasFailureToken
            )
        }
        XCTAssertEqual(invalidStatus, -22)
        XCTAssertEqual(hasFailureToken, 0)
        XCTAssertTrue(recorder.frames.isEmpty)

        try assertLegalFixtureIsStillConsumed(
            bytes, decoder: decoder, recorder: recorder, token: 302
        )
    }

    func testNilHasFailureTokenOutputIsRejectedWithoutConsumingInput() throws {
        let bytes = try fixture(named: "h264-yuv420p-one-frame.h264")
        let recorder = NativeVideoFrameRecorder()
        let decoder = try makeNativeDecoder(threadCount: 1, recorder: recorder)
        defer { vp_ffmpeg_video_decoder_destroy(decoder) }
        var failureToken: Int64 = 99

        let invalidStatus = bytes.withUnsafeBytes { raw in
            vp_ffmpeg_video_decoder_push(
                decoder,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                303,
                &failureToken,
                nil
            )
        }
        XCTAssertEqual(invalidStatus, -22)
        XCTAssertEqual(failureToken, 0)
        XCTAssertTrue(recorder.frames.isEmpty)

        try assertLegalFixtureIsStillConsumed(
            bytes, decoder: decoder, recorder: recorder, token: 304
        )
    }

    func testNilDecoderZerosBothFailureOutputsBeforeReturningInvalidArgument() {
        var failureToken: Int64 = 99
        var hasFailureToken: UInt8 = 99

        XCTAssertEqual(
            vp_ffmpeg_video_decoder_push(
                nil, nil, 0, 0, &failureToken, &hasFailureToken
            ),
            -22
        )
        XCTAssertEqual(failureToken, 0)
        XCTAssertEqual(hasFailureToken, 0)
    }

    func testLiveBridgeReportsHigh10AsUnsupportedWithDecodedToken() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "h264-high10-one-frame.h264",
            withExtension: nil,
            subdirectory: "Video"
        ))
        let bytes = try Data(contentsOf: fixture)
        var decoder: OpaquePointer?
        let status = vp_ffmpeg_video_decoder_create(nil, 0, 1, { _, _ in
            XCTFail("High10 must not be delivered as YUV420P")
        }, nil, &decoder)
        XCTAssertEqual(status, 0)
        let owned = try XCTUnwrap(decoder)
        defer { vp_ffmpeg_video_decoder_destroy(owned) }

        var failureToken: Int64 = 0
        var hasFailureToken: UInt8 = 0
        var pushStatus = bytes.withUnsafeBytes { raw in
            vp_ffmpeg_video_decoder_push(
                owned,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                41,
                &failureToken,
                &hasFailureToken
            )
        }
        if pushStatus == 0 {
            pushStatus = vp_ffmpeg_video_decoder_push(
                owned, nil, 0, 0, &failureToken, &hasFailureToken
            )
        }

        XCTAssertEqual(pushStatus, Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT))
        XCTAssertEqual(hasFailureToken, 1)
        XCTAssertEqual(failureToken, 41)

        XCTAssertEqual(
            vp_ffmpeg_video_decoder_push(owned, nil, 0, 0, nil, &hasFailureToken),
            -22
        )
    }

    // Field-coded H.264 is the one case with no hardware path, and the only one
    // worth paying software decoding for.
    func testOnlyFieldCodedH264PrefersFFmpeg() throws {
        XCTAssertTrue(RoutingVideoDecoder.prefersFFmpeg(for: try makeFormat(fieldCount: 2)))
        XCTAssertFalse(RoutingVideoDecoder.prefersFFmpeg(for: try makeFormat(fieldCount: 1)))
        XCTAssertFalse(RoutingVideoDecoder.prefersFFmpeg(for: try makeFormat(fieldCount: nil)))
    }

    func testSuccessfulPushCompletesSubmissionBeforeAnyFrameIsRequired() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.completion")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.completion.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        try decoder.decode(makeAccessUnit(id: 17), flags: [])
        queue.sync {}
        drain(executor)

        XCTAssertEqual(handle.tokens.count, 1)
        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 17, generation: generation),
        ])
    }

    func testFailedPushReportsFailureThenCompletesExactlyOnce() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        handle.pushResult = FFmpegVideoPushResult(status: -123, failureToken: nil)
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.failure")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.failure.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        try decoder.decode(makeAccessUnit(id: 19), flags: [])
        queue.sync {}
        drain(executor)

        XCTAssertEqual(events.events, [
            .submissionFailure(.badData(-123), generation: generation),
            .completed(accessUnitID: 19, generation: generation),
        ])
    }

    func testUnsupportedPushRetiresSessionBeforeQueuedUnitAndCompletesInOrder() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.unsupported")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.unsupported.submit")
        let events = FFmpegEventRecorder()
        let trace = LockedStringTrace()
        handle.handleDestroy { trace.record("destroy") }
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { event in
                events.record(event)
                switch event {
                case .submissionFailure:
                    trace.record("failure")
                case let .submissionCompleted(accessUnitID, _, _):
                    trace.record("complete.\(accessUnitID)")
                case .frame, .recoverableFailure, .fatalFailure, .transitionCompleted:
                    break
                }
            },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue,
            submissionStartSink: { trace.record("begin.\($0)") }
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        handle.arrangeBlockedPush()
        try decoder.decode(makeAccessUnit(id: 101), flags: [])
        XCTAssertTrue(handle.waitUntilPushStarts(timeout: 2))
        let firstToken = try XCTUnwrap(handle.tokens.first)
        handle.pushResult = FFmpegVideoPushResult(
            status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
            failureToken: firstToken
        )
        try decoder.decode(makeAccessUnit(id: 102), flags: [])
        handle.releaseBlockedPush()
        queue.sync {}
        drain(executor)

        XCTAssertEqual(handle.tokens, [firstToken])
        XCTAssertEqual(handle.destroyCount, 1)
        XCTAssertEqual(events.events, [
            .submissionFailure(
                .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                generation: generation
            ),
            .completed(accessUnitID: 101, generation: generation),
            .completed(accessUnitID: 102, generation: generation),
        ])
        let traceValues = trace.values
        XCTAssertLessThan(
            try XCTUnwrap(traceValues.firstIndex(of: "destroy")),
            try XCTUnwrap(traceValues.firstIndex(of: "begin.102"))
        )
        XCTAssertEqual(traceValues.filter { !$0.hasPrefix("begin.") }, [
            "destroy",
            "failure",
            "complete.101",
            "complete.102",
        ])
    }

    func testFailureWithoutTokenRetiresEpochAndDropsLaterCallback() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        handle.pushResult = FFmpegVideoPushResult(
            status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
            failureToken: nil
        )
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.tokenless")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.tokenless.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        try decoder.decode(makeAccessUnit(id: 111), flags: [])
        queue.sync {}
        let failedToken = try XCTUnwrap(handle.tokens.first)
        deliverTestFrame(token: failedToken, to: captured.receiver)
        try decoder.decode(makeAccessUnit(id: 112), flags: [])
        queue.sync {}
        drain(executor)

        XCTAssertEqual(handle.tokens, [failedToken])
        XCTAssertEqual(handle.destroyCount, 1)
        XCTAssertEqual(events.events, [
            .submissionFailure(
                .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                generation: generation
            ),
            .completed(accessUnitID: 111, generation: generation),
            .completed(accessUnitID: 112, generation: generation),
        ])
    }

    func testSynchronousFrameBeforeUnsupportedResultKeepsExactTokenOwnership() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.sync-frame")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.sync-frame.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        let releaseQueue = DispatchSemaphore(value: 0)
        queue.async { releaseQueue.wait() }
        handle.handlePush { token in
            let tokens = handle.tokens
            guard tokens.count == 2, token == tokens[1] else { return .success }
            deliverTestFrame(token: tokens[0], to: captured.receiver)
            return FFmpegVideoPushResult(
                status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                failureToken: tokens[1]
            )
        }
        try decoder.decode(makeAccessUnit(id: 121), flags: [])
        try decoder.decode(makeAccessUnit(id: 122), flags: [])
        releaseQueue.signal()
        queue.sync {}
        releaseExecutor.signal()
        drain(executor)

        let tokens = handle.tokens
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(Set(tokens).count, 2)
        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 121, generation: generation),
            .frame(accessUnitID: 121),
            .submissionFailure(
                .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                generation: generation
            ),
            .completed(accessUnitID: 122, generation: generation),
        ])

        deliverTestFrame(token: tokens[0], to: captured.receiver)
        deliverTestFrame(token: tokens[1], to: captured.receiver)
        drain(executor)
        XCTAssertEqual(events.events.filter {
            if case .frame = $0 { return true }
            return false
        }, [.frame(accessUnitID: 121)])
    }

    func testFailureWithoutTokenDoesNotPermitAlreadyClaimedFrame() throws {
        XCTAssertEqual(
            try eventsAfterOrdinaryFailure { _ in nil },
            ordinaryFailureEventsWithoutFrame
        )
    }

    func testFailureWithUnknownTokenDoesNotPermitAlreadyClaimedFrame() throws {
        XCTAssertEqual(
            try eventsAfterOrdinaryFailure { _ in 999_999 },
            ordinaryFailureEventsWithoutFrame
        )
    }

    func testFailureNamingAlreadyClaimedTokenPermitsOnlyItsExactFrame() throws {
        XCTAssertEqual(
            try eventsAfterOrdinaryFailure { $0[0] },
            [
                .completed(accessUnitID: 201, generation: generation),
                .frame(accessUnitID: 201),
                .submissionFailure(
                    .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                    generation: generation
                ),
                .completed(accessUnitID: 202, generation: generation),
            ]
        )
    }

    func testFailureNamingOldEpochTokenDoesNotPermitCurrentClaimedFrame() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.old-token")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.old-token.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let format = try makeFormat(fieldCount: 2)
        try configure(decoder, format: format, queue: queue, executor: executor)
        try decoder.decode(makeAccessUnit(id: 160), flags: [])
        queue.sync {}
        drain(executor)
        let oldToken = try XCTUnwrap(handle.tokens.first)

        try configure(decoder, format: format, queue: queue, executor: executor)
        try decoder.decode(makeAccessUnit(id: 161), flags: [])
        queue.sync {}
        drain(executor)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        handle.handlePush { token in
            let tokens = handle.tokens
            guard tokens.count == 3, token == tokens[2] else { return .success }
            deliverTestFrame(token: tokens[1], to: captured.receiver)
            return FFmpegVideoPushResult(
                status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                failureToken: oldToken
            )
        }
        try decoder.decode(makeAccessUnit(id: 162), flags: [])
        queue.sync {}
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 160, generation: generation),
            .completed(accessUnitID: 161, generation: generation),
            .submissionFailure(
                .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                generation: generation
            ),
            .completed(accessUnitID: 162, generation: generation),
        ])
    }

    func testDrainFailureWithMatchingOldTokenFencesClaimedFrameAtTransition() throws {
        try assertDrainFailureFencesClaimedFrame { $0[1] }
    }

    func testDrainFailureWithoutTokenFencesClaimedFrameAtTransition() throws {
        try assertDrainFailureFencesClaimedFrame { _ in nil }
    }

    func testClaimedFrameIsCancelledBySameGenerationReconfigure() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.claim.configure")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.claim.configure.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let format = try makeFormat(fieldCount: 2)
        try configure(decoder, format: format, queue: queue, executor: executor)
        let oldReceiver = try XCTUnwrap(captured.receiver)
        try decoder.decode(makeAccessUnit(id: 141), flags: [])
        queue.sync {}
        drain(executor)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        deliverTestFrame(token: try XCTUnwrap(handle.tokens.first), to: oldReceiver)
        enqueueConfigure(decoder, format: format, queue: queue)
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 141, generation: generation),
        ])
    }

    func testClaimedFrameIsCancelledByInvalidate() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.claim.invalidate")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.claim.invalidate.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)
        let oldReceiver = try XCTUnwrap(captured.receiver)
        try decoder.decode(makeAccessUnit(id: 142), flags: [])
        queue.sync {}
        drain(executor)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        deliverTestFrame(token: try XCTUnwrap(handle.tokens.first), to: oldReceiver)
        enqueueInvalidate(decoder, queue: queue)
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 142, generation: generation),
        ])
    }

    func testReconfigureAfterNativeFailureCancelsPermittedClaimedFrame() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.permit.configure")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.permit.configure.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        let format = try makeFormat(fieldCount: 2)
        try configure(decoder, format: format, queue: queue, executor: executor)

        try decoder.decode(makeAccessUnit(id: 150), flags: [])
        queue.sync {}
        drain(executor)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        handle.handlePush { token in
            let tokens = handle.tokens
            guard tokens.count == 2, token == tokens[1] else { return .success }
            deliverTestFrame(token: tokens[0], to: captured.receiver)
            return FFmpegVideoPushResult(
                status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                failureToken: tokens[1]
            )
        }
        try decoder.decode(makeAccessUnit(id: 151), flags: [])
        queue.sync {}
        enqueueConfigure(decoder, format: format, queue: queue)
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 150, generation: generation),
            .submissionFailure(
                .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                generation: generation
            ),
            .completed(accessUnitID: 151, generation: generation),
        ])
    }

    func testInvalidateAfterNativeFailureCancelsPermittedClaimedFrame() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.permit.invalidate")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.permit.invalidate.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        try decoder.decode(makeAccessUnit(id: 151), flags: [])
        queue.sync {}
        drain(executor)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        handle.handlePush { token in
            let tokens = handle.tokens
            guard tokens.count == 2, token == tokens[1] else { return .success }
            deliverTestFrame(token: tokens[0], to: captured.receiver)
            return FFmpegVideoPushResult(
                status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                failureToken: tokens[1]
            )
        }
        try decoder.decode(makeAccessUnit(id: 152), flags: [])
        queue.sync {}
        enqueueInvalidate(decoder, queue: queue)
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 151, generation: generation),
            .submissionFailure(
                .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                generation: generation
            ),
            .completed(accessUnitID: 152, generation: generation),
        ])
    }

    func testSixtyFifthPendingUnitRetiresSessionWithoutNativePush() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.capacity")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.capacity.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        let releaseQueue = DispatchSemaphore(value: 0)
        queue.async { releaseQueue.wait() }
        for id in UInt64(1)...65 {
            try decoder.decode(makeAccessUnit(id: id), flags: [])
        }
        releaseQueue.signal()
        queue.sync {}
        drain(executor)

        XCTAssertTrue(handle.tokens.isEmpty)
        XCTAssertEqual(handle.destroyCount, 1)
        let failures = events.events.filter {
            if case .submissionFailure = $0 { return true }
            return false
        }
        let capacityFailure = RecordedFFmpegDecoderEvent.submissionFailure(
            .backpressureTimeout,
            generation: generation
        )
        XCTAssertEqual(failures, [capacityFailure])
        let completionIDs = events.events.compactMap { event -> UInt64? in
            guard case let .completed(accessUnitID, _) = event else { return nil }
            return accessUnitID
        }
        XCTAssertEqual(completionIDs.count, 65)
        XCTAssertEqual(Set(completionIDs), Set(UInt64(1)...65))
        XCTAssertLessThan(
            try XCTUnwrap(events.events.firstIndex(of: capacityFailure)),
            try XCTUnwrap(events.events.firstIndex(of: .completed(
                accessUnitID: 65,
                generation: generation
            )))
        )

        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)
        try decoder.decode(makeAccessUnit(id: 66), flags: [])
        queue.sync {}
        drain(executor)

        XCTAssertEqual(handle.tokens, [65])
        XCTAssertEqual(events.events.filter {
            $0 == .completed(accessUnitID: 66, generation: generation)
        }, [
            .completed(accessUnitID: 66, generation: generation),
        ])
    }

    func testCapacityRetirementFencesAClaimedFrameFromTheRetiredEpoch() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.capacity-fence")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.capacity-fence.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        let claimedID = UInt64(301)
        try decoder.decode(makeAccessUnit(id: claimedID), flags: [])
        queue.sync {}
        drain(executor)
        let claimedToken = try XCTUnwrap(handle.tokens.first)

        let releaseExecutor = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        defer {
            releaseQueue.signal()
            releaseExecutor.signal()
        }
        executor.submit { releaseExecutor.wait() }
        deliverTestFrame(token: claimedToken, to: captured.receiver)

        queue.async { releaseQueue.wait() }
        let acceptedIDs = Array(UInt64(302)...365)
        for id in acceptedIDs {
            try decoder.decode(makeAccessUnit(id: id), flags: [])
        }
        let triggerID = UInt64(366)
        try decoder.decode(makeAccessUnit(id: triggerID), flags: [])

        releaseQueue.signal()
        queue.sync {}
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(handle.tokens, [claimedToken])
        XCTAssertEqual(handle.destroyCount, 1)
        XCTAssertFalse(events.events.contains(.frame(accessUnitID: claimedID)))

        let capacityFailure = RecordedFFmpegDecoderEvent.submissionFailure(
            .backpressureTimeout,
            generation: generation
        )
        let failures = events.events.filter {
            if case .submissionFailure = $0 { return true }
            return false
        }
        XCTAssertEqual(failures, [capacityFailure])

        let completionIDs = events.events.compactMap { event -> UInt64? in
            guard case let .completed(accessUnitID, _) = event else { return nil }
            return accessUnitID
        }
        let expectedCompletionIDs = [claimedID] + acceptedIDs + [triggerID]
        XCTAssertEqual(completionIDs.count, expectedCompletionIDs.count)
        XCTAssertEqual(Set(completionIDs), Set(expectedCompletionIDs))
        XCTAssertLessThan(
            try XCTUnwrap(events.events.firstIndex(of: capacityFailure)),
            try XCTUnwrap(events.events.firstIndex(of: .completed(
                accessUnitID: triggerID,
                generation: generation
            )))
        )
    }

    func testQueuedUnitFromReplacedSameGenerationSessionOnlyCompletes() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.session-epoch")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.session-epoch.submit")
        let events = FFmpegEventRecorder()
        let transitioned = DispatchSemaphore(value: 0)
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue,
            sessionTransitionSink: { _ in transitioned.signal() }
        )
        let format = try makeFormat(fieldCount: 2)
        try configure(decoder, format: format, queue: queue, executor: executor)
        XCTAssertEqual(transitioned.wait(timeout: .now()), .success)

        let releaseQueue = DispatchSemaphore(value: 0)
        queue.async { releaseQueue.wait() }
        try decoder.decode(makeAccessUnit(id: 23), flags: [])

        // Replacing the decoder without advancing the media generation still
        // starts a new reference chain. The queued old unit must not enter it.
        let replacementToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: replacementToken,
            format: format,
            generation: generation
        ))
        XCTAssertEqual(transitioned.wait(timeout: .now() + 2), .success)
        releaseQueue.signal()
        queue.sync {}
        drain(executor)

        XCTAssertTrue(handle.tokens.isEmpty)
        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 23, generation: generation),
        ])
    }

    func testUnsupportedReconfigureDestroysPreviousSessionAndLeavesNoActiveHandle() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.unsupported-reconfigure")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.unsupported-reconfigure.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(
            decoder,
            format: makeFormat(fieldCount: 2),
            queue: queue,
            executor: executor
        )
        let token = VideoDecoderTransitionToken()

        decoder.transition(.configure(
            token: token,
            format: try makeFormat(
                fieldCount: 2,
                codecType: kCMVideoCodecType_HEVC
            ),
            generation: generation
        ))
        queue.sync {}
        drain(executor)

        XCTAssertEqual(handle.destroyCount, 1)
        XCTAssertTrue(events.events.contains(.transition(
            token: token,
            outcome: .failed(.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr))
        )))
        XCTAssertThrowsError(try decoder.decode(makeAccessUnit(id: 24), flags: [])) { error in
            XCTAssertEqual(error as? VideoDecoderFailure, .sessionCreate(kVTInvalidSessionErr))
        }

        invalidate(decoder, queue: queue, executor: executor)
        XCTAssertEqual(handle.destroyCount, 1, "failed configure must not leave an active handle")
    }

    func testSessionReplacementSerializesDestroyAfterInProgressPush() throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.serial-teardown")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.serial-teardown.submit")
        let events = FFmpegEventRecorder()
        let transitioned = DispatchSemaphore(value: 0)
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue,
            sessionTransitionSink: { _ in transitioned.signal() }
        )
        let format = try makeFormat(fieldCount: 2)
        try configure(decoder, format: format, queue: queue, executor: executor)
        XCTAssertEqual(transitioned.wait(timeout: .now()), .success)

        handle.arrangeBlockedPush()
        try decoder.decode(makeAccessUnit(id: 31), flags: [])
        XCTAssertTrue(handle.waitUntilPushStarts(timeout: 2))

        decoder.transition(.configure(
            token: VideoDecoderTransitionToken(),
            format: format,
            generation: generation
        ))
        XCTAssertEqual(transitioned.wait(timeout: .now() + 2), .success)

        // The epoch changes immediately, but teardown stays behind the active
        // push on the submission queue.
        XCTAssertFalse(handle.hadConcurrentDestroy)

        handle.releaseBlockedPush()
        queue.sync {}
        drain(executor)

        XCTAssertFalse(handle.hadConcurrentDestroy)
        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 31, generation: generation),
        ])
    }

    func testRoutingDecoderRejectsDecodeWhenNoRouteIsConfigured() throws {
        let decoder = RoutingVideoDecoder(
            videoToolbox: FakeVideoDecoder(),
            ffmpeg: FakeVideoDecoder(),
            eventSink: { _ in }
        )

        XCTAssertThrowsError(try decoder.decode(makeAccessUnit(id: 29), flags: [])) { error in
            XCTAssertEqual(
                error as? VideoDecoderFailure,
                .sessionCreate(kVTInvalidSessionErr)
            )
        }
    }

    func testRoutingChildRelayActivatesSelectedRouteWithoutManualReceive() throws {
        let childRelay = RoutingVideoDecoderChildRelay()
        let videoToolbox = FakeVideoDecoder()
        let ffmpeg = FakeVideoDecoder()
        let events = DetailedFFmpegEventRecorder()
        let decoder = RoutingVideoDecoder(
            videoToolbox: videoToolbox,
            ffmpeg: ffmpeg,
            eventSink: { events.record($0) }
        )
        childRelay.install(decoder)
        videoToolbox.setTransitionEventSink(automaticallyCompletes: false) {
            childRelay.receive($0, from: .videoToolbox)
        }
        ffmpeg.setTransitionEventSink(automaticallyCompletes: false) {
            childRelay.receive($0, from: .ffmpeg)
        }

        let token = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: token,
            format: try makeFormat(fieldCount: 1),
            generation: generation
        ))
        videoToolbox.completeTransition(token: token, outcome: .completed)
        try decoder.decode(makeAccessUnit(id: 30), flags: [])

        XCTAssertEqual(videoToolbox.decodedAccessUnitIDs(generation: generation), [30])
        XCTAssertEqual(events.events, [
            .transition(token: token, outcome: .completed),
        ])
    }

    func testRoutingRouteRemainsInactiveUntilMatchingChildTransitionCompletes() throws {
        let videoToolbox = FakeVideoDecoder()
        let ffmpeg = FakeVideoDecoder()
        let events = DetailedFFmpegEventRecorder()
        let decoder = RoutingVideoDecoder(
            videoToolbox: videoToolbox,
            ffmpeg: ffmpeg,
            eventSink: { events.record($0) }
        )
        let token = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: token,
            format: try makeFormat(fieldCount: 1),
            generation: generation
        ))

        XCTAssertEqual(videoToolbox.snapshot(), [
            .transitionConfigure(token, generation),
        ])
        XCTAssertThrowsError(try decoder.decode(makeAccessUnit(id: 30), flags: []))
        XCTAssertTrue(events.events.isEmpty)

        decoder.receive(
            .transitionCompleted(token: token, outcome: .completed),
            from: .videoToolbox
        )

        XCTAssertNoThrow(try decoder.decode(makeAccessUnit(id: 30), flags: []))
        XCTAssertEqual(events.events, [
            .transition(token: token, outcome: .completed),
        ])
    }

    func testRoutingSameGenerationOldRouteDropsMediaButCancelsAcceptedCompletion() throws {
        let videoToolbox = FakeVideoDecoder()
        let ffmpeg = FakeVideoDecoder()
        let events = DetailedFFmpegEventRecorder()
        let decoder = RoutingVideoDecoder(
            videoToolbox: videoToolbox,
            ffmpeg: ffmpeg,
            eventSink: { events.record($0) }
        )
        let videoToolboxToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: videoToolboxToken,
            format: try makeFormat(fieldCount: 1),
            generation: generation
        ))
        decoder.receive(
            .transitionCompleted(token: videoToolboxToken, outcome: .completed),
            from: .videoToolbox
        )

        let ffmpegToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: ffmpegToken,
            format: try makeFormat(fieldCount: 2),
            generation: generation
        ))
        let oldIdentity = VideoDecoderEventIdentity(
            generation: generation,
            transitionToken: videoToolboxToken
        )
        let oldFrame = VideoTestFactories.decodedFrame(
            id: 31,
            pixelBuffer: try VideoTestFactories.pixelBuffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ),
            presentationTimeStamp: CMTime(value: 31, timescale: 25),
            duration: CMTime(value: 1, timescale: 25),
            generation: generation,
            parserMetadata: makeAccessUnit(id: 31).parserMetadata
        )
        decoder.receive(.frame(oldFrame, identity: oldIdentity), from: .videoToolbox)
        decoder.receive(
            .submissionFailure(
                accessUnitID: 31,
                failure: .badData(-31),
                identity: oldIdentity
            ),
            from: .videoToolbox
        )
        decoder.receive(
            .submissionCompleted(
                accessUnitID: 31,
                identity: oldIdentity,
                disposition: .noFrame
            ),
            from: .videoToolbox
        )

        XCTAssertThrowsError(try decoder.decode(makeAccessUnit(id: 32), flags: []))
        decoder.receive(
            .transitionCompleted(token: ffmpegToken, outcome: .completed),
            from: .ffmpeg
        )
        XCTAssertNoThrow(try decoder.decode(makeAccessUnit(id: 32), flags: []))

        XCTAssertEqual(events.events, [
            .transition(token: videoToolboxToken, outcome: .completed),
            .completed(accessUnitID: 31, identity: oldIdentity, disposition: .cancelled),
            .transition(token: ffmpegToken, outcome: .completed),
        ])
        XCTAssertEqual(ffmpeg.snapshot().first, .transitionConfigure(ffmpegToken, generation))
    }

    func testRoutingParserRequiresFFmpegTransitionOnlyAtInterlacedRandomAccess() throws {
        let videoToolbox = FakeVideoDecoder()
        let ffmpeg = FakeVideoDecoder()
        let decoder = RoutingVideoDecoder(
            videoToolbox: videoToolbox,
            ffmpeg: ffmpeg,
            eventSink: { _ in }
        )
        let format = try makeFormat(fieldCount: 1)
        let initialToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: initialToken,
            format: format,
            generation: generation
        ))
        decoder.receive(
            .transitionCompleted(token: initialToken, outcome: .completed),
            from: .videoToolbox
        )

        func accessUnit(
            id: UInt64,
            randomAccess: Bool,
            interlaced: Bool
        ) -> CompressedVideoAccessUnit {
            let base = makeAccessUnit(id: id)
            return CompressedVideoAccessUnit(
                id: id,
                sampleBuffer: base.sampleBuffer,
                generation: base.generation,
                isRandomAccess: randomAccess,
                parserMetadata: VideoParserMetadata(
                    fieldOrder: interlaced ? .tt : .progressive,
                    pictureStructure: .frame,
                    isInterlaced: interlaced,
                    repeatFirstField: false,
                    topFieldFirst: interlaced ? true : nil,
                    sourcePTS90k: nil
                )
            )
        }

        XCTAssertNil(decoder.transitionRequirement(for: accessUnit(
            id: 40,
            randomAccess: false,
            interlaced: true
        )))
        XCTAssertNil(decoder.transitionRequirement(for: accessUnit(
            id: 41,
            randomAccess: true,
            interlaced: false
        )))

        let triggeringRandomAccess = accessUnit(
            id: 42,
            randomAccess: true,
            interlaced: true
        )
        XCTAssertEqual(
            decoder.transitionRequirement(for: triggeringRandomAccess),
            .reconfigure
        )
        let ffmpegToken = VideoDecoderTransitionToken()
        decoder.transition(.configure(
            token: ffmpegToken,
            format: format,
            generation: generation
        ))

        XCTAssertEqual(ffmpeg.snapshot().first, .transitionConfigure(ffmpegToken, generation))
        XCTAssertThrowsError(try decoder.decode(triggeringRandomAccess, flags: []))

        decoder.receive(
            .transitionCompleted(token: ffmpegToken, outcome: .completed),
            from: .ffmpeg
        )
        XCTAssertNoThrow(try decoder.decode(triggeringRandomAccess, flags: []))
        XCTAssertEqual(ffmpeg.snapshot().filter { operation in
            guard case let .decode(id, decodedGeneration, _) = operation else {
                return false
            }
            return id == triggeringRandomAccess.id && decodedGeneration == generation
        }.count, 1)
    }

    func testPlanarChromaIsInterleavedIntoOneBiPlanarSurfaceAtHalfGeometry() throws {
        // Wide enough that the interleave runs its vector body and still leaves
        // a scalar tail: twenty chroma columns is one sixteen-wide block plus four.
        let width = 40
        let height = 8
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.submit")
        let frames = FrameRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { frames.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )

        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)
        try decoder.decode(
            makeAccessUnit(id: 7),
            flags: VTDecodeFrameFlags()
        )
        queue.sync {}
        XCTAssertEqual(handle.tokens.count, 1)

        // Distinct ramps per plane, so an interleave that swapped or dropped one
        // cannot pass by accident. Strides deliberately exceed the width.
        let lumaStride = width + 5
        let chromaStride = width / 2 + 3
        var luma = [UInt8](repeating: 0, count: lumaStride * height)
        var chromaB = [UInt8](repeating: 0, count: chromaStride * (height / 2))
        var chromaR = [UInt8](repeating: 0, count: chromaStride * (height / 2))
        for row in 0..<height {
            for column in 0..<width {
                luma[row * lumaStride + column] = UInt8((row * width + column) % 251)
            }
        }
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                chromaB[row * chromaStride + column] = UInt8(10 + row * 8 + column)
                chromaR[row * chromaStride + column] = UInt8(120 + row * 8 + column)
            }
        }

        let token = try XCTUnwrap(handle.tokens.first)
        luma.withUnsafeBufferPointer { lumaBuffer in
            chromaB.withUnsafeBufferPointer { chromaBBuffer in
                chromaR.withUnsafeBufferPointer { chromaRBuffer in
                    captured.receiver?(BorrowedFFmpegVideoFrame(
                        luma: lumaBuffer.baseAddress,
                        chromaB: chromaBBuffer.baseAddress,
                        chromaR: chromaRBuffer.baseAddress,
                        lumaStride: lumaStride,
                        chromaBStride: chromaStride,
                        chromaRStride: chromaStride,
                        width: width,
                        height: height,
                        token: token,
                        isInterlaced: true,
                        topFieldFirst: true,
                        range: .video,
                        abiVersion: VPFF_VIDEO_DECODER_ABI_VERSION,
                        structSize: UInt32(MemoryLayout<VPFFVideoFrame>.size)
                    ))
                }
            }
        }

        let decoded = try XCTUnwrap(frames.wait(timeout: 2))
        XCTAssertEqual(decoded.accessUnitID, 7)
        XCTAssertEqual(decoded.generation, generation)
        XCTAssertEqual(decoded.parserMetadata.isInterlaced, true)

        let output = decoded.pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(output), width)
        XCTAssertEqual(CVPixelBufferGetHeight(output), height)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(output),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(output), 2)

        XCTAssertEqual(CVPixelBufferLockBaseAddress(output, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let lumaOut = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 0))
            .assumingMemoryBound(to: UInt8.self)
        let lumaOutStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        for row in 0..<height {
            for column in 0..<width {
                XCTAssertEqual(
                    lumaOut[row * lumaOutStride + column],
                    luma[row * lumaStride + column],
                    "luma \(row),\(column)"
                )
            }
        }

        let chromaOut = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 1))
            .assumingMemoryBound(to: UInt8.self)
        let chromaOutStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                XCTAssertEqual(
                    chromaOut[row * chromaOutStride + column * 2],
                    chromaB[row * chromaStride + column],
                    "Cb \(row),\(column)"
                )
                XCTAssertEqual(
                    chromaOut[row * chromaOutStride + column * 2 + 1],
                    chromaR[row * chromaStride + column],
                    "Cr \(row),\(column)"
                )
            }
        }
    }

    // A frame whose token has no pending unit belongs to a torn-down session and
    // must not be published against whatever unit happens to be queued next.
    func testFrameForAnUnknownTokenIsDropped() throws {
        let captured = CapturedReceiver()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.stale")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.stale.submit")
        let frames = FrameRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { frames.record($0) },
            api: FakeFFmpegVideoDecoderAPI(
                captured: captured,
                handle: FakeFFmpegVideoDecoderHandle()
            ),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)

        var pixels = [UInt8](repeating: 0, count: 16 * 8 * 2)
        pixels.withUnsafeMutableBufferPointer { buffer in
            captured.receiver?(BorrowedFFmpegVideoFrame(
                luma: UnsafePointer(buffer.baseAddress),
                chromaB: UnsafePointer(buffer.baseAddress),
                chromaR: UnsafePointer(buffer.baseAddress),
                lumaStride: 16,
                chromaBStride: 8,
                chromaRStride: 8,
                width: 16,
                height: 8,
                token: 999,
                isInterlaced: false,
                topFieldFirst: false,
                range: .video,
                abiVersion: VPFF_VIDEO_DECODER_ABI_VERSION,
                structSize: UInt32(MemoryLayout<VPFFVideoFrame>.size)
            ))
        }

        XCTAssertNil(frames.wait(timeout: 0.3))
    }

    private var ordinaryFailureEventsWithoutFrame: [RecordedFFmpegDecoderEvent] {
        [
            .completed(accessUnitID: 201, generation: generation),
            .submissionFailure(
                .badData(kVTVideoDecoderUnsupportedDataFormatErr),
                generation: generation
            ),
            .completed(accessUnitID: 202, generation: generation),
        ]
    }

    private func eventsAfterOrdinaryFailure(
        failureToken: @escaping @Sendable ([Int64]) -> Int64?
    ) throws -> [RecordedFFmpegDecoderEvent] {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.token-scope")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.token-scope.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)
        try decoder.decode(makeAccessUnit(id: 201), flags: [])
        queue.sync {}
        drain(executor)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        handle.handlePush { token in
            let tokens = handle.tokens
            guard tokens.count == 2, token == tokens[1] else { return .success }
            deliverTestFrame(token: tokens[0], to: captured.receiver)
            return FFmpegVideoPushResult(
                status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                failureToken: failureToken(tokens)
            )
        }
        try decoder.decode(makeAccessUnit(id: 202), flags: [])
        queue.sync {}
        releaseExecutor.signal()
        drain(executor)
        return events.events
    }

    private func assertDrainFailureFencesClaimedFrame(
        failureToken: @escaping @Sendable ([Int64]) -> Int64?
    ) throws {
        let captured = CapturedReceiver()
        let handle = FakeFFmpegVideoDecoderHandle()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.delayed-token")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.delayed-token.submit")
        let events = DetailedFFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try configure(decoder, format: makeFormat(fieldCount: 2), queue: queue, executor: executor)
        try decoder.decode(makeAccessUnit(id: 211), flags: [])
        try decoder.decode(makeAccessUnit(id: 212), flags: [])
        queue.sync {}
        drain(executor)
        let pendingTokens = handle.tokens
        XCTAssertEqual(pendingTokens.count, 2)

        let releaseExecutor = DispatchSemaphore(value: 0)
        executor.submit { releaseExecutor.wait() }
        handle.handlePush { token in
            guard token == 0 else { return .success }
            deliverTestFrame(token: pendingTokens[0], to: captured.receiver)
            return FFmpegVideoPushResult(
                status: Int32(VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT),
                failureToken: failureToken(pendingTokens)
            )
        }
        let transitionToken = VideoDecoderTransitionToken()
        decoder.transition(.drainAndInvalidate(token: transitionToken))
        queue.sync {}
        releaseExecutor.signal()
        drain(executor)

        XCTAssertEqual(events.events.compactMap { event -> UInt64? in
            guard case let .completed(accessUnitID, _, _) = event else { return nil }
            return accessUnitID
        }, [211, 212])
        XCTAssertFalse(events.events.contains { event in
            if case .frame = event { return true }
            return false
        })
        XCTAssertFalse(events.events.contains { event in
            if case .submissionFailure = event { return true }
            return false
        })
        XCTAssertEqual(events.events.filter { event in
            guard case let .transition(token, _) = event else { return false }
            return token == transitionToken
        }, [
            .transition(
                token: transitionToken,
                outcome: .failed(.badData(kVTVideoDecoderUnsupportedDataFormatErr))
            ),
        ])
    }

    private func fixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Video"
        ))
        return try Data(contentsOf: url)
    }

    private func makeNativeDecoder(
        threadCount: Int32,
        recorder: NativeVideoFrameRecorder
    ) throws -> OpaquePointer {
        var decoder: OpaquePointer?
        let status = vp_ffmpeg_video_decoder_create(
            nil,
            0,
            threadCount,
            recordNativeVideoFrame,
            Unmanaged.passUnretained(recorder).toOpaque(),
            &decoder
        )
        XCTAssertEqual(status, 0)
        return try XCTUnwrap(decoder)
    }

    private func assertLegalFixtureIsStillConsumed(
        _ bytes: Data,
        decoder: OpaquePointer,
        recorder: NativeVideoFrameRecorder,
        token: Int64
    ) throws {
        var failureToken: Int64 = 99
        var hasFailureToken: UInt8 = 99
        let status = bytes.withUnsafeBytes { raw in
            vp_ffmpeg_video_decoder_push(
                decoder,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
                token,
                &failureToken,
                &hasFailureToken
            )
        }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(failureToken, 0)
        XCTAssertEqual(hasFailureToken, 0)
        XCTAssertEqual(
            vp_ffmpeg_video_decoder_push(
                decoder, nil, 0, 0, &failureToken, &hasFailureToken
            ),
            0
        )
        XCTAssertEqual(failureToken, 0)
        XCTAssertEqual(hasFailureToken, 0)
        XCTAssertEqual(recorder.frames.map(\.token), [token])
    }

    private func makeAccessUnit(id: UInt64) -> CompressedVideoAccessUnit {
        var blockBuffer: CMBlockBuffer?
        _ = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: 8,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 8,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 25),
            presentationTimeStamp: CMTime(value: Int64(id), timescale: 25),
            decodeTimeStamp: .invalid
        )
        var size = 8
        _ = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        )
        return CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer!,
            generation: generation,
            isRandomAccess: true,
            parserMetadata: VideoParserMetadata(
                fieldOrder: nil,
                pictureStructure: .frame,
                isInterlaced: nil,
                repeatFirstField: false,
                topFieldFirst: nil,
                sourcePTS90k: nil
            )
        )
    }

    private func drain(_ executor: PlaybackSerialExecutor) {
        let completed = expectation(description: "playback executor drained")
        executor.submit { completed.fulfill() }
        wait(for: [completed], timeout: 2)
    }

    private func configure(
        _ decoder: FFmpegVideoDecoder,
        format: CMVideoFormatDescription,
        queue: DispatchQueue,
        executor: PlaybackSerialExecutor
    ) throws {
        enqueueConfigure(decoder, format: format, queue: queue)
        drain(executor)
    }

    private func enqueueConfigure(
        _ decoder: FFmpegVideoDecoder,
        format: CMVideoFormatDescription,
        queue: DispatchQueue
    ) {
        decoder.transition(.configure(
            token: VideoDecoderTransitionToken(),
            format: format,
            generation: generation
        ))
        queue.sync {}
    }

    private func invalidate(
        _ decoder: FFmpegVideoDecoder,
        queue: DispatchQueue,
        executor: PlaybackSerialExecutor
    ) {
        enqueueInvalidate(decoder, queue: queue)
        drain(executor)
    }

    private func enqueueInvalidate(
        _ decoder: FFmpegVideoDecoder,
        queue: DispatchQueue
    ) {
        decoder.transition(.invalidate(token: VideoDecoderTransitionToken()))
        queue.sync {}
    }

    private func makeFormat(
        fieldCount: Int?,
        codecType: CMVideoCodecType = kCMVideoCodecType_H264
    ) throws -> CMVideoFormatDescription {
        var extensions: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        if let fieldCount {
            extensions[kCMFormatDescriptionExtension_FieldCount] = fieldCount as CFNumber
        }
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: codecType,
            width: 16,
            height: 8,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }
}

private enum RecordedFFmpegDecoderEvent: Equatable {
    case submissionFailure(VideoDecoderFailure, generation: MediaGeneration)
    case completed(accessUnitID: UInt64, generation: MediaGeneration)
    case frame(accessUnitID: UInt64)
}

private enum DetailedFFmpegDecoderEvent: Sendable, Equatable {
    case transition(
        token: VideoDecoderTransitionToken,
        outcome: VideoDecoderTransitionOutcome
    )
    case frame(accessUnitID: UInt64, identity: VideoDecoderEventIdentity)
    case submissionFailure(VideoDecoderFailure, identity: VideoDecoderEventIdentity)
    case completed(
        accessUnitID: UInt64,
        identity: VideoDecoderEventIdentity,
        disposition: VideoDecoderSubmissionDisposition
    )
}

private final class DetailedFFmpegEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DetailedFFmpegDecoderEvent] = []

    func record(_ event: VideoDecoderEvent) {
        let recorded: DetailedFFmpegDecoderEvent?
        switch event {
        case let .transitionCompleted(token, outcome):
            recorded = .transition(token: token, outcome: outcome)
        case let .frame(frame, identity):
            recorded = .frame(accessUnitID: frame.accessUnitID, identity: identity)
        case let .submissionFailure(_, failure, identity):
            recorded = .submissionFailure(failure, identity: identity)
        case let .submissionCompleted(accessUnitID, identity, disposition):
            recorded = .completed(
                accessUnitID: accessUnitID,
                identity: identity,
                disposition: disposition
            )
        case .recoverableFailure, .fatalFailure:
            recorded = nil
        }
        guard let recorded else { return }
        lock.withLock { storage.append(recorded) }
    }

    var events: [DetailedFFmpegDecoderEvent] {
        lock.withLock { storage }
    }
}

private final class FFmpegEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedFFmpegDecoderEvent] = []

    func record(_ event: VideoDecoderEvent) {
        let recorded: RecordedFFmpegDecoderEvent?
        switch event {
        case let .submissionFailure(_, failure, identity):
            recorded = .submissionFailure(failure, generation: identity.generation)
        case let .submissionCompleted(accessUnitID, identity, _):
            recorded = .completed(accessUnitID: accessUnitID, generation: identity.generation)
        case let .frame(frame, _):
            recorded = .frame(accessUnitID: frame.accessUnitID)
        case .recoverableFailure, .fatalFailure, .transitionCompleted:
            recorded = nil
        }
        guard let recorded else { return }
        lock.withLock { storage.append(recorded) }
    }

    var events: [RecordedFFmpegDecoderEvent] {
        lock.withLock { storage }
    }
}

private final class LockedTestError: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func store(_ error: Error) {
        lock.withLock { stored = error }
    }

    var error: Error? { lock.withLock { stored } }
}

private final class LockedStringTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    var values: [String] { lock.withLock { storage } }
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSCondition()
    private var frames: [DecodedVideoFrame] = []

    func record(_ event: VideoDecoderEvent) {
        guard case let .frame(frame, _) = event else { return }
        lock.lock()
        frames.append(frame)
        lock.broadcast()
        lock.unlock()
    }

    func wait(timeout: TimeInterval) -> DecodedVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while frames.isEmpty {
            guard lock.wait(until: deadline) else { return nil }
        }
        return frames.removeFirst()
    }
}
