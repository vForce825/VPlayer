// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import XCTest
@testable import VPlayerPlayback

final class DeinterlacePipelineIntegrationTests: XCTestCase {
    private let harness = DeterministicPipelineHarness()

    func testProgressive4KBypassesDeinterlacing() async throws {
        let result = try await harness.play(
            fixture: .hevc2160p50Progressive,
            frames: 150
        )

        XCTAssertEqual(result.presentations.count, 150)
        XCTAssertEqual(result.metrics.yadifKernelDispatchCount, 0)
        XCTAssertEqual(result.metrics.configurationCount, 1)
        XCTAssertGreaterThan(result.metrics.decodedAccessUnitCount, 150)
        XCTAssertEqual(result.allocatedDecodedSurfaceCount, 1)
        XCTAssertEqual(result.formatMetadata.dimensions.width, 3_840)
        XCTAssertEqual(result.formatMetadata.dimensions.height, 2_160)
        XCTAssertEqual(result.formatMetadata.bitDepth, 10)
        XCTAssertEqual(result.formatMetadata.transfer, .hlg)
        XCTAssertEqual(result.formatMetadata.primaries, .bt2020)
        XCTAssertEqual(result.formatCodecType, kCMVideoCodecType_HEVC)
        XCTAssertEqual(result.pixelFormats, [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        XCTAssertTrue(result.routes.contains(.rawWhileClassifying))
        XCTAssertTrue(result.routes.contains(.bypass))
    }

    func testPsFBypassesDeinterlacingThroughProductionCoordinator() async throws {
        let result = try await harness.play(fixture: .h2641080PsF25, frames: 16)

        XCTAssertEqual(result.presentations.count, 16)
        XCTAssertEqual(result.routes.last, .bypass)
        XCTAssertEqual(result.metrics.yadifKernelDispatchCount, 0)
        XCTAssertEqual(result.metrics.configurationCount, 1)
        XCTAssertGreaterThan(result.metrics.decodedAccessUnitCount, 16)
    }

    func test25iYADIFProducesFiftyDistinctTimesPerSecond() async throws {
        let result = try await harness.play(
            fixture: .h2641080i25TFF,
            seconds: 1
        )

        XCTAssertEqual(result.presentations.count, 50)
        XCTAssertEqual(Set(result.presentations.map(\.presentationTimeStamp)).count, 50)
        XCTAssertGreaterThan(Set(try result.presentations.map(lumaDigest)).count, 25)
        XCTAssertEqual(result.metrics.yadifKernelDispatchCount, 25)
        XCTAssertEqual(result.resolvedFieldOrders, [.top])
        XCTAssertEqual(result.pixelFormats, [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    }

    func test30000Over1001BFFKeepsExactFieldCadenceWithoutDrift() async throws {
        let result = try await harness.play(
            fixture: .h2641080i30000Over1001BFF,
            fields: 120
        )

        XCTAssertEqual(result.presentations.count, 120)
        XCTAssertEqual(result.inputFrameDurations, [CMTime(value: 3_003, timescale: 90_000)])
        XCTAssertEqual(Set(result.presentations.map(\.duration)), [
            CMTime(value: 1_001, timescale: 60_000),
        ])
        XCTAssertEqual(result.resolvedFieldOrders, [.bottom])
        XCTAssertEqual(result.pixelFormats, [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])

        let first = try XCTUnwrap(result.presentations.first).presentationTimeStamp
        let last = try XCTUnwrap(result.presentations.last).presentationTimeStamp
        let expectedLast = CMTimeAdd(
            first,
            CMTimeMultiply(CMTime(value: 1_001, timescale: 60_000), multiplier: 119)
        )
        XCTAssertEqual(CMTimeCompare(last, expectedLast), 0)
    }

    func testWrapDiscontinuityAndFormatChangeNeverMixGenerationReferences() async throws {
        let result = try await harness.play(
            fixture: .wrapThenSPSAndPMTChange,
        )

        XCTAssertTrue(result.presentationPTS.isStrictlyIncreasingWithinEachGeneration)
        XCTAssertEqual(result.metrics.crossGenerationRendererDeliveryCount, 0)
        XCTAssertEqual(result.generationAdvanceReasons, [.sps, .pmt, .discontinuity])
        XCTAssertEqual(result.generationAdvanceDeltas, [1, 1, 1])
        XCTAssertEqual(result.generationAdvanceCount, 3)
        XCTAssertEqual(result.unchangedPMTGenerationAdvanceCount, 0)
        XCTAssertGreaterThanOrEqual(result.pipelineDemuxEventCount, 4)
        XCTAssertGreaterThanOrEqual(result.discontinuityRendererFlushCount, 1)
        XCTAssertEqual(result.lateDecoderCallbackDeliveryCount, 0)
        var activeProcessorGeneration: MediaGeneration?
        for event in result.processorEvents {
            switch event {
            case let .reset(generation):
                activeProcessorGeneration = generation
            case let .submit(generation):
                XCTAssertEqual(generation, activeProcessorGeneration)
            }
        }
        XCTAssertEqual(
            result.generationBoundaryAudits.map(\.reason),
            [.sps, .pmt, .discontinuity]
        )
        for boundary in result.generationBoundaryAudits {
            let resetIndex = try XCTUnwrap(
                result.processorEvents.indices.dropFirst(boundary.processorEventOffset).first {
                    result.processorEvents[$0] == .reset(boundary.generation)
                }
            )
            let beforeReset = result.processorEvents[
                boundary.processorEventOffset..<resetIndex
            ]
            XCTAssertFalse(beforeReset.contains { event in
                if case .submit = event { return true }
                return false
            })
            let postBoundarySubmitCount = result.processorEvents.indices.filter { index in
                index > resetIndex
                    && result.processorEvents[index] == .submit(boundary.generation)
            }.count
            XCTAssertGreaterThanOrEqual(postBoundarySubmitCount, 3)
            let generationPresentationCount = result.presentationPTS.filter {
                $0.generation == boundary.generation
            }.count
            XCTAssertEqual(generationPresentationCount, 8)
        }
        XCTAssertEqual(result.rawSourcePTS90k, [
            (1 << 33) - 7_200,
            (1 << 33) - 3_600,
            0,
            3_600,
        ])
    }

    func testProductionCoordinatorReordersBFramePTSAndCarriesRepeatTiming() throws {
        let result = try harness.runClassifierAndTimingEdgeMatrix()

        XCTAssertEqual(result.unknownRoutes, [.rawWhileClassifying])
        XCTAssertTrue(result.normalizedPTS.isStrictlyIncreasing)
        XCTAssertGreaterThanOrEqual(result.synthesizedTimingCount, 2)
        XCTAssertEqual(Set(result.normalizedDurations), [CMTime(value: 1, timescale: 25)])
        XCTAssertEqual(
            result.callbackSourcePTS90k,
            [0, 7_200, 3_600, 10_800, 14_400, 14_400, nil]
        )
        XCTAssertEqual(result.deliveredSourceAccessUnitIDs.prefix(3), [1, 3, 2])
        XCTAssertEqual(result.repeatFieldRoute, .metalYADIF2x)
        XCTAssertTrue(result.repeatFieldMetadataReachedProcessor)
        XCTAssertEqual(
            result.repeatFieldNormalizedDurations,
            [CMTime(value: 1, timescale: 25)]
        )
    }

    func testGPUCommandErrorIsTerminalAndTyped() async throws {
        let result = try await harness.runGPUCommandErrorRegression()

        XCTAssertEqual(result.failure, .commandExecution)
        XCTAssertEqual(result.successfulPresentationCount, 0)
        XCTAssertEqual(result.commandSubmissionCount, 1)
    }
}
