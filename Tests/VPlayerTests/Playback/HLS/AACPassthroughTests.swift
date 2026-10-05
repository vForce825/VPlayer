// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class AACPassthroughTests: XCTestCase {
    func testChargedRawLCPreservesRateLayoutASCAndActualPayload() throws {
        for (rate, frequency) in [(44_100, 4), (48_000, 3)] {
            for (channels, config, mask) in [(1, 1, UInt64(4)), (2, 2, UInt64(3)), (6, 6, UInt64(0x3F))] {
                let asc = Self.asc(frequency: frequency, channelConfiguration: config)
                let copies = Self.copies()
                let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
                _ = try timeline.consume(.tracks(Self.tracks(rate: rate, channels: channels, mask: mask, asc: asc)))
                let payload = Data([0x21, 0x10, 0x56, 0xE5])
                let unit = try Self.unit(timeline.consume(.packet(Self.packet(payload, rate: rate))))
                let proof = try XCTUnwrap(unit.source.sourceProof)
                XCTAssertEqual(unit.source.payload, payload)
                XCTAssertEqual(proof.decoderConfiguration, asc)
                XCTAssertEqual(proof.format.sampleRate, Int32(rate))
                XCTAssertEqual(proof.sourceLayout.nativeMask, mask)
                XCTAssertEqual(unit.timing.presentationTimeStamp, .init(value: 10, timescale: 1))
                XCTAssertEqual(unit.timing.duration, .init(value: 1_024, timescale: Int32(rate)))
                XCTAssertTrue(unit.validatesSourceMapping())
                XCTAssertFalse(proof.stream.isDrained(throughFrameID: unit.source.id))
                _ = try timeline.consume(.endOfStream)
                XCTAssertTrue(proof.stream.isDrained(throughFrameID: unit.source.id))
                XCTAssertTrue(unit.validatesSourceMapping(), "Real EOF retains finished callback authority")
                timeline.retireCompressedGeneration()
                XCTAssertFalse(unit.validatesSourceMapping())
            }
        }
    }

    func testSplitADTSAndMultipleFramesRetainActualAUBytes() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks(asc: Data())))
        let payload = Data([0x21, 0x10, 0x56, 0xE5])
        let framed = Self.adts(payload)
        XCTAssertTrue(try timeline.consume(.packet(Self.packet(Data(framed.prefix(5))))).isEmpty)
        let events = try timeline.consume(.packet(Self.packet(Data(framed.dropFirst(5)) + framed, withoutPTS: true)))
        let units = events.compactMap { if case let .audioSample(unit) = $0 { unit } else { nil } }
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units.map(\.source.payload), [payload, payload])
        XCTAssertEqual(units.map { $0.source.sourceProof?.decoderConfiguration }, [Data([0x11, 0x90]), Data([0x11, 0x90])])
        XCTAssertTrue(units.allSatisfy { $0.validatesSourceMapping() })
        XCTAssertEqual(units[1].timing.presentationTimeStamp,
                       try units[0].timing.presentationTimeStamp.adding(.init(value: 1_024, timescale: 48_000)))
    }

    func testCallerCreatedTimedFrameCannotAcquireOpaqueMapping() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks()))
        let original = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21])))))
        let copied = HLSTimedAudioAccessUnit(source: original.source, generation: original.generation,
            timing: original.timing, boundaryDecision: original.boundaryDecision)
        XCTAssertNil(copied.sourceMappingIdentity)
        XCTAssertFalse(copied.validatesSourceMapping())
        let tampered = CompressedAudioFrame(id: original.source.id, payload: Data([0x22]), codec: .aac,
            generation: original.source.generation, presentationTimeStamp: original.source.presentationTimeStamp,
            duration: original.source.duration, frameSampleCount: 1_024,
            sourceProof: try XCTUnwrap(original.source.sourceProof))
        XCTAssertFalse(try XCTUnwrap(original.source.sourceProof).validates(tampered))
    }

    func testUnchargedLegacyInputHasNoProofOrMapping() throws {
        let timeline = HLSTimelineCoordinator()
        _ = try timeline.consume(.tracks(Self.tracks()))
        let unit = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21])))))
        XCTAssertNil(unit.source.sourceProof)
        XCTAssertNil(unit.sourceMappingIdentity)
        XCTAssertFalse(unit.validatesSourceMapping())
    }

    func testRejectedFinalADTSFrameCannotSealSourceEOF() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks(asc: Data())))
        let unit = try Self.unit(timeline.consume(.packet(Self.packet(Self.adts(Data([0x21]))))))
        let proof = try XCTUnwrap(unit.source.sourceProof)
        _ = try timeline.consume(.packet(Self.packet(Data([0xFF, 0xF1]), pts: 481_024)))
        _ = try timeline.consume(.endOfStream)
        XCTAssertFalse(proof.stream.isDrained(throughFrameID: unit.source.id))
        XCTAssertFalse(unit.validatesSourceMapping())
    }

    func testUnsealedCompatibilityFrameKeepsChargedBackingUntilLastAlias() throws {
        let copies = Self.copies()
        var timeline: HLSTimelineCoordinator? = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline!.consume(.tracks(Self.tracks(asc: Data([0x2B, 0x11, 0x88, 0x00]))))
        var retained: HLSTimedAudioAccessUnit? = try Self.unit(timeline!.consume(.packet(Self.packet(Data([0x21])))))
        XCTAssertNil(retained?.source.sourceProof)
        XCTAssertNil(retained?.sourceMappingIdentity)
        timeline!.retireCompressedGeneration()
        timeline = nil
        copies.cancel()
        withExtendedLifetime(retained) { XCTAssertGreaterThan(copies.framing.usage.bytes, 0) }
        var alias = retained
        retained = nil
        withExtendedLifetime(alias) { XCTAssertGreaterThan(copies.framing.usage.bytes, 0) }
        alias = nil
        XCTAssertEqual(copies.framing.usage.bytes, 0)
    }

    func testSourceConfigurationPreservesZeroVersusUnsignaledAndRejectsNonzeroBeforeClaim() throws {
        for priming: HLSSourceAudioPriming in [.notSignaledPreserveTimestamps,
            .explicit(leadingSamples: 0, trailingSamples: 0)] {
            let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
            _ = try timeline.consume(.tracks(Self.tracks()))
            let unit = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21])))))
            let configuration = try SourceAACWriterConfiguration(first: unit,
                source: Self.facts(priming: priming), binding: Self.binding())
            XCTAssertEqual(configuration.priming, priming)
            XCTAssertEqual(configuration.audioSpecificConfig, Data([0x11, 0x90]))
            XCTAssertTrue(configuration.validates(unit))
            XCTAssertThrowsError(try SourceAACWriterConfiguration(first: unit,
                source: Self.facts(priming: priming), binding: Self.binding()))
        }
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks()))
        let unit = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21])))))
        for priming: HLSSourceAudioPriming in [.unknown, .explicit(leadingSamples: 2_112, trailingSamples: 0),
            .explicit(leadingSamples: 0, trailingSamples: 512)] {
            XCTAssertThrowsError(try SourceAACWriterConfiguration(first: unit,
                source: Self.facts(priming: priming), binding: Self.binding()))
        }
        // Failed preflight did not consume the source's one real rendition slot.
        _ = try SourceAACWriterConfiguration(first: unit, source: Self.facts(), binding: Self.binding())
    }

    func testSourceSubmissionRejectsCopiedTimingAndReplayedClaim() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks()))
        let unit = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21])))))
        let config = try SourceAACWriterConfiguration(first: unit, source: Self.facts(), binding: Self.binding())
        let fabricated = HLSTimedAudioAccessUnit(source: unit.source, generation: unit.generation,
            timing: unit.timing, boundaryDecision: unit.boundaryDecision)
        XCTAssertThrowsError(try SourceAACAccessUnit(timed: fabricated, configuration: config, binding: Self.binding()))
        let submission = try SourceAACAccessUnit(timed: unit, configuration: config, binding: Self.binding())
        XCTAssertEqual(submission.payload, unit.source.payload)
        XCTAssertTrue(submission.claimForAppend())
        XCTAssertFalse(submission.claimForAppend())
    }

    func testSourceAACInitializationChecksExactASCAndPreservesMonoAndMultichannel() throws {
        for (channels, config, mask) in [(1, 1, UInt64(4)), (6, 6, UInt64(0x3F))] {
            let asc = Self.asc(frequency: 4, channelConfiguration: config)
            let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
            _ = try timeline.consume(.tracks(Self.tracks(rate: 44_100, channels: channels, mask: mask, asc: asc)))
            let unit = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21]), rate: 44_100))))
            let facts = HLSSourceAudioFacts(codec: .aac, profile: 1, sampleRate: 44_100,
                channelCount: Int32(channels), channelMask: mask, decoderConfiguration: asc,
                priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true)
            let configuration = try SourceAACWriterConfiguration(first: unit, source: facts, binding: Self.binding())
            let cookie = try AudioSpecificConfig.parse(asc).coreAudioMagicCookie
            let bytes = CompressedAudioInitializationTests.initialization(entry: "mp4a",
                children: CompressedAudioInitializationTests.box("esds", Data(repeating: 0, count: 4) + cookie),
                timescale: 44_100)
            XCTAssertEqual(try SourceAACInitializationEvidence.validate(bytes,
                configuration: configuration).timescale, 44_100)
            let other = try AudioSpecificConfig.parse(Data([0x11, 0x90])).coreAudioMagicCookie
            XCTAssertThrowsError(try SourceAACInitializationEvidence.validate(
                CompressedAudioInitializationTests.initialization(entry: "mp4a",
                    children: CompressedAudioInitializationTests.box("esds", Data(repeating: 0, count: 4) + other)),
                configuration: configuration)) { error in
                XCTAssertEqual(error as? CompressedAudioInitializationRejection, .invalidConfiguration)
            }
        }
    }

    func testSourceAACFragmentInspectionCoversSixSecondAndBoundaryCounts() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks()))
        let unit = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21])))))
        let configuration = try SourceAACWriterConfiguration(first: unit, source: Self.facts(), binding: Self.binding())
        let cookie = try AudioSpecificConfig.parse(Data([0x11, 0x90])).coreAudioMagicCookie
        let initialization = CompressedAudioInitializationTests.initialization(entry: "mp4a",
            children: CompressedAudioInitializationTests.box("esds", Data(repeating: 0, count: 4) + cookie))
        for count in [255, 256, 259, 282, 319, 320] {
            let ledger = HLSDeliveryApplicationChargeLedger()
            var inspection: SourceAACFragmentInspection? = try FMP4CompressedAudioInspection.sourceAACFragment(
                initialization: initialization, media: Self.fragment(sampleCount: count), configuration: configuration,
                expectedDuration: .init(value: Int64(count * 1_024), timescale: 48_000), applicationLedger: ledger)
            XCTAssertEqual(inspection?.sampleCount, count)
            XCTAssertEqual(inspection?.sample(at: count - 1)?.decodeOrdinal, UInt16(count - 1))
            XCTAssertGreaterThan(ledger.chargedBytes, 0)
            inspection = nil
            XCTAssertEqual(ledger.chargedBytes, 0)
        }
        XCTAssertThrowsError(try FMP4CompressedAudioInspection.sourceAACFragment(initialization: initialization,
            media: Self.fragment(sampleCount: 321), configuration: configuration,
            expectedDuration: .init(value: 321 * 1_024, timescale: 48_000)))
        timeline.retireCompressedGeneration()
        XCTAssertThrowsError(try FMP4CompressedAudioInspection.sourceAACFragment(initialization: initialization,
            media: Self.fragment(sampleCount: 47), configuration: configuration,
            expectedDuration: .init(value: 47 * 1_024, timescale: 48_000)))
    }

    private static func fragment(sampleCount: Int) -> Data {
        func u32(_ value: UInt32) -> Data { CompressedAudioInitializationTests.u32(value) }
        func box(_ type: String, _ data: Data) -> Data { CompressedAudioInitializationTests.box(type, data) }
        let header = box("tfhd", u32(0x020018) + u32(1) + u32(1_024) + u32(1))
        let decode = box("tfdt", u32(0x01000000) + u32(0) + u32(0))
        let sequence = box("mfhd", u32(0) + u32(1))
        func movie(offset: UInt32) -> Data {
            box("moof", sequence + box("traf", header + decode + box("trun", u32(1) + u32(UInt32(sampleCount)) + u32(offset))))
        }
        return movie(offset: UInt32(movie(offset: 0).count + 8)) + box("mdat", Data(repeating: 0x21, count: sampleCount))
    }

    func testPreappendCompatibilityFallbackKeepsPartialFramerAndPaidNextAU() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks(asc: Data())))
        let next = Self.adts(Data([0x22]))
        let first = try Self.unit(timeline.consume(.packet(Self.packet(Self.adts(Data([0x21])) + Data(next.prefix(5))))))
        let configuration = try SourceAACWriterConfiguration(first: first, source: Self.facts(), binding: Self.binding())
        try timeline.useCompatibleAudioBeforeSourceAppend()
        XCTAssertFalse(configuration.validates(first))
        let fallback = try Self.unit(timeline.consume(.packet(Self.packet(Data(next.dropFirst(5)), withoutPTS: true))))
        XCTAssertEqual(fallback.source.payload, Data([0x22]))
        XCTAssertEqual(fallback.source.id, first.source.id + 1)
        XCTAssertEqual(fallback.timing.presentationTimeStamp,
                       try first.timing.presentationTimeStamp.adding(.init(value: 1_024, timescale: 48_000)))
        XCTAssertNil(fallback.source.sourceProof)
        XCTAssertNil(fallback.sourceMappingIdentity)
    }

    func testClaimedSourceCannotBeReclassifiedAsPreappendFallback() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.tracks()))
        let unit = try Self.unit(timeline.consume(.packet(Self.packet(Data([0x21])))))
        let config = try SourceAACWriterConfiguration(first: unit, source: Self.facts(), binding: Self.binding())
        let submission = try SourceAACAccessUnit(timed: unit, configuration: config, binding: Self.binding())
        XCTAssertTrue(submission.claimForAppend())
        XCTAssertThrowsError(try timeline.useCompatibleAudioBeforeSourceAppend())
        XCTAssertTrue(config.validates(unit))
    }

    func testFramingCapacityAndCancellationPropagateInsteadOfDecodeBreakOrWaiting() throws {
        let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 8_192,
            maximumPCMBytes: 8_192, capacity: 8)
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline.consume(.tracks(Self.tracks()))
        var held: [HLSDataPlaneAdmission.Lease] = []
        for _ in 0..<8 { held.append(try XCTUnwrap(copies.framing.acquire(bytes: 1))) }
        XCTAssertThrowsError(try timeline.consume(.packet(Self.packet(Data([0x21]))))) { error in
            XCTAssertEqual(error as? HLSAudioCopyAdmissionFailure, .capacityExceeded)
        }
        XCTAssertEqual(copies.framing.usage.count, 8)
        held.forEach { $0.release() }; held.removeAll()
        timeline.retireCompressedGeneration()
        XCTAssertEqual(copies.framing.usage.bytes, 0)

        let cancelled = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try cancelled.consume(.tracks(Self.tracks()))
        copies.cancel()
        XCTAssertThrowsError(try cancelled.consume(.packet(Self.packet(Data([0x21]))))) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSourceMetadataCapacityDoesNotBecomeCodecRejection() throws {
        let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 2_048,
            maximumPCMBytes: 8_192, capacity: 8)
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline.consume(.tracks(Self.tracks()))
        XCTAssertThrowsError(try timeline.consume(.packet(Self.packet(Data([0x21]))))) { error in
            XCTAssertEqual(error as? HLSAudioCopyAdmissionFailure, .capacityExceeded)
        }
        timeline.retireCompressedGeneration()
        XCTAssertEqual(copies.compressedInput.usage.bytes, 0)
        XCTAssertEqual(copies.framing.usage.bytes, 0)
    }

    func testRetirementReleasesUnclaimedSourceStreamWhileTimelineRemainsAlive() throws {
        let copies = Self.copies()
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline.consume(.tracks(Self.tracks()))
        XCTAssertEqual(copies.compressedInput.usage.bytes, 2_048)

        timeline.retireCompressedGeneration()

        withExtendedLifetime(timeline) {
            XCTAssertEqual(copies.compressedInput.usage.bytes, 0,
                "An assembler's generation callback must not retain its owning generation")
            XCTAssertEqual(copies.framing.usage.bytes, 0)
        }
    }

    func testRetirementKeepsSourceStreamChargeUntilLastAccessUnitAlias() throws {
        let copies = Self.copies()
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline.consume(.tracks(Self.tracks()))
        var unit: HLSTimedAudioAccessUnit? = try Self.unit(
            timeline.consume(.packet(Self.packet(Data([0x21])))))
        var alias = unit
        let stream = TestWeakReference(unit?.source.sourceProof?.stream)
        XCTAssertNotNil(stream.value)
        let charged = copies.compressedInput.usage.bytes
        XCTAssertGreaterThan(charged, 2_048)

        timeline.retireCompressedGeneration()
        XCTAssertFalse(try XCTUnwrap(unit).validatesSourceMapping())
        withExtendedLifetime(unit) { XCTAssertEqual(copies.compressedInput.usage.bytes, charged) }
        unit = nil
        withExtendedLifetime(alias) { XCTAssertEqual(copies.compressedInput.usage.bytes, charged) }
        alias = nil

        XCTAssertNil(stream.value)
        XCTAssertEqual(copies.compressedInput.usage.bytes, 0)
        XCTAssertEqual(copies.framing.usage.bytes, 0)
        withExtendedLifetime(timeline) {}
    }

    private static func facts(priming: HLSSourceAudioPriming = .notSignaledPreserveTimestamps) -> HLSSourceAudioFacts {
        .init(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2, channelMask: 3,
            decoderConfiguration: Data([0x11, 0x90]), priming: priming,
            service: .independentMain, formatValidated: true)
    }
    private static func binding() -> FMP4WriterBinding {
        .init(outputLifecycleEpoch: .init(backendIdentity: .init(
                sessionIdentity: .init(sessionID: 1,
                    requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                backendGeneration: 1), outputNonce: 1), itemGeneration: .init(rawValue: 2),
            mediaEpoch: .init(rawValue: 3), publicationParticipantID: .init(rawValue: 4),
            renditionIdentity: .init(rawValue: 5), writerIdentity: .init(rawValue: 6))
    }

    private static func copies() -> HLSAudioCopyOwnership {
        .init(maximumCompressedBytes: 1_048_576, maximumPCMBytes: 8_388_608, capacity: 64)
    }
    private static func asc(frequency: Int, channelConfiguration: Int) -> Data {
        Data([UInt8(16 | frequency >> 1), UInt8((frequency & 1) << 7 | channelConfiguration << 3)])
    }
    private static func tracks(rate: Int = 48_000, channels: Int = 2,
                               mask: UInt64 = 3, asc: Data = Data([0x11, 0x90])) -> DemuxTrackSet {
        .init(selectedProgramID: nil, video: nil, audio: .init(streamIndex: 1, codec: .aac,
            timeBase: MediaRational(num: 1, den: Int32(rate))!, sampleRate: Int32(rate),
            channelLayout: .init(channelCount: Int32(channels), nativeMask: mask), extradata: asc))
    }
    private static func packet(_ data: Data, rate: Int = 48_000, pts: Int64? = nil, withoutPTS: Bool = false) -> DemuxPacket {
        .init(streamIndex: 1, codec: .audio(.aac), data: data,
            presentationTimeStamp: withoutPTS ? .invalid : CMTime(value: pts ?? Int64(rate * 10), timescale: Int32(rate)),
            decodeTimeStamp: .invalid, duration: .invalid, isKey: true, isCorrupt: false)
    }
    private static func unit(_ events: [HLSTimelineEvent]) throws -> HLSTimedAudioAccessUnit {
        try XCTUnwrap(events.compactMap { if case let .audioSample(unit) = $0 { unit } else { nil } }.first)
    }
    private static func adts(_ payload: Data) -> Data {
        let length = payload.count + 7
        return Data([0xFF, 0xF1, 0x4C, UInt8(0x80 | length >> 11),
                     UInt8(length >> 3), UInt8((length & 7) << 5 | 0x1F), 0xFC]) + payload
    }
}
