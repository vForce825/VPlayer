// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

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
    private var blockNextPush = false
    private var blockedPushCanReturn = false
    private var pushInProgress = false
    private var destroyedWhilePushWasInProgress = false
    var pushResult: Int32 = 0

    var tokens: [Int64] { condition.withLock { pushedTokens } }

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

    func push(_ bytes: UnsafeRawBufferPointer, token: Int64) -> Int32 {
        condition.lock()
        pushedTokens.append(token)
        if blockNextPush {
            blockNextPush = false
            pushInProgress = true
            condition.broadcast()
            while !blockedPushCanReturn { condition.wait() }
            pushInProgress = false
        }
        let result = pushResult
        condition.unlock()
        return result
    }

    func flush() {}
    func destroy() {
        condition.withLock {
            destroyedWhilePushWasInProgress =
                destroyedWhilePushWasInProgress || pushInProgress
        }
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

final class FFmpegVideoDecoderTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 2)

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
        try decoder.configure(format: try makeFormat(fieldCount: 2), generation: generation)

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
        handle.pushResult = -123
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.ffmpeg.failure")
        let queue = DispatchQueue(label: "org.vplayer.tests.ffmpeg.failure.submit")
        let events = FFmpegEventRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: FakeFFmpegVideoDecoderAPI(captured: captured, handle: handle),
            submissionQueue: queue
        )
        try decoder.configure(format: try makeFormat(fieldCount: 2), generation: generation)

        try decoder.decode(makeAccessUnit(id: 19), flags: [])
        queue.sync {}
        drain(executor)

        XCTAssertEqual(events.events, [
            .submissionFailure(.badData(-123), generation: generation),
            .completed(accessUnitID: 19, generation: generation),
        ])
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
        try decoder.configure(format: format, generation: generation)
        XCTAssertEqual(transitioned.wait(timeout: .now()), .success)

        let releaseQueue = DispatchSemaphore(value: 0)
        queue.async { releaseQueue.wait() }
        try decoder.decode(makeAccessUnit(id: 23), flags: [])

        // Replacing the decoder without advancing the media generation still
        // starts a new reference chain. The queued old unit must not enter it.
        let configureResult = LockedTestError()
        let configured = DispatchSemaphore(value: 0)
        let targetGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try decoder.configure(format: format, generation: targetGeneration)
            } catch {
                configureResult.store(error)
            }
            configured.signal()
        }
        XCTAssertEqual(transitioned.wait(timeout: .now() + 2), .success)
        releaseQueue.signal()
        XCTAssertEqual(configured.wait(timeout: .now() + 2), .success)
        XCTAssertNil(configureResult.error)
        queue.sync {}
        drain(executor)

        XCTAssertTrue(handle.tokens.isEmpty)
        XCTAssertEqual(events.events, [
            .completed(accessUnitID: 23, generation: generation),
        ])
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
        try decoder.configure(format: format, generation: generation)
        XCTAssertEqual(transitioned.wait(timeout: .now()), .success)

        handle.arrangeBlockedPush()
        try decoder.decode(makeAccessUnit(id: 31), flags: [])
        XCTAssertTrue(handle.waitUntilPushStarts(timeout: 2))

        let configureResult = LockedTestError()
        let configured = DispatchSemaphore(value: 0)
        let targetGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try decoder.configure(format: format, generation: targetGeneration)
            } catch {
                configureResult.store(error)
            }
            configured.signal()
        }
        XCTAssertEqual(transitioned.wait(timeout: .now() + 2), .success)

        // The epoch changes immediately, but teardown stays behind the active
        // push on the submission queue.
        XCTAssertEqual(configured.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertFalse(handle.hadConcurrentDestroy)

        handle.releaseBlockedPush()
        XCTAssertEqual(configured.wait(timeout: .now() + 2), .success)
        XCTAssertNil(configureResult.error)
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
            ffmpeg: FakeVideoDecoder()
        )

        XCTAssertThrowsError(try decoder.decode(makeAccessUnit(id: 29), flags: [])) { error in
            XCTAssertEqual(
                error as? VideoDecoderFailure,
                .sessionCreate(kVTInvalidSessionErr)
            )
        }
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

        try decoder.configure(format: try makeFormat(fieldCount: 2), generation: generation)
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
        let frames = FrameRecorder()
        let decoder = FFmpegVideoDecoder(
            executor: executor,
            eventSink: { frames.record($0) },
            api: FakeFFmpegVideoDecoderAPI(
                captured: captured,
                handle: FakeFFmpegVideoDecoderHandle()
            ),
            submissionQueue: DispatchQueue(label: "org.vplayer.tests.ffmpeg.stale.submit")
        )
        try decoder.configure(format: try makeFormat(fieldCount: 2), generation: generation)

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

    private func makeFormat(fieldCount: Int?) throws -> CMVideoFormatDescription {
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
            codecType: kCMVideoCodecType_H264,
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
}

private final class FFmpegEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedFFmpegDecoderEvent] = []

    func record(_ event: VideoDecoderEvent) {
        let recorded: RecordedFFmpegDecoderEvent?
        switch event {
        case let .submissionFailure(failure, generation):
            recorded = .submissionFailure(failure, generation: generation)
        case let .submissionCompleted(accessUnitID, generation):
            recorded = .completed(accessUnitID: accessUnitID, generation: generation)
        case .frame, .recoverableFailure, .fatalFailure:
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

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSCondition()
    private var frames: [DecodedVideoFrame] = []

    func record(_ event: VideoDecoderEvent) {
        guard case let .frame(frame) = event else { return }
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
