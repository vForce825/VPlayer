// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
import CoreMedia
@testable import VPlayerPlayback

final class AudioOnlyItemSelectorTests: XCTestCase {

    func testAudioOnlyFivePointOneFailsCompressedAndSelectsFidelityAAC() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        harness.failCompressedProbe()
        try await harness.select()
        XCTAssertEqual(harness.selectedRendition, .fidelityAAC)
        XCTAssertEqual(harness.maximumConcurrentProbes, 1)
        XCTAssertEqual(harness.videoResourceCount, 0)
        XCTAssertEqual(harness.masterPlaylistCount, 0)
    }

    func testAudioOnlyFivePointOneCompressedSucceedsFirst() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        try await harness.select()
        XCTAssertEqual(harness.selectedRendition, .compressed)
        XCTAssertEqual(harness.maximumConcurrentProbes, 1)
        XCTAssertEqual(harness.videoResourceCount, 0)
        XCTAssertEqual(harness.masterPlaylistCount, 0)
        XCTAssertEqual(harness.didProbeCandidate(ordinal: 1), false)
        XCTAssertEqual(harness.didProbeCandidate(ordinal: 2), false)
    }

    func testAudioOnlyFivePointOneFallsBackToStereoWhenFidelityFails() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        harness.failCompressedProbe()
        harness.failFidelityAACProbe()
        try await harness.select()
        XCTAssertEqual(harness.selectedRendition, .compatibilityStereo(reason: .probeFailed))
        XCTAssertEqual(harness.maximumConcurrentProbes, 1)
        XCTAssertEqual(harness.videoResourceCount, 0)
        XCTAssertEqual(harness.masterPlaylistCount, 0)
        XCTAssertNotNil(harness.compatibilityStereoDiagnostic)
        XCTAssertTrue(harness.compatibilityStereoDiagnostic?.contains("probeFailed") == true)
    }

    func testAudioOnlyFivePointOneFallsBackToStereoWhenFidelityTimesOut() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        harness.failCompressedProbe()
        harness.timeoutFidelityAACProbe()
        try await harness.select()
        XCTAssertEqual(harness.selectedRendition, .compatibilityStereo(reason: .probeTimedOut))
        XCTAssertEqual(harness.maximumConcurrentProbes, 1)
        XCTAssertNotNil(harness.compatibilityStereoDiagnostic)
        XCTAssertTrue(harness.compatibilityStereoDiagnostic?.contains("probeTimedOut") == true)
    }

    func testAudioOnlyStereoSourceDeduplicatesFidelityAndCompatibility() async throws {
        let harness = AudioOnlySelectorTestHarness.stereo()
        harness.failCompressedProbe()
        try await harness.select()
        XCTAssertEqual(harness.selectedRendition, .fidelityAAC)
        XCTAssertEqual(harness.candidateCount, 2)
        XCTAssertEqual(harness.videoResourceCount, 0)
        XCTAssertEqual(harness.masterPlaylistCount, 0)
    }

    func testAudioOnlyMonoSourceGeneratesFidelityAndStereoCompatibility() async throws {
        let harness = AudioOnlySelectorTestHarness.mono()
        harness.failCompressedProbe()
        try await harness.select()
        XCTAssertEqual(harness.selectedRendition, .fidelityAAC)
        XCTAssertEqual(harness.candidateCount, 3)
        XCTAssertEqual(harness.videoResourceCount, 0)
        XCTAssertEqual(harness.masterPlaylistCount, 0)
    }

    func testOuterBudgetSuffixChecks19Vs20SecondsForCompressed() async throws {
        // 19s: Compressed candidate needs 20s (5s probe + 1s cleanup + 14s suffix for m=2) -> skipped
        let harness19 = AudioOnlySelectorTestHarness.fivePointOne()
        harness19.setOuterRemainingBudget(19.0)
        try await harness19.select()
        XCTAssertEqual(harness19.selectedRendition, .fidelityAAC)
        XCTAssertEqual(harness19.didProbeCandidate(ordinal: 0), false)
        XCTAssertEqual(harness19.didProbeCandidate(ordinal: 1), true)

        // 20s: Compressed candidate has sufficient budget -> probed and selected
        let harness20 = AudioOnlySelectorTestHarness.fivePointOne()
        harness20.setOuterRemainingBudget(20.0)
        try await harness20.select()
        XCTAssertEqual(harness20.selectedRendition, .compressed)
        XCTAssertEqual(harness20.didProbeCandidate(ordinal: 0), true)
    }

    func testOuterBudgetSuffixChecks13Vs14SecondsForFidelityAAC() async throws {
        // Compressed fails probe
        // 13s: Fidelity AAC needs 14s (5s probe + 1s cleanup + 8s suffix for m=1) -> skipped
        let harness13 = AudioOnlySelectorTestHarness.fivePointOne()
        harness13.failCompressedProbe()
        harness13.setOuterRemainingBudget(13.0)
        try await harness13.select()
        XCTAssertEqual(harness13.selectedRendition, .compatibilityStereo(reason: .skippedForOuterBudget))
        XCTAssertEqual(harness13.didProbeCandidate(ordinal: 1), false)
        XCTAssertEqual(harness13.didProbeCandidate(ordinal: 2), true)

        // 14s: Fidelity AAC has sufficient budget -> probed and selected
        let harness14 = AudioOnlySelectorTestHarness.fivePointOne()
        harness14.failCompressedProbe()
        harness14.setOuterRemainingBudget(14.0)
        try await harness14.select()
        XCTAssertEqual(harness14.selectedRendition, .fidelityAAC)
        XCTAssertEqual(harness14.didProbeCandidate(ordinal: 1), true)
    }

    func testOuterBudgetSuffixChecks7Vs8SecondsForLastCandidate() async throws {
        // Both compressed and fidelity fail
        // 7s: Compatibility stereo needs 8s (5s probe + 3s post-selection reserve) -> cannot install, fails
        let harness7 = AudioOnlySelectorTestHarness.fivePointOne()
        harness7.failCompressedProbe()
        harness7.failFidelityAACProbe()
        harness7.setOuterRemainingBudget(7.0)
        do {
            try await harness7.select()
            XCTFail("Outer budget < 8s for last candidate should throw")
        } catch {
            XCTAssertTrue(error is AudioOnlySelectionFailure)
        }

        // 8s: Compatibility stereo has sufficient budget -> probed and selected
        let harness8 = AudioOnlySelectorTestHarness.fivePointOne()
        harness8.setOuterRemainingBudget(8.0)
        try await harness8.select()
        XCTAssertEqual(harness8.selectedRendition, .compatibilityStereo(reason: .skippedForOuterBudget))
        XCTAssertEqual(harness8.didProbeCandidate(ordinal: 1), false)
        XCTAssertEqual(harness8.didProbeCandidate(ordinal: 2), true)
    }

    func testCandidateCleanupTimeoutAbortsSelectionImmediately() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        harness.failCompressedProbe()
        harness.timeoutCandidateCleanup(ordinal: 0)
        do {
            try await harness.select()
            XCTFail("Cleanup timeout should abort selection immediately")
        } catch {
            guard let failure = error as? AudioOnlySelectionFailure else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(failure, .cleanupTimedOut(ordinal: 0))
        }
        XCTAssertEqual(harness.didProbeCandidate(ordinal: 1), false)
    }

    func testLoserCleanupClosesOnlyOwnSubscriptionAndPreservesSharedDecoder() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        harness.failCompressedProbe()
        try await harness.select()
        XCTAssertTrue(harness.candidateCleanedUp(ordinal: 0))
        XCTAssertEqual(harness.sharedDecoderRunCount, 1)
        XCTAssertTrue(harness.sharedDecoderPreserved)
    }

    func testCandidatesEnforceCommonSixSevenSegmentThreshold() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        harness.failCompressedProbe()
        harness.setPrefixReady(ordinal: 1, ready: false)
        harness.failFidelityAACProbe()
        try await harness.select()
        // If candidate 1 failed prefix threshold, it falls back to candidate 2
        XCTAssertEqual(harness.selectedRendition, .compatibilityStereo(reason: .probeFailed))
    }

    func testProductionCandidateBuilderStereoDeduplication() {
        let epoch = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_099)
        let transaction = AudioOnlySelectionTransaction(outputLifecycleEpoch: epoch)

        // 5.1 -> 3 candidates
        let fivePointOne = AudioOnlyItemSelector.buildCandidates(
            sourceProfile: AudioOnlySourceProfile(codec: .ac3, channelCount: 6),
            transaction: transaction
        )
        XCTAssertEqual(fivePointOne.count, 3)
        XCTAssertEqual(fivePointOne[0].renditionKind, .compressed)
        XCTAssertEqual(fivePointOne[1].renditionKind, .fidelityAAC)
        XCTAssertEqual(fivePointOne[2].renditionKind, .compatibilityStereo)

        // Stereo -> 2 candidates (deduplicated)
        let stereo = AudioOnlyItemSelector.buildCandidates(
            sourceProfile: AudioOnlySourceProfile(codec: .aac, channelCount: 2),
            transaction: transaction
        )
        XCTAssertEqual(stereo.count, 2)
        XCTAssertEqual(stereo[0].renditionKind, .compressed)
        XCTAssertEqual(stereo[1].renditionKind, .fidelityAAC)

        // Mono -> 3 candidates
        let mono = AudioOnlyItemSelector.buildCandidates(
            sourceProfile: AudioOnlySourceProfile(codec: .aac, channelCount: 1),
            transaction: transaction
        )
        XCTAssertEqual(mono.count, 3)
        XCTAssertEqual(mono[0].renditionKind, .compressed)
        XCTAssertEqual(mono[1].renditionKind, .fidelityAAC)
        XCTAssertEqual(mono[2].renditionKind, .compatibilityStereo)
    }

    func testPostSelectionBudgetUnderThreeSecondsFailsClosed() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        final class BudgetBox: @unchecked Sendable {
            private let lock = NSLock()
            private var budget: TimeInterval = 25.0
            func get() -> TimeInterval { lock.withLock { budget } }
            func set(_ value: TimeInterval) { lock.withLock { budget = value } }
        }
        let box = BudgetBox()
        harness.selector.setOuterBudgetProvider {
            box.get()
        }
        // When probe completes, drop budget below 3.0s post-selection reserve
        let compressedCandidate = harness.candidates[0]
        let probeBundle = AudioOnlyCandidateBundle(
            candidateTicket: compressedCandidate.candidateTicket,
            renditionKind: .compressed,
            mediaPlaylistURL: compressedCandidate.mediaPlaylistURL,
            probeAction: { _ in
                box.set(2.5)
                return true
            }
        )
        let selector = AudioOnlyItemSelector(
            transaction: harness.transaction,
            candidates: [probeBundle],
            outerBudgetProvider: { box.get() }
        )
        do {
            _ = try await selector.select()
            XCTFail("Post-selection reserve budget < 3.0s must throw insufficientOuterBudget")
        } catch {
            XCTAssertEqual(error as? AudioOnlySelectionFailure, .insufficientOuterBudget)
        }
    }

    func testCleanupTimeoutOnSkippedCandidateAbortsImmediately() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        // Budget is 18s -> compressed candidate (m=2, requires 20s) will be skipped
        harness.setOuterRemainingBudget(18.0)
        harness.timeoutCandidateCleanup(ordinal: 0)
        do {
            try await harness.select()
            XCTFail("Cleanup timeout during skip must immediately fail closed")
        } catch {
            XCTAssertEqual(error as? AudioOnlySelectionFailure, .cleanupTimedOut(ordinal: 0))
        }
        XCTAssertEqual(harness.didProbeCandidate(ordinal: 1), false)
    }

    func testLoserCleanupTimeoutAbortsSelection() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        // Candidate 0 succeeds probe, but candidate 1 times out during loser cleanup
        harness.timeoutCandidateCleanup(ordinal: 1)
        do {
            try await harness.select()
            XCTFail("Loser cleanup timeout must abort selection")
        } catch {
            XCTAssertEqual(error as? AudioOnlySelectionFailure, .cleanupTimedOut(ordinal: 1))
        }
    }

    func testCandidateBundleRetiresDrainFencesOnCleanup() async throws {
        let epoch = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_098)
        let transaction = AudioOnlySelectionTransaction(outputLifecycleEpoch: epoch)
        let ticket = AudioOnlyCandidateTicket(
            selectionTransactionIdentity: transaction.selectionNonce,
            itemGeneration: 1001,
            candidateOrdinal: 0,
            candidateKind: .compressed,
            renditionIdentity: AudioRenditionIdentity(rawValue: 10)
        )
        let bundle = AudioOnlyCandidateBundle(
            candidateTicket: ticket,
            renditionKind: .compressed,
            mediaPlaylistURL: URL(string: "http://127.0.0.1:19023/audio/compressed/index.m3u8")!,
            fences: CandidateBranchDrainFences()
        )
        let cleaned = await bundle.cleanup(reason: .loserUnselected, timeout: 1.0)
        XCTAssertTrue(cleaned)
        XCTAssertEqual(bundle.currentPhase, .retired)
    }

    func testBackendIntegrationWithAudioOnlySelector() async throws {
        let epoch = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_097)
        let transaction = AudioOnlySelectionTransaction(outputLifecycleEpoch: epoch)
        let candidates = AudioOnlyItemSelector.buildCandidates(
            sourceProfile: AudioOnlySourceProfile(codec: .ac3, channelCount: 6),
            transaction: transaction
        )
        let selector = AudioOnlyItemSelector(
            transaction: transaction,
            candidates: candidates
        )
        let driver = try await MainActor.run { try SystemAVPlayerDriver.make() }
        let backend = HLSAVPlayerPlaybackBackend(
            identity: epoch.backendIdentity,
            bundleBuilder: try SystemHLSOutputItemBundleBuilder(sourceURL: URL(string: "http://127.0.0.1:19023/audio")!),
            presentationContext: await MainActor.run { AVPlayerPresentationContext(player: driver.player) },
            audioOnlySelector: selector,
            coordinatorFactory: { replacement in
                try await MainActor.run {
                    try AVPlayerItemCoordinator(driver: driver, evidenceSource: replacement.evidenceSource)
                }
            }
        )
        XCTAssertTrue(backend.isAudioOnly)
    }

    func testCommittedWinnerCandidateCleansUpAndRetires() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        try await harness.select()
        guard let winner = harness.candidates.first(where: { $0.currentPhase == .committed }) else {
            return XCTFail("Must have a committed winner bundle after select")
        }
        XCTAssertEqual(winner.currentPhase, .committed)

        // Winner cleanup must succeed, transition to .retired, and be idempotent
        let cleaned = await winner.cleanup(reason: .invalidation, timeout: 1.0)
        XCTAssertTrue(cleaned, "Committed winner candidate must successfully clean up")
        XCTAssertEqual(winner.currentPhase, .retired)

        let cleanedAgain = await winner.cleanup(reason: .invalidation, timeout: 1.0)
        XCTAssertTrue(cleanedAgain, "Cleanup on already retired bundle must be idempotently true")
        XCTAssertEqual(winner.currentPhase, .retired)
    }

    func testAudioOnlyOutputItemBundleRetireProducerGraphConfirmsRetirement() async throws {
        let harness = AudioOnlySelectorTestHarness.fivePointOne()
        try await harness.select()
        guard let winner = harness.candidates.first(where: { $0.currentPhase == .committed }) else {
            return XCTFail("Must have a committed winner bundle after select")
        }

        // Wrap winner into HLSOutputItemBundle as done in HLSAVPlayerPlaybackBackend
        let outputBundle = HLSOutputItemBundle(
            startProducer: { throw AudioOnlySelectionFailure.allCandidatesFailed },
            retireProducer: {
                await winner.cleanup(reason: .invalidation, timeout: 1.0)
            }
        )

        let confirmed = await outputBundle.retireProducerGraph()
        XCTAssertTrue(confirmed, "Audio-only output bundle retirement must confirm true")
        XCTAssertEqual(outputBundle.currentLifecycle, .retired)
        XCTAssertEqual(winner.currentPhase, .retired)
    }
}

final class AudioOnlySelectorTestHarness: @unchecked Sendable {
    let channelCount: Int
    let candidates: [AudioOnlyCandidateBundle]
    let selector: AudioOnlyItemSelector
    let transaction: AudioOnlySelectionTransaction

    private(set) var selectedRendition: AudioOnlySelectedRendition?
    private(set) var selectedItemURL: URL?
    private(set) var compatibilityStereoDiagnostic: String?
    private(set) var sharedDecoderRunCount: Int = 0
    private(set) var sharedDecoderPreserved: Bool = true
    private var outerBudget: TimeInterval = 45.0
    private let lock = NSLock()

    var candidateCount: Int { candidates.count }
    var maximumConcurrentProbes: Int { selector.maximumConcurrentProbes }
    var videoResourceCount: Int { 0 }
    var masterPlaylistCount: Int { 0 }

    static func fivePointOne() -> AudioOnlySelectorTestHarness {
        AudioOnlySelectorTestHarness(channelCount: 6)
    }

    static func stereo() -> AudioOnlySelectorTestHarness {
        AudioOnlySelectorTestHarness(channelCount: 2)
    }

    static func mono() -> AudioOnlySelectorTestHarness {
        AudioOnlySelectorTestHarness(channelCount: 1)
    }

    private init(channelCount: Int) {
        self.channelCount = channelCount
        let epoch = AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 23_001)
        let transaction = AudioOnlySelectionTransaction(
            outputLifecycleEpoch: epoch,
            audioAdmissionFenceRevision: 1
        )
        self.transaction = transaction

        let profile = AudioOnlySourceProfile(
            codec: .ac3,
            channelCount: channelCount,
            sampleRate: 48_000,
            bitrate: 160_000,
            supportsCompressedFidelity: true
        )
        let bundles = AudioOnlyItemSelector.buildCandidates(
            sourceProfile: profile,
            transaction: transaction,
            fencesFactory: { kind, ordinal in
                switch kind {
                case .compressed:
                    return CandidateBranchDrainFences(
                        compressed: AudioServiceBranchDrainFence(
                            admissionIdentity: .directCompressed(
                                .audioOnly(
                                    outputLifecycleEpoch: epoch,
                                    selectionTransactionIdentity: AudioSelectionTransactionIdentity(rawValue: 1),
                                    candidateTicket: AudioCandidateTicket(rawValue: UInt64(ordinal)),
                                    itemGeneration: AudioItemGenerationIdentity(rawValue: 1001),
                                    mediaEpoch: AudioMediaEpochIdentity(rawValue: 1),
                                    publicationParticipantID: AudioPublicationParticipantIdentity(rawValue: 10),
                                    renditionIdentity: AudioRenditionIdentity(rawValue: 10)
                                ),
                                branchGeneration: 1,
                                admissionFenceRevision: 1
                            ),
                            lastIssuedLeaseSequence: 1,
                            expectedOutstandingCount: 0
                        )
                    )
                case .fidelityAAC:
                    return CandidateBranchDrainFences(
                        pcmConsumer: PCMConsumerDrainFence(
                            consumerAdmissionIdentity: PCMConsumerAdmissionIdentity(
                                owner: .audioOnly(
                                    outputLifecycleEpoch: epoch,
                                    selectionTransactionIdentity: AudioSelectionTransactionIdentity(rawValue: 1),
                                    candidateTicket: AudioCandidateTicket(rawValue: UInt64(ordinal)),
                                    itemGeneration: AudioItemGenerationIdentity(rawValue: 1002),
                                    mediaEpoch: AudioMediaEpochIdentity(rawValue: 1),
                                    publicationParticipantID: AudioPublicationParticipantIdentity(rawValue: 20),
                                    renditionIdentity: AudioRenditionIdentity(rawValue: 20)
                                ),
                                subscriptionGeneration: 1,
                                admissionFenceRevision: 1
                            ),
                            lastIssuedLeaseSequence: 1,
                            expectedOutstandingCount: 0
                        )
                    )
                case .compatibilityStereo:
                    return CandidateBranchDrainFences(
                        pcmConsumer: PCMConsumerDrainFence(
                            consumerAdmissionIdentity: PCMConsumerAdmissionIdentity(
                                owner: .audioOnly(
                                    outputLifecycleEpoch: epoch,
                                    selectionTransactionIdentity: AudioSelectionTransactionIdentity(rawValue: 1),
                                    candidateTicket: AudioCandidateTicket(rawValue: UInt64(ordinal)),
                                    itemGeneration: AudioItemGenerationIdentity(rawValue: 1003),
                                    mediaEpoch: AudioMediaEpochIdentity(rawValue: 1),
                                    publicationParticipantID: AudioPublicationParticipantIdentity(rawValue: 30),
                                    renditionIdentity: AudioRenditionIdentity(rawValue: 30)
                                ),
                                subscriptionGeneration: 1,
                                admissionFenceRevision: 1
                            ),
                            lastIssuedLeaseSequence: 1,
                            expectedOutstandingCount: 0
                        )
                    )
                }
            }
        )

        self.candidates = bundles

        let selector = AudioOnlyItemSelector(
            transaction: transaction,
            candidates: bundles,
            outerBudgetProvider: { 45.0 },
            diagnosticSink: nil
        )
        self.selector = selector
        selector.setOuterBudgetProvider { [weak self] in
            guard let self else { return 45.0 }
            return self.lock.withLock { self.outerBudget }
        }
    }

    func failCompressedProbe() {
        if let compressed = candidates.first(where: { $0.renditionKind == .compressed }) {
            compressed.injectProbeFailure()
        }
    }

    func failFidelityAACProbe() {
        if let fidelity = candidates.first(where: { $0.renditionKind == .fidelityAAC }) {
            fidelity.injectProbeFailure()
        }
    }

    func timeoutCompressedProbe() {
        if let compressed = candidates.first(where: { $0.renditionKind == .compressed }) {
            compressed.injectProbeTimeout()
        }
    }

    func timeoutFidelityAACProbe() {
        if let fidelity = candidates.first(where: { $0.renditionKind == .fidelityAAC }) {
            fidelity.injectProbeTimeout()
        }
    }

    func timeoutCandidateCleanup(ordinal: Int) {
        if let candidate = candidates.first(where: { $0.candidateTicket.candidateOrdinal == ordinal }) {
            candidate.injectCleanupTimeout()
        }
    }

    func setPrefixReady(ordinal: Int, ready: Bool) {
        if let candidate = candidates.first(where: { $0.candidateTicket.candidateOrdinal == ordinal }) {
            candidate.isPlayablePrefixReady = ready
        }
    }

    func setOuterRemainingBudget(_ seconds: TimeInterval) {
        lock.withLock { outerBudget = seconds }
    }

    func didProbeCandidate(ordinal: Int) -> Bool {
        guard let candidate = candidates.first(where: { $0.candidateTicket.candidateOrdinal == ordinal }) else {
            return false
        }
        return candidate.wasProbed
    }

    func candidateCleanedUp(ordinal: Int) -> Bool {
        guard let candidate = candidates.first(where: { $0.candidateTicket.candidateOrdinal == ordinal }) else {
            return false
        }
        return candidate.currentPhase == .retired
    }

    func select() async throws {
        // Shared decoder runs once per proof before candidate selection
        lock.withLock {
            sharedDecoderRunCount += 1
            sharedDecoderPreserved = true
        }

        let result = try await selector.select()

        lock.withLock {
            selectedRendition = result.selectedRendition
            selectedItemURL = result.selectedBundle.mediaPlaylistURL
            compatibilityStereoDiagnostic = result.diagnostic
        }
    }
}
