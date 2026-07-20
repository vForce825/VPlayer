// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class VideoPipelineCoordinatorTests: XCTestCase {
    func testRouteTableIsCompleteAndNeverDeinterlacesProgressiveOrPsF() {
        let top = ResolvedFieldOrder(
            parity: .top,
            confidence: .signaled,
            source: .parser
        )

        for algorithm in DeinterlaceAlgorithm.allCases {
            XCTAssertEqual(
                DeinterlaceRoute.resolve(scan: .unknown, selected: algorithm),
                .rawWhileClassifying
            )
            XCTAssertEqual(
                DeinterlaceRoute.resolve(scan: .progressive, selected: algorithm),
                .bypass
            )
            XCTAssertEqual(
                DeinterlaceRoute.resolve(
                    scan: .progressiveSegmentedFrame(top),
                    selected: algorithm
                ),
                .bypass
            )
        }

        XCTAssertEqual(
            DeinterlaceRoute.resolve(scan: .interlaced(top), selected: .appleTemporal),
            .appleTemporal
        )
        XCTAssertEqual(
            DeinterlaceRoute.resolve(scan: .interlaced(top), selected: .metalYADIF2x),
            .metalYADIF2x
        )
    }

    func testInitialFormatWaitsForIDRAndUnknownRawPresentationDoesNotWaitForProbe() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: false
        ))
        XCTAssertFalse(harness.decoder.snapshot().contains { operation in
            if case .decode = operation { return true }
            return false
        })

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(generation, .bothFields),
            .decode(2, generation, ._EnableAsynchronousDecompression),
        ])

        for id in 10...12 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        XCTAssertEqual(harness.coordinator.requiredVideoFrameCount, 1)
        XCTAssertEqual(harness.probe.pendingCount, 2)
        XCTAssertEqual(harness.host.deliveredFrames.count, 1)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testProgressiveAlgorithmChangeDoesNotRebuildAdvanceFlushOrDispatch() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: progressiveParser(sourcePTS90k: 36_000)
        )))
        XCTAssertEqual(harness.coordinator.route, .bypass)

        let decoderBefore = harness.decoder.snapshot()
        let operationsBefore = harness.host.operations
        let generationBefore = harness.host.generation
        harness.coordinator.setAlgorithm(.metalYADIF2x)

        XCTAssertEqual(harness.coordinator.route, .bypass)
        XCTAssertEqual(harness.host.generation, generationBefore)
        XCTAssertEqual(harness.decoder.snapshot(), decoderBefore)
        XCTAssertEqual(harness.host.operations, operationsBefore)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testInterlacedAppleAndYADIFSwitchesUseOneOrderedDrainAndIDRGate() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.trace.removeAll()

        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        generation = harness.host.generation
        XCTAssertEqual(harness.coordinator.route, .appleTemporal)
        XCTAssertEqual(generation, MediaGeneration(rawValue: 2))
        XCTAssertEqual(harness.trace.values, [
            "host.close",
            "decoder.finish",
            "decoder.wait",
            "host.advance:2",
            "host.reset:2:1",
            "decoder.invalidate",
            "host.open",
        ])

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case let .decode(id, _, _) = $0 { return id == 2 }
            return false
        })
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(generation, .appleTemporal),
            .decode(3, generation, ._EnableAsynchronousDecompression),
        ])

        harness.trace.removeAll()
        harness.coordinator.setAlgorithm(.metalYADIF2x)
        generation = harness.host.generation
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertEqual(generation, MediaGeneration(rawValue: 3))
        XCTAssertEqual(harness.trace.values, [
            "host.close",
            "decoder.finish",
            "decoder.wait",
            "host.advance:3",
            "host.reset:3:3",
            "decoder.invalidate",
            "host.open",
        ])
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 4,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(generation, .bothFields),
            .decode(4, generation, ._EnableAsynchronousDecompression),
        ])
    }

    func testSupplementalProbeDoesNotDoubleCountProgressiveFrame() throws {
        let harness = makeHarness(classifierConfiguration: ScanClassifierConfiguration(
            progressiveConfirmationFrames: 3,
            psfConfirmationFrames: 3,
            exitInterlacedConfirmationFrames: 3
        ))
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: progressiveParser(sourcePTS90k: 36_000)
        )))
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 11,
            generation: generation,
            parser: progressiveParser(sourcePTS90k: 39_600)
        )))
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        harness.probe.completeFirst(.success(ContentProbeSample(
            combRatio: 0,
            motionRatio: 0,
            sampleCount: 2_304
        )))
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)

        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 12,
            generation: generation,
            parser: progressiveParser(sourcePTS90k: 43_200)
        )))
        XCTAssertEqual(harness.coordinator.route, .bypass)
    }

    func testPsFProbeEvidenceBypassesBothDeinterlacers() throws {
        let harness = makeHarness(classifierConfiguration: ScanClassifierConfiguration(
            progressiveConfirmationFrames: 3,
            psfConfirmationFrames: 2,
            exitInterlacedConfirmationFrames: 3
        ))
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        for id in 10...12 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: fieldSignalledParser(sourcePTS90k: UInt64(id * 3_600))
            )))
            if id > 10 {
                harness.probe.completeFirst(.success(ContentProbeSample(
                    combRatio: 0.01,
                    motionRatio: 0.02,
                    sampleCount: 2_304
                )))
            }
        }

        XCTAssertEqual(harness.coordinator.route, .bypass)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertFalse(harness.decoder.snapshot().contains {
            if case .configure(_, .appleTemporal) = $0 { return true }
            return false
        })
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testTemporalConfigureFailureUsesBothFieldsOnSameIDRAndNotifiesOnce() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.temporalConfigureFailures = [
            .temporalUnavailable(.unsupportedProperty("temporal-level")),
        ]
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        generation = harness.host.generation

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))

        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(harness.coordinator.route, .rawTemporalFailure)
        XCTAssertEqual(
            harness.coordinator.selectedDeinterlaceAlgorithm,
            .appleTemporal
        )
        XCTAssertEqual(harness.decoder.snapshot().suffix(3), [
            .configure(generation, .appleTemporal),
            .configure(generation, .bothFields),
            .decode(2, generation, ._EnableAsynchronousDecompression),
        ])
        XCTAssertEqual(harness.host.notices.map(\.0), [.appleTemporalUnavailable])
        XCTAssertEqual(harness.host.notices.map(\.1), [generation])
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testTemporalRuntimeFailureRebuildsRawOnceAndAwayBackReenablesAttempt() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().last, .decode(
            2,
            generation,
            ._EnableAsynchronousDecompression
        ))

        let failedGeneration = generation
        harness.trace.removeAll()
        harness.coordinator.handle(decoder: .recoverableFailure(
            .temporalUnavailable(.processingFailed(status: -71)),
            generation: failedGeneration
        ))
        generation = harness.host.generation
        XCTAssertEqual(generation.rawValue, failedGeneration.rawValue + 1)
        XCTAssertEqual(harness.coordinator.route, .rawTemporalFailure)
        XCTAssertEqual(harness.trace.values, [
            "host.close",
            "decoder.finish",
            "decoder.wait",
            "host.advance:\(generation.rawValue)",
            "host.reset:\(generation.rawValue):1",
            "decoder.invalidate",
            "host.open",
        ])
        XCTAssertEqual(harness.host.notices.map(\.0), [.appleTemporalUnavailable])
        XCTAssertTrue(harness.host.failures.isEmpty)

        harness.coordinator.handle(decoder: .recoverableFailure(
            .temporalUnavailable(.processingFailed(status: -72)),
            generation: failedGeneration
        ))
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(harness.host.notices.count, 1)

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(generation, .bothFields),
            .decode(3, generation, ._EnableAsynchronousDecompression),
        ])

        harness.coordinator.setAlgorithm(.metalYADIF2x)
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        let beforeRetry = harness.host.generation
        harness.coordinator.setAlgorithm(.appleTemporal)
        generation = harness.host.generation
        XCTAssertEqual(generation.rawValue, beforeRetry.rawValue + 1)
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 4,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(generation, .appleTemporal),
            .decode(4, generation, ._EnableAsynchronousDecompression),
        ])
        XCTAssertEqual(harness.host.notices.count, 1)
    }

    func testNormalStopWaitsBeforeInvalidateWhileEmergencyAdvancesWithoutWaiting() throws {
        let normal = makeHarness()
        normal.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let normalGeneration = normal.host.generation
        normal.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: normalGeneration,
            randomAccess: true
        ))
        normal.trace.removeAll()
        normal.coordinator.stop(emergency: false)
        normal.coordinator.stop(emergency: false)
        XCTAssertEqual(normal.trace.values, [
            "host.close",
            "decoder.finish",
            "decoder.wait",
            "decoder.invalidate",
        ])
        XCTAssertEqual(normal.host.generation, normalGeneration)

        let emergency = makeHarness()
        emergency.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let oldGeneration = emergency.host.generation
        emergency.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: oldGeneration,
            randomAccess: true
        ))
        emergency.trace.removeAll()
        emergency.coordinator.stop(emergency: true)
        let newGeneration = emergency.host.generation
        XCTAssertEqual(newGeneration.rawValue, oldGeneration.rawValue + 1)
        XCTAssertEqual(emergency.trace.values, [
            "host.close",
            "host.advance:\(newGeneration.rawValue)",
            "host.reset:\(newGeneration.rawValue):1",
            "decoder.invalidate",
        ])
        XCTAssertFalse(emergency.decoder.snapshot().suffix(4).contains(.finish))
        XCTAssertFalse(emergency.decoder.snapshot().suffix(4).contains(.wait))
    }

    func testNormalStopDropsPendingProcessorAndProbeCompletions() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.passthrough.setAutomaticallyCompletes(false)
        for id in 10...12 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertEqual(harness.probe.pendingCount, 2)

        harness.coordinator.stop(emergency: false)
        harness.passthrough.completePending()
        harness.probe.completeFirst(.success(ContentProbeSample(
            combRatio: 0.2,
            motionRatio: 0.2,
            sampleCount: 2_304
        )))

        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testConfirmedBottomOrderReachesNormalizedYADIFAndSameGenerationStaleWorkDrops() throws {
        let harness = makeHarness(algorithm: .metalYADIF2x)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.passthrough.setAutomaticallyCompletes(false)

        for id in 10...12 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }
        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)

        for id in 13...16 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: interlacedParser(
                    parity: .bottom,
                    sourcePTS90k: UInt64(id * 3_600)
                )
            )))
        }
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertFalse(harness.yadif.submissions.isEmpty)
        XCTAssertTrue(harness.yadif.submissions.allSatisfy {
            $0.order.parity == .bottom
                && $0.order.confidence == .signaled
                && $0.order.source == .parser
        })

        harness.passthrough.completePending()
        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
        harness.probe.completeFirst(.success(ContentProbeSample(
            combRatio: 0,
            motionRatio: 0,
            sampleCount: 2_304
        )))
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testFormatLevelFieldOrderFeedsYADIFWhenPixelAttachmentsAreAbsent() throws {
        let harness = makeHarness(algorithm: .metalYADIF2x)
        let format = try VideoTestFactories.formatDescription(
            fieldCount: number(2),
            detail: kCVImageBufferFieldDetailTemporalBottomFirst
        )
        harness.coordinator.replaceFormat(format)
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        for id in 10...14 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
            if id == 11 {
                harness.probe.completeFirst(.success(ContentProbeSample(
                    combRatio: 0.2,
                    motionRatio: 0.2,
                    sampleCount: 2_304
                )))
            }
        }

        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertFalse(harness.yadif.submissions.isEmpty)
        XCTAssertTrue(harness.yadif.submissions.allSatisfy {
            $0.order.parity == .bottom
                && $0.order.source == .formatDescription
        })
    }

    func testPendingIDRAlgorithmChangeRetargetsWithoutSecondGeneration() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let firstGeneration = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: firstGeneration,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: firstGeneration,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        let pendingGeneration = harness.host.generation
        XCTAssertEqual(pendingGeneration.rawValue, firstGeneration.rawValue + 1)

        harness.coordinator.setAlgorithm(.metalYADIF2x)
        XCTAssertEqual(harness.host.generation, pendingGeneration)
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: pendingGeneration,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(pendingGeneration, .bothFields),
            .decode(2, pendingGeneration, ._EnableAsynchronousDecompression),
        ])

        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 99,
            generation: firstGeneration,
            parser: unknownParser(sourcePTS90k: 99_000)
        )))
        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
    }

    func testNonTemporalDecoderFailureIsTerminalAndNoticeFree() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        harness.coordinator.handle(decoder: .fatalFailure(
            .sessionCreate(-81),
            generation: generation
        ))

        XCTAssertEqual(harness.host.failures.map(\.0), [.videoDecode(-81)])
        XCTAssertEqual(harness.host.failures.map(\.1), [generation])
        XCTAssertTrue(harness.host.notices.isEmpty)
        XCTAssertNotEqual(harness.coordinator.route, .rawTemporalFailure)
    }

    func testSynchronousTemporalDecodeFailureUsesOrderedRawFallback() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [
            .temporalUnavailable(.processingFailed(status: -91)),
        ]
        let failedGeneration = generation
        harness.trace.removeAll()

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: failedGeneration,
            randomAccess: false
        ))

        generation = harness.host.generation
        XCTAssertEqual(generation.rawValue, failedGeneration.rawValue + 1)
        XCTAssertEqual(harness.coordinator.route, .rawTemporalFailure)
        XCTAssertEqual(harness.host.notices.map(\.0), [.appleTemporalUnavailable])
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.trace.values.suffix(7), [
            "host.close",
            "decoder.finish",
            "decoder.wait",
            "host.advance:\(generation.rawValue)",
            "host.reset:\(generation.rawValue):1",
            "decoder.invalidate",
            "host.open",
        ])
    }

    func testTrueFormatChangeToleratesTemporalDrainFailuresAndContinuesBothFields() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.finishFailures = [
            .temporalUnavailable(.processingFailed(status: -92)),
        ]
        harness.decoder.waitFailures = [
            .temporalUnavailable(.processingFailed(status: -93)),
        ]
        let oldGeneration = generation
        harness.trace.removeAll()

        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())

        generation = harness.host.generation
        XCTAssertEqual(generation.rawValue, oldGeneration.rawValue + 1)
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.notices.map(\.0), [.appleTemporalUnavailable])
        XCTAssertTrue(harness.trace.values.contains("decoder.finish"))
        XCTAssertTrue(harness.trace.values.contains("decoder.wait"))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(generation, .bothFields),
            .decode(3, generation, ._EnableAsynchronousDecompression),
        ])
    }

    func testTemporalDrainFailureWhileSwitchingAwayStillReachesYADIF() throws {
        let harness = makeHarness(algorithm: .appleTemporal)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.coordinator.handle(decoder: .frame(try decodedFrame(
            id: 10,
            generation: generation,
            parser: interlacedParser(parity: .top, sourcePTS90k: 36_000)
        )))
        generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.waitFailures = [
            .temporalUnavailable(.processingFailed(status: -94)),
        ]
        let oldGeneration = generation

        harness.coordinator.setAlgorithm(.metalYADIF2x)

        generation = harness.host.generation
        XCTAssertEqual(generation.rawValue, oldGeneration.rawValue + 1)
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.notices.map(\.0), [.appleTemporalUnavailable])
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: true
        ))
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(generation, .bothFields),
            .decode(3, generation, ._EnableAsynchronousDecompression),
        ])
    }

    func testLateAsynchronousYADIFCompletionDropsAfterRouteGenerationSwitch() throws {
        let harness = makeHarness(algorithm: .metalYADIF2x)
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let oldGeneration = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: oldGeneration,
            randomAccess: true
        ))
        for id in 10...14 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: oldGeneration,
                parser: interlacedParser(
                    parity: .top,
                    sourcePTS90k: UInt64(id * 3_600)
                )
            )))
        }
        XCTAssertGreaterThan(harness.yadif.pendingCompletionCount, 0)
        let staleCompletionCount = harness.yadif.pendingCompletionCount

        harness.coordinator.setAlgorithm(.appleTemporal)
        XCTAssertGreaterThan(harness.host.generation, oldGeneration)
        harness.yadif.completeAll()

        XCTAssertTrue(harness.host.deliveredFrames.isEmpty)
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(
            harness.metrics.snapshot(window: .seconds(60)).staleGenerationDropCount,
            UInt64(staleCompletionCount)
        )
    }

    private func makeHarness(
        algorithm: DeinterlaceAlgorithm = .appleTemporal,
        classifierConfiguration: ScanClassifierConfiguration = ScanClassifierConfiguration(
            progressiveConfirmationFrames: 1,
            psfConfirmationFrames: 1,
            exitInterlacedConfirmationFrames: 1
        )
    ) -> CoordinatorHarness {
        let trace = CoordinatorTrace()
        let decoder = RecordingCoordinatorDecoder(trace: trace)
        let passthrough = FakePipelineVideoProcessor()
        let yadif = FakeCoordinatorYADIFProcessor()
        let probe = FakeCoordinatorProbe()
        let host = CoordinatorHost(trace: trace)
        let metrics = PlaybackMetrics(
            selectedAlgorithm: algorithm,
            channelID: "channel",
            now: { 60 },
            residentMemoryProvider: { 1 }
        )
        let coordinator = VideoPipelineCoordinator(
            decoder: decoder,
            passthrough: passthrough,
            yadif: yadif,
            probe: probe,
            initialGeneration: host.generation,
            selectedAlgorithm: algorithm,
            classifierConfiguration: classifierConfiguration,
            metrics: metrics,
            hooks: host.hooks
        )
        return CoordinatorHarness(
            coordinator: coordinator,
            decoder: decoder,
            passthrough: passthrough,
            yadif: yadif,
            probe: probe,
            host: host,
            metrics: metrics,
            trace: trace
        )
    }

    private func decodedFrame(
        id: UInt64,
        generation: MediaGeneration,
        parser: VideoParserMetadata
    ) throws -> DecodedVideoFrame {
        let base = try PlaybackFakeMedia.decodedFrame(
            id: id,
            generation: generation,
            pts: CMTime(value: Int64(id), timescale: 25),
            interlaced: false
        )
        return DecodedVideoFrame(
            accessUnitID: base.accessUnitID,
            pixelBuffer: base.pixelBuffer,
            presentationTimeStamp: base.presentationTimeStamp,
            duration: base.duration,
            generation: base.generation,
            parserMetadata: parser,
            formatMetadata: base.formatMetadata
        )
    }

    private func unknownParser(sourcePTS90k: UInt64?) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: nil,
            pictureStructure: .frame,
            isInterlaced: nil,
            repeatFirstField: false,
            topFieldFirst: nil,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func progressiveParser(sourcePTS90k: UInt64?) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: .progressive,
            pictureStructure: .frame,
            isInterlaced: false,
            repeatFirstField: false,
            topFieldFirst: nil,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func interlacedParser(
        parity: FieldParity,
        sourcePTS90k: UInt64?
    ) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: parity == .top ? .tt : .bb,
            pictureStructure: parity == .top ? .topField : .bottomField,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: parity == .top,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func fieldSignalledParser(sourcePTS90k: UInt64?) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: .tt,
            pictureStructure: .frame,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: true,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func number(_ value: Int32) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value)
    }
}

private struct CoordinatorHarness {
    let coordinator: VideoPipelineCoordinator
    let decoder: RecordingCoordinatorDecoder
    let passthrough: FakePipelineVideoProcessor
    let yadif: FakeCoordinatorYADIFProcessor
    let probe: FakeCoordinatorProbe
    let host: CoordinatorHost
    let metrics: PlaybackMetrics
    let trace: CoordinatorTrace
}

private final class CoordinatorHost: @unchecked Sendable {
    private let trace: CoordinatorTrace
    private(set) var generation = MediaGeneration(rawValue: 0)
    private(set) var deliveredFrames: [VideoPresentationFrame] = []
    private(set) var notices: [(PlaybackNotice, MediaGeneration)] = []
    private(set) var failures: [(PlaybackCoreError, MediaGeneration)] = []
    private(set) var requiredVideoFrameCounts: [Int] = []
    private(set) var operations: [String] = []

    init(trace: CoordinatorTrace) {
        self.trace = trace
    }

    var hooks: VideoPipelineCoordinatorHooks {
        VideoPipelineCoordinatorHooks(
            closeAdmission: { [weak self] in
                self?.operations.append("close")
                self?.trace.append("host.close")
            },
            advanceGeneration: { [weak self] in
                guard let self else { return MediaGeneration(rawValue: 0) }
                generation = MediaGeneration(rawValue: generation.rawValue + 1)
                operations.append("advance:\(generation.rawValue)")
                trace.append("host.advance:\(generation.rawValue)")
                return generation
            },
            resetPlayback: { [weak self] generation, requiredCount in
                self?.operations.append("reset:\(generation.rawValue):\(requiredCount)")
                self?.trace.append("host.reset:\(generation.rawValue):\(requiredCount)")
            },
            reopenAdmission: { [weak self] in
                self?.operations.append("open")
                self?.trace.append("host.open")
            },
            routeDidChange: { [weak self] requiredCount in
                self?.requiredVideoFrameCounts.append(requiredCount)
            },
            deliver: { [weak self] frames, _ in
                self?.deliveredFrames.append(contentsOf: frames)
            },
            notice: { [weak self] notice, generation in
                self?.notices.append((notice, generation))
            },
            fail: { [weak self] failure, generation in
                self?.failures.append((failure, generation))
            },
            schedule: { operation in operation() }
        )
    }
}

private final class CoordinatorTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    func removeAll() { lock.withLock { storage.removeAll(keepingCapacity: true) } }
}

private final class RecordingCoordinatorDecoder: VideoDecoding, @unchecked Sendable {
    enum Operation: Equatable {
        case configure(MediaGeneration, VideoDecodeConfiguration)
        case decode(UInt64, MediaGeneration, VTDecodeFrameFlags)
        case finish
        case wait
        case invalidate
    }

    private let lock = NSLock()
    private let trace: CoordinatorTrace
    private var operations: [Operation] = []
    var temporalConfigureFailures: [VideoDecoderFailure] = []
    var decodeFailures: [VideoDecoderFailure] = []
    var finishFailures: [VideoDecoderFailure] = []
    var waitFailures: [VideoDecoderFailure] = []

    init(trace: CoordinatorTrace) {
        self.trace = trace
    }

    func configure(
        format _: CMVideoFormatDescription,
        generation: MediaGeneration,
        configuration: VideoDecodeConfiguration
    ) throws {
        lock.withLock { operations.append(.configure(generation, configuration)) }
        trace.append("decoder.configure:\(generation.rawValue):\(configuration)")
        if configuration == .appleTemporal, !temporalConfigureFailures.isEmpty {
            throw temporalConfigureFailures.removeFirst()
        }
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags: VTDecodeFrameFlags) throws {
        lock.withLock {
            operations.append(.decode(accessUnit.id, accessUnit.generation, flags))
        }
        trace.append("decoder.decode:\(accessUnit.id):\(accessUnit.generation.rawValue)")
        if !decodeFailures.isEmpty { throw decodeFailures.removeFirst() }
    }

    func finishDelayedFrames() throws {
        lock.withLock { operations.append(.finish) }
        trace.append("decoder.finish")
        if !finishFailures.isEmpty { throw finishFailures.removeFirst() }
    }

    func waitForAsynchronousFrames() throws {
        lock.withLock { operations.append(.wait) }
        trace.append("decoder.wait")
        if !waitFailures.isEmpty { throw waitFailures.removeFirst() }
    }

    func invalidate() {
        lock.withLock { operations.append(.invalidate) }
        trace.append("decoder.invalidate")
    }

    func snapshot() -> [Operation] { lock.withLock { operations } }
}

private final class FakeCoordinatorProbe: LumaScanProbing, @unchecked Sendable {
    struct Pending: @unchecked Sendable {
        let generation: MediaGeneration
        let completion: @Sendable (Result<ContentProbeSample, LumaScanProbeFailure>) -> Void
    }

    private(set) var pending: [Pending] = []
    private(set) var stopped: [MediaGeneration] = []
    var pendingCount: Int { pending.count }

    func submit(
        current _: CVPixelBuffer,
        previous _: CVPixelBuffer,
        generation: MediaGeneration,
        completion: @escaping @Sendable (
            Result<ContentProbeSample, LumaScanProbeFailure>
        ) -> Void
    ) {
        pending.append(Pending(generation: generation, completion: completion))
    }

    func stop(generation: MediaGeneration) {
        stopped.append(generation)
    }


    func completeFirst(
        _ result: Result<ContentProbeSample, LumaScanProbeFailure>
    ) {
        let item = pending.removeFirst()
        item.completion(result)
    }
}

private final class FakeCoordinatorYADIFProcessor: YADIFFrameProcessing, @unchecked Sendable {
    struct Submission: @unchecked Sendable {
        let frame: NormalizedDecodedFrame
        let order: ResolvedFieldOrder
    }

    private(set) var resets: [MediaGeneration] = []
    private(set) var submissions: [Submission] = []
    private var pendingCompletions: [@Sendable (
        Result<[VideoPresentationFrame], PlaybackFailure>
    ) -> Void] = []
    var pendingCompletionCount: Int { pendingCompletions.count }

    func reset(to generation: MediaGeneration) {
        resets.append(generation)
    }

    func submit(
        normalized frame: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity _: Bool,
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        submissions.append(Submission(frame: frame, order: order))
        pendingCompletions.append(completion)
    }

    func drain(
        completion: @escaping @Sendable (
            Result<[VideoPresentationFrame], PlaybackFailure>
        ) -> Void
    ) {
        completion(.success([]))
    }

    func completeAll() {
        let pending = pendingCompletions
        let frames = submissions.suffix(pending.count).enumerated().map { offset, item in
            VideoPresentationFrame(
                storage: .pixelBuffer(item.frame.frame.pixelBuffer),
                presentationTimeStamp: item.frame.presentationTimeStamp,
                duration: item.frame.fieldDuration,
                generation: item.frame.frame.generation,
                sequenceNumber: UInt64(offset + 1),
                sourceAccessUnitID: item.frame.frame.accessUnitID,
                formatMetadata: item.frame.frame.formatMetadata
            )
        }
        pendingCompletions.removeAll(keepingCapacity: true)
        for (completion, frame) in zip(pending, frames) {
            completion(.success([frame]))
        }
    }
}
