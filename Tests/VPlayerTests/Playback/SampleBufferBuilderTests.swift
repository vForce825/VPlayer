// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class SampleBufferBuilderTests: XCTestCase {
    func testCompressedAudioOwnedByteCountEqualsCopiedBlockAndTotalSampleSize() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42])
        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: makeAdmittedFrame(payload: payload),
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        )

        XCTAssertEqual(
            try SampleBufferBuilder.compressedAudioPayloadByteCount(sampleBuffer),
            payload.count
        )
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sampleBuffer), payload.count)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))
        XCTAssertEqual(CMBlockBufferGetDataLength(block), payload.count)
    }

    func testResetCopyPreservesOwnedDataLengthWithoutMutatingOriginal() throws {
        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: makeAdmittedFrame(payload: Data([0x01, 0x02, 0x03, 0x04])),
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        )
        let copied = try SampleBufferBuilder
            .copyingAudioSampleBufferWithResetDecoderBeforeDecoding(sampleBuffer)

        XCTAssertEqual(
            try SampleBufferBuilder.compressedAudioPayloadByteCount(copied),
            try SampleBufferBuilder.compressedAudioPayloadByteCount(sampleBuffer)
        )
        XCTAssertNil(CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil
        ))
        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            on: copied
        )
    }

    func testDirectAudioBuilderRejectsRawAACOneByteOverHardLimit() throws {
        XCTAssertThrowsError(try SampleBufferBuilder.makeAudio(
            frame: makeAdmittedFrame(
                payload: Data(repeating: 0xA5, count: 1 * 1_024 * 1_024 + 1)
            ),
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        ))
    }

    func testAudioContinuityFlagsBecomePropagatingSampleBufferAttachments() throws {
        let frame = makeAdmittedFrame(
            resetDecoderBeforeDecoding: true,
            fillDiscontinuitiesWithSilence: true
        )

        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: frame,
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        )

        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            on: sampleBuffer
        )
        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
            on: sampleBuffer
        )

        let forcedReset = try SampleBufferBuilder.makeAudio(
            frame: makeAdmittedFrame(),
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: true
        )
        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            on: forcedReset
        )
        XCTAssertNil(CMGetAttachment(
            forcedReset,
            key: kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
            attachmentModeOut: nil
        ))
    }

    func testNormalizedPTSBecomesSampleBufferPresentationTimestamp() throws {
        let normalizedPTS = CMTime(value: 1_001, timescale: 1_000)
        let frame = makeAdmittedFrame(
            sourcePTS: CMTime(value: 1, timescale: 1),
            normalizedPTS: normalizedPTS
        )

        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: frame,
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        )

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), normalizedPTS)
        XCTAssertEqual(
            try packetDescription(from: sampleBuffer).mVariableFramesInPacket,
            0
        )
    }

    func testLargeGapFirstFrameDoesNotRequestSilenceFill() throws {
        let frame = makeAdmittedFrame(
            startsNewIsland: true,
            gapBefore: CMTime(value: 251, timescale: 1_000),
            resetDecoderBeforeDecoding: true,
            fillDiscontinuitiesWithSilence: false
        )

        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: frame,
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        )

        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            on: sampleBuffer
        )
        XCTAssertNil(CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
            attachmentModeOut: nil
        ))
    }

    func testFixedPacketFormatRejectsMismatchedFrameSampleCount() throws {
        let frame = makeAdmittedFrame(frameSampleCount: 960)

        XCTAssertThrowsError(try SampleBufferBuilder.makeAudio(
            frame: frame,
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        ))
    }

    func testVariablePacketFormatUsesFrameSampleCountInPacketDescription() throws {
        let frame = makeAdmittedFrame(frameSampleCount: 256, codec: .eac3)

        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: frame,
            formatDescription: try makeFormat(codec: .eac3),
            forceResetDecoderBeforeDecoding: false
        )

        let packetDescription = try packetDescription(from: sampleBuffer)
        XCTAssertEqual(packetDescription.mVariableFramesInPacket, 256)
        XCTAssertEqual(packetDescription.mDataByteSize, UInt32(frame.frame.payload.count))
    }

    func testCanonicalAdmittedFrameBuilderPreservesPayloadTimingAndIslandFlags() throws {
        let presentationTimeStamp = CMTime(value: 3, timescale: 2)
        let frame = makeAdmittedFrame(
            sourcePTS: presentationTimeStamp,
            normalizedPTS: presentationTimeStamp,
            resetDecoderBeforeDecoding: true
        )

        let sampleBuffer = try SampleBufferBuilder.makeAudio(
            frame: frame,
            formatDescription: try makeFormat(codec: .aac),
            forceResetDecoderBeforeDecoding: false
        )

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), presentationTimeStamp)
        let packetDescription = try packetDescription(from: sampleBuffer)
        XCTAssertEqual(packetDescription.mVariableFramesInPacket, 0)
        XCTAssertEqual(packetDescription.mDataByteSize, UInt32(frame.frame.payload.count))
        XCTAssertEqual(frame.continuityIslandID, AudioContinuityIslandID(rawValue: 9))
        try assertBooleanAttachment(
            kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            on: sampleBuffer
        )
    }

    private func makeAdmittedFrame(
        frameSampleCount: Int32 = 1_024,
        codec: VPlayerPlayback.AudioCodec = .aac,
        payload: Data = Data([0xDE, 0xAD, 0xBE, 0xEF]),
        sourcePTS: CMTime = CMTime(value: 1, timescale: 1),
        normalizedPTS: CMTime = CMTime(value: 1, timescale: 1),
        startsNewIsland: Bool = false,
        gapBefore: CMTime? = nil,
        resetDecoderBeforeDecoding: Bool = false,
        fillDiscontinuitiesWithSilence: Bool = false
    ) -> AdmittedAudioFrame {
        let duration = CMTime(value: Int64(frameSampleCount), timescale: 48_000)
        return AdmittedAudioFrame(
            frame: CompressedAudioFrame(
                id: 1,
                payload: payload,
                codec: codec,
                generation: MediaGeneration(rawValue: 4),
                presentationTimeStamp: sourcePTS,
                duration: duration,
                frameSampleCount: frameSampleCount
            ),
            normalizedPresentationTimeStamp: normalizedPTS,
            effectiveCoverageStartPTS: fillDiscontinuitiesWithSilence
                ? CMTimeSubtract(normalizedPTS, gapBefore ?? .zero)
                : normalizedPTS,
            duration: duration,
            continuityIslandID: AudioContinuityIslandID(rawValue: 9),
            startsNewIsland: startsNewIsland,
            gapBefore: gapBefore,
            resetDecoderBeforeDecoding: resetDecoderBeforeDecoding,
            fillDiscontinuitiesWithSilence: fillDiscontinuitiesWithSilence
        )
    }

    private func makeFormat(
        codec: VPlayerPlayback.AudioCodec
    ) throws -> CMAudioFormatDescription {
        let format: SystemCompressedAudioFormat
        switch codec {
        case .aac:
            format = SystemCompressedAudioFormat(
                profileID: .aacLC,
                codec: .aac,
                formatID: kAudioFormatMPEG4AAC,
                sampleRate: 48_000,
                channelCount: 2,
                framesPerPacket: 1_024,
                layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
                magicCookie: Data([0x11, 0x90])
            )
        case .eac3:
            format = SystemCompressedAudioFormat(
                profileID: .eac3,
                codec: .eac3,
                formatID: kAudioFormatEnhancedAC3,
                sampleRate: 48_000,
                channelCount: 2,
                framesPerPacket: 0,
                layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
                magicCookie: nil
            )
        default:
            throw PlaybackCoreError.unsupportedAudioCodec
        }
        return try AudioFormatDescriptionBuilder.make(format).description
    }

    private func assertBooleanAttachment(
        _ key: CFString,
        on sampleBuffer: CMSampleBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var mode = kCMAttachmentMode_ShouldNotPropagate
        let value = try XCTUnwrap(
            CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: &mode),
            file: file,
            line: line
        )
        XCTAssertTrue(CFEqual(value, kCFBooleanTrue), file: file, line: line)
        XCTAssertEqual(mode, kCMAttachmentMode_ShouldPropagate, file: file, line: line)
    }

    private func packetDescription(
        from sampleBuffer: CMSampleBuffer
    ) throws -> AudioStreamPacketDescription {
        var pointer: UnsafePointer<AudioStreamPacketDescription>?
        var size = 0
        XCTAssertEqual(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
            sampleBuffer,
            packetDescriptionsPointerOut: &pointer,
            sizeOut: &size
        ), noErr)
        XCTAssertEqual(size, MemoryLayout<AudioStreamPacketDescription>.size)
        return try XCTUnwrap(pointer?.pointee)
    }
}

final class CompressedAudioRetentionPolicyTests: XCTestCase {
    func testOwnedByteReserveOverflowFailsClosedWithoutMutation() {
        var budget = OwnedByteBudget(limit: Int.max, used: Int.max)

        XCTAssertThrowsError(try budget.reserve(1)) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .audioRendererFailed(CompressedAudioRetentionPolicy.accountingError)
            )
        }
        XCTAssertEqual(budget.used, Int.max)
    }

    func testOwnedByteReleaseUnderflowFailsClosed() {
        var budget = OwnedByteBudget(limit: 8, used: 0)

        XCTAssertThrowsError(try budget.release(1)) { error in
            XCTAssertEqual(
                error as? PlaybackCoreError,
                .audioRendererFailed(CompressedAudioRetentionPolicy.accountingError)
            )
        }
        XCTAssertEqual(budget.used, 0)
    }

    func testOwnedByteReserveOverLimitReturnsFalseWithoutMutation() throws {
        var budget = OwnedByteBudget(limit: 8)
        XCTAssertTrue(try budget.reserve(8))
        XCTAssertFalse(try budget.reserve(1))
        XCTAssertEqual(budget.used, 8)
        try budget.release(8)
        XCTAssertEqual(budget.used, 0)
    }
}
