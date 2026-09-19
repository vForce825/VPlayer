// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import VPlayerPlayback

final class SegmentedFMP4WriterTests: XCTestCase {
    func testTrackBundlesUseIndependentOneInputHLSWritersAndRetainDelegate() throws {
        let factory = Task17FakeSystemWriterFactory()
        var writers: [SegmentedFMP4Writer?] = []
        for (offset, kind) in [
            SegmentedFMP4TrackKind.video,
            .aac,
            .ac3,
            .eac3,
        ].enumerated() {
            writers.append(try Task17Fixtures.makeWriter(
                seed: UInt64(100 + offset),
                kind: kind,
                factory: factory
            ))
        }

        XCTAssertEqual(factory.configurations.count, 4)
        XCTAssertEqual(Set(factory.systemWriterIdentities).count, 4)
        for (configuration, kind) in zip(factory.configurations, [
            SegmentedFMP4TrackKind.video,
            .aac,
            .ac3,
            .eac3,
        ]) {
            XCTAssertEqual(configuration.contentTypeIdentifier, UTType.mpeg4Movie.identifier)
            XCTAssertEqual(configuration.outputFileTypeProfile, AVFileTypeProfile.mpeg4AppleHLS.rawValue)
            XCTAssertTrue(CMTIME_IS_INDEFINITE(configuration.preferredOutputSegmentInterval))
            XCTAssertEqual(configuration.mediaType, kind == .video ? .video : .audio)
            XCTAssertTrue(configuration.outputSettingsAreNil)
            XCTAssertNotNil(configuration.sourceFormatHintIdentity)
            XCTAssertEqual(configuration.inputCount, 1)
            XCTAssertEqual(configuration.videoMediaTimeScale, 720_000)
        }
        XCTAssertEqual(Set(factory.delegateObjectIdentifiers.compactMap { $0 }).count, 4)
        writers.removeAll()
        XCTAssertTrue(factory.delegateObjectIdentifiers.allSatisfy { $0 == nil })
    }

    func testVideoBoundaryMatrixFlushesBeforeNextIDRAppend() throws {
        let oneTick = CMTime(value: 1, timescale: 90_000)
        let start = CMTime(value: 900_000, timescale: 90_000)
        let cases: [(CMTime, Bool, Bool)] = [
            (CMTimeSubtract(CMTimeAdd(start, CMTime(seconds: 1, preferredTimescale: 90_000)), oneTick), true, false),
            (CMTimeAdd(start, CMTime(seconds: 1, preferredTimescale: 90_000)), true, true),
            (CMTimeAdd(start, CMTime(seconds: 2, preferredTimescale: 90_000)), true, true),
        ]
        for (offset, entry) in cases.enumerated() {
            let boundary = try SegmentBoundaryCoordinator(
                mode: .audioVideo(epochStart: start, videoMode: .passthrough)
            )
            _ = try boundary.inspectVideoBoundary(at: start, isIDR: true)
            let action = try boundary.inspectVideoBoundary(at: entry.0, isIDR: entry.1)
            XCTAssertEqual(action.requiresFlushBeforeAppend, entry.2)
            XCTAssertEqual(action.logicalSequence, entry.2 ? 1 : 0)

            let factory = Task17FakeSystemWriterFactory()
            let fixture = try Task17Fixtures.realH264Sample(
                presentationTimeStamp: entry.0,
                duration: CMTime(value: 3_000, timescale: 90_000)
            )
            let writerBoundary = try SegmentBoundaryCoordinator(
                mode: .audioVideo(epochStart: start, videoMode: .passthrough)
            )
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(200 + offset),
                kind: .video,
                sourceFormatHint: fixture.format,
                boundary: writerBoundary,
                factory: factory
            )
            let firstFixture = try Task17Fixtures.realH264Sample(
                presentationTimeStamp: start,
                duration: CMTime(value: 3_000, timescale: 90_000)
            )
            let firstOutput = Task17Fixtures.videoOutput(
                fixture: firstFixture,
                generation: UInt64(200 + offset),
                accessUnitID: 1,
                sequenceNumber: 1
            )
            try writer.start(at: start)
            try writer.appendVideo(
                firstOutput,
                ticket: try writerBoundary.issueVideoAppend(
                    for: firstOutput,
                    writerBinding: writer.binding
                )
            )
            let output = Task17Fixtures.videoOutput(
                fixture: fixture,
                generation: UInt64(200 + offset),
                accessUnitID: 2,
                sequenceNumber: 2
            )
            try writer.appendVideo(
                output,
                ticket: try writerBoundary.issueVideoAppend(
                    for: output,
                    writerBinding: writer.binding
                )
            )
            if entry.2 {
                XCTAssertEqual(Array(factory.lastWriter?.calls.suffix(2) ?? []), [.flush, .append])
            } else {
                XCTAssertEqual(factory.lastWriter?.calls.last, .append)
            }
            _ = writer.cancel()
        }

        let tooLate = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: start, videoMode: .passthrough)
        )
        _ = try tooLate.inspectVideoBoundary(at: start, isIDR: true)
        XCTAssertThrowsError(try tooLate.inspectVideoBoundary(
            at: CMTimeAdd(CMTimeAdd(start, CMTime(seconds: 2, preferredTimescale: 90_000)), oneTick),
            isIDR: true
        )) { error in
            XCTAssertEqual(error as? SegmentBoundaryFailure, .videoBoundaryExceeded)
        }

        let reencoded = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: start, videoMode: .reencodedClosedGOP)
        )
        _ = try reencoded.inspectVideoBoundary(at: start, isIDR: true)
        XCTAssertTrue(try reencoded.inspectVideoBoundary(
            at: CMTimeAdd(start, CMTime(seconds: 1, preferredTimescale: 90_000)),
            isIDR: true
        ).requiresFlushBeforeAppend)
        XCTAssertThrowsError(try reencoded.inspectVideoBoundary(
            at: CMTimeAdd(CMTimeAdd(start, CMTime(seconds: 1, preferredTimescale: 90_000)), oneTick),
            isIDR: true
        ))
    }

    func testAudioRenditionsFlushAtFirstWholeAUWithinOneUnit() throws {
        let start = CMTime(value: 480_000, timescale: 48_000)
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: start, videoMode: .passthrough)
        )
        _ = try boundary.inspectVideoBoundary(at: start, isIDR: true)
        _ = try boundary.inspectVideoBoundary(at: CMTime(value: 528_000, timescale: 48_000), isIDR: true)

        let cases: [(AudioRenditionIdentity, SegmentAudioAccessUnitKind, Int64)] = [
            (.init(rawValue: 1), .aac(sampleRate: 48_000), 1_024),
            (.init(rawValue: 2), .ac3(sampleRate: 48_000), 1_536),
            (.init(rawValue: 3), .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536), 1_536),
        ]
        for (rendition, kind, samples) in cases {
            try boundary.registerAudioRendition(
                rendition,
                accessUnit: kind,
                firstEffectiveStart: start
            )
            let exact = try boundary.inspectAudioBoundary(
                rendition: rendition,
                at: CMTime(value: 528_000, timescale: 48_000)
            )
            XCTAssertTrue(exact.requiresFlushBeforeAppend)
            XCTAssertEqual(exact.logicalSequence, 1)

            let another = try SegmentBoundaryCoordinator(
                mode: .audioVideo(epochStart: start, videoMode: .passthrough)
            )
            _ = try another.inspectVideoBoundary(at: start, isIDR: true)
            _ = try another.inspectVideoBoundary(at: CMTime(value: 528_000, timescale: 48_000), isIDR: true)
            try another.registerAudioRendition(rendition, accessUnit: kind, firstEffectiveStart: start)
            let lastTick = try another.inspectAudioBoundary(
                rendition: rendition,
                at: CMTime(value: 528_000 + samples - 1, timescale: 48_000)
            )
            XCTAssertTrue(lastTick.requiresFlushBeforeAppend)
            XCTAssertThrowsError(try {
                let invalid = try SegmentBoundaryCoordinator(
                    mode: .audioVideo(epochStart: start, videoMode: .passthrough)
                )
                _ = try invalid.inspectVideoBoundary(at: start, isIDR: true)
                _ = try invalid.inspectVideoBoundary(at: CMTime(value: 528_000, timescale: 48_000), isIDR: true)
                try invalid.registerAudioRendition(rendition, accessUnit: kind, firstEffectiveStart: start)
                _ = try invalid.inspectAudioBoundary(
                    rendition: rendition,
                    at: CMTime(value: 528_000 + samples, timescale: 48_000)
                )
            }()) { error in
                XCTAssertEqual(error as? SegmentBoundaryFailure, .audioBoundaryExceeded)
            }
        }

        XCTAssertThrowsError(try boundary.registerAudioRendition(
            .init(rawValue: 99),
            accessUnit: .eac3Aggregated(sampleRate: 48_000, sampleCount: 768),
            firstEffectiveStart: start
        )) { error in
            XCTAssertEqual(error as? SegmentBoundaryFailure, .incompleteEAC3AccessUnit)
        }
    }

    func testSystemVTCadenceRejectsForwardGapAndDurationDrift() throws {
        let duration = CMTime(value: 1, timescale: 25)
        let exactDuration = try ExactMediaTime(duration)
        let expectedNextPTS = try ExactMediaTime(duration)
        let gapPTS = try ExactMediaTime(CMTime(value: 3, timescale: 25))
        let changedDuration = try ExactMediaTime(CMTime(value: 2, timescale: 25))
        XCTAssertFalse(SegmentedFMP4VideoCadencePolicy.strict.accepts(
            previousDuration: exactDuration,
            expectedNextPTS: expectedNextPTS,
            duration: exactDuration,
            presentationTimeStamp: gapPTS
        ))
        XCTAssertFalse(SegmentedFMP4VideoCadencePolicy.strict.accepts(
            previousDuration: exactDuration,
            expectedNextPTS: expectedNextPTS,
            duration: changedDuration,
            presentationTimeStamp: expectedNextPTS
        ))
    }

    func testAudioVideoBoundaryRetainsColdStartSkewUntilAudioCatchesUp() throws {
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let rendition = AudioRenditionIdentity(rawValue: 243)
        try boundary.registerAudioRendition(
            rendition,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: .zero
        )

        for second in 0...8 {
            XCTAssertNoThrow(try boundary.inspectVideoBoundary(
                at: CMTime(value: Int64(second), timescale: 1),
                isIDR: true
            ))
        }
        for second in 0...8 {
            XCTAssertNoThrow(try boundary.inspectAudioBoundary(
                rendition: rendition,
                at: CMTime(value: Int64(second), timescale: 1)
            ), "视频先到达时，音频仍必须能消费尚未超过冷启动上限的共同边界")
        }
        XCTAssertLessThanOrEqual(boundary.inspectionUsage.commonBoundarySlotCount, 16)
    }

    func testPublicationContinuityUsesSameBoundedAudioAndVideoToleranceAtEveryLayer()
        throws {
        let end = try ExactMediaTime(CMTime(value: 17, timescale: 1))
        XCTAssertTrue(HLSSegmentContinuity.accepts(
            previousEnd: end,
            nextStart: try ExactMediaTime(CMTime(value: 12_763, timescale: 750)),
            mediaType: .audio,
            accessUnitDuration: try ExactMediaTime(CMTime(value: 8, timescale: 375)),
            hasPublicationEvidence: true
        ), "AAC 完整 AU 对齐产生的 17ms 偏移必须在 coverage 层保持合法")
        XCTAssertFalse(HLSSegmentContinuity.accepts(
            previousEnd: end,
            nextStart: try ExactMediaTime(CMTime(value: 137, timescale: 8)),
            mediaType: .audio,
            accessUnitDuration: try ExactMediaTime(CMTime(value: 8, timescale: 375)),
            hasPublicationEvidence: true
        ))
        XCTAssertTrue(HLSSegmentContinuity.accepts(
            previousEnd: end,
            nextStart: try ExactMediaTime(CMTime(value: 427, timescale: 25)),
            mediaType: .video,
            accessUnitDuration: nil,
            hasPublicationEvidence: true
        ))
        XCTAssertFalse(HLSSegmentContinuity.accepts(
            previousEnd: end,
            nextStart: try ExactMediaTime(CMTime(value: 428, timescale: 25)),
            mediaType: .video,
            accessUnitDuration: nil,
            hasPublicationEvidence: true
        ))
    }

    func testInterlacedOutputWatermarkUsesDecodedFramesRatherThanSubmittedAccessUnits() {
        XCTAssertNil(HLSInterlacedOutputWatermark.targetOutputCount(
            decodedFrameCount: 30,
            outputFramesPerDecodedFrame: 1
        ))
        XCTAssertEqual(
            HLSInterlacedOutputWatermark.targetOutputCount(
                decodedFrameCount: 31,
                outputFramesPerDecodedFrame: 1
            ),
            1
        )
        XCTAssertEqual(
            HLSInterlacedOutputWatermark.targetOutputCount(
                decodedFrameCount: 270,
                outputFramesPerDecodedFrame: 1
            ),
            240,
            "无解码输出的压缩 AU 不得永久抬高输出水位"
        )
        XCTAssertEqual(
            HLSInterlacedOutputWatermark.targetOutputCount(
                decodedFrameCount: 31,
                outputFramesPerDecodedFrame: 2
            ),
            2,
            "保留双场的调用方仍按每个解码帧两个输出计算"
        )
    }

    func testInterlacedOutputFrameRateDoublesSourceFrameCadence() throws {
        XCTAssertEqual(
            HLSInterlacedYADIFPolicy.outputFrameRate(
                for: try XCTUnwrap(MediaRational(num: 25, den: 1))
            ),
            MediaRational(num: 50, den: 1)
        )
        XCTAssertEqual(
            HLSInterlacedYADIFPolicy.outputFrameRate(
                for: try XCTUnwrap(MediaRational(num: 30_000, den: 1_001))
            ),
            MediaRational(num: 60_000, den: 1_001)
        )
        XCTAssertNil(HLSInterlacedYADIFPolicy.outputFrameRate(
            for: try XCTUnwrap(MediaRational(num: Int32.max, den: 1))
        ))
    }

    func testAudioOnlyGridAndTrimmedEpochStartUseExactOneSecondBoundaries() throws {
        let start = CMTime(value: 480_000, timescale: 48_000)
        let coordinator = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let rendition = AudioRenditionIdentity(rawValue: 10)
        try coordinator.registerAudioRendition(
            rendition,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: start
        )
        XCTAssertFalse(try coordinator.inspectAudioBoundary(rendition: rendition, at: start).requiresFlushBeforeAppend)
        XCTAssertTrue(try coordinator.inspectAudioBoundary(
            rendition: rendition,
            at: CMTime(value: 528_511, timescale: 48_000)
        ).requiresFlushBeforeAppend)
        XCTAssertEqual(coordinator.inspectionCommonBoundaries, [
            ExactMediaTime(value: 10, timescale: 1),
            ExactMediaTime(value: 11, timescale: 1),
        ])

        let physicalPrimingStart = CMTime(value: 478_976, timescale: 48_000)
        let trimmed = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        XCTAssertNoThrow(try trimmed.registerAudioRendition(
            .init(rawValue: 11),
            accessUnit: .aac(sampleRate: 48_000),
            firstPhysicalStart: physicalPrimingStart,
            startTrimSamples: 1_024,
            firstEffectiveStart: start
        ))
        XCTAssertThrowsError(try trimmed.registerAudioRendition(
            .init(rawValue: 12),
            accessUnit: .aac(sampleRate: 48_000),
            firstPhysicalStart: physicalPrimingStart,
            startTrimSamples: 1_023,
            firstEffectiveStart: CMTime(value: 479_999, timescale: 48_000)
        )) { error in
            XCTAssertEqual(error as? SegmentBoundaryFailure, .firstEffectiveStartMismatch)
        }
    }

    func testRelayAcceptsOutOfOrderSynchronousAsynchronousAndSlowCurrentCallbacks() throws {
        let binding = Task17Fixtures.binding(seed: 300)
        let collector = Task17ObjectCollector()
        let relay = SegmentReportRelay(
            binding: binding,
            limits: .audio,
            capacity: 8,
            objectSink: collector.append
        )
        let tickets = try (0..<3).map {
            try relay.reserve(
                kind: .media,
                logicalSequence: UInt64($0),
                projectedByteCount: 32
            )
        }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "org.vplayer.tests.task17.callbacks", attributes: .concurrent)
        for index in [2, 0, 1] {
            group.enter()
            queue.async {
                if index == 1 { usleep(20_000) }
                let result = relay.receive(Task17Fixtures.delivery(
                    binding: binding,
                    ticket: tickets[index],
                    logicalSequence: UInt64(index),
                    byte: UInt8(index + 1)
                ))
                if case let .accepted(acceptance) = result {
                    XCTAssertTrue(relay.consumePublication(acceptance) { $0() })
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(collector.objects.map(\.logicalSequence).sorted(), [0, 1, 2])
        XCTAssertEqual(relay.usage.reservedSlots, 0)
        XCTAssertEqual(relay.usage.writerBacklogSegmentCount, 0)
        XCTAssertEqual(relay.usage.writerBacklogBytes, 0)
    }

    func testRelayRejectsDuplicateStaleAndMismatchedCallbacksAndZerosReservations() throws {
        let first = Task17Fixtures.binding(seed: 400, generation: 1)
        let second = Task17Fixtures.binding(seed: 400, generation: 2)
        let collector = Task17ObjectCollector()
        let relay = SegmentReportRelay(binding: first, limits: .audio, capacity: 8, objectSink: collector.append)
        let acceptedTicket = try relay.reserve(kind: .media, logicalSequence: 0, projectedByteCount: 8)
        let accepted = Task17Fixtures.delivery(binding: first, ticket: acceptedTicket, logicalSequence: 0, byte: 1)
        guard case let .accepted(acceptance) = relay.receive(accepted) else {
            return XCTFail("首个 callback 必须被 relay 接纳")
        }
        XCTAssertTrue(relay.consumePublication(acceptance) { $0() })
        XCTAssertEqual(relay.receive(accepted), .discarded)

        let staleTicket = try relay.reserve(kind: .media, logicalSequence: 1, projectedByteCount: 8)
        XCTAssertTrue(relay.rebind(to: second))
        XCTAssertEqual(relay.receive(Task17Fixtures.delivery(
            binding: first,
            ticket: staleTicket,
            logicalSequence: 1,
            byte: 2
        )), .fatal(.callbackIdentityMismatch))

        let wrongTicket = try relay.reserve(kind: .media, logicalSequence: 2, projectedByteCount: 8)
        var wrongWriter = Task17Fixtures.delivery(binding: second, ticket: wrongTicket, logicalSequence: 2, byte: 3)
        wrongWriter = wrongWriter.replacing(writerIdentity: FMP4WriterIdentity(rawValue: 999))
        XCTAssertEqual(relay.receive(wrongWriter), .fatal(.callbackIdentityMismatch))

        let wrongSequence = try relay.reserve(kind: .media, logicalSequence: 3, projectedByteCount: 8)
        XCTAssertEqual(relay.receive(Task17Fixtures.delivery(
            binding: second,
            ticket: wrongSequence,
            logicalSequence: 4,
            byte: 4
        )), .fatal(.callbackIdentityMismatch))

        XCTAssertEqual(collector.objects.count, 1)
        XCTAssertEqual(relay.usage.reservedSlots, 0)
        XCTAssertEqual(relay.usage.writerBacklogSegmentCount, 0)
        XCTAssertEqual(relay.usage.writerBacklogBytes, 0)
    }

    func testSystemFailuresAndIllegalOrderDoNotPublishAndReleaseOwnershipExactlyOnce() throws {
        let cases: [(Task17SystemFailurePoint, Int)] = [
            (.start, 0),
            (.readiness, 0),
            (.append, 1),
            (.flush, 1),
        ]
        for (offset, entry) in cases.enumerated() {
            let factory = Task17FakeSystemWriterFactory(failurePoint: entry.0)
            let collector = Task17ObjectCollector()
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(500 + offset),
                kind: .aac,
                factory: factory,
                collector: collector
            )
            if entry.0 == .start {
                XCTAssertThrowsError(try writer.start(at: CMTime(value: 10, timescale: 1)))
            } else {
                try writer.start(at: CMTime(value: 10, timescale: 1))
                if entry.0 == .flush {
                    let first = try Task17Fixtures.aacEpoch(bufferCount: 1)
                    try writer.appendAACEncodedEpoch(
                        first,
                        coordinator: try Task17Fixtures.aacCoordinator(epoch: first, writer: writer)
                    )
                }
                let epoch = try Task17Fixtures.aacEpoch(
                    bufferCount: 1,
                    outputBase: entry.0 == .flush
                        ? CMTime(value: 11, timescale: 1)
                        : CMTime(value: 10, timescale: 1)
                )
                XCTAssertThrowsError(try writer.appendAACEncodedEpoch(
                    epoch,
                    coordinator: try Task17Fixtures.aacCoordinator(epoch: epoch, writer: writer)
                ))
            }
            XCTAssertEqual(factory.lastWriter?.appendCount ?? 0, entry.1)
            XCTAssertEqual(factory.lastWriter?.cancelCount, 1)
            XCTAssertTrue(factory.lastWriter?.isTerminal == true)
            XCTAssertTrue(collector.objects.filter { $0.kind == .media }.isEmpty)
            XCTAssertEqual(writer.terminalReceipt?.terminalReason, .failed)
        }

        let illegal = try Task17Fixtures.makeWriter(
            seed: 510,
            kind: .aac,
            factory: Task17FakeSystemWriterFactory()
        )
        let illegalEpoch = try Task17Fixtures.aacEpoch(bufferCount: 1)
        XCTAssertThrowsError(try illegal.appendAACEncodedEpoch(
            illegalEpoch,
            coordinator: try Task17Fixtures.aacCoordinator(epoch: illegalEpoch, writer: illegal)
        )) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .illegalState)
        }
    }

    func testFinishCancelAndLateCallbacksProduceOneTerminalReceiptWithoutHalfSegment() async throws {
        let finishFactory = Task17FakeSystemWriterFactory(defersFinish: true, defersMediaCallback: true)
        let finishCollector = Task17ObjectCollector()
        let finishWriter = try Task17Fixtures.makeWriter(
            seed: 600,
            kind: .aac,
            factory: finishFactory,
            collector: finishCollector
        )
        let finishEpoch = try Task17Fixtures.aacEpoch(bufferCount: 1)
        try finishWriter.start(at: CMTime(value: 10, timescale: 1))
        try finishWriter.appendAACEncodedEpoch(
            finishEpoch,
            coordinator: try Task17Fixtures.aacCoordinator(epoch: finishEpoch, writer: finishWriter)
        )
        let task = Task {
            try await finishWriter.finish()
        }
        XCTAssertEqual(
            finishFactory.lastWriter?.waitUntilFinishRequested(timeout: .now() + 2),
            .success,
            "必须先确认 fake 已接到 finish，再注入系统完成，避免测试调度竞态"
        )
        finishFactory.lastWriter?.completeFinish(success: true)
        await Task.yield()
        XCTAssertNil(finishWriter.terminalReceipt, "真实 writer 完成但已接纳 callback 未收敛时不得签终态")
        finishFactory.lastWriter?.emitDeferredMediaCallbacks()
        let receipt = try await task.value
        XCTAssertEqual(receipt.terminalReason, .finished)
        XCTAssertEqual(receipt.inputCount, 1)
        XCTAssertEqual(receipt.initializationCallbackCount, 1)
        XCTAssertEqual(receipt.mediaCallbackCount, 1)
        XCTAssertEqual(finishWriter.cancel(), receipt)

        let cancelFactory = Task17FakeSystemWriterFactory(defersMediaCallback: true)
        let cancelCollector = Task17ObjectCollector()
        let cancelWriter = try Task17Fixtures.makeWriter(
            seed: 601,
            kind: .aac,
            factory: cancelFactory,
            collector: cancelCollector
        )
        let cancelEpoch = try Task17Fixtures.aacEpoch(bufferCount: 1)
        try cancelWriter.start(at: CMTime(value: 10, timescale: 1))
        try cancelWriter.appendAACEncodedEpoch(
            cancelEpoch,
            coordinator: try Task17Fixtures.aacCoordinator(epoch: cancelEpoch, writer: cancelWriter)
        )
        let cancelled = cancelWriter.cancel()
        cancelFactory.lastWriter?.emitDeferredMediaCallbacks()
        XCTAssertEqual(cancelled.terminalReason, .cancelled)
        XCTAssertTrue(cancelCollector.objects.filter { $0.kind == .media }.isEmpty)
        XCTAssertEqual(cancelWriter.cancel(), cancelled)
    }

    func testWriterAndUnpublishedCapacityBoundariesApplySoftThenHardWithoutSideEffects() throws {
        for (limits, softBytes, hardBytes) in [
            (FMP4WriterLimits.video, 48 * 1_024 * 1_024, 64 * 1_024 * 1_024),
            (.audio, 4 * 1_024 * 1_024, 8 * 1_024 * 1_024),
        ] {
            let relay = SegmentReportRelay(
                binding: Task17Fixtures.binding(seed: UInt64(hardBytes)),
                limits: limits,
                capacity: 8,
                objectSink: { _ in }
            )
            _ = try relay.reserve(kind: .media, logicalSequence: 0, projectedByteCount: softBytes - 1)
            XCTAssertFalse(relay.usage.shouldBackpressureWriter)
            _ = try relay.reserve(kind: .media, logicalSequence: 1, projectedByteCount: 1)
            XCTAssertTrue(relay.usage.shouldBackpressureWriter)
            _ = try relay.reserve(kind: .media, logicalSequence: 2, projectedByteCount: hardBytes - softBytes)
            XCTAssertEqual(relay.usage.writerBacklogSegmentCount, 3)
            XCTAssertEqual(relay.usage.writerBacklogBytes, hardBytes)
            XCTAssertThrowsError(try relay.reserve(
                kind: .media,
                logicalSequence: 3,
                projectedByteCount: 1
            )) { error in
                XCTAssertEqual(error as? SegmentReportRelayFailure, .writerHardCapacityExceeded)
            }
            XCTAssertEqual(relay.usage.writerBacklogSegmentCount, 3)
            XCTAssertEqual(relay.usage.writerBacklogBytes, hardBytes)
        }

        let relay = SegmentReportRelay(
            binding: Task17Fixtures.binding(seed: 700),
            limits: .audio,
            capacity: 8,
            objectSink: { _ in }
        )
        var leases: [UnpublishedLogicalSegmentLease] = []
        for sequence in 0..<8 {
            leases.append(try relay.reserveUnpublishedLogicalSegment(logicalSequence: UInt64(sequence)))
        }
        XCTAssertEqual(relay.usage.unpublishedLogicalSegmentCount, 8)
        XCTAssertThrowsError(try relay.reserveUnpublishedLogicalSegment(logicalSequence: 8)) { error in
            XCTAssertEqual(error as? SegmentReportRelayFailure, .unpublishedHardCapacityExceeded)
        }
        XCTAssertEqual(relay.usage.unpublishedLogicalSegmentCount, 8)
        for lease in leases { XCTAssertTrue(relay.releaseUnpublishedLogicalSegment(lease)) }
        XCTAssertEqual(relay.usage.unpublishedLogicalSegmentCount, 0)
    }

    func testValidAC3SubmissionClaimsThenReleasesOnlyAtWriterTerminal() async throws {
        let harness = try Task17AC3Harness(seed: 800)
        let accessUnit = try harness.makeAccessUnit(presentationTimeStamp: .zero)
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 800,
            kind: .ac3,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: accessUnit),
            compressedFormatConfiguration: accessUnit.formatConfiguration,
            factory: factory
        )
        try writer.start(at: .zero)
        try writer.appendCompressed(
            accessUnit.writerSubmission,
            coordinator: harness.coordinator,
            ticket: try Task17Fixtures.compressedTicket(accessUnit: accessUnit, writer: writer)
        )
        XCTAssertEqual(factory.lastWriter?.appendCount, 1)
        XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 1)
        XCTAssertEqual(
            harness.coordinator.branchLeaseState(try XCTUnwrap(accessUnit.directLeaseIdentity)),
            .transferred(.compressedAccessUnit(try XCTUnwrap(accessUnit.directBundleIdentity)))
        )

        let receipt = try await writer.finish()
        XCTAssertEqual(receipt.terminalReason, .finished)
        XCTAssertEqual(
            harness.coordinator.branchLeaseState(try XCTUnwrap(accessUnit.directLeaseIdentity)),
            .released
        )
        XCTAssertEqual(accessUnit.confirmWriterTerminal(using: harness.coordinator), 0)
    }

    func testCompressedExpectedIdentityMutationsAppendNothingAndKeepTransferredLease() throws {
        let harness = try Task17AC3Harness(seed: 900)
        let accessUnit = try harness.makeAccessUnit(presentationTimeStamp: .zero)
        let lease = try XCTUnwrap(accessUnit.directLeaseIdentity)
        let bundle = try XCTUnwrap(accessUnit.directBundleIdentity)
        let wrongConfiguration = CompressedAudioFormatConfiguration.eac3(
            try EAC3CompressedAudioConfiguration(
                sampleRate: 48_000,
                bsid: 16,
                bsmod: 0,
                audioCodingMode: 2,
                hasLFE: false,
                asvc: false,
                maximumDataRateKbps: 6_144
            )
        )
        let mutatedAdmissions = Task17Fixtures.mutatedDirectAdmissions(seed: 900)
        var variants: [CompressedAudioWriterSubmission] = []
        variants.append(CompressedAudioWriterSubmission(
            accessUnit: accessUnit,
            bundleIdentity: accessUnit.writerSubmission.bundleIdentity,
            admissionIdentity: mutatedAdmissions[0],
            payloadIdentity: accessUnit.payloadIdentity,
            payloadRange: accessUnit.payloadRange,
            payloadDigest: accessUnit.payloadDigest,
            formatConfiguration: accessUnit.formatConfiguration
        ))
        variants.append(CompressedAudioWriterSubmission(
            accessUnit: accessUnit,
            bundleIdentity: accessUnit.writerSubmission.bundleIdentity,
            admissionIdentity: accessUnit.admissionIdentity,
            payloadIdentity: .eac3(.init(rawValue: 1), EAC3OutputBackingOwnerIdentity()),
            payloadRange: accessUnit.payloadRange,
            payloadDigest: accessUnit.payloadDigest,
            formatConfiguration: accessUnit.formatConfiguration
        ))
        variants.append(CompressedAudioWriterSubmission(
            accessUnit: accessUnit,
            bundleIdentity: accessUnit.writerSubmission.bundleIdentity,
            admissionIdentity: accessUnit.admissionIdentity,
            payloadIdentity: accessUnit.payloadIdentity,
            payloadRange: AudioServiceByteRange(offset: 0, length: accessUnit.payloadRange.length - 1)!,
            payloadDigest: accessUnit.payloadDigest,
            formatConfiguration: accessUnit.formatConfiguration
        ))
        variants.append(CompressedAudioWriterSubmission(
            accessUnit: accessUnit,
            bundleIdentity: accessUnit.writerSubmission.bundleIdentity,
            admissionIdentity: accessUnit.admissionIdentity,
            payloadIdentity: accessUnit.payloadIdentity,
            payloadRange: accessUnit.payloadRange,
            payloadDigest: .zero,
            formatConfiguration: accessUnit.formatConfiguration
        ))
        variants.append(CompressedAudioWriterSubmission(
            accessUnit: accessUnit,
            bundleIdentity: accessUnit.writerSubmission.bundleIdentity,
            admissionIdentity: accessUnit.admissionIdentity,
            payloadIdentity: accessUnit.payloadIdentity,
            payloadRange: accessUnit.payloadRange,
            payloadDigest: accessUnit.payloadDigest,
            formatConfiguration: wrongConfiguration
        ))

        for (offset, variant) in variants.enumerated() {
            let factory = Task17FakeSystemWriterFactory()
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(910 + offset),
                kind: .ac3,
                sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: accessUnit),
                compressedFormatConfiguration: accessUnit.formatConfiguration,
                factory: factory
            )
            try writer.start(at: .zero)
            XCTAssertThrowsError(try writer.appendCompressed(
                variant,
                coordinator: harness.coordinator,
                ticket: try Task17Fixtures.compressedTicket(accessUnit: accessUnit, writer: writer)
            )) { error in
                XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .compressedIdentityMismatch)
            }
            XCTAssertEqual(factory.lastWriter?.appendCount, 0)
            XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 0)
            XCTAssertEqual(
                harness.coordinator.branchLeaseState(lease),
                .transferred(.compressedAccessUnit(bundle))
            )
            _ = writer.cancel()
        }
    }

    func testValidAggregatedEAC3SubmissionReleasesAllSixLeasesOnlyAtTerminal() async throws {
        let harness = try Task17EAC3Harness(seed: 1_200)
        let accessUnit = try harness.makeSixMemberAccessUnit()
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_200,
            kind: .eac3,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: accessUnit),
            compressedFormatConfiguration: accessUnit.formatConfiguration,
            factory: factory
        )
        try writer.start(at: .zero)
        try writer.appendCompressed(
            accessUnit.writerSubmission,
            coordinator: harness.coordinator,
            ticket: try Task17Fixtures.compressedTicket(accessUnit: accessUnit, writer: writer)
        )
        XCTAssertEqual(factory.lastWriter?.appendCount, 1)
        XCTAssertEqual(harness.states, Array(repeating: .transferred(
            .eac3AccessUnit(try XCTUnwrap(accessUnit.eac3BundleIdentity))
        ), count: 6))

        _ = try await writer.finish()
        XCTAssertEqual(harness.states, Array(repeating: .released, count: 6))
        XCTAssertEqual(accessUnit.confirmWriterTerminal(using: harness.coordinator), 0)
    }

    func testAACEndpointSameBufferAndMultiBufferReceiptsUseCheckedMapping() async throws {
        let leading: Int64 = 128
        let cases: [(writtenPhysical: CMTime, writtenEffective: ExactMediaTime)] = [
            (
                CMTime(value: 12, timescale: 1),
                ExactMediaTime(value: 12 * 48_000 + leading, timescale: 48_000)
            ),
            (
                CMTime(value: 12 * 48_000 - leading, timescale: 48_000),
                ExactMediaTime(value: 12, timescale: 1)
            ),
        ]
        for (caseIndex, testCase) in cases.enumerated() {
            for (bufferIndex, bufferCount) in [1, 3].enumerated() {
            let epoch = try Task17Fixtures.aacEpoch(bufferCount: bufferCount)
            let collector = Task17ObjectCollector()
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(1_400 + caseIndex * 10 + bufferIndex),
                kind: .aac,
                sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
                factory: Task17FakeSystemWriterFactory(
                    mediaWrittenStart: testCase.writtenPhysical
                ),
                collector: collector
            )
            try writer.start(at: CMTime(value: 10, timescale: 1))
            try writer.appendAACEncodedEpoch(
                epoch,
                coordinator: try Task17Fixtures.aacCoordinator(epoch: epoch, writer: writer)
            )
            _ = try await writer.finish()
            let receipt = try writer.makeAACEffectiveEndpointReceipt(
                epoch: epoch,
                initializationObject: try XCTUnwrap(collector.objects.first { $0.kind == .initialization }),
                mediaObjects: collector.objects.filter { $0.kind == .media }
            )
            let expectedInputPhysical = ExactMediaTime(
                value: 10 * 48_000 - leading,
                timescale: 48_000)
            XCTAssertEqual(receipt.inputEffectiveBase, ExactMediaTime(value: 10, timescale: 1))
            XCTAssertEqual(receipt.inputPhysicalBase, expectedInputPhysical)
            XCTAssertEqual(receipt.writtenPhysicalBase,
                           try ExactMediaTime(testCase.writtenPhysical))
            XCTAssertEqual(receipt.writtenEffectiveBase, testCase.writtenEffective)
            XCTAssertEqual(
                receipt.timelineOffset,
                try ExactMediaTime(testCase.writtenPhysical).subtracting(expectedInputPhysical))
            XCTAssertEqual(receipt.realSampleCount, Int64(epoch.realSampleCount))
            XCTAssertEqual(receipt.totalDecodedFrames, Int64(epoch.totalDecodedFrames))
            XCTAssertEqual(receipt.leadingFrames, Int64(epoch.leadingFrames))
            XCTAssertEqual(receipt.trailingFrames, Int64(epoch.trailingFrames))
            XCTAssertEqual(
                receipt.trailingFrames,
                receipt.totalDecodedFrames - receipt.leadingFrames - receipt.realSampleCount
            )
            XCTAssertEqual(receipt.inputEvidenceCount, bufferCount)
            XCTAssertEqual(
                receipt.lastEffectiveEnd,
                try testCase.writtenEffective.adding(ExactMediaTime(
                    value: Int64(epoch.realSampleCount), timescale: 48_000)))
            }
        }
    }

    func testAACEndpointRejectsTrimAndArithmeticMutationMatrix() async throws {
        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 3)
        let collector = Task17ObjectCollector()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_500,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            factory: Task17FakeSystemWriterFactory(
                mediaWrittenStart: CMTime(value: 10, timescale: 1)
            ),
            collector: collector
        )
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try writer.appendAACEncodedEpoch(
            epoch,
            coordinator: try Task17Fixtures.aacCoordinator(epoch: epoch, writer: writer)
        )
        _ = try await writer.finish()
        let initializer = try XCTUnwrap(collector.objects.first { $0.kind == .initialization })
        let media = collector.objects.filter { $0.kind == .media }
        let forged = AACEncodedEpoch(
            identity: epoch.identity,
            buffers: epoch.buffers,
            realSampleCount: epoch.realSampleCount + 1,
            totalDecodedFrames: epoch.totalDecodedFrames,
            leadingFrames: epoch.leadingFrames,
            trailingFrames: epoch.trailingFrames,
            actualLeadingPrimeFrames: epoch.actualLeadingPrimeFrames,
            actualTrailingPrimeFrames: epoch.actualTrailingPrimeFrames,
            bandwidth: epoch.bandwidth,
            packetLease: epoch.packetLease,
            formatLease: epoch.formatLease
        )
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: forged,
            initializationObject: initializer,
            mediaObjects: media
        ))

        let final = try XCTUnwrap(epoch.buffers.last)
        CMRemoveAttachment(final, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: media
        ))
        Task17Fixtures.setTrim(epoch.buffers[0], key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, samples: 1)
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: media
        ))
    }

    func testAACEndpointRejectsInputOrCallbackIdentityReplacement() async throws {
        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 2)
        let collector = Task17ObjectCollector()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_600,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            factory: Task17FakeSystemWriterFactory(
                mediaWrittenStart: CMTime(value: 10, timescale: 1)
            ),
            collector: collector
        )
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try writer.appendAACEncodedEpoch(
            epoch,
            coordinator: try Task17Fixtures.aacCoordinator(epoch: epoch, writer: writer)
        )
        _ = try await writer.finish()
        let initializer = try XCTUnwrap(collector.objects.first { $0.kind == .initialization })
        let media = collector.objects.filter { $0.kind == .media }
        let replacementEpoch = try Task17Fixtures.aacEpoch(bufferCount: 2)
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: replacementEpoch,
            initializationObject: initializer,
            mediaObjects: media
        ))
        let replacementObject = try Task17Fixtures.sealedObject(
            binding: Task17Fixtures.binding(seed: 1_601),
            kind: .media,
            logicalSequence: 0,
            bytes: Data([9, 9, 9])
        )
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: [replacementObject]
        ))
        let receipt = try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: media
        )
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: media
        ))
        XCTAssertEqual(receipt.writerReceiptIdentity, writer.terminalReceipt?.identity)
    }

    func testAACEncoderIdentityCannotChangeWithinWriterAndSameIdentityChunksSealEndpoint()
        async throws {
        let complete = try Task17Fixtures.aacEpoch(bufferCount: 2)
        func chunk(_ index: Int, identity: AACEncoderIdentity) -> AACEncodedEpoch {
            let leading = index == 0 ? complete.leadingFrames : 0
            let trailing = index == complete.buffers.count - 1 ? complete.trailingFrames : 0
            return AACEncodedEpoch(
                identity: identity,
                buffers: [complete.buffers[index]],
                realSampleCount: 1_024 - leading - trailing,
                totalDecodedFrames: 1_024,
                leadingFrames: leading,
                trailingFrames: trailing,
                actualLeadingPrimeFrames: UInt32(leading),
                actualTrailingPrimeFrames: UInt32(trailing),
                bandwidth: complete.bandwidth,
                packetLease: complete.packetLease,
                formatLease: complete.formatLease)
        }
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1)))
        let collector = Task17ObjectCollector()
        let factory = Task17FakeSystemWriterFactory(
            mediaWrittenStart: CMTime(value: 12, timescale: 1))
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_602,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(
                CMSampleBufferGetFormatDescription(complete.buffers[0])),
            boundary: boundary,
            factory: factory,
            collector: collector)
        try boundary.registerAudioRendition(
            writer.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: CMTime(value: 10, timescale: 1))
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try writer.appendAACEncodedEpoch(
            chunk(0, identity: complete.identity), coordinator: boundary)

        let foreignIdentity = try Task17Fixtures.aacEpoch(bufferCount: 1).identity
        XCTAssertThrowsError(try writer.appendAACEncodedEpoch(
            chunk(1, identity: foreignIdentity), coordinator: boundary
        )) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure,
                           .aacEndpointMismatch)
        }
        XCTAssertEqual(factory.lastWriter?.appendCount, 1,
                       "同 media epoch 不得接纳另一 encoder identity 的输入")

        try writer.appendAACEncodedEpoch(
            chunk(1, identity: complete.identity), coordinator: boundary)
        _ = try await writer.finish()
        let terminalBinding = try XCTUnwrap(writer.aacTerminalBinding)
        let waiter = Task { try await terminalBinding.awaitEndpointAuthority() }
        let initialization = try XCTUnwrap(
            collector.objects.first { $0.kind == .initialization })
        let authority = try writer.makeAACEffectiveEndpointAuthority(
            epoch: complete,
            initializationObject: initialization,
            mediaObjects: collector.objects.filter { $0.kind == .media })
        let awaitedAuthority = try await waiter.value
        XCTAssertTrue(awaitedAuthority === authority)
        XCTAssertEqual(authority.receipt.inputEvidenceCount, 2)
        XCTAssertEqual(authority.receipt.encoderIdentity, complete.identity)
    }

    func testRealIncrementalAACAppendsBeforeEOSAndWriterSealsEncoderReceipt() async throws {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task22-a-real-incremental")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let format = try encoder.incrementalFormatDescription()
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_603,
            kind: .aac,
            sourceFormatHint: format,
            factory: factory)
        let boundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1),
            writer: writer)
        try writer.start(at: CMTime(value: 10, timescale: 1))

        var lastEmission: AACIncrementalEmission?
        for batch in 0..<40 {
            let samples = (0..<(1_024 * 2)).map { index in
                sin(Float(batch * 2_048 + index) * 0.003125) * 0.25
            }
            _ = try encoder.pumpSigned(.pcm(samples)) {
                lastEmission = $0
                _ = try writer.appendAACIncremental($0, coordinator: boundary)
            }
        }
        let preEOSAppendCount = try XCTUnwrap(factory.lastWriter).appendCount
        XCTAssertGreaterThan(preEOSAppendCount, 0,
                             "真实 writer 首次 append 必须早于 EOS")

        let terminal = try encoder.pumpSigned(.endOfStream) {
            _ = try writer.appendAACIncremental($0, coordinator: boundary)
        }
        let final = try XCTUnwrap(terminal.finalReceipt)
        let receipt = try writer.sealAACIncrementalStream(final)
        XCTAssertEqual(receipt.binding, writer.binding)
        XCTAssertEqual(receipt.encoderIdentity, encoder.identity)
        XCTAssertEqual(receipt.inputCount, final.emissionCount)
        XCTAssertEqual(receipt.inputDigest, final.cumulativeDigest)
        XCTAssertThrowsError(try writer.sealAACIncrementalStream(final))
        let appendCountAfterSeal = factory.lastWriter?.appendCount
        XCTAssertThrowsError(try writer.appendAACIncremental(
            try XCTUnwrap(lastEmission), coordinator: boundary))
        XCTAssertEqual(factory.lastWriter?.appendCount, appendCountAfterSeal,
                       "终态后拒绝必须发生在系统 append 之前")
    }

    func testIncrementalAACWriterRejectsDuplicateAndCrossWriterReplay() async throws {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task22-a-mutation")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_604,
            kind: .aac,
            sourceFormatHint: try encoder.incrementalFormatDescription(),
            factory: factory)
        let boundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: writer)
        try writer.start(at: CMTime(value: 10, timescale: 1))
        var first: AACIncrementalEmission?
        for batch in 0..<20 where first == nil {
            let samples = (0..<(1_024 * 2)).map { index in
                sin(Float(batch * 2_048 + index) * 0.00625) * 0.25
            }
            _ = try encoder.pumpSigned(.pcm(samples)) { first = $0 }
        }
        let emission = try XCTUnwrap(first)
        XCTAssertEqual(try writer.appendAACIncremental(
            emission, coordinator: boundary), .appended)
        XCTAssertThrowsError(try writer.appendAACIncremental(
            emission, coordinator: boundary))

        let foreignFactory = Task17FakeSystemWriterFactory()
        let foreignWriter = try Task17Fixtures.makeWriter(
            seed: 1_606,
            kind: .aac,
            sourceFormatHint: try encoder.incrementalFormatDescription(),
            factory: foreignFactory)
        let foreignBoundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: foreignWriter)
        try foreignWriter.start(at: CMTime(value: 10, timescale: 1))
        XCTAssertThrowsError(try foreignWriter.appendAACIncremental(
            emission, coordinator: foreignBoundary))
        XCTAssertEqual(foreignFactory.lastWriter?.appendCount, 0,
                       "同一 live emission 不得换 writer 重放")
    }

    func testIncrementalAACSummaryKeepsQueriedPrimeIndependentFromTrim() throws {
        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 2)
        let accounting = AACIncrementalStreamAccounting(
            encoderIdentity: epoch.identity,
            inputCount: 2,
            inputDigest: Data(repeating: 0x31, count: 32),
            realSampleCount: 1_280,
            totalDecodedFrames: 2_048,
            leadingFrames: 512,
            trailingFrames: 256
        )
        let summary = AACStreamSummary(
            identity: epoch.identity,
            realSampleCount: 1_280,
            totalDecodedFrames: 2_048,
            leadingFrames: 512,
            trailingFrames: 256,
            actualLeadingPrimeFrames: 2_112,
            actualTrailingPrimeFrames: 0,
            maximumRetainedPackets: 3,
            bandwidth: epoch.bandwidth
        )

        XCTAssertTrue(accounting.matches(summary: summary),
                      "queried prime 只记录真实 converter 值，不得替代 L/P")
    }

    func testIncrementalAACFailedSystemAppendDoesNotCommitAccounting() async throws {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task22-a-append-commit")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_607,
            kind: .aac,
            sourceFormatHint: try encoder.incrementalFormatDescription(),
            factory: factory)
        let boundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: writer)
        try writer.start(at: CMTime(value: 10, timescale: 1))
        var first: AACIncrementalEmission?
        for batch in 0..<20 where first == nil {
            let samples = (0..<(1_024 * 2)).map { index in
                sin(Float(batch * 2_048 + index) * 0.004375) * 0.25
            }
            _ = try encoder.pumpSigned(.pcm(samples)) { first = $0 }
        }
        let emission = try XCTUnwrap(first)
        factory.lastWriter?.rejectNextAppend()

        XCTAssertThrowsError(try writer.appendAACIncremental(
            emission, coordinator: boundary))
        XCTAssertEqual(factory.lastWriter?.appendCount, 1)
        XCTAssertEqual(writer.incrementalAACCommittedInputCount, 0,
                       "系统 append 失败不得提交 snapshot/ordinal/digest")
    }

    func testAACPostAppendRecordFailureAndLegacyBatchSuffixAreTerminal() async throws {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task22-a-post-record")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        var first: AACIncrementalEmission?
        for batch in 0..<20 where first == nil {
            let samples = (0..<(1_024 * 2)).map { index in
                sin(Float(batch * 2_048 + index) * 0.004875) * 0.25
            }
            _ = try encoder.pumpSigned(.pcm(samples)) { first = $0 }
        }
        let emission = try XCTUnwrap(first)
        let incrementalFactory = Task17FakeSystemWriterFactory()
        let incremental = try Task17Fixtures.makeWriter(
            seed: 1_608,
            kind: .aac,
            sourceFormatHint: try encoder.incrementalFormatDescription(),
            factory: incrementalFactory,
            recordAppendFailureOrdinal: 1)
        let incrementalBoundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: incremental)
        try incremental.start(at: CMTime(value: 10, timescale: 1))

        XCTAssertThrowsError(try incremental.appendAACIncremental(
            emission, coordinator: incrementalBoundary))
        XCTAssertEqual(incrementalFactory.lastWriter?.appendCount, 1)
        XCTAssertEqual(incremental.incrementalAACCommittedInputCount, 0)
        XCTAssertTrue(incrementalFactory.lastWriter?.isTerminal == true)
        XCTAssertThrowsError(try incremental.appendAACIncremental(
            emission, coordinator: incrementalBoundary))
        XCTAssertEqual(incrementalFactory.lastWriter?.appendCount, 1,
                       "后置记录失败后同一 emission 不得重放")

        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 3)
        let legacyFactory = Task17FakeSystemWriterFactory()
        let legacy = try Task17Fixtures.makeWriter(
            seed: 1_609,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(
                CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            factory: legacyFactory,
            recordAppendFailureOrdinal: 2)
        let legacyBoundary = try Task17Fixtures.aacCoordinator(
            epoch: epoch, writer: legacy)
        try legacy.start(at: CMTime(value: 10, timescale: 1))
        XCTAssertThrowsError(try legacy.appendAACEncodedEpoch(
            epoch, coordinator: legacyBoundary))
        XCTAssertEqual(legacyFactory.lastWriter?.appendCount, 2)
        XCTAssertTrue(legacyFactory.lastWriter?.isTerminal == true)
        XCTAssertThrowsError(try legacy.appendAACEncodedEpoch(
            epoch, coordinator: legacyBoundary))
        XCTAssertEqual(legacyFactory.lastWriter?.appendCount, 2,
                       "旧 batch 已提交前缀不得由整批 retry 重放")
    }

    func testIncrementalAACFirstEmissionRequiresEffectiveSample() {
        XCTAssertFalse(AACIncrementalStreamAccounting.firstEmissionIsValid(
            decodedFrames: 512, leadingFrames: 512, trailingFrames: 0))
        XCTAssertTrue(AACIncrementalStreamAccounting.firstEmissionIsValid(
            decodedFrames: 1_024, leadingFrames: 512, trailingFrames: 256),
            "合法短流允许首尾 trim 位于同一 buffer")
    }

    func testAudioBranchAcquiresPumpBudgetBeforeFillAndAppendsBeforeEOS() async throws {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task22-a-branch-admission")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_605,
            kind: .aac,
            sourceFormatHint: try encoder.incrementalFormatDescription(),
            factory: factory)
        let boundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: writer)
        try writer.start(at: CMTime(value: 10, timescale: 1))
        let gate = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: AudioRenditionBranch.maximumPumpOutputBytes)
        let blocker = try XCTUnwrap(gate.acquire(
            bytes: AudioRenditionBranch.maximumPumpOutputBytes))
        let branch = AudioRenditionBranch(
            encoder: encoder,
            writer: writer,
            coordinator: boundary,
            admission: gate)
        let samples = (0..<(16_384 * 2)).map { index in
            sin(Float(index) * 0.003125) * 0.25
        }
        let blockedPump = Task.detached {
            try branch.pump(.pcm(samples))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(factory.lastWriter?.appendCount, 0,
                       "没有 pump 预算时不得先 Fill/append")
        XCTAssertNil(encoder.terminalFailure, "暂时背压不得终结 encoder")

        factory.lastWriter?.setReadyForMoreMediaData(false)
        blocker.release()
        let waiting = try await blockedPump.value
        XCTAssertTrue(waiting.waitingForWriter)
        XCTAssertEqual(factory.lastWriter?.appendCount, 0)
        XCTAssertEqual(writer.incrementalAACCommittedInputCount, 0,
                       "暂时不可写不得提前提交 snapshot/ordinal/digest")
        XCTAssertEqual(gate.usage.count, 1,
                       "原 signed emission 未提交前必须继续持有 pump lease")
        let pendingMemory = try XCTUnwrap(branch.pendingMemoryUsage)
        XCTAssertGreaterThan(pendingMemory.reservedBytes, 0)
        XCTAssertGreaterThan(pendingMemory.actualFrozenAndMaterializedBytes, 0)
        XCTAssertGreaterThanOrEqual(
            pendingMemory.reservedBytes,
            pendingMemory.actualFrozenAndMaterializedBytes,
            "整泵真实冻结/物化/description charge 必须由 Fill 前预留覆盖")
        let pending = try XCTUnwrap(branch.pendingEmissionIdentity)

        factory.lastWriter?.setReadyForMoreMediaData(true)
        let preEOS = try XCTUnwrap(try branch.retryPending())
        XCTAssertFalse(preEOS.waitingForWriter)
        XCTAssertEqual(branch.firstCommittedEmissionIdentity, pending,
                       "重试必须提交原对象，不得重新 Fill")
        XCTAssertTrue(preEOS.needsInput)
        XCTAssertGreaterThan(factory.lastWriter?.appendCount ?? 0, 0)
        let countBeforeUnavailable = factory.lastWriter?.appendCount
        XCTAssertNil(try branch.pump(.unavailable).finalReceipt)
        XCTAssertEqual(factory.lastWriter?.appendCount, countBeforeUnavailable)

        let terminal = try branch.pump(.endOfStream)
        XCTAssertNotNil(terminal.finalReceipt)
        XCTAssertEqual(branch.writerReceipt?.inputCount,
                       terminal.finalReceipt?.emissionCount)
        XCTAssertLessThanOrEqual(
            branch.bufferedEmissionHighWatermark,
            AudioRenditionBranch.maximumEmissionsPerPump)
        XCTAssertEqual(gate.usage, .init(count: 0, bytes: 0, cancelled: false))
    }

    func testAudioBranchHidesPendingEOSReceiptUntilRetryAndCancelRetiresLease() async throws {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task22-a-eos-pending")
        let calibration = try await calibrator.calibrate(
            plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_610,
            kind: .aac,
            sourceFormatHint: try encoder.incrementalFormatDescription(),
            factory: factory)
        let boundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: writer)
        try writer.start(at: CMTime(value: 10, timescale: 1))
        let gate = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: AACRenditionEncoder.maximumSignedPumpAllocationBytes)
        let branch = AudioRenditionBranch(
            encoder: encoder, writer: writer, coordinator: boundary,
            admission: gate)
        let samples = (0..<(4_096 * 2)).map { index in
            sin(Float(index) * 0.003875) * 0.25
        }
        _ = try branch.pump(.pcm(samples))
        factory.lastWriter?.setReadyForMoreMediaData(false)

        let waiting = try branch.pump(.endOfStream)
        XCTAssertTrue(waiting.waitingForWriter)
        XCTAssertNil(waiting.summary)
        XCTAssertNil(waiting.finalReceipt,
                     "writer 未接纳/封存 EOS 时不得向上泄露 final receipt")
        XCTAssertNil(branch.writerReceipt)
        XCTAssertEqual(gate.usage.count, 1)

        factory.lastWriter?.setReadyForMoreMediaData(true)
        let terminal = try XCTUnwrap(try branch.retryPending())
        XCTAssertNotNil(terminal.summary)
        XCTAssertNotNil(terminal.finalReceipt)
        XCTAssertNotNil(branch.writerReceipt)
        XCTAssertEqual(gate.usage.count, 0)

        let cancelCalibrator = AACPrimingCalibrator()
        let cancelCalibration = try await cancelCalibrator.calibrate(
            plan: try AACCalibrationPlan.build([
                try AACRenditionRequest(
                    layout: RenditionAudioLayout(labels: [.c]),
                    capabilityVersion: "task22-a-cancel-pending")
            ]))
        let cancelEncoder = try XCTUnwrap(cancelCalibration.encoders.first)
        let cancelFactory = Task17FakeSystemWriterFactory()
        let cancelWriter = try Task17Fixtures.makeWriter(
            seed: 1_611,
            kind: .aac,
            sourceFormatHint: try cancelEncoder.incrementalFormatDescription(),
            factory: cancelFactory)
        let cancelBoundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: cancelWriter)
        try cancelWriter.start(at: CMTime(value: 10, timescale: 1))
        let cancelGate = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: AACRenditionEncoder.maximumSignedPumpAllocationBytes)
        let cancelBranch = AudioRenditionBranch(
            encoder: cancelEncoder, writer: cancelWriter,
            coordinator: cancelBoundary, admission: cancelGate)
        cancelFactory.lastWriter?.setReadyForMoreMediaData(false)
        let mono = (0..<16_384).map { sin(Float($0) * 0.004125) * 0.25 }
        XCTAssertTrue(try cancelBranch.pump(.pcm(mono)).waitingForWriter)
        XCTAssertEqual(cancelGate.usage.count, 1)
        cancelBranch.cancel()
        XCTAssertEqual(cancelGate.usage.count, 0)
        XCTAssertNil(try cancelBranch.retryPending())

        let inflightCalibrator = AACPrimingCalibrator()
        let inflightCalibration = try await inflightCalibrator.calibrate(
            plan: try AACCalibrationPlan.build([
                try AACRenditionRequest(
                    layout: RenditionAudioLayout(labels: [.l, .r]),
                    capabilityVersion: "task22-a-cancel-inflight")
            ]))
        let inflightEncoder = try XCTUnwrap(inflightCalibration.encoders.first)
        let inflightFactory = Task17FakeSystemWriterFactory(blocksAppend: true)
        let inflightWriter = try Task17Fixtures.makeWriter(
            seed: 1_612,
            kind: .aac,
            sourceFormatHint: try inflightEncoder.incrementalFormatDescription(),
            factory: inflightFactory)
        let inflightBoundary = try Task17Fixtures.aacCoordinator(
            epoch: Task17Fixtures.aacEpoch(bufferCount: 1), writer: inflightWriter)
        try inflightWriter.start(at: CMTime(value: 10, timescale: 1))
        let inflightGate = HLSDataPlaneAdmission(
            capacity: 1,
            maximumBytes: AACRenditionEncoder.maximumSignedPumpAllocationBytes)
        let inflightBranch = AudioRenditionBranch(
            encoder: inflightEncoder, writer: inflightWriter,
            coordinator: inflightBoundary, admission: inflightGate)
        let stereo = (0..<(16_384 * 2)).map {
            sin(Float($0) * 0.004625) * 0.25
        }
        let inflightPump = Task.detached { try inflightBranch.pump(.pcm(stereo)) }
        XCTAssertEqual(inflightFactory.lastWriter?.waitUntilAppendEntered(
            timeout: .now() + 2), .success)
        let inflightCancel = Task.detached { inflightBranch.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inflightGate.usage.count, 1,
                       "真实 append 在途时 cancel 不得提前归还尾 lease")
        inflightFactory.lastWriter?.releaseBlockedAppend()
        _ = try await inflightPump.value
        await inflightCancel.value
        XCTAssertEqual(inflightGate.usage.count, 0)
    }

    func testAACTerminalBindingEndsExistingAndFutureWaitersOnCancelOrFailure()
        async throws {
        enum TerminalCase: Equatable {
            case cancel
            case failure
        }
        func joinBounded(
            _ task: Task<Result<AACEffectiveEndpointAuthority, Error>, Never>
        ) async -> (settledBeforeCancellation: Bool,
                    result: Result<AACEffectiveEndpointAuthority, Error>) {
            let settledBeforeCancellation = await withTaskGroup(
                of: Bool.self,
                returning: Bool.self
            ) { group in
                group.addTask {
                    _ = await task.value
                    return true
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        return false
                    } catch {
                        return false
                    }
                }
                let settled = await group.next() ?? false
                if !settled { task.cancel() }
                group.cancelAll()
                return settled
            }
            return (settledBeforeCancellation, await task.value)
        }
        func boundedAwait(
            _ binding: AACWriterTerminalBinding
        ) async -> (settledBeforeCancellation: Bool,
                    result: Result<AACEffectiveEndpointAuthority, Error>) {
            let task = Task { () -> Result<AACEffectiveEndpointAuthority, Error> in
                let result: Result<AACEffectiveEndpointAuthority, Error>
                do {
                    result = .success(try await binding.awaitEndpointAuthority())
                } catch {
                    result = .failure(error)
                }
                return result
            }
            return await joinBounded(task)
        }

        for (offset, terminalCase) in [TerminalCase.cancel, .failure].enumerated() {
            let factory = Task17FakeSystemWriterFactory(
                failurePoint: terminalCase == .failure ? .start : nil)
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(1_610 + offset), kind: .aac, factory: factory)
            let binding = try XCTUnwrap(writer.aacTerminalBinding)
            let entered = Task17LockedBool()
            let existing = Task { () -> Result<AACEffectiveEndpointAuthority, Error> in
                entered.setTrue()
                do {
                    return .success(try await binding.awaitEndpointAuthority())
                } catch {
                    return .failure(error)
                }
            }
            while !entered.value { await Task.yield() }
            await Task.yield()
            switch terminalCase {
            case .cancel:
                XCTAssertEqual(writer.cancel().terminalReason, .cancelled)
            case .failure:
                XCTAssertThrowsError(try writer.start(at: .zero))
                XCTAssertEqual(writer.terminalReceipt?.terminalReason, .failed)
            }

            let existingOutcome = await joinBounded(existing)
            XCTAssertTrue(existingOutcome.settledBeforeCancellation,
                          "writer 终态必须结束已经登记的 endpoint waiter")
            let future = await boundedAwait(binding)
            XCTAssertTrue(future.settledBeforeCancellation,
                          "writer 终态必须立即拒绝未来 endpoint waiter")
            for result in [existingOutcome.result, future.result] {
                guard case let .failure(error) = result else {
                    return XCTFail("失败/取消的 writer 不得签发 endpoint authority")
                }
                switch terminalCase {
                case .cancel:
                    XCTAssertTrue(error is CancellationError)
                case .failure:
                    XCTAssertEqual(error as? SegmentedFMP4WriterFailure,
                                   .systemFailure)
                }
            }
        }
    }

    func testAACAuthorityValidationFailureEndsExistingAndFutureWaiters()
        async throws {
        func joinBounded(
            _ task: Task<Result<AACEffectiveEndpointAuthority, Error>, Never>
        ) async -> (settled: Bool,
                    result: Result<AACEffectiveEndpointAuthority, Error>) {
            let settled = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                group.addTask {
                    _ = await task.value
                    return true
                }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(2)) } catch {}
                    return false
                }
                let settled = await group.next() ?? false
                if !settled { task.cancel() }
                group.cancelAll()
                return settled
            }
            return (settled, await task.value)
        }

        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 2)
        let collector = Task17ObjectCollector()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_620,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(
                CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            factory: Task17FakeSystemWriterFactory(
                mediaWrittenStart: CMTime(value: 10, timescale: 1)),
            collector: collector)
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try writer.appendAACEncodedEpoch(
            epoch,
            coordinator: try Task17Fixtures.aacCoordinator(epoch: epoch, writer: writer))
        _ = try await writer.finish()

        let binding = try XCTUnwrap(writer.aacTerminalBinding)
        let entered = Task17LockedBool()
        let existing = Task { () -> Result<AACEffectiveEndpointAuthority, Error> in
            entered.setTrue()
            do { return .success(try await binding.awaitEndpointAuthority()) }
            catch { return .failure(error) }
        }
        while !entered.value { await Task.yield() }
        await Task.yield()

        let initialization = try XCTUnwrap(
            collector.objects.first { $0.kind == .initialization })
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointAuthority(
            epoch: epoch,
            initializationObject: initialization,
            mediaObjects: [initialization]
        )) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure,
                           .aacEndpointMismatch)
        }

        let existingOutcome = await joinBounded(existing)
        let futureOutcome = await joinBounded(Task {
            do { return .success(try await binding.awaitEndpointAuthority()) }
            catch { return .failure(error) }
        })
        XCTAssertTrue(existingOutcome.settled,
                      "receipt/object 不可恢复失败必须结束已登记 waiter")
        XCTAssertTrue(futureOutcome.settled,
                      "receipt/object 不可恢复失败必须立即拒绝未来 waiter")
        for result in [existingOutcome.result, futureOutcome.result] {
            guard case let .failure(error) = result else {
                return XCTFail("validation failure 不得签发 endpoint authority")
            }
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure,
                           .aacEndpointMismatch)
        }
        XCTAssertNil(binding.endpointAuthority)
    }

    func testAACAuthorityClaimAndBindingTerminalSettleAtomicallyAcrossFailureAndConcurrency()
        async throws {
        typealias Fixture = (
            writer: SegmentedFMP4Writer,
            epoch: AACEncodedEpoch,
            initialization: SealedMediaObject,
            media: [SealedMediaObject]
        )
        func makeFinishedFixture(seed: UInt64) async throws -> Fixture {
            let epoch = try Task17Fixtures.aacEpoch(bufferCount: 2)
            let collector = Task17ObjectCollector()
            let writer = try Task17Fixtures.makeWriter(
                seed: seed,
                kind: .aac,
                sourceFormatHint: try XCTUnwrap(
                    CMSampleBufferGetFormatDescription(epoch.buffers[0])),
                factory: Task17FakeSystemWriterFactory(
                    mediaWrittenStart: CMTime(value: 10, timescale: 1)),
                collector: collector)
            try writer.start(at: CMTime(value: 10, timescale: 1))
            try writer.appendAACEncodedEpoch(
                epoch,
                coordinator: try Task17Fixtures.aacCoordinator(
                    epoch: epoch, writer: writer))
            _ = try await writer.finish()
            return (
                writer,
                epoch,
                try XCTUnwrap(collector.objects.first { $0.kind == .initialization }),
                collector.objects.filter { $0.kind == .media }
            )
        }

        // 审查复现：首个不可恢复的 sealed-object 错误必须把 claim 与 binding
        // 一起结算为 failure；随后正确参数只能取得同一失败，不能先 claim 再在
        // seal() 上触发 precondition。
        let rejected = try await makeFinishedFixture(seed: 1_621)
        let rejectedBinding = try XCTUnwrap(rejected.writer.aacTerminalBinding)
        XCTAssertThrowsError(try rejected.writer.makeAACEffectiveEndpointAuthority(
            epoch: rejected.epoch,
            initializationObject: rejected.initialization,
            mediaObjects: [rejected.initialization]
        )) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .aacEndpointMismatch)
        }
        XCTAssertThrowsError(try rejected.writer.makeAACEffectiveEndpointAuthority(
            epoch: rejected.epoch,
            initializationObject: rejected.initialization,
            mediaObjects: rejected.media
        )) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .aacEndpointMismatch)
        }
        do {
            _ = try await rejectedBinding.awaitEndpointAuthority()
            XCTFail("不可恢复的首个 validation failure 不得被后续正确参数翻转")
        } catch {
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .aacEndpointMismatch)
        }

        // 两个并发正确调用共享 writer lane 的单一 claim：只能有一个 winner；
        // loser 的重复 claim 不能把已成功 seal 的 binding 覆盖成 failure。
        let accepted = try await makeFinishedFixture(seed: 1_622)
        let outcomes = await withTaskGroup(
            of: Result<AACEffectiveEndpointAuthority, Error>.self,
            returning: [Result<AACEffectiveEndpointAuthority, Error>].self
        ) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        return .success(try accepted.writer.makeAACEffectiveEndpointAuthority(
                            epoch: accepted.epoch,
                            initializationObject: accepted.initialization,
                            mediaObjects: accepted.media))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var values: [Result<AACEffectiveEndpointAuthority, Error>] = []
            for await value in group { values.append(value) }
            return values
        }
        let authorities = outcomes.compactMap { try? $0.get() }
        XCTAssertEqual(authorities.count, 1)
        let winner = try XCTUnwrap(authorities.first)
        let acceptedBinding = try XCTUnwrap(accepted.writer.aacTerminalBinding)
        XCTAssertTrue(acceptedBinding.endpointAuthority === winner)
        let futureAuthority = try await acceptedBinding.awaitEndpointAuthority()
        XCTAssertTrue(futureAuthority === winner,
                      "并发 loser 不得覆盖首个成功 binding 终态")
    }

    func testSealedObjectCopiesMutableInputSeparatesKindsAndIsOneShot() throws {
        let binding = Task17Fixtures.binding(seed: 1_700)
        let collector = Task17ObjectCollector()
        let relay = SegmentReportRelay(binding: binding, limits: .audio, capacity: 8, objectSink: collector.append)
        let mutable = NSMutableData(data: Data([1, 2, 3, 4]))
        let ticket = try relay.reserve(kind: .initialization, logicalSequence: 0, projectedByteCount: 4)
        let delivery = SegmentCallbackDelivery(
            binding: binding,
            writerIdentity: binding.writerIdentity,
            ticket: ticket,
            logicalSequence: 0,
            kind: .initialization,
            bytes: mutable,
            report: SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: nil))
        )
        guard case let .accepted(acceptance) = relay.receive(delivery) else {
            return XCTFail("首个 callback 必须被 relay 接纳")
        }
        XCTAssertTrue(relay.consumePublication(acceptance) { $0() })
        var replacement = [UInt8](repeating: 9, count: 4)
        mutable.replaceBytes(in: NSRange(location: 0, length: 4), withBytes: &replacement)
        let sealed = try XCTUnwrap(collector.objects.first)
        XCTAssertEqual(sealed.bytes, Data([1, 2, 3, 4]))
        XCTAssertEqual(sealed.digest, Data(SHA256.hash(data: Data([1, 2, 3, 4]))))
        XCTAssertEqual(relay.receive(delivery), .discarded)
        XCTAssertEqual(collector.objects.count, 1)

        let wrongKind = try relay.reserve(kind: .media, logicalSequence: 1, projectedByteCount: 4)
        XCTAssertEqual(relay.receive(SegmentCallbackDelivery(
            binding: binding,
            writerIdentity: binding.writerIdentity,
            ticket: wrongKind,
            logicalSequence: 1,
            kind: .initialization,
            bytes: NSData(data: Data([5, 6, 7, 8])),
            report: SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: nil))
        )), .fatal(.callbackIdentityMismatch))
        XCTAssertEqual(collector.objects.count, 1)
        XCTAssertEqual(relay.usage.reservedSlots, 0)
    }

    func testRealVideoWriterProducesRecognizableInitializationAndMediaCallbacks() async throws {
        let fixture = try Task17Fixtures.realH264Sample()
        let collector = Task17ObjectCollector()
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_800,
            kind: .video,
            sourceFormatHint: fixture.format,
            boundary: boundary,
            collector: collector
        )
        let output = Task17Fixtures.videoOutput(
            fixture: fixture,
            generation: 1,
            accessUnitID: 1,
            sequenceNumber: 1
        )
        try writer.start(at: .zero)
        try writer.appendVideo(
            output,
            ticket: try boundary.issueVideoAppend(for: output, writerBinding: writer.binding)
        )
        let receipt = try await writer.finish()
        let initialization = try XCTUnwrap(collector.objects.first { $0.kind == .initialization })
        let media = try XCTUnwrap(collector.objects.first { $0.kind == .media })
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("ftyp", in: initialization.bytes))
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("moov", in: initialization.bytes))
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("moof", in: media.bytes))
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("mdat", in: media.bytes))
        XCTAssertEqual(receipt.initializationCallbackCount, 1)
        XCTAssertGreaterThanOrEqual(receipt.mediaCallbackCount, 1)
        XCTAssertTrue(media.report.identity == receipt.lastCallbackReportIdentity)
        XCTAssertTrue(try XCTUnwrap(media.publicationEvidence).matches(media))
        for (index, start) in [CMTime(value: 1, timescale: 48_000), CMTime(value: 1, timescale: 90_000)].enumerated() {
            let duration = CMTime(value: 1_001, timescale: 30_000)
            let exactFixture = try Task17Fixtures.realH264Sample(presentationTimeStamp: start, duration: duration)
            let exactCollector = Task17ObjectCollector()
            let exactBoundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: start, videoMode: .passthrough))
            let exactWriter = try Task17Fixtures.makeWriter(seed: UInt64(1_810 + index), kind: .video,
                sourceFormatHint: exactFixture.format, boundary: exactBoundary, collector: exactCollector)
            let exactOutput = Task17Fixtures.videoOutput(fixture: exactFixture, generation: 1, accessUnitID: 1, sequenceNumber: 1)
            try exactWriter.start(at: start)
            let ticket = try exactBoundary.issueVideoAppend(for: exactOutput, writerBinding: exactWriter.binding)
            XCTAssertNil(ticket.committedBoundary)
            try exactWriter.appendVideo(exactOutput, ticket: ticket)
            XCTAssertEqual(try XCTUnwrap(ticket.committedBoundary).commonStart, try ExactMediaTime(start))
            _ = try await exactWriter.finish()
            let exactMedia = try XCTUnwrap(exactCollector.objects.first { $0.kind == .media })
            XCTAssertEqual(try ExactMediaTime(XCTUnwrap(exactMedia.report.earliestPresentationTimeStamp)), try ExactMediaTime(start))
            XCTAssertEqual(try ExactMediaTime(XCTUnwrap(exactMedia.report.duration)), try ExactMediaTime(duration))
            XCTAssertTrue(try XCTUnwrap(exactMedia.publicationEvidence).matches(exactMedia))
        }
    }

    func testRealAACWriterProducesRecognizableInitializationAndMediaCallbacks() async throws {
        let epoch = try await Task17Fixtures.realAACEncodedEpoch()
        let collector = Task17ObjectCollector()
        let writer = try Task17Fixtures.makeWriter(
            seed: 1_900,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            collector: collector
        )
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try writer.appendAACEncodedEpoch(
            epoch,
            coordinator: try Task17Fixtures.aacCoordinator(epoch: epoch, writer: writer)
        )
        let receipt = try await writer.finish()
        let initialization = try XCTUnwrap(collector.objects.first { $0.kind == .initialization })
        let media = try XCTUnwrap(collector.objects.first { $0.kind == .media })
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("ftyp", in: initialization.bytes))
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("moov", in: initialization.bytes))
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("moof", in: media.bytes))
        XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("mdat", in: media.bytes))
        XCTAssertEqual(receipt.initializationCallbackCount, 1)
        XCTAssertGreaterThanOrEqual(receipt.mediaCallbackCount, 1)
        XCTAssertNotNil(media.report.systemReport)
        XCTAssertTrue(try XCTUnwrap(initialization.publicationEvidence).matches(initialization))
        XCTAssertTrue(try XCTUnwrap(media.publicationEvidence).matches(media))
        XCTAssertEqual(media.publicationEvidence?.format.codec, "mp4a.40.2")
        XCTAssertEqual(media.publicationEvidence?.format.channels, 2)
    }

    func testWriterGraphDeinitializesWithoutExplicitClose() throws {
        let factory = Task17FakeSystemWriterFactory(defersMediaCallback: true)
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1))
        )
        Task17BoundaryRegistry.shared.install(
            boundary,
            for: Task17Fixtures.binding(seed: 2_000).writerIdentity
        )
        var relay: SegmentReportRelay? = SegmentReportRelay(
            binding: Task17Fixtures.binding(seed: 2_000),
            limits: .audio,
            capacity: 8,
            objectSink: { _ in }
        )
        weak var weakRelay: SegmentReportRelay?
        weakRelay = relay
        weak var weakWriter: SegmentedFMP4Writer?
        weak var weakSystemWriter: Task17FakeSystemWriter?
        autoreleasepool {
            var writer: SegmentedFMP4Writer? = try? SegmentedFMP4Writer(
                binding: Task17Fixtures.binding(seed: 2_000),
                trackKind: .aac,
                sourceFormatHint: Task17Fixtures.audioFormat(),
                boundarySession: boundary.session,
                compressedFormatConfiguration: nil,
                relay: relay!,
                systemFactory: factory
            )
            weakWriter = writer
            weakSystemWriter = factory.lastWriter
            try? writer?.start(at: CMTime(value: 10, timescale: 1))
            if let writer, let epoch = try? Task17Fixtures.aacEpoch(bufferCount: 1) {
                try? writer.appendAACEncodedEpoch(
                    epoch,
                    coordinator: try Task17Fixtures.aacCoordinator(epoch: epoch, writer: writer)
                )
            }
            writer = nil
        }
        relay = nil
        XCTAssertNil(weakWriter)
        XCTAssertNil(weakSystemWriter)
        XCTAssertNil(weakRelay)
        XCTAssertNil(factory.delegateObjectIdentifiers.last ?? nil)
    }

    func testTypedVideoTicketBindsWriterSampleAndSequenceAndIsOneShot() throws {
        let start = CMTime(value: 900_000, timescale: 90_000)
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: start, videoMode: .passthrough)
        )
        let firstFactory = Task17FakeSystemWriterFactory()
        let secondFactory = Task17FakeSystemWriterFactory()
        let fixture = try Task17Fixtures.realH264Sample(
            presentationTimeStamp: start,
            duration: CMTime(value: 3_000, timescale: 90_000)
        )
        let output = Task17Fixtures.videoOutput(
            fixture: fixture,
            generation: 31,
            accessUnitID: 41,
            sequenceNumber: 51
        )
        let first = try Task17Fixtures.makeWriter(
            seed: 2_100,
            kind: .video,
            sourceFormatHint: fixture.format,
            boundary: boundary,
            factory: firstFactory
        )
        let second = try Task17Fixtures.makeWriter(
            seed: 2_101,
            kind: .video,
            sourceFormatHint: fixture.format,
            boundary: boundary,
            factory: secondFactory
        )
        try first.start(at: start)
        try second.start(at: start)

        let ticket = try boundary.issueVideoAppend(
            for: output,
            writerBinding: first.binding
        )
        XCTAssertThrowsError(try second.appendVideo(output, ticket: ticket))
        XCTAssertEqual(secondFactory.lastWriter?.appendCount, 0)
        try first.appendVideo(output, ticket: ticket)
        XCTAssertEqual(firstFactory.lastWriter?.appendCount, 1)
        XCTAssertThrowsError(try first.appendVideo(output, ticket: ticket))
        XCTAssertEqual(firstFactory.lastWriter?.appendCount, 1)

        let mutated = Task17Fixtures.videoOutput(
            fixture: fixture,
            generation: 31,
            accessUnitID: 41,
            sequenceNumber: 52
        )
        let mutationTicket = try boundary.issueVideoAppend(
            for: output,
            writerBinding: first.binding
        )
        XCTAssertThrowsError(try first.appendVideo(mutated, ticket: mutationTicket))
        XCTAssertEqual(firstFactory.lastWriter?.appendCount, 1)
        XCTAssertThrowsError(try boundary.issueVideoAppend(
            for: Task17Fixtures.videoOutput(
                fixture: try Task17Fixtures.realH264Sample(
                    presentationTimeStamp: CMTimeAdd(start, CMTime(value: 181_000, timescale: 90_000)),
                    duration: CMTime(value: 3_000, timescale: 90_000)
                ),
                generation: 31,
                accessUnitID: 42,
                sequenceNumber: 53
            ),
            writerBinding: first.binding
        ))
        _ = first.cancel()
        _ = second.cancel()
    }

    func testCompressedPreflightRejectsWrongTicketTerminalCapacityAndReadinessBeforeClaim() throws {
        let scenarios: [(UInt64, Task17SystemFailurePoint?, Bool, Bool)] = [
            (2_200, nil, true, false),
            (2_210, nil, false, true),
            (2_220, nil, false, false),
            (2_230, .readiness, false, false),
        ]
        for (seed, failure, wrongTicket, terminal) in scenarios {
            let harness = try Task17AC3Harness(seed: seed)
            let accessUnit = try harness.makeAccessUnit(presentationTimeStamp: .zero)
            let lease = try XCTUnwrap(accessUnit.directLeaseIdentity)
            let bundle = try XCTUnwrap(accessUnit.directBundleIdentity)
            let factory = Task17FakeSystemWriterFactory(failurePoint: failure)
            let limits = seed == 2_220
                ? FMP4WriterLimits(
                    writerSoftSegmentCount: 1,
                    writerHardSegmentCount: 1,
                    writerSoftByteCount: 16,
                    writerHardByteCount: 32
                )
                : .audio
            let writer = try Task17Fixtures.makeWriter(
                seed: seed,
                kind: .ac3,
                sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: accessUnit),
                compressedFormatConfiguration: accessUnit.formatConfiguration,
                factory: factory,
                limits: limits
            )
            try writer.start(at: .zero)
            let boundary = try XCTUnwrap(
                Task17BoundaryRegistry.shared.boundary(for: writer.binding.writerIdentity)
            )
            try boundary.registerAudioRendition(
                writer.binding.renditionIdentity,
                accessUnit: .ac3(sampleRate: 48_000),
                firstEffectiveStart: .zero
            )
            let issuedBinding = wrongTicket
                ? FMP4WriterBinding(
                    outputLifecycleEpoch: writer.binding.outputLifecycleEpoch,
                    itemGeneration: writer.binding.itemGeneration,
                    mediaEpoch: writer.binding.mediaEpoch,
                    publicationParticipantID: writer.binding.publicationParticipantID,
                    renditionIdentity: writer.binding.renditionIdentity,
                    writerIdentity: FMP4WriterIdentity(rawValue: seed + 9_000)
                )
                : writer.binding
            let ticket = try boundary.issueCompressedAudioAppend(
                for: accessUnit,
                writerBinding: issuedBinding
            )
            if terminal { _ = writer.cancel() }

            XCTAssertThrowsError(try writer.appendCompressed(
                accessUnit.writerSubmission,
                coordinator: harness.coordinator,
                ticket: ticket
            ))
            XCTAssertEqual(factory.lastWriter?.appendCount, 0)
            XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 0)
            XCTAssertEqual(
                harness.coordinator.branchLeaseState(lease),
                .transferred(.compressedAccessUnit(bundle))
            )
            _ = writer.cancel()
        }
    }

    func testWriterLaneCancelsRealSystemBeforeFailureReleaseAndSerializesAppendAgainstCancel() throws {
        let failedFactory = Task17FakeSystemWriterFactory(failurePoint: .append)
        let failedFixture = try Task17Fixtures.realH264Sample()
        let failedBoundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let failedWriter = try Task17Fixtures.makeWriter(
            seed: 2_300,
            kind: .video,
            sourceFormatHint: failedFixture.format,
            boundary: failedBoundary,
            factory: failedFactory
        )
        let failedOutput = Task17Fixtures.videoOutput(
            fixture: failedFixture,
            generation: 61,
            accessUnitID: 71,
            sequenceNumber: 81
        )
        try failedWriter.start(at: .zero)
        let failedTicket = try failedBoundary.issueVideoAppend(
            for: failedOutput,
            writerBinding: failedWriter.binding
        )
        XCTAssertThrowsError(try failedWriter.appendVideo(failedOutput, ticket: failedTicket))
        XCTAssertEqual(Array(failedFactory.lastWriter?.calls.suffix(2) ?? []), [.append, .cancel])
        XCTAssertTrue(failedFactory.lastWriter?.isTerminal == true)
        XCTAssertEqual(failedWriter.terminalReceipt?.terminalReason, .failed)

        let compressedHarness = try Task17AC3Harness(seed: 2_305)
        let compressedUnit = try compressedHarness.makeAccessUnit(presentationTimeStamp: .zero)
        let compressedLease = try XCTUnwrap(compressedUnit.directLeaseIdentity)
        let compressedFactory = Task17FakeSystemWriterFactory(failurePoint: .append)
        let compressedWriter = try Task17Fixtures.makeWriter(
            seed: 2_305,
            kind: .ac3,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: compressedUnit),
            compressedFormatConfiguration: compressedUnit.formatConfiguration,
            factory: compressedFactory
        )
        let compressedBoundary = try XCTUnwrap(
            Task17BoundaryRegistry.shared.boundary(for: compressedWriter.binding.writerIdentity)
        )
        try compressedBoundary.registerAudioRendition(
            compressedWriter.binding.renditionIdentity,
            accessUnit: .ac3(sampleRate: 48_000),
            firstEffectiveStart: .zero
        )
        try compressedWriter.start(at: .zero)
        XCTAssertThrowsError(try compressedWriter.appendCompressed(
            compressedUnit.writerSubmission,
            coordinator: compressedHarness.coordinator,
            ticket: try compressedBoundary.issueCompressedAudioAppend(
                for: compressedUnit,
                writerBinding: compressedWriter.binding
            )
        ))
        XCTAssertEqual(Array(compressedFactory.lastWriter?.calls.suffix(2) ?? []), [.append, .cancel])
        XCTAssertTrue(compressedFactory.lastWriter?.isTerminal == true)
        XCTAssertEqual(compressedHarness.coordinator.branchLeaseState(compressedLease), .released)

        let blockedFactory = Task17FakeSystemWriterFactory(blocksAppend: true)
        let blockedFixture = try Task17Fixtures.realH264Sample()
        let blockedBoundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let blockedWriter = try Task17Fixtures.makeWriter(
            seed: 2_301,
            kind: .video,
            sourceFormatHint: blockedFixture.format,
            boundary: blockedBoundary,
            factory: blockedFactory
        )
        let blockedOutput = Task17Fixtures.videoOutput(
            fixture: blockedFixture,
            generation: 62,
            accessUnitID: 72,
            sequenceNumber: 82
        )
        try blockedWriter.start(at: .zero)
        let blockedTicket = try blockedBoundary.issueVideoAppend(
            for: blockedOutput,
            writerBinding: blockedWriter.binding
        )
        let appendDone = expectation(description: "append 已结束")
        DispatchQueue.global().async {
            try? blockedWriter.appendVideo(blockedOutput, ticket: blockedTicket)
            appendDone.fulfill()
        }
        XCTAssertEqual(blockedFactory.lastWriter?.waitUntilAppendEntered(timeout: .now() + 2), .success)
        let cancelDone = expectation(description: "cancel 已结束")
        DispatchQueue.global().async {
            _ = blockedWriter.cancel()
            cancelDone.fulfill()
        }
        usleep(20_000)
        XCTAssertEqual(blockedFactory.lastWriter?.calls, [.start, .append])
        blockedFactory.lastWriter?.releaseBlockedAppend()
        wait(for: [appendDone, cancelDone], timeout: 2)
        XCTAssertEqual(Array(blockedFactory.lastWriter?.calls.suffix(2) ?? []), [.append, .cancel])
        XCTAssertEqual(blockedFactory.lastWriter?.cancelCount, 1)
    }

    func testFinishCancelCallbackDisorderAndFatalRejectionConvergeExactlyOnce() async throws {
        let cancelFactory = Task17FakeSystemWriterFactory(defersFinish: true, defersMediaCallback: true)
        let cancelBoundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let cancelWriter = try Task17Fixtures.makeWriter(
            seed: 2_400,
            kind: .aac,
            boundary: cancelBoundary,
            factory: cancelFactory
        )
        let cancelEpoch = try Task17Fixtures.aacEpoch(bufferCount: 1, outputBase: .zero)
        try cancelBoundary.registerAudioRendition(
            cancelWriter.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: .zero
        )
        try cancelWriter.start(at: .zero)
        try cancelWriter.appendAACEncodedEpoch(
            cancelEpoch,
            coordinator: cancelBoundary
        )
        let finishResult = Task { () -> Result<SegmentedFMP4WriterTerminalReceipt, Error> in
            do { return .success(try await cancelWriter.finish()) }
            catch { return .failure(error) }
        }
        XCTAssertEqual(cancelFactory.lastWriter?.waitUntilFinishRequested(timeout: .now() + 2), .success)
        let cancelled = cancelWriter.cancel()
        _ = await finishResult.value
        cancelFactory.lastWriter?.completeFinish(success: true)
        cancelFactory.lastWriter?.emitDeferredMediaCallbacks()
        XCTAssertEqual(cancelled.terminalReason, .cancelled)
        XCTAssertEqual(cancelFactory.lastWriter?.cancelCount, 1)
        XCTAssertEqual(cancelWriter.cancel(), cancelled)

        let disorderFactory = Task17FakeSystemWriterFactory(
            defersFinish: true,
            defersMediaCallback: true,
            defersInitializationCallback: true
        )
        let disorderBoundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let disorderWriter = try Task17Fixtures.makeWriter(
            seed: 2_401,
            kind: .aac,
            boundary: disorderBoundary,
            factory: disorderFactory
        )
        let disorderEpoch = try Task17Fixtures.aacEpoch(bufferCount: 1, outputBase: .zero)
        try disorderBoundary.registerAudioRendition(
            disorderWriter.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: .zero
        )
        try disorderWriter.start(at: .zero)
        try disorderWriter.appendAACEncodedEpoch(
            disorderEpoch,
            coordinator: disorderBoundary
        )
        let disorderFinish = Task { try await disorderWriter.finish() }
        XCTAssertEqual(disorderFactory.lastWriter?.waitUntilFinishRequested(timeout: .now() + 2), .success)
        disorderFactory.lastWriter?.completeFinish(success: true)
        disorderFactory.lastWriter?.emitDeferredMediaCallbacks()
        await Task.yield()
        XCTAssertNil(disorderWriter.terminalReceipt)
        disorderFactory.lastWriter?.emitDeferredInitializationCallback()
        let disorderReceipt = try await disorderFinish.value
        XCTAssertEqual(disorderReceipt.terminalReason, .finished)

        let rejectionFactory = Task17FakeSystemWriterFactory(defersFinish: true, defersMediaCallback: true)
        let rejectionWriter = try Task17Fixtures.makeWriter(
            seed: 2_402,
            kind: .aac,
            factory: rejectionFactory,
            limits: FMP4WriterLimits(
                writerSoftSegmentCount: 1,
                writerHardSegmentCount: 3,
                writerSoftByteCount: 32,
                writerHardByteCount: 64
            )
        )
        try rejectionWriter.start(at: .zero)
        let rejectionTask = Task { try await rejectionWriter.finish() }
        XCTAssertEqual(rejectionFactory.lastWriter?.waitUntilFinishRequested(timeout: .now() + 2), .success)
        rejectionFactory.lastWriter?.emitMedia(bytes: Data(repeating: 0x7f, count: 65))
        do {
            _ = try await rejectionTask.value
            XCTFail("超限 callback 必须终结 candidate")
        } catch {
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .systemFailure)
        }
        XCTAssertTrue(rejectionFactory.lastWriter?.isTerminal == true)
        XCTAssertEqual(rejectionFactory.lastWriter?.cancelCount, 1)
        rejectionFactory.lastWriter?.emitMedia(bytes: Data([1]))
        XCTAssertEqual(rejectionFactory.lastWriter?.cancelCount, 1)

        let identityFactory = Task17FakeSystemWriterFactory(defersFinish: true, defersMediaCallback: true)
        let identityWriter = try Task17Fixtures.makeWriter(seed: 2_403, kind: .aac, factory: identityFactory)
        try identityWriter.start(at: .zero)
        let identityTask = Task { try await identityWriter.finish() }
        XCTAssertEqual(identityFactory.lastWriter?.waitUntilFinishRequested(timeout: .now() + 2), .success)
        identityFactory.lastWriter?.emitMedia(
            bytes: Data([1, 2, 3]),
            writerObjectIdentity: ObjectIdentifier(Task17ForeignSystemWriterIdentity.shared)
        )
        do {
            _ = try await identityTask.value
            XCTFail("callback writer identity 不匹配必须终结 candidate")
        } catch {}
        XCTAssertEqual(identityFactory.lastWriter?.cancelCount, 1)
    }

    func testAACEndpointUsesWriterReportAndRejectsIncompleteReplacedMutatedOrConcurrentClaims() async throws {
        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 2)
        let collector = Task17ObjectCollector()
        let factory = Task17FakeSystemWriterFactory(
            mediaWrittenStart: CMTime(value: 12, timescale: 1)
        )
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1))
        )
        let writer = try Task17Fixtures.makeWriter(
            seed: 2_500,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            boundary: boundary,
            factory: factory,
            collector: collector
        )
        try boundary.registerAudioRendition(
            writer.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: CMTime(value: 10, timescale: 1)
        )
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try writer.appendAACEncodedEpoch(
            epoch,
            coordinator: boundary
        )
        _ = try await writer.finish()
        let initializer = try XCTUnwrap(collector.objects.first { $0.kind == .initialization })
        let media = collector.objects.filter { $0.kind == .media }
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: []
        ))
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: media + media
        ))
        let replacement = SealedMediaObject(
            binding: writer.binding,
            writerIdentity: writer.binding.writerIdentity,
            callbackTicket: media[0].callbackTicket,
            logicalSequence: media[0].logicalSequence,
            kind: .media,
            sourceBytes: media[0].bytes as NSData,
            report: media[0].report,
            publicationLease: nil
        )
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: [replacement]
        ))
        let extraInputEpoch = try Task17Fixtures.aacEpoch(bufferCount: 3)
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: extraInputEpoch,
            initializationObject: initializer,
            mediaObjects: media
        ))

        try Task17Fixtures.shiftOutputPTS(epoch.buffers[0], by: 1)
        XCTAssertThrowsError(try writer.makeAACEffectiveEndpointReceipt(
            epoch: epoch,
            initializationObject: initializer,
            mediaObjects: media
        ))
        try Task17Fixtures.shiftOutputPTS(epoch.buffers[0], by: -1)

        let outcomes = Task17LockedResults()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        let receipt = try writer.makeAACEffectiveEndpointReceipt(
                            epoch: epoch,
                            initializationObject: initializer,
                            mediaObjects: media
                        )
                        outcomes.append(.success(receipt))
                    } catch {
                        outcomes.append(.failure(error))
                    }
                }
            }
        }
        XCTAssertEqual(outcomes.successCount, 1)
        let receipt = try XCTUnwrap(outcomes.firstSuccess)
        XCTAssertEqual(receipt.writtenEffectiveBase, ExactMediaTime(value: 12, timescale: 1))
        XCTAssertEqual(receipt.callbackEvidenceCount, 2)
        XCTAssertEqual(receipt.inputEvidenceCount, 2)
        XCTAssertEqual(receipt.mappingReportIdentity, media[0].report.identity)
    }

    func testReencodedClosedGOPAcceptsInteriorFramesAndRejectsEarlyOrLateIDR() throws {
        let start = CMTime(value: 900_000, timescale: 90_000)
        let coordinator = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: start, videoMode: .reencodedClosedGOP)
        )
        XCTAssertFalse(try coordinator.inspectVideoBoundary(at: start, isIDR: true).requiresFlushBeforeAppend)
        for frame in 1..<30 {
            XCTAssertFalse(try coordinator.inspectVideoBoundary(
                at: CMTime(value: 900_000 + Int64(frame * 3_000), timescale: 90_000),
                isIDR: false
            ).requiresFlushBeforeAppend)
        }
        XCTAssertTrue(try coordinator.inspectVideoBoundary(
            at: CMTime(value: 990_000, timescale: 90_000),
            isIDR: true
        ).requiresFlushBeforeAppend)

        for offset in [15_000, 90_001] {
            let invalid = try SegmentBoundaryCoordinator(
                mode: .audioVideo(epochStart: start, videoMode: .reencodedClosedGOP)
            )
            _ = try invalid.inspectVideoBoundary(at: start, isIDR: true)
            XCTAssertThrowsError(try invalid.inspectVideoBoundary(
                at: CMTime(value: 900_000 + Int64(offset), timescale: 90_000),
                isIDR: true
            ))
        }
    }

    func testActualCallbackCapacityAndUnpublishedSequenceLeasesCannotBeBypassed() async throws {
        let limits = FMP4WriterLimits(
            writerSoftSegmentCount: 1,
            writerHardSegmentCount: 3,
            writerSoftByteCount: 192,
            writerHardByteCount: 256
        )
        let acceptedFactory = Task17FakeSystemWriterFactory(mediaPayloadByteCount: 240)
        let acceptedFixture = try Task17Fixtures.realH264Sample()
        let acceptedBoundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let acceptedWriter = try Task17Fixtures.makeWriter(
            seed: 2_700,
            kind: .video,
            sourceFormatHint: acceptedFixture.format,
            boundary: acceptedBoundary,
            factory: acceptedFactory,
            limits: limits
        )
        let output = Task17Fixtures.videoOutput(
            fixture: acceptedFixture,
            generation: 91,
            accessUnitID: 92,
            sequenceNumber: 93
        )
        try acceptedWriter.start(at: .zero)
        try acceptedWriter.appendVideo(
            output,
            ticket: try acceptedBoundary.issueVideoAppend(
                for: output,
                writerBinding: acceptedWriter.binding
            )
        )
        let acceptedReceipt = try await acceptedWriter.finish()
        XCTAssertEqual(acceptedReceipt.terminalReason, .finished)

        let rejectedFactory = Task17FakeSystemWriterFactory(mediaPayloadByteCount: 257)
        let rejectedFixture = try Task17Fixtures.realH264Sample()
        let rejectedBoundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let rejectedWriter = try Task17Fixtures.makeWriter(
            seed: 2_701,
            kind: .video,
            sourceFormatHint: rejectedFixture.format,
            boundary: rejectedBoundary,
            factory: rejectedFactory,
            limits: limits
        )
        let rejectedOutput = Task17Fixtures.videoOutput(
            fixture: rejectedFixture,
            generation: 94,
            accessUnitID: 95,
            sequenceNumber: 96
        )
        try rejectedWriter.start(at: .zero)
        try rejectedWriter.appendVideo(
            rejectedOutput,
            ticket: try rejectedBoundary.issueVideoAppend(
                for: rejectedOutput,
                writerBinding: rejectedWriter.binding
            )
        )
        do {
            _ = try await rejectedWriter.finish()
            XCTFail("actual callback 超过 hard cap 必须失败")
        } catch {}
        XCTAssertEqual(rejectedFactory.lastWriter?.cancelCount, 1)

        let cumulativeLimits = FMP4WriterLimits(
            writerSoftSegmentCount: 1,
            writerHardSegmentCount: 3,
            writerSoftByteCount: 128,
            writerHardByteCount: 256
        )
        let cumulativeFactory = Task17FakeSystemWriterFactory(mediaPayloadByteCount: 90)
        let cumulativeFixture = try Task17Fixtures.realH264Sample()
        let cumulativeBoundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let cumulativeWriter = try Task17Fixtures.makeWriter(
            seed: 2_704,
            kind: .video,
            sourceFormatHint: cumulativeFixture.format,
            boundary: cumulativeBoundary,
            factory: cumulativeFactory,
            limits: cumulativeLimits
        )
        try cumulativeWriter.start(at: .zero)
        for sequence in 0..<3 {
            let timedFixture = try Task17Fixtures.realH264Sample(
                presentationTimeStamp: CMTime(value: Int64(sequence), timescale: 1),
                duration: CMTime(value: 1, timescale: 30)
            )
            let timedOutput = Task17Fixtures.videoOutput(
                fixture: timedFixture,
                generation: 101,
                accessUnitID: UInt64(110 + sequence),
                sequenceNumber: UInt64(120 + sequence)
            )
            if sequence == 0 {
                try cumulativeWriter.appendVideo(
                    timedOutput,
                    ticket: try cumulativeBoundary.issueVideoAppend(
                        for: timedOutput,
                        writerBinding: cumulativeWriter.binding
                    )
                )
            } else {
                try cumulativeWriter.appendVideo(
                    timedOutput,
                    ticket: try cumulativeBoundary.issueVideoAppend(
                        for: timedOutput,
                        writerBinding: cumulativeWriter.binding
                    )
                )
            }
        }
        do {
            _ = try await cumulativeWriter.finish()
            XCTFail("三个未发布 actual callback 的累计值超过 hard cap 必须失败")
        } catch {}
        XCTAssertEqual(cumulativeFactory.lastWriter?.cancelCount, 1)

        let firstRelay = SegmentReportRelay(
            binding: Task17Fixtures.binding(seed: 2_702),
            limits: .audio,
            capacity: 3,
            objectSink: { _ in }
        )
        let secondRelay = SegmentReportRelay(
            binding: Task17Fixtures.binding(seed: 2_703),
            limits: .audio,
            capacity: 3,
            objectSink: { _ in }
        )
        let lease = try firstRelay.reserveUnpublishedLogicalSegment(logicalSequence: 7)
        XCTAssertFalse(secondRelay.releaseUnpublishedLogicalSegment(lease))
        XCTAssertTrue(firstRelay.releaseUnpublishedLogicalSegment(lease))
        XCTAssertFalse(firstRelay.releaseUnpublishedLogicalSegment(lease))
        XCTAssertEqual(firstRelay.usage.unpublishedLogicalSegmentCount, 0)
    }

    func testBoundedLedgersRejectFourthRendition129thAUAndSequenceOverflow() throws {
        let start = CMTime(value: 10, timescale: 1)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        for raw in 1...3 {
            try boundary.registerAudioRendition(
                .init(rawValue: UInt64(raw)),
                accessUnit: .aac(sampleRate: 48_000),
                firstEffectiveStart: start
            )
        }
        XCTAssertThrowsError(try boundary.registerAudioRendition(
            .init(rawValue: 4),
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: start
        )) { error in
            XCTAssertEqual(error as? SegmentBoundaryFailure, .renditionCapacityExceeded)
        }
        for second in 1...64 {
            _ = try boundary.inspectAudioBoundary(
                rendition: .init(rawValue: 1),
                at: CMTime(value: Int64(10 + second), timescale: 1)
            )
        }
        XCTAssertLessThanOrEqual(boundary.inspectionUsage.commonBoundarySlotCount, 4)
        XCTAssertEqual(boundary.inspectionUsage.lastLogicalSequence, 64)

        let overflow = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: start),
            sequenceAllocator: SegmentSequenceAllocator(initialValue: UInt64.max)
        )
        try overflow.registerAudioRendition(
            .init(rawValue: 1),
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: start
        )
        XCTAssertThrowsError(try overflow.inspectAudioBoundary(
            rendition: .init(rawValue: 1),
            at: CMTime(value: 11, timescale: 1)
        )) { error in
            XCTAssertEqual(error as? SegmentBoundaryFailure, .arithmeticOverflow)
        }

        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 129, outputBase: start)
        let factory = Task17FakeSystemWriterFactory()
        let writerBoundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let writer = try Task17Fixtures.makeWriter(
            seed: 2_800,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            boundary: writerBoundary,
            factory: factory
        )
        try writerBoundary.registerAudioRendition(
            writer.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: start
        )
        try writer.start(at: start)
        XCTAssertThrowsError(try writer.appendAACEncodedEpoch(
            epoch,
            coordinator: writerBoundary
        )) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .inputEvidenceCapacityExceeded)
        }
        XCTAssertEqual(factory.lastWriter?.appendCount, 0)
        XCTAssertEqual(factory.lastWriter?.cancelCount, 0)
        _ = writer.cancel()
    }

    func testVideoWriterCapacityAccommodatesHighFrameRateSegment() throws {
        let start = CMTime(value: 0, timescale: 90_000)
        let frameDuration = CMTime(value: 450, timescale: 90_000) // 5ms per frame, 130 frames = 650ms < 1s
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: start, videoMode: .passthrough, maximumPassthroughInterval: CMTime(value: 6, timescale: 1))
        )
        let factory = Task17FakeSystemWriterFactory()
        let initialSample = try Task17Fixtures.realH264Sample(presentationTimeStamp: start, duration: frameDuration)
        let writer = try Task17Fixtures.makeWriter(
            seed: 3_950,
            kind: .video,
            sourceFormatHint: initialSample.format,
            boundary: boundary,
            factory: factory
        )
        try writer.start(at: start)
        for i in 0..<130 {
            let pts = CMTime(value: Int64(i * 450), timescale: 90_000)
            let frame = try Task17Fixtures.realH264Sample(presentationTimeStamp: pts, duration: frameDuration)
            let output = Task17Fixtures.videoOutput(
                fixture: frame,
                generation: 3_950,
                accessUnitID: UInt64(i + 1),
                sequenceNumber: UInt64(i + 1)
            )
            let ticket = try boundary.issueVideoAppend(for: output, writerBinding: writer.binding)
            try writer.appendVideo(output, ticket: ticket)
        }
        XCTAssertEqual(factory.lastWriter?.appendCount, 130)
        _ = writer.cancel()
    }

    func testAudioBoundaryUsesHalfOpenAUDurationAndSealedBytesShareFrozenBacking() throws {
        let boundaryStart = CMTime(value: 10, timescale: 1)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: boundaryStart))
        let rendition = AudioRenditionIdentity(rawValue: 2_900)
        try boundary.registerAudioRendition(
            rendition,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: boundaryStart
        )
        let finerLastHalfTick = CMTime(value: 1_058_047, timescale: 96_000)
        XCTAssertTrue(try boundary.inspectAudioBoundary(
            rendition: rendition,
            at: finerLastHalfTick
        ).requiresFlushBeforeAppend)

        let exactEnd = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: boundaryStart))
        try exactEnd.registerAudioRendition(
            rendition,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: boundaryStart
        )
        XCTAssertThrowsError(try exactEnd.inspectAudioBoundary(
            rendition: rendition,
            at: CMTime(value: 529_024, timescale: 48_000)
        )) { error in
            XCTAssertEqual(error as? SegmentBoundaryFailure, .audioBoundaryExceeded)
        }

        let sealed = try Task17Fixtures.sealedObject(
            binding: Task17Fixtures.binding(seed: 2_900),
            kind: .media,
            logicalSequence: 0,
            bytes: Data(repeating: 0xA5, count: 64)
        )
        XCTAssertEqual(sealed.bytes, sealed.backing.bytes)
        XCTAssertEqual(sealed.byteRange.offset, 0)
        XCTAssertEqual(sealed.byteRange.length, sealed.backing.bytes.count)
        XCTAssertEqual(sealed.bytes.withUnsafeBytes { $0.baseAddress }, sealed.backing.bytes.withUnsafeBytes { $0.baseAddress })
    }

    func testBoundarySessionRejectsForgedIssuerRenditionAndPostIssueMutationAndAbortsFailedAppend() throws {
        let official = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let videoFixture = try Task17Fixtures.realH264Sample()
        let videoOutput = Task17Fixtures.videoOutput(
            fixture: videoFixture,
            generation: 301,
            accessUnitID: 302,
            sequenceNumber: 303
        )
        let videoFactory = Task17FakeSystemWriterFactory()
        let videoWriter = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_100,
            kind: .video,
            boundary: official,
            sourceFormatHint: videoFixture.format,
            factory: videoFactory
        )
        try videoWriter.start(at: .zero)

        let forged = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        XCTAssertThrowsError(try videoWriter.appendVideo(
            videoOutput,
            ticket: try forged.issueVideoAppend(for: videoOutput, writerBinding: videoWriter.binding)
        ))
        XCTAssertEqual(videoFactory.lastWriter?.appendCount, 0)

        let syncMutationTicket = try official.issueVideoAppend(
            for: videoOutput,
            writerBinding: videoWriter.binding
        )
        try Task17Fixtures.setVideoNotSync(videoFixture.sample, true)
        XCTAssertThrowsError(try videoWriter.appendVideo(videoOutput, ticket: syncMutationTicket))
        XCTAssertEqual(videoFactory.lastWriter?.appendCount, 0)
        try Task17Fixtures.setVideoNotSync(videoFixture.sample, false)

        let originalPayload = Data([0, 0, 0, 2, 0x65, 0x80])
        let payloadMutationTicket = try official.issueVideoAppend(
            for: videoOutput,
            writerBinding: videoWriter.binding
        )
        try Task17Fixtures.replacePayload(
            videoFixture.sample,
            with: Data([0, 0, 0, 2, 0x65, 0x81])
        )
        XCTAssertThrowsError(try videoWriter.appendVideo(videoOutput, ticket: payloadMutationTicket))
        XCTAssertEqual(videoFactory.lastWriter?.appendCount, 0)
        try Task17Fixtures.replacePayload(videoFixture.sample, with: originalPayload)

        try videoWriter.appendVideo(
            videoOutput,
            ticket: try official.issueVideoAppend(for: videoOutput, writerBinding: videoWriter.binding)
        )
        XCTAssertEqual(videoFactory.lastWriter?.appendCount, 1)

        let audioEpoch = try Task17Fixtures.aacEpoch(bufferCount: 1, outputBase: .zero)
        let audioFactory = Task17FakeSystemWriterFactory()
        let audioWriter = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_101,
            kind: .aac,
            boundary: official,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(audioEpoch.buffers[0])),
            factory: audioFactory
        )
        try official.registerAudioRendition(
            audioWriter.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: .zero
        )
        try audioWriter.start(at: .zero)
        XCTAssertThrowsError(try official.issueAACAppend(
            for: audioEpoch.buffers[0],
            rendition: .init(rawValue: 99_999),
            writerBinding: audioWriter.binding
        ))
        try audioWriter.appendAACEncodedEpoch(
            audioEpoch,
            coordinator: official
        )
        XCTAssertEqual(audioFactory.lastWriter?.appendCount, 1)

        let transactional = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let firstFixture = try Task17Fixtures.realH264Sample()
        let firstOutput = Task17Fixtures.videoOutput(
            fixture: firstFixture,
            generation: 311,
            accessUnitID: 312,
            sequenceNumber: 313
        )
        let failedFactory = Task17FakeSystemWriterFactory()
        let failedWriter = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_110,
            kind: .video,
            boundary: transactional,
            sourceFormatHint: firstFixture.format,
            factory: failedFactory
        )
        try failedWriter.start(at: .zero)
        try failedWriter.appendVideo(
            firstOutput,
            ticket: try transactional.issueVideoAppend(for: firstOutput, writerBinding: failedWriter.binding)
        )
        let boundaryFixture = try Task17Fixtures.realH264Sample(
            presentationTimeStamp: CMTime(value: 1, timescale: 1)
        )
        let boundaryOutput = Task17Fixtures.videoOutput(
            fixture: boundaryFixture,
            generation: 311,
            accessUnitID: 314,
            sequenceNumber: 315
        )
        failedFactory.lastWriter?.rejectNextAppend()
        XCTAssertThrowsError(try failedWriter.appendVideo(
            boundaryOutput,
            ticket: try transactional.issueVideoAppend(
                for: boundaryOutput,
                writerBinding: failedWriter.binding
            )
        ))

        let retryFactory = Task17FakeSystemWriterFactory()
        let retryWriter = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_111,
            kind: .video,
            boundary: transactional,
            sourceFormatHint: boundaryFixture.format,
            factory: retryFactory
        )
        try retryWriter.start(at: .zero)
        let retryTicket = try transactional.issueVideoAppend(
            for: boundaryOutput,
            writerBinding: retryWriter.binding
        )
        XCTAssertEqual(retryTicket.logicalSequence, 1)
        XCTAssertTrue(retryTicket.requiresFlushBeforeAppend)
        try retryWriter.appendVideo(boundaryOutput, ticket: retryTicket)
        XCTAssertEqual(retryFactory.lastWriter?.appendCount, 1)
        _ = retryWriter.cancel()
        _ = videoWriter.cancel()
        _ = audioWriter.cancel()
    }

    func testCompressedWriterUsesFrozenFormatConfigurationBeforeTask16Claim() throws {
        let harness = try Task17AC3Harness(seed: 3_200)
        let accessUnit = try harness.makeAccessUnit(presentationTimeStamp: .zero)
        let alternateFrame = AssemblerTestFixtures.syntheticAC3Frame(
            fscod: 0,
            frmsizecod: 22,
            bsmod: 1
        )
        let alternateConfiguration = CompressedAudioFormatConfiguration.ac3(
            try AC3CompressedAudioConfiguration(inspection: AC3FrameInspector.inspect(alternateFrame))
        )
        XCTAssertNotEqual(alternateConfiguration, accessUnit.formatConfiguration)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_200,
            kind: .ac3,
            boundary: boundary,
            sourceFormatHint: Task17Fixtures.audioFormat(
                formatID: kAudioFormatAC3,
                framesPerPacket: 1_536,
                magicCookie: alternateConfiguration.serializedBox
            ),
            compressedFormatConfiguration: alternateConfiguration,
            factory: factory
        )
        try boundary.registerAudioRendition(
            writer.binding.renditionIdentity,
            accessUnit: .ac3(sampleRate: 48_000),
            firstEffectiveStart: .zero
        )
        try writer.start(at: .zero)
        XCTAssertThrowsError(try writer.appendCompressed(
            accessUnit.writerSubmission,
            coordinator: harness.coordinator,
            ticket: try boundary.issueCompressedAudioAppend(
                for: accessUnit,
                writerBinding: writer.binding
            )
        )) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .compressedIdentityMismatch)
        }
        XCTAssertEqual(factory.lastWriter?.appendCount, 0)
        XCTAssertEqual(harness.coordinator.claimedCompressedWriterSubmissionCount, 0)
        XCTAssertEqual(
            harness.coordinator.branchLeaseState(try XCTUnwrap(accessUnit.directLeaseIdentity)),
            .transferred(.compressedAccessUnit(try XCTUnwrap(accessUnit.directBundleIdentity)))
        )
        _ = writer.cancel()
    }

    func testAACEndpointDerivesCountsOrderingAndTrimPlacementFromActualBuffers() async throws {
        func replacingCounts(
            _ epoch: AACEncodedEpoch,
            real: Int? = nil,
            total: Int? = nil,
            leading: Int? = nil,
            trailing: Int? = nil
        ) -> AACEncodedEpoch {
            AACEncodedEpoch(
                identity: epoch.identity,
                buffers: epoch.buffers,
                realSampleCount: real ?? epoch.realSampleCount,
                totalDecodedFrames: total ?? epoch.totalDecodedFrames,
                leadingFrames: leading ?? epoch.leadingFrames,
                trailingFrames: trailing ?? epoch.trailingFrames,
                actualLeadingPrimeFrames: epoch.actualLeadingPrimeFrames,
                actualTrailingPrimeFrames: epoch.actualTrailingPrimeFrames,
                bandwidth: epoch.bandwidth,
                packetLease: epoch.packetLease,
                formatLease: epoch.formatLease
            )
        }

        let base = try Task17Fixtures.aacEpoch(bufferCount: 3)
        let forgedTuples = [
            replacingCounts(base, real: base.realSampleCount + 1),
            replacingCounts(base, total: base.totalDecodedFrames + 1),
            replacingCounts(base, leading: base.leadingFrames + 1),
            replacingCounts(base, trailing: base.trailingFrames + 1),
        ]
        for (offset, epoch) in forgedTuples.enumerated() {
            let boundary = try SegmentBoundaryCoordinator(
                mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1))
            )
            let factory = Task17FakeSystemWriterFactory()
            let writer = try Task17Fixtures.makeAuthorizedWriter(
                seed: UInt64(3_300 + offset),
                kind: .aac,
                boundary: boundary,
                sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
                factory: factory
            )
            try boundary.registerAudioRendition(
                writer.binding.renditionIdentity,
                accessUnit: .aac(sampleRate: 48_000),
                firstEffectiveStart: CMTime(value: 10, timescale: 1)
            )
            try writer.start(at: CMTime(value: 10, timescale: 1))
            XCTAssertThrowsError(try writer.appendAACEncodedEpoch(
                epoch,
                coordinator: boundary
            ))
            XCTAssertEqual(factory.lastWriter?.appendCount, 0)
            _ = writer.cancel()
        }

        var malformed: [AACEncodedEpoch] = []
        let nonFirstStart = try Task17Fixtures.aacEpoch(bufferCount: 3)
        Task17Fixtures.removeTrim(nonFirstStart.buffers[0], key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        Task17Fixtures.setTrim(nonFirstStart.buffers[1], key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, samples: 128)
        malformed.append(nonFirstStart)
        let nonLastEnd = try Task17Fixtures.aacEpoch(bufferCount: 3)
        Task17Fixtures.setTrim(nonLastEnd.buffers[0], key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, samples: 128)
        malformed.append(nonLastEnd)
        let duplicateStart = try Task17Fixtures.aacEpoch(bufferCount: 3)
        Task17Fixtures.setTrim(duplicateStart.buffers[1], key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, samples: 1)
        malformed.append(duplicateStart)
        let oversizedTrim = try Task17Fixtures.aacEpoch(bufferCount: 3)
        Task17Fixtures.setTrim(oversizedTrim.buffers[0], key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, samples: 1_025)
        malformed.append(oversizedTrim)
        let discontinuous = try Task17Fixtures.aacEpoch(bufferCount: 3)
        try Task17Fixtures.shiftOutputPTS(discontinuous.buffers[1], by: 1)
        malformed.append(discontinuous)

        for (offset, epoch) in malformed.enumerated() {
            let boundary = try SegmentBoundaryCoordinator(
                mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1))
            )
            let factory = Task17FakeSystemWriterFactory()
            let writer = try Task17Fixtures.makeAuthorizedWriter(
                seed: UInt64(3_310 + offset),
                kind: .aac,
                boundary: boundary,
                sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
                factory: factory
            )
            try boundary.registerAudioRendition(
                writer.binding.renditionIdentity,
                accessUnit: .aac(sampleRate: 48_000),
                firstEffectiveStart: CMTime(value: 10, timescale: 1)
            )
            try writer.start(at: CMTime(value: 10, timescale: 1))
            XCTAssertThrowsError(try writer.appendAACEncodedEpoch(
                epoch,
                coordinator: boundary
            ))
            XCTAssertEqual(factory.lastWriter?.appendCount, 0)
            _ = writer.cancel()
        }

        let realEpoch = try await Task17Fixtures.realAACEncodedEpoch()
        let collector = Task17ObjectCollector()
        let legalBoundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1))
        )
        let legalWriter = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_320,
            kind: .aac,
            boundary: legalBoundary,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(realEpoch.buffers[0])),
            factory: Task17FakeSystemWriterFactory(mediaWrittenStart: CMTime(value: 12, timescale: 1)),
            collector: collector
        )
        try legalBoundary.registerAudioRendition(
            legalWriter.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: CMTime(value: 10, timescale: 1)
        )
        try legalWriter.start(at: CMTime(value: 10, timescale: 1))
        try legalWriter.appendAACEncodedEpoch(
            realEpoch,
            coordinator: legalBoundary
        )
        _ = try await legalWriter.finish()
        let endpoint = try legalWriter.makeAACEffectiveEndpointReceipt(
            epoch: realEpoch,
            initializationObject: try XCTUnwrap(collector.objects.first { $0.kind == .initialization }),
            mediaObjects: collector.objects.filter { $0.kind == .media }
        )
        XCTAssertEqual(endpoint.totalDecodedFrames, Int64(realEpoch.totalDecodedFrames))
        XCTAssertEqual(endpoint.realSampleCount, Int64(realEpoch.realSampleCount))
        XCTAssertEqual(endpoint.leadingFrames, Int64(realEpoch.leadingFrames))
        XCTAssertEqual(endpoint.trailingFrames, Int64(realEpoch.trailingFrames))
    }

    func testCompressedWriterRejectsForeignLifecycleWithOtherwiseIdenticalBinding() throws {
        for kind: SegmentedFMP4TrackKind in [.ac3, .eac3] {
            let seed: UInt64 = kind == .ac3 ? 39_000 : 39_100
            let owner = CompressedAudioBranchOwnerIdentity.audioVideo(
                outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: seed + 99),
                itemGeneration: .init(rawValue: seed + 1),
                mediaEpoch: .init(rawValue: seed + 2),
                publicationParticipantID: .init(rawValue: seed + 3),
                renditionIdentity: .init(rawValue: seed + 4))
            let unit: CompressedAudioAccessUnit
            let coordinator: AudioServiceSemanticCoordinator
            if kind == .ac3 {
                let harness = try Task17AC3Harness(seed: seed, admission: .directCompressed(
                    owner, branchGeneration: seed + 10, admissionFenceRevision: seed + 11))
                unit = try harness.makeAccessUnit(presentationTimeStamp: .zero)
                coordinator = harness.coordinator
            } else {
                let harness = try Task17EAC3Harness(seed: seed, admission: .eac3Aggregation(
                    owner, branchGeneration: seed + 10, admissionFenceRevision: seed + 11))
                unit = try harness.makeSixMemberAccessUnit()
                coordinator = harness.coordinator
            }
            let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
            let factory = Task17FakeSystemWriterFactory()
            let writer = try Task17Fixtures.makeAuthorizedWriter(seed: seed, kind: kind,
                boundary: boundary, sourceFormatHint: Task17Fixtures.compressedAudioFormat(for: unit),
                compressedFormatConfiguration: unit.formatConfiguration, factory: factory)
            try boundary.registerAudioRendition(writer.binding.renditionIdentity,
                accessUnit: kind == .ac3 ? .ac3(sampleRate: 48_000)
                    : .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536),
                firstEffectiveStart: .zero)
            try writer.start(at: .zero)
            let ticket = try boundary.issueCompressedAudioAppend(for: unit, writerBinding: writer.binding)
            XCTAssertThrowsError(try writer.appendCompressed(unit.writerSubmission,
                coordinator: coordinator, ticket: ticket), "跨 lifecycle 的真实压缩 AU 必须在 append 前拒绝")
            XCTAssertEqual(factory.lastWriter?.appendCount, 0)
            _ = writer.cancel()
        }
    }

    func testSegmentCallbackReleasesBacklogButRetainsAC3AndEAC3OwnershipUntilTerminal() throws {
        let ac3Harness = try Task17AC3Harness(seed: 3_400)
        let secondAC3Harness = try Task17AC3Harness(seed: 3_401,
            admission: .directCompressed(Task17Fixtures.compressedOwner(seed: 3_400),
                branchGeneration: 3_411, admissionFenceRevision: 3_412))
        let firstAC3 = try ac3Harness.makeAccessUnit(presentationTimeStamp: .zero)
        let secondAC3 = try secondAC3Harness.makeAccessUnit(
            presentationTimeStamp: CMTime(value: 1, timescale: 1)
        )
        let ac3Boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let ac3Writer = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_400,
            kind: .ac3,
            boundary: ac3Boundary,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: firstAC3),
            compressedFormatConfiguration: firstAC3.formatConfiguration,
            factory: Task17FakeSystemWriterFactory()
        )
        try ac3Boundary.registerAudioRendition(ac3Writer.binding.renditionIdentity, accessUnit: .ac3(sampleRate: 48_000), firstEffectiveStart: .zero)
        try ac3Writer.start(at: .zero)
        try ac3Writer.appendCompressed(
            firstAC3.writerSubmission,
            coordinator: ac3Harness.coordinator,
            ticket: try ac3Boundary.issueCompressedAudioAppend(for: firstAC3, writerBinding: ac3Writer.binding)
        )
        try ac3Writer.appendCompressed(
            secondAC3.writerSubmission,
            coordinator: secondAC3Harness.coordinator,
            ticket: try ac3Boundary.issueCompressedAudioAppend(for: secondAC3, writerBinding: ac3Writer.binding)
        )
        XCTAssertEqual(ac3Writer.usage.retainedTerminalOwnershipCount, 2)
        XCTAssertEqual(ac3Harness.coordinator.branchLeaseState(try XCTUnwrap(firstAC3.directLeaseIdentity)), .transferred(.compressedAccessUnit(try XCTUnwrap(firstAC3.directBundleIdentity))))
        XCTAssertEqual(secondAC3Harness.coordinator.branchLeaseState(try XCTUnwrap(secondAC3.directLeaseIdentity)), .transferred(.compressedAccessUnit(try XCTUnwrap(secondAC3.directBundleIdentity))))
        _ = ac3Writer.cancel()
        XCTAssertEqual(ac3Writer.usage.retainedTerminalOwnershipCount, 0)
        XCTAssertEqual(ac3Harness.coordinator.branchLeaseState(try XCTUnwrap(firstAC3.directLeaseIdentity)), .released)
        XCTAssertEqual(secondAC3Harness.coordinator.branchLeaseState(try XCTUnwrap(secondAC3.directLeaseIdentity)), .released)

        let eac3Harness = try Task17EAC3Harness(seed: 3_410)
        let secondEAC3Harness = try Task17EAC3Harness(seed: 3_411,
            admission: .eac3Aggregation(Task17Fixtures.compressedOwner(seed: 3_410),
                branchGeneration: 3_421, admissionFenceRevision: 3_422))
        let firstEAC3 = try eac3Harness.makeSixMemberAccessUnit(presentationBase: .zero)
        let secondEAC3 = try secondEAC3Harness.makeSixMemberAccessUnit(
            presentationBase: CMTime(value: 1, timescale: 1)
        )
        let eac3Boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let eac3Writer = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_410,
            kind: .eac3,
            boundary: eac3Boundary,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: firstEAC3),
            compressedFormatConfiguration: firstEAC3.formatConfiguration,
            factory: Task17FakeSystemWriterFactory()
        )
        try eac3Boundary.registerAudioRendition(eac3Writer.binding.renditionIdentity, accessUnit: .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536), firstEffectiveStart: .zero)
        try eac3Writer.start(at: .zero)
        try eac3Writer.appendCompressed(
            firstEAC3.writerSubmission,
            coordinator: eac3Harness.coordinator,
            ticket: try eac3Boundary.issueCompressedAudioAppend(for: firstEAC3, writerBinding: eac3Writer.binding)
        )
        try eac3Writer.appendCompressed(
            secondEAC3.writerSubmission,
            coordinator: secondEAC3Harness.coordinator,
            ticket: try eac3Boundary.issueCompressedAudioAppend(for: secondEAC3, writerBinding: eac3Writer.binding)
        )
        XCTAssertEqual(eac3Writer.usage.retainedTerminalOwnershipCount, 2)
        XCTAssertEqual(eac3Harness.states, Array(repeating: .transferred(
            .eac3AccessUnit(try XCTUnwrap(firstEAC3.eac3BundleIdentity))
        ), count: 6))
        XCTAssertEqual(secondEAC3Harness.states, Array(repeating: .transferred(
            .eac3AccessUnit(try XCTUnwrap(secondEAC3.eac3BundleIdentity))
        ), count: 6))
        _ = eac3Writer.cancel()
        XCTAssertEqual(eac3Writer.usage.retainedTerminalOwnershipCount, 0)
        XCTAssertEqual(eac3Harness.states, Array(repeating: .released, count: 6))
        XCTAssertEqual(secondEAC3Harness.states, Array(repeating: .released, count: 6))
    }

    func testAACBatchAndCallbackCASAccountWholeProjectedAndRemainingBacklog() throws {
        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 2)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1)))
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeAuthorizedWriter(
            seed: 3_500,
            kind: .aac,
            boundary: boundary,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            factory: factory,
            limits: FMP4WriterLimits(writerSoftSegmentCount: 1, writerHardSegmentCount: 3, writerSoftByteCount: 120, writerHardByteCount: 150)
        )
        try boundary.registerAudioRendition(writer.binding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000), firstEffectiveStart: CMTime(value: 10, timescale: 1))
        try writer.start(at: CMTime(value: 10, timescale: 1))
        XCTAssertThrowsError(try writer.appendAACEncodedEpoch(
            epoch,
            coordinator: boundary
        ))
        XCTAssertEqual(factory.lastWriter?.appendCount, 0)
        _ = writer.cancel()

        for (actual, accepted) in [(59, true), (60, true), (61, false)] {
            let binding = Task17Fixtures.binding(seed: UInt64(3_510 + actual))
            let relay = SegmentReportRelay(
                binding: binding,
                limits: FMP4WriterLimits(writerSoftSegmentCount: 2, writerHardSegmentCount: 3, writerSoftByteCount: 80, writerHardByteCount: 100),
                capacity: 8,
                objectSink: { _ in }
            )
            let first = try relay.reserve(kind: .media, logicalSequence: 0, projectedByteCount: 40)
            let second = try relay.reserve(kind: .media, logicalSequence: 1, projectedByteCount: 40)
            let result = relay.receive(SegmentCallbackDelivery(
                binding: binding,
                writerIdentity: binding.writerIdentity,
                ticket: first,
                logicalSequence: 0,
                kind: .media,
                bytes: NSData(data: Data(repeating: 0x5a, count: actual)),
                report: SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: nil))
            ))
            if accepted {
                guard case .accepted = result else { return XCTFail("remaining projected + actual 位于 hard cap 内必须接纳") }
            } else {
                XCTAssertEqual(result, .fatal(.writerHardCapacityExceeded))
            }
            XCTAssertTrue(relay.discard(second))
        }
    }

    func testPublicationSinkReentrantCancelObservesFullyCommittedCallbackState() throws {
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: .zero, videoMode: .passthrough))
        let binding = Task17Fixtures.binding(seed: 3_600)
        let probe = Task17ReentrantPublicationProbe()
        let relay = SegmentReportRelay(binding: binding, limits: .video, capacity: 8, objectSink: probe.receive)
        let factory = Task17FakeSystemWriterFactory()
        let firstFixture = try Task17Fixtures.realH264Sample()
        let writer = try SegmentedFMP4Writer(
            binding: binding,
            trackKind: .video,
            sourceFormatHint: firstFixture.format,
            boundarySession: boundary.session,
            compressedFormatConfiguration: nil,
            relay: relay,
            systemFactory: factory
        )
        probe.writer = writer
        try writer.start(at: .zero)
        let first = Task17Fixtures.videoOutput(fixture: firstFixture, generation: 361, accessUnitID: 362, sequenceNumber: 363)
        try writer.appendVideo(first, ticket: try boundary.issueVideoAppend(for: first, writerBinding: binding))
        let secondFixture = try Task17Fixtures.realH264Sample(presentationTimeStamp: CMTime(value: 1, timescale: 1))
        let second = Task17Fixtures.videoOutput(fixture: secondFixture, generation: 361, accessUnitID: 364, sequenceNumber: 365)
        try writer.appendVideo(second, ticket: try boundary.issueVideoAppend(for: second, writerBinding: binding))
        XCTAssertEqual(probe.wait(timeout: .now() + 2), .success)
        let receipt = try XCTUnwrap(probe.receipt)
        XCTAssertEqual(receipt.terminalReason, .cancelled)
        XCTAssertEqual(receipt.mediaCallbackCount, 1)
        XCTAssertEqual(receipt.callbackEvidenceCount, 2)
        XCTAssertEqual(writer.usage.pendingCallbackCount, 0)
        XCTAssertEqual(factory.lastWriter?.cancelCount, 1)
    }

    func testSlowInitializationUsesIndependentSlotFromThreeMediaReservations() throws {
        let binding = Task17Fixtures.binding(seed: 3_700)
        let relay = SegmentReportRelay(
            binding: binding,
            limits: FMP4WriterLimits(writerSoftSegmentCount: 2, writerHardSegmentCount: 3, writerSoftByteCount: 1_024, writerHardByteCount: 2_048),
            capacity: 8,
            objectSink: { _ in }
        )
        let initialization = try relay.reserve(kind: .initialization, logicalSequence: 0, projectedByteCount: 0)
        let media = try (0..<3).map {
            try relay.reserve(kind: .media, logicalSequence: UInt64($0), projectedByteCount: 128)
        }
        XCTAssertEqual(relay.usage.reservedSlots, 4)
        XCTAssertEqual(relay.usage.writerBacklogSegmentCount, 3)
        XCTAssertThrowsError(try relay.reserve(kind: .media, logicalSequence: 3, projectedByteCount: 1)) { error in
            XCTAssertEqual(error as? SegmentReportRelayFailure, .writerHardCapacityExceeded)
        }
        XCTAssertTrue(relay.discard(initialization))
        media.forEach { XCTAssertTrue(relay.discard($0)) }
        XCTAssertEqual(relay.usage.reservedSlots, 0)
    }

    func testInspectionUsesIsolatedStateAndCannotAdvanceFormalVideoOrAudioSession() throws {
        let inspectedVideo = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let untouchedVideo = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        _ = try inspectedVideo.inspectVideoBoundary(at: .zero, isIDR: true)
        _ = try inspectedVideo.inspectVideoBoundary(at: CMTime(value: 1, timescale: 1), isIDR: true)
        _ = try inspectedVideo.inspectVideoBoundary(at: .zero, isIDR: true)
        let videoFixture = try Task17Fixtures.realH264Sample()
        let videoOutput = Task17Fixtures.videoOutput(
            fixture: videoFixture,
            generation: 3_801,
            accessUnitID: 3_802,
            sequenceNumber: 3_803
        )
        let binding = Task17Fixtures.binding(seed: 3_800)
        let inspectedVideoTicket = try inspectedVideo.issueVideoAppend(
            for: videoOutput,
            writerBinding: binding
        )
        let untouchedVideoTicket = try untouchedVideo.issueVideoAppend(
            for: videoOutput,
            writerBinding: binding
        )
        XCTAssertEqual(inspectedVideoTicket.logicalSequence, untouchedVideoTicket.logicalSequence)
        XCTAssertEqual(
            inspectedVideoTicket.requiresFlushBeforeAppend,
            untouchedVideoTicket.requiresFlushBeforeAppend
        )
        inspectedVideoTicket.abort(binding: binding, session: inspectedVideo.session)
        untouchedVideoTicket.abort(binding: binding, session: untouchedVideo.session)

        let start = CMTime(value: 10, timescale: 1)
        let inspectedAudio = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let untouchedAudio = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let rendition = binding.renditionIdentity
        for coordinator in [inspectedAudio, untouchedAudio] {
            try coordinator.registerAudioRendition(
                rendition,
                accessUnit: .aac(sampleRate: 48_000),
                firstEffectiveStart: start
            )
        }
        _ = try inspectedAudio.inspectAudioBoundary(rendition: rendition, at: start)
        _ = try inspectedAudio.inspectAudioBoundary(
            rendition: rendition,
            at: CMTime(value: 11, timescale: 1)
        )
        _ = try inspectedAudio.inspectAudioBoundary(rendition: rendition, at: start)
        let audioBuffer = try Task17Fixtures.aacBuffer(pts: start)
        let inspectedAudioTicket = try inspectedAudio.issueAACAppend(
            for: audioBuffer,
            rendition: rendition,
            writerBinding: binding
        )
        let untouchedAudioTicket = try untouchedAudio.issueAACAppend(
            for: audioBuffer,
            rendition: rendition,
            writerBinding: binding
        )
        XCTAssertEqual(inspectedAudioTicket.logicalSequence, untouchedAudioTicket.logicalSequence)
        XCTAssertEqual(
            inspectedAudioTicket.requiresFlushBeforeAppend,
            untouchedAudioTicket.requiresFlushBeforeAppend
        )
        inspectedAudioTicket.abort(binding: binding, session: inspectedAudio.session)
        untouchedAudioTicket.abort(binding: binding, session: untouchedAudio.session)
    }

    func testAACWriterIssuesSequentialTicketsAcrossBoundaryAndSnapshotFailureLeavesSessionReusable() throws {
        let start = CMTime(value: 10, timescale: 1)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let factory = Task17FakeSystemWriterFactory()
        let legalEpoch = try Task17Fixtures.aacEpoch(bufferCount: 49, outputBase: start)
        let writer = try Task17Fixtures.makeWriter(
            seed: 3_900,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(legalEpoch.buffers[0])),
            boundary: boundary,
            factory: factory
        )
        let coordinator = try Task17Fixtures.aacCoordinator(
            epoch: legalEpoch,
            writer: writer,
            epochStart: start
        )
        try writer.start(at: start)

        let invalidEpoch = Task17Fixtures.replacingAACCounts(
            legalEpoch,
            totalDecodedFrames: legalEpoch.totalDecodedFrames + 1
        )
        XCTAssertThrowsError(try writer.appendAACEncodedEpoch(
            invalidEpoch,
            coordinator: coordinator
        ))
        XCTAssertEqual(factory.lastWriter?.appendCount, 0)

        let fresh = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        try fresh.registerAudioRendition(
            writer.binding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: start
        )
        XCTAssertThrowsError(try writer.appendAACEncodedEpoch(legalEpoch, coordinator: fresh))
        XCTAssertEqual(factory.lastWriter?.appendCount, 0)

        try writer.appendAACEncodedEpoch(legalEpoch, coordinator: coordinator)
        XCTAssertEqual(factory.lastWriter?.appendCount, 49)
        XCTAssertEqual(factory.lastWriter?.calls.filter { $0 == .flush }.count, 1)
        XCTAssertEqual(writer.cancel().lastLogicalSequence, 1)
    }

    func testAACNthAppendFailureAbortsOnlyUncommittedBoundaryAndRetryStartsAtSameSequence() throws {
        let start = CMTime(value: 10, timescale: 1)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let failingFactory = Task17FakeSystemWriterFactory(rejectAppendOrdinal: 48)
        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 49, outputBase: start)
        let firstWriter = try Task17Fixtures.makeWriter(
            seed: 4_000,
            kind: .aac,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            boundary: boundary,
            factory: failingFactory
        )
        let coordinator = try Task17Fixtures.aacCoordinator(
            epoch: epoch,
            writer: firstWriter,
            epochStart: start
        )
        try firstWriter.start(at: start)
        XCTAssertThrowsError(try firstWriter.appendAACEncodedEpoch(epoch, coordinator: coordinator))
        XCTAssertEqual(failingFactory.lastWriter?.appendCount, 48)
        XCTAssertEqual(failingFactory.lastWriter?.cancelCount, 1)
        XCTAssertEqual(firstWriter.terminalReceipt?.terminalReason, .failed)
        XCTAssertEqual(firstWriter.terminalReceipt?.lastLogicalSequence, 0)
        XCTAssertEqual(firstWriter.usage.retainedTerminalOwnershipCount, 0)

        let retryWorkspace = AACCalibrationWorkspace()
        let retryEpoch = try Task17Fixtures.aacEpoch(
            buffers: [epoch.buffers[47]],
            workspace: retryWorkspace
        )
        let retryFactory = Task17FakeSystemWriterFactory()
        let retryBinding = Task17Fixtures.rolloverBinding(
            from: firstWriter.binding,
            writerIdentity: .init(rawValue: 4_099)
        )
        let retryWriter = try Task17Fixtures.makeWriter(
            seed: 4_001,
            kind: .aac,
            writerBinding: retryBinding,
            sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(retryEpoch.buffers[0])),
            boundary: boundary,
            factory: retryFactory
        )
        try retryWriter.start(at: CMTime(value: 11, timescale: 1))
        try retryWriter.appendAACEncodedEpoch(retryEpoch, coordinator: coordinator)
        XCTAssertEqual(retryFactory.lastWriter?.appendCount, 1)
        XCTAssertEqual(retryWriter.cancel().lastLogicalSequence, 1)
    }

    func testCompressedSourceFormatRequiresExactNonemptyDac3AndDec3Bytes() throws {
        let configurations: [(SegmentedFMP4TrackKind, AudioFormatID, CompressedAudioFormatConfiguration)] = [
            (
                .ac3,
                kAudioFormatAC3,
                try .ac3(AC3CompressedAudioConfiguration(
                    inspection: AC3FrameInspector.inspect(
                        AssemblerTestFixtures.syntheticAC3Frame(fscod: 0, frmsizecod: 20, bsmod: 0)
                    )
                ))
            ),
            (
                .eac3,
                kAudioFormatEnhancedAC3,
                try .eac3(EAC3CompressedAudioConfiguration(
                    sampleRate: 48_000,
                    bsid: 16,
                    bsmod: 0,
                    audioCodingMode: 2,
                    hasLFE: false,
                    asvc: false,
                    maximumDataRateKbps: 6_144
                ))
            ),
        ]
        for (offset, entry) in configurations.enumerated() {
            let cookie = entry.2.serializedBox
            XCTAssertFalse(cookie.isEmpty)
            let validFactory = Task17FakeSystemWriterFactory()
            XCTAssertNoThrow(try Task17Fixtures.makeWriter(
                seed: UInt64(4_100 + offset * 10),
                kind: entry.0,
                sourceFormatHint: Task17Fixtures.audioFormat(
                    formatID: entry.1,
                    framesPerPacket: 1_536,
                    magicCookie: cookie
                ),
                compressedFormatConfiguration: entry.2,
                factory: validFactory
            ))
            XCTAssertEqual(validFactory.configurations.count, 1)

            let missingFactory = Task17FakeSystemWriterFactory()
            XCTAssertThrowsError(try Task17Fixtures.makeWriter(
                seed: UInt64(4_101 + offset * 10),
                kind: entry.0,
                sourceFormatHint: Task17Fixtures.audioFormat(
                    formatID: entry.1,
                    framesPerPacket: 1_536
                ),
                compressedFormatConfiguration: entry.2,
                factory: missingFactory
            ))
            XCTAssertEqual(missingFactory.configurations.count, 0)

            var mutated = cookie
            mutated[mutated.index(before: mutated.endIndex)] ^= 0x01
            let mutatedFactory = Task17FakeSystemWriterFactory()
            XCTAssertThrowsError(try Task17Fixtures.makeWriter(
                seed: UInt64(4_102 + offset * 10),
                kind: entry.0,
                sourceFormatHint: Task17Fixtures.audioFormat(
                    formatID: entry.1,
                    framesPerPacket: 1_536,
                    magicCookie: mutated
                ),
                compressedFormatConfiguration: entry.2,
                factory: mutatedFactory
            ))
            XCTAssertEqual(mutatedFactory.configurations.count, 0)
        }
    }

    func testRolloverAtCommonBoundaryKeepsLongSequenceBoundedAndReleasesOnlyAtRealTerminal() async throws {
        let start = CMTime(value: 10, timescale: 1)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let baseBinding = Task17Fixtures.binding(seed: 4_200)
        try boundary.registerAudioRendition(
            baseBinding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: start
        )
        let limits = SegmentedFMP4WriterOwnershipLimits(
            rolloverThreshold: 1,
            hardCapacity: 2
        )

        for cycle in 0..<3 {
            let sequenceStart = CMTime(value: Int64(10 + cycle), timescale: 1)
            let factory = Task17FakeSystemWriterFactory()
            let binding = Task17Fixtures.rolloverBinding(
                from: baseBinding,
                writerIdentity: .init(rawValue: UInt64(4_210 + cycle))
            )
            let workspace = AACCalibrationWorkspace()
            var epoch: AACEncodedEpoch? = try Task17Fixtures.aacEpoch(
                bufferCount: 1,
                outputBase: sequenceStart,
                workspace: workspace
            )
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(4_220 + cycle),
                kind: .aac,
                writerBinding: binding,
                sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch!.buffers[0])),
                boundary: boundary,
                factory: factory,
                ownershipLimits: limits
            )
            try writer.start(at: sequenceStart)
            try writer.appendAACEncodedEpoch(epoch!, coordinator: boundary)
            epoch = nil
            XCTAssertGreaterThan(workspace.currentBytes, 0)
            XCTAssertEqual(writer.usage.retainedTerminalOwnershipCount, 1)

            let nextEpoch = try Task17Fixtures.aacEpoch(
                bufferCount: 1,
                outputBase: CMTime(value: Int64(11 + cycle), timescale: 1)
            )
            XCTAssertThrowsError(try writer.appendAACEncodedEpoch(nextEpoch, coordinator: boundary)) { error in
                XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .rolloverRequired)
            }
            XCTAssertEqual(factory.lastWriter?.appendCount, 1)
            XCTAssertEqual(workspace.currentBytes, 1_048)
            let receipt = try await writer.finish()
            XCTAssertEqual(receipt.terminalReason, .finished)
            XCTAssertEqual(receipt.lastLogicalSequence, UInt64(cycle))
            XCTAssertEqual(workspace.currentBytes, 0)
            XCTAssertEqual(writer.usage.retainedTerminalOwnershipCount, 0)
            XCTAssertEqual(factory.lastWriter?.calls.filter { $0 == .finish }.count, 1)
            XCTAssertEqual(writer.cancel(), receipt)
        }
    }

    func testPreparedVideoTicketCannotCommitWithoutSuccessfulSystemAppend() throws {
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let factory = Task17FakeSystemWriterFactory()
        let firstFixture = try Task17Fixtures.realH264Sample()
        let writer = try Task17Fixtures.makeWriter(
            seed: 4_400, kind: .video, sourceFormatHint: firstFixture.format,
            boundary: boundary, factory: factory
        )
        defer { _ = writer.cancel() }
        try writer.start(at: .zero)
        let first = Task17Fixtures.videoOutput(
            fixture: firstFixture, generation: 4_400, accessUnitID: 1, sequenceNumber: 1
        )
        try writer.appendVideo(first, ticket: try boundary.issueVideoAppend(
            for: first, writerBinding: writer.binding
        ))
        let next = Task17Fixtures.videoOutput(
            fixture: try Task17Fixtures.realH264Sample(presentationTimeStamp: CMTime(value: 1, timescale: 1)),
            generation: 4_400, accessUnitID: 2, sequenceNumber: 2
        )
        let ticket = try boundary.issueVideoAppend(for: next, writerBinding: writer.binding)
        XCTAssertTrue(ticket.prepare(
            binding: writer.binding, trackKind: .video,
            sampleIdentity: try SegmentBoundaryCoordinator.videoIdentity(next), session: boundary.session
        ))
        XCTAssertFalse(ticket.commit(), "合法 ticket 与 prepare 不能冒充系统 append 成功")
        XCTAssertFalse(ticket.commit(), "重复绕过不能取得正式提交权")
        XCTAssertEqual(factory.lastWriter?.appendCount, 1)
        XCTAssertEqual(boundary.usage.lastLogicalSequence, 0)
        XCTAssertEqual(boundary.commonBoundaries, [ExactMediaTime(value: 0, timescale: 1)])
        ticket.abort(binding: writer.binding, session: boundary.session)

        let retry = try boundary.issueVideoAppend(for: next, writerBinding: writer.binding)
        XCTAssertEqual(retry.logicalSequence, 1)
        XCTAssertTrue(retry.requiresFlushBeforeAppend)
        try writer.appendVideo(next, ticket: retry)
        XCTAssertFalse(retry.commit())
        XCTAssertThrowsError(try writer.appendVideo(next, ticket: retry))
        XCTAssertEqual(factory.lastWriter?.appendCount, 2)
        XCTAssertEqual(boundary.usage.lastLogicalSequence, 1)
        XCTAssertEqual(boundary.commonBoundaries, [
            ExactMediaTime(value: 0, timescale: 1), ExactMediaTime(value: 1, timescale: 1),
        ])
    }

    func testPreparedAudioTicketCannotAdvanceAudioStateBeforeWriterAppend() throws {
        let start = CMTime(value: 10, timescale: 1)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: start))
        let epoch = try Task17Fixtures.aacEpoch(bufferCount: 49, outputBase: start)
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 4_410, kind: .aac, sourceFormatHint: try XCTUnwrap(CMSampleBufferGetFormatDescription(epoch.buffers[0])),
            boundary: boundary, factory: factory
        )
        defer { _ = writer.cancel() }
        try boundary.registerAudioRendition(
            writer.binding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000), firstEffectiveStart: start
        )
        let last = epoch.buffers[47]
        let ticket = try boundary.issueAACAppend(
            for: last, rendition: writer.binding.renditionIdentity, writerBinding: writer.binding
        )
        XCTAssertTrue(ticket.prepare(
            binding: writer.binding, trackKind: .aac,
            sampleIdentity: try SegmentBoundaryCoordinator.aacIdentity(last), session: boundary.session
        ))
        XCTAssertFalse(ticket.commit())
        XCTAssertEqual(boundary.usage.lastLogicalSequence, 0)
        XCTAssertEqual(boundary.commonBoundaries, [ExactMediaTime(value: 10, timescale: 1)])
        ticket.abort(binding: writer.binding, session: boundary.session)
        let retry = try boundary.issueAACAppend(
            for: last, rendition: writer.binding.renditionIdentity, writerBinding: writer.binding
        )
        XCTAssertEqual(retry.logicalSequence, 1)
        XCTAssertTrue(retry.requiresFlushBeforeAppend)
        retry.abort(binding: writer.binding, session: boundary.session)
        try writer.start(at: start)
        try writer.appendAACEncodedEpoch(epoch, coordinator: boundary)
        XCTAssertEqual(factory.lastWriter?.appendCount, 49)
        XCTAssertEqual(boundary.usage.lastLogicalSequence, 1)
        XCTAssertEqual(boundary.commonBoundaries, [
            ExactMediaTime(value: 10, timescale: 1), ExactMediaTime(value: 11, timescale: 1),
        ])
    }

    func testClosePublicationsRollsBackOnlyUnclaimedInitializationAndMediaOwnership() throws {
        for (claimInitialization, claimMedia) in [(false, false), (true, false), (false, true), (true, true)] {
            let binding = Task17Fixtures.binding(seed: 4_420)
            let collector = Task17ObjectCollector()
            let relay = SegmentReportRelay(binding: binding, limits: .audio, capacity: 8, objectSink: collector.append)
            var capabilities: [SegmentCallbackAcceptance] = []
            for (kind, sequence, byteCount) in [
                (SealedMediaObjectKind.initialization, UInt64(0), 17), (.media, 1, 29), (.media, 2, 37),
            ] {
                let ticket = try relay.reserve(kind: kind, logicalSequence: sequence, projectedByteCount: byteCount)
                guard case let .accepted(capability) = relay.receive(SegmentCallbackDelivery(
                    binding: binding, writerIdentity: binding.writerIdentity, ticket: ticket,
                    logicalSequence: sequence, kind: kind,
                    bytes: NSData(data: Data(repeating: 0x31, count: byteCount)),
                    report: SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: nil))
                )) else { return XCTFail("有效 callback 必须先登记精确所有权") }
                capabilities.append(capability)
            }
            if claimInitialization { XCTAssertTrue(relay.consumePublication(capabilities[0]) { $0() }) }
            let scheduler = Task17DeferredPublicationScheduler()
            if claimMedia { XCTAssertTrue(relay.consumePublication(capabilities[1], schedule: scheduler.schedule)) }
            XCTAssertEqual(relay.usage.sealedObjectByteCount, 83)
            XCTAssertEqual(relay.usage.initializationSealedObjectByteCount, 17)
            XCTAssertEqual(relay.usage.mediaSealedObjectByteCount, 66)
            XCTAssertEqual(relay.usage.publicationCapabilityCount, 3 - (claimInitialization ? 1 : 0) - (claimMedia ? 1 : 0))
            XCTAssertEqual(relay.usage.unpublishedLogicalSegmentCount, 2)
            XCTAssertEqual(relay.usage.reservedSlots, 0)
            XCTAssertEqual(relay.usage.writerBacklogBytes, 0)

            for _ in 0..<2 {
                relay.closePublications()
                XCTAssertEqual(relay.usage.publicationCapabilityCount, 0)
                XCTAssertEqual(relay.usage.initializationSealedObjectByteCount, claimInitialization ? 17 : 0)
                XCTAssertEqual(relay.usage.mediaSealedObjectByteCount, claimMedia ? 29 : 0)
                XCTAssertEqual(relay.usage.sealedObjectByteCount, (claimInitialization ? 17 : 0) + (claimMedia ? 29 : 0))
                XCTAssertEqual(relay.usage.unpublishedLogicalSegmentCount, claimMedia ? 1 : 0)
                XCTAssertEqual(relay.usage.reservedSlots, 0)
                XCTAssertEqual(relay.usage.writerBacklogSegmentCount, 0)
                XCTAssertEqual(relay.usage.writerBacklogBytes, 0)
                for capability in capabilities {
                    XCTAssertFalse(relay.consumePublication(capability) { $0() })
                }
            }
            // 已领取但尚未调度的对象仍归下游；close 不能重复扣除这份所有权。
            scheduler.runTwice()
            XCTAssertEqual(collector.objects.count, (claimInitialization ? 1 : 0) + (claimMedia ? 1 : 0))
            if claimMedia {
                let object = try XCTUnwrap(collector.objects.first(where: { $0.kind == .media }))
                let lease = try XCTUnwrap(object.publicationLease)
                XCTAssertTrue(relay.releaseUnpublishedLogicalSegment(lease))
                XCTAssertFalse(relay.releaseUnpublishedLogicalSegment(lease))
            }
            XCTAssertEqual(relay.usage.sealedObjectByteCount, claimInitialization ? 17 : 0)
            XCTAssertEqual(relay.usage.unpublishedLogicalSegmentCount, 0)
            // 精确回滚也必须释放该逻辑序号，不能只让可见计数归零。
            XCTAssertNoThrow(try {
                let replacement = try relay.reserveUnpublishedLogicalSegment(logicalSequence: 2)
                XCTAssertTrue(relay.releaseUnpublishedLogicalSegment(replacement))
            }())
        }
    }

    func testFormalBoundaryAccessorsFollowWriterCommitsAndIgnoreInspection() throws {
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
        )
        let first = try Task17Fixtures.realH264Sample()
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 4_430, kind: .video, sourceFormatHint: first.format, boundary: boundary, factory: factory
        )
        defer { _ = writer.cancel() }
        try writer.start(at: .zero)
        for second in 0...2 {
            let output = Task17Fixtures.videoOutput(
                fixture: try Task17Fixtures.realH264Sample(presentationTimeStamp: CMTime(value: Int64(second), timescale: 1)),
                generation: 4_430, accessUnitID: UInt64(second + 1), sequenceNumber: UInt64(second + 1)
            )
            try writer.appendVideo(output, ticket: try boundary.issueVideoAppend(for: output, writerBinding: writer.binding))
            XCTAssertEqual(boundary.usage.lastLogicalSequence, UInt64(second))
            XCTAssertEqual(boundary.usage.commonBoundarySlotCount, second + 1)
        }
        let expected = [ExactMediaTime(value: 0, timescale: 1), ExactMediaTime(value: 1, timescale: 1), ExactMediaTime(value: 2, timescale: 1)]
        XCTAssertEqual(boundary.commonBoundaries, expected)
        XCTAssertEqual(boundary.inspectionUsage.lastLogicalSequence, 0)
        XCTAssertEqual(boundary.inspectionCommonBoundaries, [ExactMediaTime(value: 0, timescale: 1)])
        for second in 0...3 {
            _ = try boundary.inspectVideoBoundary(at: CMTime(value: Int64(second), timescale: 1), isIDR: true)
            XCTAssertEqual(boundary.inspectionUsage.lastLogicalSequence, UInt64(second))
            XCTAssertEqual(boundary.inspectionUsage.commonBoundarySlotCount, second + 1)
            XCTAssertEqual(boundary.inspectionCommonBoundaries.last, ExactMediaTime(value: Int64(second), timescale: 1))
            XCTAssertEqual(boundary.usage.lastLogicalSequence, 2)
            XCTAssertEqual(boundary.usage.commonBoundarySlotCount, 3)
            XCTAssertEqual(boundary.commonBoundaries, expected)
        }
        XCTAssertEqual(factory.lastWriter?.appendCount, 3)
    }

    func testPublicationCapabilityRejectsWrongRelayReplayDuplicateScheduleAndTerminalLateUse() throws {
        let binding = Task17Fixtures.binding(seed: 4_300)
        let collector = Task17ObjectCollector()
        let relay = SegmentReportRelay(
            binding: binding,
            limits: .audio,
            capacity: 8,
            objectSink: collector.append
        )
        let wrongRelay = SegmentReportRelay(
            binding: binding,
            limits: .audio,
            capacity: 8,
            objectSink: collector.append
        )
        let firstTicket = try relay.reserve(kind: .media, logicalSequence: 0, projectedByteCount: 16)
        guard case let .accepted(firstCapability) = relay.receive(Task17Fixtures.delivery(
            binding: binding,
            ticket: firstTicket,
            logicalSequence: 0,
            byte: 0x31
        )) else { return XCTFail("合法 callback 必须产生待领取 publication capability") }

        let scheduler = Task17DeferredPublicationScheduler()
        XCTAssertFalse(wrongRelay.consumePublication(firstCapability, schedule: scheduler.schedule))
        XCTAssertEqual(collector.objects.count, 0)
        XCTAssertTrue(relay.consumePublication(firstCapability, schedule: scheduler.schedule))
        XCTAssertFalse(relay.consumePublication(firstCapability, schedule: scheduler.schedule))
        scheduler.runTwice()
        XCTAssertEqual(collector.objects.count, 1)

        let lateTicket = try relay.reserve(kind: .media, logicalSequence: 1, projectedByteCount: 16)
        guard case let .accepted(lateCapability) = relay.receive(Task17Fixtures.delivery(
            binding: binding,
            ticket: lateTicket,
            logicalSequence: 1,
            byte: 0x32
        )) else { return XCTFail("第二个合法 callback 必须产生 capability") }
        relay.closePublications()
        XCTAssertFalse(relay.consumePublication(lateCapability, schedule: scheduler.schedule))
        scheduler.runTwice()
        XCTAssertEqual(collector.objects.count, 1)
    }

    func testReview2WriterFailureCancellationIsLaneOwnedAndJoinedBeforeTerminalRetirement()
        async throws {
        let factory = Task17FakeSystemWriterFactory(
            defersFinish: true,
            defersMediaCallback: true,
            blocksCancel: true
        )
        let writer = try Task17Fixtures.makeWriter(
            seed: 27_001,
            kind: .aac,
            factory: factory,
            limits: FMP4WriterLimits(
                writerSoftSegmentCount: 1,
                writerHardSegmentCount: 3,
                writerSoftByteCount: 32,
                writerHardByteCount: 64
            )
        )
        try writer.start(at: .zero)
        let finished = Task17LockedBool()
        let finish = Task { () -> Result<SegmentedFMP4WriterTerminalReceipt, Error> in
            do {
                let receipt = try await writer.finish()
                finished.setTrue()
                return .success(receipt)
            } catch {
                finished.setTrue()
                return .failure(error)
            }
        }
        let systemWriter = try XCTUnwrap(factory.lastWriter)
        XCTAssertEqual(systemWriter.waitUntilFinishRequested(timeout: .now() + 2), .success)
        systemWriter.emitMedia(bytes: Data(repeating: 0x7f, count: 65))
        XCTAssertEqual(systemWriter.waitUntilCancelEntered(timeout: .now() + 2), .success)
        try await Task.sleep(for: .milliseconds(30))
        let retiredBeforeCancelJoined = finished.value
        systemWriter.releaseBlockedCancel()
        _ = await finish.value

        XCTAssertFalse(retiredBeforeCancelJoined,
                       "writer failure 的 cancel 必须进入已登记 lane 并在 terminal 前 join")
        XCTAssertEqual(systemWriter.cancelCount, 1)
        XCTAssertTrue(systemWriter.isTerminal)
    }

    func testAACContinuousWriterWindowsCarrySameSignedEmissionAndRejectContinuationReplay()
        async throws {
        let calibration = try await AACPrimingCalibrator().calibrate(plan:
            AACCalibrationPlan.build([try AACRenditionRequest(
                layout: RenditionAudioLayout(labels: [.l, .r]),
                capabilityVersion: "task22-b-window-continuation")]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let format = try encoder.incrementalFormatDescription()
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1)))
        let initialBinding = Task17Fixtures.binding(seed: 31_000)
        try boundary.registerAudioRendition(
            initialBinding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: CMTime(value: 10, timescale: 1))
        let first = try Task17Fixtures.makeWindowWriter(
            binding: initialBinding, format: format, boundary: boundary,
            factory: AVAssetSegmentedFMP4SystemWriterFactory(),
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 64))
        try first.start(at: CMTime(value: 10, timescale: 1))

        var pending: AACIncrementalEmission?
        for batch in 0..<80 where pending == nil {
            let samples = (0..<(1_024 * 2)).map {
                sin(Float(batch * 2_048 + $0) * 0.003125) * 0.25
            }
            _ = try encoder.pumpSigned(.pcm(samples)) { emission in
                do { _ = try first.appendAACIncremental(emission, coordinator: boundary) }
                catch SegmentedFMP4WriterFailure.rolloverRequired {
                    if pending == nil { pending = emission }
                }
            }
        }
        let originalPending = try XCTUnwrap(pending)
        let originalIdentity = AACIncrementalEmissionIdentity(originalPending)
        XCTAssertTrue(first.isAACWriterWindowRolloverPending)
        let continuation = try await first.finishAACWriterWindow()
        XCTAssertEqual(first.usage.retainedTerminalOwnershipCount, 0)
        let nextBinding = Task17Fixtures.rolloverBinding(
            from: initialBinding, writerIdentity: .init(rawValue: 31_100))
        let next = try Task17Fixtures.makeWindowWriter(
            binding: nextBinding, format: format, boundary: boundary,
            factory: AVAssetSegmentedFMP4SystemWriterFactory(), continuation: continuation,
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 64))
        try next.start(at: CMTime.zero)
        XCTAssertEqual(try next.appendAACIncremental(
            originalPending, coordinator: boundary), AACIncrementalAppendResult.appended)
        XCTAssertEqual(AACIncrementalEmissionIdentity(originalPending), originalIdentity)
        XCTAssertThrowsError(try Task17Fixtures.makeWindowWriter(
            binding: Task17Fixtures.rolloverBinding(
                from: initialBinding, writerIdentity: .init(rawValue: 31_101)),
            format: format, boundary: boundary,
            factory: Task17FakeSystemWriterFactory(), continuation: continuation))
        _ = next.cancel()
        encoder.dispose()

        let crossLifecycle = try await Task17Fixtures.makeWindowPredecessor(
            seed: 31_200)
        let invalidLifecycleBinding = FMP4WriterBinding(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(
                outputNonce: 31_201),
            itemGeneration: crossLifecycle.binding.itemGeneration,
            mediaEpoch: crossLifecycle.binding.mediaEpoch,
            publicationParticipantID: crossLifecycle.binding.publicationParticipantID,
            renditionIdentity: crossLifecycle.binding.renditionIdentity,
            writerIdentity: .init(rawValue: 31_298))
        XCTAssertThrowsError(try Task17Fixtures.makeWindowWriter(
            binding: invalidLifecycleBinding, format: crossLifecycle.format,
            boundary: crossLifecycle.boundary,
            factory: Task17FakeSystemWriterFactory(),
            continuation: crossLifecycle.continuation))
        XCTAssertThrowsError(try Task17Fixtures.makeWindowWriter(
            binding: Task17Fixtures.rolloverBinding(
                from: crossLifecycle.binding,
                writerIdentity: .init(rawValue: 31_299)),
            format: crossLifecycle.format, boundary: crossLifecycle.boundary,
            factory: Task17FakeSystemWriterFactory(),
            continuation: crossLifecycle.continuation),
            "非法 consume 后 continuation 必须永久烧毁")
        crossLifecycle.encoder.dispose()

        let crossRendition = try await Task17Fixtures.makeWindowPredecessor(
            seed: 31_300)
        let invalidRenditionBinding = FMP4WriterBinding(
            outputLifecycleEpoch: crossRendition.binding.outputLifecycleEpoch,
            itemGeneration: crossRendition.binding.itemGeneration,
            mediaEpoch: crossRendition.binding.mediaEpoch,
            publicationParticipantID: crossRendition.binding.publicationParticipantID,
            renditionIdentity: .init(rawValue:
                crossRendition.binding.renditionIdentity.rawValue + 1),
            writerIdentity: .init(rawValue: 31_398))
        XCTAssertThrowsError(try Task17Fixtures.makeWindowWriter(
            binding: invalidRenditionBinding, format: crossRendition.format,
            boundary: crossRendition.boundary,
            factory: Task17FakeSystemWriterFactory(),
            continuation: crossRendition.continuation))
        crossRendition.encoder.dispose()

        let jump = try await Task17Fixtures.makeWindowPredecessor(seed: 31_400)
        let jumpWriter = try Task17Fixtures.makeWindowWriter(
            binding: Task17Fixtures.rolloverBinding(
                from: jump.binding, writerIdentity: .init(rawValue: 31_499)),
            format: jump.format, boundary: jump.boundary,
            factory: AVAssetSegmentedFMP4SystemWriterFactory(),
            continuation: jump.continuation)
        try jumpWriter.start(at: .zero)
        let skippedPending = try XCTUnwrap(jump.pending.dropFirst().first)
        XCTAssertThrowsError(try jumpWriter.appendAACIncremental(
            skippedPending, coordinator: jump.boundary))
        XCTAssertEqual(try jumpWriter.appendAACIncremental(
            jump.pending[0], coordinator: jump.boundary), .appended)
        _ = jumpWriter.cancel()
        jump.encoder.dispose()

        let changedMapping = try await Task17Fixtures.makeWindowPredecessor(
            seed: 31_500)
        let shiftedStart = CMTimeAdd(try XCTUnwrap(
            changedMapping.continuation.nextPhysicalStart?.cmTime
        ), CMTime(value: 11, timescale: 1))
        let changedMappingWriter = try Task17Fixtures.makeWindowWriter(
            binding: Task17Fixtures.rolloverBinding(
                from: changedMapping.binding,
                writerIdentity: .init(rawValue: 31_599)),
            format: changedMapping.format, boundary: changedMapping.boundary,
            factory: Task17FakeSystemWriterFactory(mediaWrittenStart: shiftedStart),
            continuation: changedMapping.continuation)
        try changedMappingWriter.start(at: .zero)
        for emission in changedMapping.pending {
            XCTAssertEqual(try changedMappingWriter.appendAACIncremental(
                emission, coordinator: changedMapping.boundary), .appended)
        }
        var mappingWasRejected = false
        do {
            for batch in 0..<80 where !mappingWasRejected {
                let samples = (0..<(1_024 * 2)).map {
                    sin(Float(batch * 2_048 + $0) * 0.003125) * 0.25
                }
                _ = try changedMapping.encoder.pumpSigned(.pcm(samples)) { emission in
                    do {
                        _ = try changedMappingWriter.appendAACIncremental(
                            emission, coordinator: changedMapping.boundary)
                    } catch {
                        mappingWasRejected = true
                        throw error
                    }
                }
            }
        } catch {
            mappingWasRejected = true
        }
        XCTAssertTrue(mappingWasRejected,
                      "后继真实首 media mapping 偏移变化必须失败闭合")
    }

    func testAACContinuousBranchExceeds384SignedEmissionsAndFinalCoordinatorConsumesAutomaticHTTPSeal()
        async throws {
        let harness = try await Task22LongRenditionHarness.make()
        let factory = LoopbackHTTPSessionFactory()
        let server = try await factory.startPreparingAsynchronously(
            itemGeneration: 19, now: { 0 }, logger: { _ in },
            responseFailure: { _, _ in }, prepare: { token in
                try await harness.startPublication(loopbackSession: token)
            })
        defer {
            let ticket = server.closeAdmission()
            try? server.drain(cleanupTicket: ticket)
            try? server.retire(cleanupTicket: ticket)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var servedMedia: Set<HLSResourceKey> = []
        var skippedHistoricalMedia: HLSResourceKey?
        var reversesFirstWindow = true
        func serveNewMedia(_ snapshot: HLSPublishedSnapshot) async throws {
            let chronological = snapshot.media[2]?.resources ?? []
            let keys = reversesFirstWindow ? Array(chronological.reversed()) : chronological
            if reversesFirstWindow { reversesFirstWindow = false }
            for key in keys {
                if key == skippedHistoricalMedia { continue }
                if skippedHistoricalMedia == nil, key != chronological.last {
                    skippedHistoricalMedia = key
                    continue
                }
                guard servedMedia.insert(key).inserted else { continue }
                let url = try XCTUnwrap(URL(
                    string: server.path(for: key),
                    relativeTo: server.baseURL)?.absoluteURL)
                let (body, response) = try await session.data(from: url)
                XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
                XCTAssertFalse(body.isEmpty)
            }
        }
        try await serveNewMedia(try XCTUnwrap(harness.publisher.visible))
        let final = try await harness.finishStream(totalPCMInputs: 6_200) {
            try await serveNewMedia($0)
        }
        let branch = harness.branch
        let renditionBinding = harness.renditionBinding
        XCTAssertGreaterThan(final.emissionCount, 384)
        XCTAssertGreaterThanOrEqual(branch.physicalWriterWindowCount, 2)
        XCTAssertTrue(branch.renditionTerminalBinding === renditionBinding,
                      "物理 writer rollover 不得替换 rendition 级稳定绑定")
        let membership = try XCTUnwrap(branch.aacCallbackMembershipSnapshot)
        XCTAssertGreaterThanOrEqual(membership.count, 129)
        XCTAssertEqual(membership.pendingCount, 0)
        XCTAssertEqual(branch.writerReceipt?.inputCount, final.emissionCount)
        let renditionFinal = try await branch.finishRendition()
        XCTAssertEqual(renditionFinal.systemTerminal.terminalReason,
                       SegmentedFMP4WriterTerminalReason.finished)
        XCTAssertEqual(renditionFinal.inputCount, final.emissionCount)
        XCTAssertEqual(renditionFinal.inputDigest, final.cumulativeDigest)
        XCTAssertEqual(renditionFinal.callbackMembership.snapshot,
                       branch.aacCallbackMembershipSnapshot,
                       "最终 writer finish 产生的末 callback 必须进入全流 seal")
        XCTAssertTrue(renditionBinding.finalWriterReceipt?.identity
                        == renditionFinal.identity)
        XCTAssertEqual(final.summary.leadingFrames, harness.encoder.leadingSampleCount)
        XCTAssertGreaterThanOrEqual(final.summary.trailingFrames, 0)

        try harness.finishPublication()
        let snapshot = try XCTUnwrap(harness.publisher.visible)
        XCTAssertGreaterThanOrEqual(servedMedia.count, 129,
                                    "每个长流成员必须在仍可服务时走真实HTTP")
        XCTAssertNotNil(skippedHistoricalMedia,
                        "HTTP子集必须明确跳过一个非terminal历史成员")
        XCTAssertFalse(servedMedia.contains(try XCTUnwrap(skippedHistoricalMedia)),
                       "被跳过的历史成员不得在后续publication中补GET")
        let membershipBeforeRepeatedFinalGET = try XCTUnwrap(
            server.aacHTTPMembershipSnapshots[2])
        XCTAssertGreaterThanOrEqual(membershipBeforeRepeatedFinalGET.count, 129)
        // preparation history 只覆盖最终窗口；server/rendition HTTP membership
        // 已由此前每个资源自己的私签 admission 累积，不能被新 history 清空。
        let evidenceSource = try LoopbackAVPlayerPreparationEvidenceSource.make(
            server: server)
        let playlist = try XCTUnwrap(snapshot.media[2])
        XCTAssertTrue(playlist.representation.text.contains("#EXT-X-ENDLIST"))
        let itemURL = try XCTUnwrap(URL(
            string: try harness.declaration.playlistURI(participantID: 2),
            relativeTo: server.baseURL)?.absoluteURL)
        let initializationURLs = try playlist.initializationResources.map({
            try XCTUnwrap(URL(string: server.path(for: $0),
                              relativeTo: server.baseURL)?.absoluteURL)
        })
        let mediaURLs = try playlist.resources.map({
            try XCTUnwrap(URL(string: server.path(for: $0),
                              relativeTo: server.baseURL)?.absoluteURL)
        })
        let terminalURL = try XCTUnwrap(mediaURLs.last)
        let (playlistBody, playlistResponse) = try await session.data(from: itemURL)
        XCTAssertEqual(try XCTUnwrap(playlistResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertFalse(playlistBody.isEmpty)
        let preparation = try LoopbackAVPlayerPreparationBundle(
            evidenceSource: evidenceSource, item: harness.itemIdentity,
            publicationSequence: snapshot.publicationSequence)
        for url in initializationURLs + mediaURLs.dropLast() {
            let (body, response) = try await session.data(from: url)
            XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
            XCTAssertFalse(body.isEmpty)
        }
        // 先完整服务当前窗口的历史成员，再以终段 send-terminal 触发正式
        // publication-ready 事件；该事件是 server lane 的有界完成屏障。
        let completedPublication = expectation(
            description: "final publication 的真实 HTTP send-terminal 已完成")
        evidenceSource.installCompletedPublicationEventHandler { sequence in
            if sequence == snapshot.publicationSequence {
                completedPublication.fulfill()
            }
        }
        let (terminalBody, terminalResponse) = try await session.data(from: terminalURL)
        XCTAssertEqual(try XCTUnwrap(terminalResponse as? HTTPURLResponse).statusCode, 200)
        XCTAssertFalse(terminalBody.isEmpty)
        await fulfillment(of: [completedPublication], timeout: 10)
        let membershipAfterFinalGET = try XCTUnwrap(
            server.aacHTTPMembershipSnapshots[2])
        XCTAssertEqual(
            membershipAfterFinalGET.count,
            membershipBeforeRepeatedFinalGET.count + 1,
            "终段首次 GET 之外，当前窗口的重复 GET 不得再次累计"
        )
        let publication = try XCTUnwrap(renditionBinding.sealedPublicationReceipt)
        let http = try XCTUnwrap(renditionBinding.sealedHTTPReceipt,
                                 "终段send-terminal必须由生产server自动封存HTTP receipt")
        let (_, repeatedTerminalResponse) = try await session.data(from: terminalURL)
        XCTAssertEqual(try XCTUnwrap(repeatedTerminalResponse as? HTTPURLResponse).statusCode,
                       200)
        XCTAssertTrue(renditionBinding.sealedHTTPReceipt === http,
                      "重复终段GET不得重新封存或替换HTTP receipt")
        XCTAssertEqual(http.snapshot.count,
                       membershipAfterFinalGET.count,
                       "HTTP成员归约必须跨preparation history保留")
        XCTAssertLessThanOrEqual(http.snapshot.count, publication.snapshot.count,
                                 "最终HTTP只证明实际服务的滑窗子集")
        XCTAssertEqual(http.terminalLeaf, publication.terminalLeaf)
        var terminalFirst = AACHTTPFinalizationGate()
        XCTAssertFalse(terminalFirst.observeTerminalHTTP(http.terminalLeaf))
        XCTAssertTrue(terminalFirst.observePublication(publication))
        XCTAssertFalse(terminalFirst.observePublication(publication),
                       "同一组真实receipt只能取得一次finalization线性化点")
        _ = try XCTUnwrap(evidenceSource.consumeCompletedPublication(
            itemURL: itemURL, item: harness.itemIdentity,
            publicationSequence: snapshot.publicationSequence))
        let completed = try XCTUnwrap(
            evidenceSource.retainedCompletedPublicationEvidence())
        let authority = try XCTUnwrap(renditionBinding.endpointAuthority)
        let verified = try AVPlayerAACEndpointValidator.preflight(
            authority: authority, completedPublication: completed)
        XCTAssertEqual(verified.lastEffectiveEnd, renditionFinal.lastEffectiveEnd)
        XCTAssertEqual(verified.terminalPhysicalEnd, renditionFinal.terminalPhysicalEnd)
        let finalPreparation = try await task22PrepareFinalThroughCoordinator(
            request: preparation.request,
            evidenceSource: evidenceSource,
            effectiveEnd: renditionFinal.lastEffectiveEnd)
        XCTAssertEqual(finalPreparation.constrained, finalPreparation.expected,
                       "final已存在时正式coordinator必须消费并约束有效终点N")
        XCTAssertThrowsError(try AVPlayerAACEndpointValidator.validate(
            authority: authority, completedPublication: completed),
            "coordinator正式消费后，同一final authority不得重复消费")
    }

    func testAACServedSubsetDigestIsOrderIndependent() throws {
        let commitments = try (1...6).map { index in
            try FMP4Digest(rawDigest: Data(repeating: UInt8(index), count: 32))
        }
        var forward = AACServedSubsetDigest()
        var reverse = AACServedSubsetDigest()
        for commitment in commitments {
            forward.include(commitment: commitment)
        }
        for commitment in commitments.reversed() {
            reverse.include(commitment: commitment)
        }
        XCTAssertEqual(forward.value, reverse.value,
                       "同一真实leaf集合的HTTP摘要不得依赖完成顺序")
    }

    func testRemuxSubmissionWritesFourSampleEntriesFromRealInspectedBytes() throws {
        for (index, sampleEntry) in [
            HLSVideoSampleEntry.avc1, .avc3, .hvc1, .hev1,
        ].enumerated() {
            let codec: VideoCodec = index < 2 ? .h264 : .hevc
            let fixture = try Task17Fixtures.remuxFixture(
                codec: codec,
                sampleEntry: sampleEntry,
                seed: UInt64(9_100 + index)
            )
            let factory = Task17FakeSystemWriterFactory()
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(9_100 + index),
                kind: .video,
                writerBinding: fixture.binding,
                sourceFormatHint: fixture.builder.formatDescription,
                boundary: fixture.boundary,
                factory: factory
            )
            try writer.start(at: CMTime(value: 10, timescale: 1))
            let submission = try fixture.builder.makeSubmission(
                for: fixture.timed[0], admission: fixture.admissions[0]
            )
            let ticket = try fixture.boundary.issueRemuxVideoAppend(
                for: submission, writerBinding: writer.binding
            )
            try writer.appendRemuxVideo(submission, ticket: ticket)

            XCTAssertEqual(factory.lastWriter?.appendCount, 1)
            let appended = try XCTUnwrap(factory.lastWriter?.capturedPayloads.first)
            let appendedNALUnits = try Task17Fixtures.lengthPrefixedNALUnits(appended)
            let canonicalParameterSets = codec == .h264
                ? [AssemblerTestFixtures.h264SPS, AssemblerTestFixtures.h264PPS]
                : Task17Fixtures.task22HEVCParameterSets()
            let metadata = codec == .hevc ? [Task17Fixtures.task22HEVCHDRSEI()] : []
            let vcl = codec == .h264 ? Data([0x65, 0xB8]) : Data([0x26, 0x01, 0xA0])
            XCTAssertEqual(
                appendedNALUnits,
                (sampleEntry == .avc3 || sampleEntry == .hev1)
                    ? canonicalParameterSets + metadata + [vcl]
                    : metadata + [vcl],
                "SDK 收到的私有 sample 必须按 entry 真实 strip/preserve 参数集"
            )
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(submission.formatDescription),
                sampleEntry.fourCharacterCode
            )
            if codec == .hevc {
                let dimensions = CMVideoFormatDescriptionGetDimensions(
                    submission.formatDescription
                )
                XCTAssertEqual(dimensions.width, 3_840)
                XCTAssertEqual(dimensions.height, 2_160)
                let extensions = try XCTUnwrap(
                    CMFormatDescriptionGetExtensions(submission.formatDescription)
                        as? [CFString: Any]
                )
                XCTAssertEqual(
                    extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
                    kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
                )
                XCTAssertEqual(
                    (extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume]
                        as? Data)?.count, 24
                )
                XCTAssertEqual(
                    (extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo]
                        as? Data)?.count, 4
                )
            }
            XCTAssertEqual(submission.sourceSHA256, fixture.admissions[0].source.identity.sourceSHA256)
            XCTAssertEqual(
                submission.outputContainsParameterSets,
                sampleEntry == .avc3 || sampleEntry == .hev1
            )
            if sampleEntry == .avc1 || sampleEntry == .hvc1 {
                XCTAssertNotEqual(submission.sourceSHA256, submission.outputSHA256,
                                  "strip 后源摘要与输出摘要不能混用")
            }
        }
    }

    func testRemuxNotReadyAbortsOnlyTicketAndRetriesSameSubmissionWhenReady() throws {
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 9_110
        )
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 9_110, kind: .video, writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary, factory: factory
        )
        try writer.start(at: CMTime(value: 10, timescale: 1))
        let submission = try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0]
        )
        let firstTicket = try fixture.boundary.issueRemuxVideoAppend(
            for: submission, writerBinding: writer.binding
        )
        factory.lastWriter?.setReadyForMoreMediaData(false)
        XCTAssertThrowsError(try writer.appendRemuxVideo(submission, ticket: firstTicket)) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .notReady)
        }
        XCTAssertEqual(factory.lastWriter?.appendCount, 0)
        XCTAssertEqual(factory.lastWriter?.cancelCount, 0)
        XCTAssertNil(firstTicket.committedBoundary)

        factory.lastWriter?.setReadyForMoreMediaData(true)
        let retryTicket = try fixture.boundary.issueRemuxVideoAppend(
            for: submission, writerBinding: writer.binding
        )
        XCTAssertNoThrow(try writer.appendRemuxVideo(submission, ticket: retryTicket))
        XCTAssertEqual(factory.lastWriter?.appendCount, 1)
        XCTAssertNotNil(retryTicket.committedBoundary)
        XCTAssertThrowsError(try writer.appendRemuxVideo(
            submission,
            ticket: try fixture.boundary.issueRemuxVideoAppend(
                for: submission, writerBinding: writer.binding
            )
        ), "成功 append 后 submission 仍必须保持一次性")
    }

    func testRemuxPendingCallbackBackpressureDoesNotConsumeSubmissionBeforeRetry() throws {
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264,
            sampleEntry: .avc1,
            seed: 9_115,
            frames: (7...11).map {
                .init(pts: Int64($0 * 1_000), dts: Int64($0 * 1_000), isIDR: true)
            }
        )
        let factory = Task17FakeSystemWriterFactory(defersMediaCallback: true)
        let writer = try Task17Fixtures.makeWriter(
            seed: 9_115,
            kind: .video,
            writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary,
            factory: factory
        )
        defer { _ = writer.cancel() }
        try writer.start(at: CMTime(value: 10, timescale: 1))

        for index in 0..<4 {
            let submission = try fixture.builder.makeSubmission(
                for: fixture.timed[index], admission: fixture.admissions[index]
            )
            try writer.appendRemuxVideo(
                submission,
                ticket: try fixture.boundary.issueRemuxVideoAppend(
                    for: submission, writerBinding: writer.binding
                )
            )
        }
        XCTAssertEqual(writer.usage.pendingCallbackCount, 3)
        XCTAssertEqual(factory.lastWriter?.calls.filter { $0 == .flush }.count, 3)

        let blocked = try fixture.builder.makeSubmission(
            for: fixture.timed[4], admission: fixture.admissions[4]
        )
        let blockedTicket = try fixture.boundary.issueRemuxVideoAppend(
            for: blocked, writerBinding: writer.binding
        )
        XCTAssertThrowsError(try writer.appendRemuxVideo(blocked, ticket: blockedTicket)) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .relayCapacityExceeded)
        }
        XCTAssertEqual(factory.lastWriter?.appendCount, 4)
        XCTAssertEqual(factory.lastWriter?.calls.filter { $0 == .flush }.count, 3)
        XCTAssertEqual(factory.lastWriter?.cancelCount, 0)
        XCTAssertNil(blockedTicket.committedBoundary)
        XCTAssertEqual(writer.usage.pendingCallbackCount, 3)

        factory.lastWriter?.emitDeferredMediaCallbacks()
        XCTAssertEqual(writer.usage.pendingCallbackCount, 0)
        let retryTicket = try fixture.boundary.issueRemuxVideoAppend(
            for: blocked, writerBinding: writer.binding
        )
        XCTAssertNoThrow(try writer.appendRemuxVideo(blocked, ticket: retryTicket))
        XCTAssertEqual(factory.lastWriter?.appendCount, 5)
        XCTAssertEqual(factory.lastWriter?.calls.filter { $0 == .flush }.count, 4)
        XCTAssertEqual(factory.lastWriter?.cancelCount, 0)
        XCTAssertNotNil(retryTicket.committedBoundary)
        XCTAssertThrowsError(try writer.appendRemuxVideo(
            blocked,
            ticket: try fixture.boundary.issueRemuxVideoAppend(
                for: blocked, writerBinding: writer.binding
            )
        ), "成功后同一 submission 不能再次消费")
    }

    func testRemuxBuilderCanonicalizesReorderedDuplicateActiveParameterSets() throws {
        let h264Sets = [
            AssemblerTestFixtures.h264PPS, AssemblerTestFixtures.h264SPS,
            AssemblerTestFixtures.h264SPS, AssemblerTestFixtures.h264PPS,
        ]
        let hevcCanonical = Task17Fixtures.task22HEVCParameterSets()
        let hevcSets = [
            hevcCanonical[2], hevcCanonical[0], hevcCanonical[1],
            hevcCanonical[0], hevcCanonical[2], hevcCanonical[1],
        ]
        let cases: [(VideoCodec, HLSVideoSampleEntry, [Data])] = [
            (.h264, .avc1, h264Sets),
            (.h264, .avc3, h264Sets),
            (.hevc, .hvc1, hevcSets),
            (.hevc, .hev1, hevcSets),
        ]
        for (index, value) in cases.enumerated() {
            let fixture = try Task17Fixtures.remuxFixture(
                codec: value.0, sampleEntry: value.1, seed: UInt64(9_120 + index),
                inBandParameterSetsOverride: value.2
            )
            let submission = try fixture.builder.makeSubmission(
                for: fixture.timed[0], admission: fixture.admissions[0]
            )
            let factory = Task17FakeSystemWriterFactory()
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(9_120 + index), kind: .video,
                writerBinding: fixture.binding,
                sourceFormatHint: fixture.builder.formatDescription,
                boundary: fixture.boundary, factory: factory
            )
            try writer.start(at: CMTime(value: 10, timescale: 1))
            try writer.appendRemuxVideo(
                submission,
                ticket: try fixture.boundary.issueRemuxVideoAppend(
                    for: submission, writerBinding: writer.binding
                )
            )
            let nals = try Task17Fixtures.lengthPrefixedNALUnits(
                try XCTUnwrap(factory.lastWriter?.capturedPayloads.first)
            )
            let metadata = value.0 == .hevc ? [Task17Fixtures.task22HEVCHDRSEI()] : []
            let vcl = value.0 == .h264 ? Data([0x65, 0xB8]) : Data([0x26, 0x01, 0xA0])
            XCTAssertEqual(
                nals,
                value.1 == .avc3 || value.1 == .hev1
                    ? value.2 + metadata + [vcl]
                    : metadata + [vcl],
                "规范化只服务 format；payload 必须按 entry 保持或剥离原始重复参数 NAL"
            )
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(fixture.builder.formatDescription),
                value.1.fourCharacterCode
            )
        }
    }

    func testRemuxFormatPreservesRealSDRAndHLGInspectionMetadata() throws {
        for (index, transfer) in [(UInt8(1), DemuxColorTransfer.bt709),
                                  (UInt8(18), DemuxColorTransfer.hlg)].enumerated() {
            let fixture = try Task17Fixtures.remuxFixture(
                codec: .hevc, sampleEntry: .hvc1, seed: UInt64(9_130 + index),
                parameterSetsOverride: Task17Fixtures.task22HEVCParameterSets(
                    transferCharacteristics: transfer.0
                ),
                includeHDRMetadata: false
            )
            XCTAssertEqual(fixture.admissions[0].source.format.transfer, transfer.1)
            let extensions = try XCTUnwrap(
                CMFormatDescriptionGetExtensions(fixture.builder.formatDescription)
                    as? [CFString: Any]
            )
            XCTAssertEqual(
                extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
                transfer.1 == .hlg
                    ? kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
                    : kCVImageBufferTransferFunction_ITU_R_709_2 as String
            )
        }
    }

    func testRemuxSubmissionRejectsCrossTimelineTimingAttachmentAndWriterBindingMutation() throws {
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 9_200
        )
        let foreign = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 9_201
        )
        XCTAssertThrowsError(try fixture.builder.makeSubmission(
            for: foreign.timed[0], admission: foreign.admissions[0]
        )) { error in
            XCTAssertEqual(error as? HLSVideoRemuxSubmissionFailure, .timelineMismatch)
        }

        try Task17Fixtures.setVideoNotSync(fixture.timed[0].source.sampleBuffer, true)
        XCTAssertThrowsError(try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0]
        )) { error in
            XCTAssertEqual(error as? HLSVideoRemuxSubmissionFailure, .syncAttachmentMismatch)
        }
    }

    func testRemuxWriterAcceptsReorderedPTSWithIncreasingDTSAndRejectsDTSRegression() throws {
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264,
            sampleEntry: .avc3,
            seed: 9_300,
            frames: [
                .init(pts: 7_000, dts: 6_999, isIDR: true),
                .init(pts: 7_066, dts: 7_000, isIDR: false),
                .init(pts: 7_100, dts: 7_020, isIDR: false),
                .init(pts: 7_033, dts: 7_033, isIDR: false),
            ]
        )
        let writer = try Task17Fixtures.makeWriter(
            seed: 9_300, kind: .video, writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary
        )
        try writer.start(at: CMTime(value: 10, timescale: 1))
        for index in [0, 1, 3] {
            let submission = try fixture.builder.makeSubmission(
                for: fixture.timed[index], admission: fixture.admissions[index]
            )
            try writer.appendRemuxVideo(
                submission,
                ticket: try fixture.boundary.issueRemuxVideoAppend(
                    for: submission, writerBinding: writer.binding
                )
            )
        }
        let regressed = try fixture.builder.makeSubmission(
            for: fixture.timed[2], admission: fixture.admissions[2]
        )
        let ticket = try fixture.boundary.issueRemuxVideoAppend(
            for: regressed, writerBinding: writer.binding
        )
        XCTAssertThrowsError(try writer.appendRemuxVideo(regressed, ticket: ticket)) { error in
            XCTAssertEqual(error as? SegmentedFMP4WriterFailure, .sourceFormatMismatch)
        }
        XCTAssertNil(ticket.committedBoundary,
                     "DTS 倒退必须在系统 append 与边界提交之前失败")
    }

    func testRemuxTicketIsSingleUseAndAppendFailureDoesNotCommitBoundary() throws {
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .hevc, sampleEntry: .hvc1, seed: 9_400
        )
        let failedFactory = Task17FakeSystemWriterFactory(failurePoint: .append)
        let failedWriter = try Task17Fixtures.makeWriter(
            seed: 9_400, kind: .video, writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary, factory: failedFactory
        )
        try failedWriter.start(at: CMTime(value: 10, timescale: 1))
        let submission = try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0]
        )
        let ticket = try fixture.boundary.issueRemuxVideoAppend(
            for: submission, writerBinding: failedWriter.binding
        )
        XCTAssertThrowsError(try failedWriter.appendRemuxVideo(submission, ticket: ticket))
        XCTAssertEqual(fixture.boundary.commonBoundaries.count, 1,
                       "系统 append 失败不得提交边界")
        XCTAssertThrowsError(try failedWriter.appendRemuxVideo(submission, ticket: ticket),
                             "失败 ticket 不得重放")

        let otherBinding = Task17Fixtures.binding(seed: 9_401)
        XCTAssertThrowsError(try fixture.boundary.issueRemuxVideoAppend(
            for: submission, writerBinding: otherBinding
        )) { error in
            XCTAssertEqual(error as? SegmentBoundaryFailure, .ticketMismatch)
        }
    }

    func testRemuxBuilderRejectsParameterAndFormatDriftBeforeTicket() throws {
        let frozen = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 9_500
        )
        var changedSPS = AssemblerTestFixtures.h264SPS
        changedSPS[3] = changedSPS[3] &+ 1
        let drift = try Task17Fixtures.remuxFixture(
            codec: .h264,
            sampleEntry: .avc1,
            seed: 9_501,
            parameterSetsOverride: [changedSPS, AssemblerTestFixtures.h264PPS]
        )
        XCTAssertThrowsError(try frozen.builder.makeSubmission(
            for: drift.timed[0], admission: drift.admissions[0]
        )) { error in
            XCTAssertEqual(error as? HLSVideoRemuxSubmissionFailure, .formatMismatch)
        }
        XCTAssertEqual(frozen.boundary.commonBoundaries.count, 1,
                       "格式漂移必须在旧 writer ticket 之前拒绝")
    }

    func testRemuxSubmissionFreezesOutputBeforeMutableSourceSampleChanges() throws {
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 9_600
        )
        let submission = try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0]
        )
        let sourceSample = fixture.timed[0].source.sampleBuffer
        let sourceLength = CMBlockBufferGetDataLength(try XCTUnwrap(
            CMSampleBufferGetDataBuffer(sourceSample)
        ))
        try Task17Fixtures.replacePayload(
            sourceSample, with: Data(repeating: 0xA5, count: sourceLength)
        )
        let factory = Task17FakeSystemWriterFactory()
        let writer = try Task17Fixtures.makeWriter(
            seed: 9_600, kind: .video, writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary, factory: factory
        )
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try writer.appendRemuxVideo(
            submission,
            ticket: try fixture.boundary.issueRemuxVideoAppend(
                for: submission, writerBinding: writer.binding
            )
        )
        XCTAssertEqual(factory.lastWriter?.appendCount, 1,
                       "writer 只能物化 builder 已冻结且未外露的输出 bytes")
    }

    func testRemuxOutputAdmissionRejectsBeforeMaterializationWithoutLedgerSideEffect() throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 9_700,
            applicationLedger: ledger
        )
        let remaining = HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes
            - ledger.chargedBytes
        let blocker = try ledger.reserve(allocationIdentity: UUID(), bytes: remaining)
        defer { ledger.release(blocker) }
        let before = ledger.chargedBytes
        XCTAssertThrowsError(try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0]
        )) { error in
            XCTAssertEqual(error as? HLSVideoRemuxSubmissionFailure, .allocationRejected)
        }
        XCTAssertEqual(ledger.chargedBytes, before,
                       "拒绝必须发生在 Data/CMBlockBuffer 构造及新 reservation 之前")
        XCTAssertEqual(fixture.boundary.commonBoundaries.count, 1,
                       "准入拒绝不能签发或提交 writer ticket")
    }

    func testRealSystemWriterConsumesPrivateRemuxPayloadAndProducesValidatedObjects()
        async throws {
        for (index, entry) in [
            HLSVideoSampleEntry.avc1, .avc3, .hvc1, .hev1,
        ].enumerated() {
            let fixture = try Task17Fixtures.remuxFixture(
                codec: index < 2 ? .h264 : .hevc,
                sampleEntry: entry,
                seed: UInt64(9_800 + index)
            )
            let collector = Task17ObjectCollector()
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(9_800 + index), kind: .video,
                writerBinding: fixture.binding,
                sourceFormatHint: fixture.builder.formatDescription,
                boundary: fixture.boundary, collector: collector
            )
            let submission = try fixture.builder.makeSubmission(
                for: fixture.timed[0], admission: fixture.admissions[0]
            )
            try writer.start(at: CMTime(value: 10, timescale: 1))
            try writer.appendRemuxVideo(
                submission,
                ticket: try fixture.boundary.issueRemuxVideoAppend(
                    for: submission, writerBinding: writer.binding
                )
            )
            _ = try await writer.finish()
            let initialization = try XCTUnwrap(
                collector.objects.first { $0.kind == .initialization }
            )
            let media = try XCTUnwrap(collector.objects.first { $0.kind == .media })
            let proof = try FinalFMP4Validator(
                binding: writer.binding, mediaType: .video
            ).validateInitialization(initialization)
            XCTAssertNoThrow(
                try SegmentTimelineValidator(proof: proof).validate(media, using: proof)
            )
            let marker = String(bytes: [
                UInt8(truncatingIfNeeded: entry.fourCharacterCode >> 24),
                UInt8(truncatingIfNeeded: entry.fourCharacterCode >> 16),
                UInt8(truncatingIfNeeded: entry.fourCharacterCode >> 8),
                UInt8(truncatingIfNeeded: entry.fourCharacterCode),
            ], encoding: .ascii)!
            XCTAssertTrue(Task17Fixtures.hasTopLevelMarker(marker, in: initialization.bytes))
            XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("moof", in: media.bytes))
            if entry == .hvc1 || entry == .hev1 {
                XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("colr", in: initialization.bytes))
                XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("mdcv", in: initialization.bytes))
                XCTAssertTrue(Task17Fixtures.hasTopLevelMarker("clli", in: initialization.bytes))
                XCTAssertNotNil(
                    media.bytes.range(of: Task17Fixtures.task22HEVCHDRSEI()),
                    "真实 HEVC SEI 必须保留在 sealed media 字节中"
                )
            }
            XCTAssertTrue(try XCTUnwrap(initialization.publicationEvidence).matches(initialization))
            XCTAssertTrue(try XCTUnwrap(media.publicationEvidence).matches(media))

            let frozenBytes = initialization.bytes
            var callerCopy = frozenBytes
            callerCopy[callerCopy.startIndex] ^= 0xFF
            XCTAssertEqual(initialization.bytes, frozenBytes,
                           "回调对象必须保留 immutable copy，调用方副本不能回写")
        }
    }

    func testRemuxRolloverResignsImmutableAttemptForSamePendingCore() async throws {
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 39_100,
            frames: [
                .init(pts: 10_000, dts: 10_000, isIDR: true),
                .init(pts: 11_000, dts: 11_000, isIDR: true),
            ],
            frameDuration: CMTime(value: 1, timescale: 1)
        )
        let transferGate = Task22TransferReleaseGate()
        let first = try Task17Fixtures.makeWriter(
            seed: 39_100, kind: .video,
            writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary,
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 2),
            transferGate: transferGate
        )
        try first.start(at: CMTime(value: 10, timescale: 1))
        let accepted = try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0]
        )
        try first.appendRemuxVideo(
            accepted,
            ticket: try fixture.boundary.issueRemuxVideoAppend(
                for: accepted, writerBinding: first.binding)
        )
        let pending = try fixture.builder.makeSubmission(
            for: fixture.timed[1], admission: fixture.admissions[1]
        )
        let oldAttempt = try pending.claimWriterAttempt(binding: first.binding)
        let oldTicket = try fixture.boundary.issueRemuxVideoAppend(for: oldAttempt)
        XCTAssertThrowsError(try first.appendRemuxVideo(oldAttempt, ticket: oldTicket)) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .rolloverRequired)
        }
        XCTAssertNil(oldTicket.committedBoundary)

        let finishReturned = DispatchSemaphore(value: 0)
        let finishTask = Task {
            defer { finishReturned.signal() }
            return try await first.finishWriterWindow()
        }
        XCTAssertTrue(transferGate.waitForObjectCount(2))
        XCTAssertEqual(finishReturned.wait(timeout: .now()), .timedOut,
                       "真实 terminal 不能越过仍被 publication 持有的 transfer")
        transferGate.releaseAll()
        let continuation = try await finishTask.value
        let nextBinding = Task17Fixtures.rolloverBinding(
            from: first.binding,
            writerIdentity: .init(rawValue: 39_101)
        )
        let next = try Task17Fixtures.makeWriter(
            seed: 39_101, kind: .video,
            writerBinding: nextBinding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary,
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 2),
            writerWindowContinuation: continuation,
            releaseTransfersImmediately: true
        )
        let admission = try XCTUnwrap(next.writerWindowAdmission)
        let nextAttempt = try pending.claimWriterAttempt(
            binding: next.binding, admission: admission
        )
        XCTAssertEqual(oldAttempt.pendingIdentity, nextAttempt.pendingIdentity)
        XCTAssertNotEqual(oldAttempt.attemptIdentity, nextAttempt.attemptIdentity)
        try next.start(at: .zero)
        let nextTicket = try fixture.boundary.issueRemuxVideoAppend(for: nextAttempt)
        XCTAssertNoThrow(try next.appendRemuxVideo(nextAttempt, ticket: nextTicket))
        let staleTicket = try fixture.boundary.issueRemuxVideoAppend(for: oldAttempt)
        XCTAssertThrowsError(try next.appendRemuxVideo(oldAttempt, ticket: staleTicket))
        XCTAssertNil(staleTicket.committedBoundary)
        XCTAssertThrowsError(try pending.claimWriterAttempt(
            binding: next.binding, admission: admission
        ))
        _ = next.cancel()
    }

    func testSuccessorAttemptAllocationBackpressureDoesNotConsumeAdmissionOrPending()
        async throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 39_105,
            frames: [
                .init(pts: 0, dts: 0, isIDR: true),
                .init(pts: 1, dts: 1, isIDR: true),
            ], frameDuration: CMTime(value: 1, timescale: 1),
            frameTimestampTimescale: 1,
            applicationLedger: ledger)
        let first = try Task17Fixtures.makeWriter(
            seed: 39_105, kind: .video, writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary,
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 2),
            releaseTransfersImmediately: true)
        try first.start(at: .zero)
        let accepted = try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0])
        try first.appendRemuxVideo(
            accepted,
            ticket: try fixture.boundary.issueRemuxVideoAppend(
                for: accepted, writerBinding: first.binding))
        let pending = try fixture.builder.makeSubmission(
            for: fixture.timed[1], admission: fixture.admissions[1])
        let oldAttempt = try pending.claimWriterAttempt(binding: first.binding)
        let oldTicket = try fixture.boundary.issueRemuxVideoAppend(for: oldAttempt)
        XCTAssertThrowsError(try first.appendRemuxVideo(oldAttempt, ticket: oldTicket)) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .rolloverRequired)
        }
        let continuation = try await first.finishWriterWindow()
        let nextBinding = Task17Fixtures.rolloverBinding(
            from: first.binding, writerIdentity: .init(rawValue: 39_106))
        let nextFactory = Task17FakeSystemWriterFactory()
        let next = try Task17Fixtures.makeWriter(
            seed: 39_106, kind: .video, writerBinding: nextBinding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary, factory: nextFactory,
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 2),
            writerWindowContinuation: continuation,
            releaseTransfersImmediately: true)
        let admission = try XCTUnwrap(next.writerWindowAdmission)
        let beforePressure = ledger.chargedBytes
        let pressure = try ledger.reserve(
            allocationIdentity: UUID(),
            bytes: HLSDeliveryApplicationChargeLedger.documentedApplicationHardBytes
                - beforePressure)
        let pressured = ledger.chargedBytes
        XCTAssertThrowsError(try pending.claimWriterAttempt(
            binding: nextBinding, admission: admission)) {
            XCTAssertEqual($0 as? HLSVideoRemuxSubmissionFailure, .allocationRejected)
        }
        XCTAssertEqual(ledger.chargedBytes, pressured)
        XCTAssertEqual(nextFactory.lastWriter?.appendCount, 0)
        XCTAssertNil(oldTicket.committedBoundary)
        XCTAssertEqual(fixture.boundary.usage.lastLogicalSequence, 0)
        ledger.release(pressure)
        XCTAssertEqual(ledger.chargedBytes, beforePressure)
        let retry = try pending.claimWriterAttempt(
            binding: nextBinding, admission: admission)
        XCTAssertEqual(retry.pendingIdentity, ObjectIdentifier(pending))
        XCTAssertEqual(nextFactory.lastWriter?.appendCount, 0)
        _ = next.cancel()
    }

    func testCurrentWriterAttemptIsOneCanonicalChargedShellAcrossConcurrentAccessors()
        throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 39_107,
            applicationLedger: ledger)
        let pending = try fixture.builder.makeSubmission(
            for: fixture.timed[0], admission: fixture.admissions[0])
        let baseline = ledger.chargedBytes
        var canonical: HLSVideoRemuxWriterAttempt? = try pending.claimWriterAttempt(
            binding: fixture.binding)
        let charged = ledger.chargedBytes
        XCTAssertGreaterThan(charged, baseline)
        let identities = Task22AttemptIdentityCollector()
        let binding = fixture.binding
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let current = try! pending.currentWriterAttempt(binding: binding)
            identities.append(ObjectIdentifier(current))
        }
        XCTAssertEqual(Set(identities.values).count, 1)
        XCTAssertTrue(try pending.currentWriterAttempt(binding: fixture.binding) === canonical)
        XCTAssertEqual(ledger.chargedBytes, charged)
        XCTAssertTrue(canonical?.relinquishAfterAbort() == true)
        var retained: HLSVideoRemuxWriterAttempt? = try pending.claimWriterAttempt(
            binding: fixture.binding)
        XCTAssertGreaterThan(ledger.chargedBytes, charged)
        canonical = nil
        XCTAssertEqual(ledger.chargedBytes, charged,
                       "最后外部旧attempt alias释放后才归还旧shell费用")
        XCTAssertTrue(retained?.relinquishAfterAbort() == true)
        retained = nil
        XCTAssertEqual(ledger.chargedBytes, baseline)
    }

    func testWriterWindowContinuationRejectsTrackAndFrozenFormatMutations()
        async throws {
        let wrongTrack = try await makeRealRemuxWindowContinuation(seed: 39_192)
        let audio = try Task17AC3Harness(seed: 39_192)
            .makeAccessUnit(presentationTimeStamp: .zero)
        XCTAssertThrowsError(try Task17Fixtures.makeWriter(
            seed: 39_193, kind: .ac3,
            writerBinding: Task17Fixtures.rolloverBinding(
                from: wrongTrack.binding, writerIdentity: .init(rawValue: 139_192)),
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: audio),
            boundary: wrongTrack.boundary,
            compressedFormatConfiguration: audio.formatConfiguration,
            writerWindowContinuation: wrongTrack.continuation,
            releaseTransfersImmediately: true))

        let wrongFormat = try await makeRealRemuxWindowContinuation(seed: 39_194)
        let drift = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc3, seed: 39_195)
        XCTAssertThrowsError(try Task17Fixtures.makeWriter(
            seed: 39_195, kind: .video,
            writerBinding: Task17Fixtures.rolloverBinding(
                from: wrongFormat.binding, writerIdentity: .init(rawValue: 139_194)),
            sourceFormatHint: drift.builder.formatDescription,
            boundary: wrongFormat.boundary,
            writerWindowContinuation: wrongFormat.continuation,
            releaseTransfersImmediately: true))

        let wrongConfiguration = try await makeRealRemuxWindowContinuation(
            seed: 39_196, codec: .hevc, sampleEntry: .hvc1,
            parameterSets: Task17Fixtures.task22HEVCParameterSets(
                transferCharacteristics: 1))
        let configurationDrift = try Task17Fixtures.remuxFixture(
            codec: .hevc, sampleEntry: .hvc1, seed: 39_197,
            parameterSetsOverride: Task17Fixtures.task22HEVCParameterSets(
                transferCharacteristics: 18),
            includeHDRMetadata: false)
        XCTAssertThrowsError(try Task17Fixtures.makeWriter(
            seed: 39_197, kind: .video,
            writerBinding: Task17Fixtures.rolloverBinding(
                from: wrongConfiguration.binding,
                writerIdentity: .init(rawValue: 139_196)),
            sourceFormatHint: configurationDrift.builder.formatDescription,
            boundary: wrongConfiguration.boundary,
            writerWindowContinuation: wrongConfiguration.continuation,
            releaseTransfersImmediately: true))

        let compressedSeed: UInt64 = 39_198
        let compressedOwner = Task17Fixtures.compressedOwner(seed: compressedSeed)
        let compressedAdmission = AudioBranchAdmissionIdentity.directCompressed(
            compressedOwner, branchGeneration: compressedSeed + 10,
            admissionFenceRevision: compressedSeed + 11)
        let compressed = try Task17AC3Harness(
            seed: compressedSeed, admission: compressedAdmission)
        let firstCompressed = try compressed.makeAccessUnit(presentationTimeStamp: .zero)
        let compressedBoundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: .zero))
        let compressedBinding = Task17Fixtures.binding(seed: compressedSeed)
        try compressedBoundary.registerAudioRendition(
            compressedBinding.renditionIdentity,
            accessUnit: .ac3(sampleRate: 48_000), firstEffectiveStart: .zero)
        let compressedWriter = try Task17Fixtures.makeWriter(
            seed: compressedSeed, kind: .ac3, writerBinding: compressedBinding,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: firstCompressed),
            boundary: compressedBoundary,
            compressedFormatConfiguration: firstCompressed.formatConfiguration,
            ownershipLimits: .init(rolloverThreshold: 32, hardCapacity: 64),
            releaseTransfersImmediately: true)
        try compressedWriter.start(at: .zero)
        for index in 0..<32 {
            let unit = index == 0 ? firstCompressed : try compressed.makeAccessUnit(
                presentationTimeStamp: CMTime(
                    value: Int64(index * 1_536), timescale: 48_000))
            try compressedWriter.appendCompressed(
                unit.writerSubmission, coordinator: compressed.coordinator,
                ticket: try compressedBoundary.issueCompressedAudioAppend(
                    for: unit, writerBinding: compressedBinding))
        }
        let rolloverCompressed = try compressed.makeAccessUnit(
            presentationTimeStamp: CMTime(value: 32 * 1_536, timescale: 48_000))
        XCTAssertThrowsError(try compressedWriter.appendCompressed(
            rolloverCompressed.writerSubmission, coordinator: compressed.coordinator,
            ticket: try compressedBoundary.issueCompressedAudioAppend(
                for: rolloverCompressed, writerBinding: compressedBinding))) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .rolloverRequired)
        }
        let compressedContinuation = try await compressedWriter.finishWriterWindow()
        let differentDuration = try Task17AC3Harness(
            seed: compressedSeed + 1_000, admission: compressedAdmission,
            sampleRate: 32_000)
        let slowerUnit = try differentDuration.makeAccessUnit(
            presentationTimeStamp: CMTime(value: 32 * 1_536, timescale: 48_000))
        XCTAssertNotEqual(slowerUnit.presentationEnd, rolloverCompressed.presentationEnd)
        let beforeCompressed = compressedBoundary.usage
        let beforeClaims = differentDuration.coordinator
            .claimedCompressedWriterSubmissionCount
        XCTAssertThrowsError(try Task17Fixtures.makeWriter(
            seed: compressedSeed + 1, kind: .ac3,
            writerBinding: Task17Fixtures.rolloverBinding(
                from: compressedBinding, writerIdentity: .init(rawValue: 139_198)),
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: slowerUnit),
            boundary: compressedBoundary,
            compressedFormatConfiguration: slowerUnit.formatConfiguration,
            writerWindowContinuation: compressedContinuation,
            releaseTransfersImmediately: true))
        XCTAssertEqual(compressedBoundary.usage, beforeCompressed)
        XCTAssertEqual(differentDuration.coordinator.claimedCompressedWriterSubmissionCount,
                       beforeClaims)
        XCTAssertTrue(differentDuration.coordinator.claimCompressedAudioWriterSubmission(
            slowerUnit.writerSubmission,
            expectedIdentity: CompressedAudioWriterExpectedIdentity(
                codec: .ac3,
                admissionIdentity: compressedAdmission,
                formatConfiguration: slowerUnit.formatConfiguration)))
        XCTAssertEqual(slowerUnit.confirmWriterTerminal(using: differentDuration.coordinator), 1)
    }

    func testRemuxSuccessorRejectsFirstDecodeCadenceGapDuplicateAndBackwardWithoutMutation()
        async throws {
        let candidateIndexes = [3, 1, 0]
        for (offset, candidateIndex) in candidateIndexes.enumerated() {
            let seed = UInt64(39_300 + offset * 10)
            let predecessor = try await makeRealRemuxWindowContinuation(
                seed: seed, acceptedInputCount: 2)
            guard case let .remuxVideo(_, expectedDTS) = predecessor.continuation.cadence
            else { return XCTFail("remux continuation 必须携带 exact-next DTS") }
            let candidate = try Task17Fixtures.remuxFixture(
                codec: .h264, sampleEntry: .avc1, seed: seed,
                frames: [
                    .init(pts: 10, dts: 10, isIDR: true),
                    .init(pts: 11, dts: 11, isIDR: true),
                    .init(pts: 12, dts: 12, isIDR: true),
                    .init(pts: 13, dts: 13, isIDR: true),
                ],
                frameDuration: CMTime(value: 1, timescale: 1),
                frameTimestampTimescale: 1)
            let nextBinding = Task17Fixtures.rolloverBinding(
                from: predecessor.binding,
                writerIdentity: .init(rawValue: seed + 50_000))
            let next = try Task17Fixtures.makeWriter(
                seed: seed + 1, kind: .video, writerBinding: nextBinding,
                sourceFormatHint: predecessor.format,
                boundary: predecessor.boundary,
                ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 2),
                writerWindowContinuation: predecessor.continuation,
                releaseTransfersImmediately: true)
            let invalid = try candidate.builder.makeSubmission(
                for: candidate.timed[candidateIndex],
                admission: candidate.admissions[candidateIndex])
            let attempt = try invalid.claimWriterAttempt(
                binding: nextBinding,
                admission: try XCTUnwrap(next.writerWindowAdmission))
            let actualDTS = try XCTUnwrap(attempt.decodeTimeStamp)
            if offset == 0 {
                XCTAssertGreaterThan(CMTimeCompare(actualDTS.cmTime, expectedDTS.cmTime), 0)
            } else if offset == 1 {
                XCTAssertEqual(actualDTS, try expectedDTS.subtracting(
                    ExactMediaTime(value: 1, timescale: 1)))
            } else {
                XCTAssertLessThan(CMTimeCompare(actualDTS.cmTime, expectedDTS.cmTime), 0)
            }
            try next.start(at: .zero)
            let before = predecessor.boundary.usage
            let ticket = try predecessor.boundary.issueRemuxVideoAppend(for: attempt)
            XCTAssertThrowsError(try next.appendRemuxVideo(attempt, ticket: ticket)) {
                XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .sourceFormatMismatch)
            }
            XCTAssertNil(ticket.committedBoundary)
            XCTAssertEqual(predecessor.boundary.usage, before)
            XCTAssertEqual(next.usage.retainedTerminalOwnershipCount, 0)
            _ = next.cancel()
        }
    }

    func testCompressedSuccessorRejectsFirstPTSDiscontinuityWithoutClaimOrMutation()
        async throws {
        for kind: SegmentedFMP4TrackKind in [.ac3, .eac3] {
            for (offset, delta) in [Int64(1), -49_152, -49_153].enumerated() {
                try await exerciseCompressedSuccessorPTSRejection(
                    kind: kind,
                    seed: UInt64(39_400 + (kind == .ac3 ? 0 : 100) + offset * 10),
                    invalidDelta: delta)
            }
        }
    }

    func testRealSystemVTSuccessorRejectsFirstPTSAndDurationDiscontinuityWithoutMutation()
        async throws {
        for mutation in Task22GenericVideoPublicationHarness.SystemVTCadenceMutation.allCases {
            let harness = try Task22GenericVideoPublicationHarness(
                audioKind: .ac3, videoMode: .systemVT)
            try await harness.exerciseSystemVTSuccessorFirstCadenceRejection(mutation)
        }
    }

    private func exerciseCompressedSuccessorPTSRejection(
        kind: SegmentedFMP4TrackKind,
        seed: UInt64,
        invalidDelta: Int64
    ) async throws {
        let owner = Task17Fixtures.compressedOwner(seed: seed)
        let admission: AudioBranchAdmissionIdentity = kind == .ac3
            ? .directCompressed(owner, branchGeneration: seed + 10,
                                admissionFenceRevision: seed + 11)
            : .eac3Aggregation(owner, branchGeneration: seed + 10,
                               admissionFenceRevision: seed + 11)
        let ac3 = kind == .ac3
            ? try Task17AC3Harness(seed: seed, admission: admission) : nil
        let eac3 = kind == .eac3
            ? try Task17EAC3Harness(seed: seed, admission: admission) : nil
        func unit(at value: Int64) throws -> CompressedAudioAccessUnit {
            let time = CMTime(value: value, timescale: 48_000)
            return try ac3?.makeAccessUnit(presentationTimeStamp: time)
                ?? eac3!.makeSixMemberAccessUnit(presentationBase: time)
        }
        let firstUnit = try unit(at: 0)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let binding = Task17Fixtures.binding(seed: seed)
        try boundary.registerAudioRendition(
            binding.renditionIdentity,
            accessUnit: kind == .ac3 ? .ac3(sampleRate: 48_000)
                : .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536),
            firstEffectiveStart: .zero)
        let first = try Task17Fixtures.makeWriter(
            seed: seed, kind: kind, writerBinding: binding,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: firstUnit),
            boundary: boundary,
            compressedFormatConfiguration: firstUnit.formatConfiguration,
            ownershipLimits: .init(rolloverThreshold: 32, hardCapacity: 64),
            releaseTransfersImmediately: true)
        try first.start(at: .zero)
        for index in 0..<32 {
            let value = Int64(index * 1_536)
            let accessUnit = index == 0 ? firstUnit : try unit(at: value)
            try first.appendCompressed(
                accessUnit.writerSubmission,
                coordinator: ac3?.coordinator ?? eac3!.coordinator,
                ticket: try boundary.issueCompressedAudioAppend(
                    for: accessUnit, writerBinding: first.binding))
        }
        let rolloverUnit = try unit(at: 32 * 1_536)
        XCTAssertThrowsError(try first.appendCompressed(
            rolloverUnit.writerSubmission,
            coordinator: ac3?.coordinator ?? eac3!.coordinator,
            ticket: try boundary.issueCompressedAudioAppend(
                for: rolloverUnit, writerBinding: first.binding))) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .rolloverRequired)
        }
        let continuation = try await first.finishWriterWindow()
        let nextBinding = Task17Fixtures.rolloverBinding(
            from: binding, writerIdentity: .init(rawValue: seed + 50_000))
        let nextFactory = Task17FakeSystemWriterFactory()
        let next = try Task17Fixtures.makeWriter(
            seed: seed + 1, kind: kind, writerBinding: nextBinding,
            sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: firstUnit),
            boundary: boundary,
            compressedFormatConfiguration: firstUnit.formatConfiguration,
            factory: nextFactory,
            ownershipLimits: .init(rolloverThreshold: 32, hardCapacity: 64),
            writerWindowContinuation: continuation,
            releaseTransfersImmediately: true)
        let invalidHarnessAC3 = kind == .ac3
            ? try Task17AC3Harness(seed: seed + 1_000, admission: admission) : nil
        let invalidHarnessEAC3 = kind == .eac3
            ? try Task17EAC3Harness(seed: seed + 1_000, admission: admission) : nil
        let invalidStart = 32 * Int64(1_536) + invalidDelta
        let invalid = try invalidHarnessAC3?.makeAccessUnit(
            presentationTimeStamp: CMTime(value: invalidStart, timescale: 48_000))
            ?? invalidHarnessEAC3!.makeSixMemberAccessUnit(
                presentationBase: CMTime(value: invalidStart, timescale: 48_000))
        try next.start(at: .zero)
        let beforeUsage = boundary.usage
        let beforeClaims = (invalidHarnessAC3?.coordinator
            ?? invalidHarnessEAC3!.coordinator).claimedCompressedWriterSubmissionCount
        let ticket = try boundary.issueCompressedAudioAppend(
            for: invalid, writerBinding: next.binding)
        XCTAssertThrowsError(try next.appendCompressed(
            invalid.writerSubmission,
            coordinator: invalidHarnessAC3?.coordinator ?? invalidHarnessEAC3!.coordinator,
            ticket: ticket)) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .sourceFormatMismatch)
        }
        XCTAssertEqual(nextFactory.lastWriter?.appendCount, 0)
        XCTAssertNil(ticket.committedBoundary)
        XCTAssertEqual(boundary.usage, beforeUsage)
        XCTAssertEqual((invalidHarnessAC3?.coordinator
            ?? invalidHarnessEAC3!.coordinator).claimedCompressedWriterSubmissionCount,
                       beforeClaims)
        XCTAssertEqual(next.usage.retainedTerminalOwnershipCount, 0)
        _ = next.cancel()
    }

    func testWriterWindowContinuationRejectsEveryIdentityMutationSameWriterAndReplay()
        async throws {
        enum Mutation: CaseIterable {
            case lifecycle, item, media, participant, rendition, sameWriter
        }
        for (offset, mutation) in Mutation.allCases.enumerated() {
            let seed = UInt64(39_120 + offset * 10)
            let predecessor = try await makeRealRemuxWindowContinuation(seed: seed)
            let old = predecessor.binding
            let different = Task17Fixtures.binding(seed: seed + 50_000)
            let next = FMP4WriterBinding(
                outputLifecycleEpoch: mutation == .lifecycle
                    ? different.outputLifecycleEpoch : old.outputLifecycleEpoch,
                itemGeneration: mutation == .item
                    ? different.itemGeneration : old.itemGeneration,
                mediaEpoch: mutation == .media
                    ? different.mediaEpoch : old.mediaEpoch,
                publicationParticipantID: mutation == .participant
                    ? different.publicationParticipantID : old.publicationParticipantID,
                renditionIdentity: mutation == .rendition
                    ? different.renditionIdentity : old.renditionIdentity,
                writerIdentity: mutation == .sameWriter
                    ? old.writerIdentity : .init(rawValue: seed + 90_000))
            XCTAssertThrowsError(try Task17Fixtures.makeWriter(
                seed: seed, kind: .video, writerBinding: next,
                sourceFormatHint: predecessor.format,
                boundary: predecessor.boundary,
                writerWindowContinuation: predecessor.continuation,
                releaseTransfersImmediately: true))
        }

        let replay = try await makeRealRemuxWindowContinuation(seed: 39_190)
        let next = Task17Fixtures.rolloverBinding(
            from: replay.binding, writerIdentity: .init(rawValue: 139_190))
        _ = try Task17Fixtures.makeWriter(
            seed: 39_190, kind: .video, writerBinding: next,
            sourceFormatHint: replay.format, boundary: replay.boundary,
            writerWindowContinuation: replay.continuation,
            releaseTransfersImmediately: true)
        XCTAssertThrowsError(try Task17Fixtures.makeWriter(
            seed: 39_191, kind: .video,
            writerBinding: Task17Fixtures.rolloverBinding(
                from: replay.binding, writerIdentity: .init(rawValue: 139_191)),
            sourceFormatHint: replay.format, boundary: replay.boundary,
            writerWindowContinuation: replay.continuation,
            releaseTransfersImmediately: true))
    }

    private func makeRealRemuxWindowContinuation(
        seed: UInt64,
        codec: VideoCodec = .h264,
        sampleEntry: HLSVideoSampleEntry = .avc1,
        parameterSets: [Data]? = nil,
        acceptedInputCount: Int = 1
    ) async throws -> (
        binding: FMP4WriterBinding,
        format: CMFormatDescription,
        boundary: SegmentBoundaryCoordinator,
        continuation: WriterWindowContinuation
    ) {
        let frames: [Task17Fixtures.RemuxFrame] = (0...acceptedInputCount).map { index in
            let timestamp = Int64(10_000 + index * 1_000)
            return .init(pts: timestamp, dts: timestamp, isIDR: true)
        }
        let fixture = try Task17Fixtures.remuxFixture(
            codec: codec, sampleEntry: sampleEntry, seed: seed,
            frames: frames, frameDuration: CMTime(value: 1, timescale: 1),
            parameterSetsOverride: parameterSets,
            includeHDRMetadata: parameterSets == nil)
        let writer = try Task17Fixtures.makeWriter(
            seed: seed, kind: .video, writerBinding: fixture.binding,
            sourceFormatHint: fixture.builder.formatDescription,
            boundary: fixture.boundary,
            ownershipLimits: .init(
                rolloverThreshold: acceptedInputCount,
                hardCapacity: acceptedInputCount + 1),
            releaseTransfersImmediately: true)
        try writer.start(at: CMTime(value: 10, timescale: 1))
        for index in 0...acceptedInputCount {
            let submission = try fixture.builder.makeSubmission(
                for: fixture.timed[index], admission: fixture.admissions[index])
            do {
                try writer.appendRemuxVideo(
                    submission,
                    ticket: try fixture.boundary.issueRemuxVideoAppend(
                        for: submission, writerBinding: writer.binding))
            } catch SegmentedFMP4WriterFailure.rolloverRequired {
                XCTAssertEqual(index, acceptedInputCount)
            }
        }
        return (fixture.binding, fixture.builder.formatDescription,
                fixture.boundary, try await writer.finishWriterWindow())
    }

    func testRealInitializationCompatibilityFactsIncludeSampleEntryAndCodecBoxes()
        async throws {
        var facts: [FMP4InitializationCompatibilityFacts] = []
        let videoCases: [(HLSVideoSampleEntry, [Data]?)] = [
            (.avc1, nil), (.avc3, nil), (.hvc1, nil), (.hev1, nil),
            (.hvc1, Task17Fixtures.task22HEVCParameterSets(transferCharacteristics: 18)),
        ]
        for (index, videoCase) in videoCases.enumerated() {
            let entry = videoCase.0
            let fixture = try Task17Fixtures.remuxFixture(
                codec: index < 2 ? .h264 : .hevc,
                sampleEntry: entry,
                seed: UInt64(39_200 + index),
                parameterSetsOverride: videoCase.1
            )
            let collector = Task17ObjectCollector()
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(39_200 + index), kind: .video,
                writerBinding: fixture.binding,
                sourceFormatHint: fixture.builder.formatDescription,
                boundary: fixture.boundary,
                collector: collector
            )
            let submission = try fixture.builder.makeSubmission(
                for: fixture.timed[0], admission: fixture.admissions[0]
            )
            try writer.start(at: CMTime(value: 10, timescale: 1))
            try writer.appendRemuxVideo(
                submission,
                ticket: try fixture.boundary.issueRemuxVideoAppend(
                    for: submission, writerBinding: writer.binding)
            )
            _ = try await writer.finish()
            let initialization = try XCTUnwrap(
                collector.objects.first { $0.kind == .initialization })
            facts.append(try SealedDecodeCoverageMap.initializationCompatibilityFacts(
                initialization, mediaType: .video))
        }
        XCTAssertEqual(facts.map(\.sampleEntryMode), [.avc1, .avc3, .hvc1, .hev1, .hvc1])
        XCTAssertNotEqual(facts[2].decoderConfigurationDigest,
                          facts[4].decoderConfigurationDigest,
                          "同 hvc1 entry 的 transfer/color 配置变化必须不兼容")
        XCTAssertEqual(Set(facts.prefix(4).map(\.decoderConfigurationDigest)).count, 4,
                       "entry mode、codec config、color/HDR boxes 必须进入兼容事实")

        var compressedFacts: [FMP4InitializationCompatibilityFacts] = []
        for (offset, kind) in [SegmentedFMP4TrackKind.ac3, .eac3].enumerated() {
            let harness = kind == .ac3
                ? try Task17AC3Harness(seed: UInt64(39_260 + offset))
                : nil
            let eac3Harness = kind == .eac3
                ? try Task17EAC3Harness(seed: UInt64(39_260 + offset))
                : nil
            let unit = try harness?.makeAccessUnit(presentationTimeStamp: .zero)
                ?? eac3Harness!.makeSixMemberAccessUnit()
            let collector = Task17ObjectCollector()
            let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
            let binding = Task17Fixtures.binding(seed: UInt64(39_260 + offset))
            try boundary.registerAudioRendition(
                binding.renditionIdentity,
                accessUnit: kind == .ac3 ? .ac3(sampleRate: 48_000)
                    : .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536),
                firstEffectiveStart: .zero)
            let writer = try Task17Fixtures.makeWriter(
                seed: UInt64(39_260 + offset), kind: kind,
                writerBinding: binding,
                sourceFormatHint: try Task17Fixtures.compressedAudioFormat(for: unit),
                boundary: boundary,
                compressedFormatConfiguration: unit.formatConfiguration,
                collector: collector,
                releaseTransfersImmediately: true)
            try writer.start(at: .zero)
            try writer.appendCompressed(
                unit.writerSubmission,
                coordinator: harness?.coordinator ?? eac3Harness!.coordinator,
                ticket: try boundary.issueCompressedAudioAppend(
                    for: unit, writerBinding: writer.binding))
            _ = try await writer.finish()
            compressedFacts.append(try SealedDecodeCoverageMap.initializationCompatibilityFacts(
                try XCTUnwrap(collector.objects.first { $0.kind == .initialization }),
                mediaType: .audio))
        }
        XCTAssertEqual(compressedFacts.map(\.sampleEntryMode), [.audio, .audio])
        XCTAssertNotEqual(compressedFacts[0].decoderConfigurationDigest,
                          compressedFacts[1].decoderConfigurationDigest,
                          "ac-3/ec-3 sample entry 与压缩配置 box 必须不兼容")
    }

    func testRealAC3AndEAC3Exceed384AppendsAcrossThreePhysicalWriterWindows()
        async throws {
        for kind: SegmentedFMP4TrackKind in [.ac3, .eac3] {
            try await exerciseRealCompressedWriterWindows(kind: kind)
        }
    }

    func testRealRemuxExceeds384AppendsAcrossThreePhysicalWriterWindows()
        async throws {
        let frames = (0..<385).map { index in
            Task17Fixtures.RemuxFrame(
                pts: 300_000 + Int64(index * 1_000),
                dts: 300_000 + Int64(index * 1_000),
                isIDR: true)
        }
        let fixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 39_500,
            frames: frames,
            frameDuration: CMTime(value: 1, timescale: 30),
            frameTimestampTimescale: 30_000)
        var binding = fixture.binding
        var builder = fixture.builder
        var writer = try Task17Fixtures.makeWriter(
            seed: 39_500, kind: .video, writerBinding: binding,
            sourceFormatHint: builder.formatDescription,
            boundary: fixture.boundary,
            ownershipLimits: .init(rolloverThreshold: 160, hardCapacity: 384),
            releaseTransfersImmediately: true)
        try writer.start(at: CMTime(value: 10, timescale: 1))

        var inputIndex = 0
        var windowInputCounts: [Int] = []
        while inputIndex < fixture.timed.count {
            let submission = try builder.makeSubmission(
                for: fixture.timed[inputIndex],
                admission: fixture.admissions[inputIndex])
            do {
                try writer.appendRemuxVideo(
                    submission,
                    ticket: try fixture.boundary.issueRemuxVideoAppend(
                        for: submission, writerBinding: writer.binding))
                inputIndex += 1
            } catch SegmentedFMP4WriterFailure.rolloverRequired {
                XCTAssertLessThanOrEqual(
                    writer.usage.retainedTerminalOwnershipCount, 384)
                let continuation = try await writer.finishWriterWindow()
                windowInputCounts.append(continuation.predecessorTerminal.inputCount)
                binding = Task17Fixtures.rolloverBinding(
                    from: binding,
                    writerIdentity: .init(rawValue: 49_500
                        + UInt64(windowInputCounts.count)))
                writer = try Task17Fixtures.makeWriter(
                    seed: 39_500, kind: .video, writerBinding: binding,
                    sourceFormatHint: builder.formatDescription,
                    boundary: fixture.boundary,
                    ownershipLimits: .init(rolloverThreshold: 160, hardCapacity: 384),
                    writerWindowContinuation: continuation,
                    releaseTransfersImmediately: true)
                let admission = try XCTUnwrap(writer.writerWindowAdmission)
                builder = try HLSVideoRemuxSubmissionBuilder(
                    resuming: builder, binding: binding, admission: admission)
                let attempt = try submission.claimWriterAttempt(
                    binding: binding, admission: admission)
                try writer.start(at: .zero)
                try writer.appendRemuxVideo(
                    attempt,
                    ticket: try fixture.boundary.issueRemuxVideoAppend(for: attempt))
                inputIndex += 1
            }
        }
        let final = try await writer.finish()
        windowInputCounts.append(final.inputCount)
        XCTAssertEqual(windowInputCounts.count, 3)
        XCTAssertEqual(windowInputCounts.reduce(0, +), 385)
        XCTAssertTrue(windowInputCounts.allSatisfy { $0 <= 384 })
        XCTAssertEqual(writer.usage.retainedTerminalOwnershipCount, 0)
    }

    func testRealRemuxThreeWriterWindowsKeepCanonicalInitAndServeEachWindowOverHTTP()
        async throws {
        try await exerciseRealRemuxAndCompressedAudioPublication(.ac3)
    }

    func testRealRemuxAndEAC3ThreeWriterWindowsServeCanonicalResourcesOverHTTP()
        async throws {
        try await exerciseRealRemuxAndCompressedAudioPublication(.eac3)
    }

    func testRealSystemVTOutputExceeds384AcrossThreeWriterWindowsAndHTTP()
        async throws {
        try await exerciseRealRemuxAndCompressedAudioPublication(
            .ac3, videoMode: .systemVT)
    }

    private func exerciseRealRemuxAndCompressedAudioPublication(
        _ audioKind: SegmentedFMP4TrackKind,
        videoMode: Task22GenericVideoPublicationHarness.VideoMode = .remux
    ) async throws {
        let harness = try Task22GenericVideoPublicationHarness(
            audioKind: audioKind, videoMode: videoMode)
        let factory = LoopbackHTTPSessionFactory()
        let server = try await factory.startPreparingAsynchronously(
            itemGeneration: harness.itemGeneration, now: { 0 }, logger: { _ in },
            responseFailure: { _, _ in }, prepare: { token in
                try await harness.startPublication(loopbackSession: token)
            })
        var serverRetired = false
        defer {
            if !serverRetired {
                let ticket = server.closeAdmission()
                try? server.drain(cleanupTicket: ticket)
                try? server.retire(cleanupTicket: ticket)
            }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var canonicalInitializations: [UInt64: HLSResourceKey] = [:]
        var canonicalBodies: [UInt64: Data] = [:]
        var servedMedia: Set<HLSResourceKey> = []
        var windowsWithHTTP: [UInt64: Set<UInt64>] = [:]
        func serve(_ observation: Task22GenericVideoPublicationHarness.Observation) async throws {
            let snapshot = observation.snapshot
            for participantID in [harness.participantID, harness.audioParticipantID] {
                let playlist = try XCTUnwrap(snapshot.media[participantID])
                let initKey = try XCTUnwrap(playlist.initializationResources.first)
                if let canonical = canonicalInitializations[participantID] {
                    XCTAssertEqual(initKey, canonical,
                                   "第三窗仍须引用第一窗实际 served init")
                } else {
                    canonicalInitializations[participantID] = initKey
                }
                let initURL = try XCTUnwrap(URL(
                    string: server.path(for: initKey),
                    relativeTo: server.baseURL)?.absoluteURL)
                let (initBody, initResponse) = try await session.data(from: initURL)
                XCTAssertEqual(try XCTUnwrap(
                    initResponse as? HTTPURLResponse).statusCode, 200)
                if let canonicalBody = canonicalBodies[participantID] {
                    XCTAssertEqual(initBody, canonicalBody)
                } else {
                    canonicalBodies[participantID] = initBody
                }
                for key in playlist.resources where servedMedia.insert(key).inserted {
                    let url = try XCTUnwrap(URL(
                        string: server.path(for: key), relativeTo: server.baseURL)?.absoluteURL)
                    let (body, response) = try await session.data(from: url)
                    XCTAssertEqual(try XCTUnwrap(
                        response as? HTTPURLResponse).statusCode, 200)
                    XCTAssertFalse(body.isEmpty)
                    let map = try XCTUnwrap(harness.decodeCoverageMap(for: key),
                        "真实HTTP GET必须对应store正式parser的decode coverage")
                    XCTAssertEqual(map.sealedBodyLength, body.count)
                    XCTAssertFalse(map.samples.isEmpty)
                    XCTAssertFalse(map.commonByteSpans.isEmpty)
                    switch (participantID == harness.participantID, map.mediaType) {
                    case (true, .video), (false, .audio): break
                    default: XCTFail("decode coverage媒体类型必须匹配实际participant")
                    }
                    let source = try XCTUnwrap(observation.mediaSources[key],
                        "GET key 必须映射到产生该 sealed media 的准确物理 writer")
                    XCTAssertEqual(source.participantID, participantID)
                    windowsWithHTTP[source.participantID, default: []]
                        .insert(source.writerIdentity)
                }
            }
        }
        try await serve(harness.observation)
        try await harness.finish { try await serve($0) }
        XCTAssertGreaterThanOrEqual(harness.videoWriterWindowCount, 3)
        XCTAssertGreaterThanOrEqual(harness.audioWriterWindowCount, 3)
        XCTAssertGreaterThanOrEqual(windowsWithHTTP[harness.participantID]?.count ?? 0, 3)
        XCTAssertGreaterThanOrEqual(
            windowsWithHTTP[harness.audioParticipantID]?.count ?? 0, 3)
        XCTAssertEqual(canonicalBodies.count, 2)
        XCTAssertTrue(canonicalBodies.values.allSatisfy { !$0.isEmpty })
        XCTAssertGreaterThanOrEqual(servedMedia.count, 6)
        XCTAssertEqual(harness.maximumInstalledWindowCount, 2)
        if videoMode == .systemVT {
            XCTAssertEqual(harness.realVTEncodedFrameCount, 480)
            XCTAssertTrue(harness.realVTHardwareProofWasStable)
        }
        XCTAssertEqual(server.usage.activeResponses, 0,
                       "所有真实GET completion后response alias必须释放")
        XCTAssertEqual(server.usage.distinctBackingBytes, 0)
        let retainedKey = try XCTUnwrap(
            harness.observation.snapshot.media[harness.participantID]?.resources.last)
        let retainedResponse = try harness.retainResponseAlias(for: retainedKey)
        XCTAssertEqual(harness.responseBackingBytes, retainedResponse.residentByteCount)
        XCTAssertGreaterThan(harness.responseBackingBytes, 0)
        let cleanupTicket = server.closeAdmission()
        try server.drain(cleanupTicket: cleanupTicket)
        try server.retire(cleanupTicket: cleanupTicket)
        serverRetired = true
        XCTAssertEqual(server.usage.activeResponses, 0)
        XCTAssertEqual(server.usage.distinctBackingBytes, 0)
        XCTAssertEqual(harness.responseBackingBytes, retainedResponse.residentByteCount,
                       "server close/retire不能提前释放外部response backing alias")
        harness.releaseResponseAlias(retainedResponse)
        XCTAssertEqual(harness.responseBackingBytes, 0,
                       "最后response alias释放后store backing必须回到基线")
    }

    private func exerciseRealCompressedWriterWindows(
        kind: SegmentedFMP4TrackKind
    ) async throws {
        let seed: UInt64 = kind == .ac3 ? 39_300 : 39_400
        let makeUnit: (Int) throws -> (
            CompressedAudioAccessUnit, AudioServiceSemanticCoordinator)
        if kind == .ac3 {
            let harness = try Task17AC3Harness(seed: seed)
            makeUnit = { index in
                return (try harness.makeAccessUnit(presentationTimeStamp: CMTime(
                    value: Int64(index * 1_536), timescale: 48_000)),
                    harness.coordinator)
            }
        } else {
            let harness = try Task17EAC3Harness(seed: seed)
            makeUnit = { index in
                return (try harness.makeSixMemberAccessUnit(presentationBase: CMTime(
                    value: Int64(index * 1_536), timescale: 48_000)),
                    harness.coordinator)
            }
        }
        let firstPair = try makeUnit(0)
        let firstUnit = firstPair.0
        let format = try Task17Fixtures.compressedAudioFormat(for: firstUnit)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        var binding = Task17Fixtures.binding(seed: seed)
        try boundary.registerAudioRendition(
            binding.renditionIdentity,
            accessUnit: kind == .ac3
                ? .ac3(sampleRate: 48_000)
                : .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536),
            firstEffectiveStart: .zero)
        var writer = try Task17Fixtures.makeWriter(
            seed: seed, kind: kind, writerBinding: binding,
            sourceFormatHint: format, boundary: boundary,
            compressedFormatConfiguration: firstUnit.formatConfiguration,
            ownershipLimits: .init(rolloverThreshold: 160, hardCapacity: 384),
            releaseTransfersImmediately: true)
        try writer.start(at: .zero)

        var inputIndex = 0
        var windowInputCounts: [Int] = []
        while inputIndex < 385 {
            let pair = inputIndex == 0 ? firstPair : try makeUnit(inputIndex)
            let unit = pair.0
            let coordinator = pair.1
            do {
                try writer.appendCompressed(
                    unit.writerSubmission,
                    coordinator: coordinator,
                    ticket: try boundary.issueCompressedAudioAppend(
                        for: unit, writerBinding: writer.binding))
                inputIndex += 1
            } catch SegmentedFMP4WriterFailure.rolloverRequired {
                XCTAssertLessThanOrEqual(
                    writer.usage.retainedTerminalOwnershipCount, 384)
                let continuation = try await writer.finishWriterWindow()
                windowInputCounts.append(continuation.predecessorTerminal.inputCount)
                binding = Task17Fixtures.rolloverBinding(
                    from: binding,
                    writerIdentity: .init(rawValue: seed + 10_000
                        + UInt64(windowInputCounts.count)))
                writer = try Task17Fixtures.makeWriter(
                    seed: seed, kind: kind, writerBinding: binding,
                    sourceFormatHint: format, boundary: boundary,
                    compressedFormatConfiguration: firstUnit.formatConfiguration,
                    ownershipLimits: .init(rolloverThreshold: 160, hardCapacity: 384),
                    writerWindowContinuation: continuation,
                    releaseTransfersImmediately: true)
                try writer.start(at: .zero)
                try writer.appendCompressed(
                    unit.writerSubmission,
                    coordinator: coordinator,
                    ticket: try boundary.issueCompressedAudioAppend(
                        for: unit, writerBinding: writer.binding))
                inputIndex += 1
            }
        }
        let final = try await writer.finish()
        windowInputCounts.append(final.inputCount)
        XCTAssertEqual(windowInputCounts.count, 3)
        XCTAssertEqual(windowInputCounts.reduce(0, +), 385)
        XCTAssertTrue(windowInputCounts.allSatisfy { $0 <= 384 })
        XCTAssertEqual(writer.usage.retainedTerminalOwnershipCount, 0)
    }
}

private final class Task22GenericVideoPublicationSink: @unchecked Sendable {
    private struct Task22PublicationDiagnostic: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private enum StageFailure: Error, CustomStringConvertible {
        case mediaNotInstalled
        case timeline(Error)
        case offer(Error)
        case publish(Error)
        var description: String {
            switch self {
            case .mediaNotInstalled: "mediaNotInstalled"
            case .timeline(let error): "timeline(\(error))"
            case .offer(let error): "offer(\(error))"
            case .publish(let error): "publish(\(error))"
            }
        }
    }
    private struct ReceiveFailure: Error, CustomStringConvertible {
        let kind: SealedMediaObjectKind
        let participantID: UInt64
        let writerID: UInt64
        let underlying: Error
        var description: String {
            "receive(kind=\(kind),participant=\(participantID),writer=\(writerID)): \(underlying)"
        }
    }
    struct MediaSource {
        let participantID: UInt64
        let writerIdentity: UInt64
    }
    final class Window {
        let binding: FMP4WriterBinding
        let relay: SegmentReportRelay
        let writer: SegmentedFMP4Writer
        var initialization: SealedMediaObject?
        var proof: EpochFormatProof?
        var timeline: SegmentTimelineValidator?
        var pendingMedia: [SealedMediaObject] = []
        var installed = false
        init(binding: FMP4WriterBinding, relay: SegmentReportRelay,
             writer: SegmentedFMP4Writer) {
            self.binding = binding; self.relay = relay; self.writer = writer
        }
    }
    private let lock = NSRecursiveLock()
    private let loopbackSession: LoopbackSessionToken
    private let initialBindings: [FMP4WriterBinding]
    private let audioCodec: HLSAudioCodec
    private var windows: [Window] = []
    private var current: [UInt64: Window] = [:]
    private var storedError: Error?
    private var lastLogicalSequence: UInt64 = 0
    private var mediaSources: [HLSResourceKey: MediaSource] = [:]
    private var mediaSourceOrder: [HLSResourceKey] = []
    private var bandwidthSamples: [UInt64: [HLSBandwidthSample]] = [:]
    private(set) var store: SealedMediaStore?
    private(set) var declaration: HLSItemDeclaration?
    private(set) var publisher: HLSPublicationCoordinator?
    private(set) var maximumInstalledWindowCount = 0

    init(loopbackSession: LoopbackSessionToken,
         initialBindings: [FMP4WriterBinding], audioCodec: HLSAudioCodec) {
        self.loopbackSession = loopbackSession
        self.initialBindings = initialBindings
        self.audioCodec = audioCodec
    }

    func register(_ window: Window) {
        lock.withLock {
            precondition(windows.filter {
                $0.binding.publicationParticipantID == window.binding.publicationParticipantID
            }.count < 2)
            windows.append(window)
            maximumInstalledWindowCount = max(maximumInstalledWindowCount,
                windows.filter {
                    $0.binding.publicationParticipantID
                        == window.binding.publicationParticipantID
                }.count)
        }
    }

    func receive(_ object: SealedMediaObject, relay: SegmentReportRelay) {
        lock.withLock {
            guard storedError == nil,
                  let window = windows.first(where: {
                      $0.binding.writerIdentity == object.binding.writerIdentity
                        && $0.relay === relay
                  }) else {
                _ = relay.releaseForControl(object); return
            }
            do {
                if object.kind == .initialization {
                    window.initialization = object
                    window.proof = try FinalFMP4Validator(
                        binding: window.binding,
                        mediaType: window.writer.trackKind == .video ? .video : .audio)
                        .validateInitialization(object)
                    if publisher == nil { try installInitialIfReady() }
                    else { try installSuccessor(window) }
                } else {
                    if publisher == nil, window.initialization != nil {
                        guard window.pendingMedia.count < 8 else {
                            throw HLSPublicationFailure.capacityExceeded
                        }
                        window.pendingMedia.append(object)
                        return
                    }
                    guard let publisher, let proof = window.proof, window.installed else {
                        throw StageFailure.mediaNotInstalled
                    }
                    let timeline = window.timeline ?? SegmentTimelineValidator(
                        proof: proof, firstLogicalSequence: object.logicalSequence)
                    window.timeline = timeline
                    let receipt: SegmentValidationReceipt
                    do { receipt = try timeline.validate(object, using: proof) }
                    catch { throw StageFailure.timeline(error) }
                    lastLogicalSequence = object.logicalSequence
                    let resourceKey = HLSResourceKey(object)
                    mediaSources[resourceKey] = .init(
                        participantID: object.binding.publicationParticipantID.rawValue,
                        writerIdentity: object.binding.writerIdentity.rawValue)
                    mediaSourceOrder.append(resourceKey)
                    let offered: HLSPublicationResult
                    do {
                        offered = try publisher.offer(
                            object, receipt: receipt, relay: relay,
                            ticket: publisher.ticket,
                            now: Int64(object.logicalSequence + 1) * Task19.second)
                    } catch {
                        let boundary = try XCTUnwrap(object.publicationEvidence?.boundary)
                        let duration = receipt.presentationRange.duration
                        let samples = Array((bandwidthSamples[
                            object.binding.publicationParticipantID.rawValue] ?? []).suffix(6))
                            + [.init(bodyBytes: UInt64(object.bytes.count), duration: duration)]
                        let measured = try? HLSBandwidth.measure(samples)
                        let unit = boundary.accessUnitDuration.map {
                            "\($0.value)/\($0.timescale)"
                        } ?? "nil"
                        let bandwidth = measured.map {
                            "peak=\($0.peak),average=\($0.average)"
                        } ?? "unavailable"
                        let detail = "\(error); sequence=\(object.logicalSequence); "
                            + "actual=\(receipt.presentationRange.start.value)/"
                            + "\(receipt.presentationRange.start.timescale); "
                            + "duration=\(duration.value)/\(duration.timescale); "
                            + "common=\(boundary.commonStart.value)/"
                            + "\(boundary.commonStart.timescale); "
                            + "epoch=\(boundary.epochStart.value)/"
                            + "\(boundary.epochStart.timescale); unit=\(unit); "
                            + "bytes=\(object.bytes.count); bandwidth=\(bandwidth)"
                        throw StageFailure.offer(Task22PublicationDiagnostic(detail))
                    }
                    bandwidthSamples[object.binding.publicationParticipantID.rawValue,
                                     default: []].append(.init(
                                        bodyBytes: UInt64(object.bytes.count),
                                        duration: receipt.presentationRange.duration))
                    if bandwidthSamples[object.binding.publicationParticipantID.rawValue,
                                        default: []].count > 6 {
                        bandwidthSamples[object.binding.publicationParticipantID.rawValue]?
                            .removeFirst()
                    }
                    if case .accepted = offered {
                        do {
                            _ = try publisher.publish(
                                ticket: publisher.ticket,
                                now: Int64(object.logicalSequence + 1) * Task19.second)
                        } catch { throw StageFailure.publish(error) }
                    }
                    while mediaSourceOrder.count > 32 {
                        let visible = Set(publisher.visible?.media.values.flatMap(\.resources) ?? [])
                        guard let index = mediaSourceOrder.firstIndex(where: {
                            !visible.contains($0)
                        }) else { break }
                        let removed = mediaSourceOrder.remove(at: index)
                        mediaSources.removeValue(forKey: removed)
                    }
                }
            } catch {
                storedError = ReceiveFailure(
                    kind: object.kind,
                    participantID: object.binding.publicationParticipantID.rawValue,
                    writerID: object.binding.writerIdentity.rawValue,
                    underlying: error)
                _ = relay.releaseForControl(object)
            }
        }
    }

    private func installInitialIfReady() throws {
        let initial = try initialBindings.map { binding in
            try XCTUnwrap(windows.first { $0.binding == binding })
        }
        guard initial.allSatisfy({ $0.initialization != nil && $0.proof != nil }) else {
            return
        }
        let video = try XCTUnwrap(initial.first { $0.proof?.mediaType == .video })
        let audio = try XCTUnwrap(initial.first { $0.proof?.mediaType == .audio })
        let videoInitialization = try XCTUnwrap(video.initialization)
        let videoFormat = try XCTUnwrap(videoInitialization.publicationEvidence?.format)
        let audioInitialization = try XCTUnwrap(audio.initialization)
        let audioFormat = try XCTUnwrap(audioInitialization.publicationEvidence?.format)
        let declaration = HLSItemDeclaration(
            itemGeneration: video.binding.itemGeneration.rawValue,
            token: loopbackSession.value,
            video: .init(
                participantID: video.binding.publicationParticipantID.rawValue,
                codec: videoFormat.codec, width: videoFormat.width,
                height: videoFormat.height, frameRateMilli: 30_000,
                videoRange: videoFormat.videoRange,
                peakEnvelope: 81_600_000),
            audio: [.init(
                participantID: audio.binding.publicationParticipantID.rawValue,
                renditionID: "task22-companion", codec: audioCodec,
                channels: audioFormat.channels, language: nil, score: 100,
                peakEnvelope: 6_208_000)])
        let store = SealedMediaStore(
            loopbackSession: loopbackSession,
            itemGeneration: video.binding.itemGeneration.rawValue)
        let publisher = try HLSPublicationCoordinator(
            store: store,
            participants: try initial.map { window in .init(
                initialization: try XCTUnwrap(window.initialization),
                proof: try XCTUnwrap(window.proof),
                relay: window.relay, candidateTicket: nil) },
            declaration: declaration,
            anchor: .init(mediaOrigin: .init(value: 10, timescale: 1),
                          utcMilliseconds: 1_788_912_000_000))
        for window in initial {
            window.installed = true
            current[window.binding.publicationParticipantID.rawValue] = window
        }
        self.store = store; self.declaration = declaration; self.publisher = publisher
        for window in initial {
            let pending = window.pendingMedia
            window.pendingMedia.removeAll(keepingCapacity: true)
            for object in pending { receive(object, relay: window.relay) }
        }
    }

    private func installSuccessor(_ window: Window) throws {
        let participantID = window.binding.publicationParticipantID.rawValue
        guard let publisher, let store, let previous = current[participantID],
              let predecessorInitialization = previous.initialization,
              let predecessorProof = previous.proof,
              let successorInitialization = window.initialization,
              let successorProof = window.proof,
              let admission = window.writer.writerWindowAdmission else {
            throw HLSPublicationFailure.identityMismatch
        }
        var wrongCanonical = HLSResourceKey(predecessorInitialization)
        wrongCanonical.itemGeneration += 1
        XCTAssertFalse(store.advanceWriterWindowInitialization(
            canonicalKey: wrongCanonical,
            predecessorInitialization: predecessorInitialization,
            predecessorProof: predecessorProof,
            successorInitialization: successorInitialization,
            successorProof: successorProof,
            admission: admission, relay: window.relay))
        _ = try publisher.advanceWriterWindow(
            .init(initialization: successorInitialization, proof: successorProof,
                  relay: window.relay, candidateTicket: nil,
                  writerWindowAdmission: admission),
            admission: admission, ticket: publisher.ticket)
        window.installed = true
        current[participantID] = window
        windows.removeAll {
            $0.binding.publicationParticipantID.rawValue == participantID && $0 !== window
        }
    }

    var hasVisiblePublication: Bool { lock.withLock { publisher?.visible != nil } }
    func mediaSources(for snapshot: HLSPublishedSnapshot)
        -> [HLSResourceKey: MediaSource] {
        lock.withLock {
            let keys = Set(snapshot.media.values.flatMap(\.resources))
            return mediaSources.filter { keys.contains($0.key) }
        }
    }
    func throwIfFailed() throws { try lock.withLock { if let storedError { throw storedError } } }
    func finishPublication() throws {
        try lock.withLock {
            try throwIfFailed()
            guard let publisher else { throw HLSPublicationFailure.identityMismatch }
            _ = try publisher.publish(
                ticket: publisher.ticket,
                now: Int64(lastLogicalSequence + 2) * Task19.second,
                naturalEnd: true)
        }
    }
}

private final class Task22GenericVideoPublicationHarness: @unchecked Sendable {
    enum VideoMode: Equatable { case remux, systemVT }
    enum SystemVTCadenceMutation: CaseIterable {
        case ptsGap, ptsDuplicate, ptsBackward, duration
    }
    struct Observation {
        let snapshot: HLSPublishedSnapshot
        let mediaSources: [HLSResourceKey: Task22GenericVideoPublicationSink.MediaSource]
    }
    private let fixture: Task17Fixtures.RemuxFixture
    private let videoMode: VideoMode
    private let audioKind: SegmentedFMP4TrackKind
    private let audioCoordinator: AudioServiceSemanticCoordinator
    private let makeAudioUnit: (Int) throws -> CompressedAudioAccessUnit
    private let firstAudioUnit: CompressedAudioAccessUnit
    private var builder: HLSVideoRemuxSubmissionBuilder
    private var binding: FMP4WriterBinding
    private var audioBinding: FMP4WriterBinding
    private var writer: SegmentedFMP4Writer!
    private var audioWriter: SegmentedFMP4Writer!
    private var sink: Task22GenericVideoPublicationSink!
    private var inputIndex = 0
    private var audioInputIndex = 0
    private var pending: HLSVideoRemuxSubmission?
    private var encoder: VTVideoEncoder?
    private var pendingEncoded: HLSVideoEncodedOutput?
    private var videoPixelBuffer: CVPixelBuffer?
    private var firstHardwareProof: VTHardwareEncoderProof?
    private(set) var realVTEncodedFrameCount: UInt64 = 0
    private(set) var realVTHardwareProofWasStable = true
    private var pendingAudio: CompressedAudioAccessUnit?
    private let audioInputCount = 500
    private(set) var videoWriterWindowCount = 0
    private(set) var audioWriterWindowCount = 0
    var itemGeneration: UInt64 { binding.itemGeneration.rawValue }
    var participantID: UInt64 { binding.publicationParticipantID.rawValue }
    var audioParticipantID: UInt64 { audioBinding.publicationParticipantID.rawValue }
    var maximumInstalledWindowCount: Int { sink.maximumInstalledWindowCount }
    func decodeCoverageMap(for key: HLSResourceKey) -> SealedDecodeCoverageMap? {
        sink.store?.decodeCoverageMap(for: key)
    }
    var responseBackingBytes: Int { sink.store?.usage.responseBackingBytes ?? 0 }
    func retainResponseAlias(for key: HLSResourceKey) throws -> HLSMediaResponseLease {
        try XCTUnwrap(try sink.store?.acquireResponse(
            key, token: sink.declaration!.token, now: 0))
    }
    func releaseResponseAlias(_ lease: HLSMediaResponseLease) {
        sink.store?.release(lease, now: 0)
    }
    var observation: Observation {
        let snapshot = sink.publisher!.visible!
        return .init(snapshot: snapshot,
                     mediaSources: sink.mediaSources(for: snapshot))
    }

    func exerciseSystemVTSuccessorFirstCadenceRejection(
        _ mutation: SystemVTCadenceMutation
    ) async throws {
        try await prepareSystemVT()
        defer { encoder?.cancel() }
        let firstOutput = try await encodeSystemVTFrame(at: 0)
        let first = try Task17Fixtures.makeWriter(
            seed: 39_700, kind: .video, writerBinding: binding,
            sourceFormatHint: CMSampleBufferGetFormatDescription(firstOutput.sampleBuffer),
            boundary: fixture.boundary,
            ownershipLimits: .init(rolloverThreshold: 30, hardCapacity: 64),
            releaseTransfersImmediately: true)
        try first.start(at: CMTime(value: 10, timescale: 1))
        var precedingOutputs: [HLSVideoEncodedOutput] = []
        for index in 0..<30 {
            let output = index == 0 ? firstOutput : try await encodeSystemVTFrame(at: index)
            if index >= 28 { precedingOutputs.append(output) }
            try first.appendVideo(
                output,
                ticket: try fixture.boundary.issueVideoAppend(
                    for: output, writerBinding: first.binding))
        }
        let rollover = try await encodeSystemVTFrame(at: 30)
        XCTAssertThrowsError(try first.appendVideo(
            rollover,
            ticket: try fixture.boundary.issueVideoAppend(
                for: rollover, writerBinding: first.binding))) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .rolloverRequired)
        }
        let continuation = try await first.finishWriterWindow()
        let nextBinding = Task17Fixtures.rolloverBinding(
            from: binding, writerIdentity: .init(rawValue: 89_700))
        let next = try Task17Fixtures.makeWriter(
            seed: 39_701, kind: .video, writerBinding: nextBinding,
            sourceFormatHint: CMSampleBufferGetFormatDescription(firstOutput.sampleBuffer),
            boundary: fixture.boundary,
            ownershipLimits: .init(rolloverThreshold: 30, hardCapacity: 64),
            writerWindowContinuation: continuation,
            releaseTransfersImmediately: true)
        try next.start(at: .zero)
        let source: HLSVideoEncodedOutput
        switch mutation {
        case .ptsDuplicate:
            source = try XCTUnwrap(precedingOutputs.last)
        case .ptsBackward:
            source = try XCTUnwrap(precedingOutputs.first)
        case .ptsGap, .duration:
            source = rollover
        }
        var timing = CMSampleTimingInfo(
            duration: mutation == .duration
                ? CMTime(value: 2, timescale: 30)
                : CMSampleBufferGetDuration(source.sampleBuffer),
            presentationTimeStamp: mutation == .ptsGap
                ? CMTime(value: 332, timescale: 30)
                : CMSampleBufferGetPresentationTimeStamp(source.sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(source.sampleBuffer))
        var copied: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: source.sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copied), noErr)
        let invalid = HLSVideoEncodedOutput(
            sourceIdentity: source.sourceIdentity,
            sampleBuffer: try XCTUnwrap(copied),
            presentationOrigin: source.presentationOrigin,
            inputFormatSignature: source.inputFormatSignature,
            hardwareProof: source.hardwareProof)
        XCTAssertEqual(invalid.hardwareProof, firstOutput.hardwareProof)
        let before = fixture.boundary.usage
        if mutation == .ptsGap {
            XCTAssertThrowsError(try fixture.boundary.issueVideoAppend(
                for: invalid, writerBinding: next.binding)) {
                XCTAssertEqual($0 as? SegmentBoundaryFailure, .videoBoundaryExceeded)
            }
            XCTAssertEqual(fixture.boundary.usage, before)
            XCTAssertEqual(next.usage.retainedTerminalOwnershipCount, 0)
            _ = next.cancel()
            let receipt: HLSVideoEncoderFinishReceipt = try await withCheckedThrowingContinuation {
                continuation in encoder!.finish { continuation.resume(with: $0) }
            }
            XCTAssertEqual(receipt.hardwareProof, firstOutput.hardwareProof)
            return
        }
        let ticket = try fixture.boundary.issueVideoAppend(
            for: invalid, writerBinding: next.binding)
        XCTAssertThrowsError(try next.appendVideo(invalid, ticket: ticket)) {
            XCTAssertEqual($0 as? SegmentedFMP4WriterFailure, .sourceFormatMismatch)
        }
        XCTAssertNil(ticket.committedBoundary)
        XCTAssertEqual(fixture.boundary.usage, before)
        XCTAssertEqual(next.usage.retainedTerminalOwnershipCount, 0)
        _ = next.cancel()
        let receipt: HLSVideoEncoderFinishReceipt = try await withCheckedThrowingContinuation {
            continuation in encoder!.finish { continuation.resume(with: $0) }
        }
        XCTAssertEqual(receipt.hardwareProof, firstOutput.hardwareProof)
    }

    init(audioKind: SegmentedFMP4TrackKind, videoMode: VideoMode = .remux) throws {
        precondition(audioKind == .ac3 || audioKind == .eac3)
        // 16 秒真实输入让视频恰好在公共边界结束；短于一秒的任意 EOF 尾段
        // 由后端自然终态策略处理，不把普通 publisher 的视频下限放宽。
        let frames = (0..<480).map { index in
            Task17Fixtures.RemuxFrame(
                pts: 300_000 + Int64(index * 1_000),
                dts: 300_000 + Int64(index * 1_000), isIDR: true)
        }
        let videoFixture = try Task17Fixtures.remuxFixture(
            codec: .h264, sampleEntry: .avc1, seed: 39_700,
            frames: frames, frameDuration: CMTime(value: 1, timescale: 30),
            frameTimestampTimescale: 30_000,
            boundaryVideoMode: videoMode == .systemVT
                ? .reencodedClosedGOP : .passthrough)
        fixture = videoFixture
        self.videoMode = videoMode
        builder = videoFixture.builder
        binding = videoFixture.binding
        self.audioKind = audioKind
        audioBinding = FMP4WriterBinding(
            outputLifecycleEpoch: videoFixture.binding.outputLifecycleEpoch,
            itemGeneration: videoFixture.binding.itemGeneration,
            mediaEpoch: videoFixture.binding.mediaEpoch,
            publicationParticipantID: .init(rawValue:
                videoFixture.binding.publicationParticipantID.rawValue + 1),
            renditionIdentity: .init(rawValue:
                videoFixture.binding.renditionIdentity.rawValue + 1),
            writerIdentity: .init(rawValue:
                videoFixture.binding.writerIdentity.rawValue + 10_000))
        let owner = CompressedAudioBranchOwnerIdentity.audioVideo(
            outputLifecycleEpoch: audioBinding.outputLifecycleEpoch,
            itemGeneration: audioBinding.itemGeneration,
            mediaEpoch: audioBinding.mediaEpoch,
            publicationParticipantID: audioBinding.publicationParticipantID,
            renditionIdentity: audioBinding.renditionIdentity)
        let resolvedCoordinator: AudioServiceSemanticCoordinator
        let resolvedUnitFactory: (Int) throws -> CompressedAudioAccessUnit
        if audioKind == .ac3 {
            let harness = try Task17AC3Harness(
                seed: 39_800,
                admission: .directCompressed(
                    owner, branchGeneration: 39_810,
                    admissionFenceRevision: 39_811))
            resolvedCoordinator = harness.coordinator
            resolvedUnitFactory = { index in try harness.makeAccessUnit(
                presentationTimeStamp: CMTime(
                    value: 480_000 + Int64(index * 1_536), timescale: 48_000)) }
        } else {
            let harness = try Task17EAC3Harness(
                seed: 39_900,
                admission: .eac3Aggregation(
                    owner, branchGeneration: 39_910,
                    admissionFenceRevision: 39_911))
            resolvedCoordinator = harness.coordinator
            resolvedUnitFactory = { index in try harness.makeSixMemberAccessUnit(
                presentationBase: CMTime(
                    value: 480_000 + Int64(index * 1_536), timescale: 48_000)) }
        }
        audioCoordinator = resolvedCoordinator
        makeAudioUnit = resolvedUnitFactory
        firstAudioUnit = try resolvedUnitFactory(0)
        try videoFixture.boundary.registerAudioRendition(
            audioBinding.renditionIdentity,
            accessUnit: audioKind == .ac3
                ? .ac3(sampleRate: 48_000)
                : .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536),
            firstEffectiveStart: CMTime(value: 10, timescale: 1))
    }

    func startPublication(loopbackSession: LoopbackSessionToken) async throws
        -> LoopbackPreparedPublication {
        sink = Task22GenericVideoPublicationSink(
            loopbackSession: loopbackSession,
            initialBindings: [binding, audioBinding],
            audioCodec: audioKind == .ac3 ? .ac3 : .eac3)
        if videoMode == .systemVT {
            try await prepareSystemVT()
            pendingEncoded = try await encodeSystemVTFrame(at: inputIndex)
        }
        writer = try makeWriter(binding: binding, continuation: nil)
        audioWriter = try makeAudioWriter(binding: audioBinding, continuation: nil)
        try writer.start(at: CMTime(value: 10, timescale: 1))
        try audioWriter.start(at: CMTime(value: 10, timescale: 1))
        videoWriterWindowCount = 1
        audioWriterWindowCount = 1
        while !sink.hasVisiblePublication {
            guard inputIndex < fixture.timed.count || audioInputIndex < audioInputCount else {
                throw HLSPublicationFailure.identityMismatch
            }
            try await appendNextStreamByTime()
            try sink.throwIfFailed()
        }
        try sink.throwIfFailed()
        return LoopbackPreparedPublication(
            store: sink.store!, declaration: sink.declaration!,
            snapshot: sink.publisher!.visible!)
    }

    func finish(_ observe: (Observation) async throws -> Void) async throws {
        var seen = sink.publisher?.visible?.publicationSequence
        while inputIndex < fixture.timed.count || audioInputIndex < audioInputCount {
            try await appendNextStreamByTime()
            try sink.throwIfFailed()
            if let snapshot = sink.publisher?.visible,
               snapshot.publicationSequence != seen {
                seen = snapshot.publicationSequence
                try await observe(.init(
                    snapshot: snapshot,
                    mediaSources: sink.mediaSources(for: snapshot)))
            }
        }
        if let encoder {
            let receipt: HLSVideoEncoderFinishReceipt = try await withCheckedThrowingContinuation {
                continuation in
                encoder.finish { continuation.resume(with: $0) }
            }
            realVTEncodedFrameCount = receipt.encodedFrameCount
            realVTHardwareProofWasStable = realVTHardwareProofWasStable
                && receipt.hardwareProof == firstHardwareProof
        }
        _ = try await writer.finish()
        _ = try await audioWriter.finish()
        try sink.finishPublication()
        try sink.throwIfFailed()
        if let snapshot = sink.publisher?.visible,
           snapshot.publicationSequence != seen {
            try await observe(.init(
                snapshot: snapshot,
                mediaSources: sink.mediaSources(for: snapshot)))
        }
    }

    private func appendNext() throws {
        let submission: HLSVideoRemuxSubmission
        if let pending { submission = pending }
        else {
            submission = try builder.makeSubmission(
                for: fixture.timed[inputIndex], admission: fixture.admissions[inputIndex])
            pending = submission
        }
        try writer.appendRemuxVideo(
            submission,
            ticket: try fixture.boundary.issueRemuxVideoAppend(
                for: submission, writerBinding: writer.binding))
        pending = nil
        inputIndex += 1
    }

    private func appendNextAcrossWriterWindows() async throws {
        if videoMode == .systemVT {
            try await appendNextSystemVTAcrossWriterWindows()
            return
        }
        do {
            try appendNext()
        } catch SegmentedFMP4WriterFailure.rolloverRequired {
            let pending = try XCTUnwrap(pending,
                "rollover 后必须重送抛错前保存的同一 pending core")
            let continuation = try await writer.finishWriterWindow()
            binding = Task17Fixtures.rolloverBinding(
                from: binding,
                writerIdentity: .init(rawValue: 49_700 + UInt64(videoWriterWindowCount)))
            writer = try makeWriter(binding: binding, continuation: continuation)
            let admission = try XCTUnwrap(writer.writerWindowAdmission)
            builder = try HLSVideoRemuxSubmissionBuilder(
                resuming: builder, binding: binding, admission: admission)
            let attempt = try pending.claimWriterAttempt(
                binding: binding, admission: admission)
            try writer.start(at: .zero)
            videoWriterWindowCount += 1
            try writer.appendRemuxVideo(
                attempt,
                ticket: try fixture.boundary.issueRemuxVideoAppend(for: attempt))
            self.pending = nil
            inputIndex += 1
        }
    }

    private func appendNextSystemVTAcrossWriterWindows() async throws {
        let output: HLSVideoEncodedOutput
        if let pendingEncoded { output = pendingEncoded }
        else { output = try await encodeSystemVTFrame(at: inputIndex) }
        pendingEncoded = output
        do {
            try writer.appendVideo(
                output,
                ticket: try fixture.boundary.issueVideoAppend(
                    for: output, writerBinding: writer.binding))
        } catch SegmentedFMP4WriterFailure.rolloverRequired {
            let continuation = try await writer.finishWriterWindow()
            binding = Task17Fixtures.rolloverBinding(
                from: binding,
                writerIdentity: .init(rawValue: 49_700 + UInt64(videoWriterWindowCount)))
            writer = try makeWriter(binding: binding, continuation: continuation)
            try writer.start(at: .zero)
            videoWriterWindowCount += 1
            try writer.appendVideo(
                output,
                ticket: try fixture.boundary.issueVideoAppend(
                    for: output, writerBinding: writer.binding))
        }
        pendingEncoded = nil
        inputIndex += 1
    }

    private func prepareSystemVT() async throws {
        let format = systemVTFormat()
        let bitrate = try VTVideoBitratePolicy.freeze(
            firstTwoSecondsByteCount: 100,
            width: format.width,
            height: format.height,
            bitDepth: format.bitDepth,
            dynamicRange: format.dynamicRange)
        encoder = try VTVideoEncoder(configuration: .init(
            generation: .init(rawValue: 22_002),
            inputFormat: format,
            frameRate: try XCTUnwrap(MediaRational(num: 30, den: 1)),
            bitrate: bitrate,
            maximumPendingFrameCount: 4))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(format.width),
            Int(format.height),
            format.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        ), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Left, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferChromaLocationBottomFieldKey,
                              kCVImageBufferChromaLocation_Left, .shouldPropagate)
        videoPixelBuffer = pixelBuffer
    }

    private func encodeSystemVTFrame(at index: Int) async throws -> HLSVideoEncodedOutput {
        let encoder = try XCTUnwrap(encoder)
        let format = systemVTFormat()
        let identity = VideoEncodingFrameIdentity(
            generation: .init(rawValue: 22_002),
            accessUnitID: UInt64(index + 1),
            sequenceNumber: UInt64(index + 1))
        let frame = try VideoEncodingFrame(
            identity: identity,
            pixelBuffer: try XCTUnwrap(videoPixelBuffer),
            surfaceLease: VideoEncodingSurfaceLease {},
            presentationTimeStamp: CMTime(value: Int64(300 + index), timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            presentationOrigin: .raw,
            reliableFieldOrder: nil,
            inputFormatSignature: format)
        let output: HLSVideoEncodedOutput = try await withCheckedThrowingContinuation {
            continuation in
            encoder.encode(frame: frame) { continuation.resume(with: $0) }
        }
        if let firstHardwareProof {
            realVTHardwareProofWasStable = realVTHardwareProofWasStable
                && output.hardwareProof == firstHardwareProof
        } else {
            firstHardwareProof = output.hardwareProof
        }
        return output
    }

    private func systemVTFormat() -> VideoEncodingInputFormatSignature {
        VideoEncodingInputFormatSignature(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 1_280,
            height: 720,
            bitDepth: 8,
            range: .video,
            primaries: .bt709,
            transfer: .bt709,
            matrix: .bt709,
            cleanAperture: nil,
            sampleAspectRatio: nil,
            chromaLocation: .init(topField: "Left", bottomField: "Left"),
            masteringDisplayColorVolume: nil,
            contentLightLevelInfo: nil)
    }

    private func appendNextAudioAcrossWriterWindows() async throws {
        let unit = try pendingAudio ?? (audioInputIndex == 0
            ? firstAudioUnit : makeAudioUnit(audioInputIndex))
        pendingAudio = unit
        do {
            try audioWriter.appendCompressed(
                unit.writerSubmission, coordinator: audioCoordinator,
                ticket: try fixture.boundary.issueCompressedAudioAppend(
                    for: unit, writerBinding: audioWriter.binding))
        } catch SegmentedFMP4WriterFailure.rolloverRequired {
            let continuation = try await audioWriter.finishWriterWindow()
            audioBinding = Task17Fixtures.rolloverBinding(
                from: audioBinding,
                writerIdentity: .init(rawValue: 59_700 + UInt64(audioWriterWindowCount)))
            audioWriter = try makeAudioWriter(
                binding: audioBinding, continuation: continuation)
            try audioWriter.start(at: .zero)
            audioWriterWindowCount += 1
            try audioWriter.appendCompressed(
                unit.writerSubmission, coordinator: audioCoordinator,
                ticket: try fixture.boundary.issueCompressedAudioAppend(
                    for: unit, writerBinding: audioWriter.binding))
        }
        pendingAudio = nil
        audioInputIndex += 1
    }

    private func appendNextStreamByTime() async throws {
        if audioInputIndex >= audioInputCount {
            try await appendNextAcrossWriterWindows()
        } else if inputIndex >= fixture.timed.count {
            try await appendNextAudioAcrossWriterWindows()
        } else if 125 * inputIndex <= 120 * audioInputIndex {
            try await appendNextAcrossWriterWindows()
        } else {
            try await appendNextAudioAcrossWriterWindows()
        }
    }

    private func makeWriter(binding: FMP4WriterBinding,
                            continuation: WriterWindowContinuation?) throws
        -> SegmentedFMP4Writer {
        let holder = Task17RelayHolder()
        let relay = SegmentReportRelay(
            binding: binding, limits: .video, capacity: 8,
            objectSink: { [weak sink] object in
                guard let relay = holder.relay else { return }
                sink?.receive(object, relay: relay)
            })
        holder.relay = relay
        let writer = try SegmentedFMP4Writer(
            binding: binding, trackKind: .video,
            sourceFormatHint: videoMode == .systemVT
                ? try XCTUnwrap(pendingEncoded.flatMap {
                    CMSampleBufferGetFormatDescription($0.sampleBuffer)
                })
                : builder.formatDescription,
            boundarySession: fixture.boundary.session,
            compressedFormatConfiguration: nil,
            ownershipLimits: .init(rolloverThreshold: 192, hardCapacity: 384),
            relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(),
            writerWindowContinuation: continuation)
        sink.register(.init(binding: binding, relay: relay, writer: writer))
        return writer
    }

    private func makeAudioWriter(binding: FMP4WriterBinding,
                                 continuation: WriterWindowContinuation?) throws
        -> SegmentedFMP4Writer {
        let holder = Task17RelayHolder()
        let relay = SegmentReportRelay(
            binding: binding, limits: .audio, capacity: 8,
            objectSink: { [weak sink] object in
                guard let relay = holder.relay else { return }
                sink?.receive(object, relay: relay)
            })
        holder.relay = relay
        let writer = try SegmentedFMP4Writer(
            binding: binding, trackKind: audioKind,
            sourceFormatHint: Task17Fixtures.compressedAudioFormat(for: firstAudioUnit),
            boundarySession: fixture.boundary.session,
            compressedFormatConfiguration: firstAudioUnit.formatConfiguration,
            ownershipLimits: .init(rolloverThreshold: 192, hardCapacity: 384),
            relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(),
            writerWindowContinuation: continuation)
        sink.register(.init(binding: binding, relay: relay, writer: writer))
        return writer
    }
}

private final class Task22LongPublicationSink: @unchecked Sendable {
    private final class Window {
        let binding: FMP4WriterBinding
        let relay: SegmentReportRelay
        let writer: SegmentedFMP4Writer
        var initialization: SealedMediaObject?
        var proof: EpochFormatProof?
        var timeline: SegmentTimelineValidator?
        var installed = false

        init(binding: FMP4WriterBinding, relay: SegmentReportRelay,
             writer: SegmentedFMP4Writer) {
            self.binding = binding
            self.relay = relay
            self.writer = writer
        }
    }

    private let lock = NSRecursiveLock()
    private let initialBinding: FMP4WriterBinding
    private var windows: [UInt64: Window] = [:]
    private var storedError: Error?
    private var candidate: HLSAudioCandidateRegistration?
    private var pendingLoopbackSession: LoopbackSessionToken?
    private var lastLogicalSequence: UInt64 = 0
    private var currentWindow: Window?
    private var probedInitializationBridgeFailures = false
    private(set) var store: SealedMediaStore?
    private(set) var declaration: HLSItemDeclaration?
    private(set) var publisher: HLSPublicationCoordinator?

    init(initialBinding: FMP4WriterBinding) {
        self.initialBinding = initialBinding
    }

    func register(binding: FMP4WriterBinding, relay: SegmentReportRelay,
                  writer: SegmentedFMP4Writer) {
        lock.withLock {
            precondition(windows[binding.writerIdentity.rawValue] == nil)
            windows[binding.writerIdentity.rawValue] = Window(
                binding: binding, relay: relay, writer: writer)
        }
    }

    func receive(_ object: SealedMediaObject, relay: SegmentReportRelay) {
        lock.withLock {
            guard storedError == nil,
                  let window = windows[object.binding.writerIdentity.rawValue],
                  window.relay === relay else {
                _ = relay.releaseForControl(object)
                return
            }
            do {
                switch object.kind {
                case .initialization:
                    guard window.initialization == nil else {
                        throw HLSPublicationFailure.identityMismatch
                    }
                    window.initialization = object
                    window.proof = try FinalFMP4Validator(
                        binding: window.binding, mediaType: .audio)
                        .validateInitialization(object)
                    if window.binding == initialBinding {
                        if let pendingLoopbackSession, publisher == nil {
                            try activateLocked(loopbackSession: pendingLoopbackSession)
                        }
                    }
                    if publisher != nil, window.binding != initialBinding {
                        try installSuccessor(window)
                    }
                case .media:
                    guard let publisher, let proof = window.proof, window.installed else {
                        throw HLSPublicationFailure.identityMismatch
                    }
                    let timeline = window.timeline ?? SegmentTimelineValidator(
                        proof: proof, firstLogicalSequence: object.logicalSequence)
                    window.timeline = timeline
                    let receipt = try timeline.validate(object, using: proof)
                    lastLogicalSequence = object.logicalSequence
                    let result = try publisher.offer(
                        object, receipt: receipt, relay: relay,
                        ticket: publisher.ticket,
                        now: Int64(object.logicalSequence + 1) * Task19.second)
                    if case .accepted = result {
                        _ = try publisher.publish(
                            ticket: publisher.ticket,
                            now: Int64(object.logicalSequence + 1) * Task19.second)
                    }
                }
            } catch {
                storedError = error
                _ = relay.releaseForControl(object)
            }
        }
    }

    func activate(loopbackSession: LoopbackSessionToken) throws {
        try lock.withLock {
            try throwIfFailedLocked()
            guard publisher == nil else { throw HLSPublicationFailure.identityMismatch }
            pendingLoopbackSession = loopbackSession
            if windows[initialBinding.writerIdentity.rawValue]?.initialization != nil {
                try activateLocked(loopbackSession: loopbackSession)
            }
        }
    }

    var hasVisiblePublication: Bool {
        lock.withLock { publisher?.visible != nil }
    }

    private func activateLocked(loopbackSession: LoopbackSessionToken) throws {
            guard publisher == nil,
                  let initial = windows[initialBinding.writerIdentity.rawValue],
                  let initialization = initial.initialization,
                  let proof = initial.proof,
                  let terminal = initial.writer.aacTerminalBinding,
                  let rendition = initial.writer.aacRenditionTerminalBinding else {
                throw HLSPublicationFailure.identityMismatch
            }
            let store = SealedMediaStore(
                loopbackSession: loopbackSession, itemGeneration: 19)
            var declaration = try Task19.declaration(audioOnly: true)
            declaration.token = loopbackSession.value
            let candidate = try store.registerAudioCandidate(
                initialization: initialization, proof: proof,
                declaration: declaration)
            let publisher = try HLSPublicationCoordinator(
                store: store,
                participants: [.init(
                    initialization: initialization, proof: proof,
                    relay: initial.relay, candidateTicket: candidate.ticket,
                    candidate: candidate, aacTerminalBinding: terminal,
                    aacRenditionBinding: rendition)],
                declaration: declaration,
                anchor: .init(mediaOrigin: .init(value: 10, timescale: 1),
                              utcMilliseconds: 1_788_912_000_000))
            initial.installed = true
            currentWindow = initial
            self.store = store
            self.declaration = declaration
            self.candidate = candidate
            self.publisher = publisher
            pendingLoopbackSession = nil
    }

    func finishPublication() throws {
        try lock.withLock {
            try throwIfFailedLocked()
            guard let publisher else { throw HLSPublicationFailure.identityMismatch }
            XCTAssertEqual(try publisher.publish(
                ticket: publisher.ticket,
                now: Int64(lastLogicalSequence + 2) * Task19.second,
                naturalEnd: true), .published)
            try throwIfFailedLocked()
        }
    }

    func throwIfFailed() throws { try lock.withLock { try throwIfFailedLocked() } }

    private func installSuccessor(_ window: Window) throws {
        guard let publisher, let candidate, let store, let previous = currentWindow,
              let predecessorInitialization = previous.initialization,
              let predecessorProof = previous.proof,
              let initialization = window.initialization,
              let proof = window.proof,
              let terminal = window.writer.aacTerminalBinding,
              let rendition = window.writer.aacRenditionTerminalBinding,
              let admission = window.writer.aacWriterWindowAdmission else {
            throw HLSPublicationFailure.identityMismatch
        }
        if !probedInitializationBridgeFailures {
            var crossLifecycleKey = HLSResourceKey(predecessorInitialization)
            crossLifecycleKey.itemGeneration += 1
            XCTAssertFalse(store.advanceAACWriterWindowInitialization(
                canonicalKey: crossLifecycleKey,
                predecessorInitialization: predecessorInitialization,
                predecessorProof: predecessorProof,
                successorInitialization: initialization,
                successorProof: proof, admission: admission,
                relay: window.relay, terminalBinding: terminal,
                renditionBinding: rendition),
                "跨lifecycle canonical key不能进入window init桥")
            XCTAssertFalse(store.advanceAACWriterWindowInitialization(
                canonicalKey: HLSResourceKey(predecessorInitialization),
                predecessorInitialization: initialization,
                predecessorProof: predecessorProof,
                successorInitialization: initialization,
                successorProof: proof, admission: admission,
                relay: window.relay, terminalBinding: terminal,
                renditionBinding: rendition),
                "错误predecessor init不能消耗或签发window init桥")
            probedInitializationBridgeFailures = true
        }
        _ = try publisher.advanceAACWriterWindow(
            .init(initialization: initialization, proof: proof,
                  relay: window.relay, candidateTicket: candidate.ticket,
                  candidate: candidate, aacTerminalBinding: terminal,
                  aacRenditionBinding: rendition,
                  aacWriterWindowAdmission: admission),
            admission: admission, ticket: publisher.ticket)
        window.installed = true
        currentWindow = window
    }

    private func throwIfFailedLocked() throws {
        if let storedError { throw storedError }
    }
}

private final class Task22LongRenditionHarness: @unchecked Sendable {
    let encoder: AACRenditionEncoder
    let branch: AudioRenditionBranch
    let renditionBinding: AACRenditionTerminalBinding
    private let boundary: SegmentBoundaryCoordinator
    private let format: CMFormatDescription
    private let initialBinding: FMP4WriterBinding
    private let identityCounter = Task17LockedUInt64(32_100)
    private let sink: Task22LongPublicationSink
    private var pcmInputCount = 0

    var publisher: HLSPublicationCoordinator { sink.publisher! }
    var declaration: HLSItemDeclaration { sink.declaration! }
    var itemIdentity: AVPlayerItemInstanceIdentity {
        .init(outputLifecycleEpoch: initialBinding.outputLifecycleEpoch,
              itemGeneration: initialBinding.itemGeneration.rawValue)
    }

    static func make() async throws -> Task22LongRenditionHarness {
        let calibration = try await AACPrimingCalibrator().calibrate(plan:
            AACCalibrationPlan.build([try AACRenditionRequest(
                layout: RenditionAudioLayout(labels: [.l, .r]),
                capabilityVersion: "task22-b-385-emissions")]))
        return try Task22LongRenditionHarness(
            encoder: XCTUnwrap(calibration.encoders.first))
    }

    private init(encoder: AACRenditionEncoder) throws {
        self.encoder = encoder
        format = try encoder.incrementalFormatDescription()
        boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1)))
        initialBinding = Task19.binding(id: 2, epoch: 1, writer: 32_000, item: 19)
        sink = Task22LongPublicationSink(initialBinding: initialBinding)
        try boundary.registerAudioRendition(
            initialBinding.renditionIdentity,
            accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: CMTime(value: 10, timescale: 1))
        let first = try Self.makeWriter(
            binding: initialBinding, format: format, boundary: boundary,
            sink: sink, continuation: nil)
        try first.start(at: CMTime(value: 10, timescale: 1))
        let boundaryHolder = Task17BoundaryHolder(boundary)
        branch = AudioRenditionBranch(
            encoder: encoder, writer: first, coordinator: boundary,
            writerWindowFactory: { [weak sink, boundaryHolder, format, initialBinding,
                                    identityCounter] continuation in
                guard let sink else { throw AACRenditionFailure.cancelled }
                let binding = Task17Fixtures.rolloverBinding(
                    from: initialBinding,
                    writerIdentity: .init(rawValue: identityCounter.take()))
                return try Self.makeWriter(
                    binding: binding, format: format, boundary: boundaryHolder.value,
                    sink: sink, continuation: continuation)
            })
        renditionBinding = branch.renditionTerminalBinding
    }

    func startPublication(loopbackSession: LoopbackSessionToken) async throws
        -> LoopbackPreparedPublication {
        // server 构造闭包必须返回一个已发布的真实 prefix；继续使用同一 branch，
        // 不提前 EOS，也不构造诊断 snapshot。
        // factory 先签发真实 session；首个 init callback 在同一 sink 内创建 owner，
        // 后续 media 因而直接进入 publisher，不在 relay 外缓存 ownership。
        try sink.activate(loopbackSession: loopbackSession)
        for _ in 0..<1_000 where !sink.hasVisiblePublication {
            try await pumpPrefixPCM()
        }
        return LoopbackPreparedPublication(
            store: try XCTUnwrap(sink.store),
            declaration: try XCTUnwrap(sink.declaration),
            snapshot: try XCTUnwrap(sink.publisher?.visible))
    }

    func finishStream(
        totalPCMInputs: Int,
        onPublication: (HLSPublishedSnapshot) async throws -> Void = { _ in }
    ) async throws -> AACEncoderFinalReceipt {
        var observedPublication = publisher.visible?.publicationSequence
        while pcmInputCount < totalPCMInputs {
            try await pumpPCM()
            if let snapshot = publisher.visible,
               snapshot.publicationSequence != observedPublication {
                observedPublication = snapshot.publicationSequence
                try await onPublication(snapshot)
            }
        }
        var terminal = try branch.pump(.endOfStream)
        if terminal.waitingForWriter {
            let retried = try await branch.retryPendingAcrossWriterWindow()
            terminal = try XCTUnwrap(retried)
        }
        if let snapshot = publisher.visible,
           snapshot.publicationSequence != observedPublication {
            try await onPublication(snapshot)
        }
        try sink.throwIfFailed()
        return try XCTUnwrap(terminal.finalReceipt)
    }

    func finishPublication() throws { try sink.finishPublication() }
    private func pumpPCM() async throws {
        let batch = pcmInputCount
        let samples = (0..<(1_024 * 2)).map {
            sin(Float(batch * 2_048 + $0) * 0.002875) * 0.25
        }
        var result = try branch.pump(.pcm(samples))
        XCTAssertFalse(result.waitingForEncoderBudget)
        if result.waitingForWriter {
            let retried = try await branch.retryPendingAcrossWriterWindow()
            result = try XCTUnwrap(retried)
        }
        XCTAssertFalse(result.waitingForWriter)
        pcmInputCount += 1
        try sink.throwIfFailed()
    }

    private func pumpPrefixPCM() async throws {
        let batch = pcmInputCount
        let samples = (0..<(1_024 * 2)).map {
            sin(Float(batch * 2_048 + $0) * 0.002875) * 0.25
        }
        var result = try branch.pump(.pcm(samples))
        guard !result.waitingForEncoderBudget else {
            throw AACRenditionFailure.capacityExceeded
        }
        if result.waitingForWriter {
            let retried = try await branch.retryPendingAcrossWriterWindow()
            result = try XCTUnwrap(retried)
        }
        pcmInputCount += 1
        try sink.throwIfFailed()
    }

    private static func makeWriter(
        binding: FMP4WriterBinding, format: CMFormatDescription,
        boundary: SegmentBoundaryCoordinator, sink: Task22LongPublicationSink,
        continuation: AACWriterWindowContinuation?
    ) throws -> SegmentedFMP4Writer {
        let holder = Task17RelayHolder()
        let relay = SegmentReportRelay(
            binding: binding, limits: .audio, capacity: 8,
            objectSink: { [weak sink] object in
                guard let relay = holder.relay else { return }
                sink?.receive(object, relay: relay)
            })
        holder.relay = relay
        let writer = try SegmentedFMP4Writer(
            binding: binding, trackKind: .aac, sourceFormatHint: format,
            boundarySession: boundary.session,
            compressedFormatConfiguration: nil, relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(),
            aacContinuation: continuation)
        sink.register(binding: binding, relay: relay, writer: writer)
        return writer
    }
}

private final class Task17LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func setTrue() { lock.withLock { storage = true } }
}

private final class Task17LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

private final class Task22AttemptIdentityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObjectIdentifier] = []
    var values: [ObjectIdentifier] { lock.withLock { storage } }
    func append(_ value: ObjectIdentifier) { lock.withLock { storage.append(value) } }
}

private final class Task17LockedUInt64: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func take() -> UInt64 { lock.withLock { defer { value += 1 }; return value } }
}

private final class Task17BoundaryHolder: @unchecked Sendable {
    let value: SegmentBoundaryCoordinator
    init(_ value: SegmentBoundaryCoordinator) { self.value = value }
}

private final class Task17RelayHolder: @unchecked Sendable {
    weak var relay: SegmentReportRelay?
}

private final class Task17ObjectCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedObjects: [SealedMediaObject] = []
    var objects: [SealedMediaObject] { lock.withLock { storedObjects } }
    func append(_ object: SealedMediaObject) { lock.withLock { storedObjects.append(object) } }
}

private final class Task22TransferReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let received = DispatchSemaphore(value: 0)
    private weak var relay: SegmentReportRelay?
    private var objects: [SealedMediaObject] = []

    func install(relay: SegmentReportRelay) {
        lock.withLock { self.relay = relay }
    }

    func receive(_ object: SealedMediaObject) {
        lock.withLock { objects.append(object) }
        received.signal()
    }

    func waitForObjectCount(_ count: Int) -> Bool {
        for _ in 0..<count where received.wait(timeout: .now() + 5) != .success {
            return false
        }
        return true
    }

    func releaseAll() {
        let pair = lock.withLock { () -> (SegmentReportRelay?, [SealedMediaObject]) in
            defer { objects.removeAll(keepingCapacity: false) }
            return (relay, objects)
        }
        guard let relay = pair.0 else { return }
        for object in pair.1 { _ = relay.releaseForControl(object) }
    }
}

private final class Task17DeferredPublicationScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (@Sendable () -> Void)?

    func schedule(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { self.body = body }
    }

    func runTwice() {
        let value = lock.withLock { body }
        value?()
        value?()
    }
}

private final class Task17ReentrantPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let published = DispatchSemaphore(value: 0)
    weak var writer: SegmentedFMP4Writer?
    private var storedReceipt: SegmentedFMP4WriterTerminalReceipt?

    var receipt: SegmentedFMP4WriterTerminalReceipt? { lock.withLock { storedReceipt } }

    func receive(_ object: SealedMediaObject) {
        guard object.kind == .media, let writer else { return }
        let value = writer.cancel()
        lock.withLock { storedReceipt = value }
        published.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult { published.wait(timeout: timeout) }
}

private final class Task17LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<AACEffectiveEndpointReceipt, Error>] = []

    var successCount: Int {
        lock.withLock {
            values.reduce(into: 0) { count, value in
                if case .success = value { count += 1 }
            }
        }
    }

    var firstSuccess: AACEffectiveEndpointReceipt? {
        lock.withLock { values.compactMap { try? $0.get() }.first }
    }

    func append(_ value: Result<AACEffectiveEndpointReceipt, Error>) {
        lock.withLock { values.append(value) }
    }
}

private enum Task17SystemFailurePoint: Equatable {
    case start
    case readiness
    case append
    case flush
    case finish
}

private enum Task17SystemCall: Equatable {
    case start
    case append
    case flush
    case markFinished
    case finish
    case cancel
}

private final class Task17WeakCallbackSink: @unchecked Sendable {
    weak var value: (any SegmentedFMP4SystemCallbackSink)?
    init(_ value: any SegmentedFMP4SystemCallbackSink) { self.value = value }
}

private final class Task17WeakSystemWriter: @unchecked Sendable {
    weak var value: Task17FakeSystemWriter?
    init(_ value: Task17FakeSystemWriter) { self.value = value }
}

private final class Task17BoundaryRegistry: @unchecked Sendable {
    static let shared = Task17BoundaryRegistry()
    private let lock = NSLock()
    private var values: [FMP4WriterIdentity: SegmentBoundaryCoordinator] = [:]

    func install(_ boundary: SegmentBoundaryCoordinator, for writer: FMP4WriterIdentity) {
        lock.withLock { values[writer] = boundary }
    }

    func boundary(for writer: FMP4WriterIdentity) -> SegmentBoundaryCoordinator? {
        lock.withLock { values[writer] }
    }
}

private final class Task17ForeignSystemWriterIdentity: @unchecked Sendable {
    static let shared = Task17ForeignSystemWriterIdentity()
    private init() {}
}

private final class Task17FakeSystemWriterFactory: SegmentedFMP4SystemWriterFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let failurePoint: Task17SystemFailurePoint?
    private let defersFinish: Bool
    private let defersMediaCallback: Bool
    private let defersInitializationCallback: Bool
    private let blocksAppend: Bool
    private let blocksCancel: Bool
    private let rejectAppendOrdinal: Int?
    private let mediaPayloadByteCount: Int?
    private let mediaWrittenStart: CMTime?
    private var storedConfigurations: [SegmentedFMP4SystemConfiguration] = []
    private var storedWriters: [Task17WeakSystemWriter] = []
    private var storedSinks: [Task17WeakCallbackSink] = []

    init(
        failurePoint: Task17SystemFailurePoint? = nil,
        defersFinish: Bool = false,
        defersMediaCallback: Bool = false,
        defersInitializationCallback: Bool = false,
        blocksAppend: Bool = false,
        blocksCancel: Bool = false,
        rejectAppendOrdinal: Int? = nil,
        mediaPayloadByteCount: Int? = nil,
        mediaWrittenStart: CMTime? = nil
    ) {
        self.failurePoint = failurePoint
        self.defersFinish = defersFinish
        self.defersMediaCallback = defersMediaCallback
        self.defersInitializationCallback = defersInitializationCallback
        self.blocksAppend = blocksAppend
        self.blocksCancel = blocksCancel
        self.rejectAppendOrdinal = rejectAppendOrdinal
        self.mediaPayloadByteCount = mediaPayloadByteCount
        self.mediaWrittenStart = mediaWrittenStart
    }

    var configurations: [SegmentedFMP4SystemConfiguration] {
        lock.withLock { storedConfigurations }
    }

    var systemWriterIdentities: [ObjectIdentifier] {
        lock.withLock { storedWriters.compactMap(\.value).map { ObjectIdentifier($0) } }
    }

    var delegateObjectIdentifiers: [ObjectIdentifier?] {
        lock.withLock { storedSinks.map { $0.value.map(ObjectIdentifier.init) } }
    }

    var lastWriter: Task17FakeSystemWriter? {
        lock.withLock { storedWriters.last?.value }
    }

    func makeWriter(
        configuration: SegmentedFMP4SystemConfiguration,
        sourceFormatHint: CMFormatDescription,
        callbackSink: any SegmentedFMP4SystemCallbackSink
    ) throws -> any SegmentedFMP4SystemWriting {
        let writer = Task17FakeSystemWriter(
            failurePoint: failurePoint,
            defersFinish: defersFinish,
            defersMediaCallback: defersMediaCallback,
            defersInitializationCallback: defersInitializationCallback,
            blocksAppend: blocksAppend,
            blocksCancel: blocksCancel,
            rejectAppendOrdinal: rejectAppendOrdinal,
            mediaPayloadByteCount: mediaPayloadByteCount,
            mediaWrittenStart: mediaWrittenStart,
            callbackSink: callbackSink
        )
        lock.withLock {
            storedConfigurations.append(configuration)
            storedWriters.append(Task17WeakSystemWriter(writer))
            storedSinks.append(Task17WeakCallbackSink(callbackSink))
        }
        return writer
    }
}

private final class Task17FakeSystemWriter: SegmentedFMP4SystemWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let failurePoint: Task17SystemFailurePoint?
    private let defersFinish: Bool
    private let defersMediaCallback: Bool
    private let defersInitializationCallback: Bool
    private let blocksAppend: Bool
    private let blocksCancel: Bool
    private let rejectAppendOrdinal: Int?
    private let mediaPayloadByteCount: Int?
    private let mediaWrittenStart: CMTime?
    private weak var callbackSink: (any SegmentedFMP4SystemCallbackSink)?
    private var deferredMediaCount = 0
    private var initializationIsDeferred = false
    private let finishRequested = DispatchSemaphore(value: 0)
    private let appendEntered = DispatchSemaphore(value: 0)
    private let appendRelease = DispatchSemaphore(value: 0)
    private let cancelEntered = DispatchSemaphore(value: 0)
    private let cancelRelease = DispatchSemaphore(value: 0)
    private var finishCompletion: (@Sendable (Bool) -> Void)?
    private var storedCalls: [Task17SystemCall] = []
    private var storedAppendCount = 0
    private var storedCapturedPayloads: [Data] = []
    private var rejectsNextAppend = false
    private var readyForMoreMediaData = true

    init(
        failurePoint: Task17SystemFailurePoint?,
        defersFinish: Bool,
        defersMediaCallback: Bool,
        defersInitializationCallback: Bool,
        blocksAppend: Bool,
        blocksCancel: Bool,
        rejectAppendOrdinal: Int?,
        mediaPayloadByteCount: Int?,
        mediaWrittenStart: CMTime?,
        callbackSink: any SegmentedFMP4SystemCallbackSink
    ) {
        self.failurePoint = failurePoint
        self.defersFinish = defersFinish
        self.defersMediaCallback = defersMediaCallback
        self.defersInitializationCallback = defersInitializationCallback
        self.blocksAppend = blocksAppend
        self.blocksCancel = blocksCancel
        self.rejectAppendOrdinal = rejectAppendOrdinal
        self.mediaPayloadByteCount = mediaPayloadByteCount
        self.mediaWrittenStart = mediaWrittenStart
        self.callbackSink = callbackSink
    }

    var objectIdentity: ObjectIdentifier { ObjectIdentifier(self) }
    var isReadyForMoreMediaData: Bool {
        lock.withLock { failurePoint != .readiness && readyForMoreMediaData }
    }
    var calls: [Task17SystemCall] { lock.withLock { storedCalls } }
    var appendCount: Int { lock.withLock { storedAppendCount } }
    var capturedPayloads: [Data] { lock.withLock { storedCapturedPayloads } }
    var cancelCount: Int { calls.filter { $0 == .cancel }.count }
    var isTerminal: Bool { cancelCount > 0 || calls.contains(.finish) }

    func startWriting(at sourceTime: CMTime) -> Bool {
        lock.withLock { storedCalls.append(.start) }
        guard failurePoint != .start else { return false }
        if defersInitializationCallback {
            lock.withLock { initializationIsDeferred = true }
        } else {
            emitInitialization()
        }
        return true
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(block)
            var copy = Data(count: length)
            let status = copy.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: $0.baseAddress!
                )
            }
            if status == noErr { lock.withLock { storedCapturedPayloads.append(copy) } }
        }
        let rejects = lock.withLock { () -> Bool in
            storedCalls.append(.append)
            storedAppendCount += 1
            defer { rejectsNextAppend = false }
            return rejectsNextAppend || storedAppendCount == rejectAppendOrdinal
        }
        if blocksAppend {
            appendEntered.signal()
            _ = appendRelease.wait(timeout: .now() + 2)
        }
        return failurePoint != .append && !rejects
    }

    func rejectNextAppend() { lock.withLock { rejectsNextAppend = true } }
    func setReadyForMoreMediaData(_ ready: Bool) {
        lock.withLock { readyForMoreMediaData = ready }
    }

    func flushSegment() -> Bool {
        lock.withLock { storedCalls.append(.flush) }
        guard failurePoint != .flush else { return false }
        emitOrDeferMedia()
        return true
    }

    func markInputAsFinished() {
        lock.withLock { storedCalls.append(.markFinished) }
    }

    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { storedCalls.append(.finish) }
        emitOrDeferMedia()
        if defersFinish {
            lock.withLock { finishCompletion = completion }
            finishRequested.signal()
        } else {
            completion(failurePoint != .finish)
        }
    }

    func cancelWriting() {
        lock.withLock { storedCalls.append(.cancel) }
        if blocksCancel {
            cancelEntered.signal()
            _ = cancelRelease.wait(timeout: .now() + 2)
        }
    }

    func completeFinish(success: Bool) {
        let completion = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            defer { finishCompletion = nil }
            return finishCompletion
        }
        completion?(success)
    }

    func waitUntilFinishRequested(timeout: DispatchTime) -> DispatchTimeoutResult {
        finishRequested.wait(timeout: timeout)
    }

    func waitUntilAppendEntered(timeout: DispatchTime) -> DispatchTimeoutResult {
        appendEntered.wait(timeout: timeout)
    }

    func releaseBlockedAppend() {
        appendRelease.signal()
    }

    func waitUntilCancelEntered(timeout: DispatchTime) -> DispatchTimeoutResult {
        cancelEntered.wait(timeout: timeout)
    }

    func releaseBlockedCancel() {
        cancelRelease.signal()
    }

    func emitDeferredInitializationCallback() {
        let shouldEmit = lock.withLock { () -> Bool in
            defer { initializationIsDeferred = false }
            return initializationIsDeferred
        }
        if shouldEmit { emitInitialization() }
    }

    func emitDeferredMediaCallbacks() {
        let count = lock.withLock { () -> Int in
            defer { deferredMediaCount = 0 }
            return deferredMediaCount
        }
        for _ in 0..<count { emitMedia() }
    }

    private func emitOrDeferMedia() {
        if defersMediaCallback {
            lock.withLock { deferredMediaCount += 1 }
        } else {
            emitMedia()
        }
    }

    func emitMedia(
        bytes: Data? = nil,
        writerObjectIdentity: ObjectIdentifier? = nil
    ) {
        let defaultBytes = Data([0, 0, 0, 8]) + Data("moof".utf8)
            + Data([0, 0, 0, 8]) + Data("mdat".utf8)
        let resolved: Data
        if let bytes {
            resolved = bytes
        } else if let mediaPayloadByteCount {
            resolved = Data(repeating: 0x5a, count: mediaPayloadByteCount)
        } else {
            resolved = defaultBytes
        }
        callbackSink?.receiveSystemSegment(
            writerObjectIdentity: writerObjectIdentity ?? objectIdentity,
            bytes: resolved,
            type: .separable,
            report: .init(
                systemReport: nil,
                earliestPresentationTimeStamp: mediaWrittenStart
            )
        )
    }

    private func emitInitialization() {
        callbackSink?.receiveSystemSegment(
            writerObjectIdentity: objectIdentity,
            bytes: Data([0, 0, 0, 8]) + Data("ftyp".utf8) + Data([0, 0, 0, 8]) + Data("moov".utf8),
            type: .initialization,
            report: .init(systemReport: nil, earliestPresentationTimeStamp: nil)
        )
    }
}

private enum Task17Fixtures {
    struct WindowPredecessor {
        let encoder: AACRenditionEncoder
        let binding: FMP4WriterBinding
        let format: CMFormatDescription
        let boundary: SegmentBoundaryCoordinator
        let continuation: AACWriterWindowContinuation
        let pending: [AACIncrementalEmission]
    }

    struct VideoFixture {
        let format: CMFormatDescription
        let sample: CMSampleBuffer
    }

    struct RemuxFrame {
        let pts: Int64
        let dts: Int64
        let isIDR: Bool
    }

    struct RemuxFixture {
        let binding: FMP4WriterBinding
        let boundary: SegmentBoundaryCoordinator
        let builder: HLSVideoRemuxSubmissionBuilder
        let timed: [HLSTimedVideoAccessUnit]
        let admissions: [VideoRemuxAdmissionProof]
    }

    static func remuxFixture(
        codec: VideoCodec,
        sampleEntry: HLSVideoSampleEntry,
        seed: UInt64,
        frames: [RemuxFrame] = [.init(pts: 7_000, dts: 6_999, isIDR: true)],
        frameDuration: CMTime = CMTime(value: 1, timescale: 30),
        frameTimestampTimescale: CMTimeScale = 1_000,
        parameterSetsOverride: [Data]? = nil,
        inBandParameterSetsOverride: [Data]? = nil,
        includeHDRMetadata: Bool = true,
        applicationLedger: HLSDeliveryApplicationChargeLedger = .shared,
        boundaryVideoMode: SegmentVideoBoundaryMode = .passthrough
    ) throws -> RemuxFixture {
        precondition(frames.first?.isIDR == true)
        let parameterSets: [Data]
        let metadataNALUnits: [Data]
        let idr: Data
        let nonIDR: Data
        switch codec {
        case .h264:
            parameterSets = parameterSetsOverride
                ?? [AssemblerTestFixtures.h264SPS, AssemblerTestFixtures.h264PPS]
            idr = Data([0x65, 0xB8])
            nonIDR = Data([0x61, 0xE0])
            metadataNALUnits = []
        case .hevc:
            parameterSets = parameterSetsOverride ?? task22HEVCParameterSets()
            idr = Data([0x26, 0x01, 0xA0])
            nonIDR = Data([0x02, 0x01, 0xC0])
            metadataNALUnits = includeHDRMetadata ? [task22HEVCHDRSEI()] : []
        }
        let dimensions = try parameterSetDimensions(codec: codec, parameterSets: parameterSets)
        let track = VideoTrackDescriptor(
            streamIndex: 7,
            codec: codec,
            // 30 kHz 同时精确表示毫秒输入时间与 1/30 秒帧长。
            timeBase: MediaRational(num: 1, den: 30_000)!,
            width: dimensions.width,
            height: dimensions.height,
            videoDelay: 1,
            extradata: annexB(parameterSets),
            frameRate: MediaRational(num: 30, den: 1),
            fieldOrder: .progressive
        )
        let parser = ScriptedFFmpegParserFactory { handle, index, bytes, pts, dts, _ in
            try handle.emit(FFmpegParsedFrame(
                bytes: bytes,
                pts: pts,
                dts: dts,
                duration: frameDuration,
                fieldOrder: Int32(CodedFieldOrder.progressive.rawValue),
                pictureStructure: Int32(PictureStructure.frame.rawValue),
                keyFrame: index >= 7 ? frames[index - 7].isIDR : false,
                repeatPicture: false,
                topFieldFirst: nil,
                interlaced: false,
                sampleRate: 0,
                channels: 0,
                frameSamples: 0,
                channelLayout: nil
            ))
        }
        let timeline = HLSTimelineCoordinator(parserFactory: parser)
        _ = try timeline.consume(.tracks(DemuxTrackSet(
            selectedProgramID: 1, video: track, audio: nil
        )))
        for index in 0..<7 {
            _ = try timeline.consume(.packet(DemuxPacket(
                streamIndex: 7,
                codec: .video(codec),
                data: annexB([nonIDR]),
                presentationTimeStamp: CMTime(value: Int64(index) * 1_000, timescale: 1_000),
                decodeTimeStamp: CMTime(value: Int64(index) * 1_000, timescale: 1_000),
                duration: frameDuration,
                isKey: false,
                isCorrupt: false
            )))
        }
        var timed: [HLSTimedVideoAccessUnit] = []
        for frame in frames {
            let nals = frame.isIDR
                ? (inBandParameterSetsOverride ?? parameterSets) + metadataNALUnits + [idr]
                : [nonIDR]
            let output = try timeline.consume(.packet(DemuxPacket(
                streamIndex: 7,
                codec: .video(codec),
                data: annexB(nals),
                presentationTimeStamp: CMTime(
                    value: frame.pts, timescale: frameTimestampTimescale),
                decodeTimeStamp: CMTime(
                    value: frame.dts, timescale: frameTimestampTimescale),
                duration: frameDuration,
                isKey: frame.isIDR,
                isCorrupt: false
            )))
            timed.append(contentsOf: output.compactMap {
                if case let .videoSample(value) = $0 { value } else { nil }
            })
        }
        XCTAssertEqual(timed.count, frames.count)

        var inspection = VideoAccessUnitInspectionSession(
            generation: MediaGeneration(rawValue: 0), codec: codec
        )
        let proofs = try timed.map { value in
            let backing = try XCTUnwrap(value.source.sourceBacking)
            let range = try XCTUnwrap(value.source.sourceByteRange)
            return try inspection.inspect(VideoAccessUnitInspectionInput(
                backing: backing,
                byteRange: range,
                sourceSHA256: try XCTUnwrap(value.source.sourceSHA256),
                codec: codec,
                scanClassification: value.source.scanClassification,
                presentationTimeStamp: try ExactMediaTime(
                    CMSampleBufferGetPresentationTimeStamp(value.source.sampleBuffer)
                ),
                decodeTimeStamp: try ExactMediaTime(
                    CMSampleBufferGetDecodeTimeStamp(value.source.sampleBuffer)
                ),
                duration: try ExactMediaTime(CMSampleBufferGetDuration(value.source.sampleBuffer)),
                expectedFormat: track
            ))
        }
        let eligibility = try VideoRemuxEligibility(
            generation: .init(rawValue: 0), track: track, sampleEntry: sampleEntry
        )
        let admissions = try proofs.map { proof in
            try XCTUnwrap(eligibility.evaluate(proof).proof)
        }
        let binding = binding(seed: seed)
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioVideo(
                epochStart: CMTime(value: 10, timescale: 1),
                videoMode: boundaryVideoMode
            )
        )
        let builder = try HLSVideoRemuxSubmissionBuilder(
            reference: timed[0], admission: admissions[0], writerBinding: binding,
            applicationLedger: applicationLedger
        )
        return RemuxFixture(
            binding: binding,
            boundary: boundary,
            builder: builder,
            timed: timed,
            admissions: admissions
        )
    }

    static func task22HEVCParameterSets(
        transferCharacteristics: UInt8 = 16
    ) -> [Data] {
        func nal(_ type: UInt8, _ body: (inout Task22VideoBitWriter) -> Void) -> Data {
            var bits = Task22VideoBitWriter()
            body(&bits)
            return Data([type << 1, 0x01]) + Task22VideoBitWriter.escape(bits.finishRBSP())
        }
        let vps = nal(32) { bits in
            bits.write(0, 4); bits.write(1, 1); bits.write(1, 1); bits.write(0, 6)
            bits.write(0, 3); bits.write(1, 1); bits.write(0xFFFF, 16)
            bits.write(0, 2); bits.write(0, 1); bits.write(2, 5)
            bits.write(0, 32); bits.write(1, 1); bits.write(0, 1)
            bits.write(0, 1); bits.write(1, 1); bits.write(0, 44); bits.write(153, 8)
            bits.write(0, 1); bits.writeUE(4); bits.writeUE(0); bits.writeUE(0)
            bits.write(0, 6); bits.writeUE(0); bits.write(0, 1); bits.write(0, 1)
        }
        let sps = nal(33) { bits in
            bits.write(0, 4); bits.write(0, 3); bits.write(1, 1)
            bits.write(0, 2); bits.write(0, 1); bits.write(2, 5)
            bits.write(0, 32); bits.write(1, 1); bits.write(0, 1)
            bits.write(0, 1); bits.write(1, 1); bits.write(0, 44); bits.write(153, 8)
            bits.writeUE(0); bits.writeUE(1); bits.writeUE(3_840); bits.writeUE(2_160)
            bits.write(0, 1); bits.writeUE(2); bits.writeUE(2); bits.writeUE(4)
            bits.write(0, 1); bits.writeUE(4); bits.writeUE(0); bits.writeUE(0)
            bits.writeUE(0); bits.writeUE(3); bits.writeUE(0); bits.writeUE(3)
            bits.writeUE(0); bits.writeUE(0); bits.write(0, 1); bits.write(1, 1)
            bits.write(1, 1); bits.write(0, 1); bits.writeUE(0)
            bits.write(0, 1); bits.write(0, 1); bits.write(1, 1)
            bits.write(1, 1) // vui_parameters_present_flag
            bits.write(1, 1); bits.write(1, 8) // 1:1 sample aspect
            bits.write(0, 1); bits.write(1, 1); bits.write(5, 3); bits.write(0, 1)
            bits.write(1, 1); bits.write(9, 8)
            bits.write(UInt64(transferCharacteristics), 8); bits.write(9, 8)
            bits.write(1, 1); bits.writeUE(1); bits.writeUE(1)
            bits.write(0, 1); bits.write(0, 1); bits.write(0, 1); bits.write(0, 1)
            bits.write(1, 1); bits.write(1, 32); bits.write(30, 32)
            bits.write(0, 1); bits.write(0, 1); bits.write(0, 1)
            bits.write(0, 1) // sps_extension_present_flag
        }
        let pps = nal(34) { bits in
            bits.writeUE(0); bits.writeUE(0); bits.write(0, 1); bits.write(0, 1)
            bits.write(0, 3); bits.write(0, 1); bits.write(0, 1)
            bits.writeUE(0); bits.writeUE(0); bits.writeSE(0)
            bits.write(0, 1); bits.write(0, 1); bits.write(0, 1)
            bits.writeSE(0); bits.writeSE(0); bits.write(0, 1)
            bits.write(0, 1); bits.write(0, 1); bits.write(0, 1)
            bits.write(0, 1); bits.write(0, 1); bits.write(1, 1)
            bits.write(1, 1); bits.write(0, 1); bits.write(0, 1)
            bits.writeSE(0); bits.writeSE(0); bits.write(0, 1)
            bits.write(0, 1); bits.writeUE(0); bits.write(0, 1); bits.write(0, 1)
        }
        return [vps, sps, pps]
    }

    static func task22HEVCHDRSEI() -> Data {
        var rbsp = Data([137, 24])
        for value: UInt16 in [8_500, 39_850, 6_550, 2_300, 35_400, 14_600, 15_635, 16_450] {
            var encoded = value.bigEndian
            Swift.withUnsafeBytes(of: &encoded) { rbsp.append(contentsOf: $0) }
        }
        for value: UInt32 in [10_000_000, 50] {
            var encoded = value.bigEndian
            Swift.withUnsafeBytes(of: &encoded) { rbsp.append(contentsOf: $0) }
        }
        rbsp.append(contentsOf: [144, 4])
        for value: UInt16 in [1_000, 400] {
            var encoded = value.bigEndian
            Swift.withUnsafeBytes(of: &encoded) { rbsp.append(contentsOf: $0) }
        }
        rbsp.append(0x80)
        return Data([39 << 1, 0x01]) + Task22VideoBitWriter.escape(rbsp)
    }

    static func lengthPrefixedNALUnits(_ data: Data) throws -> [Data] {
        var result: [Data] = []
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { throw CocoaError(.fileReadCorruptFile) }
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            offset += 4
            guard let count = Int(exactly: length), count > 0,
                  count <= data.count - offset else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(data.subdata(in: offset..<(offset + count)))
            offset += count
        }
        return result
    }

    private static func parameterSetDimensions(
        codec: VideoCodec,
        parameterSets: [Data]
    ) throws -> CMVideoDimensions {
        var format: CMFormatDescription?
        let status: OSStatus
        let stableSets = parameterSets.map { $0 as NSData }
        switch codec {
        case .h264:
            var pointers = stableSets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            var sizes = stableSets.map(\.length)
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: stableSets.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        case .hevc:
            var pointers = stableSets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            var sizes = stableSets.map(\.length)
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: stableSets.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        try check(status)
        return CMVideoFormatDescriptionGetDimensions(try XCTUnwrap(format))
    }

    private static func annexB(_ nals: [Data]) -> Data {
        nals.reduce(into: Data()) { result, nal in
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(nal)
        }
    }

    static func binding(seed: UInt64, generation: UInt64 = 1) -> FMP4WriterBinding {
        FMP4WriterBinding(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: seed),
            itemGeneration: .init(rawValue: seed + generation),
            mediaEpoch: .init(rawValue: seed + generation + 1),
            publicationParticipantID: .init(rawValue: seed + generation + 2),
            renditionIdentity: .init(rawValue: seed + generation + 3),
            writerIdentity: .init(rawValue: seed + generation + 4)
        )
    }

    static func rolloverBinding(
        from value: FMP4WriterBinding,
        writerIdentity: FMP4WriterIdentity
    ) -> FMP4WriterBinding {
        FMP4WriterBinding(
            outputLifecycleEpoch: value.outputLifecycleEpoch,
            itemGeneration: value.itemGeneration,
            mediaEpoch: value.mediaEpoch,
            publicationParticipantID: value.publicationParticipantID,
            renditionIdentity: value.renditionIdentity,
            writerIdentity: writerIdentity
        )
    }

    static func makeWriter(
        seed: UInt64,
        kind: SegmentedFMP4TrackKind,
        writerBinding: FMP4WriterBinding? = nil,
        sourceFormatHint: CMFormatDescription? = nil,
        boundary: SegmentBoundaryCoordinator? = nil,
        compressedFormatConfiguration: CompressedAudioFormatConfiguration? = nil,
        videoCadencePolicy: SegmentedFMP4VideoCadencePolicy = .strict,
        factory: (any SegmentedFMP4SystemWriterFactory)? = nil,
        collector: Task17ObjectCollector? = nil,
        limits: FMP4WriterLimits? = nil,
        ownershipLimits: SegmentedFMP4WriterOwnershipLimits = .standard,
        continuation: AACWriterWindowContinuation? = nil,
        writerWindowContinuation: WriterWindowContinuation? = nil,
        releaseTransfersImmediately: Bool = false,
        transferGate: Task22TransferReleaseGate? = nil,
        recordAppendFailureOrdinal: Int? = nil
    ) throws -> SegmentedFMP4Writer {
        let binding = writerBinding ?? binding(seed: seed)
        let relayHolder = Task17RelayHolder()
        let sink: @Sendable (SealedMediaObject) -> Void
        if let transferGate {
            sink = { object in transferGate.receive(object) }
        } else if let collector {
            sink = { object in
                collector.append(object)
                if releaseTransfersImmediately {
                    _ = relayHolder.relay?.releaseForControl(object)
                }
            }
        } else if releaseTransfersImmediately {
            sink = { object in
                _ = relayHolder.relay?.releaseForControl(object)
            }
        } else {
            sink = { _ in }
        }
        let relay = SegmentReportRelay(
            binding: binding,
            limits: limits ?? (kind == .video ? .video : .audio),
            capacity: 8,
            objectSink: sink
        )
        relayHolder.relay = relay
        transferGate?.install(relay: relay)
        let resolvedFactory: any SegmentedFMP4SystemWriterFactory
        if let factory {
            resolvedFactory = factory
        } else {
            resolvedFactory = AVAssetSegmentedFMP4SystemWriterFactory()
        }
        let resolvedBoundary: SegmentBoundaryCoordinator
        if let boundary {
            resolvedBoundary = boundary
        } else if kind == .video {
            resolvedBoundary = try SegmentBoundaryCoordinator(
                mode: .audioVideo(epochStart: .zero, videoMode: .passthrough)
            )
        } else {
            resolvedBoundary = try SegmentBoundaryCoordinator(
                mode: .audioOnly(epochStart: kind == .aac ? CMTime(value: 10, timescale: 1) : .zero)
            )
        }
        let resolvedCompressedConfiguration: CompressedAudioFormatConfiguration?
        switch kind {
        case .ac3:
            resolvedCompressedConfiguration = try compressedFormatConfiguration ?? .ac3(
                AC3CompressedAudioConfiguration(
                    inspection: AC3FrameInspector.inspect(
                        AssemblerTestFixtures.syntheticAC3Frame(fscod: 0, frmsizecod: 20, bsmod: 0)
                    )
                )
            )
        case .eac3:
            resolvedCompressedConfiguration = try compressedFormatConfiguration ?? .eac3(
                EAC3CompressedAudioConfiguration(
                    sampleRate: 48_000,
                    bsid: 16,
                    bsmod: 0,
                    audioCodingMode: 2,
                    hasLFE: false,
                    asvc: false,
                    maximumDataRateKbps: 6_144
                )
            )
        case .video, .aac:
            resolvedCompressedConfiguration = nil
        }
        let resolvedFormat: CMFormatDescription
        if let sourceFormatHint {
            resolvedFormat = sourceFormatHint
        } else {
            resolvedFormat = switch kind {
            case .video: videoFormat()
            case .aac: audioFormat()
            case .ac3: audioFormat(
                formatID: kAudioFormatAC3,
                framesPerPacket: 1_536,
                magicCookie: try XCTUnwrap(resolvedCompressedConfiguration?.serializedBox)
            )
            case .eac3: audioFormat(
                formatID: kAudioFormatEnhancedAC3,
                framesPerPacket: 1_536,
                magicCookie: try XCTUnwrap(resolvedCompressedConfiguration?.serializedBox)
            )
            }
        }
        let writer = try SegmentedFMP4Writer(
            binding: binding,
            trackKind: kind,
            sourceFormatHint: resolvedFormat,
            boundarySession: resolvedBoundary.session,
            compressedFormatConfiguration: resolvedCompressedConfiguration,
            videoCadencePolicy: videoCadencePolicy,
            ownershipLimits: ownershipLimits,
            relay: relay,
            systemFactory: resolvedFactory,
            aacContinuation: continuation,
            writerWindowContinuation: writerWindowContinuation,
            recordAppendFailureOrdinal: recordAppendFailureOrdinal
        )
        Task17BoundaryRegistry.shared.install(resolvedBoundary, for: binding.writerIdentity)
        return writer
    }

    static func makeWindowWriter(
        binding: FMP4WriterBinding,
        format: CMFormatDescription,
        boundary: SegmentBoundaryCoordinator,
        factory: any SegmentedFMP4SystemWriterFactory,
        continuation: AACWriterWindowContinuation? = nil,
        ownershipLimits: SegmentedFMP4WriterOwnershipLimits = .standard
    ) throws -> SegmentedFMP4Writer {
        let holder = Task17RelayHolder()
        let relay = SegmentReportRelay(
            binding: binding, limits: .audio, capacity: 8,
            objectSink: { object in _ = holder.relay?.releaseForControl(object) })
        holder.relay = relay
        return try SegmentedFMP4Writer(
            binding: binding, trackKind: .aac, sourceFormatHint: format,
            boundarySession: boundary.session,
            compressedFormatConfiguration: nil,
            ownershipLimits: ownershipLimits,
            relay: relay, systemFactory: factory,
            aacContinuation: continuation)
    }

    static func makeWindowPredecessor(seed: UInt64) async throws
        -> WindowPredecessor {
        let calibration = try await AACPrimingCalibrator().calibrate(plan:
            AACCalibrationPlan.build([try AACRenditionRequest(
                layout: RenditionAudioLayout(labels: [.l, .r]),
                capabilityVersion: "task22-b-negative-\(seed)" )]))
        let encoder = try XCTUnwrap(calibration.encoders.first)
        let format = try encoder.incrementalFormatDescription()
        let boundary = try SegmentBoundaryCoordinator(
            mode: .audioOnly(epochStart: CMTime(value: 10, timescale: 1)))
        let binding = self.binding(seed: seed)
        try boundary.registerAudioRendition(
            binding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000),
            firstEffectiveStart: CMTime(value: 10, timescale: 1))
        let writer = try makeWindowWriter(
            binding: binding, format: format, boundary: boundary,
            factory: AVAssetSegmentedFMP4SystemWriterFactory(),
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 64))
        try writer.start(at: CMTime(value: 10, timescale: 1))
        var pending: [AACIncrementalEmission] = []
        for batch in 0..<80 where pending.isEmpty {
            let samples = (0..<(1_024 * 2)).map {
                sin(Float(batch * 2_048 + $0) * 0.003125) * 0.25
            }
            _ = try encoder.pumpSigned(.pcm(samples)) { emission in
                do { _ = try writer.appendAACIncremental(
                    emission, coordinator: boundary) }
                catch SegmentedFMP4WriterFailure.rolloverRequired {
                    pending.append(emission)
                }
            }
        }
        for batch in 80..<84 where pending.count < 2 {
            let samples = (0..<(1_024 * 2)).map {
                sin(Float(batch * 2_048 + $0) * 0.003125) * 0.25
            }
            _ = try encoder.pumpSigned(.pcm(samples)) { emission in
                // 首次 rollover 后旧 writer 的 next ordinal 仍指向 pending[0]；
                // encoder 后续签发的 N+1 只能排在同一待接管队列，不能再送旧 writer。
                pending.append(emission)
            }
        }
        let continuation = try await writer.finishAACWriterWindow()
        guard pending.count >= 2 else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        XCTAssertEqual(pending[1].ordinal, pending[0].ordinal + 1,
                       "rollover 后 N+1 必须紧随原 pending N 排队")
        return .init(encoder: encoder, binding: binding, format: format, boundary: boundary,
                     continuation: continuation, pending: pending)
    }

    static func makeAuthorizedWriter(
        seed: UInt64,
        kind: SegmentedFMP4TrackKind,
        boundary: SegmentBoundaryCoordinator,
        sourceFormatHint: CMFormatDescription? = nil,
        compressedFormatConfiguration: CompressedAudioFormatConfiguration? = nil,
        factory: (any SegmentedFMP4SystemWriterFactory)? = nil,
        collector: Task17ObjectCollector? = nil,
        limits: FMP4WriterLimits? = nil
    ) throws -> SegmentedFMP4Writer {
        let binding = binding(seed: seed)
        let sink: @Sendable (SealedMediaObject) -> Void
        if let collector { sink = { collector.append($0) } } else { sink = { _ in } }
        let relay = SegmentReportRelay(
            binding: binding,
            limits: limits ?? (kind == .video ? .video : .audio),
            capacity: 8,
            objectSink: sink
        )
        return try SegmentedFMP4Writer(
            binding: binding,
            trackKind: kind,
            sourceFormatHint: sourceFormatHint ?? (kind == .video ? videoFormat() : audioFormat()),
            boundarySession: boundary.session,
            compressedFormatConfiguration: compressedFormatConfiguration,
            relay: relay,
            systemFactory: factory ?? AVAssetSegmentedFMP4SystemWriterFactory()
        )
    }

    static func delivery(
        binding: FMP4WriterBinding,
        ticket: SegmentCallbackTicket,
        logicalSequence: UInt64,
        byte: UInt8
    ) -> SegmentCallbackDelivery {
        SegmentCallbackDelivery(
            binding: binding,
            writerIdentity: binding.writerIdentity,
            ticket: ticket,
            logicalSequence: logicalSequence,
            kind: .media,
            bytes: NSData(data: Data([byte])),
            report: SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: nil))
        )
    }

    static func sealedObject(
        binding: FMP4WriterBinding,
        kind: SealedMediaObjectKind,
        logicalSequence: UInt64,
        bytes: Data
    ) throws -> SealedMediaObject {
        let collector = Task17ObjectCollector()
        let relay = SegmentReportRelay(binding: binding, limits: .audio, capacity: 8) {
            collector.append($0)
        }
        let ticket = try relay.reserve(
            kind: kind,
            logicalSequence: logicalSequence,
            projectedByteCount: bytes.count
        )
        let result = relay.receive(SegmentCallbackDelivery(
            binding: binding,
            writerIdentity: binding.writerIdentity,
            ticket: ticket,
            logicalSequence: logicalSequence,
            kind: kind,
            bytes: NSData(data: bytes),
            report: SegmentReportReference(evidence: .init(systemReport: nil, earliestPresentationTimeStamp: nil))
        ))
        guard case let .accepted(acceptance) = result else {
            throw SegmentedFMP4WriterFailure.systemFailure
        }
        XCTAssertTrue(relay.consumePublication(acceptance) { $0() })
        return try XCTUnwrap(collector.objects.first)
    }

    static func videoFormat() -> CMFormatDescription {
        var result: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 16,
            height: 16,
            extensions: nil,
            formatDescriptionOut: &result
        )
        precondition(status == noErr)
        return result!
    }

    static func audioFormat(
        formatID: AudioFormatID = kAudioFormatMPEG4AAC,
        framesPerPacket: UInt32 = 1_024,
        magicCookie: Data = Data()
    ) -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var result: CMAudioFormatDescription?
        let status = magicCookie.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: magicCookie.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &result
            )
        }
        precondition(status == noErr)
        return result!
    }

    static func compressedAudioFormat(for accessUnit: CompressedAudioAccessUnit) throws -> CMFormatDescription {
        switch accessUnit.codec {
        case .ac3:
            return audioFormat(
                formatID: kAudioFormatAC3,
                framesPerPacket: 1_536,
                magicCookie: accessUnit.formatConfiguration.serializedBox
            )
        case .eac3:
            return audioFormat(
                formatID: kAudioFormatEnhancedAC3,
                framesPerPacket: 1_536,
                magicCookie: accessUnit.formatConfiguration.serializedBox
            )
        default:
            throw SegmentedFMP4WriterFailure.compressedIdentityMismatch
        }
    }

    static func sampleBuffer(
        format: CMFormatDescription,
        payload: Data,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        ))
        try payload.withUnsafeBytes {
            try check(CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block!,
                offsetIntoDestination: 0,
                dataLength: payload.count
            ))
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block!,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ))
        return try XCTUnwrap(sample)
    }

    static func aacBuffer(pts: CMTime) throws -> CMSampleBuffer {
        try sampleBuffer(
            format: audioFormat(),
            payload: Data(repeating: 0x21, count: 24),
            presentationTimeStamp: pts,
            duration: CMTime(value: 1_024, timescale: 48_000)
        )
    }

    static func aacEpoch(
        bufferCount: Int,
        outputBase: CMTime = CMTime(value: 10, timescale: 1),
        workspace suppliedWorkspace: AACCalibrationWorkspace? = nil
    ) throws -> AACEncodedEpoch {
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task17-synthetic-v1"
        )
        let plan = try AACCalibrationPlan.build([request])
        let identity = AACEncoderIdentity(
            plan: plan,
            ordinal: 0,
            request: request,
            nonce: ConverterInstanceNonce()
        )
        let workspace = suppliedWorkspace ?? AACCalibrationWorkspace()
        let format = audioFormat()
        let leading = 128
        let trailing = 128
        let total = bufferCount * 1_024
        let base = CMTimeConvertScale(outputBase, timescale: 48_000, method: .default)
        var buffers: [CMSampleBuffer] = []
        for index in 0..<bufferCount {
            let buffer = try sampleBuffer(
                format: format,
                payload: Data(repeating: UInt8(index + 1), count: 24),
                presentationTimeStamp: CMTime(value: base.value + Int64(index * 1_024 - leading), timescale: 48_000),
                duration: CMTime(value: 1_024, timescale: 48_000)
            )
            if index == 0 { setTrim(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, samples: leading) }
            if index == bufferCount - 1 { setTrim(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, samples: trailing) }
            try check(CMSampleBufferSetOutputPresentationTimeStamp(
                buffer,
                newValue: CMTime(
                    value: base.value + Int64(index * 1_024) - (index == 0 ? 0 : Int64(leading)),
                    timescale: 48_000
                )
            ))
            buffers.append(buffer)
        }
        return AACEncodedEpoch(
            identity: identity,
            buffers: buffers,
            realSampleCount: total - leading - trailing,
            totalDecodedFrames: total,
            leadingFrames: leading,
            trailingFrames: trailing,
            actualLeadingPrimeFrames: UInt32(leading),
            actualTrailingPrimeFrames: UInt32(trailing),
            bandwidth: AACBandwidthEvidence(
                configuredBitrate: 160_000,
                payloadCeiling: 200_000,
                fmp4BodyCeiling: 264_000,
                peakPayloadBits: UInt64(bufferCount * 24 * 8),
                accessUnitCount: UInt64(bufferCount),
                requiresWriterBodyAccounting: true
            ),
            packetLease: try workspace.acquire(.aacPackets, bytes: bufferCount * 24),
            formatLease: try workspace.acquire(.nonPayload, bytes: 1_024)
        )
    }

    static func aacEpoch(
        buffers: [CMSampleBuffer],
        workspace: AACCalibrationWorkspace
    ) throws -> AACEncodedEpoch {
        precondition(!buffers.isEmpty)
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task17-retry-v1"
        )
        let plan = try AACCalibrationPlan.build([request])
        let identity = AACEncoderIdentity(
            plan: plan,
            ordinal: 0,
            request: request,
            nonce: ConverterInstanceNonce()
        )
        let total = buffers.count * 1_024
        return AACEncodedEpoch(
            identity: identity,
            buffers: buffers,
            realSampleCount: total,
            totalDecodedFrames: total,
            leadingFrames: 0,
            trailingFrames: 0,
            actualLeadingPrimeFrames: 0,
            actualTrailingPrimeFrames: 0,
            bandwidth: AACBandwidthEvidence(
                configuredBitrate: 160_000,
                payloadCeiling: 200_000,
                fmp4BodyCeiling: 264_000,
                peakPayloadBits: UInt64(buffers.count * 24 * 8),
                accessUnitCount: UInt64(buffers.count),
                requiresWriterBodyAccounting: true
            ),
            packetLease: try workspace.acquire(.aacPackets, bytes: buffers.count * 24),
            formatLease: try workspace.acquire(.nonPayload, bytes: 1_024)
        )
    }

    static func replacingAACCounts(
        _ epoch: AACEncodedEpoch,
        totalDecodedFrames: Int
    ) -> AACEncodedEpoch {
        AACEncodedEpoch(
            identity: epoch.identity,
            buffers: epoch.buffers,
            realSampleCount: epoch.realSampleCount,
            totalDecodedFrames: totalDecodedFrames,
            leadingFrames: epoch.leadingFrames,
            trailingFrames: epoch.trailingFrames,
            actualLeadingPrimeFrames: epoch.actualLeadingPrimeFrames,
            actualTrailingPrimeFrames: epoch.actualTrailingPrimeFrames,
            bandwidth: epoch.bandwidth,
            packetLease: epoch.packetLease,
            formatLease: epoch.formatLease
        )
    }

    static func aacCoordinator(
        epoch: AACEncodedEpoch,
        writer: SegmentedFMP4Writer,
        epochStart: CMTime = CMTime(value: 10, timescale: 1)
    ) throws -> SegmentBoundaryCoordinator {
        let boundary = try XCTUnwrap(Task17BoundaryRegistry.shared.boundary(for: writer.binding.writerIdentity))
        do {
            try boundary.registerAudioRendition(
                writer.binding.renditionIdentity,
                accessUnit: .aac(sampleRate: 48_000),
                firstEffectiveStart: epochStart
            )
        } catch SegmentBoundaryFailure.duplicateRendition {
            // 同一正式 session 的后续 epoch 沿用既有 rendition 注册。
        }
        return boundary
    }

    static func compressedTicket(
        accessUnit: CompressedAudioAccessUnit,
        writer: SegmentedFMP4Writer
    ) throws -> SegmentBoundaryAppendTicket {
        let boundary = try XCTUnwrap(Task17BoundaryRegistry.shared.boundary(for: writer.binding.writerIdentity))
        let kind: SegmentAudioAccessUnitKind = accessUnit.codec == .ac3
            ? .ac3(sampleRate: accessUnit.sampleRate)
            : .eac3Aggregated(
                sampleRate: accessUnit.sampleRate,
                sampleCount: accessUnit.sampleCount
            )
        try boundary.registerAudioRendition(
            writer.binding.renditionIdentity,
            accessUnit: kind,
            firstEffectiveStart: accessUnit.presentationStart
        )
        return try boundary.issueCompressedAudioAppend(
            for: accessUnit,
            writerBinding: writer.binding
        )
    }

    static func realAACEncodedEpoch() async throws -> AACEncodedEpoch {
        let calibrator = AACPrimingCalibrator()
        let request = try AACRenditionRequest(
            layout: RenditionAudioLayout(labels: [.l, .r]),
            capabilityVersion: "task17-real-v1"
        )
        let receipt = try await calibrator.calibrate(plan: try AACCalibrationPlan.build([request]))
        let encoder = try XCTUnwrap(receipt.encoders.first)
        var samples: [Float] = []
        samples.reserveCapacity(8_192 * 2)
        for frame in 0..<8_192 {
            let value = sin(Float(frame) * 0.03125) * 0.25
            samples.append(value)
            samples.append(value)
        }
        return try encoder.encodeEpoch(samples)
    }

    static func realH264Sample(
        presentationTimeStamp: CMTime = .zero,
        duration: CMTime = CMTime(value: 1, timescale: 24)
    ) throws -> VideoFixture {
        let sps = AssemblerTestFixtures.h264SPS
        let pps = AssemblerTestFixtures.h264PPS
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        try check(status)
        let resolved = try XCTUnwrap(format)
        let sample = try sampleBuffer(
            format: resolved,
            payload: Data([0, 0, 0, 2, 0x65, 0x80]),
            presentationTimeStamp: presentationTimeStamp,
            duration: duration
        )
        return VideoFixture(format: resolved, sample: sample)
    }

    static func videoOutput(
        fixture: VideoFixture,
        generation: UInt64,
        accessUnitID: UInt64,
        sequenceNumber: UInt64
    ) -> HLSVideoEncodedOutput {
        let identity = VideoEncodingFrameIdentity(
            generation: .init(rawValue: generation),
            accessUnitID: accessUnitID,
            sequenceNumber: sequenceNumber
        )
        return HLSVideoEncodedOutput(
            sourceIdentity: identity,
            sampleBuffer: fixture.sample,
            presentationOrigin: .raw,
            inputFormatSignature: VideoEncodingInputFormatSignature(
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                width: 16,
                height: 16,
                bitDepth: 8,
                range: .video,
                primaries: .bt709,
                transfer: .bt709,
                matrix: .bt709,
                cleanAperture: nil,
                sampleAspectRatio: MediaRational(num: 1, den: 1),
                chromaLocation: .init(topField: "Left", bottomField: "Left"),
                masteringDisplayColorVolume: nil,
                contentLightLevelInfo: nil
            ),
            hardwareProof: VTHardwareEncoderProof(
                sessionID: .init(rawValue: generation + 1_000),
                generation: identity.generation,
                firstOutputIdentity: identity,
                profile: .h264High
            )
        )
    }

    static func shiftOutputPTS(_ buffer: CMSampleBuffer, by delta: Int64) throws {
        let current = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
        try check(CMSampleBufferSetOutputPresentationTimeStamp(
            buffer,
            newValue: CMTime(value: current.value + delta, timescale: current.timescale)
        ))
    }

    static func setVideoNotSync(_ buffer: CMSampleBuffer, _ value: Bool) throws {
        guard let raw = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
              let first = (raw as NSArray).firstObject as? NSMutableDictionary else {
            throw SegmentBoundaryFailure.ticketMismatch
        }
        first.setObject(value, forKey: kCMSampleAttachmentKey_NotSync as NSString)
    }

    static func replacePayload(_ buffer: CMSampleBuffer, with payload: Data) throws {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
        guard CMBlockBufferGetDataLength(block) == payload.count else {
            throw SegmentBoundaryFailure.ticketMismatch
        }
        try payload.withUnsafeBytes {
            try check(CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            ))
        }
    }

    static func hasTopLevelMarker(_ marker: String, in data: Data) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }

    static func setTrim(_ buffer: CMSampleBuffer, key: CFString, samples: Int) {
        CMSetAttachment(
            buffer,
            key: key,
            value: CMTimeCopyAsDictionary(
                CMTime(value: Int64(samples), timescale: 48_000),
                allocator: kCFAllocatorDefault
            )!,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
    }

    static func removeTrim(_ buffer: CMSampleBuffer, key: CFString) { CMRemoveAttachment(buffer, key: key) }

    static func mutatedDirectAdmissions(seed: UInt64) -> [AudioBranchAdmissionIdentity] {
        let owner = compressedOwner(seed: seed)
        return [
            .directCompressed(compressedOwner(seed: seed + 1), branchGeneration: seed + 10, admissionFenceRevision: seed + 11),
            .directCompressed(owner, branchGeneration: seed + 12, admissionFenceRevision: seed + 11),
            .directCompressed(owner, branchGeneration: seed + 10, admissionFenceRevision: seed + 12),
            .eac3Aggregation(owner, branchGeneration: seed + 10, admissionFenceRevision: seed + 11),
        ]
    }

    static func compressedOwner(seed: UInt64) -> CompressedAudioBranchOwnerIdentity {
        .audioVideo(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: seed),
            itemGeneration: .init(rawValue: seed + 1),
            mediaEpoch: .init(rawValue: seed + 2),
            publicationParticipantID: .init(rawValue: seed + 3),
            renditionIdentity: .init(rawValue: seed + 4)
        )
    }

    static func controlExecutor() -> PlaybackControlExecutor {
        PlaybackControlExecutor(
            allocator: PlaybackIdentityAllocator(),
            applyIngress: { _ in .applied },
            applyTerminalIngress: { _ in },
            applyOutputControl: { _, _ in .rejected }
        )
    }

    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AACRenditionFailure.framework(status) }
    }
}

final class Task17AC3Harness {
    let coordinator: AudioServiceSemanticCoordinator
    let admission: AudioBranchAdmissionIdentity
    private let source: AudioTrackDescriptor
    private let seed: UInt64
    private let sampleRate: Int32
    private let fscod: UInt8
    private var nextIdentity: UInt64
    private var nextBundleNonce: UInt64
    private var timeline: HLSTimelineCoordinator?
    private var cachedAuthorization: CompressedAudioCandidatePlanAuthorization?

    convenience init(seed: UInt64) throws {
        try self.init(
            seed: seed,
            admission: .directCompressed(
                Task17Fixtures.compressedOwner(seed: seed),
                branchGeneration: seed + 10,
                admissionFenceRevision: seed + 11
            )
        )
    }

    init(
        seed: UInt64,
        admission: AudioBranchAdmissionIdentity,
        sampleRate: Int32 = 48_000
    ) throws {
        guard case .directCompressed = admission else {
            throw AudioServiceSemanticFailure.invalidInputUnit
        }
        guard let fscod = [48_000: UInt8(0), 44_100: 1, 32_000: 2][sampleRate] else {
            throw AudioServiceSemanticFailure.invalidInputUnit
        }
        self.seed = seed
        self.sampleRate = sampleRate
        self.fscod = fscod
        nextIdentity = seed + 100
        nextBundleNonce = seed + 500
        source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: .ac3,
            timeBase: MediaRational(num: 1, den: 48_000)!,
            sampleRate: sampleRate,
            channelLayout: .init(channelCount: 2, nativeMask: 3),
            extradata: Data(),
            metadata: .init(role: .main, service: .independentMain, dispositions: [.default])
        )
        self.admission = admission
        coordinator = AudioServiceSemanticCoordinator(
            source: source,
            sourceTrackIdentity: .init(streamIndex: 1, trackNonce: seed + 20),
            inputFormatGeneration: .init(rawValue: seed + 21),
            allocator: PlaybackIdentityAllocator(),
            compressedOutputAdmissionAuthority: admission,
            sharedControlExecutor: Task17Fixtures.controlExecutor()
        )
        let first = makeUnit(
            bytes: AssemblerTestFixtures.syntheticAC3Frame(
                fscod: fscod, frmsizecod: 20, bsmod: 0),
            presentationTimeStamp: .zero
        )
        _ = try coordinator.establishReceipt(selectedProgramID: 7, firstInputUnit: first)
    }

    func makeAccessUnit(presentationTimeStamp: CMTime) throws -> CompressedAudioAccessUnit {
        let bytes = AssemblerTestFixtures.syntheticAC3Frame(
            fscod: fscod, frmsizecod: 20, bsmod: 0)
        let unit = makeUnit(bytes: bytes, presentationTimeStamp: presentationTimeStamp)
        let validation = try coordinator.installValidation(for: unit)
        let proof = try coordinator.makeProof(for: unit, validationNonce: validation)
        let outcome = coordinator.admit(
            proof,
            ownership: AudioServiceInputUnitOwnership()
        )
        let admitted: AdmittedAudioServiceInputUnitProof
        switch outcome {
        case let .admitted(value): admitted = value
        case let .failed(failure): throw failure
        case .ignored: throw AudioServiceSemanticFailure.staleProof
        }
        let authorization = try makeAuthorization(
            origin: presentationTimeStamp,
            frame: bytes)
        guard try coordinator.registerEligibleCompressedPlan(authorization, for: admitted),
              let lease = try coordinator.issueAudioServiceBranchLease(for: admitted, admission: admission) else {
            throw AudioServiceSemanticFailure.staleProof
        }
        defer { nextBundleNonce += 1 }
        let accessUnit = try AC3DirectAccessUnitBuilder(
            coordinator: coordinator,
            authorization: authorization
        ).makeAccessUnit(
            inputUnit: unit,
            admittedProof: admitted,
            directLease: lease,
            bundleNonce: .init(rawValue: nextBundleNonce)
        )
        XCTAssertTrue(coordinator.retireAdmittedProof(admitted))
        return accessUnit
    }

    private func makeAuthorization(
        origin: CMTime,
        frame: Data
    ) throws -> CompressedAudioCandidatePlanAuthorization {
        if let cachedAuthorization { return cachedAuthorization }
        let binding = try XCTUnwrap(coordinator.bindCompressedOutputPlan())
        let parser = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                sampleRate: self.sampleRate,
                channels: 2,
                frameSamples: 1_536,
                nativeMask: 3
            ))
        }
        let value = HLSTimelineCoordinator(
            parserFactory: parser,
            compressedAudioOutputPlanBinding: binding
        )
        _ = try value.consume(.tracks(DemuxTrackSet(selectedProgramID: 7, video: nil, audio: source)))
        _ = try value.consume(.packet(DemuxPacket(
            streamIndex: 1,
            codec: .audio(.ac3),
            data: frame,
            presentationTimeStamp: origin,
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: false
        )))
        timeline = value
        let authorization = try XCTUnwrap(coordinator.authorizeCompressedCandidate(
            try XCTUnwrap(value.makeCompressedAudioCandidatePlan())
        ))
        cachedAuthorization = authorization
        return authorization
    }

    private func makeUnit(bytes: Data, presentationTimeStamp: CMTime) -> AudioServiceInputUnit {
        defer { nextIdentity += 1 }
        return try! AudioServiceInputUnit(
            identity: .init(rawValue: nextIdentity),
            backing: AudioServiceInputBacking(identity: .init(rawValue: nextIdentity + 10_000), bytes: bytes),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: presentationTimeStamp,
            parserSampleCount: 1_536,
            parserSampleRate: sampleRate,
            parserChannelLayout: .init(channelCount: 2, nativeMask: 3),
            containerMarkedCorrupt: false
        )
    }
}

private struct Task17EAC3Member {
    let unit: AudioServiceInputUnit
    let proof: AdmittedAudioServiceInputUnitProof
    let lease: AudioServiceBranchLease
}

final class Task17EAC3Harness {
    let coordinator: AudioServiceSemanticCoordinator
    let admission: AudioBranchAdmissionIdentity
    private let source: AudioTrackDescriptor
    private let seed: UInt64
    private var nextIdentity: UInt64
    private var timeline: HLSTimelineCoordinator?
    private var leases: [AudioServiceBranchLeaseIdentity] = []
    private let aggregationAllocator = PlaybackIdentityAllocator()
    private var cachedAuthorization: CompressedAudioCandidatePlanAuthorization?

    var states: [AudioServiceBranchLeaseState?] {
        leases.map(coordinator.branchLeaseState)
    }

    convenience init(seed: UInt64) throws {
        try self.init(
            seed: seed,
            admission: .eac3Aggregation(
                Task17Fixtures.compressedOwner(seed: seed),
                branchGeneration: seed + 10,
                admissionFenceRevision: seed + 11
            )
        )
    }

    init(seed: UInt64, admission: AudioBranchAdmissionIdentity) throws {
        guard case .eac3Aggregation = admission else {
            throw AudioServiceSemanticFailure.invalidInputUnit
        }
        self.seed = seed
        nextIdentity = seed + 100
        source = AudioTrackDescriptor(
            streamIndex: 1,
            codec: .eac3,
            timeBase: MediaRational(num: 1, den: 48_000)!,
            sampleRate: 48_000,
            channelLayout: .init(channelCount: 2, nativeMask: 3),
            extradata: Data(),
            metadata: .init(role: .main, service: .independentMain, dispositions: [.default])
        )
        self.admission = admission
        coordinator = AudioServiceSemanticCoordinator(
            source: source,
            sourceTrackIdentity: .init(streamIndex: 1, trackNonce: seed + 20),
            inputFormatGeneration: .init(rawValue: seed + 21),
            allocator: PlaybackIdentityAllocator(),
            compressedOutputAdmissionAuthority: admission,
            sharedControlExecutor: Task17Fixtures.controlExecutor()
        )
        let frame = Task17EAC3Fixture.make(blockCount: 6, convsync: nil)
        _ = try coordinator.establishReceipt(
            selectedProgramID: 7,
            firstInputUnit: makeUnit(bytes: frame, blockCount: 6, presentationTimeStamp: .zero)
        )
    }

    func makeSixMemberAccessUnit(presentationBase: CMTime = .zero) throws -> CompressedAudioAccessUnit {
        let frame = Task17EAC3Fixture.make(blockCount: 6, convsync: nil)
        let authorization = try makeAuthorization(
            frame: frame,
            origin: presentationBase)
        let assembler = EAC3AccessUnitAssembler(
            coordinator: coordinator,
            authorization: authorization,
            allocator: aggregationAllocator
        )
        var output: CompressedAudioAccessUnit?
        var admittedProofs: [AdmittedAudioServiceInputUnitProof] = []
        for index in 0..<6 {
            let bytes = Task17EAC3Fixture.make(blockCount: 1, convsync: index == 0)
            let unit = makeUnit(
                bytes: bytes,
                blockCount: 1,
                presentationTimeStamp: CMTimeAdd(
                    presentationBase,
                    CMTime(value: Int64(index * 256), timescale: 48_000)
                )
            )
            let validation = try coordinator.installValidation(for: unit)
            let rawProof = try coordinator.makeProof(for: unit, validationNonce: validation)
            let outcome = coordinator.admit(
                rawProof,
                ownership: AudioServiceInputUnitOwnership()
            )
            let proof: AdmittedAudioServiceInputUnitProof
            switch outcome {
            case let .admitted(value): proof = value
            case let .failed(failure): throw failure
            case .ignored: throw AudioServiceSemanticFailure.staleProof
            }
            guard try coordinator.registerEligibleCompressedPlan(authorization, for: proof),
            let lease = try coordinator.issueAudioServiceBranchLease(for: proof, admission: admission) else {
                throw AudioServiceSemanticFailure.staleProof
            }
            leases.append(lease.identity)
            admittedProofs.append(proof)
            output = try assembler.append(
                inputUnit: unit,
                admittedProof: proof,
                aggregationLease: lease
            )
        }
        let accessUnit = try XCTUnwrap(output)
        for proof in admittedProofs {
            XCTAssertTrue(coordinator.retireAdmittedProof(proof))
        }
        return accessUnit
    }

    private func makeAuthorization(frame: Data, origin: CMTime) throws -> CompressedAudioCandidatePlanAuthorization {
        if let cachedAuthorization { return cachedAuthorization }
        let binding = try XCTUnwrap(coordinator.bindCompressedOutputPlan())
        let parser = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(
                bytes: bytes,
                pts: pts,
                sampleRate: 48_000,
                channels: 2,
                frameSamples: 1_536,
                nativeMask: 3
            ))
        }
        let value = HLSTimelineCoordinator(
            parserFactory: parser,
            compressedAudioOutputPlanBinding: binding
        )
        _ = try value.consume(.tracks(DemuxTrackSet(selectedProgramID: 7, video: nil, audio: source)))
        _ = try value.consume(.packet(DemuxPacket(
            streamIndex: 1,
            codec: .audio(.eac3),
            data: frame,
            presentationTimeStamp: origin,
            decodeTimeStamp: .invalid,
            duration: .invalid,
            isKey: false,
            isCorrupt: false
        )))
        timeline = value
        let authorization = try XCTUnwrap(coordinator.authorizeCompressedCandidate(
            try XCTUnwrap(value.makeCompressedAudioCandidatePlan())
        ))
        cachedAuthorization = authorization
        return authorization
    }

    private func makeUnit(
        bytes: Data,
        blockCount: Int,
        presentationTimeStamp: CMTime
    ) -> AudioServiceInputUnit {
        defer { nextIdentity += 1 }
        return try! AudioServiceInputUnit(
            identity: .init(rawValue: nextIdentity),
            backing: AudioServiceInputBacking(identity: .init(rawValue: nextIdentity + 10_000), bytes: bytes),
            byteRange: AudioServiceByteRange(offset: 0, length: bytes.count)!,
            presentationTimeStamp: presentationTimeStamp,
            parserSampleCount: Int32(blockCount * 256),
            parserSampleRate: 48_000,
            parserChannelLayout: .init(channelCount: 2, nativeMask: 3),
            containerMarkedCorrupt: false
        )
    }
}

private enum Task17EAC3Fixture {
    static func make(blockCount: Int, convsync: Bool?, byteCount: Int = 16) -> Data {
        var bits = Task17EAC3BitWriter()
        bits.write(0x0B77, count: 16)
        bits.write(0, count: 2)
        bits.write(0, count: 3)
        bits.write(UInt64(byteCount / 2 - 1), count: 11)
        bits.write(0, count: 2)
        bits.write(UInt64([1: 0, 2: 1, 3: 2, 6: 3][blockCount]!), count: 2)
        bits.write(2, count: 3)
        bits.write(0, count: 1)
        bits.write(16, count: 5)
        bits.write(0, count: 5)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(1, count: 1)
        bits.write(0, count: 3)
        bits.write(0, count: 1)
        bits.write(1, count: 1)
        bits.write(0, count: 2)
        bits.write(0, count: 2)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        if blockCount < 6 { bits.write(convsync == true ? 1 : 0, count: 1) }
        bits.write(0, count: 1)
        return bits.data(paddedTo: byteCount)
    }
}

private struct Task22VideoBitWriter {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: UInt64, _ count: Int) {
        for offset in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8((value >> UInt64(offset)) & 1)
                << UInt8(7 - bitCount % 8)
            bitCount += 1
        }
    }

    mutating func writeUE(_ value: UInt32) {
        let code = UInt64(value) + 1
        let width = 64 - code.leadingZeroBitCount
        if width > 1 { write(0, width - 1) }
        write(code, width)
    }

    mutating func writeSE(_ value: Int32) {
        let code = value <= 0 ? UInt32(-value) * 2 : UInt32(value) * 2 - 1
        writeUE(code)
    }

    mutating func finishRBSP() -> Data {
        write(1, 1)
        while !bitCount.isMultiple(of: 8) { write(0, 1) }
        return Data(bytes)
    }

    static func escape(_ rbsp: Data) -> Data {
        var result = Data()
        var zeroCount = 0
        for byte in rbsp {
            if zeroCount >= 2, byte <= 3 {
                result.append(3)
                zeroCount = 0
            }
            result.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return result
    }
}

private struct Task17EAC3BitWriter {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: UInt64, count: Int) {
        for offset in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8((value >> UInt64(offset)) & 1) << UInt8(7 - bitCount % 8)
            bitCount += 1
        }
    }

    func data(paddedTo byteCount: Int) -> Data {
        Data(bytes + Array(repeating: 0, count: byteCount - bytes.count))
    }
}
