// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class SourceAACNativeWindowTests: XCTestCase {
    func testRealFiveAndSixSecondSourceFragmentsPreserveBothNativeRates() async throws {
        for rate: Int32 in [44_100, 48_000] {
            let input = try await input(rate: rate)
            for seconds in [5, 6] {
                let count = (Int(rate) * seconds + 1_023) / 1_024
                let harness = try SourceAACNativeWindowHarness(input: input, longBoundary: true)
                for index in 0..<count { try await harness.branch.append(harness.frame(index)) }
                _ = try harness.timeline.consume(.endOfStream)
                let final = try await harness.branch.finish()
                XCTAssertEqual(final.inputCount, UInt64(count))
                XCTAssertEqual(harness.branch.physicalWriterCount, 1)
                let objects = harness.recorder.objects
                let initialization = try XCTUnwrap(objects.first { $0.kind == .initialization })
                let media = try XCTUnwrap(objects.first { $0.kind == .media })
                XCTAssertEqual(objects.filter { $0.kind == .media }.count, 1)
                let entry = try SourceAACInitializationEvidence.validate(initialization.bytes,
                    configuration: harness.configuration)
                let inspected = try FMP4CompressedAudioInspection.sourceAACFragment(
                    initialization: initialization.bytes, media: media.bytes,
                    configuration: harness.configuration,
                    expectedDuration: ExactMediaTime(value: Int64(count) * 1_024, timescale: rate))
                XCTAssertEqual(inspected.sampleCount, count)
                XCTAssertEqual(media.publicationEvidence?.sourceAAC?.sampleCount, count)
                XCTAssertTrue(media.publicationEvidence?.sourceAAC?.matches(media) == true)
                for index in 0..<count {
                    let sample = try XCTUnwrap(inspected.sample(at: index))
                    XCTAssertEqual(media.bytes.subdata(in: sample.byteSpan), input.payload)
                    XCTAssertEqual(sample.presentationRange.duration, .init(value: 1_024, timescale: rate))
                }
                let raw = try WriterNativeFragmentFacts.read(media.bytes)
                XCTAssertEqual(raw.sequence, 1)
                let ticks = try exactTicks(inspected.writtenRange.start.cmTime,
                    timeBase: MediaRational(num: 1, den: entry.timescale)!)
                XCTAssertEqual(raw.decodeTime, UInt64(try XCTUnwrap(ticks)))
                XCTAssertEqual(final.writtenStart, inspected.writtenRange.start)
                XCTAssertEqual(final.writtenEnd, inspected.writtenRange.end)
                await harness.branch.cancelAndAwait()
                harness.timeline.retireCompressedGeneration()
            }
        }
    }

    func testRealSourceContinuationKeepsRawSequenceTimeAndRetiredAliasCharge() async throws {
        let input = try await input(rate: 48_000)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let baseline = ledger.chargedBytes
        var harness: SourceAACNativeWindowHarness? = try .init(input: input, longBoundary: false,
            forcedWindows: true, retainFirstWindowAliases: true, ledger: ledger)
        let recorder = try XCTUnwrap(harness?.recorder)
        let oldWriter = TestWeakReference(harness?.branch.writer)
        let weakTimeline = TestWeakReference(harness?.timeline)
        let weakBranch = TestWeakReference(harness?.branch)
        for index in 0..<47 { try await harness!.branch.append(harness!.frame(index)) }
        XCTAssertEqual(harness?.branch.physicalWriterCount, 1)
        XCTAssertEqual(recorder.aliasCount, 47)
        let pending = try harness!.frame(47)
        let proof = try XCTUnwrap(pending.source.sourceProof)
        let originalProofIdentity = proof.identity
        try await harness!.branch.append(pending)
        XCTAssertEqual(harness?.branch.physicalWriterCount, 2)
        XCTAssertNil(oldWriter.value, "A real drained predecessor must not be kept alive by its native aliases")
        XCTAssertGreaterThanOrEqual(harness!.branch.writer.usage.liveInputCount, 47,
            "The successor shares predecessor input occupancy even after the previous writer is gone")
        XCTAssertLessThanOrEqual(harness!.branch.writer.usage.liveInputCount, 48)
        XCTAssertNil(harness?.branch.terminalBinding?.finalSeal, "Physical window finish is not source EOF")
        XCTAssertEqual(proof.identity, originalProofIdentity)
        let replay = try SourceAACAccessUnit(timed: pending, configuration: harness!.configuration,
            binding: harness!.branch.writer.binding)
        XCTAssertFalse(replay.claimForAppend(), "The original pending proof was consumed exactly once")
        for index in 48..<60 { try await harness!.branch.append(harness!.frame(index)) }
        _ = try harness!.timeline.consume(.endOfStream)
        let final = try await harness!.branch.finish()
        XCTAssertEqual(final.inputCount, 60)
        XCTAssertEqual(final.lastSourceID, 60)
        do {
            let objects = recorder.objects
            let media = objects.filter { $0.kind == .media }.sorted { $0.logicalSequence < $1.logicalSequence }
            let initializations = objects.filter { $0.kind == .initialization }
            XCTAssertEqual(media.count, 2); XCTAssertEqual(initializations.count, 2)
            let first = try WriterNativeFragmentFacts.read(media[0].bytes)
            let second = try WriterNativeFragmentFacts.read(media[1].bytes)
            XCTAssertEqual(first.sequence, 1); XCTAssertEqual(second.sequence, 2)
            let timescale = try SourceAACInitializationEvidence.validate(initializations[0].bytes,
                configuration: harness!.configuration).timescale
            let durationTicks = try exactTicks(CMTime(value: 47 * 1_024, timescale: 48_000),
                timeBase: MediaRational(num: 1, den: timescale)!)
            XCTAssertEqual(second.decodeTime, first.decodeTime + UInt64(try XCTUnwrap(durationTicks)),
                "Compare original mfhd/tfdt bytes; no timestamp or sequence rewriting is permitted")
            XCTAssertEqual(media[0].publicationEvidence?.sourceAAC?.timelineOffset,
                media[1].publicationEvidence?.sourceAAC?.timelineOffset)
            for initialization in initializations {
                _ = try SourceAACInitializationEvidence.validate(initialization.bytes,
                    configuration: harness!.configuration)
            }
        }
        await harness!.branch.cancelAndAwait()
        harness!.timeline.retireCompressedGeneration()
        recorder.releaseObjects()
        harness = nil
        XCTAssertNil(weakTimeline.value); XCTAssertNil(weakBranch.value)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        recorder.releaseFirstAliases(46)
        XCTAssertEqual(recorder.aliasCount, 1)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        recorder.releaseAllAliases()
        // `pending` and `proof` still own a charged source frame; the separate
        // scoped lifetime test below isolates the final native alias alone.
    }

    func testSourceSuccessorWaitsForActualPredecessorAliasBeforeClaimingPendingAU() async throws {
        let input = try await input(rate: 48_000)
        let harness = try SourceAACNativeWindowHarness(input: input, longBoundary: false,
            forcedWindows: true, retainFirstWindowAliases: true, writerCapacity: 47)
        defer { harness.recorder.releaseAllAliases(); harness.timeline.retireCompressedGeneration() }
        for index in 0..<47 { try await harness.branch.append(harness.frame(index)) }
        let predecessor = TestWeakReference(harness.branch.writer)
        let pending = try harness.frame(47)
        let identity = try XCTUnwrap(pending.source.sourceProof).identity
        let branch = harness.branch
        let append = Task { try await branch.append(pending) }
        let deadline = Date().addingTimeInterval(2)
        while !branch.isWaitingForCapacityForTesting && Date() < deadline { await Task.yield() }
        XCTAssertTrue(branch.isWaitingForCapacityForTesting)
        XCTAssertEqual(branch.physicalWriterCount, 2)
        XCTAssertNil(predecessor.value, "The awaiting successor must not pin its already-finished predecessor")
        XCTAssertEqual(harness.recorder.aliasCount, 47)
        XCTAssertEqual(branch.writer.usage.inputAllocationCount, 47,
            "A successor must not reset live occupancy or claim the waiting source AU")
        harness.recorder.releaseFirstAliases(1)
        try await append.value
        XCTAssertEqual(branch.writer.usage.inputAllocationCount, 48)
        XCTAssertEqual(try XCTUnwrap(pending.source.sourceProof).identity, identity)
        XCTAssertEqual(branch.physicalWriterCount, 2)
        _ = try harness.timeline.consume(.endOfStream)
        let final = try await branch.finish()
        XCTAssertEqual(final.inputCount, 48)
        await branch.cancelAndAwait()
    }

    func testNativeAliasesAloneRetainSourceBackingAfterAllOwnersLeave() async throws {
        let input = try await input(rate: 48_000)
        let ledger = HLSDeliveryApplicationChargeLedger()
        let baseline = ledger.chargedBytes
        let recorder: SourceAACNativeWindowRecorder
        do {
            let harness = try SourceAACNativeWindowHarness(input: input, longBoundary: false,
                retainFirstWindowAliases: true, ledger: ledger)
            recorder = harness.recorder
            for index in 0..<12 { try await harness.branch.append(harness.frame(index)) }
            await harness.branch.cancelAndAwait()
            harness.timeline.retireCompressedGeneration()
            recorder.releaseObjects()
        }
        XCTAssertEqual(recorder.aliasCount, 12)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        recorder.releaseFirstAliases(11)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        recorder.releaseAllAliases()
        let deadline = Date().addingTimeInterval(2)
        while ledger.chargedBytes != baseline && Date() < deadline { await Task.yield() }
        XCTAssertEqual(ledger.chargedBytes, baseline)
    }

    private func input(rate: Int32) async throws -> SourceAACNativeInput {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "review-lc-\(rate)-av.mp4",
            withExtension: nil, subdirectory: "Video"))
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        guard size > 0, size <= 8 * 1_024 * 1_024 else { throw HLSPublicationFailure.capacityExceeded }
        let fileCharge = try HLSCompressedAudioApplicationReservation.reserve(bytes: size + 4_096, ledger: .shared)
        let server = try NativeHLSHTTPFixture(resources: ["/source.mp4": .init(data: Data(contentsOf: url), contentType: "video/mp4")])
        let finished = expectation(description: "Bounded public LC fixture demux finished")
        let collector = SourceAACNativeInputCollector { finished.fulfill() }
        let admission = HLSDataPlaneAdmission(capacity: 8, maximumBytes: 8 * 1_024 * 1_024)
        let demuxer = FFmpegDemuxer()
        do {
            try demuxer.start(url: server.url("/source.mp4"), admission: admission, sink: collector.receive)
            await fulfillment(of: [finished], timeout: 15)
            demuxer.cancel()
            let result = try collector.input(admission: admission)
            XCTAssertEqual(result.track.sampleRate, rate)
            XCTAssertEqual(result.track.channelLayout.nativeMask, 3)
            await server.close()
            withExtendedLifetime(fileCharge) {}
            return result
        } catch { demuxer.cancel(); admission.cancel(); await server.close(); throw error }
    }
}

private final class SourceAACNativeInput: @unchecked Sendable {
    let track: AudioTrackDescriptor
    let payload: Data
    private let owners: [AdmittedDemuxEvent]
    private let admission: HLSDataPlaneAdmission
    init(track: AudioTrackDescriptor, payload: Data, owners: [AdmittedDemuxEvent], admission: HLSDataPlaneAdmission) {
        self.track = track; self.payload = payload; self.owners = owners; self.admission = admission
    }
}
private final class SourceAACNativeInputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let done: @Sendable () -> Void
    private var track: AudioTrackDescriptor?
    private var first: Data?
    private var owners: [AdmittedDemuxEvent] = []
    private var terminal = false
    init(done: @escaping @Sendable () -> Void) { self.done = done }
    func receive(_ owner: AdmittedDemuxEvent) {
        let finish = lock.withLock { () -> Bool in
            var finish = false
            owner.withBorrowedEvent { event in
                switch event {
                case let .tracks(tracks):
                    if track == nil { track = tracks.audio; owners.append(owner) }
                case let .packet(packet):
                    if first == nil, packet.streamIndex == track?.streamIndex { first = packet.data; owners.append(owner) }
                case .endOfStream, .failure, .cancelled:
                    finish = !terminal; terminal = true
                default: break
                }
            }
            return finish
        }
        if finish { done() }
    }
    func input(admission: HLSDataPlaneAdmission) throws -> SourceAACNativeInput {
        try lock.withLock {
            guard terminal, let track, track.codec == .aac, let first, !first.isEmpty,
                  first.count <= 65_536, owners.count == 2 else { throw SourceAACFailure.unsupportedSource }
            return .init(track: track, payload: first, owners: owners, admission: admission)
        }
    }
}

private final class SourceAACNativeWindowHarness {
    let timeline: HLSTimelineCoordinator
    let configuration: SourceAACWriterConfiguration
    let branch: SourceAACRenditionBranch
    let recorder: SourceAACNativeWindowRecorder
    private let input: SourceAACNativeInput
    private var nextIndex = 1
    init(input: SourceAACNativeInput, longBoundary: Bool, forcedWindows: Bool = false,
         retainFirstWindowAliases: Bool = false, writerCapacity: Int = 640,
         ledger: HLSDeliveryApplicationChargeLedger = .shared) throws {
        self.input = input
        let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 8 * 1_024 * 1_024,
            maximumPCMBytes: 1_024, capacity: 640, applicationLedger: ledger)
        timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        _ = try timeline.consume(.tracks(.init(selectedProgramID: nil, video: nil, audio: input.track)))
        let first = try Self.emit(input: input, index: 0, timeline: timeline)
        let binding = Task19.binding(id: 2, writer: 989_501)
        configuration = try SourceAACWriterConfiguration(first: first,
            source: .init(codec: .aac, profile: 1, sampleRate: input.track.sampleRate,
                channelCount: input.track.channelLayout.channelCount, channelMask: input.track.channelLayout.nativeMask ?? 0,
                decoderConfiguration: input.track.extradata, priming: .notSignaledPreserveTimestamps,
                service: .independentMain, formatValidated: true), binding: binding, applicationLedger: ledger)
        let boundary = try SegmentBoundaryCoordinator(mode: longBoundary
            ? .audioVideo(epochStart: first.timing.presentationTimeStamp.cmTime, videoMode: .passthrough,
                minimumPassthroughInterval: CMTime(value: 1, timescale: 1), maximumPassthroughInterval: CMTime(value: 6, timescale: 1))
            : .audioOnly(epochStart: first.timing.presentationTimeStamp.cmTime))
        let recorder = SourceAACNativeWindowRecorder(ledger: ledger, retainAliases: retainFirstWindowAliases)
        self.recorder = recorder
        let boundaryOwner = SourceAACNativeBoundaryOwner(boundary)
        branch = try SourceAACRenditionBranch(configuration: configuration, boundary: boundary) { configuration, continuation in
            try recorder.make(configuration: configuration, boundary: boundaryOwner.value,
                continuation: continuation, forcedWindows: forcedWindows, writerCapacity: writerCapacity)
        }
        firstFrame = first
    }
    private var firstFrame: HLSTimedAudioAccessUnit?
    func frame(_ index: Int) throws -> HLSTimedAudioAccessUnit {
        if index == 0, let firstFrame { self.firstFrame = nil; return firstFrame }
        guard index == nextIndex else { throw SourceAACFailure.sourceMismatch }
        nextIndex += 1
        return try Self.emit(input: input, index: index, timeline: timeline)
    }
    private static func emit(input: SourceAACNativeInput, index: Int, timeline: HLSTimelineCoordinator) throws -> HLSTimedAudioAccessUnit {
        let events = try timeline.consume(.packet(.init(streamIndex: input.track.streamIndex, codec: .audio(.aac), data: input.payload,
            presentationTimeStamp: CMTime(value: 900_000 + Int64(index) * 1_024, timescale: input.track.sampleRate),
            decodeTimeStamp: .invalid, duration: .invalid, isKey: true, isCorrupt: false)))
        return try XCTUnwrap(events.compactMap { if case let .audioSample(value) = $0 { return value }; return nil }.first)
    }
}

private final class SourceAACNativeWindowRecorder: @unchecked Sendable {
    private struct Captured {
        let object: SealedMediaObject
        let charge: HLSCompressedAudioApplicationReservation
    }
    private let lock = NSLock()
    private let ledger: HLSDeliveryApplicationChargeLedger
    private let retainAliases: Bool
    private var captured: [Captured] = []
    private var aliases: [CMBlockBuffer] = []
    private var count = 0
    private var callbackError: Error?
    init(ledger: HLSDeliveryApplicationChargeLedger, retainAliases: Bool) { self.ledger = ledger; self.retainAliases = retainAliases }
    var objects: [SealedMediaObject] { lock.withLock { captured.map(\.object) } }
    var aliasCount: Int { lock.withLock { aliases.count } }
    func releaseObjects() { lock.withLock { captured.removeAll() } }
    func releaseFirstAliases(_ count: Int) { lock.withLock { aliases.removeFirst(min(count, aliases.count)) } }
    func releaseAllAliases() { lock.withLock { aliases.removeAll() } }
    func make(configuration: SourceAACWriterConfiguration, boundary: SegmentBoundaryCoordinator,
              continuation: WriterWindowContinuation?, forcedWindows: Bool, writerCapacity: Int) throws -> SegmentedFMP4Writer {
        let ordinal = lock.withLock { let value = count; count += 1; return value }
        guard ordinal < 2, (ordinal == 0) == (continuation == nil) else { throw SourceAACFailure.writerBindingMismatch }
        let first = configuration.authority.initialBinding
        let binding = FMP4WriterBinding(outputLifecycleEpoch: first.outputLifecycleEpoch,
            itemGeneration: first.itemGeneration, mediaEpoch: first.mediaEpoch,
            publicationParticipantID: first.publicationParticipantID, renditionIdentity: first.renditionIdentity,
            writerIdentity: .init(rawValue: first.writerIdentity.rawValue + UInt64(ordinal)))
        let holder = SourceAACNativeRelayHolder()
        let relay = SegmentReportRelay(binding: binding, limits: .audio, capacity: 8) { [self, holder] object in
            do {
                let charge = try HLSCompressedAudioApplicationReservation.reserve(bytes: object.bytes.count + 4_096, ledger: ledger)
                try lock.withLock {
                    guard captured.count < 8 else { throw HLSPublicationFailure.capacityExceeded }
                    captured.append(.init(object: object, charge: charge))
                }
            } catch { lock.withLock { callbackError = error } }
            _ = holder.relay?.releaseForControl(object)
        }
        holder.relay = relay
        let writer = try SegmentedFMP4Writer(binding: binding, trackKind: .aac,
            sourceFormatHint: configuration.sourceFormatHint, boundarySession: boundary.session,
            compressedFormatConfiguration: nil, ownershipLimits: forcedWindows ? .init(rolloverThreshold: 1, hardCapacity: writerCapacity) : nil,
            relay: relay, systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(),
            writerWindowContinuation: continuation, applicationLedger: ledger, sourceAACConfiguration: configuration)
#if DEBUG
        if retainAliases && ordinal == 0 {
            try writer.observeNativeInputAliasesForTesting { [self] block in
                lock.withLock { precondition(aliases.count < 320); aliases.append(block) }
            }
        }
#endif
        return writer
    }
}
private final class SourceAACNativeRelayHolder: @unchecked Sendable { weak var relay: SegmentReportRelay? }

private final class SourceAACNativeBoundaryOwner: @unchecked Sendable {
    let value: SegmentBoundaryCoordinator
    init(_ value: SegmentBoundaryCoordinator) { self.value = value }
}
