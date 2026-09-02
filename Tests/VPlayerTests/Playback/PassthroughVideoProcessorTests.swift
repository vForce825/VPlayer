// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import VPlayerPlayback

final class PassthroughVideoProcessorTests: XCTestCase {
    func testStaleGenerationReturnsTypedCancellationWithoutAdvancingSequence() throws {
        let processor = PassthroughVideoProcessor()
        let activeGeneration = MediaGeneration(rawValue: 9)
        let stale = try makeFrame(id: 1, generation: MediaGeneration(rawValue: 8))
        let current = try makeFrame(id: 2, generation: activeGeneration)
        let results = ProcessorResultRecorder()

        processor.reset(to: activeGeneration)
        processor.submit(stale) { results.record($0, isIsolated: true) }
        processor.submit(current) { results.record($0, isIsolated: true) }

        let recorded = results.results
        guard case .cancelled(.staleGeneration) = recorded[0] else {
            return XCTFail("stale input must be an explicit typed cancellation")
        }
        guard case let .produced(batch) = recorded[1] else {
            return XCTFail("current input must produce a non-empty batch")
        }
        XCTAssertEqual(batch.frames.map(\.sequenceNumber), [1])
    }

    func testProgressiveAndInterlacedFramesPreserveIdentityTimingMetadataAndSequence() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.processor.identity")
        let processor = PassthroughVideoProcessor()
        let generation = MediaGeneration(rawValue: 7)
        let progressiveBuffer = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let interlacedBuffer = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let progressive = try makeFrame(
            id: 11,
            pixelBuffer: progressiveBuffer,
            generation: generation,
            parserMetadata: parserMetadata(interlaced: false)
        )
        let interlaced = try makeFrame(
            id: 12,
            pixelBuffer: interlacedBuffer,
            generation: generation,
            parserMetadata: parserMetadata(interlaced: true)
        )
        let results = ProcessorResultRecorder()

        execute(on: executor) {
            processor.reset(to: generation)
            processor.submit(progressive) { results.record($0, isIsolated: executor.isIsolated) }
            processor.submit(interlaced) { results.record($0, isIsolated: executor.isIsolated) }
        }

        XCTAssertEqual(processor.requiredInputFrameCount, 1)
        let outputs = results.producedFrames
        XCTAssertEqual(outputs.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(outputs.map(\.sourceAccessUnitID), [11, 12])
        XCTAssertEqual(outputs.map(\.generation), [generation, generation])
        XCTAssertEqual(outputs.map(\.presentationTimeStamp), [progressive.presentationTimeStamp, interlaced.presentationTimeStamp])
        XCTAssertEqual(outputs.map(\.duration), [progressive.duration, interlaced.duration])
        XCTAssertEqual(outputs.map(\.formatMetadata), [progressive.formatMetadata, interlaced.formatMetadata])
        XCTAssertEqual(results.isolationChecks, [true, true])
        XCTAssertTrue(outputs[0].pixelBuffer === progressiveBuffer)
        XCTAssertTrue(outputs[1].pixelBuffer === interlacedBuffer)
    }

    func testResetRestartsSequenceAtOne() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.processor.reset")
        let processor = PassthroughVideoProcessor()
        let firstGeneration = MediaGeneration(rawValue: 2)
        let secondGeneration = MediaGeneration(rawValue: 3)
        let results = ProcessorResultRecorder()
        let first = try makeFrame(id: 1, generation: firstGeneration)
        let second = try makeFrame(id: 2, generation: secondGeneration)

        execute(on: executor) {
            processor.reset(to: firstGeneration)
            processor.submit(first) { results.record($0, isIsolated: executor.isIsolated) }
            processor.reset(to: secondGeneration)
            processor.submit(second) { results.record($0, isIsolated: executor.isIsolated) }
        }

        let outputs = results.producedFrames
        XCTAssertEqual(outputs.map(\.sequenceNumber), [1, 1])
    }

    func testPublicMetadataEqualityComparesDimensionsAndEveryStoredField() {
        let baseline = metadata()
        XCTAssertEqual(baseline, metadata())
        XCTAssertNotEqual(baseline, metadata(dimensions: CMVideoDimensions(width: 63, height: 32)))
        XCTAssertNotEqual(baseline, metadata(bitDepth: 10))
        XCTAssertNotEqual(baseline, metadata(range: .full))
        XCTAssertNotEqual(baseline, metadata(matrix: .bt2020))
        XCTAssertNotEqual(baseline, metadata(transfer: .hlg))
        XCTAssertNotEqual(baseline, metadata(primaries: .bt2020))
        XCTAssertNotEqual(baseline, metadata(cleanAperture: CGRect(x: 1, y: 2, width: 3, height: 4)))
        XCTAssertNotEqual(baseline, metadata(chromaLocation: .init(topField: "Left", bottomField: nil)))
        XCTAssertNotEqual(baseline, metadata(hdrStaticMetadata: .init(
            masteringDisplayColorVolume: Data([1]),
            contentLightLevelInfo: nil
        )))
    }

    private func execute(
        on executor: PlaybackSerialExecutor,
        _ operation: @escaping @Sendable () -> Void
    ) {
        let completed = expectation(description: "processor operation completed")
        executor.submit {
            operation()
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    private func makeFrame(
        id: UInt64,
        pixelBuffer: CVPixelBuffer? = nil,
        generation: MediaGeneration,
        parserMetadata: VideoParserMetadata? = nil
    ) throws -> DecodedVideoFrame {
        DecodedVideoFrame(
            accessUnitID: id,
            pixelBuffer: try pixelBuffer ?? makePixelBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            presentationTimeStamp: CMTime(value: Int64(id), timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            generation: generation,
            parserMetadata: parserMetadata ?? self.parserMetadata(interlaced: false),
            formatMetadata: metadata()
        )
    }

    private func makePixelBuffer(format: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            32,
            format,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func parserMetadata(interlaced: Bool) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: interlaced ? .tt : .progressive,
            pictureStructure: .frame,
            isInterlaced: interlaced,
            repeatFirstField: interlaced,
            topFieldFirst: interlaced ? true : nil,
            sourcePTS90k: interlaced ? 90_000 : nil
        )
    }

    private func metadata(
        dimensions: CMVideoDimensions = CMVideoDimensions(width: 64, height: 32),
        bitDepth: Int = 8,
        range: VideoFormatMetadata.Range = .video,
        matrix: VideoFormatMetadata.Matrix = .bt709,
        transfer: VideoFormatMetadata.Transfer = .bt709,
        primaries: VideoFormatMetadata.Primaries = .bt709,
        cleanAperture: CGRect? = nil,
        chromaLocation: VideoFormatMetadata.ChromaLocation = .init(topField: nil, bottomField: nil),
        hdrStaticMetadata: VideoFormatMetadata.HDRStaticMetadata = .init(
            masteringDisplayColorVolume: nil,
            contentLightLevelInfo: nil
        )
    ) -> VideoFormatMetadata {
        VideoFormatMetadata(
            dimensions: dimensions,
            bitDepth: bitDepth,
            range: range,
            matrix: matrix,
            transfer: transfer,
            primaries: primaries,
            cleanAperture: cleanAperture,
            chromaLocation: chromaLocation,
            hdrStaticMetadata: hdrStaticMetadata
        )
    }

}

private final class ProcessorResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResults: [VideoProcessingResult] = []
    private var storedIsolationChecks: [Bool] = []

    func record(
        _ result: VideoProcessingResult,
        isIsolated: Bool
    ) {
        lock.lock()
        storedResults.append(result)
        storedIsolationChecks.append(isIsolated)
        lock.unlock()
    }

    var results: [VideoProcessingResult] {
        lock.lock()
        defer { lock.unlock() }
        return storedResults
    }

    var producedFrames: [VideoPresentationFrame] {
        results.flatMap { result -> [VideoPresentationFrame] in
            guard case let .produced(batch) = result else { return [] }
            return batch.frames
        }
    }

    var isolationChecks: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedIsolationChecks
    }
}
