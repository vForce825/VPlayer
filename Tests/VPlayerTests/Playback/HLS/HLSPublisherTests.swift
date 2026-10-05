// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import Foundation
import UniformTypeIdentifiers
import CoreVideo
import XCTest
import VPlayerCore
import zlib
@testable import VPlayerPlayback

final class HLSPublisherTests: XCTestCase {
    func testReview4FailedWriterIsolationAndDecoderConfigurationEpochTable() async throws {
        let cases: [(String, () async throws -> Void)] = [
            ("失败 successor 不得接管旧 relay", Task19Review4Checks.failedSuccessorLeavesActiveRelayUntouched),
            ("不同 writer 的音视频 configuration 可合法换代", Task19Review4Checks.decoderConfigurationsMayChangeAcrossEpoch),
            ("同 epoch 的 init 与 media configuration 必须一致", Task19Review4Checks.sameEpochConfigurationMismatchIsRejected),
            ("跨 epoch 的 video codec 变化拒绝", { try await Task19Review4Checks.selectionChangeIsRejected(.videoCodec) }),
            ("跨 epoch 的 audio channels 变化拒绝", { try await Task19Review4Checks.selectionChangeIsRejected(.audioChannels) }),
            ("跨 epoch 的 item generation 变化拒绝", { try await Task19Review4Checks.selectionChangeIsRejected(.itemGeneration) }),
            ("跨 epoch 的 rendition 变化拒绝", { try await Task19Review4Checks.selectionChangeIsRejected(.rendition) }),
            ("跨 epoch 的 lifecycle 变化拒绝", { try await Task19Review4Checks.selectionChangeIsRejected(.lifecycle) }),
            ("跨 epoch 的冻结 declaration 变化拒绝", Task19Review4Checks.declarationChangeIsRejected),
            ("HEVC Main10 8 位到 10 位跨代拒绝", {
                try await Task19Review4Checks.videoBitDepthChangeIsRejected(from: .hevcMain10EightBit,
                                                                      to: .hevcMain10TenBit)
            }),
            ("HEVC Main10 10 位到 8 位跨代拒绝", {
                try await Task19Review4Checks.videoBitDepthChangeIsRejected(from: .hevcMain10TenBit,
                                                                      to: .hevcMain10EightBit)
            }),
        ]
        for (name, operation) in cases {
            do { try await operation() }
            catch { XCTFail("\(name)：\(error)") }
        }
    }

    func testReview3SuccessorWriterIdentityAtomicAdmissionRetirementAndBoundedDrainTable() async throws {
        for audioOnly in [false, true] {
            for capacity in [false, true] {
                try await Task19Harness(audioOnly: audioOnly, audioCount: 2)
                    .checkWriterSuccessorTable(capacity: capacity)
            }
        }
    }

    func testReview2I1PrivateDelegateCapsuleRejectsProxyReplacementAndReplay() async throws {
        for mutation in Task19CallbackProxyFactory.Mutation.allCases {
            let probe = try await Task19WriterProbe.run(factory: Task19CallbackProxyFactory(mutation: mutation),
                count: mutation == .replay ? 48 : 24)
            if mutation == .unchanged {
                XCTAssertNil(probe.failure)
                XCTAssertEqual(probe.media.count, 1)
                XCTAssertTrue(try XCTUnwrap(probe.media.first?.publicationEvidence).matches(probe.media[0]))
            } else if mutation == .replay {
                XCTAssertNotNil(probe.failure)
                XCTAssertEqual(probe.media.count, 1, "第二个准确 pending 不得消费第一段的来源资格")
                XCTAssertEqual(probe.relay.usage.unpublishedLogicalSegmentCount, probe.media.count)
            } else {
                XCTAssertNotNil(probe.failure, "真实 adapter 不能授权 proxy 替换：\(mutation)")
                XCTAssertTrue(probe.media.isEmpty, "被替换 callback 不得签发 media publication：\(mutation)")
                XCTAssertEqual(probe.relay.usage.unpublishedLogicalSegmentCount, 0)
            }
            probe.release()
        }
    }

    func testReview2I2CandidateEnvelopeOwnBoundaryIgnoresPublicLargerAndSmaller() async throws {
        for publicEnvelope: UInt64 in [1, 1_000_000] {
            for delta: Int64 in [-1, 0, 1] {
                let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
                let track = try await Task19Track(id: 2, mediaType: .audio, item: 20, boundary: boundary)
                let packet = try await track.next()
                // 真实47个AAC AU共48128/48000秒；独立整数上取整，不调用被测bandwidth实现。
                let exactRate = (UInt64(packet.object.bytes.count) * 8 * 48_000 + 48_127) / 48_128
                var candidateDeclaration = try Task19.declaration(audioOnly: true)
                candidateDeclaration.itemGeneration = 20
                candidateDeclaration.audio[0].peakEnvelope = UInt64(Int64(exactRate) + delta)
                var publicDeclaration = candidateDeclaration
                publicDeclaration.itemGeneration = 19
                publicDeclaration.audio[0].peakEnvelope = publicEnvelope
                let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
                let candidate = try store.registerAudioCandidate(initialization: track.initialization,
                    proof: track.proof, declaration: candidateDeclaration)
                let publisher = try HLSPublicationCoordinator(store: store,
                    participants: [.init(initialization: track.initialization, proof: track.proof, relay: track.relay,
                        candidateTicket: candidate.ticket, candidate: candidate)], declaration: publicDeclaration,
                    anchor: .init(mediaOrigin: .init(value: 0, timescale: 1), utcMilliseconds: 0))
                let before = store.usage
                if delta < 0 {
                    XCTAssertThrowsError(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                        ticket: publisher.ticket, now: 0))
                    XCTAssertEqual(store.usage.segmentCount, before.segmentCount)
                    XCTAssertTrue(packet.relay.releaseForControl(packet.object))
                } else {
                    XCTAssertNoThrow(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                        ticket: publisher.ticket, now: 0))
                }
                publisher.close()
            }
            let h = try await Task19Harness(audioOnly: true, publicEnvelope: publicEnvelope)
            await assertTask19NoThrow(try await h.initial())
            XCTAssertNotNil(h.publisher.visible?.media[2])
        }
    }

    func testReview2I3RetiredHighWaterReleasesBothEpochsAndRejectsFutureOrWrongIdentity() async throws {
        for audioOnly in [false, true] {
            let h = try await Task19Harness(audioOnly: audioOnly, audioCount: audioOnly ? 2 : 1)
            try await h.initial()
            let epochOne = h.tracks
            let epochOneTicket = h.publisher.ticket
            try await h.beginEpoch(2)
            let epochTwo = h.tracks
            let ticket = h.publisher.ticket
            let retired = try h.publisher.reconfigure(retiring: [2], ticket: ticket).retiredParticipantIDs
            for (tracks, generationTicket) in [(epochOne, epochOneTicket), (epochTwo, ticket)] {
                for id in tracks.keys.sorted() {
                    let packet = try await tracks[id]!.next()
                    if retired.contains(id) {
                        XCTAssertEqual(try? h.publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                            ticket: generationTicket, now: 0), .releasedOnly)
                        XCTAssertEqual(packet.relay.usage.unpublishedLogicalSegmentCount, 0)
                        XCTAssertThrowsError(try h.publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                            ticket: generationTicket, now: 0))
                    } else { XCTAssertTrue(packet.relay.releaseForControl(packet.object)) }
                }
            }
            let original = epochTwo[2]!.binding
            let wrong: [FMP4WriterBinding] = [
                Task19.binding(id: 2, epoch: 3, item: original.itemGeneration.rawValue),
                Task19.binding(id: 2, epoch: 1, writer: 999, item: original.itemGeneration.rawValue),
                Task19.binding(id: 2, epoch: 1, item: 999),
                .init(outputLifecycleEpoch: original.outputLifecycleEpoch, itemGeneration: original.itemGeneration,
                    mediaEpoch: .init(rawValue: 1), publicationParticipantID: original.publicationParticipantID,
                    renditionIdentity: .init(rawValue: 999), writerIdentity: original.writerIdentity),
                .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 999),
                    itemGeneration: original.itemGeneration, mediaEpoch: .init(rawValue: 1),
                    publicationParticipantID: original.publicationParticipantID, renditionIdentity: original.renditionIdentity,
                    writerIdentity: original.writerIdentity)
            ]
            for binding in wrong {
                let track = try await Task19Track(id: 2, mediaType: .audio, bindingOverride: binding)
                let packet = try await track.next()
                XCTAssertThrowsError(try h.publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                    ticket: ticket, now: 0))
                XCTAssertEqual(packet.relay.usage.unpublishedLogicalSegmentCount, 1)
                XCTAssertTrue(packet.relay.releaseForControl(packet.object))
                XCTAssertTrue(track.relay.releaseForControl(track.initialization))
            }
        }
    }

    func testReview2I4EveryVideoFrameCadenceIsVerifiedAndFailureDoesNotPoisonNextWriter() async throws {
        for index in [1, 12, 23] {
            for mutation in Task19WriterProbe.CadenceMutation.allCases {
                let probe = try await Task19WriterProbe.run(mutation: (index, mutation))
                XCTAssertNotNil(probe.failure, "整段第\(index)帧\(mutation)必须失败")
                XCTAssertTrue(probe.media.isEmpty, "不能只用第一帧签发固定帧率")
                probe.release()
                let next = try await Task19WriterProbe.run()
                XCTAssertNil(next.failure)
                XCTAssertEqual(next.media.count, 1)
                XCTAssertEqual(next.media.first?.publicationEvidence?.frameDuration, Task19.time(1, 24))
                next.release()
            }
        }
        let fractional = try await Task19WriterProbe.run(frameDuration: CMTime(value: 1_001, timescale: 30_000),
            start: CMTime(value: 1, timescale: 48_000), count: 30)
        XCTAssertNil(fractional.failure)
        XCTAssertEqual(fractional.media.first?.publicationEvidence?.frameDuration, Task19.time(1_001, 30_000))
        XCTAssertEqual(try ExactMediaTime(XCTUnwrap(fractional.media.first?.report.earliestPresentationTimeStamp)), Task19.time(1, 48_000))
        fractional.release()
        let successes = Task19Counter()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<2 {
                group.addTask {
                    do {
                        let probe = try await Task19WriterProbe.run(mutation: index == 0 ? (12, .duration) : nil)
                        if index == 1 && probe.failure == nil && probe.media.count == 1 { successes.add() }
                        if index == 0 { XCTAssertNotNil(probe.failure) }
                        probe.release()
                    } catch { XCTFail("并发 cadence fixture 失败：\(error)") }
                }
            }
        }
        XCTAssertEqual(successes.value, 1)
    }

    func testReviewI1StoreRejectsSecondOwnerAndStaleVectorWithoutTakingInit() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let duplicate = try await Task19Harness.detachedParticipants()
        XCTAssertThrowsError(try HLSPublicationCoordinator(store: h.store, participants: duplicate,
            declaration: Task19.declaration(), anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0)))
        for participant in duplicate { XCTAssertTrue(participant.relay.releaseForControl(participant.initialization)) }
        let before = h.publisher.visible!.publicationSequence
        try await h.offerBoth(count: 1)
        var stale = h.publisher.ticket
        stale.participantVector[0].expectedPreviousSnapshotVersion = 0
        XCTAssertThrowsError(try h.publisher.publish(ticket: stale, now: Task19.second))
        let ticket = h.publisher.ticket
        let wins = Task19Counter()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if (try? h.publisher.publish(ticket: ticket, now: Task19.second)) == .published { wins.add() }
        }
        XCTAssertEqual(wins.value, 1)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, before + 1)
        h.publisher.close()
        XCTAssertThrowsError(try h.publisher.publish(ticket: ticket, now: 2 * Task19.second))
    }

    func testReviewI2EOFDrainsTwoAndEightBacklogBeforeUniqueEndList() async throws {
        for backlog in [2, 8] {
            let h = try await Task19Harness(terminalLogicalSequence: UInt64(5 + backlog))
            try await h.initial()
            let initialPublication = h.publisher.visible?.publicationSequence
            XCTAssertThrowsError(try h.publisher.publish(ticket: h.publisher.ticket,
                now: Task19.second, naturalEnd: true)) { error in
                XCTAssertEqual(error as? HLSPublicationFailure, .identityMismatch)
            }
            XCTAssertEqual(h.publisher.visible?.publicationSequence, initialPublication,
                "An unfinished writer cannot authorize a terminal publication")
            try await h.offerBoth(count: backlog)
            let endpoint = try XCTUnwrap(h.tracks[2]?.endpointAuthority)
            XCTAssertEqual(endpoint.receipt.terminalLogicalSequence, UInt64(5 + backlog))
            XCTAssertEqual(endpoint.media.count, 6 + backlog,
                "The terminal authority must cover every real callback, including the pending prefix")
            for index in 1...backlog {
                let ticket = h.publisher.ticket
                XCTAssertEqual(try h.publisher.publish(ticket: ticket, now: Int64(index) * Task19.second,
                    naturalEnd: index == 1), .published)
                XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, UInt64(5 + index))
                XCTAssertEqual(h.publisher.visible!.media.values.allSatisfy { $0.text.contains("#EXT-X-ENDLIST") }, index == backlog)
                XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, backlog - index)
            }
            XCTAssertThrowsError(try h.publisher.publish(ticket: h.publisher.ticket,
                now: Int64(backlog + 1) * Task19.second, naturalEnd: true))
        }
        let unequal = try await Task19Harness()
        try await unequal.initial()
        try await unequal.offer(participant: 1, count: 2)
        try await unequal.offer(participant: 2, count: 1)
        XCTAssertThrowsError(try unequal.publisher.publish(ticket: unequal.publisher.ticket, now: Task19.second, naturalEnd: true))
        XCTAssertFalse(unequal.publisher.visible!.media.values.contains { $0.text.contains("ENDLIST") })
    }

    func testNaturalEndOwnedDrainWaitsForEachRealGateAndPublishesAllEightTails() async throws {
        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let h = try await Task19Harness(terminalLogicalSequence: 13, publicationClock: timing)
        try await h.initial()
        try await h.offerBoth(count: 8)
        let finished = Task19Counter()
        let task = Task { let result = try await h.publisher.drainNaturalEnd(); finished.add(); return result }
        defer { task.cancel(); h.publisher.close() }
        await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
        clock.set(100 + UInt64(Task19.second) - 1)
        clock.fireDeadlineTimerEarly()
        await Task.yield()
        XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, 5)
        XCTAssertEqual(finished.value, 0)
        for offset in 1...8 {
            clock.set(100 + UInt64(offset) * UInt64(Task19.second))
            await assertNaturalEndEventually {
                h.publisher.visible?.media[1]?.logicalSequences.last == UInt64(5 + offset)
            }
            XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 8 - offset)
            XCTAssertEqual(h.publisher.visible!.media.values.allSatisfy {
                $0.text.contains("#EXT-X-ENDLIST")
            }, offset == 8)
            if offset < 8 {
                XCTAssertEqual(finished.value, 0)
                await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
            }
        }
        let result = try await task.value
        XCTAssertEqual(result, .endListPublished)
        XCTAssertEqual(finished.value, 1)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 9)
        XCTAssertEqual(clock.deadlineTimerHandlerInstallationCount, 1)
        XCTAssertEqual(h.store.capacityWaiterCount, 0)
        XCTAssertFalse(clock.hasScheduledDeadlineTimer)
    }

    func testNaturalEndEntryUsesElapsedTimeSinceCommitAndNeverRenewsExpiredBudget() async throws {
        for elapsed in [UInt64(999_999_999), UInt64(3_000_000_001)] {
            let clock = ManualPlaybackClock(100)
            let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
            let h = try await Task19Harness(terminalLogicalSequence: 6, publicationClock: timing)
            try await h.initial()
            try await h.offerBoth(count: 1)
            clock.set(100 + elapsed)
            let task = Task { try await h.publisher.drainNaturalEnd() }
            defer { task.cancel(); h.publisher.close() }
            if elapsed < UInt64(Task19.second) {
                await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
                XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
                clock.set(100 + UInt64(Task19.second))
                let result = try await task.value
                XCTAssertEqual(result, .endListPublished)
                XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
            } else {
                do { _ = try await task.value; XCTFail("EOF entry must not renew an expired publication ticket") }
                catch { XCTAssertEqual(error as? HLSPublicationFailure, .deadlineExceeded) }
                XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
            }
        }
    }

    func testNaturalEndCancellationCloseAndParticipantFenceCannotPublishLateTail() async throws {
        for terminal in 0..<3 {
            let clock = ManualPlaybackClock(100)
            let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
            let h = try await Task19Harness(audioOnly: true, audioCount: 2,
                terminalLogicalSequence: 6, publicationClock: timing)
            try await h.initial()
            try await h.offerBoth(count: 1)
            let task = Task { try await h.publisher.drainNaturalEnd() }
            defer { task.cancel(); h.publisher.close() }
            await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
            let ticket = h.publisher.ticket
            if terminal == 0 { task.cancel() }
            else if terminal == 1 { h.publisher.close() }
            else { _ = try h.publisher.reconfigure(retiring: [3], ticket: ticket) }
            do { _ = try await task.value; XCTFail("Retired EOF wait must fail") }
            catch {
                if terminal == 0 { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? HLSPublicationFailure, terminal == 1 ? .closed : .staleTicket) }
            }
            clock.set(100 + UInt64(Task19.second))
            XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
            XCTAssertFalse(h.publisher.visible!.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
            XCTAssertEqual(h.store.capacityWaiterCount, 0)
            XCTAssertFalse(clock.hasScheduledDeadlineTimer)
        }
    }

    func testNaturalEndFailureWakeKeepsOriginalDiagnosticAndDoesNotPublish() async throws {
        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let h = try await Task19Harness(terminalLogicalSequence: 6, publicationClock: timing)
        try await h.initial()
        try await h.offerBoth(count: 1)
        let scope = Task19NaturalEndScope()
        let original = ErrorDiagnosticSnapshot(NSError(domain: "HLS.EOF.Original", code: -91))
        let task = Task { try await h.publisher.drainNaturalEnd(scope: scope) }
        defer { task.cancel(); h.publisher.close() }
        await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
        scope.fail(original)
        timing.signal()
        do { _ = try await task.value; XCTFail("The original graph failure must interrupt its EOF wait") }
        catch { XCTAssertEqual(error as? ErrorDiagnosticSnapshot, original) }
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
        XCTAssertFalse(h.publisher.visible!.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
        XCTAssertFalse(clock.hasScheduledDeadlineTimer)
    }

    func testNaturalEndFailureScopeRejectsTheDuePublicationBeforeItsCAS() async throws {
        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let h = try await Task19Harness(terminalLogicalSequence: 6, publicationClock: timing)
        try await h.initial()
        try await h.offerBoth(count: 1)
        clock.set(100 + UInt64(Task19.second))
        let failure = ErrorDiagnosticSnapshot(NSError(domain: "HLS.EOF.BeforeCAS", code: -92))
        let scope = Task19NaturalEndScope()
        scope.fail(failure)
        do {
            _ = try await h.publisher.drainNaturalEnd(scope: scope)
            XCTFail("A failure holding the graph publication scope must win before a due CAS")
        } catch { XCTAssertEqual(error as? ErrorDiagnosticSnapshot, failure) }
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
        XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 1)
        XCTAssertFalse(h.publisher.visible!.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
        XCTAssertEqual(h.store.capacityWaiterCount, 0)
        h.publisher.close()
    }

    func testNaturalEndCommittedSnapshotSurvivesLaterFailureWithoutReportingSuccess() async throws {
        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let h = try await Task19Harness(terminalLogicalSequence: 6, publicationClock: timing)
        try await h.initial()
        try await h.offerBoth(count: 1)
        clock.set(100 + UInt64(Task19.second))
        let failure = ErrorDiagnosticSnapshot(NSError(domain: "HLS.EOF.AfterCAS", code: -93))
        let scope = Task19NaturalEndScope(failAfterOperation: failure)
        let successes = Task19Counter()
        do {
            _ = try await h.publisher.drainNaturalEnd(scope: scope)
            successes.add()
            XCTFail("A later first failure must prevent a successful terminal result")
        } catch { XCTAssertEqual(error as? ErrorDiagnosticSnapshot, failure) }
        XCTAssertEqual(successes.value, 0)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
        XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, 6)
        XCTAssertTrue(h.publisher.visible!.media.values.allSatisfy { $0.text.contains("#EXT-X-ENDLIST") },
            "The failure cannot retroactively rewrite the already committed immutable snapshot")
        XCTAssertFalse(clock.hasScheduledDeadlineTimer)
        h.publisher.close()
    }

    func testLiveProducerBackpressureWaitsForCompleteCommonPrefixNotLeadingTrack() async throws {
        let h = try await Task19Harness()
        defer { h.publisher.close() }
        try await h.initial()
        try await h.offer(participant: 1, count: 4)
        XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 4)
        XCTAssertFalse(h.publisher.shouldBackpressureProducer,
            "Video skew must leave room for the matching audio to reach the publisher")
        XCTAssertEqual(try h.publisher.nextLivePublicationWake(now: 0), 3 * Task19.second,
            "Missing audio waits on the original deadline, not a spinning due gate")
        try await h.offer(participant: 2, count: 3)
        XCTAssertFalse(h.publisher.shouldBackpressureProducer)
        try await h.offer(participant: 2, count: 1)
        XCTAssertTrue(h.publisher.shouldBackpressureProducer)
        XCTAssertEqual(try h.publisher.nextLivePublicationWake(now: 0), Task19.second)
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second), .published)
        XCTAssertFalse(h.publisher.shouldBackpressureProducer,
            "Consuming one common pending segment must release the bounded producer wait")
    }

    func testLiveGateFollowsVaryingRealSegmentDurationsAcrossOneBurst() async throws {
        let durations = [1, 3, 2, 4, 2, 1, 3].map { Task19.time(Int64($0)) }
        let clock = ManualPlaybackClock(90 * UInt64(Task19.second))
        let timing = try HLSNaturalEndPublicationClock.make(
            clock: clock, usesAbsoluteMonotonicTime: true)
        let h = try await Task19Harness(publicationDeadlineNanoseconds: 20 * Task19.second,
            initialWindowMinimumSeconds: 3, publicationClock: timing,
            plannedSegmentDurations: durations)
        defer { h.publisher.close(); timing.stopWaiting() }
        let origin = Int64(clock.nowNanoseconds)
        try await h.offerBoth(count: 3, now: origin)
        XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences, [0, 1, 2])
        try await h.offerBoth(count: 4, now: origin)
        XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 4)
        var elapsed: Int64 = 0
        for (offset, seconds) in [4, 2, 1, 3].enumerated() {
            elapsed += Int64(seconds) * Task19.second
            XCTAssertEqual(try h.publisher.nextLivePublicationWake(now: Int64(clock.nowNanoseconds)), origin + elapsed)
            clock.set(UInt64(origin + elapsed - 1))
            XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket,
                now: timing.now().logical), .waiting)
            XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, UInt64(2 + offset))
            clock.advance(nanoseconds: 1)
            XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket,
                now: timing.now().logical), .published)
            XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, UInt64(3 + offset))
            XCTAssertFalse(h.publisher.visible!.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
        }
        XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 0)
    }

    func testLiveClockCoalescesCapacitySignalAcrossRearmWithoutInlineReentry() throws {
        let clock = Task19HeldPublicationClock()
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock, usesAbsoluteMonotonicTime: true)
        let calls = Task19Counter()
        timing.installLiveWakeHandler { calls.add() }
        defer { timing.stopWaiting(); clock.timer.releaseHandler() }
        timing.consumeSignal()
        timing.signal() // store capacity changed after graph inspected its state.
        timing.scheduleLiveWake(until: 500)
        XCTAssertEqual(clock.timer.deadline, 100,
            "Installing a later media gate must not discard an already pending capacity wake")
        XCTAssertEqual(calls.value, 0, "Store-lock signals must never synchronously re-enter graph")
        let delivery = try XCTUnwrap(clock.timer.captureHandler())
        delivery()
        XCTAssertEqual(calls.value, 1)
        timing.consumeSignal()
        timing.scheduleLiveWake(until: 500)
        clock.set(499)
        delivery()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(clock.timer.deadline, 500)
        clock.set(500)
        delivery()
        XCTAssertEqual(calls.value, 2)
        timing.removeLiveWakeHandler()
        clock.set(900)
        delivery()
        XCTAssertEqual(calls.value, 2, "An old physical delivery cannot revive a retired live handler")
        XCTAssertNil(clock.timer.deadline)
    }

    func testLiveClockHandsItsOnlyTimerToNaturalEndAndRejectsLateLiveDelivery() async throws {
        let clock = Task19HeldPublicationClock()
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let liveCalls = Task19Counter()
        timing.installLiveWakeHandler { liveCalls.add() }
        timing.scheduleLiveWake(until: 200)
        let oldDelivery = try XCTUnwrap(clock.timer.captureHandler())
        timing.removeLiveWakeHandler()
        timing.consumeSignal()
        let task = Task { try await timing.wait(until: 300) }
        defer { task.cancel(); timing.stopWaiting(); clock.timer.releaseHandler() }
        await assertNaturalEndEventually { clock.timer.deadline == 300 }
        clock.set(200)
        oldDelivery()
        XCTAssertEqual(liveCalls.value, 0)
        XCTAssertEqual(clock.timer.deadline, 300)
        clock.set(300)
        oldDelivery()
        try await task.value
        XCTAssertEqual(liveCalls.value, 0)
        timing.stopWaiting()
        oldDelivery()
        XCTAssertEqual(liveCalls.value, 0)
        XCTAssertNil(clock.timer.deadline)
    }

    func testLiveCapacityReleaseUsesPublicationClockInsteadOfHTTPStoreUptime() async throws {
        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let h = try await Task19Harness(audioCount: 3, publicationClock: timing)
        defer { h.publisher.close() }
        try await h.initial()
        let pinned = try (1...4).map {
            try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 0))
        }
        try await h.offerBoth(count: 1)
        clock.set(100 + UInt64(Task19.second))
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second), .published)
        try await h.offerBoth(count: 1, now: Task19.second)
        clock.set(100 + 2 * UInt64(Task19.second))
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: 2 * Task19.second), .waiting)
        XCTAssertEqual(h.store.capacityWaiterCount, 1)
        // Production HTTP releases use host uptime. A capacity wake must re-read
        // the injected publication clock rather than expire its still-valid ticket
        // against an unrelated store timestamp.
        for lease in pinned {
            h.store.release(lease, completedAt: nil, now: 4_000_000_000_000)
        }
        await assertNaturalEndEventually { h.publisher.visible?.publicationSequence == 3 }
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 3,
            "Ordinary live capacity release must publish a valid pending segment without another callback")
        XCTAssertEqual(h.publisher.ticket.previousPublishInstant, 2 * Task19.second)
        XCTAssertEqual(h.store.capacityWaiterCount, 0)
        XCTAssertFalse(h.publisher.visible!.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
    }

    func testNaturalEndCapacityWakeUsesOneSlotAndCommitAnchorIncludesOrdinaryWake() async throws {
        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let h = try await Task19Harness(audioCount: 3, terminalLogicalSequence: 8, publicationClock: timing)
        try await h.initial()
        let old = try (1...4).map { try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 0)) }
        try await h.offerBoth(count: 1)
        clock.set(100 + UInt64(Task19.second))
        _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
        try await h.offerBoth(count: 1, now: Task19.second)
        clock.set(100 + 2 * UInt64(Task19.second))
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: 2 * Task19.second), .waiting)
        XCTAssertEqual(h.store.capacityWaiterCount, 1)
        for lease in old { h.store.release(lease, completedAt: nil, now: 2 * Task19.second) }
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 3,
            "The ordinary capacity callback must still publish without an external retry")
        let pinned = try (1...4).map { try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 2 * Task19.second)) }
        try await h.offerBoth(count: 1, now: 2 * Task19.second)
        let task = Task { try await h.publisher.drainNaturalEnd() }
        defer { task.cancel(); h.publisher.close() }
        await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
        clock.set(100 + 3 * UInt64(Task19.second) - 1)
        clock.fireDeadlineTimerEarly()
        await Task.yield()
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 3,
            "The auto-publication at logical 2s must own the new monotonic anchor")
        clock.set(100 + 3 * UInt64(Task19.second))
        let result = try await task.value
        XCTAssertEqual(result, .endListPublished)
        XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, 8)
        for lease in pinned { h.store.release(lease, completedAt: nil, now: 3 * Task19.second) }
    }

    func testNaturalEndCapacityReleaseDeadlineAndCancellationKeepOneOwnedWait() async throws {
        for outcome in 0..<3 {
            let clock = ManualPlaybackClock(100)
            let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
            let h = try await Task19Harness(audioCount: 3, terminalLogicalSequence: 8, publicationClock: timing)
            try await h.initial()
            let old = try (1...4).map { try XCTUnwrap(h.store.acquireSnapshot(participantID: UInt64($0), now: 0)) }
            try await h.offerBoth(count: 1)
            clock.set(100 + UInt64(Task19.second))
            _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second)
            try await h.offerBoth(count: 2, now: Task19.second)
            let finished = Task19Counter()
            let task = Task { let result = try await h.publisher.drainNaturalEnd(); finished.add(); return result }
            defer { task.cancel(); h.publisher.close() }
            await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
            clock.set(100 + 2 * UInt64(Task19.second))
            await assertNaturalEndEventually { h.store.capacityWaiterCount == 1 }
            XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
            XCTAssertEqual(h.publisher.ticket.absoluteDeadline, 4 * Task19.second)
            XCTAssertEqual(finished.value, 0)
            if outcome == 1 { clock.set(100 + 4 * UInt64(Task19.second) + 1) }
            if outcome == 2 { task.cancel() }
            if outcome == 0 {
                for lease in old.dropLast() {
                    h.store.release(lease, completedAt: nil, now: 90_000 * Task19.second)
                    XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
                    XCTAssertEqual(h.store.capacityWaiterCount, 1)
                }
                h.store.release(old.last!, completedAt: nil, now: 90_000 * Task19.second)
                await assertNaturalEndEventually { h.publisher.visible?.publicationSequence == 3 }
                XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, 7)
                XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 1)
                XCTAssertEqual(finished.value, 0)
                await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
                clock.set(100 + 3 * UInt64(Task19.second))
                let result = try await task.value
                XCTAssertEqual(result, .endListPublished)
                XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, 8)
            } else {
                do { _ = try await task.value; XCTFail("Blocked terminal publication must not complete") }
                catch {
                    if outcome == 1 { XCTAssertEqual(error as? HLSPublicationFailure, .deadlineExceeded) }
                    else { XCTAssertTrue(error is CancellationError) }
                }
                for lease in old { h.store.release(lease, completedAt: nil, now: 4 * Task19.second + 1) }
                XCTAssertEqual(h.publisher.visible?.publicationSequence, 2,
                    "A late capacity release must not resurrect the cancelled finish runner")
            }
            XCTAssertEqual(h.store.capacityWaiterCount, 0)
            XCTAssertFalse(clock.hasScheduledDeadlineTimer)
        }
    }

    func testNaturalEndShortPrefixIsExplicitlyIncompleteAndEndListOnlyUsesTheGate() async throws {
        let shortClock = ManualPlaybackClock(100)
        let shortTiming = try HLSNaturalEndPublicationClock.make(clock: shortClock)
        let short = try await Task19Harness(terminalLogicalSequence: 1, publicationClock: shortTiming)
        try await short.offerBoth(count: 2)
        let shortResult = try await short.publisher.drainNaturalEnd()
        XCTAssertEqual(shortResult, .insufficientInitialCoverage)
        XCTAssertNil(short.publisher.visible,
            "Real writer EOF below initial coverage cannot claim a playable prefix or ENDLIST")
        XCTAssertFalse(shortClock.hasScheduledDeadlineTimer)
        short.publisher.close()

        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let h = try await Task19Harness(terminalLogicalSequence: 5, publicationClock: timing)
        try await h.initial()
        let task = Task { try await h.publisher.drainNaturalEnd() }
        defer { task.cancel(); h.publisher.close() }
        await assertNaturalEndEventually { clock.hasScheduledDeadlineTimer }
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
        XCTAssertFalse(h.publisher.visible!.media.values.contains { $0.text.contains("#EXT-X-ENDLIST") })
        clock.set(100 + UInt64(Task19.second))
        let result = try await task.value
        XCTAssertEqual(result, .endListPublished)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
        XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences.last, 5)
        XCTAssertTrue(h.publisher.visible!.media.values.allSatisfy { $0.text.contains("#EXT-X-ENDLIST") })
        XCTAssertThrowsError(try h.publisher.publish(ticket: h.publisher.ticket, now: 2 * Task19.second, naturalEnd: true))
    }

    func testNaturalEndAnchorStartsAtCompletedCommitAndRejectsClockFaultInsideCommit() throws {
        let clock = ManualPlaybackClock(100)
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        let prepared = try timing.prepareCommit(logical: Task19.second)
        clock.set(200)
        timing.didCommit(prepared)
        clock.set(250)
        XCTAssertEqual(try timing.now().logical, Task19.second + 50,
            "Time spent committing must not let the next gate become visible early")
        let next = try timing.prepareCommit(logical: 2 * Task19.second)
        clock.set(249)
        timing.didCommit(next)
        clock.set(300)
        XCTAssertThrowsError(try timing.now()) { error in
            XCTAssertEqual(error as? HLSPublicationFailure, .arithmeticOverflow,
                "Returning past the old timestamp cannot erase a clock fault during commit")
        }
        timing.stopWaiting()
    }

    func testNaturalEndClockChargeSurvivesCancelledTimerHandlerUntilPhysicalRelease() throws {
        let application = PlaybackApplicationChargeLedger()
        let ledger = PlaybackResourceContextLedger(applicationLedger: application)
        let clock = Task19HeldPublicationClock()
        var timing: HLSNaturalEndPublicationClock? = try HLSNaturalEndPublicationClock.make(clock: clock, ledger: ledger)
        let weakTiming = Task19WeakPublicationClock(try XCTUnwrap(timing))
        XCTAssertEqual(ledger.chargedBytes, HLSNaturalEndPublicationClock.reservationBytes)
        timing?.stopWaiting()
        timing = nil
        XCTAssertNil(weakTiming.value, "The source handler must not strongly retain its owner")
        XCTAssertTrue(clock.timer.cancelled)
        XCTAssertEqual(ledger.chargedBytes, HLSNaturalEndPublicationClock.reservationBytes,
            "Cancellation does not retire the physically held callback capture")
        clock.timer.releaseHandler()
        XCTAssertEqual(ledger.chargedBytes, 0)
        XCTAssertEqual(application.chargedBytes, 0)
    }

    func testNaturalEndClockAccountsRealObjectsAndReleasesOnlyItsOwnedReservation() async throws {
        let application = PlaybackApplicationChargeLedger()
        let ledger = PlaybackResourceContextLedger(applicationLedger: application)
        let other = try ledger.reserve(allocationIdentity: .stable(UUID()), bytes: 17)
        var timing: HLSNaturalEndPublicationClock? = try HLSNaturalEndPublicationClock.make(ledger: ledger)
        let weakTiming = Task19WeakPublicationClock(try XCTUnwrap(timing))
        let measured = try XCTUnwrap(timing).knownAllocationUpperBoundBytes
        print("HLS_EOF_CLOCK_ALLOCATION measuredObjectsPlusFixedABI=\(measured) reserved=\(HLSNaturalEndPublicationClock.reservationBytes) nativeSourceAllowance=128")
        XCTAssertGreaterThan(measured, 0)
        XCTAssertLessThanOrEqual(measured, HLSNaturalEndPublicationClock.reservationBytes)
        XCTAssertEqual(ledger.chargedBytes, HLSNaturalEndPublicationClock.reservationBytes + 17)
        XCTAssertEqual(application.chargedBytes, ledger.chargedBytes)
        timing?.stopWaiting()
        timing = nil
        await assertNaturalEndEventually { weakTiming.value == nil && ledger.chargedBytes == 17 }
        XCTAssertEqual(application.chargedBytes, 17)
        ledger.release(other)
        XCTAssertEqual(application.chargedBytes, 0)
    }

    func testNaturalEndWaitKeepsSignalBeforeInstallAndRejectsOldTimerAfterRearm() async throws {
        let clock = Task19HeldPublicationClock()
        let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
        timing.consumeSignal()
        timing.signal() // capacity changes after state read, before continuation installation.
        try await timing.wait(until: 200)
        XCTAssertNil(clock.timer.deadline)

        let first = Task { try await timing.wait(until: 200) }
        await assertNaturalEndEventually { clock.timer.deadline == 200 }
        let oldDelivery = try XCTUnwrap(clock.timer.captureHandler())
        timing.signal()
        try await first.value
        timing.consumeSignal()
        let completions = Task19Counter()
        let second = Task { try await timing.wait(until: 300); completions.add() }
        await assertNaturalEndEventually { clock.timer.deadline == 300 }
        clock.set(200)
        oldDelivery()
        XCTAssertEqual(completions.value, 0)
        XCTAssertEqual(clock.timer.deadline, 300,
            "A callback from the previous schedule must preserve the current later deadline")
        clock.set(300)
        oldDelivery()
        try await second.value
        XCTAssertEqual(completions.value, 1)
        timing.stopWaiting()
        do { try await timing.wait(until: 400); XCTFail("A retired wait owner cannot be reused") }
        catch { XCTAssertEqual(error as? HLSPublicationFailure, .closed) }
        XCTAssertThrowsError(try timing.now()) { error in
            XCTAssertEqual(error as? HLSPublicationFailure, .closed)
        }
        clock.timer.releaseHandler()
    }

    func testNaturalEndClockRejectsBackwardsTimeAndOverflowWithoutPublishing() async throws {
        for backwards in [true, false] {
            let origin: UInt64 = backwards ? 100 : UInt64.max - 10
            let clock = ManualPlaybackClock(origin)
            let timing = try HLSNaturalEndPublicationClock.make(clock: clock)
            let h = try await Task19Harness(terminalLogicalSequence: 6, publicationClock: timing)
            try await h.initial()
            try await h.offerBoth(count: 1)
            if backwards { clock.set(99) }
            do { _ = try await h.publisher.drainNaturalEnd(); XCTFail("An invalid clock must not authorize publication") }
            catch { XCTAssertEqual(error as? HLSPublicationFailure, .arithmeticOverflow) }
            XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
            XCTAssertEqual(h.store.capacityWaiterCount, 0)
            h.publisher.close()
        }
    }

    private func assertNaturalEndEventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline { await Task.yield() }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testReviewI4RejectsUnboundReportsWholeOffsetAndIllegalFirstShortWindow() async throws {
        for start in [Task19.time(100), Task19.time(-1, 48_000), Task19.time(1, 48_000)] {
            await assertTask19ThrowsError(try await Task19Harness(audioStart: start))
        }
        let unbound = try await Task19Harness.detachedParticipants()
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        XCTAssertThrowsError(try HLSPublicationCoordinator(store: store, participants: unbound,
            declaration: Task19.declaration(), anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0)))
        for duration in [Task19.time(599, 600), Task19.time(4, 5)] {
            try await Task19Harness.checkShortEOFAndUnregisteredWriterSplicing(duration: duration)
        }
    }

    func testReviewI4FormalAUBoundsAndSteadySevenWindowKeepExactReceipts() async throws {
        for kind in [SegmentAudioAccessUnitKind.aac(sampleRate: 48_000), .ac3(sampleRate: 48_000),
                     .eac3Aggregated(sampleRate: 48_000, sampleCount: 1_536)] {
            let limit = kind.sampleRateAndCount.count
            for ticks in [-1, 0, 1, limit - 1, limit, limit + 1] {
                try Task19FormalBoundaryChecks.check(kind: kind, offsetTicks: ticks, accepted: ticks >= 0 && ticks < limit)
            }
        }
        let h = try await Task19Harness()
        try await h.initial()
        XCTAssertTrue(h.publisher.visible!.coverage.isSixSegmentWindowEligible)
        for index in 1...2 {
            try await h.offerBoth(count: 1)
            XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: Int64(index) * Task19.second), .published)
        }
        let coverage = h.publisher.visible!.coverage
        XCTAssertFalse(coverage.isSixSegmentWindowEligible)
        XCTAssertEqual(coverage.publishedWindow, Array(1...7))
        XCTAssertEqual(coverage.logicalSequences, Array(2...7))
        let audio = try XCTUnwrap(coverage.participants.first { $0.participantID == 2 })
        XCTAssertEqual(audio.ranges.first?.start, Task19.time(96_256, 48_000))
        XCTAssertEqual(audio.ranges.last?.end, Task19.time(384_000, 48_000))
        try Task19FormalBoundaryChecks.checkAccumulatingDrift()
    }

    func testReviewI5AudioCandidatesUseUniqueItemBundlesAndRejectTicketReplay() async throws {
        let h = try await Task19Harness(audioOnly: true, audioCount: 3)
        try await h.initial()
        let vector = h.publisher.ticket.participantVector
        XCTAssertEqual(Set(vector.map { $0.binding.itemGeneration }).count, 3)
        XCTAssertEqual(Set(vector.compactMap(\.candidateTicket)).count, 3)
        XCTAssertNil(h.publisher.visible?.master)
        for entry in vector {
            XCTAssertTrue(h.publisher.visible!.media[entry.participantID]!.text.contains("/\(entry.binding.itemGeneration.rawValue)/"))
        }
        try await Task19CandidateChecks.rejectReusedGenerationWrongTicketAndCrossBundleReceipt()
        try await Task19Harness(audioOnly: true, audioCount: 2).checkCandidatePreparationAndRejection()
    }

    func testReviewI6VideoReconfigurationRetiresWholeFrozenMasterAndLateEpochIsReleaseOnly() async throws {
        for retiredID: UInt64 in [1, 2] {
            let h = try await Task19Harness()
            try await h.initial()
            let ticket = h.publisher.ticket
            let result = try h.publisher.reconfigure(retiring: [retiredID], ticket: ticket)
            XCTAssertTrue(h.publisher.isClosed, "冻结 master 改集合必须整体退休旧 item")
            XCTAssertEqual(result.retiredParticipantIDs, [1, 2])
            XCTAssertNil(try h.store.acquireMasterSnapshot(now: 0))
            for id: UInt64 in [1, 2] { XCTAssertNil(try h.store.acquireSnapshot(participantID: id, now: 0)) }
        }
        let h = try await Task19Harness()
        try await h.initial()
        let oldTicket = h.publisher.ticket
        let oldTracks = h.tracks
        try await h.beginEpoch(2)
        for id: UInt64 in [1, 2] {
            let late = try await oldTracks[id]!.next()
            XCTAssertEqual(try h.publisher.offer(late.object, receipt: late.receipt, relay: late.relay,
                ticket: oldTicket, now: 0), .releasedOnly)
            XCTAssertEqual(late.relay.usage.unpublishedLogicalSegmentCount, 0)
        }
        try await h.offerBoth(count: 1)
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second), .published)
        try await Task19Harness(audioOnly: true, audioCount: 2).checkCandidateRollbackAndAtomicCommit()
    }

    func testReviewI8ActualFrozenFormatsAndItemLocalURIsCannotBeMisadvertised() async throws {
        for mutation in 0..<8 {
            await assertTask19ThrowsError(try await Task19Harness(declarationMutation: { declaration in
                switch mutation {
                case 0: declaration.audio[0].channels = 8
                case 1: declaration.audio[0].codec = .ac3
                case 2: declaration.audio[0].codec = .eac3
                case 3: declaration.video!.codec = "avc1.640033"
                case 4: declaration.video!.width += 1
                case 5: declaration.video!.height += 1
                case 6: declaration.video!.videoRange = "PQ"
                default: declaration.video!.frameRateMilli += 1
                }
            }).initial())
        }
        var duplicate = try Task19.declaration(audioCount: 2)
        duplicate.audio[1].renditionID = duplicate.audio[0].renditionID
        XCTAssertThrowsError(try HLSPlaylistSerializer.master(duplicate))
        try await Task19CandidateChecks.rejectOldFormatProofAndCrossBundleReceipt()
    }

    func testVideoSixWaitsForAudioAndPublishesOneAtomicVector() async throws {
        let h = try await Task19Harness()
        try await h.offer(participant: 1, count: 6)
        XCTAssertNil(h.publisher.visible)
        try await h.offer(participant: 2, count: 6)
        let visible = try XCTUnwrap(h.publisher.visible)
        XCTAssertNotNil(visible.master)
        XCTAssertEqual(visible.media.count, 2)
        XCTAssertEqual(visible.participantVector.map(\.participantID), [1, 2])
        XCTAssertEqual(h.publisher.invalidPublicationCount, 0)
        XCTAssertEqual(visible.media.mapValues { $0.logicalSequences }, [1: Array(0...5), 2: Array(0...5)])
        XCTAssertEqual(h.tracks[1]?.relay.usage.unpublishedLogicalSegmentCount, 0)
        XCTAssertEqual(h.tracks[2]?.relay.usage.unpublishedLogicalSegmentCount, 0)
    }

    func testInitialThreeSecondWindowPublishesBeforeSixSegmentSteadyState() async throws {
        let h = try await Task19Harness(initialWindowMinimumSeconds: 3)
        try await h.offer(participant: 1, count: 3)
        XCTAssertNil(h.publisher.visible)

        try await h.offer(participant: 2, count: 3)

        let visible = try XCTUnwrap(h.publisher.visible)
        XCTAssertEqual(
            visible.media.mapValues(\.logicalSequences),
            [1: Array(0...2), 2: Array(0...2)]
        )
        XCTAssertEqual(visible.coverage.logicalSequences, Array(0...2))
        XCTAssertFalse(visible.coverage.isSixSegmentWindowEligible)
    }

    func testInitialFourSecondWindowRequiresEachTrackWithoutWaitingForSix() async throws {
        let h = try await Task19Harness(initialWindowMinimumSeconds: 4)
        try await h.offerBoth(count: 3)
        XCTAssertNil(h.publisher.visible, "Three seconds must not satisfy the four-second mode")
        try await h.offer(participant: 1, count: 1)
        XCTAssertNil(h.publisher.visible, "Every participant must independently cover four seconds")
        try await h.offer(participant: 2, count: 1)
        let first = try XCTUnwrap(h.publisher.visible)
        XCTAssertEqual(first.media.mapValues(\.logicalSequences), [1: Array(0...3), 2: Array(0...3)])
        XCTAssertEqual(first.coverage.logicalSequences, Array(0...3))
        XCTAssertFalse(first.coverage.isSixSegmentWindowEligible)
        try await h.offerBoth(count: 1)
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: Task19.second), .published)
        XCTAssertEqual(h.publisher.visible?.media.mapValues(\.logicalSequences),
                       [1: Array(0...4), 2: Array(0...4)])
    }

    func testInitialWindowBoundsTrackSkewInsteadOfAbsoluteVideoSequence() async throws {
        let h = try await Task19Harness()
        try await h.offerBoth(count: 5)

        await assertTask19NoThrow(try await h.offer(participant: 1, count: 4),
            "音频已到第 5 段时，视频先到第 9 段仍是四段的有界轨间偏斜")
        XCTAssertNil(h.publisher.visible)

        try await h.offer(participant: 2, count: 1)
        XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences, Array(0...5))
        XCTAssertEqual(h.publisher.visible?.media[2]?.logicalSequences, Array(0...5))
    }

    func testInitialSixSevenAndEighthInvariantUseEachReceiptDuration() async throws {
        let legal = try await Task19Harness()
        try await legal.initial()
        XCTAssertEqual(legal.publisher.visible?.media[1]?.logicalSequences.count, 6)
        // 短 EOF 不首发；禁止把六个独立终态 writer 伪装成同一连续窗口。
        for duration in [Task19.time(599, 600), Task19.time(4, 5)] {
            try await Task19Harness.checkShortEOFAndUnregisteredWriterSplicing(duration: duration)
        }
        let h = try await Task19Harness()
        try await h.offer(participant: 1, count: 7)
        await assertTask19ThrowsError(try await h.offer(participant: 1, count: 1))
        XCTAssertNil(h.publisher.visible)
    }

    func testIdentityReceiptBackingAndOrderingFailuresPreserveOwnership() async throws {
        let h = try await Task19Harness()
        let packet = try await h.tracks[1]!.next()
        let ticket = h.publisher.ticket
        let other = try await Task19Track(id: 3, mediaType: .video).next()
        let copies = [Task19.copy(packet.object), Task19.copy(packet.object, sequence: 1),
            Task19.copy(packet.object, binding: Task19.binding(id: 1, epoch: 2)),
            Task19.copy(packet.object, binding: Task19.binding(id: 2)),
            Task19.copy(packet.object, binding: Task19.binding(id: 1, writer: 99))]
        for copy in copies {
            XCTAssertThrowsError(try h.publisher.offer(copy, receipt: packet.receipt, relay: packet.relay, ticket: ticket, now: 0))
        }
        XCTAssertThrowsError(try h.publisher.offer(packet.object, receipt: other.receipt, relay: packet.relay, ticket: ticket, now: 0))
        XCTAssertEqual(packet.relay.usage.unpublishedLogicalSegmentCount, 1)
        try h.publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay, ticket: ticket, now: 0)
        XCTAssertThrowsError(try h.publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay, ticket: ticket, now: 0))
        XCTAssertEqual(packet.relay.usage.unpublishedLogicalSegmentCount, 0)
        XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 1)
        let video = try await Task19Track(id: 1, mediaType: .video)
        let audio = try await Task19Track(id: 2, mediaType: .audio)
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        XCTAssertThrowsError(try HLSPublicationCoordinator(store: store, participants: [
            .init(initialization: video.initialization, proof: video.proof, relay: video.relay, candidateTicket: nil),
            .init(initialization: audio.initialization, proof: audio.proof, relay: video.relay, candidateTicket: nil)],
            declaration: Task19.declaration(), anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0)))
        XCTAssertEqual(store.usage.resourceCount, 0, "第二条失败不得部分接管第一条 init")
        XCTAssertEqual(store.usage.reservedBytes, 0)
        XCTAssertTrue(video.relay.releaseForControl(video.initialization), "失败后 init 的原拥有者仍有准确释放权")
    }

    func testSteadyEarliestDeadlineAndStaleTimerBoundaries() async throws {
        for instant: Int64 in [999_999_999, 1_000_000_000, 2_999_999_999, 3_000_000_000, 3_000_000_001] {
            let h = try await Task19Harness()
            try await h.initial()
            let old = h.publisher.ticket
            try await h.offerBoth(count: 1)
            if instant < 1_000_000_000 {
                XCTAssertEqual(try h.publisher.publish(ticket: old, now: instant), .waiting)
                XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
            } else if instant <= 3_000_000_000 {
                XCTAssertEqual(try h.publisher.publish(ticket: old, now: instant), .published)
                XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
                XCTAssertThrowsError(try h.publisher.publish(ticket: old, now: instant))
                XCTAssertThrowsError(try h.publisher.deadline(ticket: old, now: 3_000_000_001))
                XCTAssertFalse(h.publisher.isClosed)
            } else {
                XCTAssertThrowsError(try h.publisher.publish(ticket: old, now: instant))
                XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
            }
        }
        for instant: Int64 in [2_999_999_999, 3_000_000_000, 3_000_000_001] {
            let h = try await Task19Harness()
            try await h.initial()
            try await h.offer(participant: 1, count: 1)
            if instant < 3_000_000_000 {
                XCTAssertEqual(try h.publisher.deadline(ticket: h.publisher.ticket, now: instant), .waiting)
            } else {
                XCTAssertThrowsError(try h.publisher.deadline(ticket: h.publisher.ticket, now: instant))
                XCTAssertTrue(h.publisher.isClosed)
            }
        }
        let twoSeconds = try await Task19Harness(audioDuration: Task19.time(2), videoDuration: Task19.time(2))
        try await twoSeconds.initial()
        try await twoSeconds.offerBoth(count: 1)
        XCTAssertEqual(try twoSeconds.publisher.publish(ticket: twoSeconds.publisher.ticket, now: 1_999_999_999), .waiting)
        XCTAssertEqual(try twoSeconds.publisher.publish(ticket: twoSeconds.publisher.ticket, now: 2_000_000_000), .published)
    }

    func testBacklogFourEightAndOneSegmentPerTransaction() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        try await h.offerBoth(count: 3)
        XCTAssertFalse(h.publisher.shouldBackpressure)
        try await h.offerBoth(count: 1)
        XCTAssertTrue(h.publisher.shouldBackpressure)
        try await h.offerBoth(count: 4)
        XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 8)
        await assertTask19ThrowsError(try await h.offer(participant: 1, count: 1))
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: 1_000_000_000), .published)
        XCTAssertEqual(h.publisher.pendingLogicalSequenceCount, 7)
        XCTAssertEqual(h.publisher.visible?.media[1]?.logicalSequences, Array(1...6))
    }

    func testCASRevalidatesFullVectorAndConcurrentCommitHasOneWinner() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        try await h.offerBoth(count: 1)
        let ticket = h.publisher.ticket
        var stale = ticket
        stale.participantVector[0].expectedPreviousSnapshotVersion = 0
        XCTAssertThrowsError(try h.publisher.publish(ticket: stale, now: 1_000_000_000))
        stale = ticket
        stale.participantVector[1].expectedLogicalSequence = 99
        XCTAssertThrowsError(try h.publisher.publish(ticket: stale, now: 1_000_000_000))
        let wins = Task19Counter()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if (try? h.publisher.publish(ticket: ticket, now: 1_000_000_000)) == .published { wins.add() }
        }
        XCTAssertEqual(wins.value, 1)
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 2)
    }

    func testParticipantRetirementFencesBeforeStopMigratesSurvivorAndKeepsDeadline() async throws {
        let h = try await Task19Harness(audioOnly: true, audioCount: 2)
        try await h.initial()
        try await h.offer(participant: 2, count: 1)
        let old = h.publisher.ticket
        let late = try await h.tracks[3]!.next()
        let reconfiguration = try h.publisher.reconfigure(retiring: [3], ticket: old)
        XCTAssertEqual(reconfiguration.retiredParticipantIDs, [3])
        XCTAssertTrue(h.publisher.isRetirementFenced(participantID: 3))
        let stopped = Task19Counter()
        h.publisher.confirmRetirement(reconfiguration) {
            XCTAssertTrue(h.publisher.isRetirementFenced(participantID: 3))
            h.tracks[3]!.stopWriter()
            stopped.add()
        }
        XCTAssertEqual(stopped.value, 1)
        XCTAssertEqual(h.publisher.ticket.absoluteDeadline, 3_000_000_000)
        XCTAssertThrowsError(try h.publisher.publish(ticket: old, now: 1_000_000_000))
        let beforeRelease = late.relay.usage.unpublishedLogicalSegmentCount
        XCTAssertEqual(beforeRelease, 2, "同一 relay 还持有 waiting 中准确的前一段")
        XCTAssertEqual(try h.publisher.offer(late.object, receipt: late.receipt, relay: late.relay, ticket: old, now: 1_000_000_000), .releasedOnly)
        XCTAssertEqual(late.relay.usage.unpublishedLogicalSegmentCount, beforeRelease - 1)
        let earlier = try h.takeWaiting(participant: 3)
        XCTAssertEqual(try h.publisher.offer(earlier.object, receipt: earlier.receipt, relay: earlier.relay,
            ticket: old, now: 1_000_000_000), .releasedOnly)
        XCTAssertEqual(earlier.relay.usage.unpublishedLogicalSegmentCount, 0)
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: 1_000_000_000), .published)
        XCTAssertEqual(h.publisher.visible?.media.count, 1)
        _ = try h.publisher.reconfigure(retiring: [2], ticket: h.publisher.ticket)
        XCTAssertTrue(h.publisher.isClosed)
    }

    func testDiscontinuityReplacesAllMapsAtomicallyAndKeepsItemDeclaration() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let oldMaster = h.publisher.visible?.master?.raw
        let oldTicket = h.publisher.ticket
        try await h.beginEpoch(2)
        XCTAssertEqual(h.publisher.ticket.absoluteDeadline, oldTicket.absoluteDeadline)
        XCTAssertThrowsError(try h.publisher.publish(ticket: oldTicket, now: 1_000_000_000))
        try await h.offer(participant: 1, count: 1)
        XCTAssertEqual(h.publisher.visible?.media[1]?.text.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count, 1)
        try await h.offer(participant: 2, count: 1)
        XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: 1_000_000_000), .published)
        for snapshot in h.publisher.visible!.media.values {
            XCTAssertTrue(snapshot.text.contains("#EXT-X-DISCONTINUITY\n#EXT-X-MAP:"))
            XCTAssertTrue(snapshot.text.contains("/2/"))
        }
        XCTAssertEqual(h.publisher.visible?.master?.raw, oldMaster)
    }

    func testNaturalEOFLastSegmentOrUniqueEndOnlyObeysGateAndTeardownDoesNotEnd() async throws {
        for withSegment in [true, false] {
            let h = try await Task19Harness(terminalLogicalSequence: withSegment ? 6 : 5)
            try await h.initial()
            XCTAssertTrue(h.publisher.visible!.media.values.allSatisfy { !$0.isFinal })
            if withSegment { try await h.offerBoth(count: 1) }
            XCTAssertNotNil(h.tracks[2]?.endpointAuthority)
            XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: 999_999_999, naturalEnd: true), .waiting)
            XCTAssertTrue(h.publisher.visible!.media.values.allSatisfy { !$0.isFinal },
                "Knowing EOF before the publication gate does not commit finality")
            XCTAssertEqual(try h.publisher.publish(ticket: h.publisher.ticket, now: 1_000_000_000, naturalEnd: true), .published)
            XCTAssertTrue(h.publisher.visible!.media.values.allSatisfy { $0.isFinal })
            for id in h.tracks.keys {
                let lease = try XCTUnwrap(h.store.acquireSnapshot(participantID: id, now: Task19.second))
                XCTAssertEqual(lease.snapshot?.isFinal, true)
                XCTAssertEqual(lease.snapshot?.effectivePlaybackHorizon,
                               h.publisher.visible?.media[id]?.effectivePlaybackHorizon)
                h.store.release(lease, completedAt: nil, now: Task19.second)
            }
            XCTAssertTrue(h.publisher.visible!.media.values.allSatisfy { $0.text.hasSuffix("#EXT-X-ENDLIST\n") })
            XCTAssertThrowsError(try h.publisher.publish(ticket: h.publisher.ticket, now: 2_000_000_000, naturalEnd: true))
        }
        let h = try await Task19Harness()
        try await h.initial()
        let bytes = h.publisher.visible!.media[1]!.raw
        h.publisher.close()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("ENDLIST"))
    }

    func testStaleFinalPublicationDoesNotPromoteCommittedPrefix() async throws {
        let h = try await Task19Harness(terminalLogicalSequence: 7)
        try await h.initial()
        let prefix = try XCTUnwrap(h.publisher.visible)
        let stale = h.publisher.ticket
        try await h.offerBoth(count: 1)
        XCTAssertEqual(try h.publisher.publish(ticket: stale, now: Task19.second), .published)
        try await h.offerBoth(count: 1, now: Task19.second)
        XCTAssertThrowsError(try h.publisher.publish(ticket: stale,
            now: 2 * Task19.second, naturalEnd: true))
        XCTAssertTrue(h.publisher.visible!.media.values.allSatisfy { !$0.isFinal })
        XCTAssertGreaterThan(h.publisher.visible!.publicationSequence, prefix.publicationSequence)
        for track in h.tracks.values {
            XCTAssertNil(h.store.currentFinalPublication(matching: track.binding))
        }
    }

    func testOfflinePublicationBudgetKeepsTicketValidAfterRealtimeDeadline() async throws {
        let h = try await Task19Harness(publicationDeadlineNanoseconds: 120_000_000_000)
        try await h.initial()

        XCTAssertEqual(h.publisher.ticket.absoluteDeadline, 120_000_000_000)
        XCTAssertEqual(
            try h.publisher.publish(
                ticket: h.publisher.ticket,
                now: 90_000_000_000),
            .waiting)
        XCTAssertThrowsError(
            try h.publisher.publish(
                ticket: h.publisher.ticket,
                now: 120_000_000_001)) { error in
            XCTAssertEqual(error as? HLSPublicationFailure, .deadlineExceeded)
        }
    }

    func testMasterByteFixtureAndActualDeterministicGzip() async throws {
        let declaration = try Task19.declaration()
        let result = try XCTUnwrap(HLSPlaylistSerializer.master(declaration))
        let expected = "#EXTM3U\n#EXT-X-VERSION:10\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac-2\",NAME=\"aac-2-main\",URI=\"/v1/0123456789abcdef0123456789abcdef/19/audio/aac-2/index.m3u8\",CHANNELS=\"2\",LANGUAGE=\"und\",DEFAULT=YES,AUTOSELECT=YES\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=81864000,AVERAGE-BANDWIDTH=81864000,RESOLUTION=1920x1080,FRAME-RATE=24.000,VIDEO-RANGE=SDR,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"aac-2\",SCORE=100\n"
            + "/v1/0123456789abcdef0123456789abcdef/19/video/index.m3u8\n"
        XCTAssertEqual(result.raw, Data(expected.utf8))
        XCTAssertEqual(try Task19.inflate(result.gzip), result.raw)
        XCTAssertEqual(try HLSPlaylistSerializer.master(declaration)?.gzip, result.gzip)
        let h = try await Task19Harness()
        try await h.initial()
        for media in h.publisher.visible!.media.values {
            XCTAssertTrue(media.text.hasPrefix("#EXTM3U\n#EXT-X-VERSION:10\n#EXT-X-TARGETDURATION:2\n"))
            XCTAssertFalse(media.text.contains("INDEPENDENT-SEGMENTS"))
            XCTAssertTrue(media.text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0\n"))
            XCTAssertEqual(try Task19.inflate(media.gzip), media.raw)
        }
    }

    func testAudioOnlyCreatesNoMasterMediaOrStreamTags() async throws {
        let h = try await Task19Harness(audioOnly: true)
        try await h.initial()
        XCTAssertNil(h.publisher.visible?.master)
        XCTAssertEqual(h.publisher.masterCreationCount, 0)
        for media in h.publisher.visible!.media.values {
            XCTAssertFalse(media.text.contains("#EXT-X-MEDIA:"))
            XCTAssertFalse(media.text.contains("#EXT-X-STREAM-INF:"))
            XCTAssertFalse(media.text.contains("INDEPENDENT-SEGMENTS"))
        }
    }

    func testAudioGroupSyntaxRequiredAttributesAndPercentEncodingFailClosed() throws {
        for bad in ["", "a\"b", "a\rb", "a\nb", "a\\b", "a\u{0}b", "a%Q0", "a%2f", "a b"] {
            var declaration = try Task19.declaration()
            declaration.audio[0].renditionID = bad
            XCTAssertThrowsError(try HLSPlaylistSerializer.master(declaration), bad)
        }
        var declaration = try Task19.declaration(audioCount: 3)
        let master = try XCTUnwrap(HLSPlaylistSerializer.master(declaration)).text
        XCTAssertTrue(master.contains("GROUP-ID=\"aac-2\""))
        XCTAssertTrue(master.contains("GROUP-ID=\"aac-8\""))
        XCTAssertTrue(master.contains("GROUP-ID=\"ec3-8\""))
        XCTAssertTrue(master.contains("SCORE=300\n"))
        XCTAssertTrue(master.contains("SCORE=200\n"))
        declaration.audio[1] = declaration.audio[0]
        XCTAssertThrowsError(try HLSPlaylistSerializer.master(declaration))
        declaration = try Task19.declaration()
        declaration.audio[0].language = "\""
        XCTAssertThrowsError(try HLSPlaylistSerializer.master(declaration))
        declaration = try Task19.declaration()
        declaration.audio[0].channels = 0
        XCTAssertThrowsError(try HLSPlaylistSerializer.master(declaration))
        declaration = try Task19.declaration(audioCount: 2)
        declaration.audio[1].score = 100
        XCTAssertThrowsError(try HLSPlaylistSerializer.master(declaration))
        XCTAssertThrowsError(try HLSPlaylistSerializer.validateAudioReferences(["missing"], groups: ["aac-2"]))
    }

    func testFrozenDeclarationsAndPDTStayStableAcrossSlidingAndNewItemChangesURI() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let master = h.publisher.visible!.master!
        for index in 1...8 {
            try await h.offerBoth(count: 1, now: Int64(index - 1) * Task19.second)
            _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Int64(index) * Task19.second)
            XCTAssertEqual(h.publisher.visible?.master?.raw, master.raw)
            XCTAssertEqual(h.publisher.visible?.master?.gzip, master.gzip)
        }
        let texts = h.publisher.visible!.media.values.map(\.text)
        XCTAssertTrue(texts.allSatisfy { $0.contains("#EXT-X-PROGRAM-DATE-TIME:2026-09-09T00:00:08.000Z") })
        var item = try Task19.declaration()
        item.itemGeneration = 20
        XCTAssertNotEqual(try HLSPlaylistSerializer.master(item)?.raw, master.raw)
        XCTAssertTrue(try HLSPlaylistSerializer.master(item)!.text.contains("/20/video/index.m3u8"))
    }

    func testBandwidthMeasuresEveryContinuousSetGroupMaximumAndCheckedSafetyEdges() async throws {
        let samples: [HLSBandwidthSample] = [
            .init(bodyBytes: 1, duration: Task19.time(1, 2)),
            .init(bodyBytes: 100, duration: Task19.time(1, 2)),
            .init(bodyBytes: 1, duration: Task19.time(1, 2)),
            .init(bodyBytes: 1, duration: Task19.time(2))]
        XCTAssertEqual(try HLSBandwidth.measure(samples).peak, 808)
        XCTAssertEqual(try HLSBandwidth.measure(samples).average, 236)
        XCTAssertEqual(try HLSBandwidth.variant(video: samples, audioGroup: [samples, [.init(bodyBytes: 200, duration: Task19.time(1))]]).peak, 2408)
        for (measured, allowed) in [(109, true), (110, false), (111, false)] {
            XCTAssertEqual(try HLSBandwidth.withinLiveAverage(measured: UInt64(measured), declared: 100), allowed)
        }
        XCTAssertThrowsError(try HLSBandwidth.withinLiveAverage(measured: .max, declared: .max))
        XCTAssertThrowsError(try HLSBandwidth.measure([.init(bodyBytes: .max, duration: Task19.time(1))]))
        let h = try await Task19Harness()
        try await h.initial()
        let actual = h.publisher.visible!.media[1]!.bandwidth
        XCTAssertEqual(actual.peak, UInt64(h.tracks[1]!.lastMediaByteCount * 8))
    }

    func testCoverageLongPlaybackRemainsBoundedAndContainsRealRecentSixRanges() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        for index in 1...96 {
            try await h.offerBoth(count: 1, now: Int64(index - 1) * Task19.second)
            _ = try h.publisher.publish(ticket: h.publisher.ticket, now: Int64(index) * Task19.second)
            h.store.sweep(now: Int64(index) * Task19.second)
            XCTAssertLessThanOrEqual(h.store.usage.segmentCount, 96)
            XCTAssertLessThanOrEqual(h.store.usage.tombstoneCount, 192)
            XCTAssertLessThanOrEqual(h.store.usage.snapshotCount, 9)
            XCTAssertLessThanOrEqual(h.publisher.retainedReadinessCount, 28)
        }
        let coverage = try XCTUnwrap(h.publisher.visible?.coverage)
        XCTAssertEqual(coverage.logicalSequences, Array(96...101))
        XCTAssertEqual(coverage.participants.count, 2)
        for participant in coverage.participants {
            XCTAssertEqual(participant.ranges.count, 6)
            XCTAssertEqual(participant.ranges.first?.start, Task19.time(96))
            XCTAssertEqual(participant.ranges.last?.end,
                participant.participantID == 1 ? Task19.time(102) : Task19.time(4_896_768, 48_000))
        }
        XCTAssertEqual(h.publisher.aacPublicationMembershipSnapshots[2]?.count, 102)
        XCTAssertEqual(h.publisher.aacPublicationMembershipSnapshots[2]?.pendingCount, 0)
        XCTAssertLessThanOrEqual(MemoryLayout<PublicationCoverage>.size, 256)
    }

    func testReview2NaturalEndAACRequiresExactWriterEndpointAuthorityAndCommonBoundary() async throws {
        let harness = try await Task19Harness(audioOnly: true)
        try await harness.initial()
        XCTAssertEqual(harness.publisher.aacPublicationMembershipSnapshots[2]?.count, 6)
        let prior = try XCTUnwrap(harness.publisher.visible)
        try await harness.offerBoth(count: 1, now: Task19.second)
        XCTAssertEqual(harness.publisher.aacPublicationMembershipSnapshots[2]?.count, 7)
        XCTAssertEqual(harness.publisher.aacPublicationMembershipSnapshots[2]?.pendingCount, 0)

        XCTAssertThrowsError(try harness.publisher.publish(
            ticket: harness.publisher.ticket,
            now: 2 * Task19.second,
            naturalEnd: true
        ), "natural-end AAC 在发布前必须消费 Task17 endpoint authority 并核准共同边界")
        XCTAssertEqual(harness.publisher.visible?.publicationSequence,
                       prior.publicationSequence,
                       "缺少 endpoint authority 时不得推进 ENDLIST publication")
    }
}

/// proxy 只改变真实 delegate 的转发参数，真实 adapter 与 AVAssetWriter 始终保留。
final class Task19CallbackProxyFactory: SegmentedFMP4SystemWriterFactory, @unchecked Sendable {
    enum Mutation: CaseIterable { case unchanged, initializationBytes, mediaBytes, report, writer, kind, replay }
    private final class Proxy: SegmentedFMP4SystemCallbackSink, @unchecked Sendable {
        weak var downstream: (any SegmentedFMP4SystemCallbackSink)?
        let mutation: Mutation
        let wrongWriter = NSObject()
        private let lock = NSLock()
        private let deliveryQueue = DispatchQueue(label: "task19.callback-proxy")
        private var firstMedia: (ObjectIdentifier, Data, AVAssetSegmentType, SegmentedFMP4SystemReportEvidence)?
        init(_ downstream: any SegmentedFMP4SystemCallbackSink, mutation: Mutation) {
            self.downstream = downstream; self.mutation = mutation
        }
        func receiveSystemSegment(writerObjectIdentity: ObjectIdentifier, bytes: Data, type: AVAssetSegmentType,
                                  report: SegmentedFMP4SystemReportEvidence) {
            // proxy 不能阻塞系统 delegate 队列等待同步 cancel；固定测试输入最多两个 media callback。
            deliveryQueue.async { self.forward(writerObjectIdentity: writerObjectIdentity, bytes: bytes, type: type, report: report) }
        }
        private func forward(writerObjectIdentity: ObjectIdentifier, bytes: Data, type: AVAssetSegmentType,
                             report: SegmentedFMP4SystemReportEvidence) {
            if mutation == .replay && type == .separable {
                let previous = lock.withLock { () -> (ObjectIdentifier, Data, AVAssetSegmentType, SegmentedFMP4SystemReportEvidence)? in
                    if let firstMedia { return firstMedia }
                    firstMedia = (writerObjectIdentity, bytes, type, report)
                    return nil
                }
                if let previous {
                    downstream?.receiveSystemSegment(writerObjectIdentity: previous.0, bytes: previous.1,
                        type: previous.2, report: previous.3)
                    return
                }
            }
            var forwarded = bytes
            if mutation == .initializationBytes && type == .initialization || mutation == .mediaBytes && type == .separable {
                forwarded[forwarded.count - 1] ^= 1
            }
            let alteredReport: SegmentedFMP4SystemReportEvidence = mutation == .report && type == .separable
                ? .from(systemReport: report.systemReport, mediaType: .video) : report
            downstream?.receiveSystemSegment(writerObjectIdentity: mutation == .writer && type == .separable
                ? ObjectIdentifier(wrongWriter) : writerObjectIdentity, bytes: forwarded,
                type: mutation == .kind && type == .separable ? .initialization : type, report: alteredReport)
        }
    }
    let mutation: Mutation
    private var proxies: [Proxy] = []
    init(mutation: Mutation) { self.mutation = mutation }
    func makeWriter(configuration: SegmentedFMP4SystemConfiguration, sourceFormatHint: CMFormatDescription,
                    callbackSink: any SegmentedFMP4SystemCallbackSink) throws -> any SegmentedFMP4SystemWriting {
        let proxy = Proxy(callbackSink, mutation: mutation)
        proxies.append(proxy)
        return try AVAssetSegmentedFMP4SystemWriterFactory().makeWriter(configuration: configuration,
            sourceFormatHint: sourceFormatHint, callbackSink: proxy)
    }
}

enum Task19WriterProbe {
    enum CadenceMutation: CaseIterable { case duration, duplicatePTS, skippedPTS, oneTickPTS }
    struct Result {
        let relay: SegmentReportRelay
        let initialization: [SealedMediaObject]
        let media: [SealedMediaObject]
        let failure: (any Error)?
        func release() { for object in initialization + media { _ = relay.releaseForControl(object) } }
    }
    static func run(factory: any SegmentedFMP4SystemWriterFactory = AVAssetSegmentedFMP4SystemWriterFactory(),
                    mutation: (Int, CadenceMutation)? = nil, frameDuration: CMTime = CMTime(value: 1, timescale: 24),
                    start: CMTime = .zero, count: Int = 24) async throws -> Result {
        let binding = Task19.binding()
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: start, videoMode: .passthrough))
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(Task19.sample(mediaType: .video,
            start: start, duration: frameDuration)))
        let sink = Task19SystemSink(binding: binding)
        let relay = SegmentReportRelay(binding: binding, limits: .video, capacity: 8, objectSink: sink.collect)
        sink.relay = relay
        let writer = try SegmentedFMP4Writer(binding: binding, trackKind: .video, sourceFormatHint: format,
            boundarySession: boundary.session, compressedFormatConfiguration: nil, relay: relay, systemFactory: factory)
        let failure = Task19ErrorBox()
        do {
            try writer.start(at: start)
            for index in 0..<count {
                var pts = CMTimeAdd(start, CMTimeMultiply(frameDuration, multiplier: Int32(index)))
                var duration = frameDuration
                if let mutation, mutation.0 == index {
                    switch mutation.1 {
                    case .duration: duration = CMTime(value: 1, timescale: 60)
                    case .duplicatePTS: pts = CMTimeSubtract(pts, frameDuration)
                    case .skippedPTS: pts = CMTimeAdd(pts, frameDuration)
                    case .oneTickPTS: pts = CMTimeAdd(pts, CMTime(value: 1, timescale: 720_000))
                    }
                }
                let output = Task19.videoOutput(try Task19.sample(mediaType: .video, start: pts, duration: duration), sequence: UInt64(index))
                try await writer.appendVideoAwaitingReadiness(output, ticket: boundary.issueVideoAppend(for: output, writerBinding: binding))
            }
            let completed = XCTestExpectation(description: "真实 cadence 与 callback 终态")
            Task.detached {
                do { _ = try await writer.finish() } catch { failure.set(error) }
                completed.fulfill()
            }
            let completion = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
            XCTAssertEqual(completion, .completed)
        } catch { failure.set(error); writer.cancel() }
        var initialization: [SealedMediaObject] = [], media: [SealedMediaObject] = []
        while let object = sink.take(.initialization) { initialization.append(object) }
        while let object = sink.take(.media) { media.append(object) }
        return Result(relay: relay, initialization: initialization, media: media, failure: failure.value)
    }
}

final class Task19Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

struct Task19Packet {
    let object: SealedMediaObject
    let receipt: SegmentValidationReceipt
    let relay: SegmentReportRelay
}

/// 真实 Task 17 系统适配器和 delegate 产生 report；helper 不构造任何正式凭据。
final class Task19Track: @unchecked Sendable {
    let binding: FMP4WriterBinding
    let mediaType: FinalFMP4MediaType
    let duration: ExactMediaTime
    var relay: SegmentReportRelay
    var sink: Task19SystemSink
    let initialization: SealedMediaObject
    let proof: EpochFormatProof
    let timeline: SegmentTimelineValidator
    var nextSequence: UInt64
    var nextStart: ExactMediaTime
    var lastMediaByteCount = 0
    var boundaryOffsets: [Int64]?
    let boundary: SegmentBoundaryCoordinator?
    let audioChannels: Int
    let format: CMFormatDescription
    let epochSequence: UInt64
    let epochStart: ExactMediaTime
    let plannedDurations: [ExactMediaTime]?
    let formatVariant: Task19.FormatVariant
    private var firstMedia: SealedMediaObject?
    private var formalWriter: SegmentedFMP4Writer?
    private let terminalLogicalSequence: UInt64?
    private var endpointMedia: [SealedMediaObject] = []
    private(set) var endpointAuthority: AACEffectiveEndpointAuthority?

    /// 正式 audio track 把同一个 writer 私有终态槽交给 publisher；初始化对象、
    /// timeline mapping 与后续 endpoint 因而保持在同一 binding/media epoch。
    var aacTerminalBinding: AACWriterTerminalBinding? {
        mediaType == .audio ? formalWriter?.aacTerminalBinding : nil
    }
    var aacRenditionBinding: AACRenditionTerminalBinding? {
        // Finite batch fixtures seal the existing writer terminal authority from
        // all original batch inputs, rather than claim incremental encoder EOS.
        mediaType == .audio && terminalLogicalSequence == nil
            ? formalWriter?.aacRenditionTerminalBinding : nil
    }

    init(id: UInt64, mediaType: FinalFMP4MediaType, duration: ExactMediaTime = Task19.time(1),
         epoch: UInt64 = 1, sequence: UInt64 = 0, start: ExactMediaTime = Task19.time(0),
         item: UInt64 = 19, boundary: SegmentBoundaryCoordinator? = nil, channels: Int = 2,
         offsets: [Int64]? = nil, plannedDurations: [ExactMediaTime]? = nil,
         bindingOverride: FMP4WriterBinding? = nil, terminalSegment: Bool = false,
         terminalLogicalSequence: UInt64? = nil,
         formatVariant: Task19.FormatVariant = .baseline) async throws {
        binding = try bindingOverride ?? Task19.binding(id: id, epoch: epoch,
            writer: PlaybackIdentityAllocator.shared.next(in: .nonce), item: item)
        self.mediaType = mediaType
        self.duration = duration
        self.boundary = boundary
        audioChannels = channels
        boundaryOffsets = offsets
        epochSequence = sequence
        epochStart = start
        self.plannedDurations = plannedDurations
        self.formatVariant = formatVariant
        self.terminalLogicalSequence = terminalSegment ? sequence : terminalLogicalSequence
        format = try XCTUnwrap(CMSampleBufferGetFormatDescription(Task19.sample(mediaType: mediaType,
            start: start.cmTime, duration: duration.cmTime, channels: channels, formatVariant: formatVariant)))
        nextSequence = sequence
        nextStart = start
        sink = Task19SystemSink(binding: binding,
            retainAACEndpointInputs: self.terminalLogicalSequence != nil && mediaType == .audio)
        relay = SegmentReportRelay(binding: binding, limits: mediaType == .video ? .video : .audio,
            capacity: 8, objectSink: sink.collect)
        sink.relay = relay
        if let boundary, mediaType == .audio {
            try boundary.registerAudioRendition(binding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000), firstEffectiveStart: start.cmTime)
        }
        let firstDuration = plannedDurations?.first ?? duration
        if let boundary {
            formalWriter = try await sink.produceFormal(mediaType: mediaType, sequence: sequence, start: start, duration: firstDuration,
                boundary: boundary, format: format, continuing: nil,
                terminalSegment: self.terminalLogicalSequence == sequence,
                formatVariant: formatVariant)
        } else { try await sink.produce(mediaType: mediaType, sequence: sequence, start: start, duration: duration) }
        initialization = try XCTUnwrap(sink.take(.initialization))
        firstMedia = try XCTUnwrap(sink.take(.media))
        proof = try FinalFMP4Validator(binding: binding, mediaType: mediaType).validateInitialization(initialization)
        timeline = SegmentTimelineValidator(proof: proof, firstLogicalSequence: sequence)
    }

    func next() async throws -> Task19Packet {
        let object: SealedMediaObject
        if let firstMedia { object = firstMedia; self.firstMedia = nil }
        else {
            if let boundary {
                let actualDuration: ExactMediaTime
                if let plannedDurations, Int(nextSequence - epochSequence) < plannedDurations.count {
                    actualDuration = plannedDurations[Int(nextSequence - epochSequence)]
                } else if mediaType == .audio {
                    let target = CMTimeConvertScale(CMTimeMultiply(duration.cmTime, multiplier: Int32(nextSequence - epochSequence + 1)),
                        timescale: 48_000, method: .default).value
                    let end = try epochStart.adding(Task19.time(((target + 1_023) / 1_024) * 1_024, 48_000))
                    actualDuration = try end.subtracting(nextStart)
                } else { actualDuration = duration }
                formalWriter = try await sink.produceFormal(mediaType: mediaType, sequence: nextSequence, start: nextStart,
                    duration: actualDuration, boundary: boundary, format: format, continuing: formalWriter,
                    terminalSegment: terminalLogicalSequence == nextSequence,
                    formatVariant: formatVariant)
            } else { try await sink.produce(mediaType: mediaType, sequence: nextSequence, start: nextStart, duration: duration) }
            if let extraInit = sink.take(.initialization) { XCTAssertTrue(relay.releaseForControl(extraInit)) }
            object = try XCTUnwrap(sink.take(.media))
        }
        let receipt = try timeline.validate(object, using: proof)
        if mediaType == .audio, terminalLogicalSequence != nil {
            endpointMedia.append(object)
            if terminalLogicalSequence == object.logicalSequence {
                let writer = try XCTUnwrap(formalWriter)
                endpointAuthority = try writer.makeAACEffectiveEndpointAuthority(
                    epoch: sink.endpointEpoch(), initializationObject: initialization,
                    mediaObjects: endpointMedia)
                XCTAssertEqual(endpointAuthority?.receipt.terminalLogicalSequence,
                               object.logicalSequence)
                sink.releaseEndpointInputs()
                endpointMedia.removeAll(keepingCapacity: false)
            }
        }
        nextSequence += 1
        nextStart = receipt.presentationRange.end
        lastMediaByteCount = object.bytes.count
        return Task19Packet(object: object, receipt: receipt, relay: relay)
    }
    func stopWriter() { _ = formalWriter?.cancel() }
    deinit { _ = formalWriter?.cancel() }
}

final class Task19SystemSink: SegmentedFMP4SystemCallbackSink, @unchecked Sendable {
    let binding: FMP4WriterBinding
    weak var relay: SegmentReportRelay?
    private let lock = NSCondition()
    private var objects: [SealedMediaObject] = []
    private var objectsRetired = false
    static let objectDeliveryTimeout: TimeInterval = 10
    var collectedObjectCounts: (initialization: Int, media: Int) {
        lock.withLock {
            (objects.filter { $0.kind == .initialization }.count,
             objects.filter { $0.kind == .media }.count)
        }
    }
    private var sequence: UInt64 = 0
    private var formalAACIdentity: AACEncoderIdentity?
    private let retainAACEndpointInputs: Bool
    private var endpointInputs: [AACEncodedEpoch] = []
    init(binding: FMP4WriterBinding, retainAACEndpointInputs: Bool = false) {
        self.binding = binding
        self.retainAACEndpointInputs = retainAACEndpointInputs
    }
    func endpointEpoch() throws -> AACEncodedEpoch {
        let inputs = lock.withLock { endpointInputs }
        let first = try XCTUnwrap(inputs.first)
        let last = try XCTUnwrap(inputs.last)
        guard inputs.allSatisfy({ $0.identity == first.identity }),
              inputs.dropFirst().allSatisfy({ $0.leadingFrames == 0 }),
              inputs.dropLast().allSatisfy({ $0.trailingFrames == 0 }) else {
            throw SegmentedFMP4WriterFailure.aacEndpointMismatch
        }
        let buffers = inputs.flatMap(\.buffers)
        let payloadBytes = buffers.reduce(0) {
            $0 + (CMSampleBufferGetDataBuffer($1).map(CMBlockBufferGetDataLength) ?? 0)
        }
        let workspace = AACCalibrationWorkspace()
        return AACEncodedEpoch(identity: first.identity, buffers: buffers,
            realSampleCount: inputs.reduce(0) { $0 + $1.realSampleCount },
            totalDecodedFrames: inputs.reduce(0) { $0 + $1.totalDecodedFrames },
            leadingFrames: first.leadingFrames, trailingFrames: last.trailingFrames,
            actualLeadingPrimeFrames: first.actualLeadingPrimeFrames,
            actualTrailingPrimeFrames: last.actualTrailingPrimeFrames,
            bandwidth: .init(configuredBitrate: first.bandwidth.configuredBitrate,
                payloadCeiling: first.bandwidth.payloadCeiling,
                fmp4BodyCeiling: first.bandwidth.fmp4BodyCeiling,
                peakPayloadBits: inputs.map { $0.bandwidth.peakPayloadBits }.max() ?? 0,
                accessUnitCount: inputs.reduce(0) { $0 + $1.bandwidth.accessUnitCount },
                requiresWriterBodyAccounting: true),
            packetLease: try workspace.acquire(.aacPackets, bytes: payloadBytes),
            formatLease: try workspace.acquire(.nonPayload, bytes: 1_024))
    }
    func releaseEndpointInputs() { lock.withLock { endpointInputs.removeAll() } }
    func collect(_ object: SealedMediaObject) {
        let release = lock.withLock { () -> Bool in
            guard !objectsRetired else { return true }
            objects.append(object)
            lock.broadcast()
            return false
        }
        if release { XCTAssertTrue(relay?.releaseForControl(object) == true) }
    }
    func retireCollectedObjects() {
        let retired = lock.withLock { () -> [SealedMediaObject] in
            objectsRetired = true
            defer { objects.removeAll(keepingCapacity: false) }
            return objects
        }
        for object in retired { XCTAssertTrue(relay?.releaseForControl(object) == true) }
    }
    func take(_ kind: SealedMediaObjectKind) -> SealedMediaObject? {
        lock.withLock {
            guard let index = objects.firstIndex(where: { $0.kind == kind }) else { return nil }
            return objects.remove(at: index)
        }
    }
    func waitAndTake(_ kind: SealedMediaObjectKind,
                     timeout: TimeInterval = Task19SystemSink.objectDeliveryTimeout) -> SealedMediaObject? {
        lock.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !objects.contains(where: { $0.kind == kind }) {
            if !lock.wait(until: deadline) { break }
        }
        let index = objects.firstIndex { $0.kind == kind }
        let object = index.map { objects.remove(at: $0) }
        lock.unlock()
        return object
    }
    func receiveSystemSegment(writerObjectIdentity: ObjectIdentifier, bytes: Data, type: AVAssetSegmentType,
                              report: SegmentedFMP4SystemReportEvidence) {
        do {
            let relay = try XCTUnwrap(relay)
            let kind: SealedMediaObjectKind = type == .initialization ? .initialization : .media
            let ticket = try relay.reserve(kind: kind, logicalSequence: sequence, projectedByteCount: bytes.count)
            let result = relay.receive(.init(binding: binding, writerIdentity: binding.writerIdentity,
                ticket: ticket, logicalSequence: sequence, kind: kind, bytes: bytes as NSData,
                report: SegmentReportReference(evidence: report)))
            guard case let .accepted(acceptance) = result else { return XCTFail("真实 callback 未接纳：\(result)") }
            XCTAssertTrue(relay.consumePublication(acceptance, schedule: { $0() }))
        } catch { XCTFail("真实 callback 失败：\(error)") }
    }
    func produce(mediaType: FinalFMP4MediaType, sequence: UInt64, start: ExactMediaTime, duration: ExactMediaTime) async throws {
        self.sequence = sequence
        let sample = try Task19.sample(mediaType: mediaType, start: start.cmTime, duration: duration.cmTime)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let writer = try AVAssetSegmentedFMP4SystemWriterFactory().makeWriter(configuration: .init(
            contentTypeIdentifier: UTType.mpeg4Movie.identifier,
            outputFileTypeProfile: AVFileTypeProfile.mpeg4AppleHLS.rawValue,
            preferredOutputSegmentInterval: .indefinite, mediaType: mediaType.avMediaType,
            outputSettingsAreNil: true, sourceFormatHintIdentity: ObjectIdentifier(format), inputCount: 1),
            sourceFormatHint: format, callbackSink: self)
        XCTAssertTrue(writer.startWriting(at: start.cmTime))
        try await writer.appendAwaitingReadiness(makeReadyWriterFixtureSample(copying: sample))
        writer.markInputAsFinished()
        let done = XCTestExpectation(description: "真实系统 writer terminal")
        writer.finishWriting { success in XCTAssertTrue(success); done.fulfill() }
        let completion = await XCTWaiter.fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(completion, .completed)
    }
    func produceFormal(mediaType: FinalFMP4MediaType, sequence: UInt64, start: ExactMediaTime,
                       duration: ExactMediaTime, boundary: SegmentBoundaryCoordinator, format: CMFormatDescription,
                       continuing previous: SegmentedFMP4Writer?, terminalSegment: Bool = false,
                       formatVariant: Task19.FormatVariant = .baseline) async throws -> SegmentedFMP4Writer {
        let relay = try XCTUnwrap(relay)
        // 本层长播放测试冻结为最多128个逻辑段；不在每段偷偷重建同身份实例。
        // Task17 的 rollover 算法另由小容量最小回归覆盖；生产标准256/384保持不变。
        let writer = try previous ?? SegmentedFMP4Writer(binding: binding, trackKind: mediaType == .video ? .video : .aac,
            sourceFormatHint: format, boundarySession: boundary.session, compressedFormatConfiguration: nil,
            ownershipLimits: .init(rolloverThreshold: 6_144, hardCapacity: 6_145),
            relay: relay, systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        if previous == nil { try writer.start(at: start.cmTime) }
        if mediaType == .video {
            let count = Int(CMTimeConvertScale(duration.cmTime, timescale: 24, method: .default).value)
            XCTAssertEqual(CMTimeCompare(CMTime(value: Int64(count), timescale: 24), duration.cmTime), 0)
            for index in (previous == nil ? 0 : 1)...(terminalSegment ? count - 1 : count) {
                let sample = try Task19.sample(mediaType: .video,
                    start: CMTimeAdd(start.cmTime, CMTime(value: Int64(index), timescale: 24)),
                    duration: CMTime(value: 1, timescale: 24), isSync: index == 0 || index == count,
                    formatVariant: formatVariant)
                let output = Task19.videoOutput(sample, sequence: sequence * 100 + UInt64(index))
                try await writer.appendVideoAwaitingReadiness(output, ticket: boundary.issueVideoAppend(for: output, writerBinding: binding))
            }
        } else {
            let frames = CMTimeConvertScale(duration.cmTime, timescale: 48_000, method: .default).value
            let count = Int((frames + 1_023) / 1_024)
            var buffers: [CMSampleBuffer] = []
            for index in (previous == nil ? 0 : 1)...(terminalSegment ? count - 1 : count) {
                let pts = CMTimeAdd(start.cmTime, CMTime(value: Int64(index * 1_024), timescale: 48_000))
                let sample = try Task19.sample(mediaType: .audio, start: pts, duration: CMTime(value: 1_024, timescale: 48_000),
                    channels: Int(CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee.mChannelsPerFrame),
                    formatVariant: formatVariant)
                buffers.append(sample)
            }
            // report 是真实完整 AU 的范围；测试不把尾 trim 当成 MP4 segment duration。
            let trailing = 0
            let request = try AACRenditionRequest(layout: RenditionAudioLayout(labels: [.l, .r]), capabilityVersion: "task19-formal")
            let plan = try AACCalibrationPlan.build([request])
            let candidateIdentity = AACEncoderIdentity(
                plan: plan,
                ordinal: 0,
                request: request,
                nonce: ConverterInstanceNonce())
            // Task19 会让同一个正式 live writer 连续产出多个 segment；这些 segment
            // 必须复用同一 encoder identity，新的 identity 只能进入新的 writer/media epoch。
            let encoderIdentity = lock.withLock {
                if let formalAACIdentity { return formalAACIdentity }
                formalAACIdentity = candidateIdentity
                return candidateIdentity
            }
            let workspace = AACCalibrationWorkspace()
            let submittedCount = buffers.count
            let epoch = AACEncodedEpoch(identity: encoderIdentity,
                buffers: buffers, realSampleCount: submittedCount * 1_024, totalDecodedFrames: submittedCount * 1_024,
                leadingFrames: 0, trailingFrames: trailing, actualLeadingPrimeFrames: 0, actualTrailingPrimeFrames: UInt32(trailing),
                bandwidth: .init(configuredBitrate: 160_000, payloadCeiling: 200_000, fmp4BodyCeiling: 264_000,
                    peakPayloadBits: UInt64(submittedCount * 6 * 8), accessUnitCount: UInt64(submittedCount), requiresWriterBodyAccounting: true),
                packetLease: try workspace.acquire(.aacPackets, bytes: submittedCount * 6), formatLease: try workspace.acquire(.nonPayload, bytes: 1_024))
            try await writer.appendAACEncodedEpochAwaitingReadiness(epoch, coordinator: boundary)
            if retainAACEndpointInputs { lock.withLock { endpointInputs.append(epoch) } }
        }
        if terminalSegment {
            // 有限夹具在已声明的最后一段真实 finish；不把终态实例伪装为后续 writer。
            let completed = XCTestExpectation(description: "真实短 EOF terminal")
            let error = Task19ErrorBox()
            Task.detached {
                do { _ = try await writer.finish() } catch let failure { error.set(failure) }
                completed.fulfill()
            }
            let completion = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
            XCTAssertEqual(completion, .completed)
            if let error = error.value { throw error }
        }
        // 下一正式 sync/AU 的 append 触发真实 flush；等待准确回调而非 finish 整个实例。
        XCTAssertTrue(waitForMedia(sequence: sequence), "正式 live writer 的准确段回调")
        return writer
    }

    private func waitForMedia(sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !objects.contains(where: { $0.kind == .media && $0.logicalSequence == sequence }) {
            if !lock.wait(until: deadline) { break }
        }
        return objects.contains { $0.kind == .media && $0.logicalSequence == sequence }
    }
}

final class Task19ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: (any Error)?
    var value: (any Error)? { lock.withLock { error } }
    func set(_ value: any Error) { lock.withLock { error = value } }
}

/// 用真实 AVAssetWriter delegate callback 生成一份尚未领取的 relay capability。
/// 本辅助不构造 proof、receipt 或 publication evidence。
final class Task19UnclaimedSystemSink: SegmentedFMP4SystemCallbackSink, @unchecked Sendable {
    private let binding: FMP4WriterBinding
    private let relay: SegmentReportRelay
    private let errorBox = Task19ErrorBox()

    init(binding: FMP4WriterBinding, relay: SegmentReportRelay) {
        self.binding = binding
        self.relay = relay
    }

    var error: (any Error)? { errorBox.value }

    func receiveSystemSegment(writerObjectIdentity: ObjectIdentifier, bytes: Data, type: AVAssetSegmentType,
                              report: SegmentedFMP4SystemReportEvidence) {
        do {
            let kind: SealedMediaObjectKind = type == .initialization ? .initialization : .media
            let ticket = try relay.reserve(kind: kind, logicalSequence: 0, projectedByteCount: bytes.count)
            let result = relay.receive(.init(binding: binding, writerIdentity: binding.writerIdentity,
                ticket: ticket, logicalSequence: 0, kind: kind, bytes: bytes as NSData,
                report: SegmentReportReference(evidence: report)))
            guard case let .accepted(acceptance) = result else {
                throw SegmentReportRelayFailure.callbackIdentityMismatch
            }
            // 只保留 init capability；media 立即走正式 capability 领取路径，避免占用序号0。
            if kind == .media, !relay.consumePublication(acceptance, schedule: { $0() }) {
                throw SegmentReportRelayFailure.callbackIdentityMismatch
            }
        } catch {
            errorBox.set(error)
        }
    }

    func produce(format: CMFormatDescription, sample: CMSampleBuffer) async throws {
        let writer = try AVAssetSegmentedFMP4SystemWriterFactory().makeWriter(configuration: .init(
            contentTypeIdentifier: UTType.mpeg4Movie.identifier,
            outputFileTypeProfile: AVFileTypeProfile.mpeg4AppleHLS.rawValue,
            preferredOutputSegmentInterval: .indefinite,
            mediaType: .video,
            outputSettingsAreNil: true,
            sourceFormatHintIdentity: ObjectIdentifier(format),
            inputCount: 1
        ), sourceFormatHint: format, callbackSink: self)
        XCTAssertTrue(writer.startWriting(at: .zero))
        try await writer.appendAwaitingReadiness(makeReadyWriterFixtureSample(copying: sample))
        writer.markInputAsFinished()
        let completed = XCTestExpectation(description: "真实 callback capability")
        writer.finishWriting { success in
            XCTAssertTrue(success)
            completed.fulfill()
        }
        let completion = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(completion, .completed)
        XCTAssertNil(error)
    }
}

enum Task19Review4Checks {
    enum SelectionChange: Equatable {
        case videoCodec
        case audioChannels
        case itemGeneration
        case rendition
        case lifecycle
    }

    static func failedSuccessorLeavesActiveRelayUntouched() async throws {
        let binding = Task19.binding(writer: try PlaybackIdentityAllocator.shared.next(in: .nonce))
        let boundary = try SegmentBoundaryCoordinator(mode: .audioVideo(epochStart: .zero, videoMode: .passthrough))
        let sample = try Task19.sample(mediaType: .video, start: .zero, duration: CMTime(value: 1, timescale: 24))
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let sink = Task19SystemSink(binding: binding)
        let relay = SegmentReportRelay(binding: binding, limits: .video, capacity: 8, objectSink: sink.collect)
        sink.relay = relay

        let seed = Task19UnclaimedSystemSink(binding: binding, relay: relay)
        try await seed.produce(format: format, sample: sample)
        let seededMedia = try XCTUnwrap(sink.waitAndTake(.media))
        XCTAssertTrue(relay.releaseForControl(seededMedia))

        let writer = try SegmentedFMP4Writer(binding: binding, trackKind: .video,
            sourceFormatHint: format, boundarySession: boundary.session,
            compressedFormatConfiguration: nil, relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory())
        let pending = try relay.reserve(kind: .media, logicalSequence: 999, projectedByteCount: 17)
        let before = relay.usage
        XCTAssertEqual(before.publicationCapabilityCount, 1)
        XCTAssertEqual(before.reservedSlots, 1)

        let successor = FMP4WriterBinding(outputLifecycleEpoch: binding.outputLifecycleEpoch,
            itemGeneration: binding.itemGeneration, mediaEpoch: .init(rawValue: binding.mediaEpoch.rawValue + 1),
            publicationParticipantID: binding.publicationParticipantID,
            renditionIdentity: binding.renditionIdentity,
            writerIdentity: .init(rawValue: try PlaybackIdentityAllocator.shared.next(in: .nonce)))
        XCTAssertThrowsError(try SegmentedFMP4Writer(binding: successor, trackKind: .video,
            sourceFormatHint: format, boundarySession: boundary.session,
            compressedFormatConfiguration: nil, relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory()))
        let relayWasUnchanged = relay.usage == before
        XCTAssertTrue(relayWasUnchanged,
            "失败构造只能清理自己的系统 writer，不得关闭旧 relay 或改动 reservation/capability 账本")
        XCTAssertTrue(relay.discard(pending))
        guard relayWasUnchanged else {
            _ = writer.cancel()
            return
        }

        try writer.start(at: .zero)
        for index in 0...24 {
            let frame = try Task19.sample(mediaType: .video,
                start: CMTime(value: Int64(index), timescale: 24),
                duration: CMTime(value: 1, timescale: 24),
                isSync: index == 0 || index == 24)
            let output = Task19.videoOutput(frame, sequence: UInt64(index))
            try await writer.appendVideoAwaitingReadiness(output,
                ticket: boundary.issueVideoAppend(for: output, writerBinding: binding))
        }
        let initialization = try XCTUnwrap(sink.waitAndTake(.initialization))
        let media = try XCTUnwrap(sink.waitAndTake(.media))
        XCTAssertTrue(try XCTUnwrap(initialization.publicationEvidence).matches(initialization))
        XCTAssertTrue(try XCTUnwrap(media.publicationEvidence).matches(media))
        XCTAssertTrue(relay.releaseForControl(initialization))
        XCTAssertTrue(relay.releaseForControl(media))

        let firstTerminal = writer.cancel()
        let repeatedTerminal = writer.cancel()
        XCTAssertEqual(firstTerminal, repeatedTerminal, "旧 writer 的 terminal 必须准确一次")
        XCTAssertEqual(firstTerminal.terminalReason, .cancelled)
        XCTAssertEqual(relay.usage.publicationCapabilityCount, 0,
            "只有正式取得 source 所有权的旧 writer terminal 才撤销种子 capability")
    }

    static func decoderConfigurationsMayChangeAcrossEpoch() async throws {
        let harness = try await Task19Harness()
        try await harness.initial()
        let old = harness.tracks
        let ticket = harness.publisher.ticket
        let prepared = try await harness.prepareEpoch(2,
            formatVariants: [1: .decoderConfiguration, 2: .decoderConfiguration])
        for id: UInt64 in [1, 2] {
            let previous = try XCTUnwrap(old[id]?.initialization.publicationEvidence?.format)
            let next = try XCTUnwrap(prepared.1[id]?.initialization.publicationEvidence?.format)
            assertOnlyConfigurationChanged(from: previous, to: next, participantID: id)
            XCTAssertNotEqual(old[id]?.binding.writerIdentity, prepared.1[id]?.binding.writerIdentity)
        }
        XCTAssertNoThrow(try harness.publisher.beginEpoch(prepared.0, ticket: ticket),
            "同 item、不同正式 writer 仅 decoder configuration 改变时必须进入新 epoch")
        harness.adoptPreparedTracks(prepared.1, candidates: prepared.2)
        try await harness.offerBoth(count: 1)
        XCTAssertEqual(try harness.publisher.publish(ticket: harness.publisher.ticket, now: Task19.second), .published)
        XCTAssertEqual(harness.publisher.visible?.publicationSequence, 2)
        XCTAssertTrue(harness.publisher.visible!.media.values.allSatisfy {
            $0.initializationResources.contains { $0.mediaEpoch == 2 }
        })
    }

    static func sameEpochConfigurationMismatchIsRejected() async throws {
        let harness = try await Task19Harness()
        try await harness.initial()
        let active = try XCTUnwrap(harness.tracks[1])
        let rogueBoundary = try SegmentBoundaryCoordinator(mode: .audioVideo(
            epochStart: active.nextStart.cmTime, videoMode: .passthrough),
            sequenceAllocator: .init(initialValue: active.nextSequence))
        let rogue = try await Task19Track(id: 1, mediaType: .video, epoch: active.binding.mediaEpoch.rawValue,
            sequence: active.nextSequence, start: active.nextStart,
            item: active.binding.itemGeneration.rawValue, boundary: rogueBoundary,
            bindingOverride: active.binding, formatVariant: .decoderConfiguration)
        let previous = try XCTUnwrap(active.initialization.publicationEvidence?.format)
        let changed = try XCTUnwrap(rogue.initialization.publicationEvidence?.format)
        assertOnlyConfigurationChanged(from: previous, to: changed, participantID: 1)
        let packet = try await rogue.next()
        let ticket = harness.publisher.ticket
        let storeBefore = harness.store.usage
        let relayBefore = rogue.relay.usage
        XCTAssertThrowsError(try harness.publisher.offer(packet.object, receipt: packet.receipt,
            relay: packet.relay, ticket: ticket, now: 0),
            "同 epoch 不得把另一完整 configuration 的 init/media/capsule 混入活跃 participant")
        XCTAssertEqual(harness.publisher.ticket, ticket)
        assertStoreUsage(harness.store.usage, equals: storeBefore)
        XCTAssertEqual(rogue.relay.usage, relayBefore)
        XCTAssertTrue(rogue.relay.releaseForControl(rogue.initialization))
        XCTAssertTrue(rogue.relay.releaseForControl(packet.object))
        rogue.stopWriter()

        let activePacket = try await active.next()
        XCTAssertEqual(try harness.publisher.offer(activePacket.object, receipt: activePacket.receipt,
            relay: activePacket.relay, ticket: ticket, now: 0), .accepted,
            "拒绝混入后，活跃 writer 的真实 callback 仍须可发布")
    }

    static func selectionChangeIsRejected(_ change: SelectionChange) async throws {
        let harness = try await Task19Harness()
        try await harness.initial()
        let ticket = harness.publisher.ticket
        let storeBefore = harness.store.usage
        let formats: [UInt64: Task19.FormatVariant] = change == .videoCodec ? [1: .videoCodec] : [:]
        let prepared = try await harness.prepareEpoch(2, formatVariants: formats, selectionChange: change)
        let relayBefore = Dictionary(uniqueKeysWithValues: prepared.0.map {
            ($0.proof.binding.publicationParticipantID.rawValue, $0.relay.usage)
        })
        XCTAssertThrowsError(try harness.publisher.beginEpoch(prepared.0, ticket: ticket),
            "跨 epoch 仍须冻结 item 选择属性：\(change)")
        XCTAssertEqual(harness.publisher.ticket, ticket)
        assertStoreUsage(harness.store.usage, equals: storeBefore)
        for input in prepared.0 {
            let id = input.proof.binding.publicationParticipantID.rawValue
            XCTAssertEqual(input.relay.usage, relayBefore[id], "失败不能部分消费 participant \(id) 的 init/capability")
            XCTAssertTrue(input.relay.releaseForControl(input.initialization))
        }
        for track in prepared.1.values {
            let packet = try await track.next()
            XCTAssertTrue(packet.relay.releaseForControl(packet.object))
            track.stopWriter()
        }
        try await harness.offerBoth(count: 1)
        XCTAssertEqual(try harness.publisher.publish(ticket: harness.publisher.ticket, now: Task19.second), .published,
            "换代拒绝后旧 epoch 必须保持可发布")
    }

    static func declarationChangeIsRejected() async throws {
        try await Task19Harness(audioOnly: true).checkReview4DeclarationChangeNoConsumption()
    }

    static func videoBitDepthChangeIsRejected(from: Task19.FormatVariant,
                                              to: Task19.FormatVariant) async throws {
        let harness = try await Task19Harness(initialFormatVariants: [1: from])
        try await harness.initial()
        let old = harness.tracks
        let ticket = harness.publisher.ticket
        let visibleSequence = harness.publisher.visible?.publicationSequence
        let storeBefore = harness.store.usage
        let prepared = try await harness.prepareEpoch(2, formatVariants: [1: to])
        let previous = try XCTUnwrap(old[1]?.initialization.publicationEvidence?.format)
        let next = try XCTUnwrap(prepared.1[1]?.initialization.publicationEvidence?.format)
        XCTAssertEqual(previous.codec, next.codec, "两个方向必须保持相同 HEVC Main10 CODECS")
        XCTAssertEqual(previous.width, next.width)
        XCTAssertEqual(previous.height, next.height)
        XCTAssertEqual(previous.videoRange, next.videoRange)
        XCTAssertNotEqual(previous.configurationDigest, next.configurationDigest,
            "真实 CMFormatDescription 的 hvcC 必须随位深改变")
        let relayBefore = Dictionary(uniqueKeysWithValues: prepared.0.map {
            ($0.proof.binding.publicationParticipantID.rawValue, $0.relay.usage)
        })

        XCTAssertThrowsError(try harness.publisher.beginEpoch(prepared.0, ticket: ticket),
            "同 HEVC Main10 profile 的位深变化必须重建 item：\(from)→\(to)")
        XCTAssertEqual(harness.publisher.ticket, ticket)
        XCTAssertEqual(harness.publisher.visible?.publicationSequence, visibleSequence)
        assertStoreUsage(harness.store.usage, equals: storeBefore)
        for input in prepared.0 {
            let id = input.proof.binding.publicationParticipantID.rawValue
            XCTAssertEqual(input.relay.usage, relayBefore[id],
                "位深换代拒绝不能部分消费 participant \(id) 的 init/publication ownership")
            XCTAssertTrue(input.relay.releaseForControl(input.initialization))
        }
        for track in prepared.1.values {
            let packet = try await track.next()
            XCTAssertTrue(packet.relay.releaseForControl(packet.object))
            track.stopWriter()
        }
        for id in old.keys {
            XCTAssertEqual(harness.tracks[id]?.binding, old[id]?.binding, "拒绝后旧 participant 必须保持活跃")
        }
        try await harness.offerBoth(count: 1)
        XCTAssertEqual(try harness.publisher.publish(ticket: harness.publisher.ticket, now: Task19.second), .published,
            "位深换代拒绝后旧 participant/publication 必须继续工作")
    }

    private static func assertOnlyConfigurationChanged(from previous: SegmentedFMP4FrozenFormat,
                                                       to next: SegmentedFMP4FrozenFormat,
                                                       participantID: UInt64) {
        XCTAssertEqual(next.codec, previous.codec, "participant \(participantID) codec/profile 必须稳定")
        XCTAssertEqual(next.channels, previous.channels, "participant \(participantID) channels 必须稳定")
        XCTAssertEqual(next.width, previous.width, "participant \(participantID) width 必须稳定")
        XCTAssertEqual(next.height, previous.height, "participant \(participantID) height 必须稳定")
        XCTAssertEqual(next.videoRange, previous.videoRange, "participant \(participantID) range 必须稳定")
        XCTAssertNotEqual(next.configurationDigest, previous.configurationDigest,
            "participant \(participantID) 必须真实改变 decoder configuration")
    }

    static func assertStoreUsage(_ actual: SealedMediaStoreUsage, equals expected: SealedMediaStoreUsage) {
        XCTAssertEqual(actual.resourceCount, expected.resourceCount)
        XCTAssertEqual(actual.segmentCount, expected.segmentCount)
        XCTAssertEqual(actual.reservedBytes, expected.reservedBytes)
        XCTAssertEqual(actual.residentBytes, expected.residentBytes)
        XCTAssertEqual(actual.reservedSegmentCount, expected.reservedSegmentCount)
        XCTAssertEqual(actual.shouldBackpressure, expected.shouldBackpressure)
        XCTAssertEqual(actual.reservedSnapshotBytes, expected.reservedSnapshotBytes)
        XCTAssertEqual(actual.reservedSnapshotCount, expected.reservedSnapshotCount)
        XCTAssertEqual(actual.responseBackingBytes, expected.responseBackingBytes)
        XCTAssertEqual(actual.distinctResponseBackings, expected.distinctResponseBackings)
        XCTAssertEqual(actual.responseTailCount, expected.responseTailCount)
        XCTAssertEqual(actual.shouldBackpressureResponses, expected.shouldBackpressureResponses)
        XCTAssertEqual(actual.snapshotCount, expected.snapshotCount)
        XCTAssertEqual(actual.snapshotBytes, expected.snapshotBytes)
        XCTAssertEqual(actual.tombstoneCount, expected.tombstoneCount)
    }
}

final class Task19Harness: @unchecked Sendable {
    let store: SealedMediaStore
    let boundary: SegmentBoundaryCoordinator
    var tracks: [UInt64: Task19Track] = [:]
    let publisher: HLSPublicationCoordinator
    private var waiting: [UInt64: [Task19Packet]] = [:]
    private var candidates: [UInt64: HLSAudioCandidateRegistration] = [:]
    private let audioOnly: Bool
    init(token: String = Task19.token, loopbackSession: LoopbackSessionToken? = nil,
         audioOnly: Bool = false, audioCount: Int = 1,
         audioDuration: ExactMediaTime = Task19.time(1),
         videoDuration: ExactMediaTime = Task19.time(1), audioStart: ExactMediaTime = Task19.time(0),
         audioBoundaryOffsets: [Int64]? = nil, declarationMutation: ((inout HLSItemDeclaration) -> Void)? = nil,
         publicEnvelope: UInt64? = nil,
         publicationDeadlineNanoseconds: Int64 = 3_000_000_000,
         initialWindowMinimumSeconds: Int = 6,
         terminalLogicalSequence: UInt64? = nil,
         publicationClock: HLSNaturalEndPublicationClock? = nil,
         plannedSegmentDurations: [ExactMediaTime]? = nil,
         initialFormatVariants: [UInt64: Task19.FormatVariant] = [:]) async throws {
        let sessionToken = loopbackSession?.value ?? token
        store = loopbackSession.map { SealedMediaStore(loopbackSession: $0, itemGeneration: 19) }
            ?? SealedMediaStore(token: sessionToken, itemGeneration: 19)
        self.audioOnly = audioOnly
        // The default passthrough contract permits at most two seconds. A
        // planned 3/4-second synthetic GOP must declare its real legal bound;
        // the variable-duration regression still asserts every original gate.
        let maximumPlannedVideoDuration = plannedSegmentDurations?.max {
            CMTimeCompare($0.cmTime, $1.cmTime) < 0
        }?.cmTime
        boundary = try SegmentBoundaryCoordinator(mode: audioOnly ? .audioOnly(epochStart: .zero)
            : .audioVideo(epochStart: .zero, videoMode: .passthrough,
                maximumPassthroughInterval: maximumPlannedVideoDuration))
        let specialAudio: [ExactMediaTime]? = audioBoundaryOffsets == nil ? nil
            : [Task19.time(49_152, 48_000)] + Array(repeating: Task19.time(48_128, 48_000), count: 5) + [Task19.time(47_104, 48_000)]
        let specialVideo: [ExactMediaTime]? = audioBoundaryOffsets == nil ? nil
            : [Task19.time(48_256, 48_000)] + Array(repeating: Task19.time(48_128, 48_000), count: 5) + [Task19.time(1)]
        var plannedAudioDurations: [ExactMediaTime]?
        if let plannedSegmentDurations {
            var mediaEnd = Task19.time(0)
            var physicalEnd: Int64 = 0
            plannedAudioDurations = try plannedSegmentDurations.map { duration in
                mediaEnd = try mediaEnd.adding(duration)
                let target = CMTimeConvertScale(mediaEnd.cmTime, timescale: 48_000, method: .default).value
                let nextEnd = ((target + 1_023) / 1_024) * 1_024
                defer { physicalEnd = nextEnd }
                return Task19.time(nextEnd - physicalEnd, 48_000)
            }
        }
        if !audioOnly { tracks[1] = try await Task19Track(id: 1, mediaType: .video, duration: videoDuration,
            boundary: boundary, plannedDurations: plannedSegmentDurations ?? specialVideo,
            terminalLogicalSequence: terminalLogicalSequence,
            formatVariant: initialFormatVariants[1] ?? .baseline) }
        for index in 0..<audioCount { tracks[UInt64(index + 2)] = try await Task19Track(id: UInt64(index + 2), mediaType: .audio,
            duration: audioDuration, start: audioStart, item: audioOnly ? UInt64(20 + index) : 19,
            boundary: boundary, channels: [2, 6, 8][index], offsets: audioBoundaryOffsets,
            plannedDurations: plannedAudioDurations ?? specialAudio, terminalLogicalSequence: terminalLogicalSequence) }
        var declaration = try Task19.declaration(audioOnly: audioOnly, audioCount: audioCount)
        declaration.token = sessionToken
        if let track = tracks[1] {
            declaration.video!.width = Int(CMVideoFormatDescriptionGetDimensions(track.format).width)
            declaration.video!.height = Int(CMVideoFormatDescriptionGetDimensions(track.format).height)
            declaration.video!.codec = try XCTUnwrap(track.initialization.publicationEvidence).format.codec
            declaration.video!.frameRateMilli = 24_000
        }
        for index in declaration.audio.indices {
            declaration.audio[index].codec = .aac
            declaration.audio[index].channels = [2, 6, 8][index]
            declaration.audio[index].renditionID = "aac-\([2, 6, 8][index])"
        }
        declarationMutation?(&declaration)
        var inputs: [HLSInitialParticipant] = []
        for track in tracks.values.sorted(by: { $0.binding.publicationParticipantID.rawValue < $1.binding.publicationParticipantID.rawValue }) {
            let id = track.binding.publicationParticipantID.rawValue
            if audioOnly {
                var candidateDeclaration = declaration
                candidateDeclaration.itemGeneration = track.binding.itemGeneration.rawValue
                candidateDeclaration.audio = declaration.audio.filter { $0.participantID == id }
                candidates[id] = try store.registerAudioCandidate(initialization: track.initialization, proof: track.proof, declaration: candidateDeclaration)
            }
            inputs.append(.init(initialization: track.initialization, proof: track.proof, relay: track.relay,
                candidateTicket: candidates[id]?.ticket, candidate: candidates[id],
                aacTerminalBinding: track.aacTerminalBinding,
                aacRenditionBinding: track.aacRenditionBinding))
        }
        if let publicEnvelope { for index in declaration.audio.indices { declaration.audio[index].peakEnvelope = publicEnvelope } }
        publisher = try HLSPublicationCoordinator(store: store,
            participants: inputs,
            declaration: declaration,
            anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 1_788_912_000_000),
            publicationDeadlineNanoseconds: publicationDeadlineNanoseconds,
            initialWindowMinimumSeconds: initialWindowMinimumSeconds,
            publicationClock: publicationClock)
    }
    static func detachedParticipants() async throws -> [HLSInitialParticipant] {
        var participants: [HLSInitialParticipant] = []
        for (id, type) in [(UInt64(1), FinalFMP4MediaType.video), (UInt64(2), .audio)] {
            let track = try await Task19Track(id: id, mediaType: type)
            participants.append(HLSInitialParticipant(initialization: track.initialization,
                proof: track.proof, relay: track.relay, candidateTicket: nil))
        }
        return participants
    }
    static func checkShortEOFAndUnregisteredWriterSplicing(duration: ExactMediaTime) async throws {
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let first = try await Task19Track(id: 2, mediaType: .audio, duration: duration, item: 20,
            boundary: boundary, terminalSegment: true)
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        var declaration = try Task19.declaration(audioOnly: true)
        declaration.itemGeneration = 20
        let candidate = try store.registerAudioCandidate(initialization: first.initialization,
            proof: first.proof, declaration: declaration)
        let publisher = try HLSPublicationCoordinator(store: store,
            participants: [.init(initialization: first.initialization, proof: first.proof, relay: first.relay,
                candidateTicket: candidate.ticket, candidate: candidate,
                aacTerminalBinding: first.aacTerminalBinding)], declaration: declaration,
            anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0))
        let packet = try await first.next()
        XCTAssertNotNil(first.endpointAuthority,
            "The short-window rejection must occur after genuine writer terminal authentication")
        XCTAssertEqual(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
            ticket: publisher.ticket, now: 0), .waiting)
        XCTAssertNil(publisher.visible)
        let retained = store.usage.resourceCount
        var nextStart = packet.receipt.presentationRange.end
        for sequence: UInt64 in 1...5 {
            let unregisteredBoundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: nextStart.cmTime),
                sequenceAllocator: .init(initialValue: sequence))
            let other = try await Task19Track(id: 2, mediaType: .audio, duration: duration,
                epoch: sequence % 2 + 1, sequence: sequence, start: nextStart, item: 20,
                boundary: unregisteredBoundary, terminalSegment: true)
            let next = try await other.next()
            let ownership = next.relay.usage
            XCTAssertThrowsError(try publisher.offer(next.object, receipt: next.receipt, relay: next.relay,
                ticket: publisher.ticket, now: 0)) { error in
                XCTAssertEqual(error as? HLSPublicationFailure, .identityMismatch)
            }
            XCTAssertEqual(next.relay.usage, ownership, "真实但未登记的不同 writer/epoch 拒绝后不消费能力")
            XCTAssertEqual(store.usage.resourceCount, retained)
            XCTAssertTrue(next.relay.releaseForControl(next.object))
            XCTAssertTrue(other.relay.releaseForControl(other.initialization))
            nextStart = next.receipt.presentationRange.end
        }
        XCTAssertEqual(try publisher.publish(ticket: publisher.ticket, now: 0, naturalEnd: true), .waiting)
        XCTAssertNil(publisher.visible, "一个真实短 EOF 不得拼成初始六段或 ENDLIST")
        publisher.close()
    }
    func takeWaiting(participant: UInt64) throws -> Task19Packet {
        guard waiting[participant]?.isEmpty == false else { throw HLSPublicationFailure.invalidSequence }
        return waiting[participant]!.removeFirst()
    }
    func offer(participant: UInt64, count: Int, now: Int64 = 0) async throws {
        for _ in 0..<count {
            if waiting[participant, default: []].isEmpty {
                for id in tracks.keys.sorted() { waiting[id, default: []].append(try await tracks[id]!.next()) }
            }
            let packet = waiting[participant]!.removeFirst()
            try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay, ticket: publisher.ticket, now: now)
        }
    }
    func offerBoth(count: Int, now: Int64 = 0) async throws {
        for _ in 0..<count { for id in tracks.keys.sorted() { try await offer(participant: id, count: 1, now: now) } }
    }
    func initial() async throws { try await offerBoth(count: 6) }
    func prepareEpoch(_ epoch: UInt64, formatVariants: [UInt64: Task19.FormatVariant] = [:],
                      selectionChange: Task19Review4Checks.SelectionChange? = nil) async throws
        -> ([HLSInitialParticipant], [UInt64: Task19Track], [UInt64: HLSAudioCandidateRegistration]) {
        let old = tracks
        var preparedTracks: [UInt64: Task19Track] = [:]
        var preparedCandidates = candidates
        let first = old.values.first!
        let epochStart = try old.values.map(\.nextStart).max { try HLSChecked.compare($0, $1) < 0 }!
        let boundary = try SegmentBoundaryCoordinator(mode: audioOnly ? .audioOnly(epochStart: epochStart.cmTime)
            : .audioVideo(epochStart: epochStart.cmTime, videoMode: .passthrough),
            sequenceAllocator: .init(initialValue: first.nextSequence))
        var inputs: [HLSInitialParticipant] = []
        for id in old.keys.sorted() {
            let previous = old[id]!
            var binding = Task19.binding(id: id, epoch: epoch,
                writer: try PlaybackIdentityAllocator.shared.next(in: .nonce),
                item: previous.binding.itemGeneration.rawValue)
            switch selectionChange {
            case .itemGeneration where id == 1:
                binding = Task19.binding(id: id, epoch: epoch, writer: binding.writerIdentity.rawValue,
                    item: previous.binding.itemGeneration.rawValue + 1)
            case .rendition where id == 1:
                binding = .init(outputLifecycleEpoch: binding.outputLifecycleEpoch,
                    itemGeneration: binding.itemGeneration, mediaEpoch: binding.mediaEpoch,
                    publicationParticipantID: binding.publicationParticipantID,
                    renditionIdentity: .init(rawValue: 999), writerIdentity: binding.writerIdentity)
            case .lifecycle:
                binding = .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 999),
                    itemGeneration: binding.itemGeneration, mediaEpoch: binding.mediaEpoch,
                    publicationParticipantID: binding.publicationParticipantID,
                    renditionIdentity: binding.renditionIdentity, writerIdentity: binding.writerIdentity)
            default: break
            }
            let channels = selectionChange == .audioChannels && id == 2 ? 6 : previous.audioChannels
            let track = try await Task19Track(id: id, mediaType: previous.mediaType, duration: previous.duration, epoch: epoch,
                sequence: previous.nextSequence, start: epochStart, item: previous.binding.itemGeneration.rawValue,
                boundary: boundary, channels: channels, bindingOverride: binding,
                formatVariant: formatVariants[id] ?? .baseline)
            preparedTracks[id] = track
            if let candidate = candidates[id] {
                preparedCandidates[id] = try store.registerAudioCandidate(initialization: track.initialization, proof: track.proof,
                    declaration: candidate.declaration, replacing: candidate)
            }
            inputs.append(.init(initialization: track.initialization, proof: track.proof, relay: track.relay,
                candidateTicket: preparedCandidates[id]?.ticket, candidate: preparedCandidates[id],
                aacTerminalBinding: track.aacTerminalBinding,
                aacRenditionBinding: track.aacRenditionBinding))
        }
        return (inputs, preparedTracks, preparedCandidates)
    }
    func beginEpoch(_ epoch: UInt64) async throws {
        let (inputs, preparedTracks, preparedCandidates) = try await prepareEpoch(epoch)
        try publisher.beginEpoch(inputs, ticket: publisher.ticket)
        tracks = preparedTracks; candidates = preparedCandidates
    }
    func adoptPreparedTracks(_ preparedTracks: [UInt64: Task19Track],
                             candidates preparedCandidates: [UInt64: HLSAudioCandidateRegistration]) {
        tracks = preparedTracks
        candidates = preparedCandidates
        waiting.removeAll(keepingCapacity: true)
    }
    func checkReview4DeclarationChangeNoConsumption() async throws {
        try await initial()
        let active = try XCTUnwrap(tracks[2])
        let activeCandidate = try XCTUnwrap(candidates[2])
        let ticket = publisher.ticket
        let before = store.usage
        let nextBoundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: active.nextStart.cmTime),
            sequenceAllocator: .init(initialValue: active.nextSequence))
        let successor = try await Task19Track(id: 2, mediaType: .audio,
            epoch: active.binding.mediaEpoch.rawValue + 1,
            sequence: active.nextSequence, start: active.nextStart,
            item: active.binding.itemGeneration.rawValue, boundary: nextBoundary,
            channels: active.audioChannels, formatVariant: .decoderConfiguration)
        var changed = activeCandidate.declaration
        changed.audio[0].language = "fr"
        let relayBefore = successor.relay.usage
        XCTAssertThrowsError(try store.registerAudioCandidate(initialization: successor.initialization,
            proof: successor.proof, declaration: changed, replacing: activeCandidate),
            "同 item 跨 epoch 不得改变冻结 declaration")
        XCTAssertEqual(publisher.ticket, ticket)
        Task19Review4Checks.assertStoreUsage(store.usage, equals: before)
        XCTAssertEqual(successor.relay.usage, relayBefore,
            "candidate 拒绝不能消费 init 或已产生的 publication lease")
        XCTAssertTrue(store.acceptsCandidate(activeCandidate, proof: active.proof),
            "失败不能替换活跃 candidate")
        let packet = try await successor.next()
        XCTAssertTrue(successor.relay.releaseForControl(successor.initialization))
        XCTAssertTrue(successor.relay.releaseForControl(packet.object))
        successor.stopWriter()
        try await offerBoth(count: 1)
        XCTAssertEqual(try publisher.publish(ticket: publisher.ticket, now: Task19.second), .published,
            "declaration 换代拒绝后旧 candidate/epoch 必须保持可发布")
    }
    func checkWriterSuccessorTable(capacity: Bool) async throws {
        try await initial()
        let originalTicket = publisher.ticket
        let original = tracks
        let before = store.usage
        // 批后缀已处置：必须保留 A 及 B 前缀的 init/media 一次性所有权。
        let (failed, failedTracks, _) = try await prepareEpoch(2)
        XCTAssertTrue(failed.last!.relay.releaseForControl(failed.last!.initialization))
        XCTAssertThrowsError(try publisher.beginEpoch(failed, ticket: originalTicket))
        XCTAssertEqual(publisher.ticket, originalTicket)
        XCTAssertEqual(store.usage.resourceCount, before.resourceCount)
        XCTAssertEqual(store.usage.reservedBytes, 0)
        for input in failed.dropLast() { XCTAssertTrue(input.relay.releaseForControl(input.initialization)) }
        for track in failedTracks.values {
            let packet = try await track.next()
            XCTAssertTrue(packet.relay.releaseForControl(packet.object))
            track.stopWriter()
        }
        let (inputs, successor, registrations) = try await prepareEpoch(2)
        for id in tracks.keys {
            XCTAssertNotEqual(tracks[id]!.binding.writerIdentity, successor[id]!.binding.writerIdentity)
        }
        let first = inputs[0]
        let stable = first.proof.binding
        let identityMutations: [FMP4WriterBinding] = [
            .init(outputLifecycleEpoch: stable.outputLifecycleEpoch, itemGeneration: stable.itemGeneration,
                mediaEpoch: .init(rawValue: 1), publicationParticipantID: stable.publicationParticipantID,
                renditionIdentity: stable.renditionIdentity, writerIdentity: stable.writerIdentity),
            .init(outputLifecycleEpoch: stable.outputLifecycleEpoch, itemGeneration: stable.itemGeneration,
                mediaEpoch: .init(rawValue: 3), publicationParticipantID: stable.publicationParticipantID,
                renditionIdentity: stable.renditionIdentity, writerIdentity: original[stable.publicationParticipantID.rawValue]!.binding.writerIdentity),
            .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 999), itemGeneration: stable.itemGeneration,
                mediaEpoch: stable.mediaEpoch, publicationParticipantID: stable.publicationParticipantID,
                renditionIdentity: stable.renditionIdentity, writerIdentity: stable.writerIdentity),
            .init(outputLifecycleEpoch: stable.outputLifecycleEpoch, itemGeneration: .init(rawValue: 999),
                mediaEpoch: stable.mediaEpoch, publicationParticipantID: stable.publicationParticipantID,
                renditionIdentity: stable.renditionIdentity, writerIdentity: stable.writerIdentity),
            .init(outputLifecycleEpoch: stable.outputLifecycleEpoch, itemGeneration: stable.itemGeneration,
                mediaEpoch: stable.mediaEpoch, publicationParticipantID: .init(rawValue: 999),
                renditionIdentity: stable.renditionIdentity, writerIdentity: stable.writerIdentity),
            .init(outputLifecycleEpoch: stable.outputLifecycleEpoch, itemGeneration: stable.itemGeneration,
                mediaEpoch: stable.mediaEpoch, publicationParticipantID: stable.publicationParticipantID,
                renditionIdentity: .init(rawValue: 999), writerIdentity: stable.writerIdentity)
        ]
        for binding in identityMutations {
            var invalid = inputs
            invalid[0] = .init(initialization: Task19.copy(first.initialization, binding: binding), proof: first.proof,
                relay: first.relay, candidateTicket: first.candidateTicket, candidate: first.candidate)
            XCTAssertThrowsError(try publisher.beginEpoch(invalid, ticket: originalTicket))
            XCTAssertEqual(publisher.ticket, originalTicket)
            XCTAssertEqual(store.usage.resourceCount, before.resourceCount)
        }
        if audioOnly {
            var invalid = inputs
            invalid[0] = .init(initialization: first.initialization, proof: first.proof, relay: first.relay,
                candidateTicket: inputs[1].candidateTicket, candidate: first.candidate)
            XCTAssertThrowsError(try publisher.beginEpoch(invalid, ticket: originalTicket))
        }
        do { try publisher.beginEpoch(inputs, ticket: originalTicket) }
        catch { XCTFail("正式 A→B 必须接管；audioOnly=\(audioOnly)，capacity=\(capacity)：\(error)"); return }
        tracks = successor; candidates = registrations
        XCTAssertEqual(publisher.ticket.participantVector.map(\.binding.writerIdentity),
            inputs.map(\.proof.binding.writerIdentity))
        if capacity {
            try await offerBoth(count: 1)
            XCTAssertEqual(try publisher.publish(ticket: publisher.ticket, now: Task19.second), .published)
            let ticket = publisher.ticket
            let (thirdInputs, thirdTracks, thirdCandidates) = try await prepareEpoch(3)
            let count = store.usage.resourceCount
            XCTAssertThrowsError(try publisher.beginEpoch(thirdInputs, ticket: ticket), "未 drain A 时不能接 C")
            XCTAssertEqual(publisher.ticket, ticket)
            XCTAssertEqual(store.usage.resourceCount, count)
            XCTAssertEqual(store.usage.reservedBytes, 0)
            var late: [Task19Packet] = []
            for id in original.keys.sorted() { late.append(try await original[id]!.next()) }
            for track in original.values { track.stopWriter() }
            XCTAssertThrowsError(try publisher.beginEpoch(thirdInputs, ticket: ticket), "真实 terminal 不能抹掉在途 publication")
            for packet in late {
                XCTAssertEqual(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                    ticket: originalTicket, now: Task19.second), .releasedOnly)
                XCTAssertThrowsError(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                    ticket: originalTicket, now: Task19.second))
            }
            XCTAssertNoThrow(try publisher.beginEpoch(thirdInputs, ticket: ticket), "最后 transfer 的真实 drain 回调必须腾槽")
            tracks = thirdTracks; candidates = thirdCandidates
            var predecessor = successor
            for epoch: UInt64 in 4...20 {
                for track in predecessor.values { track.stopWriter() }
                try await offerBoth(count: 1)
                XCTAssertEqual(try publisher.publish(ticket: publisher.ticket, now: Int64(epoch - 2) * Task19.second), .published)
                predecessor = tracks
                await assertTask19NoThrow(try await beginEpoch(epoch), "固定槽位长序列不能累加历史：\(epoch)")
            }
            for track in predecessor.values { track.stopWriter() }
            publisher.close()
            for track in tracks.values {
                let packet = try await track.next()
                track.stopWriter()
                XCTAssertEqual(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                    ticket: publisher.ticket, now: 0), .releasedOnly)
            }
        } else {
            let ticket = publisher.ticket
            let retired = try publisher.reconfigure(retiring: [2], ticket: ticket).retiredParticipantIDs
            XCTAssertEqual(retired, audioOnly ? [2] : [1, 2, 3])
            // 未登记 C 有真实 writer/init/proof/capsule，仍不得冒领 A/B 的 release-only 登记。
            let rogueBoundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
            let rogue = try await Task19Track(id: 2, mediaType: .audio, epoch: 1,
                item: original[2]!.binding.itemGeneration.rawValue, boundary: rogueBoundary)
            let roguePacket = try await rogue.next()
            XCTAssertThrowsError(try publisher.offer(roguePacket.object, receipt: roguePacket.receipt,
                relay: roguePacket.relay, ticket: ticket, now: 0))
            XCTAssertTrue(roguePacket.relay.releaseForControl(roguePacket.object))
            XCTAssertTrue(rogue.relay.releaseForControl(rogue.initialization))
            for (generation, generationTicket) in [(original, originalTicket), (successor, ticket)] {
                for id in generation.keys.sorted() {
                    let packet = try await generation[id]!.next()
                    if retired.contains(id) {
                        var wrong = generationTicket
                        let index = wrong.participantVector.firstIndex { $0.participantID == id }!
                        let entry = wrong.participantVector[index]
                        wrong.participantVector[index] = .init(participantID: id,
                            candidateTicket: audioOnly ? ticket.participantVector.last!.candidateTicket :
                                AudioCandidateTicket(rawValue: 999), binding: entry.binding, proofIdentity: entry.proofIdentity,
                            declaration: entry.declaration, expectedPreviousSnapshotVersion: entry.expectedPreviousSnapshotVersion,
                            expectedLogicalSequence: entry.expectedLogicalSequence)
                        XCTAssertThrowsError(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                            ticket: wrong, now: 0), "错 candidate 不得消费旧代能力")
                        generation[id]!.stopWriter()
                        XCTAssertEqual(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                            ticket: generationTicket, now: 0), .releasedOnly)
                        XCTAssertEqual(packet.relay.usage.unpublishedLogicalSegmentCount, 0)
                        XCTAssertThrowsError(try publisher.offer(packet.object, receipt: packet.receipt, relay: packet.relay,
                            ticket: generationTicket, now: 0))
                    } else { XCTAssertTrue(packet.relay.releaseForControl(packet.object)) }
                }
            }
        }
    }
    func checkCandidatePreparationAndRejection() async throws {
        try await initial()
        let ticket = publisher.ticket
        let before = store.usage
        let (inputs, _, _) = try await prepareEpoch(2)
        let first = inputs[0]
        let originalURI = try store.resourceURI(publisher.visible!.media[2]!.resources[0], declaration: candidates[2]!.declaration)
        let video = try Task19.declaration().video!
        let mutations: [(String, (inout HLSItemDeclaration) -> Void)] = [
            ("rendition 路径", { $0.audio[0].renditionID = "changed-path" }),
            ("codec/group", { $0.audio[0].codec = .eac3 }),
            ("channels/group", { $0.audio[0].channels = 8 }),
            ("language", { $0.audio[0].language = "fr" }),
            ("score", { $0.audio[0].score += 1 }),
            ("audio envelope", { $0.audio[0].peakEnvelope += 1 }),
            ("token", { $0.token = "ffffffffffffffffffffffffffffffff" }),
            ("item generation", { $0.itemGeneration += 1 }),
            ("participant", { $0.audio[0].participantID += 1 }),
            ("空音轨", { $0.audio = [] }),
            ("重复音轨", { $0.audio.append($0.audio[0]) }),
            ("token 路径", { $0.token = "../invalid" }),
            ("rendition 路径穿越", { $0.audio[0].renditionID = "../invalid" }),
            ("track mode", { $0.video = video }),
            ("video participant", { $0.video = video; $0.video!.participantID += 1 }),
            ("video codec", { $0.video = video; $0.video!.codec = "avc1.64001f" }),
            ("video width", { $0.video = video; $0.video!.width += 1 }),
            ("video height", { $0.video = video; $0.video!.height += 1 }),
            ("video frame-rate", { $0.video = video; $0.video!.frameRateMilli += 1 }),
            ("video range", { $0.video = video; $0.video!.videoRange = "PQ" }),
            ("video envelope", { $0.video = video; $0.video!.peakEnvelope += 1 })
        ]
        for (name, mutate) in mutations {
            var changed = candidates[2]!.declaration
            mutate(&changed)
            XCTAssertThrowsError(try store.registerAudioCandidate(initialization: first.initialization,
                proof: first.proof, declaration: changed, replacing: candidates[2]), "同 item 冻结声明不得改变：\(name)")
            XCTAssertEqual(publisher.ticket, ticket)
            XCTAssertEqual(store.usage.resourceCount, before.resourceCount)
            XCTAssertEqual(store.usage.reservedBytes, 0)
            XCTAssertEqual(store.lookupURI(originalURI, now: 0), .available)
        }
        let foreign = try await Task19Harness(audioOnly: true, audioCount: 2)
        let old = tracks[2]!
        let combinations: [(String, () throws -> Void)] = [
            ("跨 store 前置 candidate", { _ = try self.store.registerAudioCandidate(initialization: first.initialization,
                proof: first.proof, declaration: self.candidates[2]!.declaration, replacing: foreign.candidates[2]) }),
            ("跨 participant 前置 candidate", { _ = try self.store.registerAudioCandidate(initialization: first.initialization,
                proof: first.proof, declaration: self.candidates[2]!.declaration, replacing: self.candidates[3]) }),
            ("跨 candidate declaration", { _ = try self.store.registerAudioCandidate(initialization: first.initialization,
                proof: first.proof, declaration: self.candidates[3]!.declaration, replacing: self.candidates[2]) }),
            ("新 init 旧 proof", { _ = try self.store.registerAudioCandidate(initialization: first.initialization,
                proof: old.proof, declaration: self.candidates[2]!.declaration, replacing: self.candidates[2]) }),
            ("旧 init 新 proof", { _ = try self.store.registerAudioCandidate(initialization: old.initialization,
                proof: first.proof, declaration: self.candidates[2]!.declaration, replacing: self.candidates[2]) }),
            ("同 epoch 重复准备", { _ = try self.store.registerAudioCandidate(initialization: old.initialization,
                proof: old.proof, declaration: self.candidates[2]!.declaration, replacing: self.candidates[2]) })
        ]
        let invalidInputs: [(String, HLSInitialParticipant)] = [
            ("新 proof 旧 candidate", .init(initialization: first.initialization, proof: first.proof, relay: first.relay,
                candidateTicket: first.candidateTicket, candidate: candidates[2])),
            ("跨 candidate ticket", .init(initialization: first.initialization, proof: first.proof, relay: first.relay,
                candidateTicket: candidates[3]!.ticket, candidate: first.candidate)),
            ("跨 store candidate", .init(initialization: first.initialization, proof: first.proof, relay: first.relay,
                candidateTicket: foreign.candidates[2]!.ticket, candidate: foreign.candidates[2])),
            ("缺 candidate", .init(initialization: first.initialization, proof: first.proof, relay: first.relay,
                candidateTicket: first.candidateTicket)),
            ("旧 proof 新 candidate", .init(initialization: old.initialization, proof: old.proof, relay: old.relay,
                candidateTicket: first.candidateTicket, candidate: first.candidate)),
            ("跨 init backing", .init(initialization: inputs[1].initialization, proof: first.proof, relay: first.relay,
                candidateTicket: first.candidateTicket, candidate: first.candidate))
        ]
        let allCombinations = combinations + invalidInputs.map { name, invalid in
            (name, { try self.publisher.beginEpoch([invalid, inputs[1]], ticket: ticket) })
        }
        for (name, operation) in allCombinations {
            XCTAssertThrowsError(try operation(), name)
            XCTAssertEqual(publisher.ticket, ticket)
            XCTAssertEqual(store.usage.resourceCount, before.resourceCount)
            XCTAssertEqual(store.usage.reservedBytes, 0)
            XCTAssertEqual(store.lookupURI(originalURI, now: 0), .available)
        }
        for id in candidates.keys.sorted() {
            XCTAssertTrue(store.acceptsCandidate(candidates[id]!, proof: tracks[id]!.proof), "prepare 不能替换 active candidate")
            XCTAssertNoThrow(try {
                let reservation = try store.reserveMedia(binding: tracks[id]!.binding, kind: .media, bodyBytes: 0)
                store.cancel(reservation)
            }())
        }
        var stale = ticket
        stale.participantVector[0].expectedPreviousSnapshotVersion += 1
        XCTAssertThrowsError(try publisher.beginEpoch(inputs, ticket: stale))
        XCTAssertThrowsError(try publisher.beginEpoch(Array(inputs.prefix(1)), ticket: ticket))
        XCTAssertEqual(publisher.ticket, ticket)
        XCTAssertEqual(store.usage.resourceCount, before.resourceCount)
        XCTAssertEqual(store.usage.reservedBytes, 0)
        for input in inputs { XCTAssertTrue(input.relay.releaseForControl(input.initialization), "失败不能消费新 init") }
        try await offerBoth(count: 1)
        XCTAssertEqual(try publisher.publish(ticket: publisher.ticket, now: Task19.second), .published)
        let retirement = try publisher.reconfigure(retiring: [2], ticket: publisher.ticket)
        XCTAssertEqual(retirement.survivorParticipantIDs, [3])
        XCTAssertThrowsError(try store.registerAudioCandidate(initialization: inputs[0].initialization,
            proof: inputs[0].proof, declaration: candidates[2]!.declaration, replacing: candidates[2]))
    }
    func checkCandidateRollbackAndAtomicCommit() async throws {
        try await initial()
        let ticket = publisher.ticket
        let before = store.usage
        let (failedInputs, _, _) = try await prepareEpoch(2)
        XCTAssertTrue(failedInputs[1].relay.releaseForControl(failedInputs[1].initialization))
        XCTAssertThrowsError(try publisher.beginEpoch(failedInputs, ticket: ticket))
        XCTAssertEqual(publisher.ticket, ticket)
        XCTAssertEqual(store.usage.resourceCount, before.resourceCount)
        XCTAssertEqual(store.usage.reservedBytes, 0)
        XCTAssertTrue(failedInputs[0].relay.releaseForControl(failedInputs[0].initialization), "批后缀失败不能接管前缀")
        try await offerBoth(count: 1)
        XCTAssertEqual(try publisher.publish(ticket: publisher.ticket, now: Task19.second), .published)
        let oldTracks = tracks
        let oldCandidates = candidates
        let oldTicket = publisher.ticket
        let (inputs, preparedTracks, preparedCandidates) = try await prepareEpoch(2)
        try publisher.beginEpoch(inputs, ticket: oldTicket)
        tracks = preparedTracks; candidates = preparedCandidates
        for id in candidates.keys.sorted() {
            XCTAssertTrue(store.acceptsCandidate(candidates[id]!, proof: tracks[id]!.proof))
            XCTAssertFalse(store.acceptsCandidate(oldCandidates[id]!, proof: oldTracks[id]!.proof))
            XCTAssertFalse(inputs.first { $0.proof.binding.publicationParticipantID.rawValue == id }!.relay
                .releaseForControl(inputs.first { $0.proof.binding.publicationParticipantID.rawValue == id }!.initialization))
            let late = try await oldTracks[id]!.next()
            XCTAssertEqual(try publisher.offer(late.object, receipt: late.receipt, relay: late.relay,
                ticket: oldTicket, now: Task19.second), .releasedOnly)
        }
        XCTAssertThrowsError(try publisher.beginEpoch(inputs, ticket: oldTicket))
        try await offerBoth(count: 1)
        XCTAssertEqual(try publisher.publish(ticket: publisher.ticket, now: 2 * Task19.second), .published)
    }
}

enum Task19FormalBoundaryChecks {
    static func check(kind: SegmentAudioAccessUnitKind, offsetTicks: Int32, accepted: Bool) throws {
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let rendition = AudioRenditionIdentity(rawValue: 2)
        try boundary.registerAudioRendition(rendition, accessUnit: kind, firstEffectiveStart: .zero)
        // 正式 ticket 的 AU 裁决在签发前完成；成功 ticket 不得靠测试 commit 自签。
        let sample = try Task19.sample(mediaType: .audio,
            start: CMTime(value: 48_000 + Int64(offsetTicks), timescale: 48_000), duration: CMTime(value: 1_024, timescale: 48_000))
        if kind.trackKind == .aac {
            if accepted {
                let ticket = try boundary.issueAACAppend(for: sample, rendition: rendition, writerBinding: Task19.binding(id: 2))
                XCTAssertEqual(ticket.logicalSequence, 1)
                XCTAssertFalse(ticket.commit(), "无真实 append 的观察不能伪造共同边界")
            } else if offsetTicks < 0 {
                let ticket = try boundary.issueAACAppend(for: sample, rendition: rendition, writerBinding: Task19.binding(id: 2))
                XCTAssertEqual(ticket.logicalSequence, 0, "前移不是下一个共同段的资格")
            } else {
                XCTAssertThrowsError(try boundary.issueAACAppend(for: sample, rendition: rendition, writerBinding: Task19.binding(id: 2)))
            }
        } else {
            // 压缩路径用已注册的正式 AU 边界算法观察上限；签发仍只允许 Task 16 submission。
            if accepted {
                XCTAssertEqual(try boundary.inspectAudioBoundary(rendition: rendition, at: CMSampleBufferGetPresentationTimeStamp(sample)).logicalSequence, 1)
            } else if offsetTicks >= 0 {
                XCTAssertThrowsError(try boundary.inspectAudioBoundary(rendition: rendition, at: CMSampleBufferGetPresentationTimeStamp(sample)))
            }
        }
    }
    static func checkAccumulatingDrift() throws {
        for tick in [1, 511, 1_023, 1_024, 1_536] {
            try check(kind: .aac(sampleRate: 48_000), offsetTicks: Int32(tick), accepted: tick < 1_024)
        }
    }
}

enum Task19CandidateChecks {
    static func rejectReusedGenerationWrongTicketAndCrossBundleReceipt() async throws {
        let h = try await Task19Harness(audioOnly: true, audioCount: 2)
        let entries = h.publisher.ticket.participantVector
        XCTAssertNotEqual(entries[0].binding.itemGeneration, entries[1].binding.itemGeneration)
        var bad = h.publisher.ticket
        bad.participantVector[0].expectedPreviousSnapshotVersion = 999
        XCTAssertThrowsError(try h.publisher.publish(ticket: bad, now: 0))
        let first = try await h.tracks[2]!.next(), other = try await h.tracks[3]!.next()
        XCTAssertThrowsError(try h.publisher.offer(first.object, receipt: other.receipt, relay: first.relay,
            ticket: h.publisher.ticket, now: 0))
        XCTAssertTrue(first.relay.releaseForControl(first.object))
        let detached = try await Task19Harness.detachedParticipants()
        let reused = detached.map { HLSInitialParticipant(initialization: $0.initialization, proof: $0.proof,
            relay: $0.relay, candidateTicket: entries[0].candidateTicket) }
        XCTAssertThrowsError(try HLSPublicationCoordinator(store: h.store, participants: reused,
            declaration: Task19.declaration(audioOnly: true, audioCount: 2),
            anchor: .init(mediaOrigin: Task19.time(0), utcMilliseconds: 0)))
    }
    static func rejectOldFormatProofAndCrossBundleReceipt() async throws {
        let h = try await Task19Harness()
        try await h.initial()
        let old = h.tracks[2]!
        try await h.beginEpoch(2)
        let current = h.tracks[2]!
        XCTAssertThrowsError(try h.publisher.beginEpoch([
            .init(initialization: current.initialization, proof: old.proof, relay: current.relay, candidateTicket: nil)],
            ticket: h.publisher.ticket))
        XCTAssertEqual(h.publisher.visible?.publicationSequence, 1)
    }
}

enum Task19 {
    enum FormatVariant: Equatable {
        case baseline
        case decoderConfiguration
        case videoCodec
        case hevcMain10EightBit
        case hevcMain10TenBit
    }

    static let second: Int64 = 1_000_000_000
    static let token = "0123456789abcdef0123456789abcdef"
    static func time(_ value: Int64, _ scale: Int32 = 1) -> ExactMediaTime { .init(value: value, timescale: scale) }
    static func binding(id: UInt64 = 1, epoch: UInt64 = 1, writer: UInt64? = nil, item: UInt64 = 19) -> FMP4WriterBinding {
        .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 19),
            itemGeneration: .init(rawValue: item), mediaEpoch: .init(rawValue: epoch),
            publicationParticipantID: .init(rawValue: id), renditionIdentity: .init(rawValue: id),
            writerIdentity: .init(rawValue: writer ?? id))
    }
    static func declaration(audioOnly: Bool = false, audioCount: Int = 1) throws -> HLSItemDeclaration {
        let choices: [HLSAudioDeclaration] = [
            .init(participantID: 2, renditionID: "aac-2", codec: .aac, channels: 2, language: nil, score: 100, peakEnvelope: 264_000),
            .init(participantID: 3, renditionID: "aac-8", codec: .aac, channels: 8, language: "en", score: 200, peakEnvelope: 704_000),
            .init(participantID: 4, renditionID: "ec3-8", codec: .eac3, channels: 8, language: "zh", score: 300, peakEnvelope: 6_208_000)]
        return HLSItemDeclaration(itemGeneration: 19, token: token,
            video: audioOnly ? nil : .init(participantID: 1, codec: "avc1.640028", width: 1920, height: 1080,
                frameRateMilli: 24_000, videoRange: "SDR", peakEnvelope: 81_600_000), audio: Array(choices.prefix(audioCount)))
    }
    static func copy(_ object: SealedMediaObject, sequence: UInt64? = nil, binding: FMP4WriterBinding? = nil) -> SealedMediaObject {
        SealedMediaObject(binding: binding ?? object.binding, writerIdentity: object.writerIdentity,
            callbackTicket: object.callbackTicket, logicalSequence: sequence ?? object.logicalSequence,
            kind: object.kind, sourceBytes: object.bytes as NSData, report: object.report, publicationLease: object.publicationLease)
    }
    static func inflate(_ gzip: Data) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        var output = Data(count: 600 * 1024)
        let count = output.count
        let status = gzip.withUnsafeBytes { source in output.withUnsafeMutableBytes { destination in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = UInt32(gzip.count)
            stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
            stream.avail_out = UInt32(count)
            return zlib.inflate(&stream, Z_FINISH)
        } }
        XCTAssertEqual(status, Z_STREAM_END)
        output.count = Int(stream.total_out)
        return output
    }
    static func sample(mediaType: FinalFMP4MediaType, start: CMTime, duration: CMTime, channels: Int = 2,
                       isSync: Bool = true, formatVariant: FormatVariant = .baseline) throws -> CMSampleBuffer {
        var format: CMFormatDescription?
        let isHEVC = formatVariant == .hevcMain10EightBit || formatVariant == .hevcMain10TenBit
        if mediaType == .video {
            if isHEVC {
                let parameters = hevcMain10ParameterSets(formatVariant)
                XCTAssertEqual(parameters[0].withUnsafeBytes { v in parameters[1].withUnsafeBytes { s in
                    parameters[2].withUnsafeBytes { p in
                        var pointers = [v.bindMemory(to: UInt8.self).baseAddress!,
                                        s.bindMemory(to: UInt8.self).baseAddress!,
                                        p.bindMemory(to: UInt8.self).baseAddress!]
                        var sizes = parameters.map(\.count)
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                            parameterSetCount: 3, parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                    }
                } }, noErr)
            } else {
                var sps = AssemblerTestFixtures.h264SPS
                var pps = AssemblerTestFixtures.h264PPS
                if formatVariant == .decoderConfiguration { pps[2] ^= 0x01 }
                if formatVariant == .videoCodec { sps[3] = 0x20 }
                XCTAssertEqual(sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                    var pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                    var sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 2, parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                } }, noErr)
            }
        } else {
            var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
            var cookie: [UInt8] = [0x11, UInt8(0x80 | ((channels == 8 ? 7 : channels) << 3))]
            if formatVariant == .decoderConfiguration { cookie.append(0) }
            XCTAssertEqual(cookie.withUnsafeBytes { CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: $0.baseAddress,
                extensions: nil, formatDescriptionOut: &format) }, noErr)
        }
        let payload: [UInt8] = mediaType == .video
            ? (isHEVC ? [0, 0, 0, 3, isSync ? 0x26 : 0x02, 0x01, 0x80]
                      : [0, 0, 0, 2, isSync ? 0x65 : 0x41, 0x80])
            : [0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c]
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block), noErr)
        let resolved = try XCTUnwrap(block)
        XCTAssertEqual(payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
            blockBuffer: resolved, offsetIntoDestination: 0, dataLength: payload.count) }, noErr)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: resolved,
            formatDescription: try XCTUnwrap(format), sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        if mediaType == .video, !isSync {
            let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
            let first = try XCTUnwrap((attachments as NSArray).firstObject as? NSMutableDictionary)
            first.setObject(true, forKey: kCMSampleAttachmentKey_NotSync as NSString)
        }
        return result
    }
    static func hevcMain10ParameterSets(_ variant: FormatVariant) -> [Data] {
        precondition(variant == .hevcMain10EightBit || variant == .hevcMain10TenBit)
        var vps = AssemblerTestFixtures.hevcVPS
        vps[6] = 0x02
        let sps: Data
        switch variant {
        case .hevcMain10EightBit:
            var value = AssemblerTestFixtures.hevcSPS
            value[3] = 0x02
            sps = value
        case .hevcMain10TenBit:
            sps = Data([0x42, 0x01, 0x01, 0x02, 0x60, 0x00, 0x00, 0x03,
                  0x00, 0xB0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
                  0x00, 0x5D, 0xA0, 0x02, 0x80, 0x80, 0x2D, 0x13,
                  0x65, 0x95, 0x9A, 0x49, 0x32, 0xBC, 0x05, 0xA8,
                  0x08, 0x08, 0x0A, 0x00])
        default:
            preconditionFailure("仅支持 HEVC Main10 位深夹具")
        }
        return [vps, sps, AssemblerTestFixtures.hevcPPS]
    }
    static func videoOutput(_ sample: CMSampleBuffer, sequence: UInt64) -> HLSVideoEncodedOutput {
        let identity = VideoEncodingFrameIdentity(generation: .init(rawValue: 19), accessUnitID: sequence, sequenceNumber: sequence)
        return HLSVideoEncodedOutput(sourceIdentity: identity, sampleBuffer: sample, presentationOrigin: .raw,
            inputFormatSignature: .init(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                width: 16, height: 16, bitDepth: 8, range: .video, primaries: .bt709, transfer: .bt709, matrix: .bt709,
                cleanAperture: nil, sampleAspectRatio: .init(num: 1, den: 1), chromaLocation: .init(topField: "Left", bottomField: "Left"),
                masteringDisplayColorVolume: nil, contentLightLevelInfo: nil),
            hardwareProof: .init(sessionID: .init(rawValue: 1_019), generation: identity.generation,
                firstOutputIdentity: identity, profile: .h264High))
    }
}

private func assertTask19NoThrow<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { _ = try await expression() }
    catch { XCTFail("Expected no error, received \(error). \(message())", file: file, line: line) }
}

private func assertTask19ThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error. \(message())", file: file, line: line)
    } catch {}
}

/// A native timer may retain its installed handler beyond cancel. This fake holds that exact
/// physical tail until the test releases it; it never signs a publication or alters a ticket.
private final class Task19HeldPublicationClock: PlaybackMonotonicClock, @unchecked Sendable {
    let timer = Task19HeldPublicationTimer()
    private let lock = NSLock()
    private var instant: UInt64 = 100
    var nowNanoseconds: UInt64 { lock.withLock { instant } }
    func set(_ instant: UInt64) { lock.withLock { self.instant = instant } }
    func makeDeadlineTimer(deliveryQueue: DispatchQueue) -> any PlaybackDeadlineTimer { timer }
}

private final class Task19HeldPublicationTimer: PlaybackDeadlineTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var storedCancelled = false
    private var storedDeadline: UInt64?
    var cancelled: Bool { lock.withLock { storedCancelled } }
    var deadline: UInt64? { lock.withLock { storedDeadline } }
    func setEventHandler(_ handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
    func schedule(notAfterInstant: UInt64?) { lock.withLock { storedDeadline = notAfterInstant } }
    func activate() {}
    func cancel() { lock.withLock { storedCancelled = true; storedDeadline = nil } }
    func captureHandler() -> (@Sendable () -> Void)? { lock.withLock { handler } }
    func releaseHandler() { lock.withLock { handler = nil } }
}

private final class Task19NaturalEndScope: HLSNaturalEndPublicationScope, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: ErrorDiagnosticSnapshot?
    private let failAfterOperation: ErrorDiagnosticSnapshot?
    init(failAfterOperation: ErrorDiagnosticSnapshot? = nil) { self.failAfterOperation = failAfterOperation }
    func fail(_ error: ErrorDiagnosticSnapshot) { lock.withLock { if failure == nil { failure = error } } }
    func withActivePublication<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            if let failure { throw failure }
            let result = try operation()
            if let failAfterOperation { failure = failAfterOperation; throw failAfterOperation }
            return result
        }
    }
}

private final class Task19WeakPublicationClock {
    weak var value: HLSNaturalEndPublicationClock?
    init(_ value: HLSNaturalEndPublicationClock) { self.value = value }
}
