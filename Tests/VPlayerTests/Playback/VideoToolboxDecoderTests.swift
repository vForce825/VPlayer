// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class VideoToolboxDecoderTests: XCTestCase {
    func testBothFieldsConfigurationUsesExactHardwareAndImageProperties() throws {
        let harness = makeHarness()

        try configure(harness, generation: 3)

        let snapshot = harness.api.snapshot
        XCTAssertEqual(snapshot.operations, ["create", "set", "copy"])
        XCTAssertEqual(snapshot.creates.count, 1)
        XCTAssertEqual(snapshot.creates.first?.decoderSpecification, [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: .boolean(true),
        ])
        XCTAssertEqual(snapshot.creates.first?.imageBufferAttributes, [
            kCVPixelBufferMetalCompatibilityKey as String: .boolean(true),
            kCVPixelBufferIOSurfacePropertiesKey as String: .dictionary([:]),
            kCVPixelBufferPixelFormatTypeKey as String: .array([
                .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
            ]),
        ])
        XCTAssertEqual(snapshot.sets, [FakeVideoToolboxAPI.PropertyRecord(
            sessionID: VTSessionID(rawValue: 1),
            key: kVTDecompressionPropertyKey_FieldMode as String,
            value: .string(kVTDecompressionProperty_FieldMode_BothFields as String)
        )])
        XCTAssertEqual(snapshot.copies, [FakeVideoToolboxAPI.CopyRecord(
            sessionID: VTSessionID(rawValue: 1),
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder as String
        )])
    }

    func testBothFieldsAcceptsUnsupportedOptionalFieldModeProperty() throws {
        let harness = makeHarness()
        harness.api.enqueueSetStatus(kVTPropertyNotSupportedErr)

        XCTAssertNoThrow(try configure(harness, generation: 3))

        XCTAssertEqual(harness.api.snapshot.operations, ["create", "set", "copy"])
        try decode(harness, id: 7, generation: 3)
        XCTAssertEqual(harness.api.snapshot.decodes.count, 1)
    }

    func testAppleTemporalConfigurationUsesExactCandidateOperationOrderAndProperties() throws {
        let harness = makeHarness()

        try configure(harness, generation: 3, configuration: .appleTemporal)

        let snapshot = harness.api.snapshot
        XCTAssertEqual(snapshot.operations, ["create", "supported", "set", "set", "copy"])
        XCTAssertEqual(snapshot.creates.first?.decoderSpecification, [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: .boolean(true),
        ])
        XCTAssertEqual(snapshot.creates.first?.imageBufferAttributes, [
            kCVPixelBufferMetalCompatibilityKey as String: .boolean(true),
            kCVPixelBufferIOSurfacePropertiesKey as String: .dictionary([:]),
            kCVPixelBufferPixelFormatTypeKey as String: .array([
                .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                .unsigned32(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
            ]),
        ])
        XCTAssertEqual(snapshot.supportedPropertyQueries, [VTSessionID(rawValue: 1)])
        XCTAssertEqual(snapshot.sets, [
            .init(
                sessionID: VTSessionID(rawValue: 1),
                key: kVTDecompressionPropertyKey_FieldMode as String,
                value: .string(kVTDecompressionProperty_FieldMode_DeinterlaceFields as String)
            ),
            .init(
                sessionID: VTSessionID(rawValue: 1),
                key: kVTDecompressionPropertyKey_DeinterlaceMode as String,
                value: .string(kVTDecompressionProperty_DeinterlaceMode_Temporal as String)
            ),
        ])
        XCTAssertEqual(snapshot.copies, [.init(
            sessionID: VTSessionID(rawValue: 1),
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder as String
        )])
    }

    func testUnsupportedCodecFailsBeforeAPIAndPreservesActiveSession() throws {
        let harness = makeHarness()
        try configure(harness, generation: 1)
        let unsupported = try makeFormat(codec: kCMVideoCodecType_JPEG)

        assertFailure(.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr)) {
            try perform(on: harness.executor) {
                try harness.decoder.configure(
                    format: unsupported,
                    generation: MediaGeneration(rawValue: 2),
                    configuration: .bothFields
                )
            }
        }

        XCTAssertEqual(harness.api.snapshot.operations, ["create", "set", "copy"])
        try decode(harness, id: 11, generation: 1)
        XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 1))
    }

    func testCandidateCreateSetAndCopyFailuresInvalidateOnlyCandidateAndPreserveOld() throws {
        struct Scenario {
            let arrange: (FakeVideoToolboxAPI) -> Void
            let expected: VideoDecoderFailure
        }
        let status: OSStatus = -12_345
        let scenarios = [
            Scenario(
                arrange: { $0.enqueueCreate(.init(status: status, returnsSession: true)) },
                expected: .sessionCreate(status)
            ),
            Scenario(
                arrange: { $0.enqueueSetStatus(status) },
                expected: .sessionCreate(status)
            ),
            Scenario(
                arrange: { $0.enqueueCopyResult(.init(status: status, value: nil)) },
                expected: .sessionCreate(status)
            ),
        ]

        for scenario in scenarios {
            let harness = makeHarness()
            try configure(harness, generation: 7)
            scenario.arrange(harness.api)

            assertFailure(scenario.expected) {
                try configure(harness, generation: 8)
            }

            XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 2)])
            try decode(harness, id: 99, generation: 7)
            XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 1))
        }
    }

    func testFalseMissingAndWrongTypeHardwarePropertiesRejectCandidateAndPreserveOld() throws {
        let rejectedValues: [VTPropertyValue?] = [
            .boolean(false),
            nil,
            .unsigned32(1),
            .string("true"),
            .unsupportedType,
        ]

        for value in rejectedValues {
            let harness = makeHarness()
            try configure(harness, generation: 5)
            harness.api.enqueueCopyResult(.init(status: noErr, value: value))

            assertFailure(.softwareDecoder) {
                try configure(harness, generation: 6)
            }

            XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 2)])
            try decode(harness, id: 12, generation: 5)
            XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 1))
        }
    }

    func testSuccessfulCandidateSwapsThenInvalidatesOnlyOldSession() throws {
        let harness = makeHarness()
        try configure(harness, generation: 2)

        try configure(harness, generation: 3)

        XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        try decode(harness, id: 4, generation: 3)
        XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 2))
    }

    func testUnsupportedAppleCodecFailsBeforeAPISideEffectsAndPreservesOldSession() throws {
        let harness = makeHarness()
        try configure(harness, generation: 4)
        let before = harness.api.snapshot
        let replacementFormat = try makeFormat(codec: kCMVideoCodecType_JPEG)

        assertFailure(.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr)) {
            try perform(on: harness.executor) {
                try harness.decoder.configure(
                    format: replacementFormat,
                    generation: MediaGeneration(rawValue: 5),
                    configuration: .appleTemporal
                )
            }
        }

        let after = harness.api.snapshot
        XCTAssertEqual(after.operations, before.operations)
        XCTAssertEqual(after.invalidatedSessionIDs, before.invalidatedSessionIDs)
        try decode(harness, id: 8, generation: 4)
        XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 1))
    }

    func testEveryTemporalInitializationFailureInvalidatesOnlyCandidateAndPreservesOldSession() throws {
        typealias Scenario = (
            expected: AppleTemporalFailure,
            arrange: (FakeVideoToolboxAPI) -> Void
        )
        let fieldModeKey = kVTDecompressionPropertyKey_FieldMode as String
        let deinterlaceModeKey = kVTDecompressionPropertyKey_DeinterlaceMode as String
        let queryStatus: OSStatus = -21_001
        let firstSetStatus: OSStatus = -21_002
        let secondSetStatus: OSStatus = -21_003
        let scenarios: [Scenario] = [
            (
                .initializationFailed(status: queryStatus),
                { $0.enqueueSupportedPropertySnapshot(.init(
                    status: queryStatus,
                    supportedPropertyKeys: [fieldModeKey, deinterlaceModeKey]
                )) }
            ),
            (
                .initializationFailed(status: kVTParameterErr),
                { $0.enqueueSupportedPropertySnapshot(.init(
                    status: noErr,
                    supportedPropertyKeys: nil
                )) }
            ),
            (
                .unsupportedProperty(fieldModeKey),
                { $0.enqueueSupportedPropertySnapshot(.init(
                    status: noErr,
                    supportedPropertyKeys: [deinterlaceModeKey]
                )) }
            ),
            (
                .unsupportedProperty(deinterlaceModeKey),
                { $0.enqueueSupportedPropertySnapshot(.init(
                    status: noErr,
                    supportedPropertyKeys: [fieldModeKey]
                )) }
            ),
            (
                .propertySetFailed(key: fieldModeKey, status: firstSetStatus),
                { $0.enqueueSetStatus(firstSetStatus) }
            ),
            (
                .propertySetFailed(key: deinterlaceModeKey, status: secondSetStatus),
                {
                    $0.enqueueSetStatus(noErr)
                    $0.enqueueSetStatus(secondSetStatus)
                }
            ),
        ]

        for scenario in scenarios {
            let harness = makeHarness()
            try configure(harness, generation: 7)
            scenario.arrange(harness.api)

            assertFailure(.temporalUnavailable(scenario.expected)) {
                try configure(harness, generation: 8, configuration: .appleTemporal)
            }

            XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 2)])
            try decode(harness, id: 99, generation: 7)
            XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 1))
        }
    }

    func testAppleBaseCreateAndHardwareFailuresRemainBaseFailuresAndPreserveOldSession() throws {
        typealias Scenario = (
            expected: VideoDecoderFailure,
            arrange: (FakeVideoToolboxAPI) -> Void
        )
        let createStatus: OSStatus = -22_001
        let copyStatus: OSStatus = -22_002
        let scenarios: [Scenario] = [
            (
                .sessionCreate(createStatus),
                { $0.enqueueCreate(.init(status: createStatus, returnsSession: true)) }
            ),
            (
                .sessionCreate(copyStatus),
                { $0.enqueueCopyResult(.init(status: copyStatus, value: nil)) }
            ),
            (
                .softwareDecoder,
                { $0.enqueueCopyResult(.init(status: noErr, value: .boolean(false))) }
            ),
        ]

        for scenario in scenarios {
            let harness = makeHarness()
            try configure(harness, generation: 7)
            scenario.arrange(harness.api)

            assertFailure(scenario.expected) {
                try configure(harness, generation: 8, configuration: .appleTemporal)
            }

            XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 2)])
            try decode(harness, id: 100, generation: 7)
            XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 1))
        }
    }

    func testSuccessfulAppleCandidateSwapsThenInvalidatesOldSession() throws {
        let harness = makeHarness()
        try configure(harness, generation: 2)

        try configure(harness, generation: 3, configuration: .appleTemporal)

        XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        try decode(harness, id: 4, generation: 3)
        XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 2))
    }

    func testBothFieldsDecodeDropsStaleInputAndPreservesCallerFlagsWithoutTemporalFlag() throws {
        let harness = makeHarness()
        try configure(harness, generation: 9)
        let callerFlags = VTDecodeFrameFlags(
            rawValue: 0x4000 | VTDecodeFrameFlags._EnableTemporalProcessing.rawValue
        )

        try decode(harness, id: 1, generation: 8, flags: callerFlags)
        XCTAssertTrue(harness.api.snapshot.decodes.isEmpty)

        try decode(harness, id: 2, generation: 9, flags: callerFlags)
        XCTAssertEqual(harness.api.snapshot.decodes.count, 1)
        XCTAssertEqual(
            harness.api.snapshot.decodes.first?.flagsRawValue,
            0x4000 | VTDecodeFrameFlags._EnableAsynchronousDecompression.rawValue
        )
        XCTAssertEqual(
            try XCTUnwrap(harness.api.snapshot.decodes.first?.flagsRawValue)
                & VTDecodeFrameFlags._EnableTemporalProcessing.rawValue,
            0
        )
        XCTAssertNil(harness.api.snapshot.decodes.first?.frameOptions)
    }

    func testAppleTemporalDecodePreservesCallerFlagsAndAddsAsyncAndTemporalFlags() throws {
        let harness = makeHarness()
        try configure(harness, generation: 9, configuration: .appleTemporal)
        let callerFlags = VTDecodeFrameFlags(rawValue: 0x4000)

        try decode(harness, id: 2, generation: 9, flags: callerFlags)

        XCTAssertEqual(
            harness.api.snapshot.decodes.first?.flagsRawValue,
            callerFlags.rawValue
                | VTDecodeFrameFlags._EnableAsynchronousDecompression.rawValue
                | VTDecodeFrameFlags._EnableTemporalProcessing.rawValue
        )
        XCTAssertNil(harness.api.snapshot.decodes.first?.frameOptions)
    }

    func testAppleTemporalEmitsEveryOneTwoOrThreeCallbacksWithSourceIdentityAndOwnTiming() throws {
        for callbackCount in 1 ... 3 {
            let harness = makeHarness()
            try configure(harness, generation: 5, configuration: .appleTemporal)
            let metadata = parserMetadata(fieldOrder: .bb, sourcePTS90k: 450_000)
            try decode(harness, id: 77, generation: 5, parserMetadata: metadata)
            let pixelBuffer = try makePixelBuffer()

            for callbackIndex in 0 ..< callbackCount {
                harness.api.deliver(index: 0, output: output(
                    imageBuffer: pixelBuffer,
                    pts: CMTime(value: Int64(100 + callbackIndex), timescale: 60),
                    duration: CMTime(value: Int64(callbackIndex + 1), timescale: 120)
                ))
            }
            drain(harness.executor)

            let frames = harness.events.frames
            XCTAssertEqual(frames.count, callbackCount)
            XCTAssertEqual(frames.map(\.accessUnitID), Array(repeating: 77, count: callbackCount))
            XCTAssertEqual(
                frames.map(\.generation),
                Array(repeating: MediaGeneration(rawValue: 5), count: callbackCount)
            )
            XCTAssertEqual(frames.map(\.parserMetadata), Array(repeating: metadata, count: callbackCount))
            XCTAssertEqual(
                frames.map(\.presentationTimeStamp),
                (0 ..< callbackCount).map {
                    CMTime(value: Int64(100 + $0), timescale: 60)
                }
            )
            XCTAssertEqual(
                frames.map(\.duration),
                (0 ..< callbackCount).map {
                    CMTime(value: Int64($0 + 1), timescale: 120)
                }
            )
        }
    }

    func testAppleTemporalStaleGenerationAndSessionCallbacksRemainSuppressed() throws {
        let harness = makeHarness()
        try configure(harness, generation: 3, configuration: .appleTemporal)
        try decode(harness, id: 1, generation: 3)

        try configure(harness, generation: 4, configuration: .appleTemporal)
        harness.api.deliver(index: 0, output: output(
            imageBuffer: try makePixelBuffer()
        ))
        drain(harness.executor)

        XCTAssertTrue(harness.events.events.isEmpty)
    }

    func testReverseCallbackDeliveryPreservesCompleteImmutableTokensAndCallbackTiming() throws {
        let harness = makeHarness()
        try configure(harness, generation: 3)
        let firstMetadata = parserMetadata(fieldOrder: .tt, sourcePTS90k: 90_000)
        let secondMetadata = parserMetadata(fieldOrder: .bb, sourcePTS90k: 180_000)
        try decode(harness, id: 10, generation: 3, parserMetadata: firstMetadata)
        try decode(harness, id: 20, generation: 3, parserMetadata: secondMetadata)
        let firstBuffer = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let secondBuffer = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        harness.api.deliver(index: 1, output: output(
            imageBuffer: secondBuffer,
            pts: CMTime(value: 200, timescale: 30),
            duration: CMTime(value: 2, timescale: 30)
        ))
        harness.api.deliver(index: 0, output: output(
            imageBuffer: firstBuffer,
            pts: CMTime(value: 100, timescale: 30),
            duration: CMTime(value: 1, timescale: 30)
        ))
        drain(harness.executor)

        let frames = harness.events.frames
        XCTAssertEqual(frames.map(\.accessUnitID), [20, 10])
        XCTAssertEqual(frames.map(\.parserMetadata), [secondMetadata, firstMetadata])
        XCTAssertEqual(frames.map(\.presentationTimeStamp), [
            CMTime(value: 200, timescale: 30), CMTime(value: 100, timescale: 30),
        ])
        XCTAssertEqual(frames.map(\.duration), [
            CMTime(value: 2, timescale: 30), CMTime(value: 1, timescale: 30),
        ])
    }

    func testGenerationSessionInvalidateAndStaleFatalCallbacksAreAllDropped() throws {
        let harness = makeHarness()
        try configure(harness, generation: 3)
        try decode(harness, id: 1, generation: 3)
        try decode(harness, id: 10, generation: 3)

        try configure(harness, generation: 4)
        try decode(harness, id: 2, generation: 4)
        harness.api.deliver(index: 0, output: output(status: noErr, imageBuffer: try makePixelBuffer()))
        harness.api.deliver(index: 1, output: output(status: -99_999))

        try configure(harness, generation: 4)
        harness.api.deliver(index: 2, output: output(status: noErr, imageBuffer: try makePixelBuffer()))

        try decode(harness, id: 3, generation: 4)
        try perform(on: harness.executor) { harness.decoder.invalidate() }
        harness.api.deliver(index: 3, output: output(status: noErr, imageBuffer: try makePixelBuffer()))
        drain(harness.executor)

        XCTAssertTrue(harness.events.events.isEmpty)
    }

    func testCallbackCanArriveFromAnotherQueueAndSinkRunsOnMediaExecutor() throws {
        let harness = makeHarness()
        try configure(harness, generation: 1)
        try decode(harness, id: 42, generation: 1)
        let delivered = expectation(description: "callback delivered from another queue")
        let callbackQueue = DispatchQueue(label: "org.vplayer.tests.vt-callback")
        let pixelBuffer = try makePixelBuffer()
        let decodeOutput = output(imageBuffer: pixelBuffer)

        callbackQueue.async {
            harness.api.deliver(index: 0, output: decodeOutput)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        drain(harness.executor)

        XCTAssertEqual(harness.events.frames.map(\.accessUnitID), [42])
        XCTAssertEqual(harness.events.isolationChecks, [true])
    }

    func testImmediateDecodeStatusClassificationThrowsOnceWithoutEvent() throws {
        let cases: [(OSStatus, VideoDecoderFailure)] = [
            (kVTVideoDecoderBadDataErr, .badData(kVTVideoDecoderBadDataErr)),
            (-8_969, .badData(-8_969)),
            (kVTVideoDecoderReferenceMissingErr, .badData(kVTVideoDecoderReferenceMissingErr)),
            (kVTVideoDecoderUnsupportedDataFormatErr, .badData(kVTVideoDecoderUnsupportedDataFormatErr)),
            (kVTVideoDecoderMalfunctionErr, .malfunction(kVTVideoDecoderMalfunctionErr)),
            (kVTSessionMalfunctionErr, .malfunction(kVTSessionMalfunctionErr)),
            (kVTVideoDecoderNotAvailableNowErr, .malfunction(kVTVideoDecoderNotAvailableNowErr)),
            (kVTVideoDecoderRemovedErr, .malfunction(kVTVideoDecoderRemovedErr)),
            (kVTInvalidSessionErr, .malfunction(kVTInvalidSessionErr)),
            (-77_777, .malfunction(-77_777)),
        ]

        for (status, expected) in cases {
            let harness = makeHarness()
            try configure(harness, generation: 1)
            harness.api.enqueueDecodeStatus(status)

            assertFailure(expected) { try decode(harness, id: 1, generation: 1) }

            XCTAssertTrue(harness.events.events.isEmpty)
            XCTAssertEqual(harness.api.snapshot.pendingDecodeCount, 0)
        }
    }

    func testAsynchronousSubmissionWindowBoundsPendingAccessUnitsAndReopensOnCallback() throws {
        let harness = makeHarness(
            maximumInFlightDecodeCount: 2,
            inFlightWaitInterval: 0.001
        )
        try configure(harness, generation: 1)

        try decode(harness, id: 1, generation: 1)
        try decode(harness, id: 2, generation: 1)
        assertFailure(.backpressureTimeout) {
            try decode(harness, id: 3, generation: 1)
        }
        XCTAssertEqual(harness.api.snapshot.decodes.count, 2)
        XCTAssertEqual(harness.api.snapshot.pendingDecodeCount, 2)

        harness.api.deliver(index: 0, output: output(imageBuffer: try makePixelBuffer()))
        try decode(harness, id: 4, generation: 1)

        XCTAssertEqual(harness.api.snapshot.decodes.map(\.sessionID), [
            VTSessionID(rawValue: 1),
            VTSessionID(rawValue: 1),
            VTSessionID(rawValue: 1),
        ])
    }

    func testAsynchronousStatusClassificationEmitsExactlyOneDisposition() throws {
        let cases: [(OSStatus, ExpectedDisposition, VideoDecoderFailure)] = [
            (1, .recoverable, .badData(1)),
            (kVTVideoDecoderBadDataErr, .recoverable, .badData(kVTVideoDecoderBadDataErr)),
            (-8_969, .recoverable, .badData(-8_969)),
            (kVTVideoDecoderReferenceMissingErr, .recoverable, .badData(kVTVideoDecoderReferenceMissingErr)),
            (kVTVideoDecoderUnsupportedDataFormatErr, .fatal, .badData(kVTVideoDecoderUnsupportedDataFormatErr)),
            (kVTVideoDecoderMalfunctionErr, .recoverable, .malfunction(kVTVideoDecoderMalfunctionErr)),
            (kVTSessionMalfunctionErr, .recoverable, .malfunction(kVTSessionMalfunctionErr)),
            (kVTVideoDecoderNotAvailableNowErr, .recoverable, .malfunction(kVTVideoDecoderNotAvailableNowErr)),
            (kVTVideoDecoderRemovedErr, .recoverable, .malfunction(kVTVideoDecoderRemovedErr)),
            (kVTInvalidSessionErr, .fatal, .malfunction(kVTInvalidSessionErr)),
            (kVTVideoDecoderUnknownErr, .fatal, .malfunction(kVTVideoDecoderUnknownErr)),
            (-66_666, .fatal, .malfunction(-66_666)),
        ]

        for (status, disposition, expectedFailure) in cases {
            let harness = makeHarness()
            try configure(harness, generation: 6)
            try decode(harness, id: 1, generation: 6)

            harness.api.deliver(index: 0, output: output(status: status))
            drain(harness.executor)

            XCTAssertEqual(harness.events.failures.count, 1)
            XCTAssertEqual(harness.events.failures.first?.failure, expectedFailure)
            XCTAssertEqual(harness.events.failures.first?.disposition, disposition)
            XCTAssertEqual(harness.events.failures.first?.generation, MediaGeneration(rawValue: 6))
        }
    }

    func testAppleTemporalImmediateProcessingFailuresAreTemporalButDataFailuresStayBadData() throws {
        let cases: [(OSStatus, VideoDecoderFailure)] = [
            (1, .badData(1)),
            (kVTVideoDecoderBadDataErr, .badData(kVTVideoDecoderBadDataErr)),
            (-8_969, .badData(-8_969)),
            (kVTVideoDecoderReferenceMissingErr, .badData(kVTVideoDecoderReferenceMissingErr)),
            (
                kVTVideoDecoderMalfunctionErr,
                .temporalUnavailable(.processingFailed(status: kVTVideoDecoderMalfunctionErr))
            ),
            (-77_701, .temporalUnavailable(.processingFailed(status: -77_701))),
        ]

        for (status, expected) in cases {
            let harness = makeHarness()
            try configure(harness, generation: 1, configuration: .appleTemporal)
            harness.api.enqueueDecodeStatus(status)

            assertFailure(expected) { try decode(harness, id: 1, generation: 1) }

            XCTAssertTrue(harness.events.events.isEmpty)
        }
    }

    func testAppleTemporalCallbackProcessingFailuresAreRecoverableButDataFailuresStayBadData() throws {
        let cases: [(OSStatus, VideoDecoderFailure)] = [
            (1, .badData(1)),
            (kVTVideoDecoderBadDataErr, .badData(kVTVideoDecoderBadDataErr)),
            (-8_969, .badData(-8_969)),
            (kVTVideoDecoderReferenceMissingErr, .badData(kVTVideoDecoderReferenceMissingErr)),
            (
                kVTVideoDecoderMalfunctionErr,
                .temporalUnavailable(.processingFailed(status: kVTVideoDecoderMalfunctionErr))
            ),
            (-77_702, .temporalUnavailable(.processingFailed(status: -77_702))),
        ]

        for (status, expected) in cases {
            let harness = makeHarness()
            try configure(harness, generation: 6, configuration: .appleTemporal)
            try decode(harness, id: 1, generation: 6)

            harness.api.deliver(index: 0, output: output(status: status))
            drain(harness.executor)

            XCTAssertEqual(harness.events.failures, [FailureRecord(
                failure: expected,
                generation: MediaGeneration(rawValue: 6),
                disposition: .recoverable
            )])
        }
    }

    func testAppleTemporalFinishAndWaitProcessingFailuresAreTemporalUnavailable() throws {
        let harness = makeHarness()
        try configure(harness, generation: 5, configuration: .appleTemporal)
        harness.api.enqueueFinishStatus(-77_703)
        harness.api.enqueueWaitStatus(-77_704)

        assertFailure(.temporalUnavailable(.processingFailed(status: -77_703))) {
            try perform(on: harness.executor) { try harness.decoder.finishDelayedFrames() }
        }
        assertFailure(.temporalUnavailable(.processingFailed(status: -77_704))) {
            try perform(on: harness.executor) { try harness.decoder.waitForAsynchronousFrames() }
        }
    }

    func testDroppedAndInterruptedNilImagesEmitNothingButUnflaggedNilIsRecoverable() throws {
        let harness = makeHarness()
        try configure(harness, generation: 2)
        try decode(harness, id: 1, generation: 2)
        try decode(harness, id: 2, generation: 2)
        try decode(harness, id: 3, generation: 2)

        harness.api.deliver(index: 0, output: output(infoFlags: .frameDropped))
        harness.api.deliver(index: 1, output: output(infoFlags: .frameInterrupted))
        harness.api.deliver(index: 2, output: output())
        drain(harness.executor)

        XCTAssertEqual(harness.events.events.count, 1)
        XCTAssertEqual(harness.events.failures.first?.disposition, .recoverable)
        XCTAssertEqual(
            harness.events.failures.first?.failure,
            .malfunction(kVTVideoDecoderMalfunctionErr)
        )
    }

    func testFinishAndWaitStatusesThrowWithoutEventsAndSuccessCallsActiveSession() throws {
        let harness = makeHarness()
        try configure(harness, generation: 5)
        harness.api.enqueueFinishStatus(-31_001)
        harness.api.enqueueWaitStatus(kVTVideoDecoderMalfunctionErr)

        assertFailure(.malfunction(-31_001)) {
            try perform(on: harness.executor) { try harness.decoder.finishDelayedFrames() }
        }
        assertFailure(.malfunction(kVTVideoDecoderMalfunctionErr)) {
            try perform(on: harness.executor) { try harness.decoder.waitForAsynchronousFrames() }
        }
        try perform(on: harness.executor) { try harness.decoder.finishDelayedFrames() }
        try perform(on: harness.executor) { try harness.decoder.waitForAsynchronousFrames() }

        XCTAssertEqual(harness.api.snapshot.finishedSessionIDs, [
            VTSessionID(rawValue: 1), VTSessionID(rawValue: 1),
        ])
        XCTAssertEqual(harness.api.snapshot.waitedSessionIDs, [
            VTSessionID(rawValue: 1), VTSessionID(rawValue: 1),
        ])
        XCTAssertTrue(harness.events.events.isEmpty)
    }

    func testInvalidateClearsBeforeAPICallAndIsIdempotent() throws {
        let harness = makeHarness()
        try configure(harness, generation: 1)
        try decode(harness, id: 1, generation: 1)

        try perform(on: harness.executor) {
            harness.decoder.invalidate()
            harness.decoder.invalidate()
        }
        harness.api.deliver(index: 0, output: output(status: -123))
        drain(harness.executor)

        XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        XCTAssertTrue(harness.events.events.isEmpty)
    }

    func testValid420v420fAndP010BuffersProduceExactRangesAndBitDepths() throws {
        let formats: [(OSType, Int, VideoFormatMetadata.Range)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, .video),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 8, .full),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 10, .video),
        ]

        for (format, bitDepth, range) in formats {
            let harness = makeHarness()
            try configure(harness, generation: 1)
            try decode(harness, id: 1, generation: 1)
            let pixelBuffer = try makePixelBuffer(format: format)

            harness.api.deliver(index: 0, output: output(imageBuffer: pixelBuffer))
            drain(harness.executor)

            let metadata = try XCTUnwrap(harness.events.frames.first?.formatMetadata)
            XCTAssertEqual(metadata.dimensions.width, 64)
            XCTAssertEqual(metadata.dimensions.height, 32)
            XCTAssertEqual(metadata.bitDepth, bitDepth)
            XCTAssertEqual(metadata.range, range)
            XCTAssertEqual(metadata.matrix, .unknown)
            XCTAssertEqual(metadata.transfer, .unknown)
            XCTAssertEqual(metadata.primaries, .unknown)
            XCTAssertNil(metadata.cleanAperture)
            XCTAssertEqual(metadata.chromaLocation, .init(topField: nil, bottomField: nil))
            XCTAssertEqual(metadata.hdrStaticMetadata, .init(
                masteringDisplayColorVolume: nil,
                contentLightLevelInfo: nil
            ))
        }
    }

    func testInvalidPixelFormatAndAllowedFormatWithWrongPlaneCountEmitFatalFailures() throws {
        let buffers = [
            try makePixelBuffer(format: kCVPixelFormatType_32BGRA),
            try makeNonPlanarAllowedPixelBuffer(),
        ]

        for pixelBuffer in buffers {
            let harness = makeHarness()
            try configure(harness, generation: 1)
            try decode(harness, id: 1, generation: 1)

            harness.api.deliver(index: 0, output: output(imageBuffer: pixelBuffer))
            drain(harness.executor)

            XCTAssertEqual(harness.events.failures, [FailureRecord(
                failure: .malfunction(kCVReturnInvalidPixelFormat),
                generation: MediaGeneration(rawValue: 1),
                disposition: .fatal
            )])
        }
    }

    func testMissingIOSurfaceEmitsFatalFailure() throws {
        let missingSurface = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes: [:]
        )
        XCTAssertNil(CVPixelBufferGetIOSurface(missingSurface))
        let harness = makeHarness()
        try configure(harness, generation: 1)
        try decode(harness, id: 1, generation: 1)

        harness.api.deliver(index: 0, output: output(imageBuffer: missingSurface))
        drain(harness.executor)

        XCTAssertEqual(harness.events.failures.first?.failure, .malfunction(
            kCVReturnPixelBufferNotMetalCompatible
        ))
        XCTAssertEqual(harness.events.failures.first?.disposition, .fatal)
    }

    func testFalseCoreVideoCompatibilityResultEmitsFatalFailure() throws {
        let harness = makeHarness(compatibilityCheck: { _, _ in false })
        try configure(harness, generation: 1)
        try decode(harness, id: 1, generation: 1)
        let pixelBuffer = try makePixelBuffer()
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pixelBuffer))

        harness.api.deliver(index: 0, output: output(imageBuffer: pixelBuffer))
        drain(harness.executor)

        XCTAssertEqual(harness.events.failures.first?.failure, .malfunction(
            kCVReturnPixelBufferNotMetalCompatible
        ))
        XCTAssertEqual(harness.events.failures.first?.disposition, .fatal)
    }

    func testP010HLGBT2020CleanApertureChromaAndHDRAreExactDeepCopies() throws {
        let harness = makeHarness()
        try configure(harness, generation: 12)
        try decode(harness, id: 404, generation: 12)
        let pixelBuffer = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let top = try XCTUnwrap(CFStringCreateMutable(kCFAllocatorDefault, 0))
        let bottom = try XCTUnwrap(CFStringCreateMutable(kCFAllocatorDefault, 0))
        CFStringAppend(top, "TopLeft" as CFString)
        CFStringAppend(bottom, "BottomLeft" as CFString)
        let masteringBytes = Array(UInt8(0)..<UInt8(24))
        let lightBytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let mastering = try mutableData(masteringBytes)
        let light = try mutableData(lightBytes)
        setAttachment(pixelBuffer, key: kCVImageBufferColorPrimariesKey, value: kCVImageBufferColorPrimaries_ITU_R_2020)
        setAttachment(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey, value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        setAttachment(pixelBuffer, key: kCVImageBufferTransferFunctionKey, value: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        setAttachment(pixelBuffer, key: kCVImageBufferChromaLocationTopFieldKey, value: top)
        setAttachment(pixelBuffer, key: kCVImageBufferChromaLocationBottomFieldKey, value: bottom)
        setAttachment(pixelBuffer, key: kCVImageBufferMasteringDisplayColorVolumeKey, value: mastering)
        setAttachment(pixelBuffer, key: kCVImageBufferContentLightLevelInfoKey, value: light)
        setAttachment(pixelBuffer, key: kCVImageBufferCleanApertureKey, value: [
            kCVImageBufferCleanApertureWidthKey as String: 60,
            kCVImageBufferCleanApertureHeightKey as String: 28,
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: 1,
            kCVImageBufferCleanApertureVerticalOffsetKey as String: -1,
        ] as CFDictionary)

        harness.api.deliver(index: 0, output: output(
            imageBuffer: pixelBuffer,
            pts: CMTime(value: 300, timescale: 60),
            duration: CMTime(value: 1, timescale: 60)
        ))
        drain(harness.executor)
        CFStringReplaceAll(top, "Mutated" as CFString)
        CFStringReplaceAll(bottom, "Mutated" as CFString)
        CFDataDeleteBytes(mastering, CFRange(location: 0, length: CFDataGetLength(mastering)))
        CFDataDeleteBytes(light, CFRange(location: 0, length: CFDataGetLength(light)))
        CVBufferRemoveAllAttachments(pixelBuffer)

        let frame = try XCTUnwrap(harness.events.frames.first)
        XCTAssertTrue(frame.pixelBuffer === pixelBuffer)
        XCTAssertEqual(frame.accessUnitID, 404)
        XCTAssertEqual(frame.generation, MediaGeneration(rawValue: 12))
        XCTAssertEqual(frame.formatMetadata, VideoFormatMetadata(
            dimensions: CMVideoDimensions(width: 64, height: 32),
            bitDepth: 10,
            range: .video,
            matrix: .bt2020,
            transfer: .hlg,
            primaries: .bt2020,
            cleanAperture: CGRect(x: 3, y: 3, width: 60, height: 28),
            chromaLocation: .init(topField: "TopLeft", bottomField: "BottomLeft"),
            hdrStaticMetadata: .init(
                masteringDisplayColorVolume: Data(masteringBytes),
                contentLightLevelInfo: Data(lightBytes)
            )
        ))
    }

    func testKnownAndUnknownAttachmentMappingsAndInvalidHDRLengths() throws {
        let harness = makeHarness()
        try configure(harness, generation: 1)
        try decode(harness, id: 1, generation: 1)
        let pixelBuffer = try makePixelBuffer()
        setAttachment(pixelBuffer, key: kCVImageBufferColorPrimariesKey, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        setAttachment(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey, value: "Identity" as CFString)
        setAttachment(pixelBuffer, key: kCVImageBufferTransferFunctionKey, value: kCVImageBufferTransferFunction_Linear)
        setAttachment(pixelBuffer, key: kCVImageBufferMasteringDisplayColorVolumeKey, value: Data(repeating: 1, count: 23) as CFData)
        setAttachment(pixelBuffer, key: kCVImageBufferContentLightLevelInfoKey, value: Data(repeating: 2, count: 5) as CFData)

        harness.api.deliver(index: 0, output: output(imageBuffer: pixelBuffer))
        drain(harness.executor)

        let metadata = try XCTUnwrap(harness.events.frames.first?.formatMetadata)
        XCTAssertEqual(metadata.primaries, .bt709)
        XCTAssertEqual(metadata.matrix, .identity)
        XCTAssertEqual(metadata.transfer, .linear)
        XCTAssertNil(metadata.hdrStaticMetadata.masteringDisplayColorVolume)
        XCTAssertNil(metadata.hdrStaticMetadata.contentLightLevelInfo)
    }

    func testSourceGateHasNoYADIFImplementation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Sources/VPlayerPlayback/Video/VideoDecoding.swift",
            "Sources/VPlayerPlayback/Video/VideoToolboxAPI.swift",
            "Sources/VPlayerPlayback/Video/VideoToolboxDecoder.swift",
            "Sources/VPlayerPlayback/Video/VideoFormatMetadataReader.swift",
            "Sources/VPlayerPlayback/Video/VideoFrameProcessing.swift",
        ]
        let existingSources = paths.compactMap { path -> String? in
            let url = repository.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        let combined = existingSources.joined(separator: "\n")

        XCTAssertNil(combined.range(of: "ya" + "dif", options: .caseInsensitive))
    }

    private func makeHarness(
        compatibilityCheck: @escaping PixelBufferCompatibilityCheck = VideoFormatMetadataReader.systemCompatibilityCheck,
        maximumInFlightDecodeCount: Int = 8,
        inFlightWaitInterval: TimeInterval = 0.25
    ) -> DecoderHarness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.decoder")
        let api = FakeVideoToolboxAPI()
        let events = DecoderEventRecorder(executor: executor)
        let decoder = VideoToolboxDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: api,
            compatibilityCheck: compatibilityCheck,
            maximumInFlightDecodeCount: maximumInFlightDecodeCount,
            inFlightWaitInterval: inFlightWaitInterval
        )
        return DecoderHarness(executor: executor, api: api, events: events, decoder: decoder)
    }

    private func configure(
        _ harness: DecoderHarness,
        generation: UInt64,
        codec: CMVideoCodecType = kCMVideoCodecType_H264,
        configuration: VideoDecodeConfiguration = .bothFields
    ) throws {
        let format = try makeFormat(codec: codec)
        try perform(on: harness.executor) {
            try harness.decoder.configure(
                format: format,
                generation: MediaGeneration(rawValue: generation),
                configuration: configuration
            )
        }
    }

    private func decode(
        _ harness: DecoderHarness,
        id: UInt64,
        generation: UInt64,
        parserMetadata: VideoParserMetadata = VideoParserMetadata(
            fieldOrder: .progressive,
            pictureStructure: .frame,
            isInterlaced: false,
            repeatFirstField: false,
            topFieldFirst: nil,
            sourcePTS90k: nil
        ),
        flags: VTDecodeFrameFlags = ._EnableAsynchronousDecompression
    ) throws {
        let format = try makeFormat(codec: kCMVideoCodecType_H264)
        let sampleBuffer = try SampleBufferBuilder.makeVideo(
            data: Data([0]),
            formatDescription: format,
            presentationTimeStamp: CMTime(value: 9, timescale: 90),
            decodeTimeStamp: CMTime(value: 8, timescale: 90),
            duration: CMTime(value: 1, timescale: 30),
            isRandomAccess: true
        )
        let accessUnit = CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: MediaGeneration(rawValue: generation),
            isRandomAccess: true,
            parserMetadata: parserMetadata
        )
        try perform(on: harness.executor) {
            try harness.decoder.decode(accessUnit, flags: flags)
        }
    }

    private func perform(
        on executor: PlaybackSerialExecutor,
        _ operation: @escaping @Sendable () throws -> Void
    ) throws {
        let result = LockedCallResult()
        let completed = expectation(description: "executor call completed")
        executor.submit {
            do {
                try operation()
                result.store(error: nil)
            } catch {
                result.store(error: error)
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        if let error = result.error { throw error }
    }

    private func drain(_ executor: PlaybackSerialExecutor) {
        let completed = expectation(description: "executor drained")
        executor.submit { completed.fulfill() }
        wait(for: [completed], timeout: 5)
    }

    private func assertFailure(
        _ expected: VideoDecoderFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as VideoDecoderFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func makeFormat(codec: CMVideoCodecType) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: 64,
            height: 32,
            extensions: nil,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }

    private func makePixelBuffer(
        format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            32,
            format,
            attributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func makeNonPlanarAllowedPixelBuffer() throws -> CVPixelBuffer {
        let byteCount = 64 * 32 * 2
        let baseAddress = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            64,
            32,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            baseAddress,
            64,
            { _, releasedAddress in releasedAddress?.deallocate() },
            nil,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else {
            baseAddress.deallocate()
            XCTFail("failed to create nonplanar pixel buffer: \(status)")
            throw PlaybackFailure(code: "pixel-buffer", userMessage: "fixture creation failed")
        }
        return try XCTUnwrap(pixelBuffer)
    }

    private func output(
        status: OSStatus = noErr,
        infoFlags: VTDecodeInfoFlags = [],
        imageBuffer: CVPixelBuffer? = nil,
        pts: CMTime = CMTime(value: 1, timescale: 30),
        duration: CMTime = CMTime(value: 1, timescale: 30)
    ) -> VTDecodeOutput {
        VTDecodeOutput(
            status: status,
            infoFlags: infoFlags,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration
        )
    }

    private func parserMetadata(
        fieldOrder: CodedFieldOrder,
        sourcePTS90k: UInt64
    ) -> VideoParserMetadata {
        VideoParserMetadata(
            fieldOrder: fieldOrder,
            pictureStructure: .frame,
            isInterlaced: true,
            repeatFirstField: false,
            topFieldFirst: fieldOrder == .tt,
            sourcePTS90k: sourcePTS90k
        )
    }

    private func mutableData(_ bytes: [UInt8]) throws -> CFMutableData {
        let data = try XCTUnwrap(CFDataCreateMutable(kCFAllocatorDefault, bytes.count))
        bytes.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                CFDataAppendBytes(data, baseAddress, bytes.count)
            }
        }
        return data
    }

    private func setAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString,
        value: CFTypeRef
    ) {
        CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
    }
}

private struct DecoderHarness: @unchecked Sendable {
    let executor: PlaybackSerialExecutor
    let api: FakeVideoToolboxAPI
    let events: DecoderEventRecorder
    let decoder: VideoToolboxDecoder
}

private enum ExpectedDisposition: Sendable, Equatable {
    case recoverable
    case fatal
}

private struct FailureRecord: Sendable, Equatable {
    let failure: VideoDecoderFailure
    let generation: MediaGeneration
    let disposition: ExpectedDisposition
}

private final class DecoderEventRecorder: @unchecked Sendable {
    private let executor: PlaybackSerialExecutor
    private let lock = NSLock()
    private var storedEvents: [VideoDecoderEvent] = []
    private var storedIsolationChecks: [Bool] = []

    init(executor: PlaybackSerialExecutor) {
        self.executor = executor
    }

    func record(_ event: VideoDecoderEvent) {
        lock.lock()
        storedEvents.append(event)
        storedIsolationChecks.append(executor.isIsolated)
        lock.unlock()
    }

    var events: [VideoDecoderEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    var isolationChecks: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedIsolationChecks
    }

    var frames: [DecodedVideoFrame] {
        events.compactMap { event in
            guard case let .frame(frame) = event else { return nil }
            return frame
        }
    }

    var failures: [FailureRecord] {
        events.compactMap { event in
            switch event {
            case .frame:
                return nil
            case let .recoverableFailure(failure, generation):
                return FailureRecord(
                    failure: failure,
                    generation: generation,
                    disposition: .recoverable
                )
            case let .fatalFailure(failure, generation):
                return FailureRecord(
                    failure: failure,
                    generation: generation,
                    disposition: .fatal
                )
            }
        }
    }
}

private final class LockedCallResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?

    func store(error: (any Error)?) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}
