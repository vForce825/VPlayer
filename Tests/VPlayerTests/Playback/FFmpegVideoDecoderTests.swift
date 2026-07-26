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
    private let lock = NSLock()
    private var pushedTokens: [Int64] = []
    var pushResult: Int32 = 0

    var tokens: [Int64] { lock.withLock { pushedTokens } }

    func push(_ bytes: UnsafeRawBufferPointer, token: Int64) -> Int32 {
        lock.withLock { pushedTokens.append(token) }
        return pushResult
    }

    func flush() {}
    func destroy() {}
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
