// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Dispatch
import Foundation
import XCTest
@testable import VPlayerPlayback

final class FFmpegDemuxerTests: XCTestCase {
    func testUnknownExplicitRoleIsCopiedAsUnclassifiableRatherThanAbsent() throws {
        for scenario in [VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_TOKEN,
                         VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_COMMENT,
                         VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_ROLE_DUB] {
            let bridge = Task11ProductionExtrasDemuxBridge(scenario: scenario)
            let demuxer = FFmpegDemuxer(bridge: bridge)
            let received = expectation(description: "tracks \(scenario.rawValue)")
            let tracks = Task22LockedValue<DemuxTrackSet?>(nil)
            try demuxer.start(url: URL(string: "https://example.invalid/source.ts")!) { event in
                if case let .tracks(value) = event {
                    tracks.set(value)
                    received.fulfill()
                }
            }
            wait(for: [received], timeout: 1)
            XCTAssertEqual(tracks.value?.audio?.metadata.roleEvidence, .unclassifiable)
            XCTAssertNil(tracks.value?.audio?.metadata.role)
        }
    }

    func testPrimaryReceiptIsRebuiltOrRejectedByProductionRefresh() {
        var competing = VPFFPrimaryRefreshDebugResult()
        XCTAssertEqual(vp_ffmpeg_demuxer_debug_refresh_audio_primary(
            VPFF_PRIMARY_REFRESH_DEBUG_COMPETING_AUDIO, &competing), 0)
        XCTAssertEqual(competing.initial_audio_count, 1)
        XCTAssertEqual(competing.refreshed_audio_count, 2)
        XCTAssertEqual(competing.refreshed_basis, VPFF_AUDIO_PRIMARY_NONE)
        XCTAssertEqual(competing.discontinuity_count, 1)

        var defaults = VPFFPrimaryRefreshDebugResult()
        XCTAssertEqual(vp_ffmpeg_demuxer_debug_refresh_audio_primary(
            VPFF_PRIMARY_REFRESH_DEBUG_DEFAULT_DRIFT, &defaults), 0)
        XCTAssertEqual(defaults.initial_basis, VPFF_AUDIO_PRIMARY_UNIQUE_DEFAULT)
        XCTAssertEqual(defaults.refreshed_basis, VPFF_AUDIO_PRIMARY_NONE)
        XCTAssertEqual(defaults.discontinuity_count, 1)

        var role = VPFFPrimaryRefreshDebugResult()
        XCTAssertEqual(vp_ffmpeg_demuxer_debug_refresh_audio_primary(
            VPFF_PRIMARY_REFRESH_DEBUG_ROLE_DRIFT, &role), 0)
        XCTAssertEqual(role.initial_basis, VPFF_AUDIO_PRIMARY_UNIQUE_DEFAULT)
        XCTAssertEqual(role.refreshed_basis, VPFF_AUDIO_PRIMARY_NONE)
        XCTAssertEqual(role.discontinuity_count, 1)

        var removed = VPFFPrimaryRefreshDebugResult()
        XCTAssertLessThan(vp_ffmpeg_demuxer_debug_refresh_audio_primary(
            VPFF_PRIMARY_REFRESH_DEBUG_SELECTED_REMOVED, &removed), 0)
    }
    func testAdmittedDemuxWaitsBeforeSecondBorrowedCopyUntilLastAliasReleases() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: 8,
            applicationLedger: ledger
        )
        let admissionProbe = DemuxAdmissionGateProbe(admission)
        let firstCallbackReturned = DispatchSemaphore(value: 0)
        let secondCallbackReturned = DispatchSemaphore(value: 0)
        let callbackReturnCount = DemuxTestCounter()
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1, 2])))
            callbackReturnCount.increment()
            firstCallbackReturned.signal()
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([3, 4])))
            callbackReturnCount.increment()
            secondCallbackReturned.signal()
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let retained = AdmittedDemuxEventRecorder()
        let firstOwnerReceived = DispatchSemaphore(value: 0)
        let terminal = expectation(description: "admitted demux terminal")
        let subject = FFmpegDemuxer(bridge: bridge, capacity: 4)

        try subject.start(url: try httpURL(), admission: admissionProbe) { envelope in
            if envelope.isTerminal { terminal.fulfill() }
            else {
                retained.append(envelope)
                firstOwnerReceived.signal()
            }
        }

        XCTAssertEqual(firstCallbackReturned.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(admissionProbe.waitUntilAttemptCount(2),
                      "producer must reach the real second admission gate")
        XCTAssertEqual(firstOwnerReceived.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(callbackReturnCount.value, 1,
                       "second borrowed callback cannot return through the occupied gate")
        retained.assertPacketData([Data([1, 2])])
        XCTAssertEqual(admission.usage, .init(count: 1, bytes: 2, cancelled: false))
        XCTAssertGreaterThan(ledger.chargedBytes, 2)

        retained.assertFirstPacketBorrowSupportsSmallDataSliceAndCOW()
        XCTAssertEqual(callbackReturnCount.value, 1)
        XCTAssertEqual(admission.usage.count, 1, "retained owner is the final alias")
        retained.removeFirstOwner()
        XCTAssertEqual(secondCallbackReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(callbackReturnCount.value, 2)
        wait(for: [terminal], timeout: 2)
        retained.assertPacketData([Data([3, 4])])
        XCTAssertEqual(admission.usage.count, 1)
        retained.removeAll()
        XCTAssertEqual(admission.usage, .init(count: 0, bytes: 0, cancelled: false))
        XCTAssertEqual(ledger.chargedBytes, 0)
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testAdmittedDemuxCancelWakesDemandWaitAndReentrantSinkDeliversOneTerminal() throws {
        let admission = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: 8,
            applicationLedger: HLSDeliveryApplicationChargeLedger()
        )
        let secondCallbackEntered = DispatchSemaphore(value: 0)
        let producerReturned = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1])))
            secondCallbackEntered.signal()
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([2])))
            producerReturned.signal()
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        let retained = AdmittedDemuxEventRecorder()
        let events = LockedEventList()
        let terminal = expectation(description: "single cancellation terminal")
        let subject = FFmpegDemuxer(bridge: bridge)
        let cancelBox = DemuxerCancelBox(subject)
        try subject.start(url: try httpURL(), admission: admission) { envelope in
            if envelope.isTerminal {
                envelope.withBorrowedEvent(events.append)
                terminal.fulfill()
            } else {
                retained.append(envelope)
                cancelBox.cancel()
            }
        }

        XCTAssertEqual(secondCallbackEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(producerReturned.wait(timeout: .now() + 2), .success)
        wait(for: [terminal], timeout: 2)
        XCTAssertEqual(events.snapshot.filter(\.isTerminal), [.cancelled])
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
        XCTAssertEqual(admission.usage.count, 1, "external alias owns the final charge")
        retained.removeAll()
        XCTAssertEqual(admission.usage.count, 0)
    }

    func testAdmittedDemuxRejectsOversizedBorrowedSpanBeforeApplicationReservation() throws {
        let scripts: [FakeFFmpegDemuxBridge.RunScript] = [
            { handle in handle.emitOversizedPacketSize(); return 0 },
            { handle in handle.emitOversizedTrackExtradata(); return 0 },
        ]
        for script in scripts {
            let ledger = HLSDeliveryApplicationChargeLedger()
            let admission = HLSDataPlaneAdmission(
                capacity: 1,
                maximumBytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes,
                applicationLedger: ledger
            )
            let bridge = FakeFFmpegDemuxBridge(runScript: script)
            let terminal = expectation(description: "oversized terminal")
            let capture = AdmittedDemuxPayloadCapture()
            let subject = FFmpegDemuxer(bridge: bridge)

            try subject.start(url: try httpURL(), admission: admission) { envelope in
                envelope.withBorrowedEvent(capture.record)
                if envelope.isTerminal { terminal.fulfill() }
            }

            wait(for: [terminal], timeout: 2)
            XCTAssertEqual(
                capture.event,
                .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode))
            )
            XCTAssertEqual(admission.usage, .init(count: 0, bytes: 0, cancelled: false))
            XCTAssertEqual(
                ledger.maximumChargedBytes,
                0,
                "invalid raw length must fail before reserve/copy"
            )
        }
    }

    func testAdmittedDemuxPermanentlyRejectsLegalPacketAboveAdmissionLimitBeforeCopy() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: 1,
            applicationLedger: ledger
        )
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1, 2])))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let events = LockedEventList()
        let unexpectedNonterminalCount = DemuxTestCounter()
        let terminal = expectation(description: "permanent admission failure")
        let subject = FFmpegDemuxer(bridge: bridge)

        try subject.start(url: try httpURL(), admission: admission) { envelope in
            if envelope.isTerminal {
                envelope.withBorrowedEvent(events.append)
                terminal.fulfill()
            } else {
                unexpectedNonterminalCount.increment()
            }
        }

        wait(for: [terminal], timeout: 2)
        XCTAssertEqual(
            events.snapshot,
            [.failure(.demuxRead(FFmpegDemuxer.oversizedValueErrorCode))],
            "permanent admission rejection must win over the later native EOS"
        )
        XCTAssertEqual(bridge.handle?.cancelCount, 1)
        XCTAssertEqual(unexpectedNonterminalCount.value, 0,
                       "failure-path test must not retain a naked media payload")
        XCTAssertEqual(admission.usage, .init(count: 0, bytes: 0, cancelled: false))
        XCTAssertEqual(ledger.maximumChargedBytes, 0,
                       "permanent rejection must precede copy and reservation")
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testExternallyCancelledAdmissionConvergesDemuxToSingleCancelledTerminal() throws {
        let admission = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: 8,
            applicationLedger: HLSDeliveryApplicationChargeLedger()
        )
        admission.cancel()
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1, 2])))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let events = LockedEventList()
        let unexpectedNonterminalCount = DemuxTestCounter()
        let terminal = expectation(description: "external admission cancellation")
        let subject = FFmpegDemuxer(bridge: bridge)

        try subject.start(url: try httpURL(), admission: admission) { envelope in
            if envelope.isTerminal {
                envelope.withBorrowedEvent(events.append)
                terminal.fulfill()
            } else {
                unexpectedNonterminalCount.increment()
            }
        }

        wait(for: [terminal], timeout: 2)
        XCTAssertEqual(events.snapshot, [.cancelled])
        XCTAssertEqual(unexpectedNonterminalCount.value, 0)
        XCTAssertEqual(bridge.handle?.cancelCount, 1)
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testAdmittedTrackExtradataStayInBorrowScopeUntilOwnerReleases() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: 32,
            applicationLedger: ledger
        )
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(
                video: .h264(extradata: Data([1, 2, 3])),
                audio: .aac(extradata: Data([4, 5]))
            )
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let terminal = expectation(description: "track terminal")
        let retained = AdmittedDemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge)

        try subject.start(url: try httpURL(), admission: admission) { envelope in
            if envelope.isTerminal { terminal.fulfill() }
            else { retained.append(envelope) }
        }

        wait(for: [terminal], timeout: 2)
        retained.assertFirstTrackExtradata(video: Data([1, 2, 3]), audio: Data([4, 5]))
        XCTAssertEqual(admission.usage.count, 1)
        retained.removeAll()
        XCTAssertEqual(admission.usage.count, 0)
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    func testAdmittedEmptyPacketRemainsBorrowedUntilOwnerReleaseAndChargesTailPeak() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let admission = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: 1,
            applicationLedger: ledger
        )
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data()))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let terminal = expectation(description: "empty packet terminal")
        let retained = AdmittedDemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge)

        try subject.start(url: try httpURL(), admission: admission) { envelope in
            if envelope.isTerminal { terminal.fulfill() }
            else { retained.append(envelope) }
        }

        wait(for: [terminal], timeout: 2)
        retained.assertFirstPacketData(Data())
        XCTAssertEqual(admission.usage.count, 1, "zero-byte work still has an owner")
        XCTAssertGreaterThan(ledger.maximumChargedBytes, 0, "tail/envelope peak is still charged")
        retained.removeAll()
        XCTAssertEqual(admission.usage.count, 0)
        XCTAssertEqual(ledger.chargedBytes, 0)
    }

    func testDemuxDiscontinuityRequiresExplicitTypedReasonWithoutDefault() throws {
        let source = try repositorySource("Sources/VPlayerPlayback/Demux/DemuxTypes.swift")
        XCTAssertNotNil(
            source.range(
                of: #"case\s+discontinuity\s*\(\s*DemuxTrackSet\s*,\s*reason\s*:\s*DemuxDiscontinuityReason\s*\)"#,
                options: .regularExpression
            ),
            "the discontinuity case must retain its typed reason parameter"
        )
        XCTAssertNil(
            source.range(
                of: #"reason\s*:\s*DemuxDiscontinuityReason\s*="#,
                options: .regularExpression
            ),
            "a default reason silently restores the untyped migration entrance"
        )
    }

#if DEBUG
    func testBootstrapPacketLimitAccepts64AndRejects65WithoutLeaking() {
        let accepted = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_EXACT)
        XCTAssertEqual(accepted.status, 0)
        XCTAssertEqual(accepted.details.peak_packet_count, 64)
        XCTAssertEqual(accepted.details.live_resource_count, 0)

        let rejected = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_PACKET_LIMIT_OVERFLOW)
        XCTAssertLessThan(rejected.status, 0)
        XCTAssertEqual(rejected.details.peak_packet_count, 64)
        XCTAssertEqual(rejected.details.live_resource_count, 0)
    }

    func testBootstrapByteLimitAcceptsExactBoundAndRejectsOneByteOverWithoutLeaking() {
        let accepted = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_EXACT)
        XCTAssertEqual(accepted.status, 0)
        XCTAssertEqual(accepted.details.peak_accounted_bytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(accepted.details.live_resource_count, 0)

        let rejected = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_BYTE_LIMIT_OVERFLOW)
        XCTAssertLessThan(rejected.status, 0)
        XCTAssertLessThan(rejected.details.peak_accounted_bytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(rejected.details.live_resource_count, 0)
    }

    func testBootstrapRejectsEOFAndBothParserZeroProgressFormsWithoutLeaking() {
        let eof = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_EOF_BEFORE_DIMENSIONS)
        XCTAssertLessThan(eof.status, 0)
        XCTAssertEqual(eof.details.live_resource_count, 0)

        let noOutput = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_NO_OUTPUT)
        XCTAssertLessThan(noOutput.status, 0)
        XCTAssertEqual(noOutput.details.parser_call_count, 1)
        XCTAssertEqual(noOutput.details.live_resource_count, 0)

        let retry = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_ZERO_CONSUMED_WITH_OUTPUT)
        XCTAssertEqual(retry.status, 0)
        XCTAssertEqual(retry.details.parser_call_count, 2)
        XCTAssertEqual(retry.details.retried_same_input, 1)
        XCTAssertEqual(retry.details.live_resource_count, 0)

        let repeated = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_REPEATED_ZERO_CONSUMED)
        XCTAssertLessThan(repeated.status, 0)
        XCTAssertEqual(repeated.details.parser_call_count, 2)
        XCTAssertEqual(repeated.details.retried_same_input, 1)
        XCTAssertEqual(repeated.details.live_resource_count, 0)
    }

    func testBootstrapRestoresInitialAndPacketLocalStreamStateInReplayOrder() {
        let result = runBootstrapDebugScenario(VPFF_BOOTSTRAP_DEBUG_SNAPSHOT_REPLAY)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.details.initial_width, 1_280)
        XCTAssertEqual(result.details.initial_height, 720)
        XCTAssertEqual(result.details.replayed_packet_count, 3)
        XCTAssertEqual(result.details.first_replay_width, 1_280)
        XCTAssertEqual(result.details.first_replay_time_base_num, 1)
        XCTAssertEqual(result.details.first_replay_time_base_den, 90_000)
        XCTAssertEqual(result.details.second_replay_sample_rate, 48_000)
        XCTAssertEqual(result.details.second_replay_time_base_num, 1)
        XCTAssertEqual(result.details.second_replay_time_base_den, 48_000)
        XCTAssertEqual(result.details.third_replay_width, 1_920)
        XCTAssertEqual(result.details.third_replay_height, 1_080)
        XCTAssertEqual(result.details.third_replay_time_base_num, 1)
        XCTAssertEqual(result.details.third_replay_time_base_den, 45_000)
        XCTAssertEqual(result.details.live_resource_count, 0)
    }
#endif

    func testAcceptsHTTPAndHTTPSAndPreservesExactUTF8BytesAndLength() throws {
        for rawURL in ["http://example.invalid/live.ts", "https://example.invalid/频道.m3u8"] {
            let bridge = FakeFFmpegDemuxBridge()
            let recorder = DemuxEventRecorder()
            let subject = FFmpegDemuxer(bridge: bridge)
            let url = try XCTUnwrap(URL(string: rawURL))

            try subject.start(url: url, sink: recorder.record)

            XCTAssertEqual(recorder.waitForTerminal().last, .endOfStream)
            XCTAssertEqual(bridge.createCount, 1)
            XCTAssertEqual(bridge.urlBytes, Data(url.absoluteString.utf8))
            XCTAssertEqual(bridge.timeoutUS, 30_000_000)
        }
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(relativePath)
        return String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self)
    }

    func testRejectsEveryNonHTTPTopLevelSchemeBeforeCreatingBridge() throws {
        for rawURL in [
            "udp://239.1.1.1:1234",
            "rtp://239.1.1.1:1234",
            "file:///tmp/video.ts",
            "tcp://example.invalid:80",
            "data:text/plain,hello",
            "crypto+http://example.invalid/live.ts",
            "relative/path",
        ] {
            let bridge = FakeFFmpegDemuxBridge()
            let subject = FFmpegDemuxer(bridge: bridge)
            let url = try XCTUnwrap(URL(string: rawURL))
            let expectedScheme = url.scheme?.lowercased() ?? ""

            XCTAssertThrowsError(try subject.start(url: url, sink: { _ in })) { error in
                XCTAssertEqual(error as? PlaybackCoreError, .unsupportedProtocol(expectedScheme))
            }
            XCTAssertEqual(bridge.createCount, 0)
        }
    }

    func testRawBorrowedTrackAndPacketBytesAreCopiedBeforeCallbackReturns() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(
                programID: 42,
                video: .h264(fieldOrder: 2, extradata: Data([1, 2, 3])),
                audio: .aac(extradata: Data([0x12, 0x10])),
                mutateBorrowedBytesAfterCallback: true
            )
            handle.emitPacket(
                .init(
                    streamIndex: 7,
                    codec: VPFF_CODEC_H264,
                    data: Data([0, 0, 1, 9, 0xF0]),
                    pts: 90_000,
                    dts: 87_000,
                    duration: 3_003,
                    isKey: true,
                    isCorrupt: true
                ),
                mutateBorrowedBytesAfterCallback: true
            )
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge)

        try subject.start(url: try httpURL(), sink: recorder.record)
        let events = recorder.waitForTerminal()

        guard case let .tracks(tracks) = events.first else {
            return XCTFail("tracks must be first")
        }
        XCTAssertEqual(tracks.selectedProgramID, 42)
        XCTAssertEqual(tracks.video?.extradata, Data([1, 2, 3]))
        XCTAssertEqual(tracks.video?.fieldOrder, .tt)
        XCTAssertEqual(tracks.audio?.extradata, Data([0x12, 0x10]))
        guard case let .packet(packet) = events.dropFirst().first else {
            return XCTFail("packet must follow tracks")
        }
        XCTAssertEqual(packet.data, Data([0, 0, 1, 9, 0xF0]))
        XCTAssertEqual(packet.presentationTimeStamp, CMTime(value: 1, timescale: 1))
        XCTAssertEqual(packet.decodeTimeStamp, CMTime(value: 29, timescale: 30))
        XCTAssertEqual(packet.duration, CMTime(value: 1_001, timescale: 30_000))
        XCTAssertTrue(packet.isKey)
        XCTAssertTrue(packet.isCorrupt)
        XCTAssertEqual(events.last, .endOfStream)
    }

    func testCopiesValidVideoFrameRateAndTreatsInvalidRateAsUnknown() throws {
        let valid = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(video: .h264(frameRateNum: 25, frameRateDen: 1))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        guard case let .tracks(tracks) = try run(bridge: valid).first else {
            return XCTFail("missing tracks")
        }
        XCTAssertEqual(tracks.video?.frameRate, MediaRational(num: 25, den: 1))

        for (numerator, denominator) in [(Int32(0), Int32(1)), (25, 0), (-1, 1), (1, -1)] {
            let invalid = FakeFFmpegDemuxBridge { handle in
                handle.emitTracks(video: .h264(frameRateNum: numerator, frameRateDen: denominator))
                handle.emitTerminal(VPFF_EVENT_END)
                return 0
            }
            guard case let .tracks(invalidTracks) = try run(bridge: invalid).first else {
                return XCTFail("missing tracks for invalid frame rate \(numerator)/\(denominator)")
            }
            XCTAssertNil(invalidTracks.video?.frameRate, "invalid frame rate \(numerator)/\(denominator) must remain unknown")
            XCTAssertEqual(invalidTracks.video?.width, 1_920)
        }
    }

    func testCopiesProgramPresenceAndUnspecifiedAndNativeChannelLayouts() throws {
        let unspecified = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(audio: .aac(
                channelOrder: VPFF_CHANNEL_ORDER_UNSPECIFIED,
                hasMask: false
            ))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let native = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(
                programID: 0,
                audio: .aac(
                    channelOrder: VPFF_CHANNEL_ORDER_NATIVE,
                    hasMask: true,
                    mask: 3
                )
            )
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let unspecifiedEvents = try run(bridge: unspecified)
        let nativeEvents = try run(bridge: native)
        guard case let .tracks(first) = unspecifiedEvents.first,
              case let .tracks(second) = nativeEvents.first else {
            return XCTFail("missing track events")
        }
        XCTAssertNil(first.selectedProgramID)
        XCTAssertNil(first.audio?.channelLayout.nativeMask)
        XCTAssertEqual(second.selectedProgramID, 0)
        XCTAssertEqual(second.audio?.channelLayout.nativeMask, 3)
    }

    func testCopiesEveryNonnegativeVideoDelayExactly() throws {
        for expected in [Int32(0), 1, 3] {
            let bridge = FakeFFmpegDemuxBridge { handle in
                handle.emitTracks(video: .h264(videoDelay: expected))
                handle.emitTerminal(VPFF_EVENT_END)
                return 0
            }

            let events = try run(bridge: bridge)

            guard case let .tracks(tracks) = events.first else {
                return XCTFail("missing tracks for video delay \(expected)")
            }
            XCTAssertEqual(tracks.video?.videoDelay, expected)
            XCTAssertEqual(events.last, .endOfStream)
        }
    }

    func testMapsEverySupportedCodecAndPreservesNegativeAndInvalidTimes() throws {
        XCTAssertEqual(VPFF_CODEC_MP1.rawValue, 7)
        XCTAssertEqual(VPFF_CODEC_MP3.rawValue, 8)
        let specs: [(VPFFCodec, MediaCodec)] = [
            (VPFF_CODEC_H264, .video(.h264)),
            (VPFF_CODEC_HEVC, .video(.hevc)),
            (VPFF_CODEC_AAC, .audio(.aac)),
            (VPFF_CODEC_AC3, .audio(.ac3)),
            (VPFF_CODEC_EAC3, .audio(.eac3)),
            (VPFF_CODEC_MP2, .audio(.mp2)),
            (VPFF_CODEC_MP1, .audio(.mp1)),
            (VPFF_CODEC_MP3, .audio(.mp3)),
        ]
        let bridge = FakeFFmpegDemuxBridge { handle in
            for (index, entry) in specs.enumerated() {
                handle.emitPacket(.init(
                    streamIndex: Int32(index),
                    codec: entry.0,
                    data: Data([UInt8(index)]),
                    pts: -3_003,
                    dts: Int64.min,
                    duration: -1
                ))
            }
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let events = try run(bridge: bridge)
        let packets = events.compactMap(\.packet)
        XCTAssertEqual(packets.map(\.codec), specs.map { $0.1 })
        XCTAssertTrue(packets.allSatisfy { $0.presentationTimeStamp == CMTime(value: -1_001, timescale: 30_000) })
        XCTAssertTrue(packets.allSatisfy { !$0.decodeTimeStamp.isValid })
        XCTAssertTrue(packets.allSatisfy { !$0.duration.isValid })

        let unsupported = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(audio: .unsupportedAudio)
            return 0
        }
        XCTAssertEqual(try run(bridge: unsupported).last, .failure(.unsupportedAudioCodec))
    }

    func testUnsupportedCodecCustomAndAmbisonicLayoutsBecomePreciseTerminalFailures() throws {
        for order in [VPFF_CHANNEL_ORDER_CUSTOM, VPFF_CHANNEL_ORDER_AMBISONIC] {
            let bridge = FakeFFmpegDemuxBridge { handle in
                handle.emitTracks(audio: .aac(channelOrder: order))
                return 0
            }
            XCTAssertEqual(try run(bridge: bridge).last, .failure(.unsupportedAudioCodec))
        }

        let unsupportedAudio = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(audio: .unsupportedAudio)
            return 0
        }
        let unsupportedVideo = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(video: .unsupportedVideo)
            return 0
        }
        XCTAssertEqual(try run(bridge: unsupportedAudio).last, .failure(.unsupportedAudioCodec))
        XCTAssertEqual(try run(bridge: unsupportedVideo).last, .failure(.unsupportedVideoCodec))
    }

    func testCErrorKindsMapOnlyToInternalPlaybackCoreErrors() throws {
        let cases: [(VPFFDemuxErrorKind, Int32, PlaybackCoreError)] = [
            (VPFF_DEMUX_ERROR_OPEN, -10, .demuxOpen(-10)),
            (VPFF_DEMUX_ERROR_READ, -11, .demuxRead(-11)),
            (VPFF_DEMUX_ERROR_TIMEOUT, -12, .networkTimeout),
            (VPFF_DEMUX_ERROR_UNSUPPORTED_VIDEO, -13, .unsupportedVideoCodec),
            (VPFF_DEMUX_ERROR_UNSUPPORTED_AUDIO, -14, .unsupportedAudioCodec),
        ]
        for entry in cases {
            let bridge = FakeFFmpegDemuxBridge { handle in
                handle.emitTerminal(VPFF_EVENT_ERROR, errorKind: entry.0, ffmpegError: entry.1)
                return entry.1
            }
            XCTAssertEqual(try run(bridge: bridge).last, .failure(entry.2))
        }
    }

    func testMalformedEnumPointerSizeAndTimeBaseAreRejectedWithoutDereference() throws {
        let invalidTimeBase = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1]), timeBaseDen: 0))
            return 0
        }
        XCTAssertEqual(
            try run(bridge: invalidTimeBase).last,
            .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode))
        )

        let invalidEnum = FakeFFmpegDemuxBridge { handle in
            handle.emitTerminal(VPFFDemuxEventKind(rawValue: 99))
            return 0
        }
        XCTAssertEqual(
            try run(bridge: invalidEnum).last,
            .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode))
        )

        let invalidSize = FakeFFmpegDemuxBridge { handle in
            handle.emitMalformedPacketPointerSize()
            return 0
        }
        XCTAssertEqual(
            try run(bridge: invalidSize).last,
            .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode))
        )
    }

    func testRejectsUnknownCodecStageAndFlagValuesAndCancelsNativeRun() throws {
        let unknownCodec = VPFFCodec(rawValue: 99)
        let unknownChannelOrder = VPFFChannelOrder(rawValue: 99)
        let unknownStage = VPFFDemuxErrorStage(rawValue: 99)
        let unknownError = VPFFDemuxErrorKind(rawValue: 99)
        let scripts: [(String, FakeFFmpegDemuxBridge.RunScript)] = [
            ("unknown video codec", { handle in
                var track = RawTrackSpec.h264()
                track.codec = unknownCodec
                handle.emitTracks(video: track)
                return 0
            }),
            ("unknown audio codec", { handle in
                var track = RawTrackSpec.aac()
                track.codec = unknownCodec
                handle.emitTracks(audio: track)
                return 0
            }),
            ("unknown packet codec", { handle in
                handle.emitPacket(.init(codec: unknownCodec, data: Data([1])))
                return 0
            }),
            ("unknown channel order", { handle in
                var track = RawTrackSpec.aac()
                track.channelOrder = unknownChannelOrder
                handle.emitTracks(audio: track)
                return 0
            }),
            ("unknown video field order", { handle in
                var track = RawTrackSpec.h264()
                track.fieldOrder = 99
                handle.emitTracks(video: track)
                return 0
            }),
            ("unknown error stage", { handle in
                handle.emitTerminal(
                    VPFF_EVENT_ERROR,
                    errorKind: VPFF_DEMUX_ERROR_READ,
                    ffmpegError: -1,
                    errorStage: unknownStage
                )
                return 0
            }),
            ("missing error stage", { handle in
                handle.emitTerminal(
                    VPFF_EVENT_ERROR,
                    errorKind: VPFF_DEMUX_ERROR_READ,
                    ffmpegError: -1,
                    errorStage: VPFF_DEMUX_STAGE_NONE
                )
                return 0
            }),
            ("stage on non-error", { handle in
                handle.emitTerminal(VPFF_EVENT_END, errorStage: VPFF_DEMUX_STAGE_READ)
                return 0
            }),
            ("unknown error kind", { handle in
                handle.emitTerminal(
                    VPFF_EVENT_ERROR,
                    errorKind: unknownError,
                    ffmpegError: -1,
                    errorStage: VPFF_DEMUX_STAGE_READ
                )
                return 0
            }),
            ("non-boolean program presence", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_END
                    event.has_program_id = 2
                }
                return 0
            }),
            ("non-boolean track presence", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_TRACKS
                    event.video.present = 2
                }
                return 0
            }),
            ("non-boolean channel-mask presence", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_TRACKS
                    event.audio.present = 1
                    event.audio.has_channel_layout_mask = 2
                }
                return 0
            }),
            ("non-boolean packet flag", { handle in
                handle.emitRawEvent { event in
                    event.kind = VPFF_EVENT_PACKET
                    event.packet.stream_index = 0
                    event.packet.codec = VPFF_CODEC_H264
                    event.packet.time_base_num = 1
                    event.packet.time_base_den = 90_000
                    event.packet.is_key = 2
                }
                return 0
            }),
        ]

        for (label, script) in scripts {
            let bridge = FakeFFmpegDemuxBridge(runScript: script)
            XCTAssertEqual(
                try run(bridge: bridge).last,
                .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode)),
                label
            )
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, label)
            XCTAssertEqual(bridge.handle?.cancelCount, 1, label)
        }
    }

    func testRejectsInvalidRequiredFieldsAndOversizedBorrowedBuffersBeforeCopying() throws {
        let scripts: [(String, FakeFFmpegDemuxBridge.RunScript)] = [
            ("no present tracks", { handle in
                handle.emitTracks()
                return 0
            }),
            ("negative track index", { handle in
                var track = RawTrackSpec.h264()
                track.streamIndex = -1
                handle.emitTracks(video: track)
                return 0
            }),
            ("zero video width", { handle in
                handle.emitTracks(video: .h264(width: 0))
                return 0
            }),
            ("zero video height", { handle in
                var track = RawTrackSpec.h264()
                track.height = 0
                handle.emitTracks(video: track)
                return 0
            }),
            ("negative video delay", { handle in
                var track = RawTrackSpec.h264()
                track.videoDelay = -1
                handle.emitTracks(video: track)
                return 0
            }),
            ("zero sample rate", { handle in
                var track = RawTrackSpec.aac()
                track.sampleRate = 0
                handle.emitTracks(audio: track)
                return 0
            }),
            ("zero channel count", { handle in
                var track = RawTrackSpec.aac()
                track.channelCount = 0
                handle.emitTracks(audio: track)
                return 0
            }),
            ("zero native channel mask", { handle in
                handle.emitTracks(audio: .aac(mask: 0))
                return 0
            }),
            ("native mask channel-count mismatch", { handle in
                handle.emitTracks(audio: .aac(mask: 1))
                return 0
            }),
            ("negative packet index", { handle in
                handle.emitPacket(.init(streamIndex: -1, codec: VPFF_CODEC_H264))
                return 0
            }),
            ("oversized packet", { handle in
                handle.emitOversizedPacketSize()
                return 0
            }),
            ("oversized extradata", { handle in
                handle.emitOversizedTrackExtradata()
                return 0
            }),
        ]

        for (label, script) in scripts {
            let bridge = FakeFFmpegDemuxBridge(runScript: script)
            XCTAssertEqual(
                try run(bridge: bridge).last,
                .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode)),
                label
            )
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, label)
            XCTAssertEqual(bridge.handle?.cancelCount, 1, label)
        }
    }

    func testRejectsOversizedURLBeforeCreatingBridge() throws {
        let bridge = FakeFFmpegDemuxBridge()
        let subject = FFmpegDemuxer(bridge: bridge)
        let rawURL = "https://example.invalid/" + String(repeating: "a", count: 64 * 1_024)
        let url = try XCTUnwrap(URL(string: rawURL))

        XCTAssertThrowsError(try subject.start(url: url, sink: { _ in })) { error in
            XCTAssertEqual(error as? PlaybackCoreError, .demuxOpen(FFmpegDemuxer.oversizedValueErrorCode))
        }
        XCTAssertEqual(bridge.createCount, 0)
    }

    func testIdenticalTimelineDiscontinuityIsDeliveredBeforePacket() throws {
        let first = RawTrackSpec.h264(width: 1_920, extradata: Data([1]))
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(video: first)
            handle.emitTracks(
                video: first,
                kind: VPFF_EVENT_DISCONTINUITY,
                discontinuityReason: VPFF_DISCONTINUITY_TIMELINE_RESET
            )
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([9])))
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let events = try run(bridge: bridge)
        XCTAssertEqual(events.count, 4)
        guard case .tracks = events[0],
              case let .discontinuity(tracks, reason) = events[1],
              case .packet = events[2] else {
            return XCTFail("expected tracks, timeline discontinuity, packet")
        }
        XCTAssertEqual(tracks.video?.width, 1_920)
        XCTAssertEqual(reason, .timelineReset)
        XCTAssertEqual(events[3], .endOfStream)
    }

    func testFormatChangeDiscontinuityCarriesExplicitReason() throws {
        let changed = RawTrackSpec.h264(width: 1_280, extradata: Data([2]))
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(video: RawTrackSpec.h264())
            handle.emitTracks(
                video: changed,
                kind: VPFF_EVENT_DISCONTINUITY,
                discontinuityReason: VPFF_DISCONTINUITY_FORMAT_CHANGE
            )
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let events = try run(bridge: bridge)
        guard case let .discontinuity(tracks, reason) = events.dropFirst().first else {
            return XCTFail("expected a format-change discontinuity")
        }
        XCTAssertEqual(tracks.video?.width, 1_280)
        XCTAssertEqual(reason, .formatChange)
    }

    func testMissingOrUnknownDiscontinuityReasonIsMalformed() throws {
        for (label, reason) in [
            ("missing", VPFF_DISCONTINUITY_NONE),
            ("unknown", VPFFDemuxDiscontinuityReason(rawValue: 99)),
        ] {
            let bridge = FakeFFmpegDemuxBridge { handle in
                handle.emitTracks(
                    video: .h264(),
                    kind: VPFF_EVENT_DISCONTINUITY,
                    discontinuityReason: reason
                )
                return 0
            }

            XCTAssertEqual(
                try run(bridge: bridge).last,
                .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode)),
                label
            )
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, label)
            XCTAssertEqual(bridge.handle?.cancelCount, 1, label)
        }
    }

    func testNonDiscontinuityEventIgnoresUnknownDiscontinuityReason() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTracks(
                video: .h264(),
                discontinuityReason: VPFFDemuxDiscontinuityReason(rawValue: 99)
            )
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }

        let events = try run(bridge: bridge)
        guard case .tracks = events.first else { return XCTFail("expected tracks") }
        XCTAssertEqual(events.last, .endOfStream)
    }

    func testNativeDemuxABIValuesAndAppendOnlyEventLayoutAreStable() {
        XCTAssertEqual(VPFF_DISCONTINUITY_NONE.rawValue, 0)
        XCTAssertEqual(VPFF_DISCONTINUITY_FORMAT_CHANGE.rawValue, 1)
        XCTAssertEqual(VPFF_DISCONTINUITY_TIMELINE_RESET.rawValue, 2)
        XCTAssertEqual(VPFF_FIELD_ORDER_UNKNOWN.rawValue, 0)
        XCTAssertEqual(VPFF_FIELD_ORDER_PROGRESSIVE.rawValue, 1)
        XCTAssertEqual(VPFF_FIELD_ORDER_TT.rawValue, 2)
        XCTAssertEqual(VPFF_FIELD_ORDER_BB.rawValue, 3)
        XCTAssertEqual(VPFF_FIELD_ORDER_TB.rawValue, 4)
        XCTAssertEqual(VPFF_FIELD_ORDER_BT.rawValue, 5)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.kind), 0)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.has_program_id), 4)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.selected_program_id), 8)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.video), 16)
        XCTAssertEqual(MemoryLayout<VPFFTrack>.offset(of: \.field_order), 53)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.audio), 96)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.packet), 176)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.error_kind), 240)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.error_stage), 244)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.ffmpeg_error), 248)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.offset(of: \.discontinuity_reason), 252)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.size, 256)
    }

    func testVersionedTrackExtrasPreserveLegacyABIAndUseStableOffsets() {
        XCTAssertEqual(MemoryLayout<VPFFTrack>.size, 80)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEvent>.size, 256)
        XCTAssertEqual(VPFF_DEMUX_EVENT_EXTRAS_VERSION_1, 1)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtras>.size, 16)
        XCTAssertEqual(MemoryLayout<VPFFTrackExtrasV1>.size, 152)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV1>.offset(of: \.header), 0)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV1>.offset(of: \.video), 16)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV1>.offset(of: \.audio), 168)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV1>.size, 320)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV2>.offset(of: \.header), 0)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV2>.offset(of: \.video), 16)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV2>.offset(of: \.audio), 168)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV2>.offset(of: \.has_audio_primary_evidence), 320)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV2>.offset(of: \.audio_primary_evidence), 324)
        XCTAssertEqual(MemoryLayout<VPFFAudioPrimaryEvidenceV1>.size, 40)
        XCTAssertEqual(MemoryLayout<VPFFDemuxEventExtrasV2>.size, 368)
    }

    func testRejectsMalformedV2PrimaryEvidenceBeforeCopyingReceipt() throws {
        // 若复制器接受未知 V2、截断 V2 或不自洽的 receipt，容器外部输入即可伪造主服务依据。
        for malformed in Task22MalformedV2PrimaryEvidence.allCases {
            let bridge = Task11ExtrasDemuxBridge { handle in
                handle.emitMalformedV2PrimaryEvidence(malformed)
                return 0
            }
            let events = try run(extrasBridge: bridge)
            guard case let .failure(.demuxRead(code)) = events.last else {
                XCTFail("\(malformed) 未被拒绝")
                continue
            }
            XCTAssertLessThan(code, 0, "\(malformed) 必须作为 malformed event 终止")
            XCTAssertEqual(events.count, 1, "\(malformed) 不得先发布 tracks")
        }
    }

    func testMasteringDisplayConstructorRequiresEveryChromaticityPairInsideUnitTriangle() {
        let nearOne = DemuxHDRRational(num: Int32.max - 1, den: Int32.max)!
        let nearZero = DemuxHDRRational(num: 1, den: Int32.max)!
        let validPairs: [(x: DemuxHDRRational, y: DemuxHDRRational)] = [
            (nearOne, nearZero),
            (DemuxHDRRational(num: 13, den: 50)!, DemuxHDRRational(num: 69, den: 100)!),
            (DemuxHDRRational(num: 3, den: 20)!, DemuxHDRRational(num: 3, den: 50)!),
            (DemuxHDRRational(num: 3_127, den: 10_000)!, DemuxHDRRational(num: 329, den: 1_000)!),
        ]
        func metadata(
            _ pairs: [(x: DemuxHDRRational, y: DemuxHDRRational)]
        ) -> DemuxMasteringDisplayMetadata? {
            DemuxMasteringDisplayMetadata(
                redX: pairs[0].x,
                redY: pairs[0].y,
                greenX: pairs[1].x,
                greenY: pairs[1].y,
                blueX: pairs[2].x,
                blueY: pairs[2].y,
                whitePointX: pairs[3].x,
                whitePointY: pairs[3].y,
                minimumLuminance: DemuxHDRRational(num: 0, den: 1)!,
                maximumLuminance: DemuxHDRRational(num: 1_000, den: 1)!
            )
        }

        XCTAssertNotNil(metadata(validPairs), "精确落在单位三角形边界应合法")
        for (index, label) in ["red", "green", "blue", "white point"].enumerated() {
            var invalidPairs = validPairs
            invalidPairs[index] = (
                DemuxHDRRational(num: 3, den: 5)!,
                DemuxHDRRational(num: 1, den: 2)!
            )
            XCTAssertNil(metadata(invalidPairs), "\(label) 的 x+y>1 应被拒绝")
        }
    }

    func testCopiesAllBorrowedTrackExtrasAndCarriesMetadataDriftOnFormatChange() throws {
        let bridge = Task11ExtrasDemuxBridge { handle in
            handle.emitTracks(
                video: true,
                audio: true,
                videoLanguage: Array("zh-Hant".utf8),
                audioLanguage: Array("en".utf8)
            ) { extras in
                extras.video.presence = 0xFFF
                extras.video.role = VPFF_TRACK_ROLE_MAIN
                extras.video.service = VPFF_TRACK_SERVICE_INDEPENDENT_MAIN
                extras.video.dispositions = 0x3
                extras.video.sample_aspect_ratio = .init(num: 4, den: 3)
                extras.video.color_range = VPFF_COLOR_RANGE_FULL
                extras.video.color_primaries = VPFF_COLOR_PRIMARIES_BT2020
                extras.video.color_transfer = VPFF_COLOR_TRANSFER_PQ
                extras.video.color_matrix = VPFF_COLOR_MATRIX_BT2020_NONCONSTANT
                extras.video.chroma_location = VPFF_CHROMA_LOCATION_TOP_LEFT
                Task11ExtrasDemuxHandle.fillMasteringDisplay(&extras.video)
                extras.video.maximum_content_light_level = 1_000
                extras.video.maximum_frame_average_light_level = 400

                extras.audio.presence = 0xF
                extras.audio.role = VPFF_TRACK_ROLE_ALTERNATE
                extras.audio.service = VPFF_TRACK_SERVICE_ASSOCIATED
                extras.audio.dispositions = 0x30
            }
            handle.emitTracks(
                video: true,
                audio: true,
                kind: VPFF_EVENT_DISCONTINUITY,
                reason: VPFF_DISCONTINUITY_FORMAT_CHANGE,
                videoLanguage: Array("zh-Hant".utf8),
                audioLanguage: Array("en".utf8)
            ) { extras in
                extras.video.presence = 0xFFF
                extras.video.role = VPFF_TRACK_ROLE_MAIN
                extras.video.service = VPFF_TRACK_SERVICE_INDEPENDENT_MAIN
                extras.video.dispositions = 0x3
                extras.video.sample_aspect_ratio = .init(num: 4, den: 3)
                extras.video.color_range = VPFF_COLOR_RANGE_FULL
                extras.video.color_primaries = VPFF_COLOR_PRIMARIES_BT2020
                extras.video.color_transfer = VPFF_COLOR_TRANSFER_PQ
                extras.video.color_matrix = VPFF_COLOR_MATRIX_BT2020_NONCONSTANT
                extras.video.chroma_location = VPFF_CHROMA_LOCATION_TOP_LEFT
                Task11ExtrasDemuxHandle.fillMasteringDisplay(&extras.video)
                extras.video.maximum_content_light_level = 2_000
                extras.video.maximum_frame_average_light_level = 800

                extras.audio.presence = 0xF
                extras.audio.role = VPFF_TRACK_ROLE_ALTERNATE
                extras.audio.service = VPFF_TRACK_SERVICE_ASSOCIATED
                extras.audio.dispositions = 0x30
            }
            handle.emitTerminal()
            return 0
        }

        let events = try run(extrasBridge: bridge)
        guard case let .tracks(first) = events[0],
              case let .discontinuity(second, reason) = events[1] else {
            return XCTFail("缺少扩展轨道事件")
        }
        XCTAssertEqual(reason, .formatChange)
        XCTAssertEqual(first.video?.metadata.role, .main)
        XCTAssertEqual(first.video?.metadata.language, "zh-Hant")
        XCTAssertEqual(first.video?.metadata.service, .independentMain)
        XCTAssertEqual(first.video?.metadata.dispositions, [.default, .forced])
        XCTAssertEqual(first.audio?.metadata.role, .alternate)
        XCTAssertEqual(first.audio?.metadata.language, "en")
        XCTAssertEqual(first.audio?.metadata.service, .associated)
        XCTAssertEqual(first.audio?.metadata.dispositions, [.commentary, .dependent])
        XCTAssertEqual(first.video?.videoMetadata.sampleAspectRatio, MediaRational(num: 4, den: 3))
        XCTAssertEqual(first.video?.videoMetadata.range, .full)
        XCTAssertEqual(first.video?.videoMetadata.primaries, .bt2020)
        XCTAssertEqual(first.video?.videoMetadata.transfer, .pq)
        XCTAssertEqual(first.video?.videoMetadata.matrix, .bt2020Nonconstant)
        XCTAssertEqual(first.video?.videoMetadata.chromaLocation, .topLeft)
        XCTAssertEqual(first.video?.videoMetadata.masteringDisplay?.displayPrimariesX, [
            DemuxHDRRational(num: 17, den: 50)!,
            DemuxHDRRational(num: 13, den: 50)!,
            DemuxHDRRational(num: 3, den: 20)!,
        ])
        XCTAssertEqual(first.video?.videoMetadata.masteringDisplay?.maximumLuminance, DemuxHDRRational(num: 1_000, den: 1))
        XCTAssertEqual(first.video?.videoMetadata.contentLightLevel, .init(
            maximumContentLightLevel: 1_000,
            maximumFrameAverageLightLevel: 400
        ))
        XCTAssertEqual(second.video?.videoMetadata.contentLightLevel, .init(
            maximumContentLightLevel: 2_000,
            maximumFrameAverageLightLevel: 800
        ))
    }

    func testMissingExtrasStayUnknownAndDefaultDispositionDoesNotInventMainRole() throws {
        let bridge = Task11ExtrasDemuxBridge { handle in
            handle.emitTracks(video: true, audio: true) { extras in
                extras.audio.presence = 1 << 3
                extras.audio.dispositions = 1
            }
            handle.emitTerminal()
            return 0
        }

        let events = try run(extrasBridge: bridge)
        guard case let .tracks(tracks) = events[0] else { return XCTFail("缺少轨道事件") }
        XCTAssertNil(tracks.audio?.metadata.role)
        XCTAssertNil(tracks.audio?.metadata.language)
        XCTAssertNil(tracks.audio?.metadata.service)
        XCTAssertEqual(tracks.audio?.metadata.dispositions, [.default])
        XCTAssertEqual(tracks.video?.metadata, DemuxTrackMetadata())
        XCTAssertEqual(tracks.video?.videoMetadata, DemuxVideoMetadata())
    }

    func testRejectsMalformedVersionSizeOffsetPresenceUTF8AndRationals() throws {
        let cases: [(String, Task11MalformedExtras)] = [
            ("version", .version),
            ("size", .size),
            ("offset", .offset),
            ("presence", .presence),
            ("utf8", .utf8),
            ("sample aspect ratio", .sampleAspectRatio),
            ("mastering display", .masteringDisplay),
            ("mastering chromaticity", .masteringChromaticity),
            ("content light level", .contentLightLevel),
        ]

        for (label, malformed) in cases {
            let bridge = Task11ExtrasDemuxBridge { handle in
                handle.emitMalformedTracks(malformed)
                return 0
            }
            XCTAssertEqual(
                try run(extrasBridge: bridge).last,
                .failure(.demuxRead(FFmpegDemuxer.malformedEventErrorCode)),
                label
            )
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, label)
            XCTAssertEqual(bridge.handle?.cancelCount, 1, label)
        }
    }

#if DEBUG
    func testPrimaryEvidenceFromProductionSelectionCoversProgramAndFormatScopes() throws {
        let cases: [(VPFFTrackExtrasDebugScenario, DemuxTrackSet.AudioPrimaryScope, Int, Int, DemuxTrackSet.AudioPrimaryBasis?)] = [
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_SOLE, .avProgram(index: 0, id: 1), 1, 0, .soleAudio),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN, .avProgram(index: 0, id: 1), 2, 0, .explicitMain),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNIQUE_DEFAULT, .avProgram(index: 0, id: 1), 2, 1, .uniqueDefault),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_AMBIGUOUS, .avProgram(index: 0, id: 1), 2, 0, nil),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MULTI_DEFAULT, .avProgram(index: 0, id: 1), 2, 2, nil),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN_DEFAULT_COMPETITION, .avProgram(index: 0, id: 1), 2, 1, nil),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNKNOWN_OR_AUXILIARY, .avProgram(index: 0, id: 1), 2, 0, nil),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_FORMAT_SCOPE, .formatStreamTableWithoutProgram, 2, 1, .uniqueDefault),
        ]
        for (scenario, scope, audioCount, defaultCount, basis) in cases {
            let events = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(scenario: scenario))
            guard case let .tracks(tracks) = events.first,
                  let evidence = tracks.audioPrimaryEvidence else {
                return XCTFail("\\(scenario.rawValue) 未从真实 C selection 事件复制 primary receipt")
            }
            XCTAssertEqual(tracks.audio?.streamIndex, evidence.selectedStreamIndex, "选中 stream 必须绑定 receipt")
            XCTAssertEqual(tracks.selectedProgramID, scope == .formatStreamTableWithoutProgram ? nil : 1)
            XCTAssertEqual(evidence.scope, scope)
            XCTAssertEqual(evidence.audioStreamCount, UInt32(audioCount), "不支持 codec 也必须留在 scope")
            XCTAssertEqual(evidence.defaultAudioStreamCount, UInt32(defaultCount))
            XCTAssertEqual(evidence.primaryBasis, basis)
        }
    }

    func testProductionSelectionReceiptDrivesAudioServiceSemanticAcrossEightScopes() throws {
        let cases: [(VPFFTrackExtrasDebugScenario, AudioServiceSemantic)] = [
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_SOLE, .independentMain),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN, .independentMain),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNIQUE_DEFAULT, .independentMain),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_AMBIGUOUS, .unknown),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MULTI_DEFAULT, .unknown),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_MAIN_DEFAULT_COMPETITION, .unknown),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_PROGRAM_UNKNOWN_OR_AUXILIARY, .unknown),
            (VPFF_TRACK_EXTRAS_DEBUG_PRIMARY_FORMAT_SCOPE, .independentMain),
        ]
        for (scenario, expectedSemantic) in cases {
            let events = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(scenario: scenario))
            guard case let .tracks(tracks) = events.first,
                  let audio = tracks.audio,
                  let evidence = tracks.audioPrimaryEvidence else {
                XCTFail("\(scenario.rawValue) 未从 C selection 取得 audio receipt")
                continue
            }
            let header: AudioServiceInputUnit?
            if audio.codec == .ac3 {
                let headerBytes = AssemblerTestFixtures.syntheticAC3Frame(bsmod: 0)
                header = try AudioServiceInputUnit(
                    identity: .init(rawValue: UInt64(scenario.rawValue)),
                    backing: .init(identity: .init(rawValue: UInt64(scenario.rawValue) + 100), bytes: headerBytes),
                    byteRange: .init(offset: 0, length: headerBytes.count)!,
                    presentationTimeStamp: .zero,
                    parserSampleCount: 1_536,
                    parserSampleRate: audio.sampleRate,
                    parserChannelLayout: audio.channelLayout,
                    containerMarkedCorrupt: false
                )
            } else {
                XCTAssertEqual(audio.codec, .aac, "\(scenario.rawValue) selection 不应伪造未知 codec")
                header = nil
            }
            let coordinator = AudioServiceSemanticCoordinator(
                source: audio,
                sourceTrackIdentity: .init(streamIndex: audio.streamIndex, trackNonce: UInt64(scenario.rawValue)),
                inputFormatGeneration: .init(rawValue: 1),
                allocator: PlaybackIdentityAllocator(),
                applicationLedger: HLSDeliveryApplicationChargeLedger()
            )
            let receipt = try coordinator.establishReceipt(
                selectedProgramID: tracks.selectedProgramID,
                firstInputUnit: header,
                audioPrimaryEvidence: evidence
            )
            XCTAssertEqual(receipt.semantic, expectedSemantic, "\(scenario.rawValue) 必须由 C receipt 裁决")
        }
    }

    func testProductionMapperExportsEvidenceRejectsDefaultInferenceAndDetectsMetadataDrift() throws {
        let full = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
            scenario: VPFF_TRACK_EXTRAS_DEBUG_FULL_EVIDENCE
        ))
        guard case let .tracks(fullTracks) = full.first else {
            return XCTFail("真实 C mapper 未产出轨道事件")
        }
        XCTAssertEqual(fullTracks.video?.metadata.role, .main)
        XCTAssertEqual(fullTracks.video?.metadata.language, "zh-Hant")
        XCTAssertEqual(fullTracks.video?.metadata.service, .independentMain)
        XCTAssertEqual(fullTracks.video?.metadata.dispositions, [.default, .forced])
        XCTAssertEqual(fullTracks.video?.videoMetadata.sampleAspectRatio, MediaRational(num: 4, den: 3))
        XCTAssertEqual(fullTracks.video?.videoMetadata.range, .full)
        XCTAssertEqual(fullTracks.video?.videoMetadata.primaries, .bt2020)
        XCTAssertEqual(fullTracks.video?.videoMetadata.transfer, .pq)
        XCTAssertEqual(fullTracks.video?.videoMetadata.matrix, .bt2020Nonconstant)
        XCTAssertEqual(fullTracks.video?.videoMetadata.chromaLocation, .topLeft)
        XCTAssertEqual(fullTracks.video?.videoMetadata.masteringDisplay, DemuxMasteringDisplayMetadata(
            redX: DemuxHDRRational(num: 17, den: 50)!,
            redY: DemuxHDRRational(num: 33, den: 100)!,
            greenX: DemuxHDRRational(num: 13, den: 50)!,
            greenY: DemuxHDRRational(num: 69, den: 100)!,
            blueX: DemuxHDRRational(num: 3, den: 20)!,
            blueY: DemuxHDRRational(num: 3, den: 50)!,
            whitePointX: DemuxHDRRational(num: 3_127, den: 10_000)!,
            whitePointY: DemuxHDRRational(num: 329, den: 1_000)!,
            minimumLuminance: DemuxHDRRational(num: 1, den: 10_000)!,
            maximumLuminance: DemuxHDRRational(num: 1_000, den: 1)!
        ))
        XCTAssertEqual(fullTracks.video?.videoMetadata.contentLightLevel, .init(
            maximumContentLightLevel: 1_000,
            maximumFrameAverageLightLevel: 400
        ))
        XCTAssertEqual(fullTracks.audio?.metadata.role, .commentary)
        XCTAssertEqual(fullTracks.audio?.metadata.language, "en")
        XCTAssertEqual(fullTracks.audio?.metadata.service, .associated)
        XCTAssertEqual(fullTracks.audio?.metadata.dispositions, [.commentary])

        let defaultOnly = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
            scenario: VPFF_TRACK_EXTRAS_DEBUG_DEFAULT_ONLY
        ))
        guard case let .tracks(defaultTracks) = defaultOnly.first else {
            return XCTFail("default-only 场景未产出轨道事件")
        }
        XCTAssertNil(defaultTracks.audio?.metadata.role)
        XCTAssertNil(defaultTracks.audio?.metadata.language)
        XCTAssertNil(defaultTracks.audio?.metadata.service)
        XCTAssertEqual(defaultTracks.audio?.metadata.dispositions, [.default])

        let audioServiceMain = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
            scenario: VPFF_TRACK_EXTRAS_DEBUG_AUDIO_SERVICE_MAIN
        ))
        guard case let .tracks(mainServiceTracks) = audioServiceMain.first else {
            return XCTFail("audio-service MAIN 场景未产出轨道事件")
        }
        XCTAssertNil(mainServiceTracks.audio?.metadata.role, "service MAIN 不是 primary track role 证据")
        XCTAssertEqual(mainServiceTracks.audio?.metadata.service, .independentMain)

        let conflict = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
            scenario: VPFF_TRACK_EXTRAS_DEBUG_SERVICE_CONFLICT
        ))
        guard case let .tracks(conflictTracks) = conflict.first else {
            return XCTFail("多来源冲突场景未产出轨道事件")
        }
        XCTAssertNil(conflictTracks.audio?.metadata.role)
        XCTAssertNil(conflictTracks.audio?.metadata.service, "冲突证据不得按优先级吞掉")
        XCTAssertEqual(conflictTracks.audio?.metadata.serviceEvidence, .unclassifiable)
        XCTAssertEqual(conflictTracks.audio?.metadata.dispositions, [.dependent])

        for (label, scenario) in [
            ("未知metadata service", VPFF_TRACK_EXTRAS_DEBUG_UNKNOWN_SERVICE_TOKEN),
            ("Karaoke side-data", VPFF_TRACK_EXTRAS_DEBUG_KARAOKE_SERVICE),
        ] {
            let events = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
                scenario: scenario
            ))
            guard case let .tracks(tracks) = events.first else {
                XCTFail("\(label) 场景未产出轨道事件")
                continue
            }
            XCTAssertEqual(tracks.audio?.metadata.role, .main, label)
            XCTAssertNil(tracks.audio?.metadata.service, label)
            XCTAssertEqual(tracks.audio?.metadata.serviceEvidence, .unclassifiable, label)
        }

        let malformedAudioService = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
            scenario: VPFF_TRACK_EXTRAS_DEBUG_MALFORMED_AUDIO_SERVICE
        ))
        guard case let .failure(.demuxRead(code)) = malformedAudioService.last else {
            return XCTFail("损坏audio-service side-data未被拒绝")
        }
        XCTAssertLessThan(code, 0)
        XCTAssertEqual(malformedAudioService.count, 1)

        let zeroMinimum = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
            scenario: VPFF_TRACK_EXTRAS_DEBUG_ZERO_MIN_LUMINANCE
        ))
        guard case let .tracks(zeroMinimumTracks) = zeroMinimum.first else {
            return XCTFail("零最小亮度应是合法 MDCV")
        }
        XCTAssertEqual(
            zeroMinimumTracks.video?.videoMetadata.masteringDisplay?.minimumLuminance,
            DemuxHDRRational(num: 0, den: 1)
        )

        for (label, scenario) in [
            ("MDCV", VPFF_TRACK_EXTRAS_DEBUG_INVALID_MASTERING_DISPLAY),
            ("MDCV unit triangle", VPFF_TRACK_EXTRAS_DEBUG_INVALID_MASTERING_DISPLAY_SUM),
            ("CLLI", VPFF_TRACK_EXTRAS_DEBUG_INVALID_CONTENT_LIGHT_LEVEL),
        ] {
            let events = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
                scenario: scenario
            ))
            guard case let .failure(.demuxRead(code)) = events.last else {
                XCTFail("非自洽 \(label) 未被生产 mapper 拒绝")
                continue
            }
            XCTAssertLessThan(code, 0, label)
            XCTAssertEqual(events.count, 1, label)
        }

        let drift = try run(productionExtrasBridge: Task11ProductionExtrasDemuxBridge(
            scenario: VPFF_TRACK_EXTRAS_DEBUG_FORMAT_DRIFT
        ))
        guard case let .tracks(initial) = drift.first,
              case let .discontinuity(changed, reason) = drift.dropFirst().first else {
            return XCTFail("元数据漂移未产出 format-change discontinuity")
        }
        XCTAssertEqual(reason, .formatChange)
        XCTAssertEqual(initial.video?.videoMetadata.contentLightLevel, .init(
            maximumContentLightLevel: 1_000,
            maximumFrameAverageLightLevel: 400
        ))
        XCTAssertEqual(changed.video?.videoMetadata.contentLightLevel, .init(
            maximumContentLightLevel: 2_000,
            maximumFrameAverageLightLevel: 800
        ))
    }
#endif

    func testCapacityFourBlocksFifthProducerUntilOneEventIsConsumed() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.blocked-drain")
        let unblockDrain = DispatchSemaphore(value: 0)
        let drainBlocked = expectation(description: "executor blocked")
        executor.submit {
            drainBlocked.fulfill()
            unblockDrain.wait()
        }
        wait(for: [drainBlocked], timeout: 2)

        let fifthAttempted = DispatchSemaphore(value: 0)
        let fifthCompleted = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            for index in 0..<4 {
                handle.emitPacket(.init(streamIndex: Int32(index), codec: VPFF_CODEC_H264, data: Data([UInt8(index)])))
            }
            fifthAttempted.signal()
            handle.emitPacket(.init(streamIndex: 4, codec: VPFF_CODEC_H264, data: Data([4])))
            fifthCompleted.signal()
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, executor: executor, capacity: 4)
        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertEqual(fifthAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fifthCompleted.wait(timeout: .now() + 0.05), .timedOut)
        unblockDrain.signal()
        XCTAssertEqual(fifthCompleted.wait(timeout: .now() + 2), .success)
        let events = recorder.waitForTerminal()
        XCTAssertEqual(events.compactMap(\.packet).count, 5)
        XCTAssertEqual(events.last, .endOfStream)
    }

    func testAggregateByteBudgetBlocksProducerBeforeEventCapacityIsReached() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.byte-budget")
        let unblockDrain = DispatchSemaphore(value: 0)
        let drainBlocked = expectation(description: "byte-budget drain blocked")
        executor.submit {
            drainBlocked.fulfill()
            unblockDrain.wait()
        }
        wait(for: [drainBlocked], timeout: 2)

        let secondAttempted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1, 2])))
            secondAttempted.signal()
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([3, 4])))
            secondCompleted.signal()
            handle.emitTerminal(VPFF_EVENT_END)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(
            bridge: bridge,
            executor: executor,
            capacity: 4,
            maximumQueuedBytes: 3
        )
        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertEqual(secondAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 0.05), .timedOut)
        unblockDrain.signal()
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 2), .success)
        let events = recorder.waitForTerminal()
        XCTAssertEqual(events.compactMap(\.packet).map(\.data), [Data([1, 2]), Data([3, 4])])
        XCTAssertEqual(events.last, .endOfStream)
    }

    func testLargeReadyQueueYieldsToDecoderAndRendererCallbacksBeforeTerminal() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.fairness")
        let releaseExecutor = DispatchSemaphore(value: 0)
        let executorBlocked = expectation(description: "fairness executor blocked")
        executor.submit {
            executorBlocked.fulfill()
            releaseExecutor.wait()
        }
        wait(for: [executorBlocked], timeout: 2)

        let producerFinished = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            for index in 0..<64 {
                handle.emitPacket(.init(
                    streamIndex: Int32(index),
                    codec: VPFF_CODEC_H264,
                    data: Data([UInt8(index)])
                ))
            }
            handle.emitTerminal(VPFF_EVENT_END)
            producerFinished.signal()
            return 0
        }
        let events = LockedEventList()
        let callbackObservation = LockedOptionalInt()
        let terminal = expectation(description: "fairness terminal")
        let subject = FFmpegDemuxer(bridge: bridge, executor: executor)
        try subject.start(url: try httpURL()) { event in
            events.append(event)
            if events.snapshot.count == 1 {
                executor.submit {
                    callbackObservation.store(events.snapshot.count)
                }
            }
            if event.isTerminal { terminal.fulfill() }
        }

        XCTAssertEqual(producerFinished.wait(timeout: .now() + 2), .success)
        releaseExecutor.signal()
        wait(for: [terminal], timeout: 5)
        let drained = expectation(description: "fairness callbacks drained")
        executor.submit { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        let observedCount = try XCTUnwrap(callbackObservation.value)
        XCTAssertGreaterThan(observedCount, 0)
        XCTAssertLessThan(observedCount, 65, "media drain must yield before the terminal")
    }

    func testSingleEventLargerThanInjectedByteBudgetFailsInsteadOfWaitingForever() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1, 2, 3, 4])))
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(
            bridge: bridge,
            capacity: 4,
            maximumQueuedBytes: 3
        )

        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertEqual(
            recorder.waitForTerminal().last,
            .failure(.demuxRead(FFmpegDemuxer.oversizedValueErrorCode))
        )
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
        XCTAssertEqual(bridge.handle?.cancelCount, 1)
    }

    func testCancelWhileProducerIsBlockedClearsQueueAndEmitsExactlyOneCancelled() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.cancel-full")
        let unblockDrain = DispatchSemaphore(value: 0)
        executor.submit { unblockDrain.wait() }
        let fifthAttempted = DispatchSemaphore(value: 0)
        let producerReleased = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            for index in 0..<4 {
                handle.emitPacket(.init(streamIndex: Int32(index), codec: VPFF_CODEC_H264, data: Data([UInt8(index)])))
            }
            fifthAttempted.signal()
            handle.emitPacket(.init(streamIndex: 4, codec: VPFF_CODEC_H264, data: Data([4])))
            producerReleased.signal()
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, executor: executor, capacity: 4)
        try subject.start(url: try httpURL(), sink: recorder.record)
        XCTAssertEqual(fifthAttempted.wait(timeout: .now() + 2), .success)

        subject.cancel()
        XCTAssertEqual(producerReleased.wait(timeout: .now() + 2), .success)
        unblockDrain.signal()
        let events = recorder.waitForTerminal()
        XCTAssertEqual(events, [.cancelled])
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
    }

    func testCancelBeforeRunRepeatedCancelAndDoubleStartAreSafe() throws {
        let ioQueue = DispatchQueue(label: "org.vplayer.tests.demux.io-gated")
        let ioGate = DispatchSemaphore(value: 0)
        ioQueue.async { ioGate.wait() }
        let bridge = FakeFFmpegDemuxBridge { handle in
            XCTAssertTrue(handle.isCancelled)
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, ioQueue: ioQueue)
        try subject.start(url: try httpURL(), sink: recorder.record)

        XCTAssertThrowsError(try subject.start(url: try httpURL(), sink: recorder.record)) { error in
            XCTAssertEqual(error as? PlaybackCoreError, .demuxOpen(FFmpegDemuxer.doubleStartErrorCode))
        }
        subject.cancel()
        subject.cancel()
        ioGate.signal()

        XCTAssertEqual(recorder.waitForTerminal(), [.cancelled])
        XCTAssertGreaterThanOrEqual(bridge.handle?.cancelCount ?? 0, 1)
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testCancelAfterEndHasWonDoesNotCancelLiveNativeHandle() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.end-wins")
        let unblockDrain = DispatchSemaphore(value: 0)
        executor.submit { unblockDrain.wait() }
        let endEmitted = DispatchSemaphore(value: 0)
        let allowRunReturn = DispatchSemaphore(value: 0)
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitTerminal(VPFF_EVENT_END)
            endEmitted.signal()
            allowRunReturn.wait()
            return 0
        }
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge, executor: executor)
        try subject.start(url: try httpURL(), sink: recorder.record)
        XCTAssertEqual(endEmitted.wait(timeout: .now() + 2), .success)

        subject.cancel()

        XCTAssertEqual(bridge.handle?.cancelCount, 0)
        unblockDrain.signal()
        XCTAssertEqual(recorder.waitForTerminal(), [.endOfStream])
        subject.cancel()
        XCTAssertEqual(bridge.handle?.cancelCount, 0)
        allowRunReturn.signal()
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testDuplicateAndPostTerminalCallbacksAreIgnored() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1])))
            handle.emitTerminal(VPFF_EVENT_END)
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([2])))
            handle.emitTerminal(
                VPFF_EVENT_ERROR,
                errorKind: VPFF_DEMUX_ERROR_READ,
                ffmpegError: -1
            )
            return 0
        }

        let events = try run(bridge: bridge)

        XCTAssertEqual(events.compactMap(\.packet).map(\.data), [Data([1])])
        XCTAssertEqual(events.filter(\.isTerminal), [.endOfStream])
        XCTAssertEqual(events.last, .endOfStream)
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)
    }

    func testSinkReentrantCancelAndDeinitDoNotDeadlockOrUseFreedHandle() throws {
        let bridge = FakeFFmpegDemuxBridge { handle in
            handle.emitPacket(.init(codec: VPFF_CODEC_H264, data: Data([1])))
            XCTAssertTrue(handle.waitUntilCancelled())
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        let terminal = expectation(description: "reentrant cancel terminal")
        let events = LockedEventList()
        var subject: FFmpegDemuxer? = FFmpegDemuxer(bridge: bridge)
        let weakSubject = WeakDemuxerBox(subject)
        try subject?.start(url: try httpURL()) { event in
            events.append(event)
            if case .packet = event { weakSubject.value?.cancel() }
            if event.isTerminal { terminal.fulfill() }
        }
        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(events.snapshot.filter(\.isTerminal).count, 1)
        subject = nil
        XCTAssertEqual(waitForDestroy(bridge.handle), 1)

        let deinitBridge = FakeFFmpegDemuxBridge { handle in
            XCTAssertTrue(handle.waitUntilCancelled())
            handle.emitTerminal(VPFF_EVENT_CANCELLED)
            return 0
        }
        var deinitSubject: FFmpegDemuxer? = FFmpegDemuxer(bridge: deinitBridge)
        try deinitSubject?.start(url: try httpURL(), sink: { _ in })
        deinitSubject = nil
        XCTAssertEqual(waitForDestroy(deinitBridge.handle), 1)
    }

    func testOneThousandDeterministicLifecycleInterleavingsHaveOneTerminalAndOneDestroy() throws {
        let executor = PlaybackSerialExecutor(label: "org.vplayer.tests.demux.race.executor")
        let ioQueue = DispatchQueue(label: "org.vplayer.tests.demux.race.io")
        for iteration in 0..<1_000 {
            let bridge = FakeFFmpegDemuxBridge { handle in
                if handle.isCancelled {
                    handle.emitTerminal(VPFF_EVENT_CANCELLED)
                } else {
                    handle.emitTerminal(VPFF_EVENT_END)
                }
                return 0
            }
            let recorder = DemuxEventRecorder()
            let subject = FFmpegDemuxer(
                bridge: bridge,
                executor: executor,
                capacity: 4,
                ioQueue: ioQueue
            )
            try subject.start(url: try httpURL(), sink: recorder.record)
            if iteration.isMultiple(of: 2) { subject.cancel() }
            if iteration.isMultiple(of: 3) { subject.cancel() }
            let events = recorder.waitForTerminal()
            XCTAssertEqual(events.filter(\.isTerminal).count, 1, "iteration \(iteration)")
            if let terminalIndex = events.firstIndex(where: \.isTerminal) {
                XCTAssertEqual(terminalIndex, events.index(before: events.endIndex))
            }
            XCTAssertEqual(waitForDestroy(bridge.handle), 1, "iteration \(iteration)")
        }
    }

    func testLiveCCreateRejectsEmbeddedNULAndNonHTTPAndCancelBeforeRunAvoidsNetwork() {
        var handle: OpaquePointer?
        let invalidURLs: [[UInt8]] = [
            Array("file:///tmp/a.ts".utf8),
            Array("http://example.invalid/a".utf8) + [0] + Array(".ts".utf8),
        ]
        for bytes in invalidURLs {
            handle = nil
            let result = bytes.withUnsafeBufferPointer { buffer in
                vp_ffmpeg_demuxer_create(
                    buffer.baseAddress,
                    buffer.count,
                    10_000_000,
                    cDemuxSmokeCallback,
                    nil,
                    &handle
                )
            }
            XCTAssertLessThan(result, 0)
            XCTAssertNil(handle)
        }

        let recorder = CSmokeRecorder()
        let context = Unmanaged.passUnretained(recorder).toOpaque()
        let bytes = Array("http://127.0.0.1:1/never-opened.ts".utf8)
        handle = nil
        let createResult = bytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                context,
                &handle
            )
        }
        XCTAssertEqual(createResult, 0)
        guard let lowercaseHandle = handle else { return XCTFail("missing live C handle") }
        vp_ffmpeg_demuxer_cancel(lowercaseHandle)
        XCTAssertEqual(vp_ffmpeg_demuxer_run(lowercaseHandle), 0)
        vp_ffmpeg_demuxer_destroy(lowercaseHandle)
        XCTAssertEqual(recorder.kinds, [Int(VPFF_EVENT_CANCELLED.rawValue)])

        let uppercaseBytes = Array("HTTPS://127.0.0.1:1/never-opened.ts".utf8)
        handle = nil
        let uppercaseResult = uppercaseBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                context,
                &handle
            )
        }
        XCTAssertEqual(uppercaseResult, 0)
        guard let uppercaseHandle = handle else { return XCTFail("missing uppercase live C handle") }
        vp_ffmpeg_demuxer_cancel(uppercaseHandle)
        XCTAssertEqual(vp_ffmpeg_demuxer_run(uppercaseHandle), 0)
        vp_ffmpeg_demuxer_destroy(uppercaseHandle)
        XCTAssertEqual(
            recorder.kinds,
            [Int(VPFF_EVENT_CANCELLED.rawValue), Int(VPFF_EVENT_CANCELLED.rawValue)]
        )
    }

    func testLiveCCreateRejectsNullEmptyInvalidUTF8OversizedAndNonpositiveTimeout() {
        var handle: OpaquePointer?
        let validBytes = Array("https://example.invalid/live.ts".utf8)

        XCTAssertLessThan(
            vp_ffmpeg_demuxer_create(
                nil,
                1,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            ),
            0
        )
        let emptyResult = [UInt8]().withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                0,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(emptyResult, 0)
        let invalidUTF8Result = [UInt8(0xC0), UInt8(0xAF)].withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(invalidUTF8Result, 0)
        let oversizedBytes = Array("https://".utf8) + Array(repeating: UInt8(ascii: "a"), count: 64 * 1_024)
        let oversizedResult = oversizedBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(oversizedResult, 0)
        let timeoutResult = validBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                0,
                cDemuxSmokeCallback,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(timeoutResult, 0)
        let nilCallbackResult = validBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                nil,
                nil,
                &handle
            )
        }
        XCTAssertLessThan(nilCallbackResult, 0)
        let nilOutputResult = validBytes.withUnsafeBufferPointer { buffer in
            vp_ffmpeg_demuxer_create(
                buffer.baseAddress,
                buffer.count,
                10_000_000,
                cDemuxSmokeCallback,
                nil,
                nil
            )
        }
        XCTAssertLessThan(nilOutputResult, 0)
        XCTAssertNil(handle)
    }

    private func run(bridge: FakeFFmpegDemuxBridge) throws -> [DemuxEvent] {
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: bridge)
        try subject.start(url: try httpURL(), sink: recorder.record)
        return recorder.waitForTerminal()
    }

    private func run(extrasBridge: Task11ExtrasDemuxBridge) throws -> [DemuxEvent] {
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: extrasBridge)
        try subject.start(url: try httpURL(), sink: recorder.record)
        return recorder.waitForTerminal()
    }

#if DEBUG
    private func run(
        productionExtrasBridge: Task11ProductionExtrasDemuxBridge
    ) throws -> [DemuxEvent] {
        let recorder = DemuxEventRecorder()
        let subject = FFmpegDemuxer(bridge: productionExtrasBridge)
        try subject.start(url: try httpURL(), sink: recorder.record)
        return recorder.waitForTerminal()
    }
#endif

    private func httpURL() throws -> URL {
        try XCTUnwrap(URL(string: "https://example.invalid/live.ts"))
    }

    private func waitForDestroy(_ handle: FakeFFmpegDemuxHandle?, timeout: TimeInterval = 5) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, handle?.destroyCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        return handle?.destroyCount ?? 0
    }

    private func waitForDestroy(_ handle: Task11ExtrasDemuxHandle?, timeout: TimeInterval = 5) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, handle?.destroyCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        return handle?.destroyCount ?? 0
    }
}

private final class Task22LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    func set(_ value: Value) { lock.withLock { stored = value } }
    var value: Value { lock.withLock { stored } }
}

private final class AdmittedDemuxEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AdmittedDemuxEvent] = []

    func append(_ value: AdmittedDemuxEvent) {
        lock.withLock { values.append(value) }
    }

    func assertPacketData(
        _ expected: [Data],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        lock.withLock {
            let actual = values.compactMap { envelope in
                var data: Data?
                envelope.withBorrowedEvent { data = $0.packet?.data }
                return data
            }
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    func assertFirstPacketBorrowSupportsSmallDataSliceAndCOW(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        lock.withLock {
            guard let first = values.first else { return XCTFail("missing owner", file: file, line: line) }
            first.withBorrowedEvent { event in
                guard var data = event.packet?.data else {
                    return XCTFail("missing packet", file: file, line: line)
                }
                XCTAssertEqual(data, Data([1, 2]), file: file, line: line)
                XCTAssertEqual(data[0..<1], Data([1]), file: file, line: line)
                data[0] = 9
                XCTAssertEqual(data, Data([9, 2]), file: file, line: line)
            }
        }
    }

    func assertFirstPacketData(
        _ expected: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        lock.withLock {
            guard let first = values.first else { return XCTFail("missing owner", file: file, line: line) }
            first.withBorrowedEvent {
                XCTAssertEqual($0.packet?.data, expected, file: file, line: line)
            }
        }
    }

    func assertFirstTrackExtradata(
        video: Data,
        audio: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        lock.withLock {
            guard let first = values.first else { return XCTFail("missing owner", file: file, line: line) }
            first.withBorrowedEvent { event in
                guard case let .tracks(tracks) = event else {
                    return XCTFail("missing tracks", file: file, line: line)
                }
                XCTAssertEqual(tracks.video?.extradata, video, file: file, line: line)
                XCTAssertEqual(tracks.audio?.extradata, audio, file: file, line: line)
            }
        }
    }

    func removeFirstOwner() { lock.withLock { _ = values.removeFirst() } }

    func removeAll() {
        lock.withLock { values.removeAll(keepingCapacity: false) }
    }
}

private final class AdmittedDemuxPayloadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvent: DemuxEvent?

    var event: DemuxEvent? { lock.withLock { storedEvent } }

    func record(_ event: DemuxEvent) { lock.withLock { storedEvent = event } }
}

private final class DemuxerCancelBox: @unchecked Sendable {
    private weak var subject: FFmpegDemuxer?

    init(_ subject: FFmpegDemuxer) { self.subject = subject }
    func cancel() { subject?.cancel() }
}

private final class DemuxTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

private final class DemuxAdmissionGateProbe: DemuxDataPlaneAdmitting, @unchecked Sendable {
    private let condition = NSCondition()
    private let base: HLSDataPlaneAdmission
    private var attemptCount = 0

    init(_ base: HLSDataPlaneAdmission) { self.base = base }

    func waitForAdmission(bytes: Int, applicationBytes: Int)
        -> DemuxDataPlaneAdmissionResult {
        condition.withLock {
            attemptCount += 1
            condition.broadcast()
        }
        return base.waitForAdmission(bytes: bytes, applicationBytes: applicationBytes)
    }

    func cancel() { base.cancel() }

    func waitUntilAttemptCount(_ expected: Int, timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while attemptCount < expected, condition.wait(until: deadline) {}
        return attemptCount >= expected
    }
}

#if DEBUG
private func runBootstrapDebugScenario(
    _ scenario: VPFFBootstrapDebugScenario
) -> (status: Int32, details: VPFFBootstrapDebugResult) {
    var details = VPFFBootstrapDebugResult()
    let status = vp_ffmpeg_demuxer_debug_run_bootstrap(scenario, &details)
    return (status, details)
}

private final class Task11ProductionExtrasDemuxBridge: FFmpegDemuxBridging, @unchecked Sendable {
    private let scenario: VPFFTrackExtrasDebugScenario

    init(scenario: VPFFTrackExtrasDebugScenario) {
        self.scenario = scenario
    }

    func create(
        urlBytes _: Data,
        timeoutUS _: Int64,
        receiver _: @escaping RawFFmpegDemuxReceiver
    ) -> FFmpegDemuxCreateResult {
        .failure(-11)
    }

    func createV2(
        urlBytes _: Data,
        timeoutUS _: Int64,
        receiver: @escaping RawFFmpegDemuxReceiverV2
    ) -> FFmpegDemuxCreateResult {
        .success(Task11ProductionExtrasDemuxHandle(scenario: scenario, receiver: receiver))
    }
}

private final class Task11ProductionExtrasDemuxHandle: FFmpegDemuxHandle, @unchecked Sendable {
    let scenario: VPFFTrackExtrasDebugScenario
    let receiver: RawFFmpegDemuxReceiverV2

    init(scenario: VPFFTrackExtrasDebugScenario, receiver: @escaping RawFFmpegDemuxReceiverV2) {
        self.scenario = scenario
        self.receiver = receiver
    }

    func run() -> Int32 {
        vp_ffmpeg_demuxer_debug_emit_track_extras(
            scenario,
            task11ProductionExtrasCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func cancel() {}
    func destroy() {}
}

private func task11ProductionExtrasCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?,
    _ extras: UnsafePointer<VPFFDemuxEventExtras>?
) {
    guard let context, let event else { return }
    Unmanaged<Task11ProductionExtrasDemuxHandle>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receiver(event, extras)
}
#endif

private enum Task11MalformedExtras: Sendable, Equatable {
    case version
    case size
    case offset
    case presence
    case utf8
    case sampleAspectRatio
    case masteringDisplay
    case masteringChromaticity
    case contentLightLevel
}

private enum Task22MalformedV2PrimaryEvidence: String, CaseIterable, Sendable {
    case unknownVersion
    case shortSize
    case nonBooleanPresence
    case mismatchedSelectedStream
    case mismatchedProgramIdentity
    case inconsistentCounts
}

private final class Task11ExtrasDemuxBridge: FFmpegDemuxBridging, @unchecked Sendable {
    typealias RunScript = @Sendable (Task11ExtrasDemuxHandle) -> Int32

    private let lock = NSLock()
    private let runScript: RunScript
    private var storedHandle: Task11ExtrasDemuxHandle?

    init(runScript: @escaping RunScript) {
        self.runScript = runScript
    }

    func create(
        urlBytes _: Data,
        timeoutUS _: Int64,
        receiver _: @escaping RawFFmpegDemuxReceiver
    ) -> FFmpegDemuxCreateResult {
        .failure(-11)
    }

    func createV2(
        urlBytes _: Data,
        timeoutUS _: Int64,
        receiver: @escaping RawFFmpegDemuxReceiverV2
    ) -> FFmpegDemuxCreateResult {
        let handle = Task11ExtrasDemuxHandle(receiver: receiver, runScript: runScript)
        lock.withLock { storedHandle = handle }
        return .success(handle)
    }

    var handle: Task11ExtrasDemuxHandle? {
        lock.withLock { storedHandle }
    }
}

private final class Task11ExtrasDemuxHandle: FFmpegDemuxHandle, @unchecked Sendable {
    private let lock = NSLock()
    private let receiver: RawFFmpegDemuxReceiverV2
    private let runScript: Task11ExtrasDemuxBridge.RunScript
    private var storedCancelCount = 0
    private var storedDestroyCount = 0

    init(
        receiver: @escaping RawFFmpegDemuxReceiverV2,
        runScript: @escaping Task11ExtrasDemuxBridge.RunScript
    ) {
        self.receiver = receiver
        self.runScript = runScript
    }

    func run() -> Int32 { runScript(self) }
    func cancel() { lock.withLock { storedCancelCount += 1 } }
    func destroy() { lock.withLock { storedDestroyCount += 1 } }

    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var destroyCount: Int { lock.withLock { storedDestroyCount } }

    func emitTracks(
        video: Bool,
        audio: Bool,
        kind: VPFFDemuxEventKind = VPFF_EVENT_TRACKS,
        reason: VPFFDemuxDiscontinuityReason = VPFF_DISCONTINUITY_NONE,
        videoLanguage: [UInt8] = [],
        audioLanguage: [UInt8] = [],
        configure: (inout VPFFDemuxEventExtrasV1) -> Void
    ) {
        emitTracks(
            video: video,
            audio: audio,
            kind: kind,
            reason: reason,
            videoLanguage: videoLanguage,
            audioLanguage: audioLanguage,
            malformed: nil,
            configure: configure
        )
    }

    func emitMalformedTracks(_ malformed: Task11MalformedExtras) {
        emitTracks(
            video: true,
            audio: false,
            videoLanguage: malformed == .utf8 ? [0xC0, 0xAF] : [],
            malformed: malformed
        ) { extras in
            switch malformed {
            case .presence:
                extras.video.presence = 1 << 63
            case .utf8:
                extras.video.presence = 1 << 1
            case .sampleAspectRatio:
                extras.video.presence = 1 << 4
                extras.video.sample_aspect_ratio = .init(num: 4, den: 0)
            case .masteringDisplay:
                extras.video.presence = 1 << 10
                Self.fillMasteringDisplay(&extras.video)
                extras.video.mastering_display_maximum_luminance.den = 0
            case .masteringChromaticity:
                extras.video.presence = 1 << 10
                Self.fillMasteringDisplay(&extras.video)
                extras.video.mastering_display_red_x = .init(num: 2, den: 1)
            case .contentLightLevel:
                extras.video.presence = 1 << 11
                extras.video.maximum_content_light_level = 400
                extras.video.maximum_frame_average_light_level = 1_000
            case .version, .size, .offset:
                break
            }
        }
    }

    func emitMalformedV2PrimaryEvidence(_ malformed: Task22MalformedV2PrimaryEvidence) {
        var event = VPFFDemuxEvent()
        event.kind = VPFF_EVENT_TRACKS
        event.has_program_id = 1
        event.selected_program_id = 1
        event.audio = Self.audioTrack(present: true)

        var extras = VPFFDemuxEventExtrasV2()
        extras.header.version = 2
        extras.header.size = UInt32(MemoryLayout<VPFFDemuxEventExtrasV2>.size)
        extras.header.audio_track_offset = UInt32(MemoryLayout<VPFFDemuxEventExtrasV1>.offset(of: \.audio)!)
        extras.has_audio_primary_evidence = 1
        extras.audio_primary_evidence.version = 1
        extras.audio_primary_evidence.scope = VPFF_AUDIO_PRIMARY_SCOPE_PROGRAM
        extras.audio_primary_evidence.program_index = 0
        extras.audio_primary_evidence.program_id = 1
        extras.audio_primary_evidence.selected_stream_index = 8
        extras.audio_primary_evidence.audio_stream_count = 2
        extras.audio_primary_evidence.default_audio_stream_count = 0
        extras.audio_primary_evidence.explicit_main_stream_count = 1
        extras.audio_primary_evidence.unclassifiable_role_stream_count = 0
        extras.audio_primary_evidence.primary_basis = VPFF_AUDIO_PRIMARY_EXPLICIT_MAIN

        switch malformed {
        case .unknownVersion:
            extras.header.version = 3
        case .shortSize:
            extras.header.size -= 1
        case .nonBooleanPresence:
            extras.has_audio_primary_evidence = 2
        case .mismatchedSelectedStream:
            extras.audio_primary_evidence.selected_stream_index = 9
        case .mismatchedProgramIdentity:
            extras.audio_primary_evidence.program_id = 2
        case .inconsistentCounts:
            extras.audio_primary_evidence.default_audio_stream_count = 3
        }

        withUnsafePointer(to: &event) { eventPointer in
            withUnsafePointer(to: &extras.header) { extrasPointer in
                receiver(eventPointer, extrasPointer)
            }
        }
    }

    func emitTerminal() {
        var event = VPFFDemuxEvent()
        event.kind = VPFF_EVENT_END
        withUnsafePointer(to: &event) { receiver($0, nil) }
    }

    static func fillMasteringDisplay(_ track: inout VPFFTrackExtrasV1) {
        track.mastering_display_red_x = .init(num: 17, den: 50)
        track.mastering_display_red_y = .init(num: 33, den: 100)
        track.mastering_display_green_x = .init(num: 13, den: 50)
        track.mastering_display_green_y = .init(num: 69, den: 100)
        track.mastering_display_blue_x = .init(num: 3, den: 20)
        track.mastering_display_blue_y = .init(num: 3, den: 50)
        track.mastering_display_white_point_x = .init(num: 3127, den: 10_000)
        track.mastering_display_white_point_y = .init(num: 329, den: 1_000)
        track.mastering_display_minimum_luminance = .init(num: 1, den: 10_000)
        track.mastering_display_maximum_luminance = .init(num: 1_000, den: 1)
    }

    private func emitTracks(
        video: Bool,
        audio: Bool,
        kind: VPFFDemuxEventKind = VPFF_EVENT_TRACKS,
        reason: VPFFDemuxDiscontinuityReason = VPFF_DISCONTINUITY_NONE,
        videoLanguage: [UInt8] = [],
        audioLanguage: [UInt8] = [],
        malformed: Task11MalformedExtras?,
        configure: (inout VPFFDemuxEventExtrasV1) -> Void
    ) {
        var mutableVideoLanguage = videoLanguage
        var mutableAudioLanguage = audioLanguage
        mutableVideoLanguage.withUnsafeBufferPointer { videoBytes in
            mutableAudioLanguage.withUnsafeBufferPointer { audioBytes in
                emitTracks(
                    video: video,
                    audio: audio,
                    kind: kind,
                    reason: reason,
                    videoLanguage: videoBytes,
                    audioLanguage: audioBytes,
                    malformed: malformed,
                    configure: configure
                )
            }
        }
        mutableVideoLanguage.indices.forEach { mutableVideoLanguage[$0] = 0xEE }
        mutableAudioLanguage.indices.forEach { mutableAudioLanguage[$0] = 0xEE }
    }

    private func emitTracks(
        video: Bool,
        audio: Bool,
        kind: VPFFDemuxEventKind,
        reason: VPFFDemuxDiscontinuityReason,
        videoLanguage: UnsafeBufferPointer<UInt8>,
        audioLanguage: UnsafeBufferPointer<UInt8>,
        malformed: Task11MalformedExtras?,
        configure: (inout VPFFDemuxEventExtrasV1) -> Void
    ) {
        var event = VPFFDemuxEvent()
        event.kind = kind
        event.video = Self.videoTrack(present: video)
        event.audio = Self.audioTrack(present: audio)
        event.discontinuity_reason = reason

        var extras = VPFFDemuxEventExtrasV1()
        extras.header.version = VPFF_DEMUX_EVENT_EXTRAS_VERSION_1
        extras.header.size = 320
        extras.header.video_track_offset = video ? 16 : 0
        extras.header.audio_track_offset = audio ? 168 : 0
        configure(&extras)
        extras.video.language = videoLanguage.isEmpty ? nil : videoLanguage.baseAddress
        extras.video.language_size = videoLanguage.count
        extras.audio.language = audioLanguage.isEmpty ? nil : audioLanguage.baseAddress
        extras.audio.language_size = audioLanguage.count

        switch malformed {
        case .version: extras.header.version = 99
        case .size: extras.header.size = 319
        case .offset: extras.header.video_track_offset = 17
        case .presence, .utf8, .sampleAspectRatio, .masteringDisplay,
             .masteringChromaticity, .contentLightLevel, nil:
            break
        }

        withUnsafePointer(to: &event) { eventPointer in
            withUnsafePointer(to: &extras.header) { extrasPointer in
                receiver(eventPointer, extrasPointer)
            }
        }
    }

    private static func videoTrack(present: Bool) -> VPFFTrack {
        var track = VPFFTrack()
        guard present else { return track }
        track.present = 1
        track.stream_index = 7
        track.codec = VPFF_CODEC_H264
        track.time_base_num = 1
        track.time_base_den = 90_000
        track.width = 1_920
        track.height = 1_080
        return track
    }

    private static func audioTrack(present: Bool) -> VPFFTrack {
        var track = VPFFTrack()
        guard present else { return track }
        track.present = 1
        track.stream_index = 8
        track.codec = VPFF_CODEC_AAC
        track.time_base_num = 1
        track.time_base_den = 48_000
        track.sample_rate = 48_000
        track.channel_count = 2
        track.channel_order = VPFF_CHANNEL_ORDER_NATIVE
        track.has_channel_layout_mask = 1
        track.channel_layout_mask = 3
        return track
    }
}

private final class WeakDemuxerBox: @unchecked Sendable {
    weak var value: FFmpegDemuxer?

    init(_ value: FFmpegDemuxer?) {
        self.value = value
    }
}

private final class LockedEventList: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DemuxEvent] = []

    func append(_ event: DemuxEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [DemuxEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class LockedOptionalInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    func store(_ value: Int) {
        lock.withLock { stored = value }
    }

    var value: Int? {
        lock.withLock { stored }
    }
}

private final class CSmokeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedKinds: [Int] = []

    func append(_ kind: Int) {
        lock.lock()
        storedKinds.append(kind)
        lock.unlock()
    }

    var kinds: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedKinds
    }
}

private func cDemuxSmokeCallback(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<VPFFDemuxEvent>?
) {
    guard let context, let event else { return }
    Unmanaged<CSmokeRecorder>.fromOpaque(context).takeUnretainedValue().append(Int(event.pointee.kind.rawValue))
}

private extension RawTrackSpec {
    static func h264(
        width: Int32 = 1_920,
        videoDelay: Int32 = 1,
        frameRateNum: Int32 = 0,
        frameRateDen: Int32 = 0,
        fieldOrder: UInt8 = 0,
        extradata: Data = Data([1, 2, 3])
    ) -> Self {
        .init(
            streamIndex: 7,
            codec: VPFF_CODEC_H264,
            width: width,
            height: 1_080,
            videoDelay: videoDelay,
            fieldOrder: fieldOrder,
            frameRateNum: frameRateNum,
            frameRateDen: frameRateDen,
            extradata: extradata
        )
    }

    static func aac(
        channelOrder: VPFFChannelOrder = VPFF_CHANNEL_ORDER_NATIVE,
        hasMask: Bool = true,
        mask: UInt64 = 3,
        extradata: Data = Data([0x12, 0x10])
    ) -> Self {
        .init(
            streamIndex: 8,
            codec: VPFF_CODEC_AAC,
            sampleRate: 48_000,
            channelCount: 2,
            channelOrder: channelOrder,
            hasChannelLayoutMask: hasMask,
            channelLayoutMask: mask,
            extradata: extradata
        )
    }

    static var unsupportedAudio: Self {
        .init(
            streamIndex: 8,
            codec: VPFF_CODEC_UNSUPPORTED,
            sampleRate: 48_000,
            channelCount: 2
        )
    }

    static var unsupportedVideo: Self {
        .init(
            streamIndex: 7,
            codec: VPFF_CODEC_UNSUPPORTED,
            width: 1_920,
            height: 1_080
        )
    }
}

private extension DemuxEvent {
    var packet: DemuxPacket? {
        guard case let .packet(packet) = self else { return nil }
        return packet
    }

    var isTerminal: Bool {
        switch self {
        case .endOfStream, .cancelled, .failure:
            true
        case .tracks, .packet, .discontinuity:
            false
        }
    }
}
