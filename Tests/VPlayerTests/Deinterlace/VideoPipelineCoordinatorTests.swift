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

        XCTAssertEqual(DeinterlaceRoute.resolve(scan: .unknown), .rawWhileClassifying)
        XCTAssertEqual(DeinterlaceRoute.resolve(scan: .progressive), .bypass)
        XCTAssertEqual(
            DeinterlaceRoute.resolve(scan: .progressiveSegmentedFrame(top)),
            .bypass
        )
        XCTAssertEqual(
            DeinterlaceRoute.resolve(scan: .interlaced(top)),
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
            .configure(generation),
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
        XCTAssertEqual(harness.probe.pendingCount, 1)
        XCTAssertEqual(harness.host.deliveredFrames.count, 1)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testHandleReturnsTrueOnlyWhenAccessUnitReachesDecoder() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation

        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: false
        )))
        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: MediaGeneration(rawValue: generation.rawValue - 1),
            randomAccess: true
        )))
        XCTAssertTrue(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: true
        )))

        harness.decoder.decodeFailures = [.badData(kVTVideoDecoderBadDataErr)]
        XCTAssertFalse(harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 4,
            generation: generation,
            randomAccess: false
        )))
    }

    func testSubmissionCompletionDoesNotChangeCoordinatorState() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        let operations = harness.decoder.snapshot()
        let hostOperations = harness.host.operations

        harness.coordinator.handle(decoder: .submissionCompleted(
            accessUnitID: 9,
            generation: generation
        ))

        XCTAssertEqual(harness.decoder.snapshot(), operations)
        XCTAssertEqual(harness.host.operations, hostOperations)
        XCTAssertTrue(harness.host.failures.isEmpty)
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
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
    }

    func testFailedProbeConservativelyRoutesFieldSignalledFramesToSelectedDeinterlacer() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        for id in 10...11 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: fieldSignalledParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        harness.probe.completeFirst(.failure(.nonIOSurfaceInput))

        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testThreeUnresolvedProbesConservativelyRouteFieldSignalledFrames() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        for id in 10...13 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: fieldSignalledParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        XCTAssertEqual(harness.probe.pendingCount, 1)
        XCTAssertEqual(harness.coordinator.route, .metalYADIF2x)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testThreeInconclusiveProbeAttemptsReleaseUnknownSourceThroughBypass() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        for id in 10...13 {
            harness.coordinator.handle(decoder: .frame(try decodedFrame(
                id: UInt64(id),
                generation: generation,
                parser: unknownParser(sourcePTS90k: UInt64(id * 3_600))
            )))
        }

        XCTAssertEqual(harness.probe.pendingCount, 1)
        XCTAssertEqual(harness.coordinator.route, .bypass)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertTrue(harness.yadif.submissions.isEmpty)
        XCTAssertTrue(harness.host.failures.isEmpty)
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
        XCTAssertEqual(harness.probe.pendingCount, 1)

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
        let harness = makeHarness()
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

    func testFatalDecoderFailureIsTerminal() throws {
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
    }

    func testRecoverableDecoderFailureDropsOnlyThatFrame() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))

        harness.coordinator.handle(decoder: .recoverableFailure(
            .badData(kVTVideoDecoderBadDataErr),
            generation: generation
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(2, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testRecoverableSynchronousDecodeFailureDropsOnlyThatAccessUnit() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [
            .badData(kVTVideoDecoderReferenceMissingErr),
        ]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.generation, generation)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(3, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testSessionMalfunctionRebuildsTheDecoderInsteadOfDroppingEveryFrame() throws {
        for status in [
            kVTVideoDecoderMalfunctionErr,
            kVTSessionMalfunctionErr,
            kVTVideoDecoderNotAvailableNowErr,
            kVTVideoDecoderRemovedErr,
        ] {
            let harness = makeHarness()
            harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
            let oldGeneration = harness.host.generation
            harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
                id: 1,
                generation: oldGeneration,
                randomAccess: true
            ))
            harness.decoder.decodeFailures = [.malfunction(status)]

            harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
                id: 2,
                generation: oldGeneration,
                randomAccess: false
            ))

            // A malfunctioning session fails every later submission the same way,
            // so counting this as one more dropped frame froze video for good
            // while access units kept arriving.
            XCTAssertGreaterThan(harness.host.generation, oldGeneration)
            XCTAssertTrue(harness.host.failures.isEmpty)
            XCTAssertEqual(harness.decoder.snapshot().last, .invalidate)
        }
    }

    func testUnrecoverableSessionMalfunctionIsReportedRatherThanRestartedForever() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        var identifier: UInt64 = 1
        for _ in 0...8 where harness.host.failures.isEmpty {
            harness.decoder.decodeFailures = [.malfunction(kVTVideoDecoderMalfunctionErr)]
            harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
                id: identifier,
                generation: harness.host.generation,
                randomAccess: true
            ))
            identifier += 1
        }

        // Restarting is bounded: a session that never comes back has to surface
        // as a real failure instead of silently discarding every frame.
        XCTAssertFalse(harness.host.failures.isEmpty)
    }

    func testDecodeBackpressureTimeoutRebuildsAtNextRandomAccessWithoutDrainingStalledSession() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let oldGeneration = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: oldGeneration,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [.backpressureTimeout]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: oldGeneration,
            randomAccess: false
        ))

        let newGeneration = harness.host.generation
        XCTAssertGreaterThan(newGeneration, oldGeneration)
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(harness.host.operations.suffix(4), [
            "close",
            "advance:\(newGeneration.rawValue)",
            "reset:\(newGeneration.rawValue):1",
            "open",
        ])
        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .decode(2, oldGeneration, ._EnableAsynchronousDecompression),
            .invalidate,
        ])

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: newGeneration,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 4,
            generation: newGeneration,
            randomAccess: true
        ))

        XCTAssertEqual(harness.decoder.snapshot().suffix(2), [
            .configure(newGeneration),
            .decode(4, newGeneration, ._EnableAsynchronousDecompression),
        ])
    }

    func testLegacyCodecBadDataSynchronousFailureDropsOnlyThatAccessUnit() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [.badData(-8_969)]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(3, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testObservedPositiveStatusSynchronousFailureDropsOnlyThatAccessUnit() throws {
        let harness = makeHarness()
        harness.coordinator.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let generation = harness.host.generation
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 1,
            generation: generation,
            randomAccess: true
        ))
        harness.decoder.decodeFailures = [.badData(1)]

        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 2,
            generation: generation,
            randomAccess: false
        ))
        harness.coordinator.handle(accessUnit: try PlaybackFakeMedia.accessUnit(
            id: 3,
            generation: generation,
            randomAccess: false
        ))

        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertEqual(
            harness.decoder.snapshot().last,
            .decode(3, generation, ._EnableAsynchronousDecompression)
        )
    }

    func testLegacyCodecBadDataDrainFailureDoesNotBlockADiscontinuityReset() throws {
        let harness = makeHarness()
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
        harness.decoder.finishFailures = [.badData(-8_969)]
        let oldGeneration = generation

        harness.coordinator.beginDiscontinuity()

        generation = harness.host.generation
        XCTAssertEqual(generation.rawValue, oldGeneration.rawValue + 1)
        XCTAssertEqual(harness.coordinator.route, .rawWhileClassifying)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testLateAsynchronousYADIFCompletionDropsAfterAGenerationSwitch() throws {
        let harness = makeHarness()
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

        harness.coordinator.beginDiscontinuity()
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
            resetPlayback: { [weak self] generation, requiredCount, _ in
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
        case configure(MediaGeneration)
        case decode(UInt64, MediaGeneration, VTDecodeFrameFlags)
        case finish
        case wait
        case invalidate
    }

    private let lock = NSLock()
    private let trace: CoordinatorTrace
    private var operations: [Operation] = []
    var configureFailures: [VideoDecoderFailure] = []
    var decodeFailures: [VideoDecoderFailure] = []
    var finishFailures: [VideoDecoderFailure] = []
    var waitFailures: [VideoDecoderFailure] = []

    init(trace: CoordinatorTrace) {
        self.trace = trace
    }

    func configure(
        format _: CMVideoFormatDescription,
        generation: MediaGeneration
    ) throws {
        lock.withLock { operations.append(.configure(generation)) }
        trace.append("decoder.configure:\(generation.rawValue)")
        if !configureFailures.isEmpty { throw configureFailures.removeFirst() }
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
