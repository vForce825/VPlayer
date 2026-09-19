// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import XCTest
@testable import VPlayerPlayback

final class AACPrimingCalibratorTests: XCTestCase {
    func testHLSRawSystemDecodePreservesEveryAUAndMeasuresChangedPrefix() async throws {
        let reference = AACPrimingCalibratorTestHarness.indexedSignal(start: 0, frames: 4_096, channels: 1)
        var baseline: Int?
        for prefix in [0,257,1_024] {
            let calibrator = AACPrimingCalibrator()
            let observer = AACReviewFixture()
            let request = try AACPrimingCalibratorTestHarness.request([.c]), plan = try AACCalibrationPlan.build([request])
            let encoder = try AACRenditionEncoder(identity: .init(plan: plan, ordinal: 0, request: request, nonce: ConverterInstanceNonce()),
                lane: calibrator.lane, workspace: calibrator.workspace, observer: AACDefaultCalibrationObserver(),
                presentationTerminal: calibrator.presentationTerminal)
            defer { encoder.dispose() }
            let source = [Float](repeating: 0, count: prefix) + reference
            let pass = try encoder.encodePass(source, cookieStage: .finalizedPass(1))
            let epoch = try encoder.makeEpoch(pass: pass, realFrames: pass.totalFrames, leading: 0)
            let decoded = try await AACSystemLoopback.decode(epoch: epoch, lane: calibrator.lane, workspace: calibrator.workspace, observer: observer)
            XCTAssertEqual(decoded.rawFrameCount, pass.totalFrames, "系统原始解码必须完整输出 Q")
            let expected = try AACPrimingCalibratorTestHarness.packetIdentity(epoch.buffers)
            XCTAssertEqual(decoded.packetIdentity, expected, "真实 HLS reader 必须保留所有 AU 字节与 packet 边界")
            XCTAssertEqual(decoded.rawReaderFormat, pass.asbd)
            XCTAssertFalse(try XCTUnwrap(decoded.rawReaderCookie).data.isEmpty)
            let measured = try AACPrimingCalibrator.leadingOffset(source: reference, decoded: decoded.rawSamples, channels: 1, maximumOffset: 8_192)
            let hash = expected.digest.map { String(format: "%02x", $0) }.joined()
            let attachment = XCTAttachment(string: "源前缀=\(prefix), Q=\(decoded.rawFrameCount), AU=\(expected.accessUnitCount), SHA256=\(hash), L=\(measured), reader=\(String(describing: decoded.rawReaderFormat))")
            attachment.name = "真实 HLS 原样 AU 与完整系统解码证据"; attachment.lifetime = .keepAlways; add(attachment)
            if let baseline { XCTAssertEqual(measured, baseline + prefix) }
            else { baseline = measured; XCTAssertGreaterThan(measured, 0) }
        }
    }
    func testIncrementalPumpAlternatesTwoRenditionsWithoutCallbackReentryOrReset() async throws {
        let observer = AACReviewFixture()
        let calibrator = AACPrimingCalibrator(observer: observer)
        let plan = try AACCalibrationPlan.build([AACPrimingCalibratorTestHarness.request([.c]), AACPrimingCalibratorTestHarness.request([.l,.r])])
        let receipt = try await calibrator.calibrate(plan: plan)
        var counts = [0,0], firstPTS = [CMTime?](repeating: nil, count: 2)
        for batch in 0..<100 {
            for (index, encoder) in receipt.encoders.enumerated() {
                let result = try encoder.pump(.pcm(AACPrimingCalibratorTestHarness.indexedSignal(start: batch * 1_024, frames: 1_024, channels: index + 1))) { buffer in
                    // append 已退出 converter permit；同一个 runner 可以继续自己的工作。
                    XCTAssertNoThrow(try calibrator.lane.call {})
                    if firstPTS[index] == nil { firstPTS[index] = CMSampleBufferGetOutputPresentationTimeStamp(buffer) }
                    counts[index] += 1
                }
                XCTAssertTrue(result.needsInput)
                XCTAssertNil(result.summary)
                XCTAssertNil(try encoder.pump(.unavailable, append: { _ in XCTFail("暂缺输入不是 EOS") }).summary)
            }
            if batch == 50 { XCTAssertTrue(counts.allSatisfy { $0 > 30 }, "两个 rendition 必须在 EOS 前持续产出") }
        }
        for (index, encoder) in receipt.encoders.enumerated() {
            let result = try encoder.pump(.endOfStream, append: { _ in counts[index] += 1 })
            let summary = try XCTUnwrap(result.summary)
            XCTAssertEqual(summary.realSampleCount, 102_400)
            XCTAssertEqual(summary.identity, encoder.identity)
            XCTAssertLessThanOrEqual(summary.maximumRetainedPackets, 64)
            XCTAssertEqual(firstPTS[index], CMTime(value: 10, timescale: 1))
        }
        XCTAssertLessThanOrEqual(calibrator.workspace.peakBytes, 4_194_304)
        XCTAssertEqual(calibrator.workspace.currentBytes, receipt.encoders.reduce(0) { $0 + $1.retainedEvidenceBytes })
    }

    func testIncrementalEncoderSignsPreEOSEmissionsAndExactlyOneFinalReceipt() async throws {
        let calibrator = AACPrimingCalibrator()
        let request = try AACPrimingCalibratorTestHarness.request([.l, .r])
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        var emissions: [AACIncrementalEmission] = []

        for batch in 0..<40 {
            let result = try encoder.pumpSigned(.pcm(
                AACPrimingCalibratorTestHarness.indexedSignal(
                    start: batch * 1_024,
                    frames: 1_024,
                    channels: 2)
            )) { emissions.append($0) }
            XCTAssertNil(result.finalReceipt)
        }
        XCTAssertFalse(emissions.isEmpty, "首批真实 AAC 必须在 EOS 前签发")
        XCTAssertEqual(emissions.map(\.ordinal), Array(0..<UInt64(emissions.count)))
        XCTAssertTrue(emissions.allSatisfy { $0.identity == encoder.identity })
        XCTAssertTrue(emissions.allSatisfy { $0.evidenceDigest.count == 32 })

        let terminal = try encoder.pumpSigned(.endOfStream) { emissions.append($0) }
        let final = try XCTUnwrap(terminal.finalReceipt)
        XCTAssertEqual(final.identity, encoder.identity)
        XCTAssertEqual(final.emissionCount, UInt64(emissions.count))
        XCTAssertEqual(final.cumulativeDigest.count, 32)
        XCTAssertEqual(final.finalEmission.ordinal, UInt64(emissions.count - 1))
        XCTAssertEqual(final.finalEmission.evidenceDigest,
                       emissions.last?.evidenceDigest)
        XCTAssertTrue(final.finalEmission.isFinalBuffer)
        XCTAssertEqual(Set(emissions.map(\.liveContextIdentity)).count, 1)
        XCTAssertTrue(emissions.allSatisfy {
            $0.frozenByteCount > 0 && $0.accountedFrozenBytes >= $0.frozenByteCount
        })
        XCTAssertTrue(final.matches(emissions: emissions))
        XCTAssertThrowsError(try encoder.pumpSigned(.endOfStream) { _ in })
    }

    func testIncrementalEncoderTemporaryPumpReservationFailureIsPreFillAndRecoverable() async throws {
        XCTAssertGreaterThanOrEqual(
            AACCalibrationWorkspace.aacPacketCapacity,
            2 * 1_024 * 1_024,
            "AAC 冻结窗口必须覆盖最长受支持 HLS GOP，不能在下一共同边界前耗尽"
        )
        let calibrator = AACPrimingCalibrator()
        let request = try AACPrimingCalibratorTestHarness.request([.l, .r])
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let blocker = try calibrator.workspace.acquire(
            .aacPackets,
            bytes: AACCalibrationWorkspace.aacPacketCapacity - 134_000
        )
        let samples = AACPrimingCalibratorTestHarness.indexedSignal(
            start: 0, frames: 16_384, channels: 2)
        var emissionCount = 0

        XCTAssertThrowsError(try encoder.pumpSigned(.pcm(samples)) {
            _ in emissionCount += 1
        }) { error in
            XCTAssertEqual(error as? AACRenditionFailure, .budgetUnavailable)
        }
        XCTAssertEqual(emissionCount, 0, "reservation 失败必须发生在首次 Fill 前")
        XCTAssertNil(encoder.terminalFailure,
                     "暂时 workspace 余额不足不得终结 encoder")

        blocker.release()
        let retry = try encoder.pumpSigned(.pcm(samples)) { _ in emissionCount += 1 }
        XCTAssertNil(encoder.terminalFailure)
        XCTAssertTrue(retry.needsInput || retry.waitingForEncoderBudget)
    }

    func testHLSCalibrationUsesNamedStrongDelegateAndRealInitMediaEvents() async throws {
        let observer = AACReviewFixture()
        let calibrator = AACPrimingCalibrator(observer: observer)
        let plan = try AACCalibrationPlan.build([AACPrimingCalibratorTestHarness.request([.l,.r])])
        _ = try await calibrator.calibrate(plan: plan)
        XCTAssertEqual(observer.initializationEvents, 2)
        XCTAssertGreaterThanOrEqual(observer.mediaEvents, 2)
        XCTAssertEqual(observer.writerIdentities.count, 2)
        XCTAssertLessThanOrEqual(observer.maximumCallbackCount, 8)
    }

    func testCancellationCleaningDoesNotPublishTerminalBeforeDisposeReturns() async throws {
        let observer = AACReviewFixture()
        let calibrator = AACPrimingCalibrator(observer: observer)
        let plan = try AACCalibrationPlan.build([AACPrimingCalibratorTestHarness.request([.c]), AACPrimingCalibratorTestHarness.request([.l,.r])])
        let receipt = try await calibrator.calibrate(plan: plan)
        var reentered = 0
        observer.onDispose = {
            reentered += 1
            XCTAssertFalse(calibrator.lane.isCancellationFinished)
            XCTAssertGreaterThan(calibrator.workspace.currentBytes, 0)
            do { try calibrator.finishOnOwnedRunner(); XCTFail("cleanup body 返回前必须 busy") }
            catch { XCTAssertEqual(error as? AACRenditionFailure, .busy) }
        }
        calibrator.cancel()
        try calibrator.finishOnOwnedRunner()
        observer.onDispose = nil
        XCTAssertEqual(reentered, 2)
        XCTAssertTrue(calibrator.lane.isCancellationFinished)
        XCTAssertEqual(calibrator.workspace.currentBytes, 0)
        XCTAssertTrue(receipt.encoders.allSatisfy { $0.passSignatures.isEmpty })
        XCTAssertNoThrow(try calibrator.finishOnOwnedRunner())
    }

    func testCancellationAtLoadTracksTerminalDoesNotStartReaderPhase() async throws {
        let observer = AACReviewFixture(); observer.cancelAtLoadTracks = true
        let calibrator = AACPrimingCalibrator(observer: observer)
        let plan = try AACCalibrationPlan.build([AACPrimingCalibratorTestHarness.request([.c])])
        do { _ = try await calibrator.calibrate(plan: plan); XCTFail("loadTracks 终止时的取消必须被观察") }
        catch { XCTAssertEqual(error as? AACRenditionFailure, .cancelled) }
        XCTAssertEqual(observer.readerEntries, 0)
        XCTAssertNil(calibrator.receipt)
        XCTAssertEqual(calibrator.workspace.currentBytes, 0)
    }

    func testEqualTypedDigestCannotSubstituteFreshPlanIdentity() async throws {
        let request = try AACPrimingCalibratorTestHarness.request([.c])
        let first = try AACCalibrationPlan.build([request]), other = try AACCalibrationPlan.build([request])
        XCTAssertEqual(first.entries, other.entries)
        XCTAssertEqual(first.digest, other.digest)
        XCTAssertNotEqual(first, other, "plan nonce 不属于稳定 typed digest")
        let calibrator = AACPrimingCalibrator()
        let receipt = try await calibrator.calibrate(plan: first)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        let replacement = AACEncoderIdentity(plan: other, ordinal: 0, request: request, nonce: encoder.identity.nonce)
        XCTAssertThrowsError(try receipt.encoder(for: replacement))
    }

    func testRealEightChannel16384GuardedProbeFitsDecodedAndCorrelationBudgets() async throws {
        let observer = AACReviewFixture()
        let calibrator = AACPrimingCalibrator(observer: observer)
        let plan = try AACCalibrationPlan.build([AACPrimingCalibratorTestHarness.request([.c,.l,.r,.ls,.rs,.rls,.rrs,.lfe])])
        let receipt = try await calibrator.calibrate(plan: plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        XCTAssertEqual(observer.probeFrames, [16_384,16_384])
        XCTAssertTrue(observer.guardsSilent)
        XCTAssertGreaterThanOrEqual(encoder.passSignatures[0].totalDecodedFrames, 16_384 + encoder.leadingSampleCount)
        XCTAssertLessThanOrEqual(calibrator.workspace.peakBytes, 4_194_304)
        XCTAssertEqual(calibrator.workspace.currentBytes, encoder.retainedEvidenceBytes)
    }

    func testActualFormatIsQueriedAtCreationAndDriftBeforePassCannotRedefineBaseline() async throws {
        let observer = AACReviewFixture(); observer.mutatePassFormat = true
        let calibrator = AACPrimingCalibrator(observer: observer)
        let plan = try AACCalibrationPlan.build([AACPrimingCalibratorTestHarness.request([.c])])
        do { _ = try await calibrator.calibrate(plan: plan); XCTFail("创建后格式漂移必须拒绝") }
        catch { XCTAssertEqual(error as? AACRenditionFailure, .calibrationMismatch) }
        XCTAssertEqual(observer.creationFormats, 1, observer.rawFormatEvidence)
        XCTAssertNil(calibrator.receipt)
        XCTAssertEqual(calibrator.workspace.currentBytes, 0)
    }

    func testActualStaticFieldsRejectDriftAtEveryFrozenBoundary() async throws {
        let stages: [AACActualFormatStage] = [.beforePass(1), .finalizedPass(1), .afterReset(1), .beforePass(2),
            .finalizedPass(2), .afterReset(2), .beforeLive, .finalDrain]
        for stage in stages {
            for field in AACReviewField.allCases {
                let observer = AACReviewFixture(); observer.mutationStage = stage; observer.mutationField = field
                let calibrator = AACPrimingCalibrator(observer: observer)
                let plan = try AACCalibrationPlan.build([AACPrimingCalibratorTestHarness.request([.c])])
                do {
                    let receipt = try await calibrator.calibrate(plan: plan)
                    _ = try receipt.encoders[0].encodeEpoch(AACPrimingCalibratorTestHarness.signal(frames: 128, channels: 1))
                    XCTFail("\(stage)/\(field) 漂移必须拒绝")
                } catch { XCTAssertEqual(error as? AACRenditionFailure, .calibrationMismatch, "\(stage)/\(field)") }
                XCTAssertEqual(observer.mutationsApplied, 1, "必须真正到达 \(stage)/\(field)")
                XCTAssertNil(calibrator.receipt)
                XCTAssertEqual(calibrator.workspace.currentBytes, 0)
            }
        }
    }
    private static let goldenCookie = Data([0x03,0x80,0x80,0x80,0x22,0,0,0,0x04,0x80,0x80,0x80,0x14,0x40,0x14,0,0x18,0,0,0,0,0,0,0x02,0x71,0,0x05,0x80,0x80,0x80,0x02,0x11,0x90,0x06,0x80,0x80,0x80,0x01,0x02])
    private func cookieEvidence(_ data: Data, workspace: AACCalibrationWorkspace) throws -> AACMagicCookieEvidence {
        try AACMagicCookieEvidence(backing: AACDataBacking(data: data, lease: workspace.acquire(.nonPayload, bytes: data.count)), configuredBitrate: 160_000, workspace: workspace)
    }
    func testESDSParserKeepsOriginalBackingAndOnlyAllowsBoundedMaxBitrate() throws {
        let workspace = AACCalibrationWorkspace()
        let baseline = try cookieEvidence(Self.goldenCookie, workspace: workspace)
        XCTAssertEqual(baseline.backing.data, Self.goldenCookie)
        XCTAssertEqual(baseline.maximumBitrateRange, 18..<22)
        XCTAssertEqual(baseline.maximumBitrate, 0)
        XCTAssertEqual(baseline.decoderSpecificInfo, Data([0x11,0x90]))
        for rate: UInt32 in [0,160_000,200_000] {
            var candidate = Self.goldenCookie
            candidate.replaceSubrange(18..<22, with: [UInt8(rate >> 24),UInt8(truncatingIfNeeded: rate >> 16),UInt8(truncatingIfNeeded: rate >> 8),UInt8(truncatingIfNeeded: rate)])
            let live = try cookieEvidence(candidate, workspace: workspace)
            XCTAssertEqual(live.maximumBitrate, rate)
            XCTAssertNoThrow(try baseline.validateLive(live))
            XCTAssertEqual(baseline.backing.data, Self.goldenCookie)
        }
        for rate: UInt32 in [200_001,UInt32.max] {
            var candidate = Self.goldenCookie
            candidate.replaceSubrange(18..<22, with: [UInt8(rate >> 24),UInt8(truncatingIfNeeded: rate >> 16),UInt8(truncatingIfNeeded: rate >> 8),UInt8(truncatingIfNeeded: rate)])
            XCTAssertThrowsError(try cookieEvidence(candidate, workspace: workspace))
        }
    }
    func testESDSParserRejectsEveryOtherFieldMalformedHierarchyAndTrailingBytes() throws {
        let workspace = AACCalibrationWorkspace()
        let baseline = try cookieEvidence(Self.goldenCookie, workspace: workspace)
        for index in [0,1,2,3,4,5,6,7,8,9,12,13,14,15,16,17,22,23,24,25,26,27,30,31,32,33,34,37,38] {
            var candidate = Self.goldenCookie; candidate[index] ^= 1
            XCTAssertThrowsError(try baseline.validateLive(cookieEvidence(candidate, workspace: workspace)), "字段 byte\(index) 不可漂移")
        }
        for count in 0..<Self.goldenCookie.count {
            XCTAssertThrowsError(try cookieEvidence(Self.goldenCookie.prefix(count), workspace: workspace))
        }
        var overflow = Self.goldenCookie; overflow.replaceSubrange(1..<5, with: [0xff,0xff,0xff,0xff])
        var duplicate = Self.goldenCookie; duplicate.append(contentsOf: Self.goldenCookie[33...]); duplicate[4] += 6
        for invalid in [overflow,duplicate,Self.goldenCookie + Data([0]),Data(repeating: 0, count: 524_289)] {
            XCTAssertThrowsError(try cookieEvidence(invalid, workspace: workspace))
        }
    }
    func testActualAUWindowEnforcesPayloadEnvelopeIndependentlyOfCookie() throws {
        let workspace = AACCalibrationWorkspace()
        let cookie = try cookieEvidence(Self.goldenCookie, workspace: workspace)
        XCTAssertNoThrow(try cookie.validateLive(cookie))
        let exact = try AACPayloadBandwidthWindow(configuredBitrate: 160_000, workspace: workspace)
        XCTAssertNoThrow(try exact.append(payloadBytes: 25_000))
        XCTAssertEqual(exact.evidence.payloadCeiling, 200_000)
        XCTAssertEqual(exact.evidence.fmp4BodyCeiling, 264_000)
        XCTAssertTrue(exact.evidence.requiresWriterBodyAccounting)
        XCTAssertThrowsError(try exact.append(payloadBytes: 1)) { XCTAssertEqual($0 as? AACRenditionFailure, .aacEncoderCookieInvariantViolation) }
        let oversized = try AACPayloadBandwidthWindow(configuredBitrate: 160_000, workspace: workspace)
        XCTAssertThrowsError(try oversized.append(payloadBytes: 25_001))
        XCTAssertThrowsError(try oversized.append(payloadBytes: Int.max))
        XCTAssertThrowsError(try oversized.append(payloadBytes: 0))
        XCTAssertThrowsError(try oversized.append(payloadBytes: 10, packetFrames: 960))
    }
    func testOneSecondAUWindowUses48kClockAndFixedCapacityThroughManyPackets() throws {
        let workspace = AACCalibrationWorkspace()
        let window = try AACPayloadBandwidthWindow(configuredBitrate: 160_000, workspace: workspace)
        for _ in 0..<10_000 { try window.append(payloadBytes: 500) }
        XCTAssertEqual(window.retainedCount, 47)
        XCTAssertEqual(window.evidence.accessUnitCount, 10_000)
        XCTAssertEqual(window.evidence.peakPayloadBits, 188_000)
        XCTAssertLessThanOrEqual(workspace.currentBytes, 1_024)
    }
    func testRequestsFreezeAllFieldsAndBitrateTiers() throws {
        let rows: [([RenditionChannelLabel], UInt32)] = [([.c],96_000),([.l,.r],160_000),([.c,.l,.r],320_000),([.c,.l,.r,.ls,.rs,.lfe],320_000),([.c,.l,.r,.ls,.rs,.cs,.lfe],512_000),([.c,.l,.r,.ls,.rs,.rls,.rrs,.lfe],512_000)]
        for (labels, bitrate) in rows {
            let request = try AACRenditionRequest(layout: RenditionAudioLayout(labels: labels), capabilityVersion: "os-device-v1")
            XCTAssertEqual(request.outputASBD.sampleRate, 48_000)
            XCTAssertEqual(request.outputASBD.formatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(request.outputASBD.formatFlags, 0)
            XCTAssertEqual(request.outputASBD.framesPerPacket, 1024)
            XCTAssertEqual(request.bitrate, bitrate)
            XCTAssertEqual(request.primeMethod, kConverterPrimeMethod_Normal)
        }
    }

    func testPlanStableDedupeThenOrdinalsAndTypedDigest() throws {
        let a = try AACPrimingCalibratorTestHarness.request([.c])
        let b = try AACPrimingCalibratorTestHarness.request([.l,.r])
        let c = try AACPrimingCalibratorTestHarness.request([.c,.l,.r])
        let plan = try AACCalibrationPlan.build([a,a,b,a])
        XCTAssertEqual(plan.entries.map(\.ordinal), [0,1])
        XCTAssertEqual(plan.entries.map(\.request), [a,b])
        XCTAssertEqual(plan.digest.count, 32)
        XCTAssertNotEqual(plan.digest, try AACCalibrationPlan.build([b,a]).digest)
        XCTAssertThrowsError(try AACCalibrationPlan.build([a,b,c]))
        XCTAssertEqual(try AACCalibrationPlan.build([]).entries.count, 0)
        XCTAssertThrowsError(try AACCalibrationPlan(entries: [.init(ordinal: 0, request: a),.init(ordinal: 1, request: a)]))
        XCTAssertThrowsError(try AACCalibrationPlan(entries: [.init(ordinal: 1, request: a)]))
        XCTAssertThrowsError(try AACCalibrationPlan(entries: [.init(ordinal: 0, request: a),.init(ordinal: 2, request: b)]))
        XCTAssertThrowsError(try AACCalibrationPlan(entries: [.init(ordinal: 0, request: a),.init(ordinal: 1, request: b),.init(ordinal: 2, request: c)]))
        let changed = try AACRenditionRequest(layout: RenditionAudioLayout(labels: [.c]), capabilityVersion: "os-device-v2", inputCookie: Data([1]))
        XCTAssertNotEqual(plan.digest, try AACCalibrationPlan.build([changed,b]).digest)
    }

    func testRealAudioConverterTwoPassCalibrationAndSameObjectLiveHandoff() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.l,.r])
        defer { attachEvidence(harness) }
        let receipt: AACCalibrationReceipt
        do { receipt = try await harness.calibrator.calibrate(plan: harness.plan) }
        catch {
            XCTFail("真实 cookie 阶段证据：\(harness.observer.evidence)，系统 AAC component：\(try AACPrimingCalibratorTestHarness.components())")
            throw error
        }
        let encoder = try XCTUnwrap(receipt.encoders.first)
        XCTAssertEqual(encoder.identity.plan, harness.plan)
        XCTAssertEqual(encoder.identity.ordinal, 0)
        XCTAssertEqual(encoder.passSignatures.count, 2)
        XCTAssertEqual(encoder.passSignatures[0], encoder.passSignatures[1])
        XCTAssertEqual(encoder.passSignatures[1].finalizedCookie, encoder.finalCookie)
        XCTAssertFalse(encoder.finalCookie.isEmpty)
        XCTAssertGreaterThan(encoder.leadingSampleCount, 0)
        let nonce = encoder.identity.nonce
        let epoch = try encoder.encodeEpoch(AACPrimingCalibratorTestHarness.signal(frames: 8_192, channels: 2))
        XCTAssertEqual(epoch.identity.nonce, nonce)
        XCTAssertEqual(epoch.realSampleCount, 8_192)
        XCTAssertEqual(epoch.totalDecodedFrames - epoch.leadingFrames - epoch.trailingFrames, 8_192)
        XCTAssertEqual(epoch.buffers.first.map(CMSampleBufferGetOutputPresentationTimeStamp), CMTime(value: 10, timescale: 1))
        for buffer in epoch.buffers {
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer))
            let actual = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
            XCTAssertEqual(AACASBD(actual.pointee), encoder.passSignatures[1].actualASBD)
            var size = 0
            let cookie = try XCTUnwrap(CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size))
            XCTAssertEqual(Data(bytes: cookie, count: size), encoder.finalCookie)
        }
        XCTAssertEqual(harness.calibrator.workspace.currentBytes, encoder.retainedEvidenceBytes + epoch.accountedBytes)
        XCTAssertGreaterThan(encoder.retainedEvidenceBytes, encoder.finalCookie.count)
        XCTAssertLessThanOrEqual(harness.calibrator.workspace.peakBytes, 4 * 1_024 * 1_024)
    }

    func testRealShortEpochSameBufferTrimsAndSystemTimelineCoverage() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.c])
        defer { attachEvidence(harness) }
        let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        let source = AACPrimingCalibratorTestHarness.signal(frames: 128, channels: 1)
        let epoch = try encoder.encodeEpoch(source)
        XCTAssertEqual(epoch.buffers.count, 1)
        XCTAssertGreaterThan(epoch.leadingFrames, 0)
        XCTAssertGreaterThan(epoch.trailingFrames, 0)
        XCTAssertLessThanOrEqual(epoch.leadingFrames + epoch.trailingFrames, epoch.totalDecodedFrames)
        XCTAssertEqual(epoch.actualLeadingPrimeFrames, 2_112)
        XCTAssertEqual(epoch.actualTrailingPrimeFrames, 832)
        assertEffectiveInputBuffers(epoch.buffers, realFrames: 128, leading: epoch.leadingFrames, trailing: epoch.trailingFrames)
        let decoded = try await AACSystemLoopback.decode(epoch: epoch, observer: harness.observer)
        XCTAssertEqual(decoded.rawFrameCount, epoch.totalDecodedFrames, "自然系统解码必须返回完整 Q，不能按 N 裁 PCM")
        XCTAssertEqual(decoded.rawSamples.count, epoch.totalDecodedFrames)
        XCTAssertTrue(decoded.didDrainNaturally)
        XCTAssertEqual(decoded.packetIdentity, try AACPrimingCalibratorTestHarness.packetIdentity(epoch.buffers))
        XCTAssertEqual(try XCTUnwrap(decoded.writerCookieEvidence).decoderSpecificInfo, Data([0x11,0x88]))
        XCTAssertEqual(try AACPrimingCalibrator.leadingOffset(source: source, decoded: decoded.rawSamples, channels: 1, maximumOffset: 8_192), epoch.leadingFrames)
        XCTAssertEqual(CMTimeSubtract(decoded.rawEndPTS, decoded.rawFirstPTS), CMTime(value: Int64(epoch.totalDecodedFrames), timescale: 48_000))
        attachLayeredEvidence(decoded.inputTiming, identity: decoded.packetIdentity, rawFirst: decoded.rawFirstPTS, rawEnd: decoded.rawEndPTS)
    }

    func testRealMiddleLoopbackCorrelationPreservesSampleZeroAndTailCoverage() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.l,.r])
        let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        let source = AACPrimingCalibratorTestHarness.signal(frames: 12_288, channels: 2)
        let epoch = try encoder.encodeEpoch(source)
        assertEffectiveInputBuffers(epoch.buffers, realFrames: 12_288, leading: epoch.leadingFrames, trailing: epoch.trailingFrames)
        let decoded = try await AACSystemLoopback.decode(epoch: epoch)
        XCTAssertEqual(decoded.rawFrameCount, epoch.totalDecodedFrames)
        XCTAssertEqual(decoded.rawSamples.count, epoch.totalDecodedFrames * 2)
        XCTAssertTrue(decoded.didDrainNaturally)
        XCTAssertEqual(decoded.packetIdentity, try AACPrimingCalibratorTestHarness.packetIdentity(epoch.buffers))
        XCTAssertEqual(try XCTUnwrap(decoded.writerCookieEvidence).decoderSpecificInfo, Data([0x11,0x90]))
        let leading = try AACPrimingCalibrator.leadingOffset(source: source, decoded: decoded.rawSamples, channels: 2, maximumOffset: 8_192)
        XCTAssertEqual(leading, epoch.leadingFrames)
        for start in [0,4_096,8_192] {
            let reference = Array(source[(start * 2)..<((start + 4_096) * 2)])
            let observed = Array(decoded.rawSamples[((leading + start) * 2)..<((leading + start + 4_096) * 2)])
            XCTAssertEqual(try AACPrimingCalibrator.leadingOffset(source: reference, decoded: observed, channels: 2, maximumOffset: 0), 0)
        }
        attachLayeredEvidence(decoded.inputTiming, identity: decoded.packetIdentity, rawFirst: decoded.rawFirstPTS, rawEnd: decoded.rawEndPTS)
    }

    private func assertEffectiveInputBuffers(_ buffers: [CMSampleBuffer], realFrames: Int64, leading: Int, trailing: Int,
                                             file: StaticString = #filePath, line: UInt = #line) {
        func trim(_ buffer: CMSampleBuffer, _ key: CFString) -> CMTime {
            guard let value = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) else { return .zero }
            return CMTimeMakeFromDictionary((value as! CFDictionary))
        }
        var rawFrames: Int64 = 0, effectiveFrames: Int64 = 0
        for (index, buffer) in buffers.enumerated() {
            let frames = Int64(CMSampleBufferGetNumSamples(buffer)) * 1_024
            let start = index == 0 ? Int64(leading) : 0, end = index == buffers.count - 1 ? Int64(trailing) : 0
            XCTAssertEqual(CMTimeCompare(trim(buffer, kCMSampleBufferAttachmentKey_TrimDurationAtStart), CMTime(value: start, timescale: 48_000)), 0, file: file, line: line)
            XCTAssertEqual(CMTimeCompare(trim(buffer, kCMSampleBufferAttachmentKey_TrimDurationAtEnd), CMTime(value: end, timescale: 48_000)), 0, file: file, line: line)
            XCTAssertLessThanOrEqual(start + end, frames, file: file, line: line)
            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffer), CMTime(value: 480_000 + rawFrames - Int64(leading), timescale: 48_000)), 0, file: file, line: line)
            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetOutputPresentationTimeStamp(buffer), CMTime(value: 480_000 + effectiveFrames, timescale: 48_000)), 0, file: file, line: line)
            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetOutputDuration(buffer), CMTime(value: frames - start - end, timescale: 48_000)), 0, file: file, line: line)
            rawFrames += frames; effectiveFrames += frames - start - end
        }
        XCTAssertEqual(effectiveFrames, realFrames, file: file, line: line)
        XCTAssertEqual(rawFrames, Int64(leading) + realFrames + Int64(trailing), file: file, line: line)
    }
    private func attachLayeredEvidence(_ timing: AACWriterInputTimingEvidence, identity: AACPacketSequenceEvidence,
                                       rawFirst: CMTime, rawEnd: CMTime) {
        let hash = identity.digest.map { String(format: "%02x", $0) }.joined()
        let attachment = XCTAttachment(string: "输入有效 N=\(timing.effectiveSampleCount), outputPTS=\(timing.effectiveStartPTS), outputEnd=\(timing.effectiveEndPTS), start/end trim=\(timing.leadingTrimFrames)/\(timing.trailingTrimFrames)；自然 raw Q=\(timing.rawDecodedFrames), rawPTS=\(rawFirst), rawEnd=\(rawEnd), AU=\(identity.accessUnitCount), packet-v2 SHA256=\(hash)。本证据不代表 AVPlayer 尾端已裁剪。")
        attachment.name = "输入有效域与原始解码域的独立证据"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private func attachEvidence(_ harness: AACPrimingCalibratorTestHarness) {
        let attachment = XCTAttachment(string: (harness.observer.evidence + harness.observer.formatEvidence).joined(separator: "\n"))
        attachment.name = "真实 R／B 与各阶段实际格式证据"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFinalCookieMayDifferFromProvisionalButPassOrLiveDriftFailsClosed() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.c], mutation: .provisionalCookie)
        let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        XCTAssertNotEqual(encoder.creationCookieDigest, encoder.resetCookieDigest)
        XCTAssertNoThrow(try encoder.encodeEpoch(AACPrimingCalibratorTestHarness.signal(frames: 128, channels: 1)))
    }

    func testFinalizedB1B2DriftRejectsBeforeReceipt() async throws {
        for mutation in [AACBoundaryMutation.firstPassCookie, .secondPassCookie, .firstPassEmpty, .secondPassEmpty] {
            let harness = try AACPrimingCalibratorTestHarness(labels: [.c], mutation: mutation)
            do { _ = try await harness.calibrator.calibrate(plan: harness.plan); XCTFail("B1/B2 漂移必须拒绝") }
            catch { XCTAssertEqual(error as? AACRenditionFailure, .aacEncoderCookieInvariantViolation) }
            XCTAssertNil(harness.calibrator.receipt)
            XCTAssertEqual(harness.calibrator.workspace.currentBytes, 0)
        }
    }

    func testResetR1R2DriftAndEmptyStateChangesRejectBeforeReceipt() async throws {
        for mutation in [AACBoundaryMutation.firstResetCookie, .secondResetCookie, .firstResetEmpty, .secondResetEmpty] {
            let harness = try AACPrimingCalibratorTestHarness(labels: [.c], mutation: mutation)
            do { _ = try await harness.calibrator.calibrate(plan: harness.plan); XCTFail("R1/R2 漂移或空态变化必须拒绝") }
            catch { XCTAssertEqual(error as? AACRenditionFailure, .aacEncoderCookieInvariantViolation) }
            XCTAssertNil(harness.calibrator.receipt)
            XCTAssertEqual(harness.calibrator.workspace.currentBytes, 0)
        }
    }

    func testMatchingEmptyResetStatesRequireMatchingEmptyBeforeLive() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.c], mutation: .bothResetsEmpty)
        let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        XCTAssertTrue(encoder.resetCookie.isEmpty)
        XCTAssertFalse(encoder.finalCookie.isEmpty)
        XCTAssertNoThrow(try encoder.encodeEpoch(AACPrimingCalibratorTestHarness.signal(frames: 128, channels: 1)))
    }

    func testBeforeLiveResetDriftAndEmptyStateRejectBeforeOutput() async throws {
        for mutation in [AACBoundaryMutation.beforeLiveCookie, .beforeLiveEmpty, .emptyResetsWithNonemptyBeforeLive] {
            let harness = try AACPrimingCalibratorTestHarness(labels: [.c], mutation: mutation)
            let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
            let encoder = try XCTUnwrap(receipt.encoders.first)
            XCTAssertThrowsError(try encoder.encodeEpoch(AACPrimingCalibratorTestHarness.signal(frames: 128, channels: 1))) {
                XCTAssertEqual($0 as? AACRenditionFailure, .aacEncoderCookieInvariantViolation)
            }
            XCTAssertNil(harness.calibrator.receipt)
            XCTAssertFalse(encoder.mayPublishTailOrEndList)
        }
    }

    func testLiveFinalB3DriftAndEmptyStatePublishOnePresentationTerminal() async throws {
        for mutation in [AACBoundaryMutation.finalDrainCookie, .finalDrainEmpty] {
            let harness = try AACPrimingCalibratorTestHarness(labels: [.c], mutation: mutation)
            let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
            let encoder = try XCTUnwrap(receipt.encoders.first)
            encoder.markVisible()
            XCTAssertThrowsError(try encoder.encodeEpoch(AACPrimingCalibratorTestHarness.signal(frames: 128, channels: 1))) {
                XCTAssertEqual($0 as? AACRenditionFailure, .aacEncoderCookieInvariantViolation)
            }
            XCTAssertEqual(encoder.terminalFailure, .aacEncoderCookieInvariantViolation)
            XCTAssertEqual(harness.calibrator.presentationTerminal.publicationCount, 1)
            XCTAssertFalse(encoder.mayPublishTailOrEndList)
            XCTAssertNil(harness.calibrator.receipt)
            XCTAssertThrowsError(try receipt.encoder(for: encoder.identity))
        }
    }

    func testTwoRenditionsShareTerminalAndRejectConcurrentCalibration() async throws {
        let observer = AACCookieBoundaryFixture(mutation: .finalDrainCookie)
        let calibrator = AACPrimingCalibrator(observer: observer)
        let plan = try AACCalibrationPlan.build([
            AACPrimingCalibratorTestHarness.request([.c]),
            AACPrimingCalibratorTestHarness.request([.l,.r]),
        ])
        let receipt = try await calibrator.calibrate(plan: plan)
        XCTAssertEqual(receipt.encoders.count, 2)
        let first = receipt.encoders[0], sibling = receipt.encoders[1]
        XCTAssertNotEqual(first.identity.nonce, sibling.identity.nonce)
        XCTAssertEqual(first.identity.ordinal, 0)
        XCTAssertEqual(sibling.identity.ordinal, 1)
        do { _ = try await calibrator.calibrate(plan: plan); XCTFail("一个 backend 不得开启第二 transaction") }
        catch { XCTAssertEqual(error as? AACRenditionFailure, .busy) }
        first.markVisible()
        XCTAssertThrowsError(try first.encodeEpoch(AACPrimingCalibratorTestHarness.signal(frames: 128, channels: 1)))
        XCTAssertFalse(sibling.mayPublishTailOrEndList)
        XCTAssertEqual(sibling.terminalFailure, .aacEncoderCookieInvariantViolation)
        try calibrator.finishOnOwnedRunner()
        XCTAssertEqual(calibrator.workspace.currentBytes, 0)
        XCTAssertEqual(calibrator.presentationTerminal.publicationCount, 1)
        XCTAssertNoThrow(try calibrator.finishOnOwnedRunner())
    }

    func testRetainedReceiptCancellationReleasesAllEntriesOnlyOnOriginalRunner() async throws {
        let calibrator = AACPrimingCalibrator()
        let plan = try AACCalibrationPlan.build([
            AACPrimingCalibratorTestHarness.request([.c]), AACPrimingCalibratorTestHarness.request([.l,.r]),
        ])
        let receipt = try await calibrator.calibrate(plan: plan)
        let before = calibrator.workspace.currentBytes
        XCTAssertGreaterThan(before, 0)
        try calibrator.lane.enter()
        calibrator.cancel()
        XCTAssertNil(calibrator.receipt)
        XCTAssertEqual(calibrator.workspace.currentBytes, before)
        XCTAssertThrowsError(try calibrator.finishOnOwnedRunner()) { XCTAssertEqual($0 as? AACRenditionFailure, .busy) }
        XCTAssertEqual(calibrator.workspace.currentBytes, before)
        calibrator.lane.leave()
        try calibrator.finishOnOwnedRunner()
        XCTAssertEqual(calibrator.workspace.currentBytes, 0)
        XCTAssertTrue(receipt.encoders.allSatisfy { $0.passSignatures.isEmpty })
        XCTAssertNoThrow(try calibrator.finishOnOwnedRunner())
        XCTAssertThrowsError(try receipt.encoder(for: receipt.encoders[0].identity))
    }

    func testStreamingLiveUsesBoundedTailAndIntegerClockBeyondCalibrationCap() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.l,.r])
        defer { attachEvidence(harness) }
        let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        var batches = 0
        let decoded = try await AACSystemLoopback.decodeStream(encoder: encoder, realFrames: 102_400, nextPCM: {
            guard batches < 100 else { return nil }
            let start = batches * 1_024
            batches += 1
            return AACPrimingCalibratorTestHarness.indexedSignal(start: start, frames: 1_024, channels: 2)
        })
        let summary = decoded.summary
        XCTAssertEqual(summary.realSampleCount, 102_400)
        XCTAssertEqual(decoded.rawFrameCount, summary.totalDecodedFrames, "raw Q 与 effective N 是两个独立域")
        XCTAssertTrue(decoded.didDrainNaturally)
        XCTAssertEqual(decoded.packetIdentity, decoded.inputPacketIdentity)
        XCTAssertEqual(try XCTUnwrap(decoded.packetIdentity).accessUnitCount, Int(summary.totalDecodedFrames / 1_024))
        let timing = try XCTUnwrap(decoded.inputTiming)
        XCTAssertEqual(timing.rawDecodedFrames, summary.totalDecodedFrames)
        XCTAssertEqual(timing.effectiveSampleCount, 102_400)
        XCTAssertEqual(timing.effectiveStartPTS, CMTime(value: 10, timescale: 1))
        XCTAssertEqual(timing.effectiveEndPTS, CMTime(value: 582_400, timescale: 48_000))
        XCTAssertEqual(timing.leadingTrimFrames, Int64(summary.leadingFrames))
        XCTAssertEqual(timing.trailingTrimFrames, summary.trailingFrames)
        XCTAssertGreaterThan(summary.bandwidth.accessUnitCount, 100)
        XCTAssertLessThanOrEqual(summary.bandwidth.peakPayloadBits, 200_000)
        XCTAssertEqual(summary.bandwidth.fmp4BodyCeiling, 264_000)
        XCTAssertTrue(summary.bandwidth.requiresWriterBodyAccounting)
        XCTAssertLessThanOrEqual(summary.maximumRetainedPackets, 64)
        XCTAssertEqual(CMTimeSubtract(decoded.rawEndPTS, decoded.rawFirstPTS), CMTime(value: summary.totalDecodedFrames, timescale: 48_000))
        XCTAssertEqual(decoded.rawWindowStartFrames, [Int64(summary.leadingFrames),Int64(summary.leadingFrames) + 51_200,Int64(summary.leadingFrames) + 98_304])
        for (start, window) in [(0,decoded.rawFirstContentWindow),(51_200,decoded.rawMiddleContentWindow)] {
            let source = AACPrimingCalibratorTestHarness.indexedSignal(start: start, frames: 4_096, channels: 2)
            XCTAssertEqual(try AACPrimingCalibrator.leadingOffset(source: source, decoded: window, channels: 2, maximumOffset: 8), 0)
        }
        let tailSource = AACPrimingCalibratorTestHarness.indexedSignal(start: 98_304, frames: 4_096, channels: 2)
        let tailEvidence = AACPrimingCalibratorTestHarness.tailContentEvidence(source: tailSource, decoded: decoded.rawLastContentWindow)
        XCTAssertEqual(tailEvidence.count, 16)
        let tailAttachment = XCTAttachment(string: tailEvidence.map {
            "块\($0.block)／声道\($0.channel)：NCC=\($0.correlation)，能量比=\($0.energyRatio)，固定阈值NCC≥0.70且能量比0.25...2.0，通过=\($0.matches)"
        }.joined(separator: "\n"))
        tailAttachment.name = "完整源尾4096的8×512双声道独立判据"
        tailAttachment.lifetime = .keepAlways; add(tailAttachment)
        XCTAssertTrue(AACPrimingCalibratorTestHarness.completeTailContentMatches(tailEvidence))
        // 逐块、逐声道破坏实际产物的副本；最后两块明确覆盖源末1024 frame。
        let wrongTail = AACPrimingCalibratorTestHarness.indexedSignal(start: 1_000_000, frames: 4_096, channels: 2)
        for block in 0..<8 {
            for channel in 0..<2 {
                for replacement in 0..<2 {
                    var damaged = decoded.rawLastContentWindow
                    for frame in (block * 512)..<((block + 1) * 512) {
                        damaged[frame * 2 + channel] = replacement == 0 ? 0 : wrongTail[frame * 2 + channel]
                    }
                    let damagedEvidence = AACPrimingCalibratorTestHarness.tailContentEvidence(source: tailSource, decoded: damaged)
                    XCTAssertFalse(AACPrimingCalibratorTestHarness.completeTailContentMatches(damagedEvidence),
                        "源尾4096中的第\(block)块／声道\(channel)／损坏\(replacement)不得漏检，覆盖frame \(block * 512)..<\((block + 1) * 512)")
                    XCTAssertEqual(damagedEvidence.count, 16)
                    for metric in damagedEvidence {
                        XCTAssertEqual(metric.matches, metric.block != block || metric.channel != channel,
                            "仅注入的512-frame声道块应失败，实际块\(metric.block)／声道\(metric.channel)：NCC=\(metric.correlation)，能量比=\(metric.energyRatio)")
                    }
                }
            }
        }
        XCTAssertEqual(decoded.writerDecoderSpecificInfo, Data([0x11,0x90]))
        let attachment = XCTAttachment(string: decoded.writerESDS.map { String(format: "%02x", $0) }.joined())
        attachment.name = "实际 writer esds 原字节"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertLessThanOrEqual(harness.calibrator.workspace.peakBytes, 4_194_304)
        XCTAssertEqual(harness.calibrator.workspace.currentBytes, encoder.retainedEvidenceBytes + decoded.decodedLease.bytes
            + decoded.writerCookieEvidence.metadataLease.bytes + decoded.writerCookieEvidence.backing.lease.bytes
            + decoded.metadataLease.bytes + decoded.rawReaderCookie.lease.bytes)
        attachLayeredEvidence(decoded.inputTiming, identity: decoded.packetIdentity, rawFirst: decoded.rawFirstPTS, rawEnd: decoded.rawEndPTS)
    }

    func testCancellationFromPCMProducerStopsBeforeNextFillAndReleasesBackings() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.c])
        let receipt = try await harness.calibrator.calibrate(plan: harness.plan)
        let encoder = try XCTUnwrap(receipt.encoders.first)
        var callbacks = 0, appended = 0
        XCTAssertThrowsError(try encoder.encodeStream(nextPCM: {
            callbacks += 1
            harness.calibrator.cancel()
            return AACPrimingCalibratorTestHarness.signal(frames: 1_024, channels: 1)
        }, append: { _ in appended += 1 })) {
            XCTAssertEqual($0 as? AACRenditionFailure, .cancelled)
        }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(appended, 0)
        XCTAssertNil(harness.calibrator.receipt)
        XCTAssertEqual(harness.calibrator.workspace.currentBytes, 0)
    }

    func testSingleLaneRejectsOverlapAndCancellationWaitsForCallTerminal() throws {
        let lane = AACOwnedCallLane()
        var terminal = 0
        try lane.call {
            XCTAssertThrowsError(try lane.call {})
            lane.requestCancel()
            XCTAssertTrue(lane.cancelRequested)
            XCTAssertEqual(terminal, 0)
        }
        lane.finishCancellation { terminal += 1 }
        lane.finishCancellation { terminal += 1 }
        XCTAssertEqual(terminal, 1)
        XCTAssertThrowsError(try lane.call {})
    }

    func testCancellationDuringCalibrationRevokesReceiptAndReleasesWorkspace() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.c], mutation: .cancelAfterFirstPass)
        do { _ = try await harness.calibrator.calibrate(plan: harness.plan); XCTFail("取消后不得移交") }
        catch { XCTAssertEqual(error as? AACRenditionFailure, .cancelled) }
        XCTAssertEqual(harness.calibrator.workspace.currentBytes, 0)
        XCTAssertNil(harness.calibrator.receipt)
    }

    func testWorkspaceEverySubledgerAliasSoftHardAndPreallocationCookieLimits() throws {
        let workspace = AACCalibrationWorkspace()
        let caps: [(AACCalibrationWorkspace.Kind, Int)] = [(.sourcePCM,524_288),(.aacPackets,524_288),(.temporaryFile,1_048_576),(.decodedPCM,1_048_576),(.correlation,524_288),(.nonPayload,524_288)]
        for (kind, cap) in caps {
            let lease = try workspace.acquire(kind, bytes: cap)
            XCTAssertThrowsError(try workspace.acquire(kind, bytes: 1))
            XCTAssertEqual(workspace.currentBytes, cap)
            lease.release(); lease.release()
            XCTAssertEqual(workspace.currentBytes, 0)
            XCTAssertThrowsError(try workspace.acquire(kind, bytes: cap + 1))
        }
        let a = try workspace.acquire(.temporaryFile, bytes: 1_048_576)
        let alias = a
        let b = try workspace.acquire(.decodedPCM, bytes: 1_048_576)
        let c = try workspace.acquire(.sourcePCM, bytes: 524_288)
        let d = try workspace.acquire(.aacPackets, bytes: 524_288)
        XCTAssertTrue(workspace.atSoftLimit)
        XCTAssertThrowsError(try workspace.acquire(.correlation, bytes: 1))
        let zero = try workspace.acquire(.nonPayload, bytes: 0)
        XCTAssertEqual(workspace.currentBytes, 3_145_728)
        d.release()
        let e = try workspace.acquire(.correlation, bytes: 524_288)
        XCTAssertThrowsError(try workspace.acquire(.nonPayload, bytes: 1))
        e.release()
        let crossing = try workspace.acquire(.nonPayload, bytes: 1)
        let f = try workspace.acquire(.correlation, bytes: 524_288)
        XCTAssertEqual(workspace.currentBytes, 3_145_729)
        XCTAssertThrowsError(try workspace.acquire(.aacPackets, bytes: 1))
        alias.release(); a.release(); b.release(); c.release(); zero.release(); crossing.release(); f.release()
        XCTAssertEqual(workspace.currentBytes, 0)
        XCTAssertThrowsError(try AACRenditionEncoder.validateCookieCapacity(524_289))
        XCTAssertNoThrow(try AACRenditionEncoder.validateCookieCapacity(524_288))
    }

    func testCallbackAccumulatorFixedCountAndBytesRejectsOverflow() throws {
        let accumulator = AACCallbackAccumulator()
        for _ in 0..<8 { try accumulator.append(Data(repeating: 0, count: 1_024)) }
        XCTAssertThrowsError(try accumulator.append(Data([1])))
        XCTAssertEqual(accumulator.count, 8)
        accumulator.releaseAll()
        XCTAssertEqual(accumulator.count, 0)
        XCTAssertThrowsError(try accumulator.append(Data(repeating: 0, count: 8_193)))
        let request = try AACPrimingCalibratorTestHarness.request([.c])
        let plan = try AACCalibrationPlan.build([request])
        let identity = AACEncoderIdentity(plan: plan, ordinal: 0, request: request, nonce: ConverterInstanceNonce())
        let writer = ObjectIdentifier(accumulator)
        XCTAssertThrowsError(try accumulator.append(.init(writerIdentity: writer, encoderIdentity: identity, initialization: false, payload: Data([1]))))
        try accumulator.append(.init(writerIdentity: writer, encoderIdentity: identity, initialization: true, payload: Data([1])))
        let wrongPlan = AACEncoderIdentity(plan: try AACCalibrationPlan.build([request]), ordinal: 0, request: request, nonce: identity.nonce)
        XCTAssertThrowsError(try accumulator.append(.init(writerIdentity: writer, encoderIdentity: wrongPlan, initialization: false, payload: Data([2]))))
        let otherWriter = AACCallbackAccumulator()
        XCTAssertThrowsError(try accumulator.append(.init(writerIdentity: ObjectIdentifier(otherWriter), encoderIdentity: identity, initialization: false, payload: Data([2]))))
        for _ in 1..<8 { try accumulator.append(.init(writerIdentity: writer, encoderIdentity: identity, initialization: false, payload: Data([2]))) }
        XCTAssertThrowsError(try accumulator.append(.init(writerIdentity: writer, encoderIdentity: identity, initialization: false, payload: Data([2]))))
        accumulator.releaseAll()
        try accumulator.append(.init(writerIdentity: writer, encoderIdentity: identity, initialization: true, payload: Data(repeating: 0, count: 524_288)))
        XCTAssertThrowsError(try accumulator.append(.init(writerIdentity: writer, encoderIdentity: identity, initialization: false, payload: Data([2]))))
        accumulator.releaseAll()
    }

    func testIdentityCannotSubstituteEqualFormatFromAnotherConverterOrPlan() async throws {
        let harness = try AACPrimingCalibratorTestHarness(labels: [.c])
        let first = try await harness.calibrator.calibrate(plan: harness.plan)
        let other = try AACPrimingCalibratorTestHarness(labels: [.c])
        let second = try await other.calibrator.calibrate(plan: other.plan)
        let a = try XCTUnwrap(first.encoders.first)
        let b = try XCTUnwrap(second.encoders.first)
        XCTAssertNotEqual(a.identity.nonce, b.identity.nonce)
        XCTAssertThrowsError(try first.encoder(for: b.identity))
        XCTAssertTrue(try first.encoder(for: a.identity) === a)
        harness.calibrator.cancel()
        XCTAssertThrowsError(try first.encoder(for: a.identity))
    }
}

private enum AACReviewField: CaseIterable { case asbd, layout, leading, duration }
private final class AACReviewFixture: AACCalibrationObserver, @unchecked Sendable {
    private let lock = NSLock()
    var onDispose: (() -> Void)?
    var cancelAtLoadTracks = false
    var mutatePassFormat = false
    var mutationStage: AACActualFormatStage?
    var mutationField = AACReviewField.asbd
    private(set) var mutationsApplied = 0
    private let injectedWorkspace = AACCalibrationWorkspace()
    private(set) var readerEntries = 0
    private(set) var creationFormats = 0
    private(set) var probeFrames: [Int] = []
    private(set) var guardsSilent = true
    private(set) var initializationEvents = 0
    private(set) var mediaEvents = 0
    private(set) var writerIdentities: [ObjectIdentifier] = []
    private(set) var maximumCallbackCount = 0
    private(set) var rawFormatEvidence = ""
    func cookie(_ value: Data, at stage: AACCookieStage) -> Data { value }
    func completedPass(_ pass: Int, lane: AACOwnedCallLane) {}
    func willDispose() { onDispose?() }
    func observedFormat(_ format: AACRenditionEncoder.ActualFormat) {
        rawFormatEvidence = "实际 ASBD=\(format.asbd), prime=\(format.leadingPrimeFrames)/\(format.trailingPrimeFrames), layout=\(format.layoutBacking.data as NSData)"
    }
    func observedProbe(_ samples: [Float], channels: Int) {
        probeFrames.append(samples.count / channels)
        guardsSilent = guardsSilent && samples.prefix(256 * channels).allSatisfy { $0 == 0 }
            && samples.suffix(256 * channels).allSatisfy { $0 == 0 }
    }
    func actualFormat(_ format: AACRenditionEncoder.ActualFormat, at stage: AACActualFormatStage) -> AACRenditionEncoder.ActualFormat {
        if case .creation = stage { creationFormats += 1 }
        guard (mutatePassFormat && stage == .beforePass(1)) || mutationStage == stage else { return format }
        mutationsApplied += 1
        var changed = format.asbd, leading = format.leadingPrimeFrames, layout = format.layoutBacking
        switch mutationField {
        case .asbd: changed.reserved = 1
        case .duration: changed.framesPerPacket = 960
        case .leading: leading += 1
        case .layout:
            var data = layout.data; data[0] ^= 1
            layout = AACDataBacking(data: data, lease: try! injectedWorkspace.acquire(.nonPayload, bytes: data.count))
        }
        return AACRenditionEncoder.ActualFormat(asbd: changed, layoutBacking: layout,
            leadingPrimeFrames: leading, trailingPrimeFrames: format.trailingPrimeFrames)
    }
    func loopbackPhase(_ phase: AACLoopbackPhase, lane: AACOwnedCallLane) {
        switch phase {
        case .loadedTracks: if cancelAtLoadTracks { lane.requestCancel() }
        case .createReader: readerEntries += 1
        }
    }
    func writerSegment(initialization: Bool, writerIdentity: ObjectIdentifier) {
        lock.withLock {
            if initialization { initializationEvents += 1; writerIdentities.append(writerIdentity) }
            else { mediaEvents += 1 }
            maximumCallbackCount = max(maximumCallbackCount, initializationEvents + mediaEvents)
        }
    }
}

private struct AACPrimingCalibratorTestHarness {
    struct TailBlockEvidence {
        let block: Int
        let channel: Int
        let correlation: Double
        let energyRatio: Double
        // 手工固定下限拒绝静音/弱内容，上限拒绝异常放大；不从本次正常解码自适应。
        var matches: Bool {
            correlation.isFinite && correlation >= 0.70 && energyRatio.isFinite && energyRatio >= 0.25 && energyRatio <= 2.0
        }
    }
    static func tailContentEvidence(source: [Float], decoded: [Float]) -> [TailBlockEvidence] {
        guard source.count == 8_192, decoded.count == 8_192,
              source.allSatisfy(\.isFinite), decoded.allSatisfy(\.isFinite) else { return [] }
        var evidence: [TailBlockEvidence] = []; evidence.reserveCapacity(16)
        // 测试内独立逐样本计算去均值NCC，不调用生产leadingOffset，也不搜索最佳偏移。
        for block in 0..<8 {
            for channel in 0..<2 {
                var sourceSum = 0.0, decodedSum = 0.0, sourceEnergy = 0.0, decodedEnergy = 0.0, product = 0.0
                for frame in (block * 512)..<((block + 1) * 512) {
                    let a = Double(source[frame * 2 + channel]), b = Double(decoded[frame * 2 + channel])
                    sourceSum += a; decodedSum += b
                    sourceEnergy += a * a; decodedEnergy += b * b; product += a * b
                }
                let sourceVariance = sourceEnergy - sourceSum * sourceSum / 512.0
                let decodedVariance = decodedEnergy - decodedSum * decodedSum / 512.0
                let covariance = product - sourceSum * decodedSum / 512.0
                let correlation = sourceVariance > 0 && decodedVariance > 0
                    ? covariance / (sourceVariance * decodedVariance).squareRoot() : Double.nan
                let energyRatio = sourceEnergy > 0 ? decodedEnergy / sourceEnergy : Double.nan
                evidence.append(TailBlockEvidence(block: block, channel: channel, correlation: correlation, energyRatio: energyRatio))
            }
        }
        return evidence
    }
    static func completeTailContentMatches(_ evidence: [TailBlockEvidence]) -> Bool {
        evidence.count == 16 && evidence.allSatisfy(\.matches)
    }
    static func packetIdentity(_ buffers: [CMSampleBuffer]) throws -> AACPacketSequenceEvidence {
        var digest = SHA256(); digest.update(data: Data("VPlayer.AACPacketSequence.v2".utf8))
        var packets = 0
        for buffer in buffers {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
            var descriptions: UnsafePointer<AudioStreamPacketDescription>?, bytes = 0
            try AACRenditionEncoder.check(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &descriptions,
                sizeOut: &bytes))
            let values = try XCTUnwrap(descriptions)
            XCTAssertEqual(bytes, CMSampleBufferGetNumSamples(buffer) * MemoryLayout<AudioStreamPacketDescription>.stride)
            for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                let packet = values[index]
                let size = Int(packet.mDataByteSize)
                var data = Data(count: size)
                try data.withUnsafeMutableBytes { target in
                    try AACRenditionEncoder.check(CMBlockBufferCopyDataBytes(block, atOffset: Int(packet.mStartOffset),
                        dataLength: size, destination: target.baseAddress!))
                }
                for value: UInt32 in [1_024,packet.mVariableFramesInPacket,packet.mDataByteSize] {
                    withUnsafeBytes(of: value.bigEndian) { digest.update(data: Data($0)) }
                }
                digest.update(data: data); packets += 1
            }
        }
        return .init(accessUnitCount: packets, digest: Data(digest.finalize()))
    }
    static func indexedSignal(start: Int, frames: Int, channels: Int) -> [Float] {
        var samples: [Float] = []; samples.reserveCapacity(frames * channels)
        for frame in start..<(start + frames) {
            var value = UInt32(frame) &+ 0x71a2b3c4
            value = (value ^ (value >> 16)) &* 0x7feb352d
            value = (value ^ (value >> 15)) &* 0x846ca68b
            value ^= value >> 16
            let sample = Float(Int32(bitPattern: value) >> 17) / 32_768
            for _ in 0..<channels { samples.append(sample) }
        }
        return samples
    }
    let plan: AACCalibrationPlan
    let calibrator: AACPrimingCalibrator
    let observer: AACCookieBoundaryFixture
    init(labels: [RenditionChannelLabel], mutation: AACBoundaryMutation = .none) throws {
        plan = try AACCalibrationPlan.build([Self.request(labels)])
        observer = AACCookieBoundaryFixture(mutation: mutation)
        calibrator = AACPrimingCalibrator(observer: observer)
    }
    static func request(_ labels: [RenditionChannelLabel]) throws -> AACRenditionRequest {
        try AACRenditionRequest(layout: RenditionAudioLayout(labels: labels), capabilityVersion: "simulator-fixture-v1")
    }
    static func signal(frames: Int, channels: Int) -> [Float] {
        var result = [Float](); result.reserveCapacity(frames * channels)
        var state: UInt32 = 0x12345678
        for _ in 0..<frames {
            state = state &* 1_664_525 &+ 1_013_904_223
            let value = Float(Int32(bitPattern: state) >> 17) / 32_768
            for _ in 0..<channels { result.append(value) }
        }
        return result
    }
    static func components() throws -> [String] {
        var format = kAudioFormatMPEG4AAC
        var size: UInt32 = 0
        try AACRenditionEncoder.check(AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, 4, &format, &size))
        guard size <= 8_192 else { throw AACRenditionFailure.capacityExceeded }
        var descriptions = [AudioClassDescription](repeating: AudioClassDescription(), count: Int(size) / MemoryLayout<AudioClassDescription>.stride)
        try AACRenditionEncoder.check(AudioFormatGetProperty(kAudioFormatProperty_Encoders, 4, &format, &size, &descriptions))
        return descriptions.map { "type=\($0.mType), subtype=\($0.mSubType), manufacturer=\($0.mManufacturer)" }
    }
}


private enum AACBoundaryMutation: Sendable { case none, provisionalCookie, firstPassCookie, secondPassCookie, firstPassEmpty, secondPassEmpty, firstResetCookie, secondResetCookie, firstResetEmpty, secondResetEmpty, bothResetsEmpty, emptyResetsWithNonemptyBeforeLive, beforeLiveCookie, beforeLiveEmpty, finalDrainCookie, finalDrainEmpty, cancelAfterFirstPass }

private final class AACCookieBoundaryFixture: AACCalibrationObserver, @unchecked Sendable {
    let mutation: AACBoundaryMutation
    private let lock = NSLock()
    private var records: [String] = []
    private var formats: [String] = []
    var evidence: [String] { lock.withLock { records } }
    var formatEvidence: [String] { lock.withLock { formats } }
    init(mutation: AACBoundaryMutation) { self.mutation = mutation }
    func cookie(_ value: Data, at stage: AACCookieStage) -> Data {
        lock.withLock {
            if records.count < 8 { records.append("\(stage):\(value.map { String(format: "%02x", $0) }.joined())") }
        }
        switch (stage, mutation) {
        case (.provisional, .provisionalCookie): return Data([0xaa])
        case (.finalizedPass(1), .firstPassCookie), (.finalizedPass(2), .secondPassCookie),
             (.afterReset(1), .firstResetCookie), (.afterReset(2), .secondResetCookie),
             (.beforeLive, .beforeLiveCookie):
            var changed = value
            if changed.count > 21 { changed[21] ^= 1 } else { changed.append(0xcc) }
            return changed
        case (.finalDrain, .finalDrainCookie):
            var changed = value
            if changed.count > 31 { changed[31] ^= 1 } else { changed.append(0xcc) }
            return changed
        case (.finalizedPass(1), .firstPassEmpty), (.finalizedPass(2), .secondPassEmpty),
             (.afterReset(1), .firstResetEmpty), (.afterReset(2), .secondResetEmpty),
             (.afterReset, .bothResetsEmpty), (.beforeLive, .bothResetsEmpty),
             (.afterReset, .emptyResetsWithNonemptyBeforeLive),
             (.beforeLive, .beforeLiveEmpty), (.finalDrain, .finalDrainEmpty):
            return Data()
        default: return value
        }
    }
    func completedPass(_ pass: Int, lane: AACOwnedCallLane) {
        if pass == 1, mutation == .cancelAfterFirstPass { lane.requestCancel() }
    }
    func observedFormat(_ format: AACRenditionEncoder.ActualFormat) {
        lock.withLock {
            if formats.count < 8 {
                formats.append("actual[\(formats.count)]: ASBD=\(format.asbd), leading=\(format.leadingPrimeFrames), trailing=\(format.trailingPrimeFrames), layout=\(format.layoutBacking.data.map { String(format: "%02x", $0) }.joined())")
            }
        }
    }
}
