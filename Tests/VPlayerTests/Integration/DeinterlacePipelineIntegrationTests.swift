// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import XCTest
@testable import VPlayerPlayback

final class DeinterlacePipelineIntegrationTests: XCTestCase {
    private let harness = DeterministicPipelineHarness()

    func testProgressive4KBypassesBothAlgorithms() async throws {
        for algorithm in DeinterlaceAlgorithm.allCases {
            let result = try await harness.play(
                fixture: .hevc2160p50Progressive,
                algorithm: algorithm,
                frames: 150
            )

            XCTAssertEqual(result.presentations.count, 150)
            XCTAssertEqual(result.metrics.yadifKernelDispatchCount, 0)
            XCTAssertEqual(result.metrics.temporalPropertySetCount, 0)
            XCTAssertEqual(result.metrics.temporalDecodeFlagCount, 0)
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
    }

    func test25iYADIFProducesFiftyDistinctTimesPerSecond() async throws {
        let result = try await harness.play(
            fixture: .h2641080i25TFF,
            algorithm: .metalYADIF2x,
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
            algorithm: .metalYADIF2x,
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
            algorithm: .metalYADIF2x
        )

        XCTAssertTrue(result.presentationPTS.isStrictlyIncreasingWithinEachGeneration)
        XCTAssertEqual(result.metrics.crossGenerationReferenceCount, 0)
        XCTAssertEqual(
            result.metrics.staleGenerationDropCount,
            UInt64(result.injectedLateCallbackCount)
        )
        XCTAssertEqual(result.generationAdvanceReasons, [.sps, .pmt])
        XCTAssertEqual(result.generationAdvanceDeltas, [1, 1])
        XCTAssertEqual(result.generationAdvanceCount, 2)
        XCTAssertEqual(result.unchangedPMTGenerationAdvanceCount, 0)
        XCTAssertEqual(result.rawSourcePTS90k, [
            (1 << 33) - 7_200,
            (1 << 33) - 3_600,
            0,
            3_600,
        ])
    }

    func testClassifierAndTimingEdgeMatrixUsesProductionStateMachines() throws {
        let result = try harness.runClassifierAndTimingEdgeMatrix()

        XCTAssertEqual(result.psfRoutes, [.bypass, .bypass])
        XCTAssertEqual(
            result.unknownRoutes,
            [.rawWhileClassifying, .rawWhileClassifying]
        )
        XCTAssertEqual(result.repeatFieldObservationCount, 1)
        XCTAssertTrue(result.normalizedPTS.isStrictlyIncreasing)
        XCTAssertGreaterThanOrEqual(result.synthesizedTimingCount, 3)
        XCTAssertEqual(Set(result.normalizedDurations), [CMTime(value: 1, timescale: 25)])
    }

    func testTemporalInitializationAndRuntimeFailureRemainRawAndNoticeOnce() throws {
        let result = try harness.runTemporalFailureRegression()

        XCTAssertEqual(result.initializationFallbackRoute, .rawTemporalFailure)
        XCTAssertEqual(result.runtimeFallbackRoute, .rawTemporalFailure)
        XCTAssertEqual(result.temporalPropertySetCount, 4)
        XCTAssertEqual(result.temporalDecodeFlagCount, 1)
        XCTAssertEqual(result.initializationNoticeCount, 1)
        XCTAssertEqual(result.runtimeNoticeCount, 1)
        XCTAssertEqual(result.initializationSelectedAlgorithm, .appleTemporal)
        XCTAssertEqual(result.runtimeSelectedAlgorithm, .appleTemporal)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testGPUCommandErrorIsTerminalAndTyped() async throws {
        let result = try await harness.runGPUCommandErrorRegression()

        XCTAssertEqual(result.failure?.code, "metal.command")
        XCTAssertEqual(result.successfulPresentationCount, 0)
        XCTAssertEqual(result.commandSubmissionCount, 1)
    }

    func testRapidAppleYADIFSwitchDropsLateWorkBeforeDelivery() throws {
        let result = try harness.runRapidAlgorithmSwitchRegression()

        XCTAssertEqual(result.routes, [.appleTemporal, .metalYADIF2x, .appleTemporal])
        XCTAssertEqual(result.injectedLateCallbackCount, 1)
        XCTAssertEqual(result.staleGenerationDropCount, 1)
        XCTAssertEqual(result.crossGenerationDeliveryCount, 0)
    }
}
