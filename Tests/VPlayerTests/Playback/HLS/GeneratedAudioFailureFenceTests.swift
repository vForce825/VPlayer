// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class GeneratedAudioFailureFenceTests: XCTestCase {
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
    private let callback: @Sendable () -> Bool
    var isCurrent: Bool { true }
    var compatibilityCalls: Int { calls.value }
    init(callback: @escaping @Sendable () -> Bool) throws {
        let context = try sourceContext()
        let owner = try XCTUnwrap(context.owner)
        lifecycle = .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce)
        source = .init(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data()))
        facts = .init(source: source, media: [.init(url: context.entryURL, container: .mpegTS,
            video: nil, audio: [.init(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2,
                channelMask: 3, decoderConfiguration: Data([0x11, 0x90]), priming: .notSignaledPreserveTimestamps,
                service: .independentMain, formatValidated: true)], hasUnsupportedTracks: false)],
            complete: true, inspectedBytes: 1)
        plan = .init(owner: owner, resolutionGeneration: 1, transport: .generated, video: .source,
            audio: .passthrough(.aac), selectedServiceURL: context.entryURL, formatFingerprint: facts.formatFingerprint)
        self.callback = callback
    }
    func requestCompatibleAudioGeneration() -> Bool { calls.increment(); return callback() }
}
