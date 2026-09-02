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
    func testConfigureTransitionReturnsWhileNativeQueueIsBlockedAndCompletesOnceOnExecutor() throws {
        let harness = makeHarness()
        let queueBlocked = expectation(description: "native submission queue blocked")
        let transitionReturned = expectation(description: "transition call returned")
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        harness.submissionQueue.async {
            queueBlocked.fulfill()
            releaseQueue.wait()
        }
        wait(for: [queueBlocked], timeout: 2)

        let token = VideoDecoderTransitionToken()
        let format = try makeFormat(codec: kCMVideoCodecType_H264)
        harness.executor.submit {
            harness.decoder.transition(.configure(
                token: token,
                format: format,
                generation: MediaGeneration(rawValue: 41)
            ))
            transitionReturned.fulfill()
        }

        wait(for: [transitionReturned], timeout: 2)
        XCTAssertTrue(harness.events.transitionCompletions.isEmpty)

        releaseQueue.signal()
        harness.drainSubmissions()
        drain(harness.executor)

        XCTAssertEqual(harness.events.transitionCompletions, [
            TransitionCompletionRecord(
                token: token,
                outcome: .completed
            ),
        ])
        XCTAssertEqual(harness.events.transitionIsolationChecks, [true])
    }

    func testNewerInvalidateSupersedesConfigureAlreadyInsideNativeCreation() throws {
        let harness = makeHarness()
        let configureEnteredNativeCreation = expectation(
            description: "configure entered native creation"
        )
        let releaseConfigure = DispatchSemaphore(value: 0)
        defer { releaseConfigure.signal() }
        harness.api.enqueueCreateInterception {
            configureEnteredNativeCreation.fulfill()
            releaseConfigure.wait()
        }

        let configureToken = VideoDecoderTransitionToken()
        harness.decoder.transition(.configure(
            token: configureToken,
            format: try makeFormat(codec: kCMVideoCodecType_H264),
            generation: MediaGeneration(rawValue: 46)
        ))
        wait(for: [configureEnteredNativeCreation], timeout: 2)

        let invalidateToken = VideoDecoderTransitionToken()
        harness.decoder.transition(.invalidate(token: invalidateToken))
        releaseConfigure.signal()
        harness.drainSubmissions()
        drain(harness.executor)

        assertFailure(.sessionCreate(kVTInvalidSessionErr)) {
            try decode(harness, id: 460, generation: 46)
        }
        XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        XCTAssertEqual(harness.events.transitionCompletions.filter {
            $0.token == configureToken || $0.token == invalidateToken
        }, [
            TransitionCompletionRecord(token: configureToken, outcome: .completed),
            TransitionCompletionRecord(token: invalidateToken, outcome: .completed),
        ])
    }

    func testNewerConfigurePreventsSupersededCandidateFromBecomingTemporarilyActive() throws {
        let harness = makeHarness()
        let firstConfigureEntered = expectation(description: "first configure entered creation")
        let secondConfigureEntered = expectation(description: "second configure entered creation")
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSecond.signal()
        }
        harness.api.enqueueCreateInterception {
            firstConfigureEntered.fulfill()
            releaseFirst.wait()
        }
        harness.api.enqueueCreateInterception {
            secondConfigureEntered.fulfill()
            releaseSecond.wait()
        }

        let firstToken = VideoDecoderTransitionToken()
        harness.decoder.transition(.configure(
            token: firstToken,
            format: try makeFormat(codec: kCMVideoCodecType_H264),
            generation: MediaGeneration(rawValue: 47)
        ))
        wait(for: [firstConfigureEntered], timeout: 2)

        let secondToken = VideoDecoderTransitionToken()
        harness.decoder.transition(.configure(
            token: secondToken,
            format: try makeFormat(codec: kCMVideoCodecType_H264),
            generation: MediaGeneration(rawValue: 48)
        ))
        releaseFirst.signal()
        wait(for: [secondConfigureEntered], timeout: 2)
        drain(harness.executor)

        let staleAccessUnit = try makeAccessUnit(
            id: 470,
            generation: 47,
            isRandomAccess: true
        )
        assertFailure(.sessionCreate(kVTInvalidSessionErr)) {
            try perform(on: harness.executor) {
                try harness.decoder.decode(
                    staleAccessUnit,
                    flags: ._EnableAsynchronousDecompression
                )
            }
        }

        releaseSecond.signal()
        harness.drainSubmissions()
        drain(harness.executor)
        try decode(harness, id: 480, generation: 48)

        XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 2))
        XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        XCTAssertEqual(harness.events.transitionCompletions.filter {
            $0.token == firstToken || $0.token == secondToken
        }, [
            TransitionCompletionRecord(token: firstToken, outcome: .completed),
            TransitionCompletionRecord(token: secondToken, outcome: .completed),
        ])
    }

    func testProducedAndNoFrameCompletionsCarryTheConfiguredTransitionIdentityInOrder() throws {
        let harness = makeHarness()
        let configurationToken = VideoDecoderTransitionToken()
        let format = try makeFormat(codec: kCMVideoCodecType_H264)
        harness.decoder.transition(.configure(
            token: configurationToken,
            format: format,
            generation: MediaGeneration(rawValue: 42)
        ))
        harness.drainSubmissions()
        drain(harness.executor)

        try decode(harness, id: 101, generation: 42)
        harness.api.deliver(index: 0, output: output(imageBuffer: try makePixelBuffer()))
        drain(harness.executor)

        try decode(harness, id: 102, generation: 42)
        harness.api.deliver(index: 1, output: output(infoFlags: .frameDropped))
        drain(harness.executor)

        let identity = VideoDecoderEventIdentity(
            generation: MediaGeneration(rawValue: 42),
            transitionToken: configurationToken
        )
        XCTAssertEqual(harness.events.identifiedOutputEvents, [
            .frame(accessUnitID: 101, identity: identity),
            .completed(accessUnitID: 101, identity: identity, disposition: .produced),
            .completed(accessUnitID: 102, identity: identity, disposition: .noFrame),
        ])
    }

    func testInvalidateTransitionImmediatelyFencesFrameAndCancelsLeaseExactlyOnce() throws {
        let harness = makeHarness()
        let configurationToken = VideoDecoderTransitionToken()
        let format = try makeFormat(codec: kCMVideoCodecType_H264)
        harness.decoder.transition(.configure(
            token: configurationToken,
            format: format,
            generation: MediaGeneration(rawValue: 43)
        ))
        harness.drainSubmissions()
        drain(harness.executor)
        try decode(harness, id: 103, generation: 43)

        let queueBlocked = expectation(description: "native submission queue blocked")
        let transitionReturned = expectation(description: "invalidate transition returned")
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        harness.submissionQueue.async {
            queueBlocked.fulfill()
            releaseQueue.wait()
        }
        wait(for: [queueBlocked], timeout: 2)

        let invalidateToken = VideoDecoderTransitionToken()
        harness.executor.submit {
            harness.decoder.transition(.invalidate(token: invalidateToken))
            transitionReturned.fulfill()
        }
        wait(for: [transitionReturned], timeout: 2)

        harness.api.deliver(index: 0, output: output(imageBuffer: try makePixelBuffer()))
        drain(harness.executor)
        let identity = VideoDecoderEventIdentity(
            generation: MediaGeneration(rawValue: 43),
            transitionToken: configurationToken
        )
        XCTAssertEqual(harness.events.identifiedOutputEvents, [
            .completed(accessUnitID: 103, identity: identity, disposition: .cancelled),
        ])
        XCTAssertFalse(harness.events.transitionCompletions.contains {
            $0.token == invalidateToken
        })

        releaseQueue.signal()
        harness.drainSubmissions()
        drain(harness.executor)
        harness.api.deliver(index: 0, output: output(imageBuffer: try makePixelBuffer()))
        drain(harness.executor)

        XCTAssertEqual(harness.events.identifiedOutputEvents, [
            .completed(accessUnitID: 103, identity: identity, disposition: .cancelled),
        ])
        XCTAssertEqual(harness.events.transitionCompletions.filter {
            $0.token == invalidateToken
        }, [
            TransitionCompletionRecord(token: invalidateToken, outcome: .completed),
        ])
    }

    func testDrainAndInvalidateTransitionReturnsWhileNativeQueueIsBlocked() throws {
        let harness = makeHarness()
        let configurationToken = VideoDecoderTransitionToken()
        harness.decoder.transition(.configure(
            token: configurationToken,
            format: try makeFormat(codec: kCMVideoCodecType_H264),
            generation: MediaGeneration(rawValue: 44)
        ))
        harness.drainSubmissions()
        drain(harness.executor)

        let queueBlocked = expectation(description: "native submission queue blocked")
        let transitionReturned = expectation(description: "drain transition returned")
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        harness.submissionQueue.async {
            queueBlocked.fulfill()
            releaseQueue.wait()
        }
        wait(for: [queueBlocked], timeout: 2)

        let token = VideoDecoderTransitionToken()
        harness.executor.submit {
            harness.decoder.transition(.drainAndInvalidate(token: token))
            transitionReturned.fulfill()
        }
        wait(for: [transitionReturned], timeout: 2)
        XCTAssertFalse(harness.events.transitionCompletions.contains { $0.token == token })

        releaseQueue.signal()
        harness.drainSubmissions()
        drain(harness.executor)

        XCTAssertEqual(harness.api.snapshot.finishedSessionIDs, [VTSessionID(rawValue: 1)])
        XCTAssertEqual(harness.api.snapshot.waitedSessionIDs, [VTSessionID(rawValue: 1)])
        XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        XCTAssertEqual(harness.events.transitionCompletions.filter { $0.token == token }, [
            TransitionCompletionRecord(token: token, outcome: .completed),
        ])
    }

    func testDrainAndInvalidateBestEffortInvalidatesAfterFinishAndWaitFailures() throws {
        let harness = makeHarness()
        harness.decoder.transition(.configure(
            token: VideoDecoderTransitionToken(),
            format: try makeFormat(codec: kCMVideoCodecType_H264),
            generation: MediaGeneration(rawValue: 45)
        ))
        harness.drainSubmissions()
        drain(harness.executor)
        harness.api.enqueueFinishStatus(kVTVideoDecoderMalfunctionErr)
        harness.api.enqueueWaitStatus(kVTInvalidSessionErr)

        let token = VideoDecoderTransitionToken()
        harness.decoder.transition(.drainAndInvalidate(token: token))
        harness.drainSubmissions()
        drain(harness.executor)

        XCTAssertEqual(harness.api.snapshot.operations.suffix(3), [
            "finish", "wait", "invalidate",
        ])
        XCTAssertEqual(harness.events.transitionCompletions.filter { $0.token == token }, [
            TransitionCompletionRecord(
                token: token,
                outcome: .failed(.malfunction(kVTVideoDecoderMalfunctionErr))
            ),
        ])
    }

    func testDecoderOutputPoolFloorShrinksForFourKP010Memory() {
        XCTAssertEqual(
            PlaybackTuning.default.decoderOutputPoolFloor(
                for: CMVideoDimensions(width: 1_920, height: 1_080)
            ),
            PlaybackTuning.default.decoderOutputPoolFloor
        )
        XCTAssertEqual(
            PlaybackTuning.default.decoderOutputPoolFloor(
                for: CMVideoDimensions(width: 3_840, height: 2_160)
            ),
            10
        )
    }

    func testBothFieldsConfigurationUsesExactHardwareAndImageProperties() throws {
        let harness = makeHarness()

        try configure(harness, generation: 3)

        let snapshot = harness.api.snapshot
        XCTAssertEqual(snapshot.operations, ["create", "copy", "set", "set", "set", "copy"])
        XCTAssertEqual(snapshot.creates.count, 1)
        XCTAssertEqual(snapshot.creates.first?.decoderSpecification, [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: .boolean(true),
        ])
        // No pixel format is named: the decoder said its own fastest output is
        // one this renderer can map, so constraining it could only insert a
        // conversion.
        XCTAssertEqual(snapshot.creates.first?.imageBufferAttributes, [
            kCVPixelBufferMetalCompatibilityKey as String: .boolean(true),
            kCVPixelBufferIOSurfacePropertiesKey as String: .dictionary([:]),
        ])
        XCTAssertEqual(snapshot.sets, [
            FakeVideoToolboxAPI.PropertyRecord(
                sessionID: VTSessionID(rawValue: 1),
                key: kVTDecompressionPropertyKey_FieldMode as String,
                value: .string(kVTDecompressionProperty_FieldMode_BothFields as String)
            ),
            // Interlaced H.264 has no hardware path on Apple silicon, so this
            // decodes in software; a single thread cannot keep up with 1080i25.
            FakeVideoToolboxAPI.PropertyRecord(
                sessionID: VTSessionID(rawValue: 1),
                key: kVTDecompressionPropertyKey_ThreadCount as String,
                value: .unsigned32(UInt32(ProcessInfo.processInfo.activeProcessorCount))
            ),
            FakeVideoToolboxAPI.PropertyRecord(
                sessionID: VTSessionID(rawValue: 1),
                key: kVTDecompressionPropertyKey_OutputPoolRequestedMinimumBufferCount as String,
                value: .unsigned32(UInt32(PlaybackTuning.default.decoderOutputPoolFloor))
            ),
        ])
        XCTAssertEqual(snapshot.copies, [
            FakeVideoToolboxAPI.CopyRecord(
                sessionID: VTSessionID(rawValue: 1),
                key: kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance as String
            ),
            FakeVideoToolboxAPI.CopyRecord(
                sessionID: VTSessionID(rawValue: 1),
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder as String
            ),
        ])
    }

    // A decoder whose own fastest output cannot be turned into a texture has to
    // be constrained to one that can, and the session that revealed it must not
    // be left behind.
    func testUnrenderableDecoderPreferenceIsReplacedByAConstrainedSession() throws {
        let harness = makeHarness()
        harness.api.setSupportedPixelFormatsResult(.init(
            status: noErr,
            value: .array([
                .unsigned32(kCVPixelFormatType_422YpCbCr8),
                .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ])
        ))

        try configure(harness, generation: 3)

        let snapshot = harness.api.snapshot
        XCTAssertEqual(snapshot.creates.count, 2)
        XCTAssertNil(snapshot.creates.first?.imageBufferAttributes[
            kCVPixelBufferPixelFormatTypeKey as String
        ])
        XCTAssertEqual(
            snapshot.creates.last?.imageBufferAttributes[
                kCVPixelBufferPixelFormatTypeKey as String
            ],
            .unsigned32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        )
        XCTAssertEqual(snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        try decode(harness, id: 7, generation: 3)
        XCTAssertEqual(harness.api.snapshot.decodes.last?.sessionID, VTSessionID(rawValue: 2))
    }

    // Nothing renderable on offer, or no answer at all: fall back to naming
    // every format the renderer can map and let VideoToolbox choose.
    func testUnreadablePixelFormatPreferenceFallsBackToTheRenderableList() throws {
        let harness = makeHarness()
        harness.api.setSupportedPixelFormatsResult(.init(
            status: kVTPropertyNotSupportedErr,
            value: nil
        ))

        try configure(harness, generation: 3)

        let snapshot = harness.api.snapshot
        XCTAssertEqual(snapshot.creates.count, 2)
        XCTAssertEqual(
            snapshot.creates.last?.imageBufferAttributes[
                kCVPixelBufferPixelFormatTypeKey as String
            ],
            .array(VideoToolboxDecoder.renderablePixelFormats.map { .unsigned32($0) })
        )
        XCTAssertEqual(snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
    }

    func testBothFieldsAcceptsUnsupportedOptionalFieldModeProperty() throws {
        let harness = makeHarness()
        harness.api.enqueueSetStatus(kVTPropertyNotSupportedErr)

        XCTAssertNoThrow(try configure(harness, generation: 3))

        XCTAssertEqual(
            harness.api.snapshot.operations,
            ["create", "copy", "set", "set", "set", "copy"]
        )
        try decode(harness, id: 7, generation: 3)
        XCTAssertEqual(harness.api.snapshot.decodes.count, 1)
    }

    // The pool floor is a hint; a decoder that refuses it still decodes.
    func testUnsupportedOutputPoolFloorLeavesTheSessionUsable() throws {
        let harness = makeHarness()
        harness.api.enqueueSetStatus(noErr)
        harness.api.enqueueSetStatus(kVTPropertyNotSupportedErr)

        XCTAssertNoThrow(try configure(harness, generation: 3))

        try decode(harness, id: 7, generation: 3)
        XCTAssertEqual(harness.api.snapshot.decodes.count, 1)
    }

    func testUnsupportedCodecPermanentlyFencesAndInvalidatesActiveSession() throws {
        let harness = makeHarness()
        try configure(harness, generation: 1)
        let unsupported = try makeFormat(codec: kCMVideoCodecType_JPEG)

        assertFailure(.sessionCreate(kVTVideoDecoderUnsupportedDataFormatErr)) {
            try configure(harness, format: unsupported, generation: 2)
        }

        XCTAssertEqual(
            harness.api.snapshot.operations,
            ["create", "copy", "set", "set", "set", "copy", "invalidate"]
        )
        assertFailure(.sessionCreate(kVTInvalidSessionErr)) {
            try decode(harness, id: 11, generation: 1)
        }
    }

    func testCandidateCreateSetAndCopyFailuresInvalidateCandidateAndFencedOldSession() throws {
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

            XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [
                VTSessionID(rawValue: 2),
                VTSessionID(rawValue: 1),
            ])
            assertFailure(.sessionCreate(kVTInvalidSessionErr)) {
                try decode(harness, id: 99, generation: 7)
            }
        }
    }

    func testFalseMissingAndWrongTypeHardwarePropertiesFenceOldSession() throws {
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

            XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [
                VTSessionID(rawValue: 2),
                VTSessionID(rawValue: 1),
            ])
            assertFailure(.sessionCreate(kVTInvalidSessionErr)) {
                try decode(harness, id: 12, generation: 5)
            }
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

    func testCreateAndHardwareFailuresRemainBaseFailuresAndFenceOldSession() throws {
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
                try configure(harness, generation: 8)
            }

            XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [
                VTSessionID(rawValue: 2),
                VTSessionID(rawValue: 1),
            ])
            assertFailure(.sessionCreate(kVTInvalidSessionErr)) {
                try decode(harness, id: 100, generation: 7)
            }
        }
    }

    func testDecodeDropsStaleInputAndPreservesCallerFlagsWithoutTemporalFlag() throws {
        let harness = makeHarness()
        try configure(harness, generation: 9)
        let callerFlags = VTDecodeFrameFlags(
            rawValue: 0x4000 | VTDecodeFrameFlags._EnableTemporalProcessing.rawValue
        )

        assertFailure(.sessionCreate(kVTInvalidSessionErr)) {
            try decode(harness, id: 1, generation: 8, flags: callerFlags)
        }
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
        try invalidate(harness)
        harness.api.deliver(index: 3, output: output(status: noErr, imageBuffer: try makePixelBuffer()))
        drain(harness.executor)

        XCTAssertTrue(harness.events.frames.isEmpty)
        XCTAssertTrue(harness.events.failures.isEmpty)
        XCTAssertEqual(Set(harness.events.completions), Set([
            CompletionRecord(accessUnitID: 1, generation: MediaGeneration(rawValue: 3)),
            CompletionRecord(accessUnitID: 10, generation: MediaGeneration(rawValue: 3)),
            CompletionRecord(accessUnitID: 2, generation: MediaGeneration(rawValue: 4)),
            CompletionRecord(accessUnitID: 3, generation: MediaGeneration(rawValue: 4)),
        ]))
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
        XCTAssertEqual(harness.events.completions, [CompletionRecord(
            accessUnitID: 42,
            generation: MediaGeneration(rawValue: 1)
        )])
        XCTAssertEqual(harness.events.isolationChecks, [true, true])
    }

    // Handing a unit to VideoToolbox happens off the caller's thread, so the
    // classification that used to come back as a `throw` now has to arrive as
    // exactly one submission-failure event — the coordinator drives the same
    // recovery from either.
    func testImmediateDecodeStatusClassificationReportsOneSubmissionFailure() throws {
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

            try decode(harness, id: 1, generation: 1)
            drain(harness.executor)

            XCTAssertEqual(harness.events.failures, [FailureRecord(
                failure: expected,
                generation: MediaGeneration(rawValue: 1),
                disposition: .submission
            )])
            XCTAssertEqual(harness.events.completions, [CompletionRecord(
                accessUnitID: 1,
                generation: MediaGeneration(rawValue: 1)
            )])
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
        try decode(harness, id: 3, generation: 1)
        drain(harness.executor)
        XCTAssertEqual(harness.events.failures, [FailureRecord(
            failure: .backpressureTimeout,
            generation: MediaGeneration(rawValue: 1),
            disposition: .submission
        )])
        XCTAssertEqual(harness.events.completions.map(\.accessUnitID), [3])
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

    func testDroppedAndInterruptedNilImagesStillCompleteExactlyOnce() throws {
        let harness = makeHarness()
        try configure(harness, generation: 2)
        try decode(harness, id: 1, generation: 2)
        try decode(harness, id: 2, generation: 2)
        try decode(harness, id: 3, generation: 2)

        harness.api.deliver(index: 0, output: output(infoFlags: .frameDropped))
        harness.api.deliver(index: 1, output: output(infoFlags: .frameInterrupted))
        harness.api.deliver(index: 2, output: output())
        drain(harness.executor)

        XCTAssertEqual(harness.events.completions.map(\.accessUnitID), [1, 2, 3])
        XCTAssertEqual(harness.events.failures.first?.disposition, .recoverable)
        XCTAssertEqual(
            harness.events.failures.first?.failure,
            .malfunction(kVTVideoDecoderMalfunctionErr)
        )
    }

    func testInvalidateClearsBeforeAPICallAndIsIdempotent() throws {
        let harness = makeHarness()
        try configure(harness, generation: 1)
        try decode(harness, id: 1, generation: 1)

        try invalidate(harness)
        try invalidate(harness)

        XCTAssertEqual(harness.api.snapshot.invalidatedSessionIDs, [VTSessionID(rawValue: 1)])
        XCTAssertTrue(harness.events.frames.isEmpty)
        XCTAssertTrue(harness.events.failures.isEmpty)
        XCTAssertEqual(harness.events.completions.map(\.accessUnitID), [1])

        // A callback racing teardown may still arrive, but the completion lease
        // has already been consumed by invalidation and cannot release twice.
        harness.api.deliver(index: 0, output: output(status: -123))
        drain(harness.executor)

        XCTAssertTrue(harness.events.frames.isEmpty)
        XCTAssertTrue(harness.events.failures.isEmpty)
        XCTAssertEqual(harness.events.completions.map(\.accessUnitID), [1])
    }

    // A decoder that has fallen behind must cost frames, not the read path: the
    // bound sheds work, and it resumes only at a random-access unit because the
    // ones in between reference pictures that were never submitted.
    func testBacklogBoundSkipsToTheNextRandomAccessUnitOnceItIsFull() throws {
        let backlog = DecodeSubmissionBacklog(depth: 2)

        XCTAssertEqual(backlog.admit(isRandomAccess: true), .submit)
        XCTAssertEqual(backlog.admit(isRandomAccess: false), .submit)
        // Full: this one is shed and the bound latches.
        XCTAssertEqual(backlog.admit(isRandomAccess: false), .skip)
        backlog.complete()
        backlog.complete()
        // Drained, but a non-keyframe still cannot restart a broken chain.
        XCTAssertEqual(backlog.admit(isRandomAccess: false), .skip)
        XCTAssertEqual(backlog.admit(isRandomAccess: true), .submit)
        XCTAssertEqual(backlog.maximumDepth, 2)
    }

    // Skipping is a property of the run of undecodable units, not of the
    // decoder: a session rebuild starts a new chain and must not inherit it.
    func testBacklogResumesImmediatelyAfterASessionChange() {
        let backlog = DecodeSubmissionBacklog(depth: 1)
        XCTAssertEqual(backlog.admit(isRandomAccess: true), .submit)
        XCTAssertEqual(backlog.admit(isRandomAccess: true), .skip)
        backlog.complete()

        backlog.resumeAfterSessionChange()

        XCTAssertEqual(backlog.admit(isRandomAccess: false), .submit)
    }

    func testAccessUnitsBeyondTheBacklogBoundNeverReachTheDecoder() throws {
        let tuning = PlaybackTuning(videoBufferSeconds: 0.5)
        let depth = tuning.decodeSubmissionQueueDepth
        let harness = makeHarness(maximumInFlightDecodeCount: depth * 4, tuning: tuning)
        try configure(harness, generation: 1)

        // Stall submission so the queue actually accumulates: with a decoder
        // that answers instantly nothing would ever be behind.
        let release = DispatchSemaphore(value: 0)
        harness.submissionQueue.async { release.wait() }
        for id in 0..<UInt64(depth + 4) {
            let accessUnit = try makeAccessUnit(id: id, generation: 1, isRandomAccess: false)
            try perform(on: harness.executor) {
                try harness.decoder.decode(
                    accessUnit,
                    flags: ._EnableAsynchronousDecompression
                )
            }
        }
        release.signal()
        harness.drainSubmissions()
        drain(harness.executor)

        XCTAssertEqual(harness.api.snapshot.decodes.count, depth)
        XCTAssertEqual(
            harness.events.completions.map(\.accessUnitID),
            Array(UInt64(depth)..<UInt64(depth + 4))
        )
    }

    func testQueuedAccessUnitFromAnOldSubmissionEpochCompletesWithoutDecoding() throws {
        let epoch = SubmissionEpoch()
        let harness = makeHarness(submissionEpoch: epoch)
        try configure(harness, generation: 1)

        let release = DispatchSemaphore(value: 0)
        harness.submissionQueue.async { release.wait() }
        let accessUnit = try makeAccessUnit(id: 88, generation: 1, isRandomAccess: true)
        try perform(on: harness.executor) {
            try harness.decoder.decode(
                accessUnit,
                flags: ._EnableAsynchronousDecompression
            )
        }
        epoch.bump()
        release.signal()
        harness.drainSubmissions()
        drain(harness.executor)

        XCTAssertTrue(harness.api.snapshot.decodes.isEmpty)
        XCTAssertEqual(harness.events.completions, [CompletionRecord(
            accessUnitID: 88,
            generation: MediaGeneration(rawValue: 1)
        )])
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
        inFlightWaitInterval: TimeInterval = 0.25,
        tuning: PlaybackTuning = .default,
        submissionEpoch: SubmissionEpoch = SubmissionEpoch()
    ) -> DecoderHarness {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.decoder")
        let api = FakeVideoToolboxAPI()
        let events = DecoderEventRecorder(executor: executor)
        let submissionQueue = DispatchQueue(label: "org.vplayer.tests.decoder.submit")
        let decoder = VideoToolboxDecoder(
            executor: executor,
            eventSink: { events.record($0) },
            api: api,
            compatibilityCheck: compatibilityCheck,
            maximumInFlightDecodeCount: maximumInFlightDecodeCount,
            inFlightWaitInterval: inFlightWaitInterval,
            tuning: tuning,
            submissionQueue: submissionQueue,
            submissionEpoch: submissionEpoch
        )
        return DecoderHarness(
            executor: executor,
            api: api,
            events: events,
            decoder: decoder,
            submissionQueue: submissionQueue
        )
    }

    private func configure(
        _ harness: DecoderHarness,
        generation: UInt64,
        codec: CMVideoCodecType = kCMVideoCodecType_H264
    ) throws {
        try configure(
            harness,
            format: makeFormat(codec: codec),
            generation: generation
        )
    }

    private func configure(
        _ harness: DecoderHarness,
        format: CMVideoFormatDescription,
        generation: UInt64
    ) throws {
        let token = VideoDecoderTransitionToken()
        try perform(on: harness.executor) {
            harness.decoder.transition(.configure(
                token: token,
                format: format,
                generation: MediaGeneration(rawValue: generation)
            ))
        }
        harness.drainSubmissions()
        drain(harness.executor)
        guard let outcome = harness.events.takeTransitionOutcome(token: token) else {
            XCTFail("missing configure transition completion")
            return
        }
        if case let .failed(failure) = outcome {
            throw failure
        }
    }

    private func invalidate(_ harness: DecoderHarness) throws {
        let token = VideoDecoderTransitionToken()
        try perform(on: harness.executor) {
            harness.decoder.transition(.invalidate(token: token))
        }
        harness.drainSubmissions()
        drain(harness.executor)
        guard let outcome = harness.events.takeTransitionOutcome(token: token) else {
            XCTFail("missing invalidate transition completion")
            return
        }
        if case let .failed(failure) = outcome {
            throw failure
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
        harness.drainSubmissions()
    }

    private func makeAccessUnit(
        id: UInt64,
        generation: UInt64,
        isRandomAccess: Bool
    ) throws -> CompressedVideoAccessUnit {
        let format = try makeFormat(codec: kCMVideoCodecType_H264)
        let sampleBuffer = try SampleBufferBuilder.makeVideo(
            data: Data([0]),
            formatDescription: format,
            presentationTimeStamp: CMTime(value: 9, timescale: 90),
            decodeTimeStamp: CMTime(value: 8, timescale: 90),
            duration: CMTime(value: 1, timescale: 30),
            isRandomAccess: isRandomAccess
        )
        return CompressedVideoAccessUnit(
            id: id,
            sampleBuffer: sampleBuffer,
            generation: MediaGeneration(rawValue: generation),
            isRandomAccess: isRandomAccess,
            parserMetadata: VideoParserMetadata(
                fieldOrder: .progressive,
                pictureStructure: .frame,
                isInterlaced: false,
                repeatFirstField: false,
                topFieldFirst: nil,
                sourcePTS90k: nil
            )
        )
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
    /// Submission no longer happens on the caller's thread, so a test that
    /// looks at the API right after `decode` would be racing it.
    let submissionQueue: DispatchQueue

    func drainSubmissions() {
        submissionQueue.sync {}
    }
}

private enum ExpectedDisposition: Sendable, Equatable {
    case recoverable
    case fatal
    case submission
}

private struct FailureRecord: Sendable, Equatable {
    let failure: VideoDecoderFailure
    let generation: MediaGeneration
    let disposition: ExpectedDisposition
}

private struct CompletionRecord: Sendable, Hashable {
    let accessUnitID: UInt64
    let generation: MediaGeneration
}

private struct TransitionCompletionRecord: Sendable, Equatable {
    let token: VideoDecoderTransitionToken
    let outcome: VideoDecoderTransitionOutcome
}

private enum IdentifiedDecoderOutputEvent: Sendable, Equatable {
    case frame(accessUnitID: UInt64, identity: VideoDecoderEventIdentity)
    case completed(
        accessUnitID: UInt64,
        identity: VideoDecoderEventIdentity,
        disposition: VideoDecoderSubmissionDisposition
    )
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

    func takeTransitionOutcome(
        token: VideoDecoderTransitionToken
    ) -> VideoDecoderTransitionOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storedEvents.firstIndex(where: { event in
            guard case let .transitionCompleted(eventToken, _) = event else { return false }
            return eventToken == token
        }),
        case let .transitionCompleted(_, outcome) = storedEvents.remove(at: index) else {
            return nil
        }
        storedIsolationChecks.remove(at: index)
        return outcome
    }

    var isolationChecks: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedIsolationChecks
    }

    var frames: [DecodedVideoFrame] {
        events.compactMap { event in
            guard case let .frame(frame, _) = event else { return nil }
            return frame
        }
    }

    var failures: [FailureRecord] {
        events.compactMap { event in
            switch event {
            case .frame, .submissionCompleted, .transitionCompleted:
                return nil
            case let .recoverableFailure(failure, identity):
                return FailureRecord(
                    failure: failure,
                    generation: identity.generation,
                    disposition: .recoverable
                )
            case let .fatalFailure(failure, identity):
                return FailureRecord(
                    failure: failure,
                    generation: identity.generation,
                    disposition: .fatal
                )
            case let .submissionFailure(_, failure, identity):
                return FailureRecord(
                    failure: failure,
                    generation: identity.generation,
                    disposition: .submission
                )
            }
        }
    }

    var completions: [CompletionRecord] {
        events.compactMap { event in
            guard case let .submissionCompleted(accessUnitID, identity, _) = event else {
                return nil
            }
            return CompletionRecord(
                accessUnitID: accessUnitID,
                generation: identity.generation
            )
        }
    }

    var transitionCompletions: [TransitionCompletionRecord] {
        events.compactMap { event in
            guard case let .transitionCompleted(token, outcome) = event else { return nil }
            return TransitionCompletionRecord(token: token, outcome: outcome)
        }
    }

    var transitionIsolationChecks: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return zip(storedEvents, storedIsolationChecks).compactMap { event, isIsolated in
            guard case .transitionCompleted = event else { return nil }
            return isIsolated
        }
    }


    var identifiedOutputEvents: [IdentifiedDecoderOutputEvent] {
        events.compactMap { event in
            switch event {
            case let .frame(frame, identity):
                return .frame(accessUnitID: frame.accessUnitID, identity: identity)
            case let .submissionCompleted(accessUnitID, identity, disposition):
                return .completed(
                    accessUnitID: accessUnitID,
                    identity: identity,
                    disposition: disposition
                )
            case .recoverableFailure,
                 .fatalFailure,
                 .submissionFailure,
                 .transitionCompleted:
                return nil
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
