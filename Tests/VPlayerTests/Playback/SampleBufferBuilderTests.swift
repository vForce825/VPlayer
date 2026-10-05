// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class SampleBufferBuilderTests: XCTestCase {
    func testWriterInputPreservesThreePacketPrimingPrefixOutputTimestampRepresentation() throws {
        let physicalPTS = CMTime(value: 480_000 - 2_112, timescale: 48_000)
        let source = try makeWriterAACSource(sampleRate: 48_000, sampleCount: 3,
            timings: [CMSampleTimingInfo(duration: CMTime(value: 1_024, timescale: 48_000),
                presentationTimeStamp: physicalPTS, decodeTimeStamp: .invalid)])
        CMSetAttachment(source, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: try XCTUnwrap(CMTimeCopyAsDictionary(
                CMTime(value: 2_112, timescale: 48_000), allocator: kCFAllocatorDefault)),
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(source),
            CMTime(value: 480_000, timescale: 48_000))
        let attachments = writerAttachments(source, mode: kCMAttachmentMode_ShouldPropagate)
        let outputTiming = try WriterInputOutputTiming.settingExplicit(CMTime(value: 10, timescale: 1), on: source)
        assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(source), CMTime(value: 10, timescale: 1))
        print("HLS_WRITER_OUTPUT_ATTACHMENT_COUNTS fixture=three-packet-prefix "
            + "before=\(attachments?.count ?? -1) "
            + "after=\(writerAttachments(source, mode: kCMAttachmentMode_ShouldPropagate)?.count ?? -1)")

        let wrapped = try SampleBufferBuilder.makeWriterInputSample(source, lifetime: WriterInputLifetime(),
            outputTiming: outputTiming)
        assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(wrapped), CMTime(value: 10, timescale: 1))
        try assertWriterInputMatches(wrapped, source, packetized: true)
    }

    func testWriterInputPreservesReducedAACTimingRepresentationAtBothSampleRates() throws {
        for sampleRate: Int32 in [48_000, 44_100] {
            for decorated in [false, true] {
                let flags: CMTimeFlags = decorated ? [.valid, .hasBeenRounded] : .valid
                let duration = CMTime(value: sampleRate == 48_000 ? 8 : 256,
                    timescale: sampleRate == 48_000 ? 375 : 11_025, flags: flags, epoch: 0)
                let timing = CMSampleTimingInfo(duration: duration,
                    presentationTimeStamp: CMTime(value: 11, timescale: 3,
                        flags: flags, epoch: decorated ? 7 : 0),
                    decodeTimeStamp: .invalid)
                for sampleCount in [1, 2, 64] {
                    for outputOverride in [false, true] {
                        let source = try makeWriterAACSource(sampleRate: sampleRate,
                            sampleCount: sampleCount, timings: [timing])
                        var sourceTiming = CMSampleTimingInfo()
                        XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(source, at: 0,
                            timingInfoOut: &sourceTiming), noErr)
                        assertExactTime(sourceTiming.duration, duration)
                        assertExactTime(sourceTiming.presentationTimeStamp, timing.presentationTimeStamp)
                        if sampleCount == 1 { assertExactTime(CMSampleBufferGetDuration(source), duration) }
                        let outputTiming = outputOverride
                            ? try WriterInputOutputTiming.settingExplicit(CMTime(value: 31, timescale: 3,
                                flags: flags, epoch: decorated ? 7 : 0), on: source)
                            : .calculated
                        let wrapped = try SampleBufferBuilder.makeWriterInputSample(source,
                            lifetime: WriterInputLifetime(), outputTiming: outputTiming)
                        try assertWriterInputMatches(wrapped, source, packetized: true)
                    }
                }
            }
        }
    }

    func testWriterInputPreservesEveryEntryOfNonuniformAACTimingArray() throws {
        let timings = (0..<64).map { index in
            CMSampleTimingInfo(
                duration: index.isMultiple(of: 2)
                    ? CMTime(value: 8, timescale: 375)
                    : CMTime(value: 1_024, timescale: 48_000, flags: [.valid, .hasBeenRounded], epoch: 0),
                presentationTimeStamp: CMTime(value: 4_000 + Int64(index) * 8,
                    timescale: 375, flags: .valid, epoch: 7),
                decodeTimeStamp: .invalid)
        }
        let source = try makeWriterAACSource(sampleRate: 48_000, sampleCount: timings.count, timings: timings)
        var count = 0
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(source, entryCount: 0,
            arrayToFill: nil, entriesNeededOut: &count), noErr)
        XCTAssertEqual(count, timings.count, "The fixture must exercise the full bounded timing array")
        let wrapped = try SampleBufferBuilder.makeWriterInputSample(source, lifetime: WriterInputLifetime())
        try assertWriterInputMatches(wrapped, source, packetized: true)
    }

    func testWriterInputPreservesCalculatedOutputTimestampWithoutAddingAttachments() throws {
        for packetized in [false, true] {
            let source = try makeWriterInputSource(packetized: packetized)
            XCTAssertEqual(writerAttachments(source, mode: kCMAttachmentMode_ShouldPropagate)?.count ?? 0, 0)
            let wrapped = try SampleBufferBuilder.makeWriterInputSample(source, lifetime: WriterInputLifetime())
            try assertWriterInputMatches(wrapped, source, packetized: packetized)

            // A calculated timestamp must remain calculated after wrapping. An
            // explicit override with the same current value would freeze it here.
            let trim = CMTime(value: 128, timescale: 48_000)
            for sample in [source, wrapped] {
                CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                    value: try XCTUnwrap(CMTimeCopyAsDictionary(trim, allocator: kCFAllocatorDefault)),
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(wrapped),
                CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(source), trim))
            try assertWriterInputMatches(wrapped, source, packetized: packetized)
        }
    }

    func testWriterInputPreservesRemovedAttachmentsWithCalculatedAndExplicitOutputTiming() throws {
        for packetized in [false, true] {
            for explicit in [false, true] {
                let source = try makeWriterInputSource(packetized: packetized)
                // Match the source fixture's set/copy/remove history. CoreMedia may
                // retain an empty mode dictionary after removing its final key.
                for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
                    let key = "VPlayer.WriterInput.Removed" as CFString
                    CMSetAttachment(source, key: key, value: kCFBooleanTrue, attachmentMode: mode)
                    CMRemoveAttachment(source, key: key)
                    XCTAssertNil(CMGetAttachment(source, key: key, attachmentModeOut: nil))
                    XCTAssertEqual(writerAttachments(source, mode: mode)?.count ?? 0, 0)
                }
                let outputTiming = explicit
                    ? try WriterInputOutputTiming.settingExplicit(CMTime(value: 91, timescale: 7), on: source)
                    : .calculated
                let wrapped = try SampleBufferBuilder.makeWriterInputSample(source,
                    lifetime: WriterInputLifetime(), outputTiming: outputTiming)
                try assertWriterInputMatches(wrapped, source, packetized: packetized)

                // Dictionary allocation state must not turn a calculated PTS into
                // an override or erase the explicit creation-time intent.
                let trim = CMTime(value: 128, timescale: 48_000)
                for sample in [source, wrapped] {
                    CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                        value: try XCTUnwrap(CMTimeCopyAsDictionary(trim, allocator: kCFAllocatorDefault)),
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(wrapped),
                    explicit ? CMTime(value: 91, timescale: 7)
                        : CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(source), trim))
                try assertWriterInputMatches(wrapped, source, packetized: packetized)
            }
        }
    }

    func testWriterInputPreservesTrimmedCalculatedOutputTimestampAndAttachmentModes() throws {
        for packetized in [false, true] {
            for reversed in [false, true] {
                let source = try makeWriterInputSource(packetized: packetized)
                let startTrim = CMTime(value: 128, timescale: 48_000)
                let endTrim = CMTime(value: 64, timescale: 48_000)
                for (key, trim) in [(kCMSampleBufferAttachmentKey_TrimDurationAtStart, startTrim),
                                    (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, endTrim)] {
                    CMSetAttachment(source, key: key,
                        value: try XCTUnwrap(CMTimeCopyAsDictionary(trim, allocator: kCFAllocatorDefault)),
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                if reversed {
                    CMSetAttachment(source, key: kCMSampleBufferAttachmentKey_Reverse,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                CMSetAttachment(source, key: "VPlayer.WriterInput.Private" as CFString,
                    value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
                let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(source,
                    createIfNecessary: true))
                let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(
                    try XCTUnwrap(CFArrayGetValueAtIndex(attachments, 0))).takeUnretainedValue()
                CFDictionarySetValue(dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())

                let wrapped = try SampleBufferBuilder.makeWriterInputSample(source, lifetime: WriterInputLifetime())
                let pts = CMSampleBufferGetPresentationTimeStamp(source)
                let expected = reversed
                    ? CMTimeSubtract(CMTimeAdd(pts, CMSampleBufferGetDuration(source)), endTrim)
                    : CMTimeAdd(pts, startTrim)
                assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(wrapped), expected)
                try assertWriterInputMatches(wrapped, source, packetized: packetized)
            }
        }
    }

    func testWriterInputPreservesExplicitOutputTimestampEvenWhenItEqualsCalculatedValue() throws {
        for packetized in [false, true] {
            for shifted in [false, true] {
                let source = try makeWriterInputSource(packetized: packetized)
                let calculated = CMSampleBufferGetOutputPresentationTimeStamp(source)
                let explicit = shifted ? CMTime(value: 91, timescale: 7) : calculated
                let before = writerAttachments(source, mode: kCMAttachmentMode_ShouldPropagate)
                let outputTiming = try WriterInputOutputTiming.settingExplicit(explicit, on: source)
                print("HLS_WRITER_OUTPUT_ATTACHMENT_COUNTS fixture=explicit-override "
                    + "packetized=\(packetized) shifted=\(shifted) before=\(before?.count ?? -1) "
                    + "after=\(writerAttachments(source, mode: kCMAttachmentMode_ShouldPropagate)?.count ?? -1)")

                let wrapped = try SampleBufferBuilder.makeWriterInputSample(source, lifetime: WriterInputLifetime(),
                    outputTiming: outputTiming)
                assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(wrapped), explicit)
                try assertWriterInputMatches(wrapped, source, packetized: packetized)

                for sample in [source, wrapped] {
                    CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                        value: try XCTUnwrap(CMTimeCopyAsDictionary(
                            CMTime(value: 128, timescale: 48_000), allocator: kCFAllocatorDefault)),
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(wrapped), explicit)
                try assertWriterInputMatches(wrapped, source, packetized: packetized)
            }
        }
    }

    func testWriterInputRejectsExplicitIntentThatNoLongerMatchesSource() throws {
        let source = try makeWriterInputSource(packetized: true)
        let outputTiming = try WriterInputOutputTiming.settingExplicit(CMTime(value: 10, timescale: 1), on: source)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(source,
            newValue: CMTime(value: 480_000, timescale: 48_000)), noErr)
        XCTAssertFalse(outputTiming.matchesSource(source), "Equivalent fractions do not satisfy exact recorded intent")
        XCTAssertThrowsError(try SampleBufferBuilder.makeWriterInputSample(source,
            lifetime: WriterInputLifetime(), outputTiming: outputTiming))
        assertExactTime(CMSampleBufferGetOutputPresentationTimeStamp(source),
            CMTime(value: 480_000, timescale: 48_000))
    }

    func testHLSOwnedBlockChargesBeforeCopyAndRetainsChargeWhileInputOverlaps() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: 32,
            applicationLedger: ledger
        )
        let admission = HLSOwnedBlockAdmission(
            maximumPayloadBytes: 32,
            capacity: 1,
            applicationLedger: ledger
        )
        let input = Data([0x10, 0x20, 0x30, 0x40])
        let inputLease = try XCTUnwrap(inputAdmission.acquire(
            units: 1,
            bytes: input.count,
            applicationBytes: input.count
        ))

        let block = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
            copying: input.span,
            admission: admission
        )

        let blockCharge = input.count + HLSOwnedBlockAdmission.fixedOwnerMetadataBytes
        XCTAssertEqual(admission.debugAllocationChargeSnapshot, input.count + blockCharge)
        XCTAssertEqual(ledger.chargedBytes, input.count + blockCharge)
        XCTAssertEqual(try copiedBlockData(block), input)
        XCTAssertEqual(input, Data([0x10, 0x20, 0x30, 0x40]))
        inputLease.release()
        XCTAssertEqual(ledger.chargedBytes, blockCharge)
    }

    func testHLSOwnedBlockKeepsChargeUntilLastBufferReferenceAfterSampleRelease() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSOwnedBlockAdmission(
            maximumPayloadBytes: 32,
            applicationLedger: ledger
        )
        let expectedCharge = 4 + HLSOwnedBlockAdmission.fixedOwnerMetadataBytes
        let input = Data([0xAB, 0xCD, 0xEF, 0x01])
        var reference: CMBlockBuffer? = try makeHLSBufferReferenceAlias(
            input: input,
            admission: admission
        )

        XCTAssertEqual(ledger.chargedBytes, expectedCharge)
        XCTAssertEqual(try copiedBlockData(try XCTUnwrap(reference)), Data([0xAB, 0xCD, 0xEF, 0x01]))

        reference = nil
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    func testHLSOwnedBlockFailureSeamsReleaseAdmissionExactlyOnce() throws {
        for mode in HLSOwnedBlockAdmission.ConstructionMode.allCases where mode != .normal {
            let ledger = HLSDeliveryApplicationChargeLedger()
            let admission = HLSOwnedBlockAdmission(
                maximumPayloadBytes: 32,
                applicationLedger: ledger,
                constructionMode: mode
            )
            let input = Data([0x01, 0x02, 0x03, 0x04])

            var didThrow = false
            do {
                _ = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
                    copying: input.span,
                    admission: admission
                )
            } catch {
                didThrow = true
            }
            XCTAssertTrue(didThrow, "构造接缝 \(mode) 必须失败")
            XCTAssertEqual(ledger.chargedBytes, 0, "\(mode) 不得遗留 application charge")
            XCTAssertEqual(admission.usage.count, 0, "\(mode) 不得遗留 local lease")
            switch mode {
            case .normal:
                XCTFail("normal 不属于失败接缝")
            case .failBeforeAllocation:
                XCTAssertEqual(admission.allocationAttemptCount, 0)
                XCTAssertEqual(admission.freeBlockCount, 0)
            case .failAllocation:
                XCTAssertEqual(admission.allocationAttemptCount, 1, "必须实际调用 AllocateBlock")
                XCTAssertEqual(admission.freeBlockCount, 0, "未提供 block 时 SDK 不得调用 FreeBlock")
            case .failAfterAllocation,
                 .failAfterAllocationFreeBeforeReturn,
                 .failAfterAllocationFreeDuringFailureCleanup:
                XCTAssertEqual(admission.allocationAttemptCount, 1, "已分配失败必须真的进入 AllocateBlock")
                XCTAssertEqual(admission.freeBlockCount, 1, "已提供 block 后必须由唯一 FreeBlock 释放")
                if mode == .failAfterAllocationFreeBeforeReturn {
                    XCTAssertEqual(admission.debugFreeBlockCountBeforeFailureCleanup, 1)
                }
                if mode == .failAfterAllocationFreeDuringFailureCleanup {
                    XCTAssertEqual(admission.debugFreeBlockCountBeforeFailureCleanup, 0)
                }
            }
            XCTAssertEqual(admission.refConReleaseCount, 1, "每个失败分支只能消费一次 refCon")
        }
    }

    func testHLSOwnedBlockPermanentRejectionDoesNotAllocateOrCharge() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSOwnedBlockAdmission(
            maximumPayloadBytes: 3,
            applicationLedger: ledger
        )

        let input = Data([0x01, 0x02, 0x03, 0x04])
        var didThrow = false
        do {
            _ = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
                copying: input.span,
                admission: admission
            )
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow)
        XCTAssertEqual(ledger.chargedBytes, 0)
        XCTAssertEqual(admission.usage.count, 0)
    }

    func testHLSOwnedBlockWaiterAdvancesAfterAliasReleaseAndLocalCancellationIsIndependent() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSOwnedBlockAdmission(
            maximumPayloadBytes: 32,
            capacity: 1,
            applicationLedger: ledger
        )
        let input = Data([0x01, 0x02, 0x03, 0x04])
        var block: CMBlockBuffer? = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
            copying: input.span,
            admission: admission
        )
        var alias: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithBufferReference(
                allocator: kCFAllocatorDefault,
                referenceBuffer: try XCTUnwrap(block),
                offsetToData: 0,
                dataLength: input.count,
                flags: 0,
                blockBufferOut: &alias
            ),
            noErr
        )
        block = nil

        let completed = expectation(description: "外部 alias 释放后 waiter 获得真实 local slot")
        let releasedWaiter = WorkerOutcome()
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            let payload = Data([0x05, 0x06, 0x07, 0x08])
            do {
                _ = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
                    copying: payload.span,
                    admission: admission
                )
                releasedWaiter.set(true)
            } catch {
                releasedWaiter.set(false)
            }
        }
        XCTAssertTrue(admission.waitUntilWaitingCount(1), "第二个 producer 必须实际等待 local admission")
        alias = nil
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(releasedWaiter.value)

        let held = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
            copying: input.span,
            admission: admission
        )
        let cancelled = expectation(description: "等待中的 local admission 被 cancel 唤醒")
        let observedExpectedCancellation = WorkerOutcome()
        DispatchQueue.global().async {
            defer { cancelled.fulfill() }
            let payload = Data([0x09, 0x0A, 0x0B, 0x0C])
            do {
                _ = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
                    copying: payload.span,
                    admission: admission
                )
            } catch let error as HLSOwnedBlockAdmissionError {
                observedExpectedCancellation.set(error == .cancelled)
            } catch {
                observedExpectedCancellation.set(false)
            }
        }
        XCTAssertTrue(admission.waitUntilWaitingCount(1), "cancel 前第二个 producer 必须已进入真实等待")
        admission.cancel()
        wait(for: [cancelled], timeout: 2)
        XCTAssertTrue(observedExpectedCancellation.value)
        XCTAssertEqual(
            ledger.chargedBytes,
            input.count + HLSOwnedBlockAdmission.fixedOwnerMetadataBytes,
            "cancel 只关闭 local admission，已持有原 block 的费用仍在"
        )
        let sibling = HLSOwnedBlockAdmission(
            maximumPayloadBytes: 32,
            applicationLedger: ledger
        )
        var siblingError: Error?
        do {
            _ = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
                copying: input.span,
                admission: sibling
            )
        } catch {
            siblingError = error
        }
        XCTAssertNil(siblingError)
        _ = held
    }

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
        codec: VPlayerPlayback.AudioCodec, sampleRate: Int32 = 48_000
    ) throws -> CMAudioFormatDescription {
        let format: SystemCompressedAudioFormat
        switch codec {
        case .aac:
            format = SystemCompressedAudioFormat(
                profileID: .aacLC,
                codec: .aac,
                formatID: kAudioFormatMPEG4AAC,
                sampleRate: sampleRate,
                channelCount: 2,
                framesPerPacket: 1_024,
                layout: .bitmap(AudioChannelBitmap(rawValue: 3)),
                magicCookie: sampleRate == 44_100 ? Data([0x12, 0x10]) : Data([0x11, 0x90])
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

    private func makeWriterInputSource(packetized: Bool) throws -> CMSampleBuffer {
        let audio = try SampleBufferBuilder.makeAudio(frame: makeAdmittedFrame(),
            formatDescription: makeFormat(codec: .aac), forceResetDecoderBeforeDecoding: false)
        if packetized { return audio }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1_024, timescale: 48_000),
            presentationTimeStamp: CMTime(value: 48_000, timescale: 48_000),
            decodeTimeStamp: CMTime(value: 47_000, timescale: 48_000))
        var size = CMSampleBufferGetTotalSampleSize(audio)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(CMSampleBufferGetDataBuffer(audio)), formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    private func writerAttachments(_ sample: CMSampleBuffer, mode: CMAttachmentMode) -> NSDictionary? {
        CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample,
            attachmentMode: mode).map { $0 as NSDictionary }
    }

    private func makeWriterAACSource(sampleRate: Int32, sampleCount: Int,
                                     timings: [CMSampleTimingInfo]) throws -> CMSampleBuffer {
        let payload = Data(repeating: 0x5A, count: sampleCount * 4)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
            flags: 0, blockBufferOut: &block), noErr)
        let backing = try XCTUnwrap(block)
        XCTAssertEqual(payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: backing,
                offsetIntoDestination: 0, dataLength: bytes.count)
        }, noErr)
        var size = 4
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: backing,
            formatDescription: try makeFormat(codec: .aac, sampleRate: sampleRate),
            sampleCount: sampleCount, sampleTimingEntryCount: timings.count, sampleTimingArray: timings,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    private func assertExactTime(_ actual: CMTime, _ expected: CMTime,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.value, expected.value, file: file, line: line)
        XCTAssertEqual(actual.timescale, expected.timescale, file: file, line: line)
        XCTAssertEqual(actual.flags, expected.flags, file: file, line: line)
        XCTAssertEqual(actual.epoch, expected.epoch, file: file, line: line)
    }

    private func assertWriterInputMatches(_ actual: CMSampleBuffer, _ expected: CMSampleBuffer,
                                          packetized: Bool, file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        XCTAssertNotEqual(ObjectIdentifier(actual), ObjectIdentifier(expected), file: file, line: line)
        XCTAssertEqual(CMSampleBufferGetFormatDescription(actual).map(ObjectIdentifier.init),
            CMSampleBufferGetFormatDescription(expected).map(ObjectIdentifier.init), file: file, line: line)
        XCTAssertEqual(CMSampleBufferGetNumSamples(actual), CMSampleBufferGetNumSamples(expected),
            file: file, line: line)
        for (actualTime, expectedTime) in [
            (CMSampleBufferGetDuration(actual), CMSampleBufferGetDuration(expected)),
            (CMSampleBufferGetPresentationTimeStamp(actual), CMSampleBufferGetPresentationTimeStamp(expected)),
            (CMSampleBufferGetDecodeTimeStamp(actual), CMSampleBufferGetDecodeTimeStamp(expected)),
            (CMSampleBufferGetOutputPresentationTimeStamp(actual), CMSampleBufferGetOutputPresentationTimeStamp(expected)),
            (CMSampleBufferGetOutputDecodeTimeStamp(actual), CMSampleBufferGetOutputDecodeTimeStamp(expected)),
            (CMSampleBufferGetOutputDuration(actual), CMSampleBufferGetOutputDuration(expected))
        ] {
            assertExactTime(actualTime, expectedTime, file: file, line: line)
        }
        for index in 0..<CMSampleBufferGetNumSamples(expected) {
            var actualTiming = CMSampleTimingInfo(), expectedTiming = CMSampleTimingInfo()
            XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(actual, at: index, timingInfoOut: &actualTiming),
                noErr, file: file, line: line)
            XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(expected, at: index, timingInfoOut: &expectedTiming),
                noErr, file: file, line: line)
            assertExactTime(actualTiming.duration, expectedTiming.duration, file: file, line: line)
            assertExactTime(actualTiming.presentationTimeStamp, expectedTiming.presentationTimeStamp, file: file, line: line)
            assertExactTime(actualTiming.decodeTimeStamp, expectedTiming.decodeTimeStamp, file: file, line: line)
            XCTAssertEqual(CMSampleBufferGetSampleSize(actual, at: index), CMSampleBufferGetSampleSize(expected, at: index),
                file: file, line: line)
        }
        var actualTimingCount = 0, expectedTimingCount = 0
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(actual, entryCount: 0,
            arrayToFill: nil, entriesNeededOut: &actualTimingCount), noErr, file: file, line: line)
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(expected, entryCount: 0,
            arrayToFill: nil, entriesNeededOut: &expectedTimingCount), noErr, file: file, line: line)
        XCTAssertEqual(actualTimingCount, expectedTimingCount, file: file, line: line)
        guard (1...64).contains(actualTimingCount), actualTimingCount == expectedTimingCount else {
            XCTFail("Timing arrays must retain the same bounded shape", file: file, line: line)
            return
        }
        var actualTimings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: actualTimingCount)
        var expectedTimings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: expectedTimingCount)
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(actual, entryCount: actualTimingCount,
            arrayToFill: &actualTimings, entriesNeededOut: nil), noErr, file: file, line: line)
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(expected, entryCount: expectedTimingCount,
            arrayToFill: &expectedTimings, entriesNeededOut: nil), noErr, file: file, line: line)
        for index in actualTimings.indices {
            assertExactTime(actualTimings[index].duration, expectedTimings[index].duration, file: file, line: line)
            assertExactTime(actualTimings[index].presentationTimeStamp, expectedTimings[index].presentationTimeStamp,
                file: file, line: line)
            assertExactTime(actualTimings[index].decodeTimeStamp, expectedTimings[index].decodeTimeStamp,
                file: file, line: line)
        }
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            // Buffer attachment facts are keyed entries. Empty dictionary storage
            // is not transferred by CMSetAttachments, which applies each entry.
            XCTAssertTrue((writerAttachments(actual, mode: mode) ?? NSDictionary())
                == (writerAttachments(expected, mode: mode) ?? NSDictionary()),
                "attachmentMode=\(mode)", file: file, line: line)
        }
        XCTAssertTrue(CMSampleBufferGetSampleAttachmentsArray(actual, createIfNecessary: false).map { $0 as NSArray }
            == CMSampleBufferGetSampleAttachmentsArray(expected, createIfNecessary: false).map { $0 as NSArray },
            file: file, line: line)
        XCTAssertEqual(try copiedBlockData(XCTUnwrap(CMSampleBufferGetDataBuffer(actual))),
            try copiedBlockData(XCTUnwrap(CMSampleBufferGetDataBuffer(expected))), file: file, line: line)
        if packetized {
            var actualPackets: UnsafePointer<AudioStreamPacketDescription>?
            var expectedPackets: UnsafePointer<AudioStreamPacketDescription>?
            var actualBytes = 0, expectedBytes = 0
            XCTAssertEqual(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(actual,
                packetDescriptionsPointerOut: &actualPackets, sizeOut: &actualBytes), noErr, file: file, line: line)
            XCTAssertEqual(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(expected,
                packetDescriptionsPointerOut: &expectedPackets, sizeOut: &expectedBytes), noErr, file: file, line: line)
            let count = CMSampleBufferGetNumSamples(expected)
            let requiredBytes = count * MemoryLayout<AudioStreamPacketDescription>.stride
            XCTAssertEqual(actualBytes, requiredBytes, file: file, line: line)
            XCTAssertEqual(expectedBytes, actualBytes, file: file, line: line)
            guard actualBytes >= requiredBytes, expectedBytes >= requiredBytes else { return }
            let actualDescriptions = try XCTUnwrap(actualPackets, file: file, line: line)
            let expectedDescriptions = try XCTUnwrap(expectedPackets, file: file, line: line)
            for index in 0..<count {
                XCTAssertEqual(actualDescriptions[index].mStartOffset, expectedDescriptions[index].mStartOffset,
                    file: file, line: line)
                XCTAssertEqual(actualDescriptions[index].mVariableFramesInPacket, expectedDescriptions[index].mVariableFramesInPacket,
                    file: file, line: line)
                XCTAssertEqual(actualDescriptions[index].mDataByteSize, expectedDescriptions[index].mDataByteSize,
                    file: file, line: line)
            }
        }
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

    private func copiedBlockData(_ block: CMBlockBuffer) throws -> Data {
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        XCTAssertEqual(status, noErr)
        return data
    }

    private func makeReadySample(dataBuffer: CMBlockBuffer) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = CMBlockBufferGetDataLength(dataBuffer)
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: dataBuffer,
                formatDescription: nil,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample
            ),
            noErr
        )
        return try XCTUnwrap(sample)
    }

    private func makeHLSBufferReferenceAlias(
        input: Data,
        admission: HLSOwnedBlockAdmission
    ) throws -> CMBlockBuffer {
        var block: CMBlockBuffer? = try SampleBufferBuilder.makeHLSOwnedBlockBuffer(
            copying: input.span,
            admission: admission
        )
        var sample: CMSampleBuffer? = try makeReadySample(dataBuffer: try XCTUnwrap(block))
        var reference: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithBufferReference(
                allocator: kCFAllocatorDefault,
                referenceBuffer: try XCTUnwrap(CMSampleBufferGetDataBuffer(try XCTUnwrap(sample))),
                offsetToData: 0,
                dataLength: input.count,
                flags: 0,
                blockBufferOut: &reference
            ),
            noErr
        )
        sample = nil
        block = nil
        return try XCTUnwrap(reference)
    }

    private final class WorkerOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ value: Bool) {
            lock.lock()
            storage = value
            lock.unlock()
        }
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
