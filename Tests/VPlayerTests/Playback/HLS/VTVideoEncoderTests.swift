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

final class VTVideoEncoderTests: XCTestCase {
    func testSynchronousNativeOutputIsCopiedBeforeWorkQueuePublication() throws {
        let api = FakeVTCompressionAPI()
        api.synchronousOutput = .success(sampleBuffer: try makeCompressedSampleBuffer())
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(
            maximumPayloadBytes: 4_096,
            applicationLedger: ledger
        )
        let encoder = try makeEncoder(api: api, compressedOutputOwnership: ownership)
        let captureCharge = LockedCounter()
        api.synchronousOutputDelivered = { if ledger.chargedBytes > 0 { captureCharge.increment() } }
        let completion = expectation(description: "owned compressed output")
        encoder.encode(frame: try makeFrame(id: 1)) { result in
            guard case let .success(output) = result else {
                XCTFail("同步 native output 应在首次 capture 时复制")
                return
            }
            XCTAssertTrue(CMSampleBufferDataIsReady(output.sampleBuffer))
            XCTAssertGreaterThan(ledger.chargedBytes, 0)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)
        XCTAssertEqual(captureCharge.value, 1,
                       "native encode 返回前的同步 callback 已首次捕获并收费")
    }

    func testAsynchronousNativeOutputIsCopiedBeforePublication() throws {
        let api = FakeVTCompressionAPI()
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(maximumPayloadBytes: 4_096, applicationLedger: ledger)
        let encoder = try makeEncoder(api: api, compressedOutputOwnership: ownership)
        let completion = expectation(description: "异步 owned compressed output")
        encoder.encode(frame: try makeFrame(id: 1)) { result in
            guard case .success = result else { return XCTFail("异步输出必须复制") }
            XCTAssertGreaterThan(ledger.chargedBytes, 0)
            completion.fulfill()
        }
        api.drain()
        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
        wait(for: [completion], timeout: 2)
    }

    func testDroppedCallbackWithSamplePreservesNativeFlagsWithoutCopying() throws {
        let api = FakeVTCompressionAPI()
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(maximumPayloadBytes: 4_096, applicationLedger: ledger)
        api.synchronousOutput = .init(status: noErr, infoFlags: [.frameDropped],
                                      sampleBuffer: try makeCompressedSampleBuffer())
        let encoder = try makeEncoder(api: api, compressedOutputOwnership: ownership)
        let completion = expectation(description: "dropped")
        encoder.encode(frame: try makeFrame(id: 1)) { result in
            guard case let .failure(failure) = result else {
                return XCTFail("frameDropped 不得变成 success")
            }
            XCTAssertEqual(failure, .frameDropped)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)
        XCTAssertEqual(encoder.terminal, .failed(.frameDropped))
        XCTAssertEqual(ledger.chargedBytes, 0, "原生 frameDropped 不能被 copy 成 success")
    }

    func testRepeatedCallbackClaimsOnlyOneOutputBeforeCopying() throws {
        let api = FakeVTCompressionAPI()
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(maximumPayloadBytes: 4_096, applicationLedger: ledger)
        let encoder = try makeEncoder(api: api, compressedOutputOwnership: ownership)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(id: 1)) { recorder.record($0) }
        api.drain()
        let sample = try makeCompressedSampleBuffer()
        api.deliverFirst(.success(sampleBuffer: sample), retainingCallback: true)
        api.redeliverRetained(.success(sampleBuffer: sample))
        api.drain()
        XCTAssertEqual(recorder.successes.count, 1)
        guard let owned = recorder.successes.first else { return }
        XCTAssertEqual(ledger.chargedBytes,
                       CMSampleBufferGetTotalSampleSize(owned.sampleBuffer) +
                           HLSOwnedBlockAdmission.fixedOwnerMetadataBytes)
    }

    func testCancelWakesBlockedCompressedCopyBeforeNativeInvalidate() throws {
        let api = FakeVTCompressionAPI()
        api.holdNextInvalidate()
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(maximumPayloadBytes: 4_096, capacity: 1,
                                               applicationLedger: ledger)
        var retained: CMSampleBuffer? = try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
            makeCompressedSampleBuffer(), ownership: ownership)
        let encoder = try makeEncoder(api: api, compressedOutputOwnership: ownership)
        encoder.encode(frame: try makeFrame(id: 1)) { _ in }
        api.drain()
        let blockedOutput = TestCMSampleBufferBox(try makeCompressedSampleBuffer())
        DispatchQueue.global().async {
            api.deliverFirst(.success(sampleBuffer: blockedOutput.value))
        }
        XCTAssertTrue(ownership.compressedOutputBlockAdmission.waitUntilWaitingCount(1))
        let receipt = CancellationReceiptRecorder()
        encoder.cancel { receipt.record($0) }
        XCTAssertTrue(api.waitUntilInvalidateEntered())
        api.releaseHeldInvalidate()
        api.drain()
        XCTAssertEqual(receipt.value, true)
        XCTAssertEqual(api.snapshot.invalidatedSessionIDs.count, 1)
        withExtendedLifetime(retained) {}
        retained = nil
    }

    func testConcurrentClaimWaitingForCopyPublishesAfterEncodeReturns() throws {
        let api = FakeVTCompressionAPI()
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(maximumPayloadBytes: 4_096, capacity: 1,
                                               applicationLedger: ledger)
        var retained: CMSampleBuffer? = try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
            makeCompressedSampleBuffer(), ownership: ownership)
        api.concurrentOutputBeforeEncodeReturn = .success(sampleBuffer: try makeCompressedSampleBuffer())
        let encoder = try makeEncoder(api: api, compressedOutputOwnership: ownership)
        let completion = expectation(description: "concurrent callback must publish once")
        encoder.encode(frame: try makeFrame(id: 1)) { result in
            guard case .success = result else { return XCTFail("copy 解锁后唯一输出必须发布") }
            completion.fulfill()
        }
        XCTAssertTrue(ownership.compressedOutputBlockAdmission.waitUntilWaitingCount(1))
        api.drain() // encode 已返回并关闭 synchronous submission，callback 仍在 copy wait。
        withExtendedLifetime(retained) {}
        retained = nil
        wait(for: [completion], timeout: 2)
    }

    func testCancelledLateNativeSampleIsNotPublishedOrBorrowed() throws {
        let api = FakeVTCompressionAPI()
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(maximumPayloadBytes: 4_096, applicationLedger: ledger)
        let encoder = try makeEncoder(api: api, compressedOutputOwnership: ownership)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(id: 1)) { recorder.record($0) }
        api.drain()
        let cancelled = expectation(description: "cancelled")
        encoder.cancel { _ in cancelled.fulfill() }
        wait(for: [cancelled], timeout: 2)
        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
        api.drain()
        XCTAssertTrue(recorder.successes.isEmpty)
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    func testOwnedCompressedCopyPreservesTimingFormatAndSampleAttachments() throws {
        let source = try makeCompressedSampleBuffer(pts: CMTime(value: 9, timescale: 50),
                                                    dts: CMTime(value: 7, timescale: 50), notSync: true)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: true))
        let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(CFArrayGetValueAtIndex(attachments, 0)!).takeUnretainedValue()
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        let nalType = NSNumber(value: 19)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_HEVCSyncSampleNALUnitType).toOpaque(),
                             Unmanaged.passUnretained(nalType).toOpaque())
        CMSetAttachment(source,
                        key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                        value: kCFBooleanTrue,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let copy = try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
            source, ownership: .init(maximumPayloadBytes: 4_096, applicationLedger: ledger))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(copy), CMSampleBufferGetPresentationTimeStamp(source))
        XCTAssertEqual(CMSampleBufferGetDecodeTimeStamp(copy), CMSampleBufferGetDecodeTimeStamp(source))
        XCTAssertEqual(CMSampleBufferGetDuration(copy), CMSampleBufferGetDuration(source))
        XCTAssertTrue(CFEqual(
            try XCTUnwrap(CMSampleBufferGetFormatDescription(copy)),
            try XCTUnwrap(CMSampleBufferGetFormatDescription(source))
        ))
        let copied = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: false))
        let copiedDictionary = Unmanaged<CFDictionary>.fromOpaque(CFArrayGetValueAtIndex(copied, 0)!).takeUnretainedValue()
        XCTAssertNotNil(CFDictionaryGetValue(copiedDictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()))
        XCTAssertNotNil(CFDictionaryGetValue(copiedDictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()))
        XCTAssertNotNil(CFDictionaryGetValue(copiedDictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_HEVCSyncSampleNALUnitType).toOpaque()))
        XCTAssertNotNil(CMGetAttachment(copy,
                                        key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                                        attachmentModeOut: nil))
    }

    func testOwnedCompressedCopyPreservesHEVCTemporalLevelInfoAfterSourceRelease() throws {
        var source: CMSampleBuffer? = try makeCompressedSampleBuffer(profile: .hevcMain)
        let expected = makeHEVCTemporalLevelInfo(compatibilityBytes: 4, constraintBytes: 6)
        try setHEVCTemporalLevelInfo(expected, on: try XCTUnwrap(source))
        let ledger = HLSDeliveryApplicationChargeLedger()
        let copy = try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
            try XCTUnwrap(source), ownership: .init(maximumPayloadBytes: 4_096, applicationLedger: ledger))
        source = nil
        let dictionary = try temporalLevelInfo(from: copy)
        XCTAssertEqual(dictionary["temporal"] as? NSNumber, 3)
        XCTAssertEqual(dictionary["profileSpace"] as? NSNumber, 1)
        XCTAssertEqual(dictionary["tier"] as? NSNumber, 1)
        XCTAssertEqual(dictionary["profile"] as? NSNumber, 2)
        XCTAssertEqual(dictionary["level"] as? NSNumber, 5)
        XCTAssertEqual(
            dictionary["compatibility"] as? Data,
            try XCTUnwrap(expected["compatibility"] as? Data)
        )
        XCTAssertEqual(
            dictionary["constraint"] as? Data,
            try XCTUnwrap(expected["constraint"] as? Data)
        )
        XCTAssertGreaterThan(ledger.chargedBytes, CMSampleBufferGetTotalSampleSize(copy) + HLSOwnedBlockAdmission.fixedOwnerMetadataBytes)
    }

    func testOwnedCompressedCopyRejectsMalformedHEVCTemporalLevelInfoBeforeCopying() throws {
        let source = try makeCompressedSampleBuffer(profile: .hevcMain)
        try setHEVCTemporalLevelInfo(makeHEVCTemporalLevelInfo(compatibilityBytes: 5, constraintBytes: 6), on: source)
        XCTAssertThrowsError(try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
            source, ownership: .init(maximumPayloadBytes: 4_096, applicationLedger: .init())))
    }

    func testOwnedCompressedCopyKeepsChargeUntilLastIndependentSampleAliasReleases() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let ownership = HLSVideoCopyOwnership(maximumPayloadBytes: 4_096, applicationLedger: ledger)
        var alias: CMSampleBuffer? = try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
            makeCompressedSampleBuffer(), ownership: ownership)
        XCTAssertGreaterThan(ledger.chargedBytes, 0)
        withExtendedLifetime(alias) {}
        alias = nil
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    func testOwnedCompressedCopyRejectsUnknownLargeAttachmentBeforeCopying() throws {
        let source = try makeCompressedSampleBuffer()
        CMSetAttachment(source,
                        key: "org.vplayer.tests.unbounded-attachment" as CFString,
                        value: Data(repeating: 0xA5, count: 8 * 1_024) as CFData,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let ledger = HLSDeliveryApplicationChargeLedger()
        XCTAssertThrowsError(try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
            source, ownership: .init(maximumPayloadBytes: 4_096, applicationLedger: ledger)
        ))
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    func testRealSystemVTCompressionCreatesPreparesAndReturnsHardwareFirstOutput()
        async throws {
        let format = makeFormat(width: 1_280, height: 720)
        let bitrate = try VTVideoBitratePolicy.freeze(
            firstTwoSecondsByteCount: 100,
            width: format.width,
            height: format.height,
            bitDepth: format.bitDepth,
            dynamicRange: format.dynamicRange)
        let generation = MediaGeneration(rawValue: 22_001)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let encoder = try VTVideoEncoder(configuration: .init(
            generation: generation,
            inputFormat: format,
            frameRate: try XCTUnwrap(MediaRational(num: 30, den: 1)),
            bitrate: bitrate,
            maximumPendingFrameCount: 4
        ), compressedOutputOwnership: .init(
            maximumPayloadBytes: 64 * 1_024 * 1_024,
            capacity: 4,
            maximumRetainedBytes: 64 * 1_024 * 1_024,
            applicationLedger: ledger
        ))
        let pixelBuffer = try makePixelBuffer(format: format)
        let identity = VideoEncodingFrameIdentity(
            generation: generation, accessUnitID: 1, sequenceNumber: 1)
        let frame = try VideoEncodingFrame(
            identity: identity,
            pixelBuffer: pixelBuffer,
            surfaceLease: VideoEncodingSurfaceLease {},
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 30),
            presentationOrigin: .raw,
            reliableFieldOrder: nil,
            inputFormatSignature: format)
        let output: HLSVideoEncodedOutput = try await withCheckedThrowingContinuation {
            continuation in
            encoder.encode(frame: frame) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(output.sourceIdentity, identity)
        XCTAssertEqual(output.hardwareProof.generation, generation)
        XCTAssertEqual(output.hardwareProof.firstOutputIdentity, identity)
        XCTAssertEqual(output.hardwareProof.profile, encoder.selectedProfile)
        XCTAssertTrue(CMSampleBufferDataIsReady(output.sampleBuffer))
        XCTAssertGreaterThan(ledger.chargedBytes, 0,
                             "真实 SystemVT 入口必须消费同一 HLS ownership")
        let finish: HLSVideoEncoderFinishReceipt = try await withCheckedThrowingContinuation {
            continuation in
            encoder.finish { continuation.resume(with: $0) }
        }
        XCTAssertEqual(finish.encodedFrameCount, 1)
        XCTAssertEqual(finish.hardwareProof, output.hardwareProof)
    }

    func testSurfaceLeaseReleasesExactlyOnceAcrossExplicitReleaseAndDeinit() {
        let counter = LockedCounter()
        var lease: VideoEncodingSurfaceLease? = VideoEncodingSurfaceLease {
            counter.increment()
        }

        lease?.release()
        lease?.release()
        lease = nil

        XCTAssertEqual(counter.value, 1)
    }

    func testBitratePolicyUsesExactTwoSecondMeasurementQualityFloorsAndFrozenEnvelope() throws {
        let cases: [(Int32, Int32, UInt8, HLSVideoDynamicRange, UInt64)] = [
            (1_280, 720, 8, .sdr, 5_000_000),
            (1_920, 1_080, 8, .sdr, 12_000_000),
            (3_840, 2_160, 8, .sdr, 30_000_000),
            (1_920, 1_080, 10, .sdr, 45_000_000),
            (1_920, 1_080, 10, .hlg, 45_000_000),
        ]
        for (width, height, bitDepth, dynamicRange, expectedAverage) in cases {
            let policy = try VTVideoBitratePolicy.freeze(
                firstTwoSecondsByteCount: 100,
                width: width,
                height: height,
                bitDepth: bitDepth,
                dynamicRange: dynamicRange
            )
            XCTAssertEqual(policy.averageBitsPerSecond, expectedAverage)
        }

        // 2 秒内 2,500,000 bytes = 10 Mbps；乘 1.10 后是 11 Mbps。
        let measured = try VTVideoBitratePolicy.freeze(
            firstTwoSecondsByteCount: 2_500_000,
            width: 1_280,
            height: 720,
            bitDepth: 8,
            dynamicRange: .sdr
        )
        XCTAssertEqual(measured.averageBitsPerSecond, 11_000_000)
        XCTAssertEqual(measured.payloadBitsPerSecond, 16_500_000)
        XCTAssertEqual(measured.dataRateLimitBytesPerSecond, 2_062_500)
        XCTAssertEqual(measured.overheadBitsPerSecond, 330_000)
        XCTAssertEqual(measured.declaredBitsPerSecond, 16_830_000)

        XCTAssertThrowsError(try VTVideoBitratePolicy.freeze(
            firstTwoSecondsByteCount: UInt64.max,
            width: 1_280,
            height: 720,
            bitDepth: 8,
            dynamicRange: .sdr
        )) { error in
            XCTAssertEqual(error as? VTVideoEncoderFailure, .arithmeticOverflow)
        }
    }

    func testCodecSelectionCoversNV12H264HEVCMainAndP010Main10() throws {
        let cases: [(OSType, Int32, Int32, VideoFormatMetadata.Transfer, VTVideoCodecProfile)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1_920, 1_080, .bt709, .h264High),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 3_840, 2_160, .bt709, .hevcMain),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 1_920, 1_080, .bt709, .hevcMain10),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 3_840, 2_160, .hlg, .hevcMain10),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, 3_840, 2_160, .pq, .hevcMain10),
        ]

        for (pixelFormat, width, height, transfer, expected) in cases {
            let api = FakeVTCompressionAPI()
            let encoder = try makeEncoder(
                api: api,
                format: makeFormat(
                    pixelFormat: pixelFormat,
                    width: width,
                    height: height,
                    transfer: transfer
                )
            )
            XCTAssertEqual(encoder.selectedProfile, expected)
            XCTAssertEqual(api.snapshot.creates.count, 1)
            encoder.cancel()
            api.drain()
        }
    }

    func testInvalidInputFailsBeforeSessionCreation() throws {
        let invalidFormats: [VideoEncodingInputFormatSignature] = [
            makeFormat(width: 3_841, height: 2_160),
            makeFormat(width: 3_840, height: 2_161),
            makeFormat(transfer: .unknown),
            makeFormat(primaries: .unknown),
            makeFormat(matrix: .unknown),
            makeFormat(range: .unknown),
            makeFormat(transfer: .hlg),
            makeFormat(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                transfer: .hlg,
                primaries: .bt709,
                matrix: .bt709
            ),
        ]
        for format in invalidFormats {
            let api = FakeVTCompressionAPI()
            XCTAssertThrowsError(try makeEncoder(api: api, format: format))
            XCTAssertTrue(api.snapshot.creates.isEmpty)
        }

        let api = FakeVTCompressionAPI()
        XCTAssertThrowsError(try makeEncoder(
            api: api,
            frameRate: try XCTUnwrap(MediaRational(num: 60_001, den: 1_000))
        )) { error in
            XCTAssertEqual(error as? VTVideoEncoderFailure, .frameRateExceeded)
        }
        XCTAssertTrue(api.snapshot.creates.isEmpty)
    }

    func testSessionConfigurationContainsHardwareRealtimeClosedGOPBitrateAndMetadata() throws {
        let mastering = Data((0..<24).map(UInt8.init))
        let light = Data([0, 1, 2, 3])
        let api = FakeVTCompressionAPI()
        _ = try makeEncoder(
            api: api,
            format: makeFormat(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                width: 3_840,
                height: 2_160,
                transfer: .hlg,
                cleanAperture: makeCleanAperture(),
                sampleAspectRatio: MediaRational(num: 4, den: 3),
                masteringDisplay: mastering,
                contentLightLevel: light
            ),
            frameRate: try XCTUnwrap(MediaRational(num: 60_000, den: 1_001))
        )

        let snapshot = api.snapshot
        XCTAssertEqual(
            snapshot.creates.first?.encoderSpecification[
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String
            ],
            .boolean(true)
        )
        let values = Dictionary(uniqueKeysWithValues: snapshot.sets.map { ($0.key, $0.value) })
        XCTAssertEqual(values[kVTCompressionPropertyKey_RealTime as String], .boolean(true))
        XCTAssertEqual(values[kVTCompressionPropertyKey_ExpectedFrameRate as String], .rational(60_000, 1_001))
        XCTAssertEqual(values[kVTCompressionPropertyKey_AllowFrameReordering as String], .boolean(false))
        XCTAssertEqual(values[kVTCompressionPropertyKey_AllowOpenGOP as String], .boolean(false))
        XCTAssertEqual(values[kVTCompressionPropertyKey_MaxKeyFrameInterval as String], .signed(60))
        XCTAssertEqual(values[kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String], .rational(1, 1))
        XCTAssertEqual(values[kVTCompressionPropertyKey_FieldCount as String], .signed(1))
        XCTAssertEqual(values[kVTCompressionPropertyKey_AverageBitRate as String], .unsigned(45_000_000))
        XCTAssertEqual(values[kVTCompressionPropertyKey_DataRateLimits as String], .array([
            .unsigned(8_437_500), .signed(1),
        ]))
        XCTAssertEqual(values[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String], .data(mastering))
        XCTAssertEqual(values[kVTCompressionPropertyKey_ContentLightLevelInfo as String], .data(light))
        XCTAssertEqual(values[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String], .string(
            kVTHDRMetadataInsertionMode_Auto as String
        ))
        XCTAssertEqual(values[kVTCompressionPropertyKey_PixelAspectRatio as String], .dictionary([
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: .signed(4),
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: .signed(3),
        ]))
        XCTAssertNotNil(values[kVTCompressionPropertyKey_CleanAperture as String])
    }

    func testH264FallsBackOnlyBeforeSubmissionWhenCreatePrepareOrHardwareProbeFails() throws {
        for failure in [FallbackFailure.create, .prepare, .hardware] {
            let api = FakeVTCompressionAPI()
            switch failure {
            case .create:
                api.createStatuses = [kVTVideoEncoderNotAvailableNowErr, noErr]
            case .prepare:
                api.prepareStatuses = [kVTVideoEncoderMalfunctionErr, noErr]
            case .hardware:
                api.hardwareResults = [.init(status: noErr, value: .boolean(false)), .hardware]
            }

            let encoder = try makeEncoder(api: api)
            XCTAssertEqual(encoder.selectedProfile, .hevcMain)
            XCTAssertEqual(api.snapshot.creates.map(\.codecType), [
                kCMVideoCodecType_H264, kCMVideoCodecType_HEVC,
            ])
            XCTAssertEqual(
                api.snapshot.invalidatedSessionIDs.count,
                failure == .create ? 0 : 1
            )
            encoder.cancel()
            api.drain()
        }
    }

    func testFirstOutputIsWithheldUntilSyncSampleAndSecondHardwareProbeSucceed() throws {
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api)
        let recorder = EncodingRecorder()
        let leaseCounter = LockedCounter()
        encoder.encode(frame: try makeFrame(id: 1, leaseCounter: leaseCounter)) {
            recorder.record($0)
        }
        api.drain()

        XCTAssertTrue(recorder.results.isEmpty)
        XCTAssertEqual(leaseCounter.value, 0)
        XCTAssertEqual(api.snapshot.hardwareCopyCount, 1)

        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
        api.drain()

        XCTAssertEqual(recorder.successes.map(\.sourceIdentity.accessUnitID), [1])
        XCTAssertEqual(leaseCounter.value, 1)
        XCTAssertEqual(api.snapshot.hardwareCopyCount, 2)
        XCTAssertNotNil(recorder.successes.first?.hardwareProof)
    }

    func testFirstDroppedNonSyncOrHardwareLostOutputFailsTerminallyWithoutPublishing() throws {
        let cases: [VTCompressionOutput] = [
            .init(status: noErr, infoFlags: [.frameDropped], sampleBuffer: nil),
            .init(status: noErr, infoFlags: [], sampleBuffer: try makeCompressedSampleBuffer(notSync: true)),
        ]
        for output in cases {
            let api = FakeVTCompressionAPI()
            api.hardwareResults = [.hardware, .hardware]
            let encoder = try makeEncoder(api: api)
            let recorder = EncodingRecorder()
            encoder.encode(frame: try makeFrame(id: 1)) { recorder.record($0) }
            api.drain()
            api.deliverFirst(output)
            api.drain()
            XCTAssertTrue(recorder.successes.isEmpty)
            guard case .failed = encoder.terminal else {
                return XCTFail("首个无效输出必须进入失败终态")
            }
        }

        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .init(status: noErr, value: .boolean(false))]
        let encoder = try makeEncoder(api: api)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(id: 1)) { recorder.record($0) }
        api.drain()
        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
        api.drain()
        XCTAssertTrue(recorder.successes.isEmpty)
        XCTAssertEqual(encoder.terminal, .failed(.hardwareEncoderNotActive))
    }

    func testSynchronousCallbackImmediateStatusFailureAndDuplicateCallbackReleaseOnce() throws {
        do {
            let api = FakeVTCompressionAPI()
            api.hardwareResults = [.hardware, .hardware]
            api.synchronousOutput = .success(sampleBuffer: try makeCompressedSampleBuffer())
            let encoder = try makeEncoder(api: api)
            let recorder = EncodingRecorder()
            let leaseCounter = LockedCounter()
            encoder.encode(frame: try makeFrame(id: 1, leaseCounter: leaseCounter)) {
                recorder.record($0)
            }
            api.drain()
            XCTAssertEqual(recorder.successes.count, 1)
            XCTAssertEqual(leaseCounter.value, 1)
        }

        do {
            let api = FakeVTCompressionAPI()
            api.encodeStatuses = [kVTVideoEncoderMalfunctionErr]
            let encoder = try makeEncoder(api: api)
            let recorder = EncodingRecorder()
            let leaseCounter = LockedCounter()
            encoder.encode(frame: try makeFrame(id: 1, leaseCounter: leaseCounter)) {
                recorder.record($0)
            }
            api.drain()
            XCTAssertEqual(recorder.failures, [.encode(kVTVideoEncoderMalfunctionErr)])
            XCTAssertEqual(leaseCounter.value, 1)
        }

        do {
            let api = FakeVTCompressionAPI()
            api.hardwareResults = [.hardware, .hardware]
            let encoder = try makeEncoder(api: api)
            let recorder = EncodingRecorder()
            let leaseCounter = LockedCounter()
            encoder.encode(frame: try makeFrame(id: 1, leaseCounter: leaseCounter)) {
                recorder.record($0)
            }
            api.drain()
            let output = VTCompressionOutput.success(
                sampleBuffer: try makeCompressedSampleBuffer()
            )
            api.deliverFirst(output, retainingCallback: true)
            api.drain()
            api.redeliverRetained(output)
            api.drain()
            XCTAssertEqual(recorder.results.count, 1)
            XCTAssertEqual(leaseCounter.value, 1)
        }
    }

    func testSlowFirstCallbackKeepsBothFieldsSubmittedToHardwareConcurrently() throws {
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api)
        let recorder = EncodingRecorder()
        let firstLease = LockedCounter()
        let secondLease = LockedCounter()
        encoder.encode(frame: try makeFrame(
            id: 1,
            sequence: 1,
            origin: .metalYADIF(field: .top),
            reliableOrder: .init(parity: .top, confidence: .signaled, source: .parser),
            leaseCounter: firstLease
        )) { recorder.record($0) }
        encoder.encode(frame: try makeFrame(
            id: 1,
            sequence: 2,
            pts: CMTime(value: 1, timescale: 50),
            origin: .metalYADIF(field: .bottom),
            reliableOrder: .init(parity: .top, confidence: .signaled, source: .parser),
            leaseCounter: secondLease
        )) { recorder.record($0) }
        api.drain()

        XCTAssertEqual(
            api.snapshot.encodes.map(\.sequenceNumber),
            [1, 2],
            "25i→50p 必须让两个场同时在 VT 编码流水线中，不能每个 callback 串行一场"
        )
        XCTAssertEqual(firstLease.value, 0)
        XCTAssertEqual(secondLease.value, 0)

        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
        api.drain()
        XCTAssertEqual(api.snapshot.encodes.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(firstLease.value, 1)
        XCTAssertEqual(secondLease.value, 0)

        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
            pts: CMTime(value: 1, timescale: 50)
        )))
        api.drain()
        XCTAssertEqual(recorder.successes.map(\.sourceIdentity.sequenceNumber), [1, 2])
        XCTAssertEqual(secondLease.value, 1)
    }

    func testBackpressureRejectsOnlyNewFrameAndDrainsAcceptedFieldPair() throws {
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api, maximumPendingFrameCount: 2)
        let accepted = EncodingRecorder()
        let rejected = EncodingRecorder()
        let firstLease = LockedCounter()
        let secondLease = LockedCounter()
        let rejectedLease = LockedCounter()

        encoder.encode(frame: try makeFrame(
            id: 1,
            sequence: 1,
            origin: .metalYADIF(field: .top),
            reliableOrder: .init(parity: .top, confidence: .signaled, source: .parser),
            leaseCounter: firstLease
        )) { accepted.record($0) }
        encoder.encode(frame: try makeFrame(
            id: 1,
            sequence: 2,
            pts: CMTime(value: 1, timescale: 50),
            origin: .metalYADIF(field: .bottom),
            reliableOrder: .init(parity: .top, confidence: .signaled, source: .parser),
            leaseCounter: secondLease
        )) { accepted.record($0) }
        encoder.encode(frame: try makeFrame(
            id: 2,
            sequence: 3,
            pts: CMTime(value: 2, timescale: 50),
            leaseCounter: rejectedLease
        )) { rejected.record($0) }
        api.drain()

        XCTAssertEqual(rejected.failures, [.backpressureExceeded])
        XCTAssertNil(encoder.terminal)
        XCTAssertEqual(firstLease.value, 0)
        XCTAssertEqual(secondLease.value, 0)
        XCTAssertEqual(rejectedLease.value, 1)

        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
        api.drain()
        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
            pts: CMTime(value: 1, timescale: 50)
        )))
        api.drain()

        XCTAssertEqual(accepted.successes.map(\.sourceIdentity.sequenceNumber), [1, 2])
        XCTAssertEqual(firstLease.value, 1)
        XCTAssertEqual(secondLease.value, 1)
        XCTAssertNil(encoder.terminal)
    }

    func testDroppingLastEncoderReferenceKeepsSurfaceLeaseUntilNativeCallback() throws {
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let leaseCounter = LockedCounter()
        var encoder: VTVideoEncoder? = try makeEncoder(api: api)
        encoder?.encode(frame: try makeFrame(id: 1, leaseCounter: leaseCounter)) { _ in }
        api.drain()

        encoder = nil
        XCTAssertEqual(leaseCounter.value, 0)

        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
        api.drain()
        XCTAssertEqual(leaseCounter.value, 1)
    }

    func testUnreliableFieldOrderFailsBeforeNativeEncode() throws {
        let orders: [ResolvedFieldOrder?] = [
            nil,
            .init(parity: .top, confidence: .assumed, source: .none),
            .init(parity: .bottom, confidence: .assumed, source: .contentProbe),
        ]
        for order in orders {
            let api = FakeVTCompressionAPI()
            let encoder = try makeEncoder(api: api)
            let recorder = EncodingRecorder()
            encoder.encode(frame: try makeFrame(
                id: 1,
                origin: .metalYADIF(field: .top),
                reliableOrder: order
            )) { recorder.record($0) }
            api.drain()
            XCTAssertTrue(api.snapshot.encodes.isEmpty)
            XCTAssertEqual(recorder.failures, [.unreliableFieldOrder])
        }
    }

    func testFinishAndCancelClosePendingLeasesAndIgnoreLateCallbacks() throws {
        do {
            let api = FakeVTCompressionAPI()
            api.hardwareResults = [.hardware, .hardware]
            let encoder = try makeEncoder(api: api)
            let outputRecorder = EncodingRecorder()
            let finishRecorder = FinishRecorder()
            encoder.encode(frame: try makeFrame(id: 1)) { outputRecorder.record($0) }
            encoder.finish { finishRecorder.record($0) }
            api.drain()
            XCTAssertTrue(api.snapshot.completedSessionIDs.isEmpty)
            api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
            api.drain()
            XCTAssertEqual(api.snapshot.completedSessionIDs.count, 1)
            XCTAssertEqual(api.snapshot.invalidatedSessionIDs.count, 1)
            XCTAssertEqual(finishRecorder.successes.first?.encodedFrameCount, 1)
            XCTAssertEqual(encoder.terminal, .finished)
            let cancelledAfterFinish = expectation(description: "finished 读取同一 native 完成事实")
            encoder.cancel { receipt in
                XCTAssertTrue(receipt)
                cancelledAfterFinish.fulfill()
            }
            wait(for: [cancelledAfterFinish], timeout: 2)
            XCTAssertEqual(api.snapshot.invalidatedSessionIDs.count, 1,
                           "finished 后读取 receipt 不得第二次 invalidate")
        }

        do {
            let api = FakeVTCompressionAPI()
            let encoder = try makeEncoder(api: api)
            let recorder = EncodingRecorder()
            let leaseCounter = LockedCounter()
            encoder.encode(frame: try makeFrame(id: 1, leaseCounter: leaseCounter)) {
                recorder.record($0)
            }
            api.drain()
            encoder.cancel()
            api.drain()
            XCTAssertEqual(leaseCounter.value, 1)
            XCTAssertEqual(recorder.failures, [.cancelled])
            XCTAssertEqual(encoder.terminal, .cancelled)
            XCTAssertEqual(api.snapshot.invalidatedSessionIDs.count, 1)
            api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer()))
            api.drain()
            XCTAssertEqual(recorder.results.count, 1)
            XCTAssertEqual(leaseCounter.value, 1)
        }
    }

    func testCancelCompletionWaitsForNativeInvalidateReturnAndCancelledEncoderReusesReceipt() throws {
        let api = FakeVTCompressionAPI()
        api.holdNextInvalidate()
        let encoder = try makeEncoder(api: api)
        let first = expectation(description: "native invalidate 返回后才交付 cancel receipt")
        let firstReceipt = CancellationReceiptRecorder()

        encoder.cancel { receipt in
            firstReceipt.record(receipt)
            first.fulfill()
        }
        XCTAssertTrue(api.waitUntilInvalidateEntered(), "cancel 必须实际进入 VT native lane")
        XCTAssertNil(firstReceipt.value, "api.invalidate 未返回前不得以 terminal 快照交付成功")
        api.releaseHeldInvalidate()
        wait(for: [first], timeout: 2)
        XCTAssertEqual(firstReceipt.value, true)

        let second = expectation(description: "完成后的读取复用同一 native receipt")
        encoder.cancel { receipt in
            XCTAssertTrue(receipt)
            second.fulfill()
        }
        wait(for: [second], timeout: 2)
        XCTAssertEqual(api.snapshot.invalidatedSessionIDs.count, 1,
                       "读取已确认 receipt 不得再次调用 native invalidate")
    }

    func testH264CapabilityPropertyFailureFallsBackButParameterFailureDoesNot() throws {
        do {
            let api = FakeVTCompressionAPI()
            api.propertyStatuses = [kVTPropertyNotSupportedErr]
            let encoder = try makeEncoder(api: api)
            XCTAssertEqual(encoder.selectedProfile, .hevcMain)
            XCTAssertEqual(api.snapshot.creates.map(\.codecType), [
                kCMVideoCodecType_H264, kCMVideoCodecType_HEVC,
            ])
            encoder.cancel()
            api.drain()
        }

        do {
            let api = FakeVTCompressionAPI()
            api.propertyStatuses = [kVTParameterErr]
            XCTAssertThrowsError(try makeEncoder(api: api)) { error in
                guard case let .propertySet(_, status) = error as? VTVideoEncoderFailure else {
                    return XCTFail("非法参数必须保留原始 typed failure")
                }
                XCTAssertEqual(status, kVTParameterErr)
            }
            XCTAssertEqual(api.snapshot.creates.map(\.codecType), [kCMVideoCodecType_H264])
        }
    }

    func testFirstOutputRejectsMissingTruncatedOrMismatchedAVCCAndHVCC() throws {
        struct Fixture {
            let name: String
            let format: VideoEncodingInputFormatSignature
            let profile: VTVideoCodecProfile
            let atom: CodecConfigurationAtomFixture
        }
        let h264 = makeFormat()
        let hevcMain = makeFormat(width: 3_840, height: 2_160)
        let hevcMain10 = makeFormat(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let fixtures: [Fixture] = [
            .init(name: "缺少 avcC", format: h264, profile: .h264High, atom: .missing),
            .init(name: "截断 avcC", format: h264, profile: .h264High, atom: .bytes(Data([1, 100]))),
            .init(
                name: "H.264 profile 错误",
                format: h264,
                profile: .h264High,
                atom: .bytes(makeAVCC(profileIDC: 77, bitDepthMinus8: 0))
            ),
            .init(
                name: "H.264 bit depth 错误",
                format: h264,
                profile: .h264High,
                atom: .bytes(makeAVCC(profileIDC: 100, bitDepthMinus8: 2))
            ),
            .init(
                name: "H.264 avcC 与 SPS profile 不一致",
                format: h264,
                profile: .h264High,
                atom: .bytes(makeAVCC(
                    profileIDC: 100,
                    bitDepthMinus8: 0,
                    spsProfileIDC: 77
                ))
            ),
            .init(
                name: "H.264 avcC 与 SPS bit depth 不一致",
                format: h264,
                profile: .h264High,
                atom: .bytes(makeAVCC(
                    profileIDC: 100,
                    bitDepthMinus8: 0,
                    spsBitDepthMinus8: 2
                ))
            ),
            .init(
                name: "H.264 SPS 在 bit depth 后截断",
                format: h264,
                profile: .h264High,
                atom: .bytes(makeAVCC(
                    profileIDC: 100,
                    bitDepthMinus8: 0,
                    truncateSPSAfterBitDepth: true
                ))
            ),
            .init(name: "缺少 hvcC", format: hevcMain, profile: .hevcMain, atom: .missing),
            .init(name: "截断 hvcC", format: hevcMain, profile: .hevcMain, atom: .bytes(Data([1, 1]))),
            .init(
                name: "HEVC Main profile 错误",
                format: hevcMain,
                profile: .hevcMain,
                atom: .bytes(makeHVCC(
                    profileIDC: 2,
                    bitDepthMinus8: 0,
                    width: 3_840,
                    height: 2_160
                ))
            ),
            .init(
                name: "HEVC Main10 profile 错误",
                format: hevcMain10,
                profile: .hevcMain10,
                atom: .bytes(makeHVCC(profileIDC: 1, bitDepthMinus8: 2))
            ),
            .init(
                name: "HEVC Main10 bit depth 错误",
                format: hevcMain10,
                profile: .hevcMain10,
                atom: .bytes(makeHVCC(profileIDC: 2, bitDepthMinus8: 0))
            ),
            .init(
                name: "HEVC hvcC 与 SPS profile 不一致",
                format: hevcMain10,
                profile: .hevcMain10,
                atom: .bytes(makeHVCC(
                    profileIDC: 2,
                    bitDepthMinus8: 2,
                    spsProfileIDC: 1
                ))
            ),
            .init(
                name: "HEVC SPS 在 bit depth 后截断",
                format: hevcMain10,
                profile: .hevcMain10,
                atom: .bytes(makeHVCC(
                    profileIDC: 2,
                    bitDepthMinus8: 2,
                    truncateSPSAfterBitDepth: true
                ))
            ),
            .init(
                name: "HEVC SPS 缺少 emulation prevention",
                format: hevcMain10,
                profile: .hevcMain10,
                atom: .bytes(makeHVCC(
                    profileIDC: 2,
                    bitDepthMinus8: 2,
                    escapeSequenceParameterSet: false
                ))
            ),
            .init(
                name: "HEVC hvcC 与 SPS bit depth 不一致",
                format: hevcMain10,
                profile: .hevcMain10,
                atom: .bytes(makeHVCC(
                    profileIDC: 2,
                    bitDepthMinus8: 2,
                    spsBitDepthMinus8: 0
                ))
            ),
            .init(
                name: "HEVC hvcC 与 SPS constraint flags 不一致",
                format: hevcMain10,
                profile: .hevcMain10,
                atom: .bytes(makeHVCC(
                    profileIDC: 2,
                    bitDepthMinus8: 2,
                    constraintIndicatorFlags: 1 << 47,
                    spsConstraintIndicatorFlags: 0
                ))
            ),
        ]

        for fixture in fixtures {
            let api = FakeVTCompressionAPI()
            api.hardwareResults = [.hardware, .hardware]
            let encoder = try makeEncoder(api: api, format: fixture.format)
            XCTAssertEqual(encoder.selectedProfile, fixture.profile, fixture.name)
            let recorder = EncodingRecorder()
            encoder.encode(frame: try makeFrame(id: 1, format: fixture.format)) {
                recorder.record($0)
            }
            api.drain()
            api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
                format: fixture.format,
                profile: fixture.profile,
                atom: fixture.atom
            )))
            api.drain()

            XCTAssertTrue(recorder.successes.isEmpty, fixture.name)
            XCTAssertEqual(recorder.failures, [.unexpectedOutputFormat], fixture.name)
            XCTAssertEqual(encoder.terminal, .failed(.unexpectedOutputFormat), fixture.name)
            XCTAssertEqual(api.snapshot.hardwareCopyCount, 1, fixture.name)
        }
    }

    func testFirstOutputAcceptsValidH264SequenceParameterSetExtension() throws {
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(id: 1)) { recorder.record($0) }
        api.drain()

        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
            atom: .bytes(makeAVCC(
                profileIDC: 100,
                bitDepthMinus8: 0,
                sequenceParameterSetExtensions: [[0x6D, 0x80]]
            ))
        )))
        api.drain()

        XCTAssertEqual(recorder.successes.map(\.sourceIdentity.accessUnitID), [1])
        XCTAssertNil(encoder.terminal)
    }

    func testBT2020TransferAliasMatchesFrozenBT709OnInputAndOutput() throws {
        let format = makeFormat()
        let pixelBuffer = try makePixelBuffer(format: format)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2020,
            .shouldPropagate
        )
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api, format: format)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(
            id: 1,
            format: format,
            pixelBuffer: pixelBuffer
        )) { recorder.record($0) }
        api.drain()

        XCTAssertEqual(api.snapshot.encodes.count, 1)
        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
            mutateExtensions: {
                $0[kCMFormatDescriptionExtension_TransferFunction as String] =
                    kCMFormatDescriptionTransferFunction_ITU_R_2020
            }
        )))
        api.drain()

        XCTAssertEqual(recorder.successes.map(\.sourceIdentity.accessUnitID), [1])
        XCTAssertNil(encoder.terminal)
    }

    func testHEVCConfigurationAcceptsEscaped03Payload() throws {
        let format = makeFormat(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api, format: format)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(id: 1, format: format)) {
            recorder.record($0)
        }
        api.drain()

        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
            format: format,
            profile: .hevcMain10,
            atom: .bytes(makeHVCC(
                profileIDC: 2,
                bitDepthMinus8: 2,
                compatibilityFlags: 0x0000_0300
            ))
        )))
        api.drain()

        XCTAssertEqual(recorder.successes.map(\.sourceIdentity.accessUnitID), [1])
        XCTAssertNil(encoder.terminal)
    }

    func testFirstOutputRequiresExactTypedColorExtensions() throws {
        typealias Mutation = (inout [String: Any]) -> Void
        let format = makeFormat()
        let fixtures: [(String, Mutation)] = [
            ("缺少 primaries", { $0.removeValue(
                forKey: kCMFormatDescriptionExtension_ColorPrimaries as String
            ) }),
            ("缺少 transfer", { $0.removeValue(
                forKey: kCMFormatDescriptionExtension_TransferFunction as String
            ) }),
            ("缺少 matrix", { $0.removeValue(
                forKey: kCMFormatDescriptionExtension_YCbCrMatrix as String
            ) }),
            ("primaries 不匹配", { $0[
                kCMFormatDescriptionExtension_ColorPrimaries as String
            ] = kCMFormatDescriptionColorPrimaries_ITU_R_2020 }),
            ("transfer 类型错误", { $0[
                kCMFormatDescriptionExtension_TransferFunction as String
            ] = NSNumber(value: 1) }),
            ("matrix 不匹配", { $0[
                kCMFormatDescriptionExtension_YCbCrMatrix as String
            ] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 }),
            ("full-range 类型错误", { $0[
                kCMFormatDescriptionExtension_FullRangeVideo as String
            ] = NSNumber(value: 0) }),
            ("full-range 不匹配", { $0[
                kCMFormatDescriptionExtension_FullRangeVideo as String
            ] = kCFBooleanTrue }),
        ]

        for (name, mutation) in fixtures {
            try assertFirstOutputRejected(
                name,
                format: format,
                profile: .h264High,
                mutateExtensions: mutation
            )
        }
    }

    func testFirstOutputUsesCompressedVideoRangeAndSPSChromaDefaultsWithoutCMExtensions()
        throws {
        let format = makeFormat()
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api, format: format)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(id: 1, format: format)) {
            recorder.record($0)
        }
        api.drain()
        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
            format: format,
            profile: .h264High,
            mutateExtensions: {
                $0.removeValue(
                    forKey: kCMFormatDescriptionExtension_FullRangeVideo as String)
                $0.removeValue(
                    forKey: kCMFormatDescriptionExtension_ChromaLocationTopField as String)
                $0.removeValue(
                    forKey: kCMFormatDescriptionExtension_ChromaLocationBottomField as String)
            }
        )))
        api.drain()

        XCTAssertEqual(recorder.successes.map(\.sourceIdentity.accessUnitID), [1])
        XCTAssertNil(encoder.terminal)
    }

    func testFirstOutputCannotDefaultMissingCompressedRangeForFullRangeInput() throws {
        let format = makeFormat(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        try assertFirstOutputRejected(
            "full-range输入不能把缺失压缩扩展解释为full",
            format: format,
            profile: .h264High
        ) {
            $0.removeValue(forKey: kCMFormatDescriptionExtension_FullRangeVideo as String)
        }
    }

    func testFirstOutputRejectsExplicitUnsupportedSPSChromaInsteadOfDefaultingLeft()
        throws {
        let format = makeFormat()
        let unsupported = makeH264SequenceParameterSet(
            profileIDC: 100,
            bitDepthMinus8: 0,
            truncateAfterBitDepth: false,
            chromaLocationType: 3
        )
        let unsupportedProof = try VideoSequenceParameterSetInspector.inspectH264(unsupported)
        XCTAssertEqual(unsupportedProof.width, 1_920)
        XCTAssertEqual(unsupportedProof.height, 1_080)
        XCTAssertTrue(unsupportedProof.chromaLocationWasPresent)
        XCTAssertNil(unsupportedProof.effectiveChromaLocation)

        try assertFirstOutputRejected(
            "SPS显式chroma_sample_loc_type=3不能解释为缺省Left",
            format: format,
            profile: .h264High,
            atom: .bytes(makeAVCC(
                profileIDC: 100,
                bitDepthMinus8: 0,
                spsChromaLocationType: 3
            )),
            mutateExtensions: { _ in }
        )
    }

    func testFirstOutputRejectsConflictingEffectiveChromaAcrossMultipleSPS() throws {
        let format = makeFormat()
        let left = makeH264SequenceParameterSet(
            profileIDC: 100,
            bitDepthMinus8: 0,
            truncateAfterBitDepth: false
        )
        let center = makeH264SequenceParameterSet(
            profileIDC: 100,
            bitDepthMinus8: 0,
            truncateAfterBitDepth: false,
            sequenceParameterSetID: 1,
            chromaLocationType: 1
        )
        let leftProof = try VideoSequenceParameterSetInspector.inspectH264(left)
        let centerProof = try VideoSequenceParameterSetInspector.inspectH264(center)
        for proof in [leftProof, centerProof] {
            XCTAssertEqual(proof.width, 1_920)
            XCTAssertEqual(proof.height, 1_080)
        }
        XCTAssertFalse(leftProof.chromaLocationWasPresent)
        XCTAssertEqual(leftProof.effectiveChromaLocation, .left)
        XCTAssertTrue(centerProof.chromaLocationWasPresent)
        XCTAssertEqual(centerProof.effectiveChromaLocation, .center)

        try assertFirstOutputRejected(
            "多个SPS的有效Left/Center色度事实冲突必须拒绝",
            format: format,
            profile: .h264High,
            atom: .bytes(makeAVCC(
                profileIDC: 100,
                bitDepthMinus8: 0,
                additionalSequenceParameterSets: [center]
            )),
            mutateExtensions: { _ in }
        )
    }

    func testFirstOutputRequiresDeclaredPASPCLAPHDRAndChromaExtensions() throws {
        typealias Mutation = (inout [String: Any]) -> Void
        let mastering = Data((0..<24).map(UInt8.init))
        let light = Data([0, 1, 2, 3])
        let format = makeFormat(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: .pq,
            cleanAperture: makeCleanAperture(),
            sampleAspectRatio: MediaRational(num: 4, den: 3),
            masteringDisplay: mastering,
            contentLightLevel: light
        )
        let fixtures: [(String, Mutation)] = [
            ("缺少 pasp", { $0.removeValue(
                forKey: kCMFormatDescriptionExtension_PixelAspectRatio as String
            ) }),
            ("pasp 数值溢出", { $0[
                kCMFormatDescriptionExtension_PixelAspectRatio as String
            ] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String:
                    NSNumber(value: Int64.max),
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String:
                    NSNumber(value: 3),
            ] }),
            ("缺少 clap", { $0.removeValue(
                forKey: kCMFormatDescriptionExtension_CleanAperture as String
            ) }),
            ("clap rational 截断", { extensions in
                var clap = extensions[
                    kCMFormatDescriptionExtension_CleanAperture as String
                ] as! [String: Any]
                clap[kCMFormatDescriptionKey_CleanApertureWidthRational as String] = [1_880]
                extensions[kCMFormatDescriptionExtension_CleanAperture as String] = clap
            }),
            ("缺少 MDCV", { $0.removeValue(
                forKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
            ) }),
            ("MDCV 值不匹配", { $0[
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
            ] = Data(repeating: 0, count: 24) }),
            ("缺少 CLLI", { $0.removeValue(
                forKey: kCMFormatDescriptionExtension_ContentLightLevelInfo as String
            ) }),
            ("CLLI 类型错误", { $0[
                kCMFormatDescriptionExtension_ContentLightLevelInfo as String
            ] = "00010203" }),
            ("chroma 值不匹配", { $0[
                kCMFormatDescriptionExtension_ChromaLocationTopField as String
            ] = kCMFormatDescriptionChromaLocation_Center }),
        ]

        for (name, mutation) in fixtures {
            try assertFirstOutputRejected(
                name,
                format: format,
                profile: .hevcMain10,
                mutateExtensions: mutation
            )
        }
    }

    func testInputPixelBufferAttachmentsMustMatchFrozenSignatureBeforeNativeEncode() throws {
        typealias Mutation = (CVPixelBuffer) -> Void
        let mastering = Data((0..<24).map(UInt8.init))
        let light = Data([0, 1, 2, 3])
        let format = makeFormat(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            transfer: .pq,
            cleanAperture: makeCleanAperture(),
            sampleAspectRatio: MediaRational(num: 4, den: 3),
            masteringDisplay: mastering,
            contentLightLevel: light
        )
        let fixtures: [(String, Mutation)] = [
            ("缺少 primaries", { CVBufferRemoveAttachment(
                $0, kCVImageBufferColorPrimariesKey
            ) }),
            ("transfer 类型错误", { CVBufferSetAttachment(
                $0, kCVImageBufferTransferFunctionKey, NSNumber(value: 1), .shouldPropagate
            ) }),
            ("matrix 不匹配", { CVBufferSetAttachment(
                $0, kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate
            ) }),
            ("缺少 bottom chroma", { CVBufferRemoveAttachment(
                $0, kCVImageBufferChromaLocationBottomFieldKey
            ) }),
            ("pasp 为零", { CVBufferSetAttachment(
                $0,
                kCVImageBufferPixelAspectRatioKey,
                [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 4,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 0,
                ] as CFDictionary,
                .shouldPropagate
            ) }),
            ("clap 类型错误", { CVBufferSetAttachment(
                $0, kCVImageBufferCleanApertureKey, "bad" as CFString, .shouldPropagate
            ) }),
            ("MDCV 长度错误", { CVBufferSetAttachment(
                $0, kCVImageBufferMasteringDisplayColorVolumeKey,
                Data(repeating: 0, count: 23) as CFData, .shouldPropagate
            ) }),
            ("缺少 CLLI", { CVBufferRemoveAttachment(
                $0, kCVImageBufferContentLightLevelInfoKey
            ) }),
        ]

        for (name, mutation) in fixtures {
            let api = FakeVTCompressionAPI()
            let encoder = try makeEncoder(api: api, format: format)
            let pixelBuffer = try makePixelBuffer(format: format)
            mutation(pixelBuffer)
            let recorder = EncodingRecorder()
            encoder.encode(frame: try makeFrame(
                id: 1,
                format: format,
                pixelBuffer: pixelBuffer
            )) { recorder.record($0) }
            api.drain()

            XCTAssertTrue(api.snapshot.encodes.isEmpty, name)
            XCTAssertEqual(recorder.failures, [.inputFormatChanged], name)
            XCTAssertEqual(encoder.terminal, .failed(.inputFormatChanged), name)
        }
    }
}

private enum CodecConfigurationAtomFixture {
    case valid
    case missing
    case bytes(Data)
}

private extension VTVideoEncoderTests {
    enum FallbackFailure: Equatable { case create, prepare, hardware }

    func makeEncoder(
        api: FakeVTCompressionAPI,
        format: VideoEncodingInputFormatSignature? = nil,
        frameRate: MediaRational? = MediaRational(num: 25, den: 1),
        maximumPendingFrameCount: Int = 4,
        compressedOutputOwnership: HLSVideoCopyOwnership? = nil
    ) throws -> VTVideoEncoder {
        let resolvedFormat = format ?? makeFormat()
        let bitrate = try VTVideoBitratePolicy.freeze(
            firstTwoSecondsByteCount: 100,
            width: resolvedFormat.width,
            height: resolvedFormat.height,
            bitDepth: resolvedFormat.bitDepth,
            dynamicRange: resolvedFormat.dynamicRange
        )
        return try VTVideoEncoder(
            configuration: VTVideoEncoderConfiguration(
                generation: MediaGeneration(rawValue: 7),
                inputFormat: resolvedFormat,
                frameRate: try XCTUnwrap(frameRate),
                bitrate: bitrate,
                maximumPendingFrameCount: maximumPendingFrameCount
            ),
            api: api,
            workQueue: api.workQueue,
            compressedOutputOwnership: compressedOutputOwnership
        )
    }

    func makeFormat(
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        width: Int32 = 1_920,
        height: Int32 = 1_080,
        transfer: VideoFormatMetadata.Transfer = .bt709,
        primaries: VideoFormatMetadata.Primaries? = nil,
        matrix: VideoFormatMetadata.Matrix? = nil,
        range: VideoFormatMetadata.Range? = nil,
        cleanAperture: HLSCleanApertureSignature? = nil,
        sampleAspectRatio: MediaRational? = nil,
        masteringDisplay: Data? = nil,
        contentLightLevel: Data? = nil
    ) -> VideoEncodingInputFormatSignature {
        let isTenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let isFull = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let isHDR = transfer == .hlg || transfer == .pq
        return VideoEncodingInputFormatSignature(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            bitDepth: isTenBit ? 10 : 8,
            range: range ?? (isFull ? .full : .video),
            primaries: primaries ?? (isHDR ? .bt2020 : .bt709),
            transfer: transfer,
            matrix: matrix ?? (isHDR ? .bt2020 : .bt709),
            cleanAperture: cleanAperture,
            sampleAspectRatio: sampleAspectRatio,
            chromaLocation: .init(topField: "Left", bottomField: "Left"),
            masteringDisplayColorVolume: masteringDisplay,
            contentLightLevelInfo: contentLightLevel
        )
    }

    func makeCleanAperture() -> HLSCleanApertureSignature {
        HLSCleanApertureSignature(
            width: MediaRational(num: 1_880, den: 1)!,
            height: MediaRational(num: 1_060, den: 1)!,
            horizontalOffset: SignedMediaRational(num: 1, den: 2)!,
            verticalOffset: SignedMediaRational(num: -1, den: 2)!
        )
    }

    func makeFrame(
        id: UInt64,
        sequence: UInt64 = 1,
        pts: CMTime = .zero,
        origin: PresentationOrigin = .raw,
        reliableOrder: ResolvedFieldOrder? = nil,
        leaseCounter: LockedCounter = LockedCounter(),
        format: VideoEncodingInputFormatSignature? = nil,
        pixelBuffer: CVPixelBuffer? = nil
    ) throws -> VideoEncodingFrame {
        let resolvedFormat = format ?? makeFormat()
        return try VideoEncodingFrame(
            identity: .init(
                generation: MediaGeneration(rawValue: 7),
                accessUnitID: id,
                sequenceNumber: sequence
            ),
            pixelBuffer: try pixelBuffer ?? makePixelBuffer(format: resolvedFormat),
            surfaceLease: VideoEncodingSurfaceLease { leaseCounter.increment() },
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 50),
            presentationOrigin: origin,
            reliableFieldOrder: reliableOrder,
            inputFormatSignature: resolvedFormat
        )
    }

    func makePixelBuffer(
        format: VideoEncodingInputFormatSignature
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(format.width),
            Int(format.height),
            format.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw VTVideoEncoderFailure.invalidPixelBuffer
        }
        setInputAttachments(on: buffer, format: format)
        return buffer
    }

    func makeCompressedSampleBuffer(
        pts: CMTime = .zero,
        dts: CMTime? = nil,
        notSync: Bool = false,
        format: VideoEncodingInputFormatSignature? = nil,
        profile: VTVideoCodecProfile = .h264High,
        atom: CodecConfigurationAtomFixture = .valid,
        mutateExtensions: ((inout [String: Any]) -> Void)? = nil
    ) throws -> CMSampleBuffer {
        let resolvedFormat = format ?? makeFormat()
        var extensions = makeOutputExtensions(
            format: resolvedFormat,
            profile: profile,
            atom: atom
        )
        mutateExtensions?(&extensions)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: profile.codecType,
            width: resolvedFormat.width,
            height: resolvedFormat.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        ), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: 4,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 4,
            flags: 0,
            blockBufferOut: &block
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 50),
            presentationTimeStamp: pts,
            decodeTimeStamp: dts ?? pts
        )
        var size = 4
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(block),
            formatDescription: try XCTUnwrap(format),
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ), noErr)
        let result = try XCTUnwrap(sample)
        if notSync,
           let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(
               result,
               createIfNecessary: true
           ),
           CFArrayGetCount(rawAttachments) == 1,
           let rawDictionary = CFArrayGetValueAtIndex(rawAttachments, 0) {
            let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(rawDictionary)
                .takeUnretainedValue()
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return result
    }

    func makeHEVCTemporalLevelInfo(compatibilityBytes: Int, constraintBytes: Int) -> [String: Any] {
        ["temporal": NSNumber(value: 3), "profileSpace": NSNumber(value: 1),
         "tier": NSNumber(value: 1), "profile": NSNumber(value: 2), "level": NSNumber(value: 5),
         "compatibility": Data(repeating: 0x11, count: compatibilityBytes),
         "constraint": Data(repeating: 0x22, count: constraintBytes)]
    }

    func setHEVCTemporalLevelInfo(_ value: [String: Any], on sample: CMSampleBuffer) throws {
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let attachmentValue = try XCTUnwrap(CFArrayGetValueAtIndex(attachments, 0))
        let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(attachmentValue).takeUnretainedValue()
        let compatibility = try XCTUnwrap(value["compatibility"] as? Data) as CFData
        let constraint = try XCTUnwrap(value["constraint"] as? Data) as CFData
        let temporal: [CFString: Any] = [
            kCMHEVCTemporalLevelInfoKey_TemporalLevel: try XCTUnwrap(value["temporal"]),
            kCMHEVCTemporalLevelInfoKey_ProfileSpace: try XCTUnwrap(value["profileSpace"]),
            kCMHEVCTemporalLevelInfoKey_TierFlag: try XCTUnwrap(value["tier"]),
            kCMHEVCTemporalLevelInfoKey_ProfileIndex: try XCTUnwrap(value["profile"]),
            kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags: compatibility,
            kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags: constraint,
            kCMHEVCTemporalLevelInfoKey_LevelIndex: try XCTUnwrap(value["level"]),
        ]
        let temporalDictionary: CFDictionary = temporal as CFDictionary
        withExtendedLifetime(temporalDictionary) {
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_HEVCTemporalLevelInfo).toOpaque(),
                                 Unmanaged.passUnretained(temporalDictionary).toOpaque())
        }
    }

    func temporalLevelInfo(from sample: CMSampleBuffer) throws -> [String: Any] {
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false))
        let attachmentValue = try XCTUnwrap(CFArrayGetValueAtIndex(attachments, 0))
        let dictionary = Unmanaged<CFDictionary>.fromOpaque(attachmentValue).takeUnretainedValue()
        let value = try XCTUnwrap(CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_HEVCTemporalLevelInfo).toOpaque()))
        let temporal = Unmanaged<CFDictionary>.fromOpaque(value).takeUnretainedValue()
        func field(_ key: CFString) throws -> Any {
            let value = try XCTUnwrap(CFDictionaryGetValue(temporal, Unmanaged.passUnretained(key).toOpaque()))
            return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        }
        return ["temporal": try field(kCMHEVCTemporalLevelInfoKey_TemporalLevel), "profileSpace": try field(kCMHEVCTemporalLevelInfoKey_ProfileSpace), "tier": try field(kCMHEVCTemporalLevelInfoKey_TierFlag), "profile": try field(kCMHEVCTemporalLevelInfoKey_ProfileIndex), "compatibility": try field(kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags), "constraint": try field(kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags), "level": try field(kCMHEVCTemporalLevelInfoKey_LevelIndex)]
    }

    func assertFirstOutputRejected(
        _ name: String,
        format: VideoEncodingInputFormatSignature,
        profile: VTVideoCodecProfile,
        atom: CodecConfigurationAtomFixture = .valid,
        mutateExtensions: @escaping (inout [String: Any]) -> Void
    ) throws {
        let api = FakeVTCompressionAPI()
        api.hardwareResults = [.hardware, .hardware]
        let encoder = try makeEncoder(api: api, format: format)
        XCTAssertEqual(encoder.selectedProfile, profile, name)
        let recorder = EncodingRecorder()
        encoder.encode(frame: try makeFrame(id: 1, format: format)) {
            recorder.record($0)
        }
        api.drain()
        api.deliverFirst(.success(sampleBuffer: try makeCompressedSampleBuffer(
            format: format,
            profile: profile,
            atom: atom,
            mutateExtensions: mutateExtensions
        )))
        api.drain()

        XCTAssertTrue(recorder.successes.isEmpty, name)
        XCTAssertEqual(recorder.failures, [.unexpectedOutputFormat], name)
        XCTAssertEqual(encoder.terminal, .failed(.unexpectedOutputFormat), name)
        XCTAssertEqual(api.snapshot.hardwareCopyCount, 1, name)
    }

    func makeOutputExtensions(
        format: VideoEncodingInputFormatSignature,
        profile: VTVideoCodecProfile,
        atom: CodecConfigurationAtomFixture
    ) -> [String: Any] {
        var extensions: [String: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries as String:
                colorPrimariesValue(format.primaries),
            kCMFormatDescriptionExtension_TransferFunction as String:
                transferFunctionValue(format.transfer),
            kCMFormatDescriptionExtension_YCbCrMatrix as String:
                matrixValue(format.matrix),
            kCMFormatDescriptionExtension_FullRangeVideo as String:
                format.range == .full,
        ]
        switch atom {
        case .valid:
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = [
                profile.codecType == kCMVideoCodecType_H264 ? "avcC" : "hvcC":
                    profile.codecType == kCMVideoCodecType_H264
                        ? makeAVCC(profileIDC: 100, bitDepthMinus8: 0)
                        : makeHVCC(
                            profileIDC: profile == .hevcMain ? 1 : 2,
                            bitDepthMinus8: profile == .hevcMain ? 0 : 2,
                            width: format.width,
                            height: format.height
                        ),
            ]
        case .missing:
            break
        case let .bytes(bytes):
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = [
                profile.codecType == kCMVideoCodecType_H264 ? "avcC" : "hvcC": bytes,
            ]
        }
        if let top = format.chromaLocation.topField {
            extensions[kCMFormatDescriptionExtension_ChromaLocationTopField as String] = top
        }
        if let bottom = format.chromaLocation.bottomField {
            extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField as String] = bottom
        }
        if let aspect = format.sampleAspectRatio {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio as String] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String:
                    NSNumber(value: aspect.num),
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String:
                    NSNumber(value: aspect.den),
            ]
        }
        if let aperture = format.cleanAperture {
            extensions[kCMFormatDescriptionExtension_CleanAperture as String] =
                makeCleanApertureDictionary(aperture)
        }
        if let mastering = format.masteringDisplayColorVolume {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] = mastering
        }
        if let light = format.contentLightLevelInfo {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = light
        }
        return extensions
    }

    func setInputAttachments(
        on pixelBuffer: CVPixelBuffer,
        format: VideoEncodingInputFormatSignature
    ) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
        set(kCVImageBufferColorPrimariesKey, colorPrimariesValue(format.primaries))
        set(kCVImageBufferTransferFunctionKey, transferFunctionValue(format.transfer))
        set(kCVImageBufferYCbCrMatrixKey, matrixValue(format.matrix))
        if let top = format.chromaLocation.topField {
            set(kCVImageBufferChromaLocationTopFieldKey, top as CFString)
        }
        if let bottom = format.chromaLocation.bottomField {
            set(kCVImageBufferChromaLocationBottomFieldKey, bottom as CFString)
        }
        if let aspect = format.sampleAspectRatio {
            set(kCVImageBufferPixelAspectRatioKey, [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String:
                    NSNumber(value: aspect.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String:
                    NSNumber(value: aspect.den),
            ] as CFDictionary)
        }
        if let aperture = format.cleanAperture {
            set(kCVImageBufferCleanApertureKey, makeCleanApertureDictionary(aperture) as CFDictionary)
        }
        if let mastering = format.masteringDisplayColorVolume {
            set(kCVImageBufferMasteringDisplayColorVolumeKey, mastering as CFData)
        }
        if let light = format.contentLightLevelInfo {
            set(kCVImageBufferContentLightLevelInfoKey, light as CFData)
        }
    }

    func makeCleanApertureDictionary(
        _ aperture: HLSCleanApertureSignature
    ) -> [String: Any] {
        [
            kCMFormatDescriptionKey_CleanApertureWidth as String:
                NSNumber(value: Double(aperture.width.num) / Double(aperture.width.den)),
            kCMFormatDescriptionKey_CleanApertureHeight as String:
                NSNumber(value: Double(aperture.height.num) / Double(aperture.height.den)),
            kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String:
                NSNumber(
                    value: Double(aperture.horizontalOffset.num)
                        / Double(aperture.horizontalOffset.den)
                ),
            kCMFormatDescriptionKey_CleanApertureVerticalOffset as String:
                NSNumber(
                    value: Double(aperture.verticalOffset.num)
                        / Double(aperture.verticalOffset.den)
                ),
            kCMFormatDescriptionKey_CleanApertureWidthRational as String: [
                NSNumber(value: aperture.width.num), NSNumber(value: aperture.width.den),
            ],
            kCMFormatDescriptionKey_CleanApertureHeightRational as String: [
                NSNumber(value: aperture.height.num), NSNumber(value: aperture.height.den),
            ],
            kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational as String: [
                NSNumber(value: aperture.horizontalOffset.num),
                NSNumber(value: aperture.horizontalOffset.den),
            ],
            kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational as String: [
                NSNumber(value: aperture.verticalOffset.num),
                NSNumber(value: aperture.verticalOffset.den),
            ],
        ]
    }

    func colorPrimariesValue(_ value: VideoFormatMetadata.Primaries) -> CFString {
        switch value {
        case .bt709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case .bt2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case .unknown: "" as CFString
        }
    }

    func transferFunctionValue(_ value: VideoFormatMetadata.Transfer) -> CFString {
        switch value {
        case .bt709: kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case .pq: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case .linear: kCMFormatDescriptionTransferFunction_Linear
        case .unknown: "" as CFString
        }
    }

    func matrixValue(_ value: VideoFormatMetadata.Matrix) -> CFString {
        switch value {
        case .bt601: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case .bt709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case .bt2020: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case .identity: "Identity" as CFString
        case .unknown: "" as CFString
        }
    }

    func makeAVCC(
        profileIDC: UInt8,
        bitDepthMinus8: UInt8,
        spsProfileIDC: UInt8? = nil,
        spsBitDepthMinus8: UInt8? = nil,
        truncateSPSAfterBitDepth: Bool = false,
        sequenceParameterSetExtensions: [[UInt8]] = [],
        spsChromaLocationType: UInt32? = nil,
        additionalSequenceParameterSets: [[UInt8]] = []
    ) -> Data {
        let sequenceParameterSet = makeH264SequenceParameterSet(
            profileIDC: spsProfileIDC ?? profileIDC,
            bitDepthMinus8: spsBitDepthMinus8 ?? bitDepthMinus8,
            truncateAfterBitDepth: truncateSPSAfterBitDepth,
            chromaLocationType: spsChromaLocationType
        )
        let sequenceParameterSets = [sequenceParameterSet] + additionalSequenceParameterSets
        precondition(sequenceParameterSets.count <= 31)
        var bytes: [UInt8] = [
            1, profileIDC, 0, 40, 0xFF,
            0xE0 | UInt8(sequenceParameterSets.count),
        ]
        for unit in sequenceParameterSets {
            bytes.append(UInt8(unit.count >> 8))
            bytes.append(UInt8(unit.count & 0xFF))
            bytes.append(contentsOf: unit)
        }
        bytes.append(contentsOf: [1, 0, 2, 0x68, 0x80])
        bytes.append(contentsOf: [
            0xFD, 0xF8 | (bitDepthMinus8 & 0x07),
            0xF8 | (bitDepthMinus8 & 0x07),
            UInt8(sequenceParameterSetExtensions.count),
        ])
        for unit in sequenceParameterSetExtensions {
            bytes.append(UInt8(unit.count >> 8))
            bytes.append(UInt8(unit.count & 0xFF))
            bytes.append(contentsOf: unit)
        }
        return Data(bytes)
    }

    func makeH264SequenceParameterSet(
        profileIDC: UInt8,
        bitDepthMinus8: UInt8,
        truncateAfterBitDepth: Bool,
        sequenceParameterSetID: UInt32 = 0,
        chromaLocationType: UInt32? = nil
    ) -> [UInt8] {
        var writer = TestRBSPBitWriter()
        writer.append(UInt64(profileIDC), bitCount: 8)
        writer.append(0, bitCount: 8)
        writer.append(40, bitCount: 8)
        writer.appendUnsignedExpGolomb(UInt64(sequenceParameterSetID))
        if profileIDC == 100 {
            writer.appendUnsignedExpGolomb(1)
            writer.appendUnsignedExpGolomb(UInt64(bitDepthMinus8))
            writer.appendUnsignedExpGolomb(UInt64(bitDepthMinus8))
            writer.append(bit: false)
            writer.append(bit: false)
        }
        if !truncateAfterBitDepth {
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(4)
            writer.append(bit: false) // gaps_in_frame_num_value_allowed_flag
            writer.appendUnsignedExpGolomb(119)
            writer.appendUnsignedExpGolomb(67)
            writer.append(bit: true)
            writer.append(bit: true)
            writer.append(bit: true)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(4)
            if let chromaLocationType {
                writer.append(bit: true) // vui_parameters_present_flag
                writer.append(bit: false) // aspect_ratio_info_present_flag
                writer.append(bit: false) // overscan_info_present_flag
                writer.append(bit: false) // video_signal_type_present_flag
                writer.append(bit: true) // chroma_loc_info_present_flag
                writer.appendUnsignedExpGolomb(UInt64(chromaLocationType))
                writer.appendUnsignedExpGolomb(UInt64(chromaLocationType))
                writer.append(bit: false) // timing_info_present_flag
                writer.append(bit: false) // nal_hrd_parameters_present_flag
                writer.append(bit: false) // vcl_hrd_parameters_present_flag
                writer.append(bit: false) // pic_struct_present_flag
                writer.append(bit: false) // bitstream_restriction_flag
            } else {
                writer.append(bit: false) // vui_parameters_present_flag
            }
        }
        return [0x67] + escapeRBSP(writer.finish())
    }

    func makeHVCC(
        profileIDC: UInt8,
        bitDepthMinus8: UInt8,
        width: Int32 = 1_920,
        height: Int32 = 1_080,
        compatibilityFlags: UInt32 = 0,
        constraintIndicatorFlags: UInt64 = 0,
        spsProfileIDC: UInt8? = nil,
        spsBitDepthMinus8: UInt8? = nil,
        spsConstraintIndicatorFlags: UInt64? = nil,
        truncateSPSAfterBitDepth: Bool = false,
        escapeSequenceParameterSet: Bool = true
    ) -> Data {
        var bytes: [UInt8] = [
            1, profileIDC & 0x1F,
            UInt8(truncatingIfNeeded: compatibilityFlags >> 24),
            UInt8(truncatingIfNeeded: compatibilityFlags >> 16),
            UInt8(truncatingIfNeeded: compatibilityFlags >> 8),
            UInt8(truncatingIfNeeded: compatibilityFlags),
            UInt8(truncatingIfNeeded: constraintIndicatorFlags >> 40),
            UInt8(truncatingIfNeeded: constraintIndicatorFlags >> 32),
            UInt8(truncatingIfNeeded: constraintIndicatorFlags >> 24),
            UInt8(truncatingIfNeeded: constraintIndicatorFlags >> 16),
            UInt8(truncatingIfNeeded: constraintIndicatorFlags >> 8),
            UInt8(truncatingIfNeeded: constraintIndicatorFlags),
            120,
            0xF0, 0,
            0xFC,
            0xFD,
            0xF8 | (bitDepthMinus8 & 0x07),
            0xF8 | (bitDepthMinus8 & 0x07),
            0, 0,
            0x0F,
            3,
        ]
        let parameterSets: [(UInt8, [UInt8])] = [
            (32, [0x40, 0x01, 0x80]),
            (33, makeHEVCSequenceParameterSet(
                profileIDC: spsProfileIDC ?? profileIDC,
                bitDepthMinus8: spsBitDepthMinus8 ?? bitDepthMinus8,
                width: width,
                height: height,
                compatibilityFlags: compatibilityFlags,
                constraintIndicatorFlags:
                    spsConstraintIndicatorFlags ?? constraintIndicatorFlags,
                truncateAfterBitDepth: truncateSPSAfterBitDepth,
                escape: escapeSequenceParameterSet
            )),
            (34, [0x44, 0x01, 0x80]),
        ]
        for (type, unit) in parameterSets {
            bytes.append(0x80 | type)
            bytes.append(contentsOf: [0, 1])
            bytes.append(UInt8(unit.count >> 8))
            bytes.append(UInt8(unit.count & 0xFF))
            bytes.append(contentsOf: unit)
        }
        return Data(bytes)
    }

    func makeHEVCSequenceParameterSet(
        profileIDC: UInt8,
        bitDepthMinus8: UInt8,
        width: Int32,
        height: Int32,
        compatibilityFlags: UInt32,
        constraintIndicatorFlags: UInt64,
        truncateAfterBitDepth: Bool,
        escape: Bool
    ) -> [UInt8] {
        var writer = TestRBSPBitWriter()
        writer.append(0, bitCount: 4)
        writer.append(0, bitCount: 3)
        writer.append(bit: true)
        writer.append(UInt64(profileIDC & 0x1F), bitCount: 8)
        writer.append(UInt64(compatibilityFlags), bitCount: 32)
        writer.append(constraintIndicatorFlags, bitCount: 48)
        writer.append(120, bitCount: 8)
        writer.appendUnsignedExpGolomb(0)
        writer.appendUnsignedExpGolomb(1)
        writer.appendUnsignedExpGolomb(UInt64(width))
        writer.appendUnsignedExpGolomb(UInt64(height))
        writer.append(bit: false)
        writer.appendUnsignedExpGolomb(UInt64(bitDepthMinus8))
        writer.appendUnsignedExpGolomb(UInt64(bitDepthMinus8))
        if !truncateAfterBitDepth {
            writer.appendUnsignedExpGolomb(4)
            writer.append(bit: false)
            writer.appendUnsignedExpGolomb(4)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(3)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(3)
            writer.appendUnsignedExpGolomb(0)
            writer.appendUnsignedExpGolomb(0)
            writer.append(bit: false)
            writer.append(bit: true)
            writer.append(bit: true)
            writer.append(bit: false)
            writer.appendUnsignedExpGolomb(0)
            writer.append(bit: false)
            writer.append(bit: false)
            writer.append(bit: true)
            writer.append(bit: false)
            writer.append(bit: false)
        }
        let rbsp = writer.finish()
        return [0x42, 0x01] + (escape ? escapeRBSP(rbsp) : rbsp)
    }

    func escapeRBSP(_ rbsp: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var zeroCount = 0
        for byte in rbsp {
            if zeroCount == 2, byte <= 3 {
                result.append(3)
                zeroCount = 0
            }
            result.append(byte)
            zeroCount = byte == 0 ? min(2, zeroCount + 1) : 0
        }
        return result
    }
}

private final class TestVTCompressionSession: VTCompressionSessionHandle, @unchecked Sendable {
    let id: VTCompressionSessionID
    init(id: VTCompressionSessionID) { self.id = id }
}

/// 仅测试 fake 的受控跨队列交付：box 明确拥有 CoreMedia 引用，避免把
/// CMSampleBuffer 的非 Sendable 类型直接捕获进 `@Sendable` closure。
private final class TestCMSampleBufferBox: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}

private final class FakeVTCompressionAPI: VTCompressionAPI, @unchecked Sendable {
    struct CreateRecord: Sendable {
        let codecType: CMVideoCodecType
        let encoderSpecification: [String: VTCompressionPropertyValue]
    }
    struct SetRecord: Sendable { let key: String; let value: VTCompressionPropertyValue }
    struct EncodeRecord: Sendable { let sequenceNumber: UInt64 }
    struct Snapshot: Sendable {
        let creates: [CreateRecord]
        let sets: [SetRecord]
        let encodes: [EncodeRecord]
        let hardwareCopyCount: Int
        let completedSessionIDs: [VTCompressionSessionID]
        let invalidatedSessionIDs: [VTCompressionSessionID]
    }

    let workQueue = DispatchQueue(label: "org.vplayer.tests.vt-encoder")
    var createStatuses: [OSStatus] = []
    var prepareStatuses: [OSStatus] = []
    var propertyStatuses: [OSStatus] = []
    var hardwareResults: [VTCompressionPropertyCopyResult] = [.hardware]
    var encodeStatuses: [OSStatus] = []
    var synchronousOutput: VTCompressionOutput?
    var concurrentOutputBeforeEncodeReturn: VTCompressionOutput?
    var synchronousOutputDelivered: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var creates: [CreateRecord] = []
    private var sets: [SetRecord] = []
    private var encodes: [EncodeRecord] = []
    private var hardwareCopyCount = 0
    private var completedSessionIDs: [VTCompressionSessionID] = []
    private var invalidatedSessionIDs: [VTCompressionSessionID] = []
    private var pending: [@Sendable (VTCompressionOutput) -> Void] = []
    private var retainedCallback: (@Sendable (VTCompressionOutput) -> Void)?
    private var holdInvalidate = false
    private let invalidateEntered = DispatchSemaphore(value: 0)
    private let invalidateRelease = DispatchSemaphore(value: 0)

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                creates: creates,
                sets: sets,
                encodes: encodes,
                hardwareCopyCount: hardwareCopyCount,
                completedSessionIDs: completedSessionIDs,
                invalidatedSessionIDs: invalidatedSessionIDs
            )
        }
    }

    func createSession(
        configuration: VTCompressionSessionCreationConfiguration
    ) -> (status: OSStatus, session: (any VTCompressionSessionHandle)?) {
        lock.withLock {
            creates.append(CreateRecord(
                codecType: configuration.codecType,
                encoderSpecification: configuration.encoderSpecification
            ))
            let status = createStatuses.isEmpty ? noErr : createStatuses.removeFirst()
            guard status == noErr else { return (status, nil) }
            defer { nextID += 1 }
            return (
                noErr,
                TestVTCompressionSession(id: VTCompressionSessionID(rawValue: nextID))
            )
        }
    }

    func setProperty(
        _ session: any VTCompressionSessionHandle,
        key: String,
        value: VTCompressionPropertyValue
    ) -> OSStatus {
        lock.withLock {
            sets.append(SetRecord(key: key, value: value))
            return propertyStatuses.isEmpty ? noErr : propertyStatuses.removeFirst()
        }
    }

    func copyProperty(
        _ session: any VTCompressionSessionHandle,
        key: String
    ) -> VTCompressionPropertyCopyResult {
        lock.withLock {
            hardwareCopyCount += 1
            return hardwareResults.isEmpty ? .hardware : hardwareResults.removeFirst()
        }
    }

    func prepare(_ session: any VTCompressionSessionHandle) -> OSStatus {
        lock.withLock {
            prepareStatuses.isEmpty ? noErr : prepareStatuses.removeFirst()
        }
    }

    func encode(
        _ session: any VTCompressionSessionHandle,
        frame: VideoEncodingFrame,
        forceKeyFrame: Bool,
        output: @escaping @Sendable (VTCompressionOutput) -> Void
    ) -> VTCompressionSubmissionResult {
        let scripted: (OSStatus, VTCompressionOutput?) = lock.withLock {
            encodes.append(EncodeRecord(sequenceNumber: frame.identity.sequenceNumber))
            let status = encodeStatuses.isEmpty ? noErr : encodeStatuses.removeFirst()
            if status == noErr { pending.append(output) }
            return (status, synchronousOutput)
        }
        if let synchronous = scripted.1 {
            output(synchronous)
            synchronousOutputDelivered?()
        }
        if let concurrentOutputBeforeEncodeReturn {
            let callbackStarted = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                callbackStarted.signal()
                output(concurrentOutputBeforeEncodeReturn)
            }
            _ = callbackStarted.wait(timeout: .now() + 2)
        }
        return VTCompressionSubmissionResult(status: scripted.0, infoFlags: [])
    }

    func completeFrames(_ session: any VTCompressionSessionHandle) -> OSStatus {
        lock.withLock {
            completedSessionIDs.append(session.id)
            return noErr
        }
    }

    func invalidate(_ session: any VTCompressionSessionHandle) {
        let shouldHold = lock.withLock { () -> Bool in
            invalidatedSessionIDs.append(session.id)
            return holdInvalidate
        }
        invalidateEntered.signal()
        if shouldHold { invalidateRelease.wait() }
    }

    func holdNextInvalidate() { lock.withLock { holdInvalidate = true } }

    func waitUntilInvalidateEntered(timeout: TimeInterval = 2) -> Bool {
        invalidateEntered.wait(timeout: .now() + timeout) == .success
    }

    func releaseHeldInvalidate() {
        lock.withLock { holdInvalidate = false }
        invalidateRelease.signal()
    }

    func deliverFirst(_ output: VTCompressionOutput, retainingCallback: Bool = false) {
        let callback: (@Sendable (VTCompressionOutput) -> Void)? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let callback = pending.removeFirst()
            if retainingCallback { retainedCallback = callback }
            return callback
        }
        callback?(output)
    }

    func redeliverRetained(_ output: VTCompressionOutput) {
        lock.withLock { retainedCallback }?(output)
    }

    func drain() { workQueue.sync {} }
}

private extension VTCompressionPropertyCopyResult {
    static let hardware = VTCompressionPropertyCopyResult(
        status: noErr,
        value: .boolean(true)
    )
}

private final class EncodingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>] = []
    func record(_ value: Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>) {
        lock.withLock { stored.append(value) }
    }
    var results: [Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>] {
        lock.withLock { stored }
    }
    var successes: [HLSVideoEncodedOutput] {
        results.compactMap { try? $0.get() }
    }
    var failures: [VTVideoEncoderFailure] {
        results.compactMap { result in
            guard case let .failure(error) = result else { return nil }
            return error
        }
    }
}

private final class CancellationReceiptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func record(_ value: Bool) { lock.withLock { stored = value } }
}

private final class FinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>] = []
    func record(_ value: Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>) {
        lock.withLock { stored.append(value) }
    }
    var successes: [HLSVideoEncoderFinishReceipt] {
        lock.withLock { stored.compactMap { try? $0.get() } }
    }
}

private struct TestRBSPBitWriter {
    private var bytes: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var usedBitCount = 0

    mutating func append(bit: Bool) {
        currentByte = (currentByte << 1) | (bit ? 1 : 0)
        usedBitCount += 1
        if usedBitCount == 8 {
            bytes.append(currentByte)
            currentByte = 0
            usedBitCount = 0
        }
    }

    mutating func append(_ value: UInt64, bitCount: Int) {
        for shift in stride(from: bitCount - 1, through: 0, by: -1) {
            append(bit: value & (UInt64(1) << UInt64(shift)) != 0)
        }
    }

    mutating func appendUnsignedExpGolomb(_ value: UInt64) {
        let codeNumber = value + 1
        let bitCount = 64 - codeNumber.leadingZeroBitCount
        for _ in 1..<bitCount { append(bit: false) }
        append(codeNumber, bitCount: bitCount)
    }

    mutating func finish() -> [UInt8] {
        append(bit: true)
        while usedBitCount != 0 { append(bit: false) }
        return bytes
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.withLock { stored += 1 } }
    var value: Int { lock.withLock { stored } }
}
