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

    func testTransportQuantizedADTSKeepsRawMappingAndWritesExact44100Cadence() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.clockTracks()))
        let first = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 0))))
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: Self.clockFacts(), binding: Self.binding())
        for index in 0..<1_292 {
            // A fixed quantization phase, including zero PTS reduced to scale 1.
            let ticks = (Int64(index) * 102_400 + 33) / 49
            let timed = index == 0 ? first : try Self.unit(
                timeline.consume(.packet(Self.clockPacket(pts: ticks))))
            XCTAssertEqual(CMTimeCompare(timed.source.presentationTimeStamp,
                CMTime(value: ticks, timescale: 90_000)), 0)
            XCTAssertEqual(timed.timing.presentationTimeStamp,
                try ExactMediaTime(value: 10, timescale: 1).adding(.init(value: ticks, timescale: 90_000)))
            XCTAssertTrue(timed.validatesSourceMapping())
            let unit = try SourceAACAccessUnit(timed: timed, configuration: configuration, binding: Self.binding())
            XCTAssertEqual(unit.presentationStart,
                try configuration.firstPresentationTime.adding(.init(value: Int64(index) * 1_024, timescale: 44_100)))
            XCTAssertEqual(unit.duration, .init(value: 1_024, timescale: 44_100))
            XCTAssertEqual(unit.payload, Data([0x21, 0x10, 0x56, 0xE5]))
            // Preparing/retrying an unclaimed AU must not advance its producer clock.
            XCTAssertEqual(try SourceAACAccessUnit(timed: timed, configuration: configuration,
                binding: Self.binding()).presentationStart, unit.presentationStart)
        }
        _ = try timeline.consume(.endOfStream)
        XCTAssertTrue(first.validatesSourceMapping(), "Clean EOF keeps delayed source proofs current")
    }

    func testFirstWriterAUUsesItsPairedCanonicalOriginAfterEarlierAudioWasDiscarded() throws {
        let factory = ScriptedFFmpegParserFactory { handle, _, bytes, pts, dts, _ in
            try handle.emit(FFmpegParsedFrame(bytes: bytes, pts: pts, dts: dts,
                duration: CMTime(value: 3_000, timescale: 90_000),
                fieldOrder: Int32(CodedFieldOrder.progressive.rawValue),
                pictureStructure: Int32(PictureStructure.frame.rawValue), keyFrame: true,
                repeatPicture: false, topFieldFirst: nil, interlaced: false,
                sampleRate: 0, channels: 0, frameSamples: 0, channelLayout: nil))
        }
        let timeline = HLSTimelineCoordinator(parserFactory: factory, hlsAudioCopyOwnership: Self.copies())
        let video = VideoTrackDescriptor(streamIndex: 7, codec: .hevc,
            timeBase: MediaRational(num: 1, den: 90_000)!, width: 1_920, height: 1_080,
            videoDelay: 0, extradata: Data(), frameRate: MediaRational(num: 30, den: 1), fieldOrder: .unknown)
        _ = try timeline.consume(.tracks(.init(selectedProgramID: nil, video: video, audio: Self.clockTracks().audio)))
        for index in 0...16 {
            _ = try timeline.consume(.packet(Self.clockPacket(pts: (Int64(index) * 102_400 + 33) / 49)))
        }
        var emitted: [HLSTimelineEvent] = []
        for index in 0..<8 {
            let bytes = AssemblerTestFixtures.hevcAccessUnit(includeParameterSets: index == 0,
                nal: Data([index == 7 ? 0x26 : 0x02, 1, 0x80]))
            emitted = try timeline.consume(.packet(.init(streamIndex: 7, codec: .video(.hevc), data: bytes,
                presentationTimeStamp: CMTime(value: index == 7 ? 33_437 : Int64(index) * 3_000, timescale: 90_000),
                decodeTimeStamp: .invalid, duration: .invalid, isKey: index == 7, isCorrupt: false)))
        }
        let first = try Self.unit(emitted)
        XCTAssertEqual(first.source.id, 17)
        XCTAssertEqual(first.boundaryDecision, .unchanged)
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: Self.clockFacts(), binding: Self.binding())
        XCTAssertNotEqual(configuration.firstCanonicalSourceTime, try ExactMediaTime(first.source.presentationTimeStamp))
        XCTAssertEqual(try SourceAACAccessUnit(timed: first, configuration: configuration,
            binding: Self.binding()).presentationStart, configuration.firstPresentationTime)
        let second = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 35_527))))
        XCTAssertEqual(try SourceAACAccessUnit(timed: second, configuration: configuration,
            binding: Self.binding()).presentationStart,
            try configuration.firstPresentationTime.adding(.init(value: 1_024, timescale: 44_100)))
    }

    func testQuantizedClockKeepsAuthenticatedMissingPTSContinuation() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.clockTracks()))
        let first = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 0))))
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: Self.clockFacts(), binding: Self.binding())
        let continued = try Self.unit(timeline.consume(.packet(Self.packet(
            Self.adts(Data([0x22]), frequency: 4), rate: 44_100, withoutPTS: true))))
        let explicit = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 4_180))))
        for (index, timed) in [continued, explicit].enumerated() {
            XCTAssertEqual(try SourceAACAccessUnit(timed: timed, configuration: configuration,
                binding: Self.binding()).presentationStart,
                try configuration.firstPresentationTime.adding(.init(value: Int64(index + 1) * 1_024, timescale: 44_100)))
        }
    }

    func testQuantizedClockRejectsOneTickPhaseSpanWithoutDroppingRawAU() throws {
        let ticks = (0..<49).map { (Int64($0) * 102_400 + 48) / 49 } + [102_401]
        try Self.assertClockFailure(ticks)
    }

    func testQuantizedClockRejectsPCMSampleAndWholeAUGapsAndOverlaps() throws {
        for ticks: [Int64] in [[0, 2_092], [0, 2_088], [0, 4_180], [0, 0], [0, 2_090, 2_090]] {
            try Self.assertClockFailure(ticks)
        }
    }

    func testQuantizedClockRejectsSlowDriftAndInconsistentAlternatingPhase() throws {
        // Each endpoint individually fits within one tick of the initial anchor,
        // but the last observation has no common phase with the earlier minimum.
        try Self.assertClockFailure([0, 2_090, 4_179, 6_270])
        let drift = (0..<21).map { (Int64($0) * 102_400 + 48) / 49 + Int64($0 / 20) }
        try Self.assertClockFailure(drift)
    }

    func testCorrectionDoesNotExpandToRawAACOtherRatesOrOtherSourceClocks() throws {
        try Self.assertClockFailure([0, 2_090], rawAAC: true)
        try Self.assertClockFailure([0, 1_025], timeScale: 44_100)
        try Self.assertClockFailure([0, 20_900], timeScale: 900_000)
        try Self.assertClockFailure([0, 1_921], rate: 48_000)
        for (rate, scale, ticks, raw): (Int32, Int32, [Int64], Bool) in [
            (48_000, 48_000, [0, 1_024], true),
            (48_000, 90_000, [0, 1_920], false),
            (44_100, 44_100, [0, 1_024], true),
        ] {
            let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
            _ = try timeline.consume(.tracks(Self.clockTracks(rate: rate, timeScale: scale, rawAAC: raw)))
            let first = try Self.unit(timeline.consume(.packet(Self.clockPacket(
                pts: ticks[0], rate: rate, timeScale: scale, rawAAC: raw))))
            let configuration = try SourceAACWriterConfiguration(first: first,
                source: Self.clockFacts(rate: rate), binding: Self.binding())
            let second = try Self.unit(timeline.consume(.packet(Self.clockPacket(
                pts: ticks[1], rate: rate, timeScale: scale, rawAAC: raw))))
            let unit = try SourceAACAccessUnit(timed: second, configuration: configuration, binding: Self.binding())
            XCTAssertEqual(unit.presentationStart,
                try configuration.firstPresentationTime.adding(.init(value: 1_024, timescale: rate)))
        }
    }

    func testQuantizedClockFallbackKeepsQueuedAndSubsequentObservedTimestamps() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.clockTracks()))
        let first = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 0))))
        let queued = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 2_090))))
        try timeline.useCompatibleAudioBeforeSourceAppend()
        XCTAssertFalse(first.validatesSourceMapping())
        XCTAssertFalse(queued.validatesSourceMapping())
        XCTAssertEqual(CMTimeCompare(queued.source.presentationTimeStamp,
            CMTime(value: 2_090, timescale: 90_000)), 0)
        let next = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 4_180))))
        XCTAssertNil(next.source.sourceProof)
        XCTAssertEqual(CMTimeCompare(next.source.presentationTimeStamp,
            CMTime(value: 4_180, timescale: 90_000)), 0)
        XCTAssertEqual(next.timing.presentationTimeStamp,
            try ExactMediaTime(value: 10, timescale: 1).adding(.init(value: 4_180, timescale: 90_000)))
    }

    func testUnchargedHDMIAssemblyKeepsQuantizedSourceTiming() throws {
        let timeline = HLSTimelineCoordinator()
        _ = try timeline.consume(.tracks(Self.clockTracks()))
        _ = try timeline.consume(.packet(Self.clockPacket(pts: 0)))
        let second = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 2_090))))
        XCTAssertNil(second.source.sourceProof)
        XCTAssertEqual(CMTimeCompare(second.source.presentationTimeStamp,
            CMTime(value: 2_090, timescale: 90_000)), 0)
    }

    func testQuantizedClockRestartsOnlyWithANewTimelineGeneration() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        let tracks = Self.clockTracks()
        _ = try timeline.consume(.tracks(tracks))
        let old = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 0))))
        _ = try timeline.consume(.packet(Self.clockPacket(pts: 2_090)))
        _ = try timeline.consume(.discontinuity(tracks, reason: .timelineReset))
        XCTAssertFalse(old.validatesSourceMapping())
        let first = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 90_000))))
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: Self.clockFacts(), binding: Self.binding())
        let second = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 92_090))))
        XCTAssertNotEqual(first.generation, old.generation)
        XCTAssertEqual(try SourceAACAccessUnit(timed: second, configuration: configuration,
            binding: Self.binding()).presentationStart,
            try configuration.firstPresentationTime.adding(.init(value: 1_024, timescale: 44_100)))
    }

    func testFormatChangeAndCancellationFenceQuantizedSourceProofs() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.clockTracks()))
        let old = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 0))))
        _ = try timeline.consume(.packet(Self.clockPacket(pts: 2_090)))
        _ = try timeline.consume(.discontinuity(Self.clockTracks(rate: 48_000), reason: .formatChange))
        XCTAssertFalse(old.validatesSourceMapping())
        let first = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 90_000, rate: 48_000))))
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: Self.clockFacts(rate: 48_000), binding: Self.binding())
        let second = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 91_920, rate: 48_000))))
        XCTAssertEqual(try SourceAACAccessUnit(timed: second, configuration: configuration,
            binding: Self.binding()).presentationStart,
            try configuration.firstPresentationTime.adding(.init(value: 1_024, timescale: 48_000)))
        _ = try timeline.consume(.cancelled)
        XCTAssertFalse(first.validatesSourceMapping())
        XCTAssertFalse(second.validatesSourceMapping())
        XCTAssertThrowsError(try SourceAACAccessUnit(timed: second, configuration: configuration, binding: Self.binding()))
    }

    func testInvalidAACCannotAcquireCadenceOrSealAnEarlierProof() throws {
        for invalidKind in 0..<6 {
            let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
            _ = try timeline.consume(.tracks(Self.clockTracks()))
            let first = try Self.unit(timeline.consume(.packet(Self.clockPacket(pts: 0))))
            var data = Self.adts(Data([0x21]), frequency: 4)
            if invalidKind == 0 { data[2] = 0x90 } // Non-LC profile.
            if invalidKind == 1 { data[6] |= 1 } // Multiple raw data blocks.
            if invalidKind == 2 { data = Data(data.prefix(5)) } // Incomplete final AU.
            if invalidKind == 4 { data[2] = 0x4C } // Unexpected sample rate.
            if invalidKind == 5 { data[3] = 0x40 } // Unexpected channel layout.
            _ = try timeline.consume(.packet(Self.clockPacket(pts: 2_090,
                corrupt: invalidKind == 3, data: data)))
            _ = try timeline.consume(.endOfStream)
            XCTAssertFalse(first.validatesSourceMapping())
            XCTAssertFalse(try XCTUnwrap(first.source.sourceProof).stream.isDrained(throughFrameID: first.source.id))
        }
    }

    func testAbsentInitialTimestampCannotInventACadenceAnchor() throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: Self.copies())
        _ = try timeline.consume(.tracks(Self.clockTracks()))
        XCTAssertThrowsError(try timeline.consume(.packet(Self.packet(
            Self.adts(Data([0x21]), frequency: 4), rate: 44_100, withoutPTS: true))))
    }

    private static func assertClockFailure(_ ticks: [Int64], rate: Int32 = 44_100,
        timeScale: Int32 = 90_000, rawAAC: Bool = false,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies())
        _ = try timeline.consume(.tracks(clockTracks(rate: rate, timeScale: timeScale, rawAAC: rawAAC)))
        let first = try unit(timeline.consume(.packet(clockPacket(pts: ticks[0], rate: rate,
            timeScale: timeScale, rawAAC: rawAAC))))
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: clockFacts(rate: rate), binding: binding())
        for (index, pts) in ticks.dropFirst().enumerated() {
            let timed = try unit(timeline.consume(.packet(clockPacket(pts: pts, rate: rate,
                timeScale: timeScale, rawAAC: rawAAC))))
            XCTAssertEqual(CMTimeCompare(timed.source.presentationTimeStamp,
                CMTime(value: pts, timescale: timeScale)), 0, file: file, line: line)
            XCTAssertEqual(timed.source.payload, Data([0x21, 0x10, 0x56, 0xE5]), file: file, line: line)
            if index == ticks.count - 2 {
                XCTAssertNil(timed.source.sourceProof, file: file, line: line)
                XCTAssertThrowsError(try SourceAACAccessUnit(timed: timed, configuration: configuration,
                    binding: binding()), file: file, line: line)
            } else {
                XCTAssertNotNil(timed.source.sourceProof, file: file, line: line)
            }
        }
        XCTAssertFalse(first.validatesSourceMapping(), file: file, line: line)
        let afterFailure = try unit(timeline.consume(.packet(clockPacket(
            pts: ticks.last! + 3_000, rate: rate, timeScale: timeScale, rawAAC: rawAAC))))
        XCTAssertNil(afterFailure.source.sourceProof, "A poisoned clock cannot restart in the same source", file: file, line: line)
        XCTAssertEqual(afterFailure.source.payload, Data([0x21, 0x10, 0x56, 0xE5]), file: file, line: line)
        _ = try timeline.consume(.endOfStream)
        XCTAssertFalse(try XCTUnwrap(first.source.sourceProof).stream.isDrained(throughFrameID: first.source.id),
            file: file, line: line)
    }

    private static func clockTracks(rate: Int32 = 44_100, timeScale: Int32 = 90_000,
        rawAAC: Bool = false) -> DemuxTrackSet {
        .init(selectedProgramID: nil, video: nil, audio: .init(streamIndex: 1, codec: .aac,
            timeBase: MediaRational(num: 1, den: timeScale)!, sampleRate: rate,
            channelLayout: .init(channelCount: 2, nativeMask: 3),
            extradata: rawAAC ? clockFacts(rate: rate).decoderConfiguration : Data()))
    }
    private static func clockFacts(rate: Int32 = 44_100) -> HLSSourceAudioFacts {
        .init(codec: .aac, profile: 1, sampleRate: rate, channelCount: 2, channelMask: 3,
            decoderConfiguration: asc(frequency: rate == 44_100 ? 4 : 3, channelConfiguration: 2),
            priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true)
    }
    private static func clockPacket(pts: Int64, rate: Int32 = 44_100, timeScale: Int32 = 90_000,
        rawAAC: Bool = false, corrupt: Bool = false, data: Data? = nil) -> DemuxPacket {
        let payload = Data([0x21, 0x10, 0x56, 0xE5])
        return .init(streamIndex: 1, codec: .audio(.aac),
            data: data ?? (rawAAC ? payload : adts(payload, frequency: rate == 44_100 ? 4 : 3)),
            presentationTimeStamp: CMTime(value: pts, timescale: timeScale), decodeTimeStamp: .invalid,
            duration: .invalid, isKey: true, isCorrupt: corrupt)
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
    private static func adts(_ payload: Data, frequency: UInt8 = 3) -> Data {
        let length = payload.count + 7
        return Data([0xFF, 0xF1, 0x40 | frequency << 2, UInt8(0x80 | length >> 11),
                     UInt8(length >> 3), UInt8((length & 7) << 5 | 0x1F), 0xFC]) + payload
    }
}
