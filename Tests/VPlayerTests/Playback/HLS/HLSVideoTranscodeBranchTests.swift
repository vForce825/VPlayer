// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import VideoToolbox
import XCTest
@testable import VPlayerPlayback

final class HLSVideoTranscodeBranchTests: XCTestCase {
    func testPaidPrepaidCapabilityKeepsOriginalChargeAfterSourceLeaseReleases() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSDataPlaneAdmission(
            capacity: 2, maximumBytes: 4_096, applicationLedger: ledger
        )
        guard case let .accepted(paidLease) = admission.admit(
            units: 1, bytes: 1_024, applicationBytes: 1_280
        ) else { return XCTFail("测试前置：真实 application reservation 必须成功") }
        XCTAssertNil(paidLease.makePrepaidCapability(maximumPrepaidBytes: 1_025),
                     "capability 的预付范围不得超过真实 paid lease 的已准入 bytes")
        var capability: HLSDataPlaneAdmission.PrepaidCapability? = paidLease.makePrepaidCapability(
            maximumPrepaidBytes: 1_024
        )
        XCTAssertNotNil(capability, "只有真实已付费 reservation 能签发预付能力")
        let chargedWhilePaid = ledger.chargedBytes
        paidLease.release()
        XCTAssertEqual(ledger.chargedBytes, chargedWhilePaid,
                       "原 lease 提前 release 后，capability 仍须持有真实费用")

        guard case let .accepted(prepaidLease) = admission.admitPrepaid(
            units: 1, bytes: 1_024, capability: try XCTUnwrap(capability)
        ) else { return XCTFail("存活 capability 应可交接已预付的同一 backing") }
        XCTAssertNil(prepaidLease.makePrepaidCapability(maximumPrepaidBytes: 1_024),
                     "无 application reservation 的 local-only 预付 lease 不得重新签发能力")
        prepaidLease.release()
        XCTAssertEqual(ledger.chargedBytes, chargedWhilePaid)
        capability = nil
        XCTAssertEqual(ledger.chargedBytes, 0,
                       "最后一个 capability 释放后才可归还原始 application reservation")
    }

    func testPrepaidCapabilityRejectsDifferentLedgerWithoutCreatingUnchargedLease() throws {
        let paidLedger = HLSDeliveryApplicationChargeLedger()
        let foreignLedger = HLSDeliveryApplicationChargeLedger()
        let paidAdmission = HLSDataPlaneAdmission(
            capacity: 1, maximumBytes: 4_096, applicationLedger: paidLedger
        )
        let foreignAdmission = HLSDataPlaneAdmission(
            capacity: 1, maximumBytes: 4_096, applicationLedger: foreignLedger
        )
        guard case let .accepted(paidLease) = paidAdmission.admit(
            units: 1, bytes: 1_024, applicationBytes: 1_280
        ), let capability = paidLease.makePrepaidCapability(maximumPrepaidBytes: 1_024) else {
            return XCTFail("测试前置：真实 reservation 必须签发 capability")
        }
        paidLease.release()

        guard case .permanentlyRejected = foreignAdmission.admitPrepaid(
            units: 1, bytes: 1_024, capability: capability
        ) else { return XCTFail("跨 ledger capability 不得换取无费用 lease") }
        XCTAssertEqual(foreignAdmission.usage.count, 0)
        XCTAssertGreaterThan(paidLedger.chargedBytes, 0,
                             "拒绝跨账本使用不能偷放原始 reservation")
    }

    func testLocalOnlyPrepaidLeaseCannotIssuePrepaidCapability() {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSDataPlaneAdmission(
            capacity: 2, maximumBytes: 4_096, applicationLedger: ledger
        )
        guard case let .accepted(paidLease) = admission.admit(
            units: 1, bytes: 1_024, applicationBytes: 1_280
        ), let capability = paidLease.makePrepaidCapability(maximumPrepaidBytes: 1_024),
              case let .accepted(localOnlyLease) = admission.admitPrepaid(
                units: 1, bytes: 1_024, capability: capability
              ) else {
            return XCTFail("测试前置：真实 capability 的一次本地预付交接必须成功")
        }
        XCTAssertNil(localOnlyLease.makePrepaidCapability(maximumPrepaidBytes: 1_024),
                     "没有自身真实 application reservation 的 local-only lease 不得再签发 capability")
    }

    func testHLSConversionCreditPrepaysActualInputAndP010PairBeforeOutputAllocation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let admission = HLSDataPlaneAdmission(capacity: 3, maximumBytes: 1_000_000)
        let provider = HLSDecodedSurfaceAdmission(admission: admission)
        var source: CVPixelBuffer? = try VideoTestFactories.pixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, width: 16, height: 16
        )
        var tail: DecodedVideoFrameRetentionTail? = try XCTUnwrap(
            provider.admitSurface(pixelBuffer: try XCTUnwrap(source))
        )
        XCTAssertEqual(admission.usage.count, 1,
                       "60 个既有 conversion credit 的单位语义不因三份 backing 被改成 20")
        XCTAssertGreaterThan(admission.usage.bytes, CVPixelBufferGetDataSize(try XCTUnwrap(source)),
                             "同次 reservation 的 byte 费用必须含 input 及两个 output backing")
        var decoded: DecodedVideoFrame? = DecodedVideoFrame(
            accessUnitID: 1, pixelBuffer: try XCTUnwrap(source),
            presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 25),
            generation: .init(rawValue: 1), parserMetadata: .init(
                fieldOrder: nil, pictureStructure: .frame, isInterlaced: true,
                repeatFirstField: false, topFieldFirst: true, sourcePTS90k: 0
            ),
            formatMetadata: VideoFormatMetadata(
                dimensions: .init(width: 16, height: 16), bitDepth: 10, range: .full,
                matrix: .bt2020, transfer: .pq, primaries: .bt2020, cleanAperture: nil,
                chromaLocation: .init(topField: nil, bottomField: nil),
                hdrStaticMetadata: .init(masteringDisplayColorVolume: Data([1]), contentLightLevelInfo: Data([2]))
            ), retentionTail: tail
        )
        var outputs: YADIFAllocatedOutputs? = try HLSYADIFOutputAllocator().allocate(
            matching: try XCTUnwrap(decoded)
        )
        XCTAssertThrowsError(try HLSYADIFOutputAllocator().allocate(matching: try XCTUnwrap(decoded)),
                             "一个 input credit 不得重复创建第二个未预费 output pair")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(try XCTUnwrap(outputs).first),
                       kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        XCTAssertNoThrow(try YADIFTextureMapper(device: device).map(try XCTUnwrap(outputs).second))
        decoded = nil; source = nil; tail = nil
        XCTAssertEqual(admission.usage.count, 1,
                       "decoder input 已释放时，GPU/bridge/VT 的 output tail 仍保留同一 reservation")
        outputs = nil
        XCTAssertEqual(admission.usage.count, 0)
    }

    func testHLSOutputBackingCreditFollowsLastRawPixelBufferAliasWithoutPropagation() throws {
        let admission = HLSDataPlaneAdmission(capacity: 3, maximumBytes: 1_000_000)
        let provider = HLSDecodedSurfaceAdmission(admission: admission)
        var source: CVPixelBuffer? = try VideoTestFactories.pixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 16, height: 16
        )
        var tail: DecodedVideoFrameRetentionTail? = try XCTUnwrap(
            provider.admitSurface(pixelBuffer: try XCTUnwrap(source))
        )
        var decoded: DecodedVideoFrame? = DecodedVideoFrame(
            accessUnitID: 1, pixelBuffer: try XCTUnwrap(source),
            presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 25),
            generation: .init(rawValue: 1), parserMetadata: .init(
                fieldOrder: .tt, pictureStructure: .frame, isInterlaced: true,
                repeatFirstField: false, topFieldFirst: true, sourcePTS90k: 0
            ), formatMetadata: VideoFormatMetadata(
                dimensions: .init(width: 16, height: 16), bitDepth: 8, range: .video,
                matrix: .bt709, transfer: .bt709, primaries: .bt709,
                cleanAperture: nil,
                chromaLocation: .init(topField: nil, bottomField: nil),
                hdrStaticMetadata: .init(masteringDisplayColorVolume: nil, contentLightLevelInfo: nil)
            ),
            retentionTail: tail
        )
        var outputs: YADIFAllocatedOutputs? = try HLSYADIFOutputAllocator().allocate(
            matching: try XCTUnwrap(decoded)
        )
        var mode = CVAttachmentMode.shouldPropagate
        XCTAssertNotNil(CVBufferCopyAttachment(
            try XCTUnwrap(outputs).first,
            VideoOutputBackingRetentionTail.attachmentKey,
            &mode
        ))
        XCTAssertEqual(mode, .shouldNotPropagate,
                       "费用尾是 raw backing 的 owner，不能随图像 metadata 传播")

        var rawAlias: CVPixelBuffer? = try XCTUnwrap(outputs).first
        XCTAssertNotNil(rawAlias)
        decoded = nil; source = nil; tail = nil; outputs = nil
        XCTAssertEqual(admission.usage.count, 1,
                       "不能只靠 frame/tail 局部变量；外部 raw pixel-buffer alias 仍须持费")
        rawAlias = nil
        XCTAssertEqual(admission.usage.count, 0)
    }

    func testHLSSurfaceAdmissionCreatesAlignedVideoAndFullRangeIOSurfacesMappableByYADIF() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        for range in [VideoFormatMetadata.Range.video, .full] {
            let admission = HLSDataPlaneAdmission(capacity: 1, maximumBytes: 1_000_000)
            let provider = HLSDecodedSurfaceAdmission(admission: admission)
            let scope = provider.makeSurfaceSessionScope()
            var surface: (pixelBuffer: CVPixelBuffer, tail: DecodedVideoFrameRetentionTail)? = try XCTUnwrap(scope.allocateAdmittedFFmpegSurface(
                width: 318, height: 242, range: range
            ))
            let buffer = try XCTUnwrap(surface?.pixelBuffer)
            XCTAssertEqual(CVPixelBufferGetPlaneCount(buffer), 2)
            XCTAssertNoThrow(try YADIFSurfaceValidator.validate(YADIFSurfaceDescription(pixelBuffer: buffer)))
            let mapped = try YADIFTextureMapper(device: device).map(buffer)
            XCTAssertEqual(mapped.luma.pixelFormat, .r8Uint)
            XCTAssertEqual(mapped.chroma.pixelFormat, .rg8Uint)
            surface = nil
            XCTAssertEqual(admission.usage.count, 0)
        }
    }

    func testHLSSurfaceAdmissionRejectsIOSurfaceAllocationLargerThanPrepaidLayout() throws {
        let admission = HLSDataPlaneAdmission(capacity: 1, maximumBytes: 1_000_000)
        let provider = HLSDecodedSurfaceAdmission(
            admission: admission,
            surfaceAllocationSize: { _ in Int.max }
        )
        let scope = provider.makeSurfaceSessionScope()
        XCTAssertNil(scope.allocateAdmittedFFmpegSurface(width: 318, height: 242, range: .video))
        XCTAssertEqual(admission.usage.count, 0,
                       "超出声明的实际 backing allocation 必须受控拒绝并归还预费 tail")
    }

    func testRetiredSurfaceScopeSuppressesLateAllocationFailureAfterCancellation() throws {
        let enteredAllocationQuery = DispatchSemaphore(value: 0)
        let releaseAllocationQuery = DispatchSemaphore(value: 0)
        let noFatal = expectation(description: "已退休 scope 的迟到 allocation 失败不得上报 fatal")
        noFatal.isInverted = true
        let provider = HLSDecodedSurfaceAdmission(
            admission: HLSDataPlaneAdmission(capacity: 1, maximumBytes: 1_000_000),
            surfaceAllocationSize: { _ in
                enteredAllocationQuery.signal()
                releaseAllocationQuery.wait()
                return Int.max
            }
        )
        let scope = provider.makeSurfaceSessionScope { noFatal.fulfill() }
        let queue = DispatchQueue(label: "org.vplayer.tests.hls-surface.retired-allocation")
        let returned = expectation(description: "被取消的 allocation callback 返回")
        queue.async {
            XCTAssertNil(scope.allocateAdmittedFFmpegSurface(width: 318, height: 242, range: .video))
            returned.fulfill()
        }
        XCTAssertEqual(enteredAllocationQuery.wait(timeout: .now() + 2), .success)
        scope.cancelSurfaceAdmission()
        releaseAllocationQuery.signal()
        wait(for: [returned, noFatal], timeout: 0.2)
    }
    func testVideoOwnerInitialFormatKeepsInputGenerationAndAcceptsFirstAccessUnit() throws {
        let generation = MediaGeneration(rawValue: 9)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let branch = HLSVideoTranscodeBranch(
            generation: generation,
            inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 1,
            encoder: encoder,
            outputSink: { _ in }
        )
        let owner = HLSVideoBranch(
            executor: PlaybackSerialExecutor(label: "org.vplayer.tests.hls-video-owner"),
            decoderFactory: { _, sink in
                let decoder = OwnerVideoDecoder(eventSink: sink)
                decoderBox.decoder = decoder
                return decoder
            },
            passthrough: PassthroughVideoProcessor(),
            yadif: OwnerYADIFProcessor(),
            probe: nil,
            initialGeneration: generation,
            transcodeBranch: branch
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())

        let accepted = expectation(description: "first access unit accepted")
        owner.submit(try PlaybackFakeMedia.accessUnit(
            id: 1, generation: generation, randomAccess: true
        )) { result in
            XCTAssertTrue(result)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 2)
        XCTAssertEqual(decoderBox.decoder?.decodedAccessUnitIDs, [1])
    }

    func testVideoOwnerNaturalEOFWaitsForEncoderFinishReceipt() throws {
        let generation = MediaGeneration(rawValue: 9)
        let queue = FakeMetalCommandQueue()
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let transcode = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2, encoder: encoder,
            outputSink: { envelope in envelope.withBorrowedOutput { _ in } }
        )
        let factory = OwnerFactoryProbe()
        let owner = HLSVideoBranch(
            executor: PlaybackSerialExecutor(label: "org.vplayer.tests.hls-video-owner.real-eof"),
            decoderFactory: { provider, sink in
                let decoder = OwnerVideoDecoder(eventSink: sink, surfaceAdmission: provider)
                decoderBox.decoder = decoder
                return decoder
            },
            passthrough: PassthroughVideoProcessor(), yadif: OwnerYADIFProcessor(),
            yadifFactory: { allocator in
                let processor = try! YADIFProcessor(
                    commandSubmitter: queue, surfacePool: ProgressiveSurfacePool(),
                    outputAllocator: { try! allocator.allocate(matching: $0) },
                    // 只有一个 ready/window 槽：native EOF 放出 normalizer 两个
                    // tail 时，第三原帧必须经 owner FIFO 等待容量唤醒后重试。
                    clock: OwnerYADIFClock(), maximumInFlight: 1, maximumPendingFrames: 1
                )
                factory.store(processor)
                return processor
            }, probe: nil, initialGeneration: generation, transcodeBranch: transcode
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner.observeAudioTimelineOrigin(.zero)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        for id in UInt64(1)...3 {
            try OwnerVideoTestSupport.submit(owner, id: id, generation: generation, expected: true)
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            decoder.decodedAccessUnitIDs == [1, 2, 3]
        })
        decoder.holdNextNaturalDrain()
        let finished = expectation(description: "自然 EOF 取得 encoder receipt")
        owner.finishNaturally { result in
            guard case .success = result else {
                return XCTFail("自然 EOF 必须交付真实 encoder receipt，而非终态快照")
            }
            finished.fulfill()
        }
        try OwnerVideoTestSupport.submit(owner, id: 4, generation: generation, expected: false)
        for id in UInt64(1)...3 {
            decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
                id: id, generation: generation,
                pts: CMTime(value: Int64(id - 1), timescale: 25), interlaced: true
            ))
            decoder.complete(id: id)
        }
        XCTAssertFalse(OwnerVideoTestSupport.eventually(timeout: 0.1) {
            queue.pendingSubmissionCount > 0
        }, "native drain receipt 前，normalizer 的两个尾帧不得伪造完成")
        decoder.completeNaturalDrain()
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            factory.processor != nil && queue.pendingSubmissionCount == 1
        }, "normalizer 的两个尾帧不能在 native drain 前被跳过")
        for (jobIndex, accessUnitID) in [UInt64(1), 2, 3].enumerated() {
            XCTAssertTrue(OwnerVideoTestSupport.eventually {
                queue.pendingSubmissionCount == 1
            }, "第 \(jobIndex + 1) 个 normalizer/YADIF job 必须等待真实 GPU 完成")
            queue.completeNext(.completed)
            XCTAssertTrue(OwnerVideoTestSupport.eventually {
                encoder.submittedFrames.count == jobIndex * 2 + 2
            })
            XCTAssertEqual(
                encoder.submittedFrames.suffix(2).map(\.identity.accessUnitID),
                [accessUnitID, accessUnitID],
                "25i 的上下两个场必须成对进入编码器"
            )
            XCTAssertFalse(OwnerVideoTestSupport.eventually(timeout: 0.1) {
                encoder.finishCallCount > 0
            }, "任一双场仍在 encoder 时不得提前完成 EOF")
            encoder.completeFirstSuccessfully()
            XCTAssertEqual(encoder.submittedFrames.count, jobIndex * 2 + 2)
            encoder.completeFirstSuccessfully()
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually(timeout: 2) {
            encoder.finishCallCount > 0
        })
        XCTAssertEqual(encoder.finishCallCount, 1)
        encoder.completeFinishSuccessfully()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(encoder.submittedFrames.map(\.identity.accessUnitID), [1, 1, 2, 2, 3, 3],
                       "normalizer 尾、FIFO、bridge 与 encoder 必须完整保留双场顺序")
        XCTAssertEqual(factory.processor?.metricsSnapshot.gpuQueueFullDropCount, 0,
                       "owner FIFO 重试不能退化为 display 路径的 GPU 压力丢帧")
        let retired = expectation(description: "自然 EOF 后读取 encoder 实际完成事实")
        owner.retire(emergency: false) { receipt in
            XCTAssertTrue(receipt); retired.fulfill()
        }
        wait(for: [retired], timeout: 2)
        let repeated = expectation(description: "保存的自然 EOF 退休 receipt 可重复读取")
        owner.retire(emergency: false) { receipt in
            XCTAssertTrue(receipt); repeated.fulfill()
        }
        wait(for: [repeated], timeout: 2)
        XCTAssertEqual(encoder.cancelCallCount, 1,
                       "自然 EOF 已完成 native work 后不得重发 encoder cancel")
    }

    func testVideoOwnerBackpressureClosesDecoderAdmissionAndRetriesFIFO() throws {
        let generation = MediaGeneration(rawValue: 9)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let yadif = OwnerYADIFProcessor()
        let transcode = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2, encoder: encoder,
            outputSink: { envelope in envelope.withBorrowedOutput { _ in } }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: transcode, yadif: yadif
        )
        // 真实压测需要 HLS coordinator 走 YADIF；以 track 的已知场序驱动，不能
        // 依赖 16×16 fake pixel buffer 的 attachment 猜测。
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner.observeAudioTimelineOrigin(.zero)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        for id in UInt64(1)...5 {
            try OwnerVideoTestSupport.submit(owner, id: id, generation: generation, expected: true)
            decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
                id: id, generation: generation,
                pts: CMTime(value: Int64(id - 1), timescale: 25), interlaced: true
            ))
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            yadif.pendingCount == 3
        })
        yadif.completeFirstWithTwoFields()
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            encoder.submittedFrames.map(\.identity.accessUnitID) == [1, 1]
        })
        yadif.completeFirstWithTwoFields()
        XCTAssertTrue(OwnerVideoTestSupport.eventually { !owner.hasOpenInputAdmission })
        try OwnerVideoTestSupport.submit(owner, id: 6, generation: generation, expected: false)
        // 原子双场占满 branch 两格。第一场 retirement 后仍放不下下一原子 pair；
        // 第二场真实退休才会由 bridge 接纳完整 retry pair 并重开上游。
        encoder.completeFirstSuccessfully()
        XCTAssertEqual(encoder.submittedFrames.map(\.identity.accessUnitID), [1, 1])
        encoder.completeFirstSuccessfully()
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            encoder.submittedFrames.map(\.identity.accessUnitID) == [1, 1, 2, 2]
        })
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        try OwnerVideoTestSupport.submit(owner, id: 6, generation: generation, expected: true)
    }

    func testVideoOwnerNaturalEOFRejectsDuplicateAndStopCannotReviveLateDrain() throws {
        let generation = MediaGeneration(rawValue: 41)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2, encoder: encoder, outputSink: { _ in }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner.observeAudioTimelineOrigin(.zero)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        decoder.holdNextNaturalDrain()

        let firstEOF = expectation(description: "首个 EOF 被 stop 取消")
        owner.finishNaturally { result in
            guard case .failure(.cancelled) = result else {
                return XCTFail("stop 必须取消未完成 EOF")
            }
            firstEOF.fulfill()
        }
        let duplicateEOF = expectation(description: "重复 EOF 被有界拒绝")
        owner.finishNaturally { result in
            guard case .failure(.cancelled) = result else {
                return XCTFail("重复 EOF 不能创建第二个可完成 waiter")
            }
            duplicateEOF.fulfill()
        }
        wait(for: [duplicateEOF], timeout: 2)
        owner.stop(emergency: false)
        wait(for: [firstEOF], timeout: 2)
        decoder.completeNaturalDrain()
        XCTAssertFalse(OwnerVideoTestSupport.eventually(timeout: 0.1) { encoder.finishCallCount > 0 },
                       "stop 后迟到 native drain 不得进入 encoder finish")

        let replacementDecoderBox = OwnerDecoderBox()
        let replacementEncoder = BranchFakeVideoEncoder()
        let replacement = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: replacementDecoderBox,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 2, encoder: replacementEncoder, outputSink: { _ in }
            )
        )
        replacement.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        replacement.observeAudioTimelineOrigin(.zero)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { replacement.hasOpenInputAdmission })
        try OwnerVideoTestSupport.submit(replacement, id: 1, generation: generation, expected: true)
        _ = try XCTUnwrap(replacementDecoderBox.decoder)
        let replacedEOF = expectation(description: "换代取消已进入 encoder 的旧 EOF")
        let replacementResults = BranchFinishRecorder()
        replacement.finishNaturally { result in
            replacementResults.record(result)
            guard case .failure = result else {
                return XCTFail("格式换代不得确认旧 EOF")
            }
            replacedEOF.fulfill()
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            replacementEncoder.finishCallCount == 1
        }, "native/YADIF 已真实退休后才会进入 encoder finish")
        replacement.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        wait(for: [replacedEOF], timeout: 2)
        replacementEncoder.completeFinishSuccessfully()
        XCTAssertTrue(OwnerVideoTestSupport.eventually(timeout: 0.1) {
            replacementResults.values.count == 1
        }, "换代完成后迟到 encoder receipt 不得补发第二次成功")
        XCTAssertEqual(replacementResults.failures.count, 1)
    }

    func testVideoOwnerNaturalEOFAcceptsConfiguredAccessUnitBeforeNativeDrain() throws {
        let generation = MediaGeneration(rawValue: 42)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2, encoder: encoder, outputSink: { _ in }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch
        )
        let decoder = try XCTUnwrap(decoderBox.decoder)
        decoder.holdNextConfiguration()
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        decoder.holdNextNaturalDrain()
        owner.finishNaturally { _ in }
        decoder.completePendingConfiguration()
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            decoder.decodedAccessUnitIDs == [1]
        }, "EOF 不得跳过已接纳的配置 AU")
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            decoder.naturalDrainTransitionCount == 1
        }, "配置完成并提交 native decode 后才允许开始自然 drain")
        XCTAssertEqual(decoder.eventTimeline, ["decode:1", "drain"],
                       "自然 EOF 必须先消费配置中的 AU，再启动 native drain")
        decoder.completeNaturalDrain()
        owner.stop(emergency: false)
    }

    func testVideoOwnerFatalFailureDuringNativeDrainRevokesEOFBeforeLateDrain() throws {
        let generation = MediaGeneration(rawValue: 43)
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.hls-video-owner.fatal-native")
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2, encoder: encoder, outputSink: { _ in }
        )
        let fatalObserved = expectation(description: "真实 fatal 经 coordinator hook 到达 failureSink")
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch,
            executor: executor,
            failureSink: { _, observedGeneration in
                XCTAssertEqual(observedGeneration, generation)
                fatalObserved.fulfill()
            }
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner.observeAudioTimelineOrigin(.zero)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        decoder.holdNextNaturalDrain()
        let eofFailed = expectation(description: "native draining EOF 被 fatal 撤权")
        let results = BranchFinishRecorder()
        owner.finishNaturally { result in
            results.record(result)
            guard case .failure = result else { return XCTFail("fatal 后 EOF 不得成功") }
            eofFailed.fulfill()
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            decoder.naturalDrainTransitionCount == 1
        })
        decoder.emitFatal(.malfunction(-1))
        wait(for: [fatalObserved, eofFailed], timeout: 2)
        decoder.completeNaturalDrain()
        let lateDrainConsumed = expectation(description: "迟到 native drain 已由 owner lane 消费")
        executor.submit { lateDrainConsumed.fulfill() }
        wait(for: [lateDrainConsumed], timeout: 2)
        XCTAssertEqual(results.values.count, 1)
        XCTAssertEqual(results.failures.count, 1)
        XCTAssertEqual(encoder.finishCallCount, 0,
                       "fatal 抢先后迟到 native drain 不得进入 encoder finish")
    }

    func testVideoOwnerFatalFailureDuringEncoderFinishRevokesLateReceipt() throws {
        let generation = MediaGeneration(rawValue: 44)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        encoder.retainsLateFinishCompletion = true
        let yadif = OwnerYADIFProcessor()
        let branchWorkQueue = DispatchQueue(label: "org.vplayer.tests.hls-video-owner.fatal-receipt")
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2, encoder: encoder,
            workQueue: branchWorkQueue,
            surfaceLeaseFactory: { _ in VideoEncodingSurfaceLease {} },
            outputSink: { envelope in envelope.withBorrowedOutput { _ in } }
        )
        let fatalObserved = expectation(description: "encoder finish 时 fatal 到达 failureSink")
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch,
            yadif: yadif,
            failureSink: { _, observedGeneration in
                XCTAssertEqual(observedGeneration, generation)
                fatalObserved.fulfill()
            }
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner.observeAudioTimelineOrigin(.zero)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        let decoder = try XCTUnwrap(decoderBox.decoder)
        for id in UInt64(1)...3 {
            try OwnerVideoTestSupport.submit(owner, id: id, generation: generation, expected: true)
            decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
                id: id, generation: generation,
                pts: CMTime(value: Int64(id - 1), timescale: 25), interlaced: true
            ))
            decoder.complete(id: id)
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { yadif.pendingCount > 0 })
        yadif.completeFirstWithTwoFields()
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.submittedFrames.count == 2 })

        let eofFailed = expectation(description: "encoder finishing EOF 被 fatal 撤权")
        let results = BranchFinishRecorder()
        owner.finishNaturally { result in
            results.record(result)
            guard case .failure = result else { return XCTFail("fatal 后旧 encoder receipt 不得成功") }
            eofFailed.fulfill()
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually(timeout: 2) {
            if encoder.finishCallCount > 0 { return true }
            encoder.completeFirstSuccessfully()
            return false
        }, "至少一个真实双场已通过 bridge/encoder 后才进入 finish receipt")
        decoder.emitFatal(.malfunction(-1))
        wait(for: [fatalObserved, eofFailed], timeout: 2)
        encoder.deliverRetainedLateFinishSuccessfully()
        let lateReceiptConsumed = expectation(description: "迟到 encoder receipt 已由 branch queue 消费")
        branchWorkQueue.async { lateReceiptConsumed.fulfill() }
        wait(for: [lateReceiptConsumed], timeout: 2)
        XCTAssertEqual(results.values.count, 1)
        XCTAssertEqual(results.failures.count, 1)
    }

    func testVideoOwnerObservesEncoderFailureWithoutWaitingForAnotherBatch() throws {
        let generation = MediaGeneration(rawValue: 46)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let yadif = OwnerYADIFProcessor()
        let branch = HLSVideoTranscodeBranch(
            generation: generation,
            inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2,
            encoder: encoder,
            outputSink: { _ in }
        )
        let failureObserved = expectation(
            description: "编码器终态无需等待下一批即可到达 owner"
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation,
            decoderBox: decoderBox,
            transcodeBranch: branch,
            yadif: yadif,
            failureSink: { error, observedGeneration in
                XCTAssertEqual(observedGeneration, generation)
                guard case .metalCommand = error else {
                    return XCTFail("应保留为 HLS 编码分支失败，实际为 \(error)")
                }
                failureObserved.fulfill()
            }
        )
        owner.replaceFormat(
            try PlaybackFakeMedia.videoFormat(),
            streamFieldOrder: .tt
        )
        owner.observeAudioTimelineOrigin(.zero)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        let decoder = try XCTUnwrap(decoderBox.decoder)
        for id in UInt64(1)...3 {
            try OwnerVideoTestSupport.submit(
                owner,
                id: id,
                generation: generation,
                expected: true
            )
            decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
                id: id,
                generation: generation,
                pts: CMTime(value: Int64(id - 1), timescale: 25),
                interlaced: true
            ))
            decoder.complete(id: id)
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { yadif.pendingCount > 0 })
        yadif.completeFirstWithTwoFields()
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            !encoder.submittedFrames.isEmpty
        })

        encoder.completeFirst(with: .failure(.callback(-22)))

        wait(for: [failureObserved], timeout: 2)
        XCTAssertFalse(owner.hasOpenInputAdmission)
    }

    func testVideoOwnerFatalDecoderEventCancelsBranchAndRejectsLaterInput() throws {
        let generation = MediaGeneration(rawValue: 9)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 1, encoder: encoder, outputSink: { _ in }
        )
        let failed = expectation(description: "owner failure observed")
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch,
            failureSink: { _, observedGeneration in
                XCTAssertEqual(observedGeneration, generation)
                failed.fulfill()
            }
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        try XCTUnwrap(decoderBox.decoder).emitFatal(.malfunction(-1))
        wait(for: [failed], timeout: 2)
        try OwnerVideoTestSupport.submit(owner, id: 2, generation: generation, expected: false)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { branch.terminal == .cancelled })
        let laterRetirement = expectation(description: "fatal 首次 noop 后读取同一真实退休 receipt")
        owner.retire(emergency: false) { receipt in
            XCTAssertTrue(receipt)
            laterRetirement.fulfill()
        }
        wait(for: [laterRetirement], timeout: 2)
        XCTAssertEqual(encoder.cancelCallCount, 1,
                       "fatal 和后续 bundle caller 不得各自发起 native cancel")
    }

    func testVideoOwnerRetirementSharesOneActualEncoderReceiptWithLaterBundleCaller() throws {
        let generation = MediaGeneration(rawValue: 45)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        encoder.delaysCancelCompletion = true
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 1, encoder: encoder, outputSink: { _ in }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch
        )
        let first = expectation(description: "首个 owner 停在实际 encoder receipt 后确认")
        let duplicate = expectation(description: "在途重复申请明确拒绝")
        owner.retire(emergency: false) { XCTAssertTrue($0); first.fulfill() }
        owner.retire(emergency: false) { XCTAssertFalse($0); duplicate.fulfill() }
        wait(for: [duplicate], timeout: 2)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.cancelCallCount == 1 },
                      "重复拒绝只说明 context 已安装；必须等 owner 的实际链到达 encoder")
        encoder.completeFirstDelayedSuccessfully()
        wait(for: [first], timeout: 2)

        let later = expectation(description: "正式 bundle 读取同一实际成功 receipt")
        owner.retire(emergency: false) { XCTAssertTrue($0); later.fulfill() }
        wait(for: [later], timeout: 2)
        XCTAssertEqual(encoder.cancelCallCount, 1, "后续读取不得重发 native cancel")
    }

    func testVideoOwnerRetirementKeepsOwnerAliveUntilHeldEncoderReceiptThenReleasesIt() throws {
        let generation = MediaGeneration(rawValue: 46)
        let encoder = BranchFakeVideoEncoder()
        encoder.delaysCancelCompletion = true
        var owner: HLSVideoBranch? = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: OwnerDecoderBox(),
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1, encoder: encoder, outputSink: { _ in }
            )
        )
        let weakOwner = OwnerWeakReference(owner)
        let retired = expectation(description: "持有 encoder receipt 后确认")
        owner?.retire(emergency: false) { XCTAssertTrue($0); retired.fulfill() }
        owner = nil
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.cancelCallCount == 1 })
        XCTAssertNotNil(weakOwner.value, "唯一 RetirementContext 必须强持 owner")
        encoder.completeFirstDelayedSuccessfully()
        wait(for: [retired], timeout: 2)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { weakOwner.value == nil })
    }

    func testVideoOwnerNativeRetirementFailureStillCancelsEncoderAndKeepsUnconfirmedOwner() throws {
        let generation = MediaGeneration(rawValue: 49)
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        encoder.delaysCancelCompletion = true
        let yadif = OwnerYADIFProcessor()
        var owner: HLSVideoBranch? = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1, encoder: encoder, outputSink: { _ in }
            ), yadif: yadif
        )
        let decoder = try XCTUnwrap(decoderBox.decoder)
        decoder.holdNextRetirement()
        let results = OwnerRetirementResults()
        owner?.retire(emergency: false) { results.append($0) }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { decoder.isRetirementHeld })
        decoder.completeRetirement(.failed(.malfunction(-1)))
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.cancelCallCount == 1 },
                      "native failure 仍必须经过 YADIF barrier 到 encoder cancel")
        XCTAssertEqual(yadif.drainCallCount, 1)
        XCTAssertTrue(results.values.isEmpty)
        let weakOwner = OwnerWeakReference(owner)
        owner = nil
        XCTAssertNotNil(weakOwner.value, "未确认 context 必须保留 owner")
        encoder.completeFirstDelayedSuccessfully()
        XCTAssertTrue(OwnerVideoTestSupport.eventually { results.values == [false] })
        XCTAssertNotNil(weakOwner.value, "false 不能为求回零丢失未确认 owner")
        let repeated = expectation(description: "未确认退休重复请求明确失败")
        weakOwner.value?.retire(emergency: false) { receipt in
            XCTAssertFalse(receipt); repeated.fulfill()
        }
        wait(for: [repeated], timeout: 2)
        XCTAssertEqual(encoder.cancelCallCount, 1)
    }

    func testVideoOwnerRetirementWaitsForHeldNativeGPUAndEncoderReceipts() throws {
        let generation = MediaGeneration(rawValue: 47)
        let queue = FakeMetalCommandQueue()
        let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder()
        encoder.delaysCancelCompletion = true
        let factory = OwnerFactoryProbe()
        let ownerLane = PlaybackSerialExecutor(label: "org.vplayer.tests.retirement.real-yadif")
        let owner = HLSVideoBranch(
            executor: ownerLane,
            decoderFactory: { provider, sink in
                let decoder = OwnerVideoDecoder(eventSink: sink, surfaceAdmission: provider)
                decoderBox.decoder = decoder; return decoder
            }, passthrough: PassthroughVideoProcessor(), yadif: OwnerYADIFProcessor(),
            yadifFactory: { allocator in
                let processor = try! YADIFProcessor(
                    commandSubmitter: queue, surfacePool: ProgressiveSurfacePool(),
                    outputAllocator: { try! allocator.allocate(matching: $0) },
                    clock: OwnerYADIFClock(), maximumInFlight: 1, maximumPendingFrames: 4
                )
                factory.store(processor); return processor
            }, probe: nil, initialGeneration: generation,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 2, encoder: encoder, outputSink: { _ in }
            )
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner.observeAudioTimelineOrigin(.zero)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission })
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        for index in 0..<4 {
            decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation,
                pts: CMTime(value: Int64(index), timescale: 25), interlaced: true
            ))
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { queue.pendingSubmissionCount == 1 })
        decoder.holdNextRetirement()
        let results = OwnerRetirementResults()
        owner.retire(emergency: false) { results.append($0) }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { decoder.isRetirementHeld })
        let nativeBarrier = expectation(description: "native held 后 owner lane 已消费")
        ownerLane.submit { XCTAssertTrue(results.values.isEmpty); nativeBarrier.fulfill() }
        wait(for: [nativeBarrier], timeout: 2)
        decoder.completeRetirement()
        let gpuBarrier = expectation(description: "native receipt 后 GPU barrier 尚未完成")
        ownerLane.submit {
            XCTAssertTrue(results.values.isEmpty); XCTAssertEqual(encoder.cancelCallCount, 0)
            gpuBarrier.fulfill()
        }
        wait(for: [gpuBarrier], timeout: 2)
        queue.completeNext(.completed)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.cancelCallCount == 1 })
        XCTAssertTrue(results.values.isEmpty, "encoder fake 的 terminal 不能代替 native receipt")
        encoder.completeFirstDelayedSuccessfully()
        XCTAssertTrue(OwnerVideoTestSupport.eventually { results.values == [true] })
    }

    func testFrozenPreparationRoleSingleClaimSurvivesOnlyThroughLastRawAlias() throws {
        let baseline = PlaybackResourceContextLedger.shared.chargedBytes
        var rawAlias: CVPixelBuffer?
        do {
        var preparation: FrozenPreparationOwner? = try FrozenPreparationOwner.reserve()
        var role: FrozenPreparationVideoRetirementRole? = try XCTUnwrap(
            preparation?.claimVideoRetirementRole()
        )
        XCTAssertNil(preparation?.claimVideoRetirementRole(), "固定图只可领取一个视频角色")
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, baseline + 19 * 1_024)
        let generation = MediaGeneration(rawValue: 48)
        let queue = FakeMetalCommandQueue(); let decoderBox = OwnerDecoderBox()
        let encoder = BranchFakeVideoEncoder(); let factory = OwnerFactoryProbe()
        var owner: HLSVideoBranch? = HLSVideoBranch(
            executor: PlaybackSerialExecutor(label: "org.vplayer.tests.frozen-role.raw-alias"),
            decoderFactory: { provider, sink in
                let decoder = OwnerVideoDecoder(eventSink: sink, surfaceAdmission: provider)
                decoderBox.decoder = decoder; return decoder
            }, passthrough: PassthroughVideoProcessor(), yadif: OwnerYADIFProcessor(),
            yadifFactory: { allocator in
                let processor = try! YADIFProcessor(commandSubmitter: queue,
                    surfacePool: ProgressiveSurfacePool(),
                    outputAllocator: { try! allocator.allocate(matching: $0) },
                    clock: OwnerYADIFClock(), maximumInFlight: 1, maximumPendingFrames: 4)
                factory.store(processor); return processor
            }, probe: nil, initialGeneration: generation,
            transcodeBranch: HLSVideoTranscodeBranch(generation: generation,
                inputFormat: OwnerVideoTestSupport.inputFormat, maximumPendingFrameCount: 2,
                encoder: encoder, outputSink: { _ in }), preparationRole: role
        )
        owner?.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner?.observeAudioTimelineOrigin(.zero)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner?.hasOpenInputAdmission == true })
        try OwnerVideoTestSupport.submit(try XCTUnwrap(owner), id: 1, generation: generation, expected: true)
        for index in 0..<4 { decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
            id: 1, generation: generation, pts: CMTime(value: Int64(index), timescale: 25), interlaced: true)) }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { queue.pendingSubmissionCount == 1 })
        queue.completeNext(.completed)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.submittedFrames.count == 2 })
        rawAlias = encoder.submittedFrames[0].pixelBuffer
        encoder.clearSubmittedHistory(); decoder.complete(id: 1)
        let retired = expectation(description: "owner 实际退休")
        owner?.retire(emergency: false) { XCTAssertTrue($0); retired.fulfill() }
        wait(for: [retired], timeout: 2)
        owner = nil; preparation = nil; role = nil
        while queue.pendingSubmissionCount > 0 { queue.completeNext(.completed) }
        }
        XCTAssertNotNil(rawAlias, "实际输出 backing 必须作为外部 raw alias 逃出图 scope")
        XCTAssertEqual(PlaybackResourceContextLedger.shared.chargedBytes, baseline + 19 * 1_024,
                       "最后 raw alias 只保留原 owner 的单份 19KiB")
        rawAlias = nil
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            PlaybackResourceContextLedger.shared.chargedBytes == baseline
        })
    }

    func testVideoOwnerStopRetainsInputChargeUntilMatchingCompletionAndIgnoresOldIdentity() throws {
        let generation = MediaGeneration(rawValue: 9)
        let ledger = HLSDeliveryApplicationChargeLedger(
            fixedBookkeepingChargeBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes - 20_000
        )
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let decoderBox = OwnerDecoderBox()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 1, encoder: BranchFakeVideoEncoder(), outputSink: { _ in }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch,
            inputAdmission: inputAdmission
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let baselineCharge = ledger.chargedBytes
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        XCTAssertGreaterThan(ledger.chargedBytes, 0)
        owner.stop(emergency: false)
        XCTAssertGreaterThan(ledger.chargedBytes, 0,
                             "stop 只请求 native 退休，不能提前退提交中的 AU 费用")
        decoder.complete(id: 1)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes == baselineCharge })
        decoder.complete(id: 1)
        XCTAssertEqual(ledger.chargedBytes, baselineCharge)
    }

    func testVideoOwnerConfigurationFailureReturnsPrepaidLeaseAndNotifiesWaitingProducer() throws {
        let generation = MediaGeneration(rawValue: 9)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let decoderBox = OwnerDecoderBox()
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation,
            decoderBox: decoderBox,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation,
                inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1,
                encoder: BranchFakeVideoEncoder(),
                outputSink: { _ in }
            ),
            inputAdmission: inputAdmission
        )
        let decoder = try XCTUnwrap(decoderBox.decoder)
        decoder.holdNextConfiguration()
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())

        let wakeup = HLSVideoInputCapacityWakeup()
        owner.installInputCapacityWakeup(wakeup)
        XCTAssertTrue(wakeup.wait(timeout: 2), "消费注册时的初始可用唤醒")
        let accepted = expectation(description: "configuration submission owns the lease")
        owner.submit(try PlaybackFakeMedia.accessUnit(id: 1, generation: generation, randomAccess: true)) {
            XCTAssertTrue($0)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 2)
        XCTAssertGreaterThan(ledger.chargedBytes, 0)
        XCTAssertTrue(wakeup.wait(timeout: 2), "消费配置关闭准入时的唤醒")

        let producerWoken = expectation(description: "producer lane 读取配置失败后的取消状态")
        DispatchQueue(label: "org.vplayer.tests.hls-video-owner.configuration-failure-producer").async {
            while owner.inputCapacityState != .cancelled {
                XCTAssertTrue(wakeup.wait(timeout: 2))
            }
            XCTAssertEqual(owner.inputCapacityState, .cancelled)
            producerWoken.fulfill()
        }

        decoder.failPendingConfiguration()
        wait(for: [producerWoken], timeout: 2)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes == 0 })
    }

    func testVideoOwnerStopBeforeNativeConfigurationReturnsPrepaidLease() throws {
        let generation = MediaGeneration(rawValue: 9)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let decoderBox = OwnerDecoderBox()
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation,
            decoderBox: decoderBox,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation,
                inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1,
                encoder: BranchFakeVideoEncoder(),
                outputSink: { _ in }
            ),
            inputAdmission: inputAdmission
        )
        let decoder = try XCTUnwrap(decoderBox.decoder)
        decoder.holdNextConfiguration()
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())

        let accepted = expectation(description: "配置中的 AU 已由 owner 持有")
        owner.submit(try PlaybackFakeMedia.accessUnit(id: 1, generation: generation, randomAccess: true)) {
            XCTAssertTrue($0)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 2)
        XCTAssertGreaterThan(ledger.chargedBytes, 0)

        owner.stop(emergency: false)

        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes == 0 },
                      "未交 native 的配置 AU 在停止时必须以 pending identity 精确退费")
    }

    func testVideoOwnerSynchronousDecodeThrowReturnsPrepaidLease() throws {
        let generation = MediaGeneration(rawValue: 9)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let decoderBox = OwnerDecoderBox()
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation,
            decoderBox: decoderBox,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation,
                inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1,
                encoder: BranchFakeVideoEncoder(),
                outputSink: { _ in }
            ),
            inputAdmission: inputAdmission
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        try XCTUnwrap(decoderBox.decoder).complete(id: 1)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes == 0 })

        let decoder = try XCTUnwrap(decoderBox.decoder)
        let wakeup = HLSVideoInputCapacityWakeup()
        owner.installInputCapacityWakeup(wakeup)
        XCTAssertTrue(wakeup.wait(timeout: 2), "先消费注册产生的初始可用通知")
        decoder.failNextDecode(with: .badData(-1))
        let rejected = expectation(description: "同步 decoder 拒绝有明确分类")
        owner.submitClassified(try PlaybackFakeMedia.accessUnit(
            id: 2, generation: generation, randomAccess: true
        )) { disposition in
            XCTAssertEqual(disposition, .discardedByDecoder)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
        XCTAssertTrue(wakeup.wait(timeout: 2),
            "同步拒绝归还 pending 输入槽后必须唤醒生产者重新检查容量")
        XCTAssertEqual(ledger.chargedBytes, 0,
                       "同步 throw 没有 native completion，pending lease 必须由拒绝路径归还")
    }

    func testVideoOwnerConfigurationTimeoutReturnsPrepaidLease() throws {
        let generation = MediaGeneration(rawValue: 9)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let deadline = OwnerTransitionDeadline()
        let decoderBox = OwnerDecoderBox()
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation,
            decoderBox: decoderBox,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation,
                inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1,
                encoder: BranchFakeVideoEncoder(),
                outputSink: { _ in }
            ),
            inputAdmission: inputAdmission,
            decoderTransitionDeadline: .milliseconds(1),
            decoderTransitionDeadlineScheduler: { _, operation in deadline.install(operation) }
        )
        let decoder = try XCTUnwrap(decoderBox.decoder)
        decoder.holdNextConfiguration()
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        XCTAssertGreaterThan(ledger.chargedBytes, 0)

        deadline.fire()

        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes == 0 })
        XCTAssertEqual(owner.inputCapacityState, .cancelled)
    }

    func testVideoOwnerLateAvailableWakeupReadsCurrentCancelledState() throws {
        let generation = MediaGeneration(rawValue: 9)
        let decoderBox = OwnerDecoderBox()
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation,
            decoderBox: decoderBox,
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation,
                inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1,
                encoder: BranchFakeVideoEncoder(),
                outputSink: { _ in }
            )
        )
        let wakeup = HLSVideoInputCapacityWakeup()
        owner.installInputCapacityWakeup(wakeup)
        XCTAssertTrue(wakeup.wait(timeout: 2), "消费注册时的初始可用唤醒")
        let producerLane = DispatchQueue(label: "org.vplayer.tests.hls-video-owner.late-wakeup")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let observed = expectation(description: "producer 在迟到唤醒后读取取消状态")
        producerLane.async {
            entered.signal()
            release.wait()
            XCTAssertTrue(wakeup.wait(timeout: 2))
            XCTAssertEqual(owner.inputCapacityState, .cancelled)
            observed.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        owner.stop(emergency: false)
        release.signal()

        wait(for: [observed], timeout: 2)
    }

    func testVideoOwnerStopSignalsBlockedProducerWithoutBlockingAndReleasesOwner() throws {
        let generation = MediaGeneration(rawValue: 9)
        let wakeup = HLSVideoInputCapacityWakeup()
        var owner: HLSVideoBranch? = OwnerVideoTestSupport.makeOwner(
            generation: generation,
            decoderBox: OwnerDecoderBox(),
            transcodeBranch: HLSVideoTranscodeBranch(
                generation: generation,
                inputFormat: OwnerVideoTestSupport.inputFormat,
                maximumPendingFrameCount: 1,
                encoder: BranchFakeVideoEncoder(),
                outputSink: { _ in }
            )
        )
        let releasedOwner = OwnerWeakReference(owner)
        owner?.installInputCapacityWakeup(wakeup)
        XCTAssertTrue(wakeup.wait(timeout: 2), "消费注册时的初始可用唤醒")

        let producerLane = DispatchQueue(label: "org.vplayer.tests.hls-video-owner.blocked-producer")
        let producerEntered = DispatchSemaphore(value: 0)
        let producerReleased = expectation(description: "阻塞 producer 被 stop 唤醒")
        producerLane.async { [weak owner] in
            producerEntered.signal()
            XCTAssertTrue(wakeup.wait(timeout: 2))
            XCTAssertEqual(owner?.inputCapacityState, .cancelled)
            producerReleased.fulfill()
        }
        XCTAssertEqual(producerEntered.wait(timeout: .now() + 2), .success)

        let started = Date()
        owner?.stop(emergency: false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1,
                          "owner/control lane 只 signal，不能等待 producer")
        wait(for: [producerReleased], timeout: 2)
        owner = nil
        XCTAssertTrue(OwnerVideoTestSupport.eventually { releasedOwner.value == nil },
                      "终态信号发出后 owner 必须解除对唤醒对象的注册")
    }

    func testVideoOwnerStopKeepsQueuedPrepaidAccessUnitUntilLaneDeclinesIt() throws {
        let generation = MediaGeneration(rawValue: 9)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.hls-video-owner.stop-queued")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        executor.submit {
            entered.signal()
            release.wait()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let decoderBox = OwnerDecoderBox()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 1, encoder: BranchFakeVideoEncoder(), outputSink: { _ in }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch,
            inputAdmission: inputAdmission, executor: executor
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let declined = expectation(description: "queued AU declined after stop")
        owner.submit(try PlaybackFakeMedia.accessUnit(id: 1, generation: generation, randomAccess: true)) {
            XCTAssertFalse($0)
            declined.fulfill()
        }
        XCTAssertGreaterThan(ledger.chargedBytes, 0)
        owner.stop(emergency: false)
        XCTAssertGreaterThan(ledger.chargedBytes, 0,
                             "stop 不能在排队闭包仍持有 AU 时提前退输入费用")
        release.signal()
        wait(for: [declined], timeout: 2)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes == 0 })
    }

    func testVideoOwnerStopDuringNativeDecodeMovesLeaseToMatchingCompletion() throws {
        let generation = MediaGeneration(rawValue: 9)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let decodeEntered = DispatchSemaphore(value: 0)
        let releaseDecode = DispatchSemaphore(value: 0)
        let decoderBox = OwnerDecoderBox()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 1, encoder: BranchFakeVideoEncoder(), outputSink: { _ in }
        )
        let owner = HLSVideoBranch(
            executor: PlaybackSerialExecutor(label: "org.vplayer.tests.hls-video-owner.stop-native"),
            decoderFactory: { _, sink in
                let decoder = OwnerVideoDecoder(
                    eventSink: sink, decodeEntered: decodeEntered, releaseDecode: releaseDecode
                )
                decoderBox.decoder = decoder
                return decoder
            },
            passthrough: PassthroughVideoProcessor(), yadif: OwnerYADIFProcessor(), probe: nil,
            initialGeneration: generation, transcodeBranch: branch, inputAdmission: inputAdmission
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        let accepted = expectation(description: "native decode ownership accepted")
        owner.submit(try PlaybackFakeMedia.accessUnit(id: 1, generation: generation, randomAccess: true)) {
            XCTAssertTrue($0)
            accepted.fulfill()
        }
        XCTAssertEqual(decodeEntered.wait(timeout: .now() + 2), .success)
        owner.stop(emergency: false)
        XCTAssertGreaterThan(ledger.chargedBytes, 0,
                             "native decode 尚未返回时 stop 不得删除交接中的 lease")
        releaseDecode.signal()
        wait(for: [accepted], timeout: 2)
        XCTAssertGreaterThan(ledger.chargedBytes, 0)
        try XCTUnwrap(decoderBox.decoder).complete(id: 1)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes == 0 })
    }

    func testVideoOwnerDelayedYADIFCompletionEncodesWholeTwoFieldBatch() throws {
        let generation = MediaGeneration(rawValue: 9)
        let decoderBox = OwnerDecoderBox()
        let yadif = OwnerYADIFProcessor()
        let encoder = BranchFakeVideoEncoder()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2, encoder: encoder,
            outputSink: { envelope in envelope.withBorrowedOutput { _ in } }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch, yadif: yadif
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        owner.observeAudioTimelineOrigin(.zero)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        for id in UInt64(1)...6 {
            try OwnerVideoTestSupport.submit(owner, id: id, generation: generation, expected: true)
            decoder.emit(try PlaybackFakeMedia.decodedFrame(
                id: id, generation: generation,
                pts: CMTime(value: Int64(id - 1), timescale: 25), interlaced: true
            ))
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { yadif.pendingCount > 0 })
        XCTAssertTrue(encoder.submittedFrames.isEmpty,
                      "YADIF 首输入只建立参考，completion 前不得绕过为单场编码")
        yadif.completeFirstWithTwoFields()
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            encoder.submittedFrames.count == 2
        })
        XCTAssertEqual(encoder.submittedFrames.map(\.identity.accessUnitID),
                       [encoder.submittedFrames[0].identity.accessUnitID,
                        encoder.submittedFrames[0].identity.accessUnitID])
    }

    func testVideoOwnerRealYADIFStopsBeforeGPUQueuePressureAndRetriesAfterCompletion() throws {
        let generation = MediaGeneration(rawValue: 9)
        let queue = FakeMetalCommandQueue()
        let yadif = try YADIFProcessor(
            commandSubmitter: queue,
            surfacePool: ProgressiveSurfacePool(),
            clock: OwnerYADIFClock(),
            maximumInFlight: 1,
            maximumPendingFrames: 1
        )
        let decoderBox = OwnerDecoderBox()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 100, encoder: BranchFakeVideoEncoder(), outputSink: { _ in }
        )
        let owner = OwnerVideoTestSupport.makeOwner(
            generation: generation, decoderBox: decoderBox, transcodeBranch: branch, yadif: yadif
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        owner.observeAudioTimelineOrigin(CMTime.zero)
        let decoder = try XCTUnwrap(decoderBox.decoder)

        // All eight are accepted before GPU pressure is visible. Their decoded
        // callbacks then arrive as the legal, already-prepaid tail after HLS
        // closes source admission.
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission },
                      "初始 decoder configure 完成前不提交第一个受费 AU")
        try OwnerVideoTestSupport.submit(owner, id: 1, generation: generation, expected: true)
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            decoder.decodedAccessUnitIDs == [1] && owner.hasOpenInputAdmission
        }, "AU1 触发的真实 decoder configure 完成后才提交后续初始 AU")
        for id in UInt64(2)...8 {
            XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.hasOpenInputAdmission },
                          "后续初始 AU 必须等待真实配置/准入重开")
            try OwnerVideoTestSupport.submit(owner, id: id, generation: generation, expected: true)
        }
        for id in UInt64(1)...8 {
            decoder.emit(try PlaybackFakeMedia.decodedFrame(
                id: id, generation: generation,
                pts: CMTime(value: Int64(id - 1), timescale: 25), interlaced: true
            ))
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { queue.pendingSubmissionCount == 1 })
        try OwnerVideoTestSupport.submit(owner, id: 9, generation: generation, expected: false)
        XCTAssertEqual(yadif.metricsSnapshot.gpuQueueFullDropCount, 0)

        for _ in 0..<8 {
            queue.completeNext(.completed)
            _ = OwnerVideoTestSupport.eventually(timeout: 0.1) { queue.pendingSubmissionCount > 0 }
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            queue.submittedSourceAccessUnitIDs.count >= 5
        })
        XCTAssertEqual(queue.submittedSourceAccessUnitIDs,
                       queue.submittedSourceAccessUnitIDs.sorted())
        XCTAssertEqual(yadif.metricsSnapshot.gpuQueueFullDropCount, 0)
        XCTAssertTrue(OwnerVideoTestSupport.eventually(timeout: 2) {
            queue.pendingSubmissionCount == 0
        }, "必须等待当前真实 GPU job 完成；normalizer/YADIF 尾可合法保留尚未成 job 的帧")
        for id in UInt64(1)...8 { decoder.complete(id) }
        XCTAssertTrue(OwnerVideoTestSupport.eventually(timeout: 2) { owner.hasOpenInputAdmission },
                      "matching native completion 归还输入 lease 后才允许第九 AU")
        try OwnerVideoTestSupport.submit(owner, id: 9, generation: generation, expected: true)
    }

    func testVideoOwnerFactoryRealYADIFPrepaysPairAndAdvancesAfterGPUHighWater() throws {
        let generation = MediaGeneration(rawValue: 31)
        let accessUnit = try OwnerVideoTestSupport.interlacedAccessUnit(id: 1, generation: generation)
        let source = try VideoTestFactories.pixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 16, height: 16
        )
        let headroom = try OwnerVideoTestSupport.conversionHighWaterHeadroom(
            source: source, accessUnit: accessUnit
        )
        let ledger = HLSDeliveryApplicationChargeLedger(
            fixedBookkeepingChargeBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes - headroom
        )
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let queue = FakeMetalCommandQueue()
        let decoderBox = OwnerDecoderBox()
        let factory = OwnerFactoryProbe()
        let encoder = BranchFakeVideoEncoder()
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2,
            admission: HLSDataPlaneAdmission(
                capacity: 2,
                maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
                applicationLedger: ledger
            ),
            encoder: encoder, outputSink: { envelope in
                envelope.withBorrowedOutput { _ in }
            }
        )
        let owner = HLSVideoBranch(
            executor: PlaybackSerialExecutor(label: "org.vplayer.tests.hls-credit.owner-factory"),
            decoderFactory: { provider, sink in
                let decoder = OwnerVideoDecoder(eventSink: sink, surfaceAdmission: provider)
                decoderBox.decoder = decoder
                return decoder
            }, passthrough: PassthroughVideoProcessor(), yadif: OwnerYADIFProcessor(),
            yadifFactory: { allocator in
                let processor = try! YADIFProcessor(
                    commandSubmitter: queue, surfacePool: ProgressiveSurfacePool(),
                    outputAllocator: { try! allocator.allocate(matching: $0) },
                    clock: OwnerYADIFClock(), maximumInFlight: 1, maximumPendingFrames: 4
                )
                factory.store(processor)
                return processor
            }, probe: nil, initialGeneration: generation, transcodeBranch: branch,
            inputAdmission: inputAdmission, applicationLedger: ledger
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: CodedFieldOrder.tt)
        owner.observeAudioTimelineOrigin(CMTime.zero)
        try OwnerVideoTestSupport.submit(owner, accessUnit: accessUnit, expected: true)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        for index in 0..<4 {
            decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation, pts: CMTime(value: Int64(index), timescale: 25), interlaced: true
            ))
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { factory.processor != nil && queue.pendingSubmissionCount == 1 })
        let prepaidCharge = ledger.chargedBytes
        let processor = try XCTUnwrap(factory.processor)
        XCTAssertEqual(processor.metricsSnapshot.gpuQueueFullDropCount, 0)
        queue.completeNext(.completed)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.submittedFrames.count == 2 })
        XCTAssertEqual(ledger.chargedBytes, prepaidCharge,
                       "真实 pair 进入 branch 不得在同一 ledger 重复计费")
    }

    func testCreditedRawAliasKeepsConversionReservationUntilLastHolderReleases() throws {
        let generation = MediaGeneration(rawValue: 32)
        let accessUnit = try OwnerVideoTestSupport.interlacedAccessUnit(id: 1, generation: generation)
        let source = try VideoTestFactories.pixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 16, height: 16
        )
        let headroom = try OwnerVideoTestSupport.conversionHighWaterHeadroom(
            source: source, accessUnit: accessUnit
        )
        let ledger = HLSDeliveryApplicationChargeLedger(
            fixedBookkeepingChargeBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes - headroom
        )
        let inputAdmission = HLSDataPlaneAdmission(
            capacity: 8,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: ledger
        )
        let queue = FakeMetalCommandQueue()
        let decoderBox = OwnerDecoderBox()
        let factory = OwnerFactoryProbe()
        let encoder = BranchFakeVideoEncoder()
        encoder.delaysCancelCompletion = true
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: OwnerVideoTestSupport.inputFormat,
            maximumPendingFrameCount: 2,
            admission: HLSDataPlaneAdmission(
                capacity: 2,
                maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
                applicationLedger: ledger
            ),
            encoder: encoder, outputSink: { envelope in envelope.withBorrowedOutput { _ in } }
        )
        let owner = HLSVideoBranch(
            executor: PlaybackSerialExecutor(label: "org.vplayer.tests.hls-credit.owner-stop"),
            decoderFactory: { provider, sink in
                let decoder = OwnerVideoDecoder(eventSink: sink, surfaceAdmission: provider)
                decoderBox.decoder = decoder
                return decoder
            }, passthrough: PassthroughVideoProcessor(), yadif: OwnerYADIFProcessor(),
            yadifFactory: { allocator in
                let processor = try! YADIFProcessor(
                    commandSubmitter: queue, surfacePool: ProgressiveSurfacePool(),
                    outputAllocator: { try! allocator.allocate(matching: $0) },
                    clock: OwnerYADIFClock(), maximumInFlight: 1, maximumPendingFrames: 4
                )
                factory.store(processor)
                return processor
            }, probe: nil, initialGeneration: generation, transcodeBranch: branch,
            inputAdmission: inputAdmission, applicationLedger: ledger
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat(), streamFieldOrder: .tt)
        owner.observeAudioTimelineOrigin(.zero)
        try OwnerVideoTestSupport.submit(owner, accessUnit: accessUnit, expected: true)
        let decoder = try XCTUnwrap(decoderBox.decoder)
        for index in 0..<4 {
            decoder.emitFrame(try PlaybackFakeMedia.decodedFrame(
                id: 1, generation: generation, pts: CMTime(value: Int64(index), timescale: 25), interlaced: true
            ))
        }
        XCTAssertTrue(OwnerVideoTestSupport.eventually { factory.processor != nil && queue.pendingSubmissionCount == 1 })
        queue.completeNext(.completed)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.submittedFrames.count == 2 })
        var rawAlias: CVPixelBuffer? = encoder.submittedFrames[0].pixelBuffer
        XCTAssertNotNil(rawAlias)
        encoder.clearSubmittedHistory()
        decoder.complete(id: 1)
        XCTAssertTrue(OwnerVideoTestSupport.eventually { ledger.chargedBytes > HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes - headroom })

        let started = Date()
        owner.stop(emergency: true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1,
                          "紧急 stop 只取消 owner 图，不能等待仍持有 surface lease 的原生 encoder")
        XCTAssertTrue(OwnerVideoTestSupport.eventually { owner.inputCapacityState == .cancelled })
        XCTAssertFalse(OwnerVideoTestSupport.eventually(timeout: 0.1) { branch.terminal == .cancelled },
                       "迟到 native cancel receipt 前不得宣布 branch 已退休")

        XCTAssertTrue(OwnerVideoTestSupport.eventually { encoder.cancelCallCount == 1 },
                      "必须先确认 owner 已实际发起 native cancel")
        encoder.completeFirstDelayedSuccessfully()
        XCTAssertTrue(OwnerVideoTestSupport.eventually { branch.terminal == .cancelled },
                      "迟到 encoder success 不得复活已取消的 owner 图")
        XCTAssertGreaterThan(ledger.chargedBytes,
                             HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes - headroom,
                             "encoder 迟到完成后，唯一 raw pixel-buffer alias 仍须保留 conversion reservation")
        rawAlias = nil
        XCTAssertTrue(OwnerVideoTestSupport.eventually {
            ledger.chargedBytes == HLSDeliveryApplicationChargeLedger.documentedApplicationSoftBytes - headroom
        })
    }

    func testVideoOwnerRetainsMoreThanEightProviderTailedOutputsUntilBlockedYADIFResumesInOrder() throws {
        let generation = MediaGeneration(rawValue: 9)
        let yadif = OwnerRetryingYADIFProcessor()
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.hls-video-owner.real-vt-multi-output")
        let submissionQueue = DispatchQueue(label: "org.vplayer.tests.hls-video-owner.real-vt-multi-output.submit")
        let api = FakeVideoToolboxAPI()
        let nativeInputFormat = VideoEncodingInputFormatSignature(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 16, height: 16, bitDepth: 8, range: .video,
            primaries: .unknown, transfer: .unknown, matrix: .unknown,
            cleanAperture: nil, sampleAspectRatio: nil,
            chromaLocation: .init(topField: nil, bottomField: nil),
            masteringDisplayColorVolume: nil, contentLightLevelInfo: nil
        )
        let branch = HLSVideoTranscodeBranch(
            generation: generation, inputFormat: nativeInputFormat,
            maximumPendingFrameCount: 100, encoder: BranchFakeVideoEncoder(), outputSink: { _ in }
        )
        let owner = HLSVideoBranch(
            executor: executor,
            decoderFactory: { provider, sink in
                VideoToolboxDecoder(
                    executor: executor,
                    eventSink: sink,
                    api: api,
                    tuning: .default,
                    submissionQueue: submissionQueue,
                    surfaceAdmission: provider
                )
            },
            passthrough: PassthroughVideoProcessor(), yadif: yadif, probe: nil,
            initialGeneration: generation, transcodeBranch: branch
        )
        owner.replaceFormat(try PlaybackFakeMedia.videoFormat())
        owner.observeAudioTimelineOrigin(.zero)
        try OwnerVideoTestSupport.submit(
            owner,
            accessUnit: try OwnerVideoTestSupport.interlacedAccessUnit(id: 1, generation: generation),
            expected: true
        )
        XCTAssertTrue(OwnerVideoTestSupport.eventually { api.snapshot.pendingDecodeCount == 1 })

        for outputIndex in 0..<12 {
            api.deliver(index: 0, output: VTDecodeOutput(
                status: noErr,
                infoFlags: [],
                imageBuffer: try VideoTestFactories.pixelBuffer(
                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    width: 16,
                    height: 16
                ),
                presentationTimeStamp: CMTime(value: Int64(outputIndex), timescale: 25),
                duration: CMTime(value: 1, timescale: 25)
            ), on: submissionQueue)
        }
        submissionQueue.sync {}

        XCTAssertEqual(yadif.submittedAccessUnitIDs, [])
        XCTAssertEqual(branch.terminal, nil, "合法迟到输出不得因旧 8 槽而 fatal")

        // normalizer 只保留两个重排序尾；其余十帧仍各自保有同一 owner/provider
        // 的 tail，因此真实 FIFO 压力超过旧上限 8，而非伪造三帧 reference window。
        for expectedCount in 1...10 {
            yadif.releaseOne()
            XCTAssertTrue(OwnerVideoTestSupport.eventually {
                yadif.submittedAccessUnitIDs.count == expectedCount
            })
        }
        XCTAssertEqual(yadif.submittedAccessUnitIDs, Array(repeating: UInt64(1), count: 10))
        XCTAssertEqual(yadif.submittedSourcePresentationTimes,
                       (0..<10).map { CMTime(value: Int64($0), timescale: 25) })
        for (index, presentationTimeStamp) in yadif.submittedPresentationTimes.enumerated() {
            XCTAssertEqual(CMTimeCompare(
                presentationTimeStamp,
                CMTime(value: Int64(index * 1_800), timescale: 90_000)
            ), 0, "normalizer 必须保持实际 field 时序，而不能仅以相同 AU ID 蒙混")
        }
    }

    func testAtomicBackpressureBridgeChargesAndReplaysWholeYADIFBatch() throws {
        let harness = try BranchHarness(capacity: 2)
        let bridge = HLSVideoAtomicBackpressureBridge(
            branch: harness.branch,
            applicationLedger: harness.applicationLedger
        )
        let capacityReleased = DispatchSemaphore(value: 0)
        harness.branch.installCapacityReleaseSink { bridge.signalCapacityReleased() }
        bridge.installCapacityWakeup { capacityReleased.signal() }
        let workQueueEntered = DispatchSemaphore(value: 0)
        let releaseWorkQueue = DispatchSemaphore(value: 0)
        harness.workQueue.async {
            workQueueEntered.signal()
            releaseWorkQueue.wait()
        }
        XCTAssertEqual(workQueueEntered.wait(timeout: .now() + 2), .success)

        let first = try harness.makeYADIFBatch(accessUnitID: 1, firstSequence: 1)
        let retry = try harness.makeYADIFBatch(accessUnitID: 2, firstSequence: 3)
        XCTAssertEqual(bridge.submit(.batch(first), generation: harness.generation), .accepted)
        XCTAssertEqual(bridge.submit(.batch(retry), generation: harness.generation), .retry)
        XCTAssertTrue(bridge.hasPendingBatch)
        XCTAssertGreaterThan(harness.applicationLedger.chargedBytes, 0,
                             "retry 返回前必须先为 bridge 所持原始双场建立 application charge")

        releaseWorkQueue.signal()
        harness.drain()
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.admission.usage.count, 0)
        XCTAssertEqual(capacityReleased.wait(timeout: .now() + 2), .success,
                       "必须在最后一个 admission tail owner 释放后通知，而不是 encoder callback 时")
        XCTAssertTrue(bridge.hasPendingBatch,
                      "第一批退费不能连带释放尚未接受的 retry 原始双场")

        XCTAssertEqual(bridge.retryPending(), .accepted)
        XCTAssertFalse(bridge.hasPendingBatch)
        XCTAssertEqual(harness.admission.usage.count, 2)
        harness.drain()
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.encoder.submittedFrames.map(\.identity.sequenceNumber), [1, 2, 3, 4],
                       "bridge 重试必须复交原子双场，不得丢场或重复消费")

        bridge.cancel()
        harness.drain()
        XCTAssertTrue(harness.encoder.waitUntilCancelCallbackDelivered(),
                      "bridge cancel 必须等同一 encoder 实际 cancel receipt")
        harness.drain()
        XCTAssertEqual(harness.branch.terminal, .cancelled)
        XCTAssertEqual(harness.applicationLedger.chargedBytes, 0)
    }

    func testProductionInterlacedCadenceEncodesBothProgressiveFieldsAt50p() throws {
        let harness = try BranchHarness(
            capacity: 2,
            cadencePolicy: HLSInterlacedYADIFPolicy.cadence
        )
        let batch = try harness.makeYADIFBatch(
            accessUnitID: 1,
            firstSequence: 10,
            sourceDuration: CMTime(value: 1, timescale: 25)
        )

        XCTAssertEqual(
            harness.branch.receive(.batch(batch), generation: harness.generation),
            .accepted
        )
        harness.drain()

        XCTAssertEqual(
            harness.encoder.submittedFrames.count,
            2,
            "生产分支必须一次把 YADIF 的两个场提交给编码器"
        )
        harness.encoder.completeFirstSuccessfully()
        harness.drain()

        let submitted = harness.encoder.submittedFrames
        guard submitted.count == 2 else {
            return XCTFail("25i 生产链路必须提交两个逐行场，实际为 \(submitted.count)")
        }
        XCTAssertEqual(submitted.map(\.identity.sequenceNumber), [10, 11])
        XCTAssertEqual(CMTimeCompare(submitted[0].presentationTimeStamp, .zero), 0)
        XCTAssertEqual(CMTimeCompare(
            submitted[1].presentationTimeStamp,
            CMTime(value: 1, timescale: 50)
        ), 0)
        for frame in submitted {
            XCTAssertEqual(CMTimeCompare(
                frame.duration,
                CMTime(value: 1, timescale: 50)
            ), 0)
        }
    }

    func testTemporarySubmissionAdmissionRetriesWholeYADIFBatchBeforeBlockedWorkQueueCapture()
        throws {
        let harness = try BranchHarness(capacity: 2)
        let workQueueEntered = DispatchSemaphore(value: 0)
        let releaseWorkQueue = DispatchSemaphore(value: 0)
        harness.workQueue.async {
            workQueueEntered.signal()
            releaseWorkQueue.wait()
        }
        XCTAssertEqual(workQueueEntered.wait(timeout: .now() + 2), .success)
        let first = try harness.makeYADIFBatch(accessUnitID: 1, firstSequence: 1)
        let retry = try harness.makeYADIFBatch(accessUnitID: 2, firstSequence: 3)
        let productionSink = harness.branch.admittedAtomicEncodingSink

        XCTAssertEqual(
            productionSink(.batch(first), harness.generation),
            .accepted
        )
        XCTAssertEqual(
            productionSink(.batch(retry), harness.generation),
            .retry(required: 2, available: 0)
        )
        XCTAssertEqual(harness.admission.usage.count, 2)
        XCTAssertTrue(harness.encoder.submittedFrames.isEmpty)
        XCTAssertEqual(harness.leaseRecorder.totalAcquisitionCount, 0)

        releaseWorkQueue.signal()
        harness.drain()
        XCTAssertEqual(harness.encoder.submittedFrames.map(\.identity.sequenceNumber), [1, 2])
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.admission.usage.count, 0)
        XCTAssertEqual(
            productionSink(.batch(retry), harness.generation),
            .accepted,
            "caller retries the original authoritative batch after capacity returns"
        )
    }

    func testPermanentlyImpossibleAdmissionRejectsBeforeDispatchOrSurfaceLease() throws {
        do {
            let hard = HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes
            let ledger = HLSDeliveryApplicationChargeLedger(
                fixedBookkeepingChargeBytes: hard - 1
            )
            let harness = try BranchHarness(capacity: 1, applicationLedger: ledger)
            let workQueueEntered = DispatchSemaphore(value: 0)
            let releaseWorkQueue = DispatchSemaphore(value: 0)
            harness.workQueue.async {
                workQueueEntered.signal()
                releaseWorkQueue.wait()
            }
            XCTAssertEqual(workQueueEntered.wait(timeout: .now() + 2), .success)

            let batch = try harness.makeRawBatch(accessUnitID: 2, sequence: 3)
            let result = harness.branch.receive(
                .batch(batch),
                generation: harness.generation
            )

            guard case let .rejected(failure) = result,
                  case let .dataPlaneAdmissionRejected(rejection) = failure,
                  case let .invalidApplicationCharge(required, minimum, maximum) = rejection else {
                releaseWorkQueue.signal()
                harness.drain()
                return XCTFail("single reservation above the immutable ledger limit must reject")
            }
            XCTAssertGreaterThan(required, minimum)
            XCTAssertEqual(maximum, 0,
                           "fixed usage at/above soft cap makes every new allocation permanent")
            XCTAssertTrue(harness.encoder.submittedFrames.isEmpty)
            XCTAssertEqual(harness.leaseRecorder.totalAcquisitionCount, 0)
            XCTAssertEqual(harness.admission.usage.count, 0)
            XCTAssertEqual(ledger.maximumChargedBytes, hard - 1)
            releaseWorkQueue.signal()
            harness.drain()
            XCTAssertEqual(harness.branch.terminal, .failed(failure))
        }

        do {
            let ledger = HLSDeliveryApplicationChargeLedger()
            let blocker = try ledger.reserve(
                allocationIdentity: UUID(),
                bytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes
            )
            let harness = try BranchHarness(capacity: 1, applicationLedger: ledger)
            let batch = try harness.makeRawBatch(accessUnitID: 3, sequence: 4)

            XCTAssertEqual(
                harness.branch.receive(.batch(batch), generation: harness.generation),
                .retry(required: 1, available: 1),
                "dynamic reservations are temporary even when they currently fill the hard cap"
            )
            XCTAssertNil(harness.branch.terminal)
            XCTAssertEqual(harness.leaseRecorder.totalAcquisitionCount, 0)
            ledger.release(blocker)
            XCTAssertEqual(
                harness.branch.receive(.batch(batch), generation: harness.generation),
                .accepted,
                "caller retries the same authoritative batch after dynamic charge release"
            )
            harness.drain()
            harness.branch.cancel()
            XCTAssertTrue(harness.encoder.waitUntilCancelCallbackDelivered())
            harness.drain()
            XCTAssertEqual(harness.admission.usage.count, 0)
        }
    }

    func testEncodedOutputAliasRetainsBatchAdmissionUntilDownstreamReleases() throws {
        let harness = try BranchHarness(capacity: 1, retainOutputEnvelopes: true)
        let first = try harness.makeRawBatch(accessUnitID: 1, sequence: 1)
        let second = try harness.makeRawBatch(accessUnitID: 2, sequence: 2)

        XCTAssertEqual(
            harness.branch.receive(.batch(first), generation: harness.generation),
            .accepted
        )
        harness.drain()
        harness.encoder.completeFirstSuccessfully()
        harness.drain()

        XCTAssertEqual(harness.outputs.map(\.sequenceNumber), [1])
        XCTAssertEqual(harness.admission.usage.count, 1)
        XCTAssertEqual(
            harness.branch.receive(.batch(second), generation: harness.generation),
            .retry(required: 1, available: 0)
        )
        harness.branch.cancel()
        harness.drain()
        XCTAssertTrue(harness.encoder.waitUntilCancelCallbackDelivered(),
                      "外部 alias 场景也必须等待 encoder 实际 cancel receipt")
        harness.drain()
        XCTAssertEqual(harness.branch.terminal, .cancelled)
        XCTAssertEqual(harness.admission.usage.count, 1,
                       "cancel cannot retire an externally retained output owner")
        harness.releaseOutputEnvelopes()
        XCTAssertEqual(harness.admission.usage.count, 0)
        XCTAssertEqual(harness.applicationLedger.chargedBytes, 0)
    }

    func testExternallyCancelledAdmissionConvergesVideoAndRejectsLaterFinish() throws {
        let harness = try BranchHarness(capacity: 1)
        harness.admission.cancel()
        let finishRecorder = BranchFinishRecorder()

        XCTAssertEqual(
            harness.branch.receive(
                .batch(try harness.makeRawBatch(accessUnitID: 1, sequence: 1)),
                generation: harness.generation
            ),
            .rejected(.cancelled)
        )
        harness.branch.finish(completion: finishRecorder.record)
        harness.drain()

        XCTAssertEqual(harness.branch.terminal, .cancelled)
        XCTAssertEqual(harness.encoder.cancelCallCount, 1)
        XCTAssertEqual(harness.encoder.finishCallCount, 0,
                       "finish cannot reopen a cancellation observed at admission")
        XCTAssertEqual(finishRecorder.failures, [.cancelled])
        XCTAssertEqual(harness.admission.usage.count, 0)
    }

    func testEncoderFailureAndCancelReleaseBatchAdmissionToBaseline() throws {
        do {
            let harness = try BranchHarness(capacity: 2)
            XCTAssertEqual(
                harness.branch.receive(
                    .batch(try harness.makeYADIFBatch(accessUnitID: 1, firstSequence: 1)),
                    generation: harness.generation
                ),
                .accepted
            )
            harness.drain()
            harness.encoder.completeFirst(with: .failure(.callback(-22)))
            harness.drain()
            XCTAssertEqual(harness.branch.terminal, .failed(.encoder(.callback(-22))))
            XCTAssertEqual(harness.admission.usage.count, 0)
            XCTAssertEqual(harness.applicationLedger.chargedBytes, 0)
        }

        do {
            let harness = try BranchHarness(capacity: 2)
            XCTAssertEqual(
                harness.branch.receive(
                    .batch(try harness.makeYADIFBatch(accessUnitID: 1, firstSequence: 1)),
                    generation: harness.generation
                ),
                .accepted
            )
            harness.drain()
            harness.branch.cancel()
            XCTAssertTrue(harness.encoder.waitUntilCancelCallbackDelivered())
            harness.drain()
            XCTAssertEqual(harness.branch.terminal, .cancelled)
            XCTAssertEqual(harness.admission.usage.count, 0)
            XCTAssertEqual(harness.applicationLedger.chargedBytes, 0)
        }
    }

    func testAtomicYADIFBatchPreservesFieldTimingIdentityOriginAndFormat() throws {
        let harness = try BranchHarness(capacity: 4)
        let batch = try harness.makeYADIFBatch(
            accessUnitID: 41,
            firstSequence: 80,
            presentationTimeStamp: CMTime(value: 7, timescale: 25),
            sourceDuration: CMTime(value: 1, timescale: 25),
            firstParity: .top
        )

        harness.branch.receive(.batch(batch), generation: harness.generation)
        harness.drain()

        XCTAssertEqual(harness.encoder.submittedFrames.count, 2)
        let first = try XCTUnwrap(harness.encoder.submittedFrames.first)
        XCTAssertEqual(first.identity, VideoEncodingFrameIdentity(
            generation: harness.generation,
            accessUnitID: 41,
            sequenceNumber: 80
        ))
        XCTAssertEqual(first.presentationTimeStamp, CMTime(value: 7, timescale: 25))
        XCTAssertEqual(first.duration, CMTime(value: 1, timescale: 50))
        XCTAssertEqual(first.presentationOrigin, .metalYADIF(field: .top))
        XCTAssertEqual(first.reliableFieldOrder, harness.reliableTopFirst)
        XCTAssertEqual(first.inputFormatSignature, harness.format)

        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        let second = try XCTUnwrap(harness.encoder.submittedFrames.last)
        XCTAssertEqual(second.identity.sequenceNumber, 81)
        XCTAssertEqual(second.presentationTimeStamp, CMTime(value: 3, timescale: 10))
        XCTAssertEqual(second.duration, CMTime(value: 1, timescale: 50))
        XCTAssertEqual(second.presentationOrigin, .metalYADIF(field: .bottom))
        XCTAssertEqual(second.reliableFieldOrder, harness.reliableTopFirst)
        XCTAssertEqual(harness.outputs.map(\.sequenceNumber), [80])

        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.outputs.map(\.sequenceNumber), [80, 81])
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 80), 1)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 81), 1)
    }

    func testYADIFGapFillSynthesizesContinuousFramesFromLastSurface() throws {
        let harness = try BranchHarness(
            capacity: 4,
            gapPolicy: .fillForwardGaps(maximumSyntheticFrameCount: 500)
        )
        XCTAssertEqual(harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 1,
                firstSequence: 1,
                presentationTimeStamp: .zero
            )),
            generation: harness.generation
        ), .accepted)
        XCTAssertEqual(harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 2,
                firstSequence: 3,
                presentationTimeStamp: CMTime(value: 228, timescale: 50)
            )),
            generation: harness.generation
        ), .accepted)

        for _ in 0..<230 {
            harness.drain()
            harness.encoder.completeFirstSuccessfully()
        }
        harness.drain()

        let submitted = harness.encoder.submittedFrames
        XCTAssertEqual(submitted.count, 230)
        XCTAssertEqual(submitted.map(\.presentationTimeStamp), (0..<230).map {
            CMTime(value: Int64($0), timescale: 50)
        })
        XCTAssertEqual(submitted.filter { $0.identity.gapFillOrdinal > 0 }.count, 226)
        XCTAssertTrue(submitted[2..<228].allSatisfy {
            $0.pixelBuffer === submitted[1].pixelBuffer
        }, "4.52 秒 GOP 恢复空洞必须复用上一场画面，不能提前显示未来帧")
        XCTAssertEqual(harness.leaseRecorder.acquisitionCount(for: 2), 1)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 2), 1,
            "所有合成帧完成后才归还上一场的唯一 surface lease")
    }

    func testYADIFGapFillSnapsTransportClockJitterToFieldCadence() throws {
        let harness = try BranchHarness(
            capacity: 6,
            gapPolicy: .fillForwardGaps(maximumSyntheticFrameCount: 500)
        )
        XCTAssertEqual(harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 1,
                firstSequence: 1,
                presentationTimeStamp: .zero
            )),
            generation: harness.generation
        ), .accepted)
        XCTAssertEqual(harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 2,
                firstSequence: 3,
                presentationTimeStamp: CMTime(value: 7_201, timescale: 90_000)
            )),
            generation: harness.generation
        ), .accepted)

        for _ in 0..<6 {
            harness.drain()
            harness.encoder.completeFirstSuccessfully()
        }
        harness.drain()

        XCTAssertNil(harness.branch.terminal)
        XCTAssertEqual(harness.encoder.submittedFrames.map(\.presentationTimeStamp), (0..<6).map {
            CMTime(value: Int64($0) * 1_800, timescale: 90_000)
        })
        XCTAssertEqual(
            harness.encoder.submittedFrames.filter { $0.identity.gapFillOrdinal > 0 }.count,
            2,
            "广播时钟的 1 tick 抖动不能被误判成非法时间；真正缺少的两场仍须补齐"
        )
    }

    func testPermanentBatchCapacityRejectsWithoutAcquiringEitherFieldLease() throws {
        let harness = try BranchHarness(capacity: 1)
        let batch = try harness.makeYADIFBatch(
            accessUnitID: 1,
            firstSequence: 10
        )

        let result = harness.branch.receive(.batch(batch), generation: harness.generation)
        harness.drain()

        XCTAssertTrue(harness.encoder.submittedFrames.isEmpty)
        XCTAssertEqual(harness.leaseRecorder.acquisitionCount(for: 10), 0)
        XCTAssertEqual(harness.leaseRecorder.acquisitionCount(for: 11), 0)
        XCTAssertEqual(harness.leaseRecorder.totalReleaseCount, 0)
        XCTAssertEqual(result, .rejected(.batchCapacityExceeded(required: 2, available: 1)))
        XCTAssertEqual(
            harness.branch.terminal,
            .failed(.batchCapacityExceeded(required: 2, available: 1))
        )
        XCTAssertEqual(harness.encoder.cancelCallCount, 1)
    }

    func testSlowFirstCallbackRetainsSecondFieldAndPrioritizesItBeforeLaterBatch() throws {
        let harness = try BranchHarness(capacity: 4)
        harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 1,
                firstSequence: 1
            )),
            generation: harness.generation
        )
        harness.branch.receive(
            .batch(try harness.makeRawBatch(
                accessUnitID: 2,
                sequence: 3,
                presentationTimeStamp: CMTime(value: 1, timescale: 25)
            )),
            generation: harness.generation
        )
        harness.drain()

        XCTAssertEqual(harness.encoder.submittedFrames.map(\.identity.sequenceNumber), [1, 2])
        XCTAssertEqual(harness.leaseRecorder.totalReleaseCount, 0)

        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.encoder.submittedFrames.map(\.identity.sequenceNumber), [1, 2, 3])
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 1), 1)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 2), 0)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 3), 0)
        XCTAssertEqual(harness.leaseRecorder.maximumLiveCount, 3)

        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.encoder.submittedFrames.map(\.identity.sequenceNumber), [1, 2, 3])
        XCTAssertEqual(harness.outputs.map(\.sequenceNumber), [1, 2])
    }

    func testFrozenFormatRejectsWholeBatchBeforeAnyFrameIsSubmitted() throws {
        let harness = try BranchHarness(capacity: 4)
        let changedMetadata = harness.makeMetadata(
            sampleAspectRatio: MediaRational(num: 1, den: 1),
            contentLightLevelInfo: Data([9, 8, 7, 6])
        )
        let batch = try harness.makeYADIFBatch(
            accessUnitID: 5,
            firstSequence: 20,
            metadata: changedMetadata
        )

        harness.branch.receive(.batch(batch), generation: harness.generation)
        harness.drain()

        XCTAssertTrue(harness.encoder.submittedFrames.isEmpty)
        XCTAssertEqual(harness.leaseRecorder.acquisitionCount(for: 20), 0)
        XCTAssertEqual(harness.leaseRecorder.acquisitionCount(for: 21), 0)
        XCTAssertEqual(harness.branch.terminal, .failed(.inputFormatChanged))
    }

    func testFrozenFormatAcceptsMissingDecodedColorAttachmentsWhenStreamSignatureIsKnown() throws {
        let harness = try BranchHarness(capacity: 4)
        let reference = harness.makeMetadata()
        let missingColorAttachments = VideoFormatMetadata(
            dimensions: reference.dimensions,
            bitDepth: reference.bitDepth,
            range: reference.range,
            matrix: .unknown,
            transfer: .unknown,
            primaries: .unknown,
            cleanAperture: nil,
            chromaLocation: .init(topField: nil, bottomField: nil),
            hdrStaticMetadata: .init(
                masteringDisplayColorVolume: nil,
                contentLightLevelInfo: nil
            ),
            sampleAspectRatio: nil
        )

        harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 6,
                firstSequence: 30,
                metadata: missingColorAttachments
            )),
            generation: harness.generation
        )
        harness.drain()

        XCTAssertEqual(harness.encoder.submittedFrames.map(\.identity.sequenceNumber), [30, 31],
                       "缺失的 decoded attachment 不能覆盖码流冻结的已知色彩签名")
        let submitted = try XCTUnwrap(harness.encoder.submittedFrames.first?.pixelBuffer)
        XCTAssertEqual(
            CVBufferCopyAttachment(submitted, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_2020 as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(submitted, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(submitted, kCVImageBufferYCbCrMatrixKey, nil) as? String,
            kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        )
        XCTAssertNotNil(
            CVBufferCopyAttachment(submitted, kCVImageBufferPixelAspectRatioKey, nil),
            "进入严格 VT 编码器前必须把码流冻结的 SAR 物化到 surface"
        )
        XCTAssertNotNil(
            CVBufferCopyAttachment(submitted, kCVImageBufferMasteringDisplayColorVolumeKey, nil),
            "进入严格 VT 编码器前必须把码流冻结的 HDR 静态元数据物化到 surface"
        )
        XCTAssertNil(harness.branch.terminal)
    }

    func testStaleGenerationBatchIsReleasedWithoutPoisoningCurrentGeneration() throws {
        let harness = try BranchHarness(capacity: 4)
        let staleGeneration = MediaGeneration(rawValue: harness.generation.rawValue - 1)
        harness.branch.receive(
            .batch(try harness.makeRawBatch(
                accessUnitID: 1,
                sequence: 1,
                generation: staleGeneration
            )),
            generation: staleGeneration
        )
        harness.branch.receive(
            .batch(try harness.makeRawBatch(
                accessUnitID: 2,
                sequence: 2
            )),
            generation: harness.generation
        )
        harness.drain()

        XCTAssertEqual(harness.encoder.submittedFrames.map(\.identity.sequenceNumber), [2])
        XCTAssertNil(harness.branch.terminal)
        XCTAssertEqual(harness.leaseRecorder.acquisitionCount(for: 1), 0)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 1), 0)

        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.outputs.map(\.sequenceNumber), [2])
    }

    func testFirstEncodedOutputBindsOriginAndHardwareProofToFirstFrame() throws {
        do {
            let harness = try BranchHarness(capacity: 2)
            harness.branch.receive(
                .batch(try harness.makeYADIFBatch(
                    accessUnitID: 1,
                    firstSequence: 1
                )),
                generation: harness.generation
            )
            harness.drain()
            harness.encoder.completeFirstSuccessfully(presentationOrigin: .raw)
            harness.drain()

            XCTAssertTrue(harness.outputs.isEmpty)
            XCTAssertEqual(
                harness.branch.terminal,
                .failed(.encoder(.unexpectedOutputFormat))
            )
        }

        do {
            let harness = try BranchHarness(capacity: 1)
            harness.branch.receive(
                .batch(try harness.makeRawBatch(
                    accessUnitID: 1,
                    sequence: 1
                )),
                generation: harness.generation
            )
            harness.drain()
            harness.encoder.completeFirstSuccessfully(
                hardwareFirstOutputIdentity: VideoEncodingFrameIdentity(
                    generation: harness.generation,
                    accessUnitID: 999,
                    sequenceNumber: 999
                )
            )
            harness.drain()

            XCTAssertTrue(harness.outputs.isEmpty)
            XCTAssertEqual(
                harness.branch.terminal,
                .failed(.encoder(.unexpectedOutputFormat))
            )
        }
    }

    func testLaterEncodedOutputCannotReplaceFrozenHardwareProof() throws {
        let harness = try BranchHarness(capacity: 2)
        harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 1,
                firstSequence: 1
            )),
            generation: harness.generation
        )
        harness.drain()
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        harness.encoder.completeFirstSuccessfully(hardwareSessionID: 100)
        harness.drain()

        XCTAssertEqual(harness.outputs.map(\.sequenceNumber), [1])
        XCTAssertEqual(
            harness.branch.terminal,
            .failed(.encoder(.unexpectedOutputFormat))
        )
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 1), 1)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 2), 1)
    }

    func testFinishReceiptMustMatchPublishedCountAndFrozenHardwareProof() throws {
        for corruption in [FinishReceiptCorruption.count, .hardwareSession] {
            let harness = try BranchHarness(capacity: 1)
            let finishRecorder = BranchFinishRecorder()
            harness.branch.receive(
                .batch(try harness.makeRawBatch(
                    accessUnitID: 1,
                    sequence: 1
                )),
                generation: harness.generation
            )
            harness.drain()
            harness.encoder.completeFirstSuccessfully()
            harness.drain()
            harness.branch.finish { finishRecorder.record($0) }
            harness.drain()

            switch corruption {
            case .count:
                harness.encoder.completeFinishSuccessfully(encodedFrameCount: 2)
            case .hardwareSession:
                harness.encoder.completeFinishSuccessfully(hardwareSessionID: 100)
            }
            harness.drain()

            XCTAssertEqual(
                harness.branch.terminal,
                .failed(.encoder(.unexpectedOutputFormat))
            )
            XCTAssertEqual(
                finishRecorder.failures,
                [.encoder(.unexpectedOutputFormat)]
            )
        }
    }

    func testEncoderFailureFailsOnceAndReleasesActiveAndQueuedLeases() throws {
        let harness = try BranchHarness(capacity: 4)
        harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 1,
                firstSequence: 1
            )),
            generation: harness.generation
        )
        harness.drain()

        harness.encoder.completeFirst(with: .failure(.callback(-12_345)))
        harness.drain()

        XCTAssertEqual(harness.branch.terminal, .failed(.encoder(.callback(-12_345))))
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 1), 1)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 2), 1)
        XCTAssertTrue(harness.outputs.isEmpty)
        XCTAssertEqual(harness.encoder.cancelCallCount, 1)
    }

    func testCancelReleasesEveryLeaseOnceAndLateCallbackCannotPublish() throws {
        let harness = try BranchHarness(capacity: 4)
        harness.encoder.retainsLateCallback = true
        harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 1,
                firstSequence: 1
            )),
            generation: harness.generation
        )
        harness.drain()

        harness.branch.cancel()
        harness.drain()
        harness.encoder.deliverRetainedLateSuccess()
        harness.drain()

        XCTAssertEqual(harness.branch.terminal, .cancelled)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 1), 1)
        XCTAssertEqual(harness.leaseRecorder.releaseCount(for: 2), 1)
        XCTAssertEqual(harness.encoder.cancelCallCount, 1)
        XCTAssertTrue(harness.outputs.isEmpty)
    }

    func testFinishDrainsAcceptedFramesThenFinishesEncoderExactlyOnce() throws {
        let harness = try BranchHarness(capacity: 4)
        let firstFinish = expectation(description: "第一个 finish 完成")
        let secondFinish = expectation(description: "第二个 finish 加入同一终结")
        let lateFinish = expectation(description: "终态 finish 复用收据")
        let finishRecorder = BranchFinishRecorder()
        harness.branch.receive(
            .batch(try harness.makeYADIFBatch(
                accessUnitID: 1,
                firstSequence: 1
            )),
            generation: harness.generation
        )
        harness.branch.finish { result in
            finishRecorder.record(result)
            firstFinish.fulfill()
        }
        harness.branch.finish { result in
            finishRecorder.record(result)
            secondFinish.fulfill()
        }
        harness.drain()
        XCTAssertEqual(harness.encoder.finishCallCount, 0)

        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.encoder.finishCallCount, 0)
        harness.encoder.completeFirstSuccessfully()
        harness.drain()
        XCTAssertEqual(harness.outputs.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(harness.encoder.finishCallCount, 1)

        harness.encoder.completeFinishSuccessfully()
        harness.drain()
        wait(for: [firstFinish, secondFinish], timeout: 1)
        XCTAssertEqual(finishRecorder.values.count, 2)
        XCTAssertEqual(harness.branch.terminal, .finished)

        harness.branch.finish { result in
            finishRecorder.record(result)
            lateFinish.fulfill()
        }
        harness.drain()
        wait(for: [lateFinish], timeout: 1)
        XCTAssertEqual(finishRecorder.values.count, 3)
        XCTAssertEqual(harness.encoder.finishCallCount, 1)
    }
}

private final class BranchHarness: @unchecked Sendable {
    let generation = MediaGeneration(rawValue: 9)
    let format: VideoEncodingInputFormatSignature
    let reliableTopFirst = ResolvedFieldOrder(
        parity: .top,
        confidence: .signaled,
        source: .parser
    )
    let encoder = BranchFakeVideoEncoder()
    let leaseRecorder = BranchLeaseRecorder()
    let workQueue = DispatchQueue(label: "org.vplayer.tests.hls-video-transcode-branch")
    let applicationLedger: HLSDeliveryApplicationChargeLedger
    let admission: HLSDataPlaneAdmission
    let branch: HLSVideoTranscodeBranch

    private let outputRecorder = BranchOutputRecorder()
    private let retainedOutputRecorder = BranchAdmittedOutputRecorder()

    var outputs: [VideoEncodingFrameIdentity] { outputRecorder.values }

    init(
        capacity: Int,
        retainOutputEnvelopes: Bool = false,
        gapPolicy: HLSVideoGapPolicy = .strict,
        cadencePolicy: HLSVideoTranscodeCadencePolicy = .preserveAllFields,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .init()
    ) throws {
        format = VideoEncodingInputFormatSignature(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            width: 1_920,
            height: 1_080,
            bitDepth: 10,
            range: .video,
            primaries: .bt2020,
            transfer: .pq,
            matrix: .bt2020,
            cleanAperture: nil,
            sampleAspectRatio: MediaRational(num: 4, den: 3),
            chromaLocation: .init(topField: "Left", bottomField: "Left"),
            masteringDisplayColorVolume: Data(repeating: 0x2A, count: 24),
            contentLightLevelInfo: Data([0x03, 0xE8, 0x01, 0x90])
        )
        self.applicationLedger = applicationLedger
        admission = HLSDataPlaneAdmission(
            capacity: capacity,
            maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
            applicationLedger: applicationLedger
        )
        branch = HLSVideoTranscodeBranch(
            generation: generation,
            inputFormat: format,
            maximumPendingFrameCount: capacity,
            gapPolicy: gapPolicy,
            cadencePolicy: cadencePolicy,
            admission: admission,
            encoder: encoder,
            workQueue: workQueue,
            surfaceLeaseFactory: { [leaseRecorder] output in
                leaseRecorder.makeLease(sequenceNumber: output.frame.sequenceNumber)
            },
            outputSink: { [outputRecorder, retainedOutputRecorder] envelope in
                envelope.withBorrowedOutput { outputRecorder.record($0.sourceIdentity) }
                if retainOutputEnvelopes { retainedOutputRecorder.append(envelope) }
            }
        )
    }

    func releaseOutputEnvelopes() { retainedOutputRecorder.removeAll() }

    func drain() { workQueue.sync {} }

    func makeYADIFBatch(
        accessUnitID: UInt64,
        firstSequence: UInt64,
        presentationTimeStamp: CMTime = .zero,
        sourceDuration: CMTime = CMTime(value: 1, timescale: 25),
        firstParity: FieldParity = .top,
        metadata: VideoFormatMetadata? = nil
    ) throws -> VideoProcessingFrameBatch {
        let fieldDuration = CMTimeMultiplyByRatio(
            sourceDuration,
            multiplier: 1,
            divisor: 2
        )
        let order = ResolvedFieldOrder(
            parity: firstParity,
            confidence: .signaled,
            source: .parser
        )
        let secondParity: FieldParity = firstParity == .top ? .bottom : .top
        return VideoProcessingFrameBatch(
            first: VideoProcessingOutputFrame(
                frame: try makeFrame(
                    accessUnitID: accessUnitID,
                    sequence: firstSequence,
                    presentationTimeStamp: presentationTimeStamp,
                    duration: fieldDuration,
                    generation: generation,
                    metadata: metadata
                ),
                origin: .metalYADIF(field: firstParity),
                resolvedFieldOrder: order
            ),
            remaining: [VideoProcessingOutputFrame(
                frame: try makeFrame(
                    accessUnitID: accessUnitID,
                    sequence: firstSequence + 1,
                    presentationTimeStamp: CMTimeAdd(presentationTimeStamp, fieldDuration),
                    duration: fieldDuration,
                    generation: generation,
                    metadata: metadata
                ),
                origin: .metalYADIF(field: secondParity),
                resolvedFieldOrder: order
            )]
        )
    }

    func makeRawBatch(
        accessUnitID: UInt64,
        sequence: UInt64,
        presentationTimeStamp: CMTime = .zero,
        generation: MediaGeneration? = nil
    ) throws -> VideoProcessingFrameBatch {
        VideoProcessingFrameBatch(first: VideoProcessingOutputFrame(
            frame: try makeFrame(
                accessUnitID: accessUnitID,
                sequence: sequence,
                presentationTimeStamp: presentationTimeStamp,
                duration: CMTime(value: 1, timescale: 25),
                generation: generation ?? self.generation,
                metadata: nil
            ),
            origin: .raw,
            resolvedFieldOrder: nil
        ))
    }

    func makeMetadata(
        sampleAspectRatio: MediaRational? = MediaRational(num: 4, den: 3),
        contentLightLevelInfo: Data? = Data([0x03, 0xE8, 0x01, 0x90])
    ) -> VideoFormatMetadata {
        VideoFormatMetadata(
            dimensions: CMVideoDimensions(width: format.width, height: format.height),
            bitDepth: Int(format.bitDepth),
            range: format.range,
            matrix: format.matrix,
            transfer: format.transfer,
            primaries: format.primaries,
            cleanAperture: nil,
            chromaLocation: format.chromaLocation,
            hdrStaticMetadata: .init(
                masteringDisplayColorVolume: format.masteringDisplayColorVolume,
                contentLightLevelInfo: contentLightLevelInfo
            ),
            sampleAspectRatio: sampleAspectRatio
        )
    }

    private func makeFrame(
        accessUnitID: UInt64,
        sequence: UInt64,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        generation: MediaGeneration,
        metadata: VideoFormatMetadata?
    ) throws -> VideoPresentationFrame {
        VideoPresentationFrame(
            pixelBuffer: try makePixelBuffer(),
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            generation: generation,
            sequenceNumber: sequence,
            sourceAccessUnitID: accessUnitID,
            formatMetadata: metadata ?? makeMetadata()
        )
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(format.width),
            Int(format.height),
            format.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VTVideoEncoderFailure.invalidPixelBuffer
        }
        return pixelBuffer
    }
}

private final class BranchAdmittedOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HLSVideoEncodedOutputEnvelope] = []

    func append(_ value: HLSVideoEncodedOutputEnvelope) {
        lock.withLock { values.append(value) }
    }

    func removeAll() {
        lock.withLock { values.removeAll(keepingCapacity: false) }
    }
}

private enum FinishReceiptCorruption {
    case count
    case hardwareSession
}

private final class BranchFakeVideoEncoder: HLSVideoEncoding, @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let frame: VideoEncodingFrame
        let completion: @Sendable (
            Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>
        ) -> Void
    }

    private let lock = NSLock()
    private let cancelCallbackDelivered = DispatchSemaphore(value: 0)
    private var submitted: [VideoEncodingFrame] = []
    private var pending: [Pending] = []
    private var retainedLate: Pending?
    private var finishCompletions: [@Sendable (
        Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>
    ) -> Void] = []
    private var retainedFinishCompletions: [@Sendable (
        Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>
    ) -> Void] = []
    private var retainedCancelCompletion: (@Sendable (Bool) -> Void)?
    private var storedTerminal: HLSVideoEncoderTerminal?
    private var finishedNativeWorkCompleted = false
    private var storedFinishCallCount = 0
    private var storedCancelCallCount = 0
    var retainsLateCallback = false
    var retainsLateFinishCompletion = false
    var delaysCancelCompletion = false

    var submittedFrames: [VideoEncodingFrame] { lock.withLock { submitted } }
    var finishCallCount: Int { lock.withLock { storedFinishCallCount } }
    var cancelCallCount: Int { lock.withLock { storedCancelCallCount } }
    var terminal: HLSVideoEncoderTerminal? { lock.withLock { storedTerminal } }

    func clearSubmittedHistory() {
        lock.withLock { submitted.removeAll(keepingCapacity: false) }
    }

    func encode(
        frame: VideoEncodingFrame,
        completion: @escaping @Sendable (
            Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>
        ) -> Void
    ) {
        lock.withLock {
            submitted.append(frame)
            pending.append(Pending(frame: frame, completion: completion))
        }
    }

    func finish(
        completion: @escaping @Sendable (
            Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>
        ) -> Void
    ) {
        lock.withLock {
            storedFinishCallCount += 1
            finishCompletions.append(completion)
        }
    }

    func cancel(completion: @escaping @Sendable (Bool) -> Void) {
        let cancellation: ([Pending], Bool) = lock.withLock {
            storedCancelCallCount += 1
            if storedTerminal == .finished, finishedNativeWorkCompleted { return ([], true) }
            guard storedTerminal == nil else { return ([], false) }
            storedTerminal = .cancelled
            if retainsLateFinishCompletion {
                retainedFinishCompletions = finishCompletions
                finishCompletions.removeAll(keepingCapacity: false)
            }
            let cancelled = pending
            pending.removeAll(keepingCapacity: false)
            if retainsLateCallback { retainedLate = cancelled.first }
            if delaysCancelCompletion {
                retainedLate = cancelled.first
                guard retainedCancelCompletion == nil else { return ([], false) }
                retainedCancelCompletion = completion
                return ([], false)
            }
            return (cancelled, true)
        }
        for item in cancellation.0 {
            item.frame.surfaceLease.release()
            item.completion(.failure(.cancelled))
        }
        if cancellation.1 {
            completion(true)
            cancelCallbackDelivered.signal()
        }
    }

    func waitUntilCancelCallbackDelivered(timeout: TimeInterval = 2) -> Bool {
        cancelCallbackDelivered.wait(timeout: .now() + timeout) == .success
    }

    func completeFirstSuccessfully(
        presentationOrigin: PresentationOrigin? = nil,
        hardwareSessionID: UInt64 = 99,
        hardwareFirstOutputIdentity: VideoEncodingFrameIdentity? = nil
    ) {
        let item: Pending? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }
        guard let item else { return }
        item.frame.surfaceLease.release()
        item.completion(.success(makeOutput(
            for: item.frame,
            presentationOrigin: presentationOrigin,
            hardwareSessionID: hardwareSessionID,
            hardwareFirstOutputIdentity: hardwareFirstOutputIdentity
        )))
    }

    func completeFirst(with result: Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>) {
        let item: Pending? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }
        guard let item else { return }
        item.frame.surfaceLease.release()
        item.completion(result)
    }

    func deliverRetainedLateSuccess() {
        let item = lock.withLock { retainedLate }
        guard let item else { return }
        item.completion(.success(makeOutput(for: item.frame)))
    }

    func completeFirstDelayedSuccessfully() {
        let delivery: (Pending?, (@Sendable (Bool) -> Void)?) = lock.withLock {
            defer { retainedLate = nil }
            let callback = retainedCancelCompletion
            retainedCancelCompletion = nil
            return (retainedLate, callback)
        }
        if let item = delivery.0 {
            item.frame.surfaceLease.release()
            item.completion(.success(makeOutput(for: item.frame)))
        }
        if let callback = delivery.1 {
            callback(true)
            cancelCallbackDelivered.signal()
        }
    }

    func completeFinishSuccessfully(
        encodedFrameCount: UInt64? = nil,
        hardwareSessionID: UInt64 = 99
    ) {
        let delivery: (
            [@Sendable (Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>) -> Void],
            HLSVideoEncoderFinishReceipt
        )? = lock.withLock {
            guard storedTerminal == nil, let first = submitted.first else { return nil }
            storedTerminal = .finished
            finishedNativeWorkCompleted = true
            let callbacks = finishCompletions
            finishCompletions.removeAll(keepingCapacity: false)
            return (callbacks, HLSVideoEncoderFinishReceipt(
                generation: first.identity.generation,
                encodedFrameCount: encodedFrameCount ?? UInt64(submitted.count),
                hardwareProof: VTHardwareEncoderProof(
                    sessionID: VTCompressionSessionID(rawValue: hardwareSessionID),
                    generation: first.identity.generation,
                    firstOutputIdentity: first.identity,
                    profile: .hevcMain10
                )
            ))
        }
        guard let delivery else { return }
        for callback in delivery.0 { callback(.success(delivery.1)) }
    }

    /// 模拟已向 encoder 注册、但 cancel 后才从硬件返回的 finish success；这不
    /// 改写 fake 的 cancelled terminal，也不让正常 finish API 复活。
    func deliverRetainedLateFinishSuccessfully() {
        let delivery: (
            [@Sendable (Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>) -> Void],
            HLSVideoEncoderFinishReceipt
        )? = lock.withLock {
            guard let first = submitted.first, !retainedFinishCompletions.isEmpty else { return nil }
            let callbacks = retainedFinishCompletions
            retainedFinishCompletions.removeAll(keepingCapacity: false)
            return (callbacks, HLSVideoEncoderFinishReceipt(
                generation: first.identity.generation,
                encodedFrameCount: UInt64(submitted.count),
                hardwareProof: VTHardwareEncoderProof(
                    sessionID: VTCompressionSessionID(rawValue: 99),
                    generation: first.identity.generation,
                    firstOutputIdentity: first.identity,
                    profile: .hevcMain10
                )
            ))
        }
        guard let delivery else { return }
        for callback in delivery.0 { callback(.success(delivery.1)) }
    }

    private func makeOutput(
        for frame: VideoEncodingFrame,
        presentationOrigin: PresentationOrigin? = nil,
        hardwareSessionID: UInt64 = 99,
        hardwareFirstOutputIdentity: VideoEncodingFrameIdentity? = nil
    ) -> HLSVideoEncodedOutput {
        HLSVideoEncodedOutput(
            sourceIdentity: frame.identity,
            sampleBuffer: Self.makePlaceholderSampleBuffer(),
            presentationOrigin: presentationOrigin ?? frame.presentationOrigin,
            inputFormatSignature: frame.inputFormatSignature,
            hardwareProof: VTHardwareEncoderProof(
                sessionID: VTCompressionSessionID(rawValue: hardwareSessionID),
                generation: frame.identity.generation,
                firstOutputIdentity: hardwareFirstOutputIdentity
                    ?? submittedFrames.first?.identity
                    ?? frame.identity,
                profile: .hevcMain10
            )
        )
    }

    private static func makePlaceholderSampleBuffer() -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 1,
            height: 1,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            formatDescription: format!,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr)
        return sample!
    }
}

private final class BranchLeaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var acquisitions: [UInt64: Int] = [:]
    private var releases: [UInt64: Int] = [:]
    private var liveCount = 0
    private var maximumStoredLiveCount = 0

    var totalAcquisitionCount: Int { lock.withLock { acquisitions.values.reduce(0, +) } }

    func makeLease(sequenceNumber: UInt64) -> VideoEncodingSurfaceLease {
        lock.withLock {
            acquisitions[sequenceNumber, default: 0] += 1
            liveCount += 1
            maximumStoredLiveCount = max(maximumStoredLiveCount, liveCount)
        }
        return VideoEncodingSurfaceLease { [weak self] in
            self?.lock.withLock {
                self?.releases[sequenceNumber, default: 0] += 1
                self?.liveCount -= 1
            }
        }
    }

    func acquisitionCount(for sequenceNumber: UInt64) -> Int {
        lock.withLock { acquisitions[sequenceNumber, default: 0] }
    }

    func releaseCount(for sequenceNumber: UInt64) -> Int {
        lock.withLock { releases[sequenceNumber, default: 0] }
    }

    var totalReleaseCount: Int {
        lock.withLock { releases.values.reduce(0, +) }
    }

    var maximumLiveCount: Int { lock.withLock { maximumStoredLiveCount } }
}

private final class BranchOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VideoEncodingFrameIdentity] = []
    func record(_ identity: VideoEncodingFrameIdentity) { lock.withLock { stored.append(identity) } }
    var values: [VideoEncodingFrameIdentity] { lock.withLock { stored } }
}

private final class BranchFinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [
        Result<HLSVideoEncoderFinishReceipt, HLSVideoTranscodeBranchFailure>
    ] = []

    func record(
        _ result: Result<HLSVideoEncoderFinishReceipt, HLSVideoTranscodeBranchFailure>
    ) {
        lock.withLock { stored.append(result) }
    }

    var values: [Result<HLSVideoEncoderFinishReceipt, HLSVideoTranscodeBranchFailure>] {
        lock.withLock { stored }
    }

    var failures: [HLSVideoTranscodeBranchFailure] {
        values.compactMap { result in
            guard case let .failure(failure) = result else { return nil }
            return failure
        }
    }
}

private enum OwnerVideoTestSupport {
    static let inputFormat = VideoEncodingInputFormatSignature(
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        width: 16,
        height: 16,
        bitDepth: 8,
        range: .video,
        primaries: .bt709,
        transfer: .bt709,
        matrix: .bt709,
        cleanAperture: nil,
        sampleAspectRatio: nil,
        chromaLocation: .init(topField: nil, bottomField: nil),
        masteringDisplayColorVolume: nil,
        contentLightLevelInfo: nil
    )

    static func makeOwner(
        generation: MediaGeneration,
        decoderBox: OwnerDecoderBox,
        transcodeBranch: HLSVideoTranscodeBranch,
        inputAdmission: HLSDataPlaneAdmission? = nil,
        executor: PlaybackSerialExecutor? = nil,
        yadif: any YADIFFrameProcessing = OwnerYADIFProcessor(),
        decoderTransitionDeadline: DispatchTimeInterval = .seconds(5),
        decoderTransitionDeadlineScheduler: VideoPipelineCoordinator.DecoderTransitionDeadlineScheduler? = nil,
        failureSink: @escaping HLSVideoBranch.FailureSink = { _, _ in }
    ) -> HLSVideoBranch {
        HLSVideoBranch(
            executor: executor ?? PlaybackSerialExecutor(label: "org.vplayer.tests.hls-video-owner"),
            decoderFactory: { _, sink in
                let decoder = OwnerVideoDecoder(eventSink: sink)
                decoderBox.decoder = decoder
                return decoder
            },
            passthrough: PassthroughVideoProcessor(),
            yadif: yadif,
            probe: nil,
            initialGeneration: generation,
            transcodeBranch: transcodeBranch,
            inputAdmission: inputAdmission,
            decoderTransitionDeadline: decoderTransitionDeadline,
            decoderTransitionDeadlineScheduler: decoderTransitionDeadlineScheduler,
            failureSink: failureSink
        )
    }

    static func submit(
        _ owner: HLSVideoBranch,
        id: UInt64,
        generation: MediaGeneration,
        expected: Bool
    ) throws {
        let completion = XCTestExpectation(description: "AU \(id) accepted=\(expected)")
        owner.submit(try PlaybackFakeMedia.accessUnit(
            id: id, generation: generation, randomAccess: true
        )) { result in
            XCTAssertEqual(result, expected, "AU \(id) expected=\(expected) actual=\(result)")
            completion.fulfill()
        }
        XCTWaiter().wait(for: [completion], timeout: 2)
    }

    static func submit(
        _ owner: HLSVideoBranch,
        accessUnit: CompressedVideoAccessUnit,
        expected: Bool
    ) throws {
        let completion = XCTestExpectation(description: "AU \(accessUnit.id) accepted=\(expected)")
        owner.submit(accessUnit) { result in
            XCTAssertEqual(result, expected, "AU \(accessUnit.id) expected=\(expected) actual=\(result)")
            completion.fulfill()
        }
        XCTWaiter().wait(for: [completion], timeout: 2)
    }

    static func interlacedAccessUnit(
        id: UInt64,
        generation: MediaGeneration
    ) throws -> CompressedVideoAccessUnit {
        let source = try PlaybackFakeMedia.accessUnit(
            id: id, generation: generation, randomAccess: true
        )
        return try CompressedVideoAccessUnit(
            id: source.id,
            sampleBuffer: source.sampleBuffer,
            generation: source.generation,
            isRandomAccess: source.isRandomAccess,
            randomAccessKind: source.randomAccessKind,
            scanClassification: source.scanClassification,
            parserMetadata: VideoParserMetadata(
                fieldOrder: .tt,
                pictureStructure: .frame,
                isInterlaced: true,
                repeatFirstField: false,
                topFieldFirst: true,
                sourcePTS90k: nil
            ),
            sourceBacking: try XCTUnwrap(source.sourceBacking),
            sourceByteRange: try XCTUnwrap(source.sourceByteRange)
        )
    }

    static func conversionHighWaterHeadroom(
        source: CVPixelBuffer,
        accessUnit: CompressedVideoAccessUnit
    ) throws -> Int {
        let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(source),
                                    "真实 conversion source 必须有 IOSurface backing")
        let inputBytes = IOSurfaceGetAllocSize(surface.takeUnretainedValue())
        let outputLayout = try XCTUnwrap(HLSYADIFOutputAllocator.Layout(source: source))
        let metadataBytes = 4 * HLSDataPlaneAdmission.applicationLeaseOverheadBytes + 3 * 512
        let accessUnitBytes = try XCTUnwrap(accessUnit.sourceByteRange).length
            + HLSDataPlaneAdmission.applicationLeaseOverheadBytes
        let fourNativeCredits = 4 * (inputBytes + 2 * outputLayout.allocationSize + metadataBytes)
        let boundedEncodedMargin = 2 * HLSDataPlaneAdmission.applicationLeaseOverheadBytes
        return fourNativeCredits + accessUnitBytes + boundedEncodedMargin
    }

    static func eventually(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private final class OwnerDecoderBox: @unchecked Sendable {
    var decoder: OwnerVideoDecoder?
}

private final class OwnerFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: YADIFProcessor?
    var processor: YADIFProcessor? { lock.withLock { value } }
    func store(_ processor: YADIFProcessor) { lock.withLock { value = processor } }
}

private final class OwnerSurfaceAdmissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any DecodedVideoSurfaceAdmitting)?
    var provider: (any DecodedVideoSurfaceAdmitting)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class OwnerWeakReference: @unchecked Sendable {
    weak var value: HLSVideoBranch?
    init(_ value: HLSVideoBranch?) { self.value = value }
}

private final class OwnerTransitionDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (@Sendable () -> Void)?

    func install(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { pending = operation }
    }

    func fire() {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { pending = nil }
            return pending
        }
        operation?()
    }
}

private final class OwnerInputCapacityStates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HLSVideoBranch.InputCapacityState] = []

    var values: [HLSVideoBranch.InputCapacityState] { lock.withLock { storage } }
    func append(_ state: HLSVideoBranch.InputCapacityState) {
        lock.withLock { storage.append(state) }
    }
}

private final class OwnerRetirementResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func append(_ value: Bool) { lock.withLock { storage.append(value) } }
}

private final class OwnerYADIFClock: PlaybackClock, @unchecked Sendable {
    var currentTime: CMTime { .zero }
    func pause() {}
    func anchor(mediaTime _: CMTime, atHostTime _: CMTime, rate _: Float) {}
    func setRate(_: Float) {}
}

private final class OwnerVideoDecoder: VideoDecoding, @unchecked Sendable {
    private let eventSink: @Sendable (VideoDecoderEvent) -> Void
    private let lock = NSLock()
    private var storedDecodedAccessUnitIDs: [UInt64] = []
    private var currentIdentity: VideoDecoderEventIdentity?
    private var holdsNextConfiguration = false
    private var heldNaturalDrainToken: VideoDecoderTransitionToken?
    private var heldRetirementToken: VideoDecoderTransitionToken?
    private var holdsNextNaturalDrain = false
    private var holdsNextRetirement = false
    private var storedNaturalDrainTransitionCount = 0
    private var storedEventTimeline: [String] = []
    private var nextDecodeFailure: VideoDecoderFailure?
    private let decodeEntered: DispatchSemaphore?
    private let releaseDecode: DispatchSemaphore?
    private let surfaceAdmission: (any DecodedVideoSurfaceAdmitting)?

    init(
        eventSink: @escaping @Sendable (VideoDecoderEvent) -> Void,
        decodeEntered: DispatchSemaphore? = nil,
        releaseDecode: DispatchSemaphore? = nil,
        surfaceAdmission: (any DecodedVideoSurfaceAdmitting)? = nil
    ) {
        self.eventSink = eventSink
        self.decodeEntered = decodeEntered
        self.releaseDecode = releaseDecode
        self.surfaceAdmission = surfaceAdmission
    }

    var decodedAccessUnitIDs: [UInt64] { lock.withLock { storedDecodedAccessUnitIDs } }
    var naturalDrainTransitionCount: Int { lock.withLock { storedNaturalDrainTransitionCount } }
    var isRetirementHeld: Bool { lock.withLock { heldRetirementToken != nil } }
    var eventTimeline: [String] { lock.withLock { storedEventTimeline } }

    func holdNextConfiguration() { lock.withLock { holdsNextConfiguration = true } }

    func holdNextNaturalDrain() { lock.withLock { holdsNextNaturalDrain = true } }
    func holdNextRetirement() { lock.withLock { holdsNextRetirement = true } }

    func completeRetirement(_ outcome: VideoDecoderTransitionOutcome = .completed) {
        guard let token = lock.withLock({ () -> VideoDecoderTransitionToken? in
            defer { heldRetirementToken = nil }
            return heldRetirementToken
        }) else { return }
        eventSink(.transitionCompleted(token: token, outcome: outcome))
    }

    func completeNaturalDrain() {
        guard let token = lock.withLock({ () -> VideoDecoderTransitionToken? in
            defer { heldNaturalDrainToken = nil }
            return heldNaturalDrainToken
        }) else { return }
        eventSink(.transitionCompleted(token: token, outcome: .completed))
    }

    func transition(_ transition: VideoDecoderTransition) {
        if case let .drainAndInvalidate(token) = transition {
            if lock.withLock({ () -> Bool in
                guard holdsNextRetirement else { return false }
                holdsNextRetirement = false
                heldRetirementToken = token
                return true
            }) { return }
            eventSink(.transitionCompleted(token: token, outcome: .completed))
            return
        }
        if case let .invalidate(token) = transition {
            eventSink(.transitionCompleted(token: token, outcome: .completed))
            return
        }
        if case let .drain(token) = transition {
            lock.withLock {
                storedNaturalDrainTransitionCount += 1
                storedEventTimeline.append("drain")
            }
            if lock.withLock({ () -> Bool in
                guard holdsNextNaturalDrain else { return false }
                holdsNextNaturalDrain = false
                heldNaturalDrainToken = token
                return true
            }) { return }
            eventSink(.transitionCompleted(token: token, outcome: .completed))
            return
        }
        guard case let .configure(token, _, generation) = transition else { return }
        lock.withLock {
            currentIdentity = VideoDecoderEventIdentity(
                generation: generation,
                transitionToken: token
            )
        }
        guard !lock.withLock({
            defer { holdsNextConfiguration = false }
            return holdsNextConfiguration
        }) else { return }
        eventSink(.transitionCompleted(token: token, outcome: .completed))
    }

    func failPendingConfiguration() {
        guard let identity = lock.withLock({ currentIdentity }) else { return }
        eventSink(.transitionCompleted(
            token: identity.transitionToken,
            outcome: .failed(.malfunction(-1))
        ))
    }

    func completePendingConfiguration() {
        guard let identity = lock.withLock({ currentIdentity }) else { return }
        eventSink(.transitionCompleted(token: identity.transitionToken, outcome: .completed))
    }

    func failNextDecode(with failure: VideoDecoderFailure) {
        lock.withLock { nextDecodeFailure = failure }
    }

    func decode(_ accessUnit: CompressedVideoAccessUnit, flags _: VTDecodeFrameFlags) throws {
        if let failure = lock.withLock({ () -> VideoDecoderFailure? in
            defer { nextDecodeFailure = nil }
            return nextDecodeFailure
        }) {
            throw failure
        }
        lock.withLock {
            storedDecodedAccessUnitIDs.append(accessUnit.id)
            storedEventTimeline.append("decode:\(accessUnit.id)")
        }
        decodeEntered?.signal()
        releaseDecode?.wait()
    }

    func emit(_ frame: DecodedVideoFrame) {
        guard let identity = lock.withLock({ currentIdentity }) else { return }
        eventSink(.frame(frame, identity: identity))
        complete(frame.accessUnitID)
    }

    func emitFrame(_ frame: DecodedVideoFrame) {
        guard let identity = lock.withLock({ currentIdentity }) else { return }
        let credited = DecodedVideoFrame(
            accessUnitID: frame.accessUnitID, pixelBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp, duration: frame.duration,
            generation: frame.generation, parserMetadata: frame.parserMetadata,
            formatMetadata: frame.formatMetadata,
            retentionTail: surfaceAdmission?.admitSurface(pixelBuffer: frame.pixelBuffer)
        )
        eventSink(.frame(credited, identity: identity))
    }

    func complete(_ accessUnitID: UInt64) {
        guard let identity = lock.withLock({ currentIdentity }) else { return }
        eventSink(.submissionCompleted(
            accessUnitID: accessUnitID,
            identity: identity,
            disposition: .produced
        ))
    }

    func emitFatal(_ failure: VideoDecoderFailure) {
        guard let identity = lock.withLock({ currentIdentity }) else { return }
        eventSink(.fatalFailure(failure, identity: identity))
    }

    func complete(id: UInt64) {
        guard let identity = lock.withLock({ currentIdentity }) else { return }
        eventSink(.submissionCompleted(accessUnitID: id, identity: identity, disposition: .cancelled))
    }
}

private final class OwnerYADIFProcessor: YADIFFrameProcessing, @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        let normalized: NormalizedDecodedFrame
        let order: ResolvedFieldOrder
        let completion: @Sendable (VideoProcessingResult) -> Void
    }
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var storedDrainCallCount = 0
    let requiredInputFrameCount = 3
    var pendingCount: Int { lock.withLock { pending.count } }
    var drainCallCount: Int { lock.withLock { storedDrainCallCount } }
    func reset(to _: MediaGeneration) { lock.withLock { pending.removeAll(keepingCapacity: false) } }
    func submit(
        normalized: NormalizedDecodedFrame,
        order: ResolvedFieldOrder,
        discontinuity _: Bool,
        completion: @escaping @Sendable (VideoProcessingResult) -> Void
    ) { lock.withLock { pending.append(.init(normalized: normalized, order: order, completion: completion)) } }
    func drain(completion: @escaping @Sendable () -> Void) {
        lock.withLock { storedDrainCallCount += 1 }
        completion()
    }
    func completeFirstWithTwoFields() {
        guard let item = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) else { return }
        let frame = item.normalized.frame
        let first = VideoPresentationFrame(
            pixelBuffer: frame.pixelBuffer, presentationTimeStamp: item.normalized.presentationTimeStamp,
            duration: item.normalized.fieldDuration, generation: frame.generation,
            sequenceNumber: frame.accessUnitID * 2, sourceAccessUnitID: frame.accessUnitID,
            formatMetadata: frame.formatMetadata
        )
        let second = VideoPresentationFrame(
            pixelBuffer: frame.pixelBuffer,
            presentationTimeStamp: CMTimeAdd(item.normalized.presentationTimeStamp, item.normalized.fieldDuration),
            duration: item.normalized.fieldDuration, generation: frame.generation,
            sequenceNumber: frame.accessUnitID * 2 + 1, sourceAccessUnitID: frame.accessUnitID,
            formatMetadata: frame.formatMetadata
        )
        let opposite: FieldParity = item.order.parity == .top ? .bottom : .top
        item.completion(.produced(.init(
            first: .init(frame: first, origin: .metalYADIF(field: item.order.parity), resolvedFieldOrder: item.order),
            remaining: [.init(frame: second, origin: .metalYADIF(field: opposite), resolvedFieldOrder: item.order)]
        )))
    }
}

private final class OwnerRetryingYADIFProcessor: YADIFFrameProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var retrying = true
    private var releaseSink: (@Sendable () -> Void)?
    private var submitted: [UInt64] = []
    private var submittedSourcePTS: [CMTime] = []
    private var submittedPTS: [CMTime] = []
    var submittedAccessUnitIDs: [UInt64] { lock.withLock { submitted } }
    var submittedSourcePresentationTimes: [CMTime] { lock.withLock { submittedSourcePTS } }
    var submittedPresentationTimes: [CMTime] { lock.withLock { submittedPTS } }
    func reset(to _: MediaGeneration) {}
    func submit(normalized: NormalizedDecodedFrame, order _: ResolvedFieldOrder,
                discontinuity _: Bool,
                completion _: @escaping @Sendable (VideoProcessingResult) -> Void) {
        lock.withLock {
            submitted.append(normalized.frame.accessUnitID)
            submittedSourcePTS.append(normalized.frame.presentationTimeStamp)
            submittedPTS.append(normalized.presentationTimeStamp)
        }
    }
    func trySubmit(normalized: NormalizedDecodedFrame, order: ResolvedFieldOrder,
                   discontinuity: Bool,
                   completion: @escaping @Sendable (VideoProcessingResult) -> Void) -> YADIFFrameAdmission {
        if lock.withLock({ retrying }) { return .retry }
        submit(normalized: normalized, order: order, discontinuity: discontinuity, completion: completion)
        return .accepted
    }
    func installCapacityReleaseSink(_ sink: @escaping @Sendable () -> Void) {
        lock.withLock { releaseSink = sink }
    }
    func drain(completion: @escaping @Sendable () -> Void) { completion() }
    func releaseOne() {
        let sink = lock.withLock { () -> (@Sendable () -> Void)? in
            retrying = false
            return releaseSink
        }
        sink?()
    }
}
