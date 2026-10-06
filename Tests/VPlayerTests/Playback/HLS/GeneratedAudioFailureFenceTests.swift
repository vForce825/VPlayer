// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class GeneratedAudioFailureFenceTests: XCTestCase {
    func testSameFormatAACAndDolbyDiscontinuityUsesOneOwnedGenerationRecovery() async throws {
        for codec: AudioCodec in [.aac, .ac3, .eac3] {
            let context = try GeneratedAudioTestContext(codec: codec) { true }
            let executor = PlaybackControlExecutor(allocator: PlaybackIdentityAllocator(),
                applyIngress: { _ in .applied }, applyTerminalIngress: { _ in },
                applyOutputControl: { _, _ in .rejected })
            let graph = try SystemHLSMediaGraphAuthority(lifecycle: context.lifecycle,
                generatedSource: context, sharedControlExecutor: executor)
            let ingress = HLSDataPlaneAdmission(capacity: 3, maximumBytes: 4_096)
            let tracks = DemuxTrackSet(selectedProgramID: nil, video: nil,
                audio: .init(streamIndex: 1, codec: codec, timeBase: MediaRational(num: 1, den: 48_000)!,
                    sampleRate: 48_000, channelLayout: .init(channelCount: 2, nativeMask: 3),
                    extradata: codec == .aac ? Data([0x11, 0x90]) : Data(),
                    metadata: .init(role: .main, service: .independentMain, dispositions: [.default])))
            for event: DemuxEvent in [.tracks(tracks), .discontinuity(tracks, reason: .timelineReset),
                                     .discontinuity(tracks, reason: .timelineReset)] {
                graph.append(.init(event: event,
                    admissionTail: DemuxAdmissionTail(lease: try XCTUnwrap(ingress.acquire(bytes: 1_024)))))
            }
            let deadline = Date().addingTimeInterval(2)
            while graph.failureDiagnostic == nil && Date() < deadline { await Task.yield() }
            XCTAssertNotNil(graph.failureDiagnostic)
            XCTAssertEqual(context.generationCalls, 1)
            XCTAssertEqual(context.compatibilityCalls, 0)
            let retired = await graph.retireAllResourcesAndAwaitReceipt()
            XCTAssertTrue(retired)
        }
    }

    func testGeneratedSourceAACNativeTrialDoesNotCreateCompatibilityCalibration() async throws {
        let context = try GeneratedAudioTestContext { true }
        let probe = HLSWriterAcceptanceProbe()
        let graph = try SystemHLSMediaGraphAuthority(lifecycle: context.lifecycle,
            acceptanceProbe: probe, generatedSource: context)
        let ingress = HLSDataPlaneAdmission(capacity: 2, maximumBytes: 4_096)
        let tracks = DemuxTrackSet(selectedProgramID: nil, video: nil,
            audio: .init(streamIndex: 1, codec: .aac, timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000, channelLayout: .init(channelCount: 2, nativeMask: 3),
                extradata: Data([0x11, 0x90])))
        graph.append(AdmittedDemuxEvent(event: .tracks(tracks),
            admissionTail: DemuxAdmissionTail(lease: try XCTUnwrap(ingress.acquire(bytes: 1_024)))))
        graph.append(AdmittedDemuxEvent(event: .packet(.init(streamIndex: 1, codec: .audio(.aac),
            data: Data([0x21, 0x10, 0x56, 0xE5]),
            presentationTimeStamp: CMTime(value: 480_000, timescale: 48_000),
            decodeTimeStamp: .invalid, duration: .invalid, isKey: true, isCorrupt: false)),
            admissionTail: DemuxAdmissionTail(lease: try XCTUnwrap(ingress.acquire(bytes: 4)))))
        let deadline = Date().addingTimeInterval(2)
        while probe.snapshot.nativeWriterCount == 0 && graph.failureDiagnostic == nil && Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(probe.snapshot.nativeWriterCount, 1, "Actual first native format trial must run")
        XCTAssertEqual(graph.audioCalibrationAttemptsForTesting, 0)
        // One raw-AU trial does not prove init/media publication or decoder output.
        // The separate genuine source publication fixture supplies that gate.
        let retired = await graph.retireAllResourcesAndAwaitReceipt()
        XCTAssertTrue(retired)
        XCTAssertTrue(probe.snapshot.isComplete)
    }

    func testDeclaredEAC3EnvelopeTracksActualConfigurationWithoutChangingCaps() throws {
        for (rate, envelope): (UInt16, UInt64) in [(4_096, 4_352_000), (6_144, 6_400_000)] {
            let configuration = CompressedAudioFormatConfiguration.eac3(try .init(sampleRate: 48_000,
                bsid: 16, bsmod: 0, audioCodingMode: 7, hasLFE: true, asvc: false, maximumDataRateKbps: rate))
            XCTAssertEqual(SegmentedFMP4Writer.audioPeakEnvelope(configuration: configuration), envelope)
        }
        XCTAssertEqual(SegmentedFMP4Writer.audioPeakEnvelope(configuration: nil), 2_048_000)
    }

    func testGeneratedVideoPlanCannotWashUnknownOrConflictingScanIntoRemux() {
        for plan: HLSPlaybackPlan.Video in [.source, .remux, .deinterlaceAndEncode, .unsupported] {
            for source: HLSScanEvidence in [.unknown, .progressive, .interlaced, .contradictory] {
                for actual: VideoScanClassificationEvidence in [.unresolved, .progressive, .interlaced] {
                    let expected = plan == .remux && source == .progressive && actual == .progressive
                        || plan == .deinterlaceAndEncode && source == .interlaced && actual == .interlaced
                    XCTAssertEqual(HLSGeneratedVideoPlanPolicy.accepts(plan: plan, source: source, actual: actual), expected)
                }
            }
        }
    }

    func testRuntimeParameterSetsUseTheSameCanonicalSourceFingerprint() throws {
        let fixtures: [(VideoCodec, [Data])] = [
            (.h264, [AssemblerTestFixtures.h264SPS, AssemblerTestFixtures.h264PPS]),
            (.hevc, [AssemblerTestFixtures.hevcVPS, AssemblerTestFixtures.hevcSPS, AssemblerTestFixtures.hevcPPS]),
        ]
        for (codec, sets) in fixtures {
            let format = try VideoFormatDescriptionBuilder.make(codec: codec, parameterSets: sets)
            let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 1_048_576,
                maximumPCMBytes: 1_048_576, capacity: 4)
            XCTAssertEqual(try HLSGeneratedVideoPlanPolicy.configurationFingerprint(format: format,
                codec: codec, copyOwnership: copies),
                try HLSVideoConfigurationFingerprint.make(codec: codec, parameterSets: sets))
            XCTAssertEqual(copies.compressedInput.usage.bytes, 0)
        }
    }

    func testOwnedCompatibilityCallbackPrecedesFailureVisibilityAndRetirementJoinsIt() async throws {
        let entered = expectation(description: "Owned callback entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let context = try GeneratedAudioTestContext {
            entered.fulfill()
            release.wait()
            return true
        }
        let sink = GeneratedAudioCounter()
        let graph = try SystemHLSMediaGraphAuthority(lifecycle: context.lifecycle,
            publicationDeadlineNanoseconds: 5_000_000_000, failureSink: { _ in sink.increment() },
            generatedSource: context)
        let failure = Task.detached { graph.recordFailureForTesting(CompressedAudioInitializationRejection.invalidConfiguration) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNil(graph.failureDiagnostic)
        let prefixDone = GeneratedAudioCounter()
        let prefix = Task { let result = await graph.awaitAllTrackPlayablePrefix(minimumSeconds: 3); prefixDone.increment(); return result }
        let deadline = Date().addingTimeInterval(2)
        while !graph.prefixPreparationInFlightForTesting && Date() < deadline { await Task.yield() }
        XCTAssertTrue(graph.prefixPreparationInFlightForTesting)
        XCTAssertEqual(prefixDone.value, 0)
        let duplicate = await graph.awaitAllTrackPlayablePrefix(minimumSeconds: 3)
        XCTAssertNil(duplicate, "Duplicate preparation cannot allocate another waiter")
        let retired = GeneratedAudioCounter()
        let retirement = Task { let result = await graph.retireAllResourcesAndAwaitReceipt(); retired.increment(); return result }
        await Task.yield()
        XCTAssertEqual(retired.value, 0, "The external failure stack is part of physical retirement")
        release.signal()
        await failure.value
        let prefixResult = await prefix.value
        let retirementResult = await retirement.value
        XCTAssertNil(prefixResult)
        XCTAssertTrue(retirementResult)
        XCTAssertEqual(context.compatibilityCalls, 1)
        XCTAssertEqual(sink.value, 0)
    }

    func testPublicationDeadlineCannotExposeFailureWhileOwnedCallbackIsHeld() async throws {
        let entered = expectation(description: "Owned callback entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let context = try GeneratedAudioTestContext { entered.fulfill(); release.wait(); return true }
        let graph = try SystemHLSMediaGraphAuthority(lifecycle: context.lifecycle,
            publicationDeadlineNanoseconds: 20_000_000, generatedSource: context)
        let failure = Task.detached { graph.recordFailureForTesting(CompressedAudioInitializationRejection.invalidConfiguration) }
        await fulfillment(of: [entered], timeout: 2)
        let done = GeneratedAudioCounter()
        let prefix = Task { let result = await graph.awaitAllTrackPlayablePrefix(minimumSeconds: 3); done.increment(); return result }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(done.value, 0)
        XCTAssertNil(graph.failureDiagnostic)
        release.signal()
        await failure.value
        let result = await prefix.value
        XCTAssertNil(result)
        let retired = await graph.retireAllResourcesAndAwaitReceipt()
        XCTAssertTrue(retired)
    }

    func testTypedWriterFailuresUseOnlyTheirOriginalOwnedRecovery() async throws {
        for accepted in [false, true] {
            for compatibility in [false, true] {
                let context = try GeneratedAudioTestContext { accepted }
                let sink = GeneratedAudioCounter()
                let graph = try SystemHLSMediaGraphAuthority(lifecycle: context.lifecycle,
                    acceptanceProbe: HLSWriterAcceptanceProbe(), failureSink: { _ in sink.increment() },
                    generatedSource: context)
                graph.recordFailureForTesting(compatibility
                    ? SegmentedFMP4WriterFailure.compressedAudioCompatibilityRequired
                    : SegmentedFMP4WriterFailure.newGenerationRequired)
                XCTAssertEqual(context.compatibilityCalls, compatibility ? 1 : 0)
                XCTAssertEqual(context.generationCalls, compatibility ? 0 : 1)
                XCTAssertEqual(sink.value, accepted ? 0 : 1)
                XCTAssertNotNil(graph.failureDiagnostic)
                let retired = await graph.retireAllResourcesAndAwaitReceipt()
                XCTAssertTrue(retired)
            }
        }
    }

    func testCapacityCancellationAndInternalErrorsDoNotLatchCodecRejection() async throws {
        let errors: [any Error] = [CancellationError(), AACRenditionFailure.capacityExceeded,
                                   SegmentedFMP4WriterFailure.systemFailure]
        for error in errors {
            let context = try GeneratedAudioTestContext { true }
            let sink = GeneratedAudioCounter()
            let graph = try SystemHLSMediaGraphAuthority(lifecycle: context.lifecycle,
                failureSink: { _ in sink.increment() }, generatedSource: context)
            graph.recordFailureForTesting(error)
            XCTAssertEqual(context.compatibilityCalls, 0)
            XCTAssertEqual(sink.value, 1)
            XCTAssertNotNil(graph.failureDiagnostic)
            let retired = await graph.retireAllResourcesAndAwaitReceipt()
            XCTAssertTrue(retired)
        }
    }

    func testPaidCopyOwnerOutlivesGraphUntilItsOwnLastAlias() async throws {
        let context = try GeneratedAudioTestContext { false }
        let ledger = HLSDeliveryApplicationChargeLedger()
        var graph: SystemHLSMediaGraphAuthority? = try .init(lifecycle: context.lifecycle,
            generatedSource: context, sourceCopyApplicationLedger: ledger)
        var retained: HLSAudioCopyOwnership? = try XCTUnwrap(graph?.sourceCopyOwnershipForTesting)
        XCTAssertEqual(ledger.chargedBytes, 16_384)
        let retired = await graph!.retireAllResourcesAndAwaitReceipt()
        XCTAssertTrue(retired)
        graph = nil
        retained?.cancel()
        XCTAssertEqual(ledger.chargedBytes, 16_384)
        var alias = retained
        retained = nil
        withExtendedLifetime(alias) { XCTAssertEqual(ledger.chargedBytes, 16_384) }
        alias = nil
        XCTAssertEqual(ledger.chargedBytes, 0)
    }
}

private final class GeneratedAudioCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class GeneratedAudioTestContext: HLSGeneratedSourceContext, @unchecked Sendable {
    let plan: HLSPlaybackPlan
    let facts: HLSCompatibilityFacts
    let lifecycle: OutputLifecycleEpoch
    private let source: ResolvedPlaybackSource
    private let calls = GeneratedAudioCounter()
    private let generations = GeneratedAudioCounter()
    private let callback: @Sendable () -> Bool
    var isCurrent: Bool { true }
    var compatibilityCalls: Int { calls.value }
    var generationCalls: Int { generations.value }
    init(codec: AudioCodec = .aac, callback: @escaping @Sendable () -> Bool) throws {
        let context = try sourceContext()
        let owner = try XCTUnwrap(context.owner)
        lifecycle = .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce)
        source = .init(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data()))
        facts = .init(source: source, media: [.init(url: context.entryURL, container: .mpegTS,
            video: nil, audio: [.init(codec: codec, profile: codec == .aac ? 1 : (codec == .ac3 ? 8 : 16),
                sampleRate: 48_000, channelCount: 2,
                channelMask: 3, decoderConfiguration: codec == .aac ? Data([0x11, 0x90]) : Data(), priming: .notSignaledPreserveTimestamps,
                service: .independentMain, formatValidated: true)], hasUnsupportedTracks: false)],
            complete: true, inspectedBytes: 1)
        plan = .init(owner: owner, resolutionGeneration: 1, transport: .generated, video: .source,
            audio: .passthrough(codec), selectedServiceURL: context.entryURL, formatFingerprint: facts.formatFingerprint,
            compressedAudioAdmissionCandidate: codec == .aac ? nil : .init(codec: codec,
                profile: codec == .ac3 ? 8 : 16, sampleRate: 48_000, channelCount: 2, channelMask: 3,
                decoderConfiguration: Data(), outputRouteIdentifier: "original-test-route",
                requiresAACCompatibilityRendition: false))
        self.callback = callback
    }
    func requestCompatibleAudioGeneration() -> Bool { calls.increment(); return callback() }
    func requestNewGeneration() -> Bool { generations.increment(); return callback() }
}
