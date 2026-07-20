// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreVideo
import Foundation
import Metal
import XCTest
@testable import VPlayerPlayback

@MainActor
final class LumaScanProbeTests: XCTestCase {
    private let generation = MediaGeneration(rawValue: 40)

    func testPublicContractsAndPackedLayoutAreSendableAndExactlyNineKiB() {
        requireSendable(LumaScanProbeFailure.self)
        requireSendable(LumaScanProbe.self)

        XCTAssertEqual(LumaScanProbeLayout.width, 64)
        XCTAssertEqual(LumaScanProbeLayout.height, 36)
        XCTAssertEqual(LumaScanProbeLayout.sampleCount, 2_304)
        XCTAssertEqual(LumaScanProbeLayout.resultStride, 4)
        XCTAssertEqual(LumaScanProbeLayout.resultBufferLength, 9_216)
    }

    func testTwentySameGenerationCallsReserveExactlyTwelveBackendAttempts() throws {
        let backend = FakeLumaScanProbeBackend()
        let sut = LumaScanProbe(backend: backend, maximumFrames: 12)
        let pair = try makePair()

        for _ in 0..<20 {
            sut.submit(current: pair.current, previous: pair.previous, generation: generation) { _ in }
        }

        XCTAssertEqual(backend.submissionCount, 12)
        XCTAssertEqual(backend.generations, Array(repeating: generation, count: 12))
    }

    func testConfiguredBudgetClampsToZeroThroughAbsoluteTwelve() throws {
        let pair = try makePair()
        for (configured, expected) in [(0, 0), (-4, 0), (5, 5), (12, 12), (99, 12)] {
            let backend = FakeLumaScanProbeBackend()
            let sut = LumaScanProbe(backend: backend, maximumFrames: configured)

            for _ in 0..<20 {
                sut.submit(current: pair.current, previous: pair.previous, generation: generation) { _ in }
            }

            XCTAssertEqual(backend.submissionCount, expected, "configured budget \(configured)")
        }
    }

    func testNewerGenerationGetsFreshBudgetAndStaleGenerationCannotReachBackend() throws {
        let backend = FakeLumaScanProbeBackend()
        let sut = LumaScanProbe(backend: backend, maximumFrames: 2)
        let pair = try makePair()
        let newer = MediaGeneration(rawValue: generation.rawValue + 1)

        for _ in 0..<3 {
            sut.submit(current: pair.current, previous: pair.previous, generation: generation) { _ in }
        }
        for _ in 0..<3 {
            sut.submit(current: pair.current, previous: pair.previous, generation: newer) { _ in }
        }
        sut.submit(current: pair.current, previous: pair.previous, generation: generation) { _ in }

        XCTAssertEqual(backend.generations, [generation, generation, newer, newer])
    }

    func testStopIsMonotonicAndOnlyStrictlyNewerSubmitRestartsUnstoppedBudget() throws {
        let backend = FakeLumaScanProbeBackend()
        let sut = LumaScanProbe(backend: backend, maximumFrames: 4)
        let pair = try makePair()
        let older = MediaGeneration(rawValue: generation.rawValue - 1)
        let next = MediaGeneration(rawValue: generation.rawValue + 1)
        let future = MediaGeneration(rawValue: generation.rawValue + 3)

        sut.submit(current: pair.current, previous: pair.previous, generation: generation) { _ in }
        sut.stop(generation: older)
        sut.submit(current: pair.current, previous: pair.previous, generation: generation) { _ in }
        sut.stop(generation: generation)
        sut.submit(current: pair.current, previous: pair.previous, generation: generation) { _ in }
        sut.submit(current: pair.current, previous: pair.previous, generation: next) { _ in }
        sut.stop(generation: future)
        sut.submit(current: pair.current, previous: pair.previous, generation: next) { _ in }
        sut.submit(current: pair.current, previous: pair.previous, generation: future) { _ in }
        let afterFuture = MediaGeneration(rawValue: future.rawValue + 1)
        sut.submit(current: pair.current, previous: pair.previous, generation: afterFuture) { _ in }

        XCTAssertEqual(backend.generations, [generation, generation, next, afterFuture])
    }

    func testOldAndStoppedCompletionsAreSuppressedWhileActiveCompletionIsDeliveredOnce() throws {
        let backend = FakeLumaScanProbeBackend()
        let sut = LumaScanProbe(backend: backend, maximumFrames: 3)
        let pair = try makePair()
        let newer = MediaGeneration(rawValue: generation.rawValue + 1)
        let recorder = ProbeCompletionRecorder()
        let sample = ContentProbeSample(combRatio: 0.1, motionRatio: 0.2, sampleCount: 2_304)

        sut.submit(current: pair.current, previous: pair.previous, generation: generation) {
            recorder.append($0)
        }
        sut.submit(current: pair.current, previous: pair.previous, generation: newer) {
            recorder.append($0)
        }
        backend.complete(at: 0, with: .success(sample))
        backend.complete(at: 1, with: .success(sample), times: 2)

        sut.submit(current: pair.current, previous: pair.previous, generation: newer) {
            recorder.append($0)
        }
        sut.stop(generation: newer)
        backend.complete(at: 2, with: .success(sample))

        XCTAssertEqual(recorder.results, [.success(sample)])
    }

    func testSynchronousBackendCompletionDoesNotDeadlock() throws {
        let sample = ContentProbeSample(combRatio: 0.01, motionRatio: 0.03, sampleCount: 2_304)
        let backend = FakeLumaScanProbeBackend(synchronousResult: .success(sample))
        let sut = LumaScanProbe(backend: backend, maximumFrames: 1)
        let pair = try makePair()
        let recorder = ProbeCompletionRecorder()

        sut.submit(current: pair.current, previous: pair.previous, generation: generation) {
            recorder.append($0)
        }

        XCTAssertEqual(recorder.results, [.success(sample)])
    }

    func testGPUResourcesAreReleasedBeforeBackendCompletionCanWakeCaller() {
        let resources = FakeLumaScanCompletionResources()
        let recorder = ReleaseOrderingRecorder()
        let sample = ContentProbeSample(combRatio: 0.1, motionRatio: 0.2, sampleCount: 2_304)

        LumaScanCompletionDelivery.deliver(
            result: .success(sample),
            resources: resources
        ) { result in
            recorder.record(
                resourcesReleased: resources.isReleased,
                result: result
            )
        }

        XCTAssertEqual(resources.releaseCount, 1)
        XCTAssertTrue(recorder.resourcesWereReleased)
        XCTAssertEqual(recorder.result, .success(sample))
    }

    func testBackendValidationFailuresConsumeBudgetAndForwardOnlyForActiveGeneration() throws {
        let backend = FakeLumaScanProbeBackend(submissionFailure: .textureMappingFailed(code: -1))
        let sut = LumaScanProbe(backend: backend, maximumFrames: 2)
        let pair = try makePair()
        let recorder = ProbeCompletionRecorder()

        for _ in 0..<3 {
            sut.submit(current: pair.current, previous: pair.previous, generation: generation) {
                recorder.append($0)
            }
        }

        XCTAssertEqual(backend.submissionCount, 2)
        XCTAssertEqual(recorder.results, [
            .failure(.textureMappingFailed(code: -1)),
            .failure(.textureMappingFailed(code: -1)),
        ])
        backend.complete(
            at: 0,
            with: .success(ContentProbeSample(
                combRatio: 0,
                motionRatio: 0,
                sampleCount: 2_304
            ))
        )
        XCTAssertEqual(recorder.results.count, 2, "a throwing backend cannot complete twice later")
    }

    func testInitializationAndCommandFailureSurfaceIsPreciseAndForwarded() throws {
        let initializationFailures: [LumaScanProbeFailure] = [
            .initializationFailed,
            .shaderLibraryUnavailable,
            .shaderFunctionUnavailable,
            .computePipelineCreationFailed,
            .textureCacheCreationFailed(code: -2),
        ]
        for failure in initializationFailures {
            XCTAssertThrowsError(try LumaScanProbe(maximumFrames: 12, makeBackend: { throw failure })) {
                XCTAssertEqual($0 as? LumaScanProbeFailure, failure)
            }
        }

        let submissionFailures: [LumaScanProbeFailure] = [
            .resultBufferAllocationFailed,
            .commandBufferAllocationFailed,
            .commandEncoderAllocationFailed,
            .asynchronousCommandFailed,
        ]
        let pair = try makePair()
        for failure in submissionFailures {
            let backend = FakeLumaScanProbeBackend(synchronousResult: .failure(failure))
            let sut = LumaScanProbe(backend: backend, maximumFrames: 1)
            let recorder = ProbeCompletionRecorder()
            sut.submit(current: pair.current, previous: pair.previous, generation: generation) {
                recorder.append($0)
            }
            XCTAssertEqual(recorder.results, [.failure(failure)])
        }
    }

    func testNV12AndP010RangesSelectExactLumaTextureFormats() throws {
        let formats: [(OSType, MTLPixelFormat)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .r8Unorm),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, .r8Unorm),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, .r16Unorm),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, .r16Unorm),
        ]

        for (format, expectedTextureFormat) in formats {
            let buffer = try makePixelBuffer(pixelFormat: format)
            let mapping = try LumaScanInputValidator.validate(
                current: .init(pixelBuffer: buffer),
                previous: .init(pixelBuffer: buffer)
            )
            XCTAssertEqual(mapping.pixelFormat, expectedTextureFormat)
            XCTAssertEqual(mapping.width, 128)
            XCTAssertEqual(mapping.height, 72)
        }
    }

    func testInvalidSurfacePlanesDimensionsFormatsAndPairMismatchAreDistinguished() throws {
        let valid = LumaScanPixelBufferProperties(
            hasIOSurface: true,
            planeCount: 2,
            width: 128,
            height: 72,
            lumaWidth: 128,
            lumaHeight: 72,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let actualMissingSurface = try makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes: [:]
        )
        XCTAssertFalse(LumaScanPixelBufferProperties(
            pixelBuffer: actualMissingSurface
        ).hasIOSurface)

        XCTAssertThrowsError(try LumaScanInputValidator.validate(
            current: replacing(valid, hasIOSurface: false),
            previous: valid
        )) { XCTAssertEqual($0 as? LumaScanProbeFailure, .nonIOSurfaceInput) }
        XCTAssertThrowsError(try LumaScanInputValidator.validate(
            current: replacing(valid, planeCount: 1),
            previous: valid
        )) { XCTAssertEqual($0 as? LumaScanProbeFailure, .invalidPlaneCount(current: 1, previous: 2)) }
        XCTAssertThrowsError(try LumaScanInputValidator.validate(
            current: replacing(valid, lumaHeight: 2),
            previous: replacing(valid, lumaHeight: 2)
        )) { XCTAssertEqual($0 as? LumaScanProbeFailure, .invalidDimensions) }
        XCTAssertThrowsError(try LumaScanInputValidator.validate(
            current: replacing(valid, pixelFormat: kCVPixelFormatType_32BGRA),
            previous: replacing(valid, pixelFormat: kCVPixelFormatType_32BGRA)
        )) {
            XCTAssertEqual(
                $0 as? LumaScanProbeFailure,
                .unsupportedPixelFormat(kCVPixelFormatType_32BGRA)
            )
        }
        XCTAssertThrowsError(try LumaScanInputValidator.validate(
            current: valid,
            previous: replacing(valid, width: 64, lumaWidth: 64)
        )) { XCTAssertEqual($0 as? LumaScanProbeFailure, .incompatiblePixelBuffers) }
        XCTAssertThrowsError(try LumaScanInputValidator.validate(
            current: valid,
            previous: replacing(
                valid,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
        )) { XCTAssertEqual($0 as? LumaScanProbeFailure, .incompatiblePixelBuffers) }
    }

    func testProductionSourceNeverLocksOrDownloadsVideoPlanesOrWaitsForGPU() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/VPlayerPlayback/Scan/LumaScanProbe.swift"
            ),
            encoding: .utf8
        )
        for forbidden in [
            "CVPixelBufferLockBaseAddress",
            "CVPixelBufferGetBaseAddress",
            ".getBytes(",
            "waitUntilCompleted",
        ] {
            XCTAssertFalse(source.contains(forbidden), "production source contains \(forbidden)")
        }
    }

    func testMovingProgressiveLinearDiagonalNV12HasLowCombAndVisibleMotion() throws {
        let sample = try runRealProbe(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            pattern: .progressiveDiagonal
        )

        XCTContext.runActivity(
            named: "NV12 progressive comb=\(sample.combRatio) motion=\(sample.motionRatio)"
        ) { _ in }
        XCTAssertEqual(sample.sampleCount, 2_304)
        XCTAssertLessThan(sample.combRatio, 0.02)
        XCTAssertGreaterThan(sample.motionRatio, 0.015)
    }

    func testAlternatingFieldMotionNV12ExceedsInterlaceAndMotionThresholds() throws {
        let sample = try runRealProbe(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            pattern: .alternatingFields
        )

        XCTContext.runActivity(
            named: "NV12 interlaced comb=\(sample.combRatio) motion=\(sample.motionRatio)"
        ) { _ in }
        XCTAssertEqual(sample.sampleCount, 2_304)
        XCTAssertGreaterThanOrEqual(sample.combRatio, 0.08)
        XCTAssertGreaterThanOrEqual(sample.motionRatio, 0.015)
    }

    func testRealP010ProbeUsesSamePackedSampleContract() throws {
        let sample = try runRealProbe(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            pattern: .progressiveDiagonal
        )

        XCTContext.runActivity(
            named: "P010 progressive comb=\(sample.combRatio) motion=\(sample.motionRatio)"
        ) { _ in }
        XCTAssertEqual(sample.sampleCount, 2_304)
        XCTAssertLessThan(sample.combRatio, 0.02)
        XCTAssertGreaterThan(sample.motionRatio, 0.015)
    }

    private func runRealProbe(
        pixelFormat: OSType,
        pattern: ProbePattern
    ) throws -> ContentProbeSample {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let pair = try makePair(pixelFormat: pixelFormat, pattern: pattern)
        let sut = try LumaScanProbe(commandQueue: queue)
        let expectation = expectation(description: "GPU probe completion")
        let recorder = ProbeCompletionRecorder()

        sut.submit(current: pair.current, previous: pair.previous, generation: generation) {
            recorder.append($0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        guard let result = recorder.results.first else {
            throw XCTFailAndThrow("missing probe result")
        }
        return try result.get()
    }

    private func makePair(
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        pattern: ProbePattern = .progressiveDiagonal
    ) throws -> (current: CVPixelBuffer, previous: CVPixelBuffer) {
        let current = try makePixelBuffer(pixelFormat: pixelFormat)
        let previous = try makePixelBuffer(pixelFormat: pixelFormat)
        try seed(current, pattern: pattern, isCurrent: true)
        try seed(previous, pattern: pattern, isCurrent: false)
        return (current, previous)
    }

    private func makePixelBuffer(
        pixelFormat: OSType,
        width: Int = 128,
        height: Int = 72,
        attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TestFailure.pixelBuffer(status)
        }
        return pixelBuffer
    }

    private func seed(
        _ pixelBuffer: CVPixelBuffer,
        pattern: ProbePattern,
        isCurrent: Bool
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw TestFailure.missingPlane
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let isP010 = CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

        for y in 0..<height {
            for x in 0..<width {
                let value = pattern.value(x: x, y: y, isCurrent: isCurrent)
                if isP010 {
                    luma.advanced(by: y * bytesPerRow)
                        .assumingMemoryBound(to: UInt16.self)[x] = UInt16(value) << 8
                } else {
                    luma.advanced(by: y * bytesPerRow)
                        .assumingMemoryBound(to: UInt8.self)[x] = UInt8(value)
                }
            }
        }
    }

    private func replacing(
        _ value: LumaScanPixelBufferProperties,
        hasIOSurface: Bool? = nil,
        planeCount: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        lumaWidth: Int? = nil,
        lumaHeight: Int? = nil,
        pixelFormat: OSType? = nil
    ) -> LumaScanPixelBufferProperties {
        LumaScanPixelBufferProperties(
            hasIOSurface: hasIOSurface ?? value.hasIOSurface,
            planeCount: planeCount ?? value.planeCount,
            width: width ?? value.width,
            height: height ?? value.height,
            lumaWidth: lumaWidth ?? value.lumaWidth,
            lumaHeight: lumaHeight ?? value.lumaHeight,
            pixelFormat: pixelFormat ?? value.pixelFormat
        )
    }
}

private enum ProbePattern {
    case progressiveDiagonal
    case alternatingFields

    func value(x: Int, y: Int, isCurrent: Bool) -> Int {
        switch self {
        case .progressiveDiagonal:
            return 40 + x / 2 + y - (isCurrent ? 0 : 8)
        case .alternatingFields:
            if isCurrent {
                return y.isMultiple(of: 2) ? 32 : 220
            }
            return y.isMultiple(of: 2) ? 220 : 32
        }
    }
}

private enum TestFailure: Error {
    case pixelBuffer(CVReturn)
    case missingPlane
    case missingResult(String)
}

private func XCTFailAndThrow(_ message: String) -> TestFailure {
    XCTFail(message)
    return .missingResult(message)
}

private final class FakeLumaScanProbeBackend: LumaScanProbeBackend, @unchecked Sendable {
    private struct Submission {
        let generation: MediaGeneration
        let completion: @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    }

    private let lock = NSLock()
    private var submissions: [Submission] = []
    private let synchronousResult: Result<ContentProbeSample, LumaScanProbeFailure>?
    private let submissionFailure: LumaScanProbeFailure?

    init(
        synchronousResult: Result<ContentProbeSample, LumaScanProbeFailure>? = nil,
        submissionFailure: LumaScanProbeFailure? = nil
    ) {
        self.synchronousResult = synchronousResult
        self.submissionFailure = submissionFailure
    }

    var submissionCount: Int {
        lock.withLock { submissions.count }
    }

    var generations: [MediaGeneration] {
        lock.withLock { submissions.map(\.generation) }
    }

    func submit(
        current: CVPixelBuffer,
        previous: CVPixelBuffer,
        generation: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) throws(LumaScanProbeFailure) {
        lock.withLock {
            submissions.append(Submission(generation: generation, completion: completion))
        }
        if let submissionFailure {
            throw submissionFailure
        }
        if let synchronousResult {
            completion(synchronousResult)
        }
    }

    func complete(
        at index: Int,
        with result: Result<ContentProbeSample, LumaScanProbeFailure>,
        times: Int = 1
    ) {
        let completion = lock.withLock { submissions[index].completion }
        for _ in 0..<times {
            completion(result)
        }
    }
}

private final class ProbeCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<ContentProbeSample, LumaScanProbeFailure>] = []

    var results: [Result<ContentProbeSample, LumaScanProbeFailure>] {
        lock.withLock { storage }
    }

    func append(_ result: Result<ContentProbeSample, LumaScanProbeFailure>) {
        lock.withLock { storage.append(result) }
    }
}

private final class FakeLumaScanCompletionResources:
    LumaScanCompletionResourceReleasing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var releases = 0

    var isReleased: Bool {
        lock.withLock { releases > 0 }
    }

    var releaseCount: Int {
        lock.withLock { releases }
    }

    func releaseBeforeCompletion() {
        lock.withLock { releases += 1 }
    }
}

private final class ReleaseOrderingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (
        resourcesReleased: Bool,
        result: Result<ContentProbeSample, LumaScanProbeFailure>
    )?

    var resourcesWereReleased: Bool {
        lock.withLock { storage?.resourcesReleased ?? false }
    }

    var result: Result<ContentProbeSample, LumaScanProbeFailure>? {
        lock.withLock { storage?.result }
    }

    func record(
        resourcesReleased: Bool,
        result: Result<ContentProbeSample, LumaScanProbeFailure>
    ) {
        lock.withLock { storage = (resourcesReleased, result) }
    }
}

private func requireSendable<T: Sendable>(_: T.Type) {}
