// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerCore
@testable import VPlayerPlayback

#if !HLS_ACCEPTANCE_BASELINE
/// Short controls run on the candidate before either capped observation. These
/// exercise native components, not a second playback or resource-stability run.
final class AcceptanceNativeControlTests: XCTestCase {
    private func checkAccessLogCompletionStates() throws {
        let completed = AcceptanceAccessLogCapture(deadline: 2)
        completed.complete(droppedFrames: 3, stalls: 1, at: 1)
        let observed = try completed.finish()
        XCTAssertEqual(observed.status, .available)
        XCTAssertEqual(observed.droppedFrames, 3)
        XCTAssertEqual(observed.stalls, 1)
        completed.complete(droppedFrames: 99, stalls: 99, at: 1.5)
        XCTAssertEqual(try completed.finish(), observed, "Only the first completion is observable")

        let unavailable = AcceptanceAccessLogCapture(deadline: 2)
        unavailable.complete(droppedFrames: nil, stalls: nil, at: 1)
        let absent = try unavailable.finish()
        XCTAssertEqual(absent.status, .unavailable)
        XCTAssertNil(absent.droppedFrames)
        XCTAssertNil(absent.stalls)

        let timeout = AcceptanceAccessLogCapture(deadline: 2)
        XCTAssertThrowsError(try timeout.finish())
        timeout.complete(droppedFrames: 0, stalls: 0, at: 3)
        XCTAssertThrowsError(try timeout.finish(), "Late delivery cannot convert timeout into success")
        let late = AcceptanceAccessLogCapture(deadline: 2)
        late.complete(droppedFrames: 0, stalls: 0, at: 2)
        XCTAssertThrowsError(try late.finish(), "A callback must finish before its deadline")
    }

    func testNativeObservationControlsRejectFiveFaults() throws {
        try checkAccessLogCompletionStates()
        var positive: [String: Any] = [:]
        var negative: [String: Any] = [:]

        // Real CMSampleBuffer PCM enters the exact long-run meter and serializer.
        var pcm = [Float](repeating: 0.1, count: 48_000 * 2)
        let clean = try meter(pcm)
        positive["mute"] = AcceptanceReport.audio(clean)
        for index in (12_768 * 2)..<((12_768 + 1_008) * 2) { pcm[index] = 0 }
        let muted = try meter(pcm)
        XCTAssertEqual(clean.silentShortWindows, 0)
        XCTAssertGreaterThanOrEqual(muted.silentShortWindows, 3)
        negative["mute"] = AcceptanceReport.audio(muted)

        // Actual MP4 bytes go through the exact capture parser and continuity state.
        var continuous = AcceptanceFragmentContinuity()
        var wrapped = AcceptanceFragmentContinuity()
        for (index, sequence) in [UInt32(1), 2, 3].enumerated() {
            try continuous.observe(fragment(sequence: sequence, time: UInt32(index * 1_024)), defaultDuration: 1_024)
        }
        for (index, sequence) in [UInt32.max - 1, UInt32.max, 1].enumerated() {
            try wrapped.observe(fragment(sequence: sequence, time: UInt32(index * 1_024)), defaultDuration: 1_024)
        }
        XCTAssertTrue(continuous.rawSequenceContinuous)
        XCTAssertFalse(wrapped.rawSequenceContinuous)
        positive["wrap"] = AcceptanceReport.fragment(continuous)
        negative["wrap"] = AcceptanceReport.fragment(wrapped)

        // Retain a real CoreMedia alias after the original backing owner is gone.
        let probe = HLSWriterAcceptanceProbe()
        let observation = try XCTUnwrap(probe.register(binding: binding(41), hardInputCount: 1,
            hardInputBytes: 16, hardEvidenceCount: 1, hardCallbackCount: 1))
        let ledger = HLSDeliveryApplicationChargeLedger()
        let inputs = WriterInputAdmission(capacity: 1, maximumBytes: 16,
            applicationLedger: ledger, observation: observation)
        var original: CMBlockBuffer? = try SampleBufferBuilder.makeHLSPrepaidBlockBuffer(
            copying: Data([1, 2, 3, 4]), lifetime: inputs.admit(bytes: 4))
        var retained: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithBufferReference(allocator: kCFAllocatorDefault,
            referenceBuffer: try XCTUnwrap(original), offsetToData: 0, dataLength: 4,
            flags: 0, blockBufferOut: &retained), noErr)
        original = nil
        try withExtendedLifetime(XCTUnwrap(retained)) {
            XCTAssertEqual(probe.snapshot.liveInputCount, 1)
            XCTAssertGreaterThan(ledger.chargedBytes, 0)
            negative["retained_input"] = AcceptanceReport.retirement(probe.snapshot)
        }
        retained = nil
        XCTAssertEqual(probe.snapshot.liveInputCount, 0)
        XCTAssertEqual(ledger.chargedBytes, 0)
        positive["retained_input"] = AcceptanceReport.retirement(probe.snapshot)

        // The real SegmentedFMP4Writer reserves its initialization callback. Only
        // its inspection adapter withholds delivery; no probe count is fabricated.
        let callbackProbe = HLSWriterAcceptanceProbe()
        let writerBinding = binding(42)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let relay = SegmentReportRelay(binding: writerBinding, limits: .audio,
            capacity: 4, objectSink: { _ in })
        let writer = try SegmentedFMP4Writer(binding: writerBinding, trackKind: .aac,
            sourceFormatHint: aacFormat(), boundarySession: boundary.session,
            compressedFormatConfiguration: nil, relay: relay,
            systemFactory: WithheldInitializationFactory(), acceptanceProbe: callbackProbe)
        defer { _ = writer.cancel() }
        try writer.start(at: .zero)
        XCTAssertEqual(writer.usage.pendingCallbackCount, 1)
        XCTAssertEqual(callbackProbe.snapshot.pendingCallbacks, 1)
        negative["lost_callback"] = AcceptanceReport.retirement(callbackProbe.snapshot)
        _ = writer.cancel()
        XCTAssertEqual(callbackProbe.snapshot.pendingCallbacks, 0)
        positive["lost_callback"] = AcceptanceReport.retirement(callbackProbe.snapshot)

        // Controlled footprint observations use the same collector and serialization.
        let flat = AcceptanceSampleCollector()
        let growing = AcceptanceSampleCollector()
        for index in 0..<60 {
            flat.append(AcceptanceReport.sample(wall: Double(index * 5), footprint: 100 * 1_024 * 1_024,
                packets: index * 100, eof: false, packetAge: 0))
            growing.append(AcceptanceReport.sample(wall: Double(index * 5),
                footprint: UInt64(100 + index) * 1_024 * 1_024, packets: index * 100, eof: false, packetAge: 0))
        }
        positive["footprint_growth"] = ["samples":try flat.snapshot()]
        negative["footprint_growth"] = ["samples":try growing.snapshot()]
        let result: [String: Any] = ["schema":1,"kind":"native_component_fault_controls",
            "positive":positive,"negative":negative]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        // The runner must pass this actual observation into the production report
        // validator's shared predicates before it may start the capped runs.
        print("HLS_ACCEPTANCE_CONTROLS=" + String(decoding: bytes, as: UTF8.self))
    }

    private func meter(_ pcm: [Float]) throws -> AcceptancePCMStatistics {
        let bytes = pcm.withUnsafeBytes { Data($0) }
        let sample = try PCMSampleBufferBuilder.make(bytes: bytes, frameCount: 48_000,
            sampleRate: 48_000, channels: 2, channelOrder: .native, channelLayoutMask: 3,
            presentationTimeStamp: .zero)
        var result = AcceptancePCMStatistics()
        try result.consume(sample)
        return result
    }
    private func binding(_ value: UInt64) -> FMP4WriterBinding {
        let session = PlaybackSessionIdentity(sessionID: value,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        return FMP4WriterBinding(outputLifecycleEpoch: .init(backendIdentity:
            .init(sessionIdentity: session, backendGeneration: value), outputNonce: value),
            itemGeneration: .init(rawValue: value), mediaEpoch: .init(rawValue: value),
            publicationParticipantID: .init(rawValue: value), renditionIdentity: .init(rawValue: value),
            writerIdentity: .init(rawValue: value))
    }
    private func aacFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1_024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let cookie = Data([0x11, 0x90])
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: $0.baseAddress,
                extensions: nil, formatDescriptionOut: &format)
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }
    private func fragment(sequence: UInt32, time: UInt32) -> Data {
        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func box(_ name: String, _ payload: Data) -> Data {
            word(UInt32(payload.count + 8)) + Data(name.utf8) + payload
        }
        let header = box("mfhd", word(0) + word(sequence))
        let track = box("tfhd", word(0) + word(1)) + box("tfdt", word(0) + word(time)) +
            box("trun", word(0) + word(1))
        return box("moof", header + box("traf", track)) + box("mdat", Data([1, 2, 3, 4]))
    }
}

private struct WithheldInitializationFactory: SegmentedFMP4SystemWriterFactory {
    func makeWriter(configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription, callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws -> any SegmentedFMP4SystemWriting { WithheldInitializationWriter() }
}

/// Inspection adapter only: successful start deliberately never sends the reserved
/// initialization callback, making the real writer/probe pending state observable.
private final class WithheldInitializationWriter: SegmentedFMP4SystemWriting, @unchecked Sendable {
    var objectIdentity: ObjectIdentifier { ObjectIdentifier(self) }
    func startWriting(at sourceTime: CMTime) -> Bool { true }
    func appendAwaitingReadiness(_ sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) async throws {
        throw AcceptanceError.invalid("callback control must not submit media")
    }
    func flushSegment() -> Bool { false }
    func markInputAsFinished() { }
    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
    func cancelWriting() { }
}
#endif
