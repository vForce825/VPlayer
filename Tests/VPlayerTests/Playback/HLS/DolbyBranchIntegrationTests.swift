// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

/// These tests submit real public fixture AUs through the real paid producer,
/// timeline mapping, branch, sample materializer and service retirement path.
/// The prompt adapter intentionally provides no native callback or continuation.
final class DolbyBranchIntegrationTests: XCTestCase {
    func testPublicAC3BranchRetiresTwentyFourConsumedFramesWithPromptRelease() async throws {
        try await assertPromptRelease(fixture: .ac3())
    }

    func testPublicSixMemberEAC3BranchRetiresEveryConsumedMemberWithPromptRelease() async throws {
        try await assertPromptRelease(fixture: .eac3())
    }

    private func assertPromptRelease(fixture: DolbyBranchFixture) async throws {
        let graph = try DolbyBranchTestGraph(fixture: fixture, accessUnits: 24, retainsAliases: false)
        defer { graph.timeline.retireCompressedGeneration() }
        XCTAssertGreaterThan(graph.frames.count, 16)
        XCTAssertEqual(graph.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0,
            "Retaining source frames before output admission must not consume service staging slots")
        let configuration = try XCTUnwrap(graph.frames.first?.source.dolbyProof?.configuration)
        let cookie = try XCTUnwrap(graph.frames.first?.source.dolbyProof?.systemFormat.magicCookie)
        XCTAssertEqual(cookie, configuration.serializedBox,
            "The actual producer format must satisfy the writer's full dac3/dec3 cookie contract")
        for (index, frame) in graph.frames.enumerated() {
            try await graph.branch.append(frame)
            if (index + 1).isMultiple(of: fixture.frames.count) {
                let completed = (index + 1) / fixture.frames.count
                XCTAssertEqual(graph.factory.samples.count, completed)
                XCTAssertEqual(graph.producer.coordinator.liveCompressedWriterSubmissionCount, 0)
                XCTAssertEqual(graph.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0,
                    "Each AC3 proof or all six EAC3 proofs must retire after the actual awaited append")
                XCTAssertEqual(graph.branch.writer?.usage.liveInputCount, 0)
                for consumed in graph.frames[0...index] {
                    XCTAssertNil(consumed.source.dolbyProof?.admittedProof)
                }
            }
        }
        XCTAssertEqual(graph.branch.physicalWriterCount, 1)
        XCTAssertEqual(graph.factory.samples.count, 24)
        for (index, sample) in graph.factory.samples.enumerated() {
            XCTAssertEqual(sample.bytes, fixture.accessUnit)
            XCTAssertEqual(sample.presentationTime, CMTime(value: 480_000 + Int64(index * 1_536), timescale: 48_000))
            XCTAssertEqual(sample.duration, CMTime(value: 1_536, timescale: 48_000))
            XCTAssertEqual(sample.channelPositions, UInt32(fixture.channelMask))
        }
        XCTAssertGreaterThan(graph.copies.compressedInput.usage.bytes, 0,
            "The deliberately retained source frame array still owns its separate paid source tails")
        for frame in graph.frames {
            XCTAssertThrowsError(try graph.producer.admitForOutput(XCTUnwrap(frame.source.dolbyProof)))
        }
        await graph.branch.cancelAndAwait()
        // This adapter has no real native publication callbacks, so deliberately
        // do not finish a physical window or claim native EOF/continuation here.
    }

#if DEBUG
    func testDelayedAC3NativeAliasesDoNotKeepProducerTimelineOrBranchOwnerAlive() async throws {
        try await assertDelayedRelease(fixture: .ac3())
    }

    func testDelayedSixMemberEAC3NativeAliasesRetireAllMembersAfterOwnersDisappear() async throws {
        try await assertDelayedRelease(fixture: .eac3())
    }

    private func assertDelayedRelease(fixture: DolbyBranchFixture) async throws {
        let ledger = HLSDeliveryApplicationChargeLedger()
        let baseline = ledger.chargedBytes
        var graph: DolbyBranchTestGraph? = try DolbyBranchTestGraph(fixture: fixture,
            accessUnits: 24, retainsAliases: true, applicationLedger: ledger)
        let weakGraph = TestWeakReference(graph)
        let weakProducer = TestWeakReference(graph?.producer)
        let weakTimeline = TestWeakReference(graph?.timeline)
        let weakBranch = TestWeakReference(graph?.branch)
        let aliases = try XCTUnwrap(graph?.factory.aliases)
        var coordinator: AudioServiceSemanticCoordinator? = graph?.producer.coordinator
        let weakCoordinator = TestWeakReference(coordinator)
        let expectedMembers = 24 * fixture.frames.count
        for frame in try XCTUnwrap(graph?.frames) { try await graph!.branch.append(frame) }
        XCTAssertEqual(aliases.count, 24)
        XCTAssertEqual(coordinator?.liveCompressedWriterSubmissionCount, 24)
        XCTAssertEqual(coordinator?.audioServiceRegistryUsage.admittedProofs, expectedMembers)
        // Records remain solely for native last-use after branch consumption;
        // source proof objects must no longer hold those service records.
        for frame in graph!.frames { XCTAssertNil(frame.source.dolbyProof?.admittedProof) }
        let writer = try XCTUnwrap(graph?.branch.writer)
        XCTAssertEqual(writer.usage.liveInputCount, 24)
        await graph!.branch.cancelAndAwait()
        graph!.timeline.retireCompressedGeneration()
        XCTAssertEqual(coordinator?.liveCompressedWriterSubmissionCount, 24,
            "Cancellation cannot counterfeit release of retained native block references")
        graph = nil
        XCTAssertNil(weakGraph.value)
        XCTAssertNil(weakProducer.value)
        XCTAssertNil(weakTimeline.value)
        XCTAssertNil(weakBranch.value)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        aliases.releaseFirst(23)
        XCTAssertEqual(coordinator?.liveCompressedWriterSubmissionCount, 1)
        XCTAssertEqual(coordinator?.audioServiceRegistryUsage.admittedProofs, fixture.frames.count)
        XCTAssertEqual(writer.usage.liveInputCount, 1)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        aliases.releaseAll()
        XCTAssertEqual(coordinator?.liveCompressedWriterSubmissionCount, 0)
        XCTAssertEqual(coordinator?.audioServiceRegistryUsage.admittedProofs, 0)
        XCTAssertEqual(writer.usage.liveInputCount, 0)
        coordinator = nil
        XCTAssertNil(weakCoordinator.value)
        // Writer bookkeeping is still deliberately held by `writer`; the
        // separate owner-release test below checks the entire ledger baseline.
    }

    func testFinalNativeAliasReturnsLedgerAfterEveryGraphScopedOwnerIsReleased() async throws {
        let fixture = try await DolbyBranchFixture.ac3()
        let ledger = HLSDeliveryApplicationChargeLedger()
        let baseline = ledger.chargedBytes
        var graph: DolbyBranchTestGraph? = try DolbyBranchTestGraph(fixture: fixture,
            accessUnits: 20, retainsAliases: true, applicationLedger: ledger)
        let aliases = try XCTUnwrap(graph?.factory.aliases)
        weak var weakWriter: SegmentedFMP4Writer?
        for frame in graph!.frames { try await graph!.branch.append(frame) }
        weakWriter = graph?.branch.writer
        await graph!.branch.cancelAndAwait()
        graph!.timeline.retireCompressedGeneration()
        graph = nil
        XCTAssertNil(weakWriter)
        XCTAssertEqual(aliases.count, 20)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        aliases.releaseFirst(19)
        XCTAssertGreaterThan(ledger.chargedBytes, baseline)
        aliases.releaseAll()
        // The prepaid capacity deadline handler may still be leaving Dispatch;
        // retain its charge until that real tail, rather than forcing zero early.
        let deadline = Date().addingTimeInterval(2)
        while ledger.chargedBytes != baseline && Date() < deadline { await Task.yield() }
        XCTAssertEqual(ledger.chargedBytes, baseline)
    }

    func testNativeEAC3BranchPublishesActualSixBlockConfigurationAndSideLayout() async throws {
        let fixture = try DolbyBranchFixture.eac3()
        let graph = try DolbyBranchTestGraph(fixture: fixture, accessUnits: 4,
            retainsAliases: false, usesNativeWriter: true)
        defer { graph.timeline.retireCompressedGeneration() }
        for frame in graph.frames { try await graph.branch.append(frame) }
        let terminal = try await graph.branch.finish()
        XCTAssertEqual(terminal.terminalReason, .finished)
        XCTAssertEqual(graph.branch.physicalWriterCount, 1)
        for _ in 0..<200 where graph.factory.initializations.count != 1 || graph.factory.mediaCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try graph.factory.checkCallbackFailures()
        XCTAssertEqual(graph.factory.initializations.count, 1)
        XCTAssertEqual(graph.factory.mediaCount, 1)
        let bytes = try XCTUnwrap(graph.factory.initializations.first)
        let configuration = try XCTUnwrap(graph.branch.configuration)
        let evidence = try DolbyWriterInitializationEvidence.validate(bytes,
            configuration: configuration, sourceLayout: fixture.source.channelLayout)
        XCTAssertEqual(evidence.channelPositions, 0x60F)
        XCTAssertFalse(configuration.declaresDolbyAtmos)
        await graph.branch.cancelAndAwait()
    }

    func testRealNativePredecessorRolloverKeepsOriginalPendingAUAndLiveAliasDomain() async throws {
        // A real AVAssetWriter predecessor is mandatory: no fake callback binding,
        // fabricated drain certificate, or directly constructed continuation.
        let fixture = try await DolbyBranchFixture.ac3()
        let graph = try DolbyBranchTestGraph(fixture: fixture, accessUnits: 34,
            retainsAliases: true, usesNativeWriter: true,
            ownershipLimits: .init(rolloverThreshold: 1, hardCapacity: 384))
        defer { graph.factory.aliases.releaseAll(); graph.timeline.retireCompressedGeneration() }
        for frame in graph.frames.prefix(32) { try await graph.branch.append(frame) }
        XCTAssertEqual(graph.branch.physicalWriterCount, 1)
        XCTAssertEqual(graph.factory.aliases.count, 32)
        let predecessor = TestWeakReference(graph.branch.writer)
        let finalPendingProof = try XCTUnwrap(graph.frames[32].source.dolbyProof)
        let proofIdentity = finalPendingProof.identity
        try await graph.branch.append(graph.frames[32])
        XCTAssertEqual(graph.branch.physicalWriterCount, 2)
        XCTAssertEqual(graph.factory.continuationCount, 1)
        XCTAssertNil(predecessor.value)
        XCTAssertEqual(finalPendingProof.identity, proofIdentity)
        XCTAssertNil(finalPendingProof.admittedProof)
        XCTAssertEqual(graph.producer.coordinator.claimedCompressedWriterSubmissionCount, 33,
            "The pre-claim capacity retry consumes its original complete AU exactly once")
        XCTAssertGreaterThanOrEqual(graph.branch.writer!.usage.liveInputCount, 32,
            "The successor retains the predecessor's actual input admission domain")
        try await graph.branch.append(graph.frames[33])
        let terminal = try await graph.branch.finish()
        XCTAssertEqual(terminal.terminalReason, .finished)
        XCTAssertEqual(graph.factory.writerBindings.count, 2)
        XCTAssertNotEqual(graph.factory.writerBindings[0].writerIdentity, graph.factory.writerBindings[1].writerIdentity)
        XCTAssertEqual(graph.factory.writerBindings[0].renditionIdentity, graph.factory.writerBindings[1].renditionIdentity)
        XCTAssertEqual(graph.factory.continuationCount, 1)
        for _ in 0..<200 where graph.factory.initializations.count != 2 || graph.factory.mediaCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try graph.factory.checkCallbackFailures()
        let initializations = graph.factory.initializations
        XCTAssertEqual(initializations.count, 2)
        let configuration = try XCTUnwrap(graph.branch.configuration)
        for bytes in initializations {
            let evidence = try DolbyWriterInitializationEvidence.validate(bytes,
                configuration: configuration, sourceLayout: fixture.source.channelLayout)
            XCTAssertEqual(evidence.channelPositions, UInt32(fixture.channelMask))
        }
        XCTAssertGreaterThanOrEqual(graph.factory.mediaCount, 2)
        await graph.branch.cancelAndAwait()
        XCTAssertGreaterThanOrEqual(graph.producer.coordinator.liveCompressedWriterSubmissionCount, 32)
        graph.factory.aliases.releaseAll()
    }
#endif
}

private struct DolbyBranchFixture: Sendable {
    let codec: VPlayerPlayback.AudioCodec
    let frames: [Data]
    let channelMask: UInt64
    var accessUnit: Data { frames.reduce(into: Data()) { $0.append($1) } }
    var source: AudioTrackDescriptor {
        .init(streamIndex: 1, codec: codec, timeBase: MediaRational(num: 1, den: 48_000)!,
            sampleRate: 48_000, channelLayout: .init(channelCount: 6, nativeMask: channelMask),
            extradata: Data(), metadata: .init(role: .main, service: .independentMain, dispositions: [.default]))
    }
    static func ac3() async throws -> Self {
        let asset = AVURLAsset(url: try FixtureLoader.url("ac3-48k-5point1.mov"))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        guard reader.canAdd(output) else { throw SegmentedFMP4WriterFailure.invalidSystemConfiguration }
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer { if reader.status == .reading { reader.cancelReading() } }
        let next = try await provider.next()
        let sample = try makeOwnedReaderFixtureSample(copying: XCTUnwrap(next))
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let size = CMSampleBufferGetSampleSize(sample, at: 0)
        guard size > 0, size <= CMBlockBufferGetDataLength(block) else {
            throw SegmentedFMP4WriterFailure.sourceFormatMismatch
        }
        var bytes = Data(count: size)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
        }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let inspection = try AC3FrameInspector.inspect(bytes)
        XCTAssertEqual(inspection.sampleRate, 48_000); XCTAssertEqual(inspection.channelCount, 6)
        return Self(codec: .ac3, frames: [bytes], channelMask: 0x3F)
    }
    static func eac3() throws -> Self {
        let bytes = try FixtureLoader.data("eac3-main-6x1block-5.1.eac3")
        var frames: [Data] = []; var offset = 0
        for index in 0..<6 {
            guard offset + 4 <= bytes.count else { throw SegmentedFMP4WriterFailure.sourceFormatMismatch }
            let size = 2 * ((((Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])) & 0x07FF) + 1)
            guard size > 0, size <= bytes.count - offset else { throw SegmentedFMP4WriterFailure.sourceFormatMismatch }
            let frame = bytes.subdata(in: offset..<(offset + size))
            let inspection = try EAC3FrameInspector.inspect(frame)
            XCTAssertEqual(inspection.blockCount, 1); XCTAssertEqual(inspection.channelCount, 6)
            XCTAssertEqual(inspection.convsync, index == 0); XCTAssertEqual(inspection.bsmod, 0)
            XCTAssertEqual(inspection.hasJOC, false)
            frames.append(frame); offset += size
        }
        return Self(codec: .eac3, frames: frames, channelMask: 0x60F)
    }
}

/// A bounded graph-scoped test owner, not a replacement production graph. The
/// writer factory captures only its independent recorder, never this owner.
private final class DolbyBranchTestGraph {
    let producer: DolbyAudioSourceProducer
    let timeline: HLSTimelineCoordinator
    let copies: HLSAudioCopyOwnership
    let factory: DolbyBranchWriterFactory
    let frames: [HLSTimedAudioAccessUnit]
    let branch: DolbyCompressedAudioRenditionBranch

    init(fixture: DolbyBranchFixture, accessUnits: Int, retainsAliases: Bool,
         usesNativeWriter: Bool = false, ownershipLimits: SegmentedFMP4WriterOwnershipLimits? = nil,
         applicationLedger: HLSDeliveryApplicationChargeLedger = .init()) throws {
        precondition((1...40).contains(accessUnits))
        let binding = FMP4WriterBinding(
            outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 91_000),
            itemGeneration: .init(rawValue: 91_001), mediaEpoch: .init(rawValue: 91_002),
            publicationParticipantID: .init(rawValue: 91_003), renditionIdentity: .init(rawValue: 91_004),
            writerIdentity: .init(rawValue: 91_005))
        let executor = PlaybackControlExecutor(allocator: PlaybackIdentityAllocator(),
            applyIngress: { _ in .applied }, applyTerminalIngress: { _ in }, applyOutputControl: { _, _ in .rejected })
        let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 8 * 1_024 * 1_024,
            maximumPCMBytes: 1_024, capacity: 512, applicationLedger: applicationLedger)
        self.copies = copies
        let tracks = DemuxTrackSet(selectedProgramID: 7, video: nil, audio: fixture.source)
        let producer = try DolbyAudioSourceProducer(tracks: tracks, binding: binding,
            sharedControlExecutor: executor, copyOwnership: copies, applicationLedger: applicationLedger)
        self.producer = producer
        let parser = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            let samples = fixture.codec == .ac3 ? Int32(1_536) : try EAC3FrameInspector.inspect(bytes).sampleCount
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(bytes: bytes, pts: pts,
                sampleRate: 48_000, channels: 6, frameSamples: samples, nativeMask: fixture.channelMask))
        }
        let timeline = HLSTimelineCoordinator(parserFactory: parser, hlsAudioCopyOwnership: copies,
            sharedControlExecutor: executor, dolbyProducer: producer)
        self.timeline = timeline
        _ = try timeline.consume(.tracks(tracks))
        var frames: [HLSTimedAudioAccessUnit] = []
        for accessUnit in 0..<accessUnits {
            for (member, bytes) in fixture.frames.enumerated() {
                let sample = 900_000 + accessUnit * 1_536 + (fixture.codec == .eac3 ? member * 256 : 0)
                frames += try timeline.consume(.packet(.init(streamIndex: 1, codec: .audio(fixture.codec),
                    data: bytes, presentationTimeStamp: CMTime(value: Int64(sample), timescale: 48_000),
                    decodeTimeStamp: .invalid, duration: .invalid, isKey: false, isCorrupt: false))).compactMap {
                        if case let .audioSample(frame) = $0 { return frame }; return nil
                    }
            }
        }
        frames += try timeline.consume(.endOfStream).compactMap {
            if case let .audioSample(frame) = $0 { return frame }; return nil
        }
        XCTAssertEqual(frames.count, accessUnits * fixture.frames.count)
        self.frames = frames
        let first = try XCTUnwrap(frames.first)
        let plan = try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan(for: first))
        let authorization = try XCTUnwrap(producer.coordinator.authorizeCompressedCandidate(plan))
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: first.timing.presentationTimeStamp.cmTime))
        let factory = DolbyBranchWriterFactory(binding: binding, boundary: boundary,
            retainsAliases: retainsAliases, usesNativeWriter: usesNativeWriter,
            ownershipLimits: ownershipLimits, applicationLedger: applicationLedger)
        self.factory = factory
        branch = try DolbyCompressedAudioRenditionBranch(producer: producer, authorization: authorization,
            boundary: boundary, initialFormatAdmission: { configuration, format, layout in
                configuration.codec == fixture.codec && format.channelCount == 6
                    && layout.nativeMask == fixture.channelMask
            }, writerFactory: { configuration, description, continuation in
                try factory.make(configuration: configuration, description: description, continuation: continuation)
            })
    }
    deinit {
        branch.cancel()
        timeline.retireCompressedGeneration()
    }
}

private struct DolbyObservedSample: Sendable {
    let bytes: Data
    let presentationTime: CMTime
    let duration: CMTime
    let channelPositions: UInt32?
}

private final class DolbyBranchWriterFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let initialBinding: FMP4WriterBinding
    private let boundary: SegmentBoundaryCoordinator
    private let retainsAliases: Bool
    private let usesNativeWriter: Bool
    private let ownershipLimits: SegmentedFMP4WriterOwnershipLimits?
    private let ledger: HLSDeliveryApplicationChargeLedger
    let aliases = DolbyRetainedBlockAliases(capacity: 40)
    private var bindings: [FMP4WriterBinding] = []
    private var submitted: [DolbyObservedSample] = []
    private var initializationBytes: [Data] = []
    private var mediaObjects = 0
    private var continuations = 0
    private var callbackFailure: String?
    var writerBindings: [FMP4WriterBinding] { lock.withLock { bindings } }
    var samples: [DolbyObservedSample] { lock.withLock { submitted } }
    var initializations: [Data] { lock.withLock { initializationBytes } }
    var mediaCount: Int { lock.withLock { mediaObjects } }
    var continuationCount: Int { lock.withLock { continuations } }

    init(binding: FMP4WriterBinding, boundary: SegmentBoundaryCoordinator, retainsAliases: Bool,
         usesNativeWriter: Bool, ownershipLimits: SegmentedFMP4WriterOwnershipLimits?,
         applicationLedger: HLSDeliveryApplicationChargeLedger) {
        initialBinding = binding; self.boundary = boundary; self.retainsAliases = retainsAliases
        self.usesNativeWriter = usesNativeWriter; self.ownershipLimits = ownershipLimits; ledger = applicationLedger
    }
    func make(configuration: CompressedAudioFormatConfiguration, description: CMAudioFormatDescription,
              continuation: WriterWindowContinuation?) throws -> SegmentedFMP4Writer {
        let ordinal = lock.withLock { bindings.count }
        guard ordinal < 2, (ordinal == 0) == (continuation == nil), usesNativeWriter || continuation == nil else {
            throw SegmentedFMP4WriterFailure.invalidSystemConfiguration
        }
        let binding = FMP4WriterBinding(outputLifecycleEpoch: initialBinding.outputLifecycleEpoch,
            itemGeneration: initialBinding.itemGeneration, mediaEpoch: initialBinding.mediaEpoch,
            publicationParticipantID: initialBinding.publicationParticipantID,
            renditionIdentity: initialBinding.renditionIdentity,
            writerIdentity: .init(rawValue: initialBinding.writerIdentity.rawValue + UInt64(ordinal)))
        if let continuation {
            XCTAssertEqual(continuation.predecessorTerminal.binding, lock.withLock { bindings.last })
            XCTAssertEqual(continuation.predecessorTerminal.terminalReason, .finished)
        }
        let holder = DolbyWeakRelay()
        let relay = SegmentReportRelay(binding: binding, limits: .audio, capacity: 8, objectSink: { [self] object in
            lock.withLock {
                if object.kind == .initialization {
                    if initializationBytes.count < 2 { initializationBytes.append(object.bytes) }
                    else { callbackFailure = "Unexpected extra native initialization" }
                } else { mediaObjects += 1 }
            }
            if holder.relay?.releaseForControl(object) != true {
                lock.withLock { callbackFailure = "Actual callback ownership failed to release" }
            }
        })
        holder.relay = relay
        let system: any SegmentedFMP4SystemWriterFactory = usesNativeWriter
            ? AVAssetSegmentedFMP4SystemWriterFactory() : DolbyPromptSystemFactory(recorder: self)
        let writer = try SegmentedFMP4Writer(binding: binding,
            trackKind: configuration.codec == .ac3 ? .ac3 : .eac3, sourceFormatHint: description,
            boundarySession: boundary.session, compressedFormatConfiguration: configuration,
            ownershipLimits: ownershipLimits, relay: relay, systemFactory: system,
            writerWindowContinuation: continuation, applicationLedger: ledger)
#if DEBUG
        if retainsAliases && ordinal == 0 {
            let aliases = self.aliases
            try writer.observeNativeInputAliasesForTesting { aliases.retain($0) }
        }
#endif
        lock.withLock { bindings.append(binding); if continuation != nil { continuations += 1 } }
        return writer
    }
    func record(_ sample: CMSampleBuffer) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: size)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
        }
        guard status == noErr else { return false }
        return lock.withLock {
            guard submitted.count < 40 else { return false }
            submitted.append(.init(bytes: bytes, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                duration: CMSampleBufferGetDuration(sample), channelPositions: try? CompressedAudioChannelPositions.bitmap(in: format)))
            return true
        }
    }
    func checkCallbackFailures() throws {
        if let failure = lock.withLock({ callbackFailure }) {
            XCTFail(failure); throw SegmentedFMP4WriterFailure.systemFailure
        }
    }
}

private final class DolbyWeakRelay: @unchecked Sendable { weak var relay: SegmentReportRelay? }

private struct DolbyPromptSystemFactory: SegmentedFMP4SystemWriterFactory {
    let recorder: DolbyBranchWriterFactory
    func makeWriter(configuration: SegmentedFMP4SystemConfiguration, sourceFormatHint: CMFormatDescription,
                    callbackSink: any SegmentedFMP4SystemCallbackSink) throws -> any SegmentedFMP4SystemWriting {
        // Never bind native callback identity or emit a native receipt.
        DolbyPromptSystemWriter(recorder: recorder)
    }
}

private final class DolbyPromptSystemWriter: SegmentedFMP4SynchronousSystemWriting, @unchecked Sendable {
    private let recorder: DolbyBranchWriterFactory
    init(recorder: DolbyBranchWriterFactory) { self.recorder = recorder }
    var objectIdentity: ObjectIdentifier { ObjectIdentifier(self) }
    var isReadyForMoreMediaData: Bool { true }
    func startWriting(at sourceTime: CMTime) -> Bool { true }
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool { recorder.record(sampleBuffer) }
    func flushSegment() -> Bool { XCTFail("Prompt-only branch fixture must stay before its first boundary"); return false }
    func markInputAsFinished() { XCTFail("Prompt-only adapter cannot prove real native EOF") }
    func finishWriting(_ completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
    func cancelWriting() {}
}

private final class DolbyRetainedBlockAliases: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storage: [CMBlockBuffer] = []
    init(capacity: Int) { self.capacity = capacity }
    var count: Int { lock.withLock { storage.count } }
    func retain(_ block: CMBlockBuffer) {
        lock.withLock {
            guard storage.count < capacity else { XCTFail("Bounded native alias observation overflow"); return }
            var alias: CMBlockBuffer?
            let status = CMBlockBufferCreateWithBufferReference(allocator: kCFAllocatorDefault,
                referenceBuffer: block, offsetToData: 0, dataLength: CMBlockBufferGetDataLength(block),
                flags: 0, blockBufferOut: &alias)
            XCTAssertEqual(status, noErr)
            if let alias { storage.append(alias) }
        }
    }
    func releaseFirst(_ count: Int) {
        let released: [CMBlockBuffer] = lock.withLock {
            precondition(count <= storage.count)
            let released = Array(storage.prefix(count)); storage.removeFirst(count); return released
        }
        withExtendedLifetime(released) {}
    }
    func releaseAll() {
        let released = lock.withLock { let released = storage; storage.removeAll(); return released }
        withExtendedLifetime(released) {}
    }
}
