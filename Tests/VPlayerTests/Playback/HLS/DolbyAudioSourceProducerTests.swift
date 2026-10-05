// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class DolbyAudioSourceProducerTests: XCTestCase {
    func testInterleavedTransportClockProofsStayCurrentAfterOutputRetirement() throws {
        for codec: AudioCodec in [.ac3, .eac3] {
            let source = AudioTrackDescriptor(streamIndex: 1, codec: codec,
                timeBase: MediaRational(num: 1, den: 90_000)!, sampleRate: 48_000,
                channelLayout: .init(channelCount: 6, nativeMask: 0x60F), extradata: Data(),
                metadata: .init(role: .main, service: .independentMain, dispositions: [.default]))
            let harness = try DolbyProducerTestHarness(sourceDescriptor: source)
            defer { harness.producer.cancel() }
            let bytes: Data
            let samples: Int32
            if codec == .ac3 {
                bytes = AssemblerTestFixtures.syntheticAC3Frame(acmod: 7, lfeon: true)
                samples = 1_536
            } else {
                let fixture = try FixtureLoader.data("eac3-main-6x1block-5.1.eac3")
                let size = 2 * (((Int(fixture[2]) & 7) << 8 | Int(fixture[3])) + 1)
                bytes = Data(fixture.prefix(size))
                samples = try EAC3FrameInspector.inspect(bytes).sampleCount
            }
            let profile = try AudioCodecProfileRegistry.profile(for: source)
            for index in 0..<16 {
                let tail = HLSAudioCopyTail(try XCTUnwrap(harness.copies.compressedInput.acquire(bytes: bytes.count)))
                let pts = source.timeBase.cmTime(forFFmpegValue: Int64(index) * Int64(samples) * 90_000 / 48_000)
                let framed = FramedCompressedAudioFrame(payload: bytes, presentationTimeStamp: pts,
                    parserSampleCount: samples, parserSampleRate: 48_000, parserChannelLayout: source.channelLayout,
                    containerMarkedCorrupt: false, hlsCopyTail: tail)
                let proof = try harness.producer.makeProof(id: UInt64(index + 1), generation: .init(rawValue: 1),
                    framed: framed, inspected: profile.inspect(framed, source: source))
                if index == 0 { try harness.producer.beginOutput() }
                let admitted = try harness.producer.admitForOutput(proof)
                XCTAssertEqual(admitted.identity.proofIdentity.codecFacts, proof.codecFacts)
                XCTAssertTrue(harness.producer.coordinator.retireAdmittedProof(admitted))
                proof.forgetRetiredAdmission()
                XCTAssertTrue(harness.producer.isCurrent)
                XCTAssertNotNil(harness.producer.outputPlanBinding)
                XCTAssertEqual(harness.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
            }
            try harness.producer.finishSourceInput()
            XCTAssertNoThrow(try harness.producer.requireSourceDrained(throughFrameID: 16))
        }
    }

    func testStartupFramesDoNotFillServiceRegistryBeforeOutputConsumesThem() throws {
        let harness = try DolbyProducerTestHarness()
        var proofs: [DolbyAudioFrameProof] = []
        for index in 0..<40 { proofs.append(try harness.proof(id: UInt64(index + 1), sample: Int64(index * 1_536))) }
        XCTAssertEqual(harness.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
        for proof in proofs {
            let admitted = try harness.producer.admitForOutput(proof)
            XCTAssertEqual(admitted.identity.proofIdentity.codecFacts, proof.codecFacts)
            XCTAssertTrue(harness.producer.coordinator.retireAdmittedProof(admitted))
            XCTAssertThrowsError(try harness.producer.admitForOutput(proof), "Retirement cannot permit replay")
        }
        XCTAssertEqual(harness.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
    }

    func testEmptyTransportExtradataUsesValidatedHeaderConfiguration() throws {
        let harness = try DolbyProducerTestHarness()
        let proof = try harness.proof(id: 1, sample: 0)
        XCTAssertTrue(harness.source.extradata.isEmpty)
        XCTAssertEqual(proof.configuration.codec, .eac3)
        XCTAssertEqual(proof.configuration.serializedBox.count, 13)
        XCTAssertEqual(proof.codecFacts.sampleCount, 1_536)
        XCTAssertEqual(proof.sourceLayout.nativeMask, 3)
        XCTAssertNotNil(harness.producer.outputPlanBinding)
    }

    func testOneBlockFramesHaveExactDurationAndDoNotInventCompleteAU() throws {
        let harness = try DolbyProducerTestHarness()
        let first = try harness.proof(id: 1, sample: 0, blocks: 1, convsync: true)
        let second = try harness.proof(id: 2, sample: 256, blocks: 1, convsync: false)
        XCTAssertEqual(first.codecFacts.eac3BlockCount, 1)
        XCTAssertEqual(first.duration, CMTime(value: 256, timescale: 48_000))
        XCTAssertEqual(second.presentationTimeStamp, CMTime(value: 256, timescale: 48_000))
        XCTAssertEqual(harness.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
    }

    func testSixOneBlockMembersAggregateInOrderAndRetireEveryServiceProof() throws {
        let harness = try DolbyProducerTestHarness()
        var proofs: [DolbyAudioFrameProof] = []
        for index in 0..<6 {
            proofs.append(try harness.proof(id: UInt64(index + 1), sample: Int64(index * 256),
                blocks: 1, convsync: index == 0))
        }
        let authorization = try harness.authorization()
        let assembler = EAC3AccessUnitAssembler(coordinator: harness.producer.coordinator,
            authorization: authorization, allocator: harness.producer.allocator)
        var completed: CompressedAudioAccessUnit?
        for (index, proof) in proofs.enumerated() {
            let admitted = try harness.producer.admitForOutput(proof)
            XCTAssertTrue(try harness.producer.coordinator.registerEligibleCompressedPlan(authorization, for: admitted))
            let lease = try XCTUnwrap(harness.producer.coordinator.issueAudioServiceBranchLease(
                for: admitted, admission: authorization.admissionIdentity))
            completed = try assembler.append(inputUnit: proof.inputUnit, admittedProof: admitted, aggregationLease: lease)
            XCTAssertEqual(completed == nil, index < 5)
        }
        let unit = try XCTUnwrap(completed)
        XCTAssertEqual(unit.sampleCount, 1_536)
        XCTAssertEqual(unit.payload, proofs.reduce(into: Data()) { $0.append($1.inputUnit.bytes) })
        XCTAssertEqual(unit.presentationEnd, CMTime(value: 1_536, timescale: 48_000))
        let bundle = try XCTUnwrap(unit.eac3BundleIdentity)
        for lease in try XCTUnwrap(unit.aggregationProof).orderedAggregationLeaseIdentities.values {
            XCTAssertEqual(harness.producer.coordinator.releaseAudioServiceBranchLease(lease,
                expectedOwner: .eac3AccessUnit(bundle)), .released)
        }
        for proof in proofs {
            XCTAssertTrue(harness.producer.coordinator.retireAdmittedProof(try XCTUnwrap(proof.admittedProof)))
            proof.forgetRetiredAdmission()
            XCTAssertNil(proof.admittedProof)
            XCTAssertThrowsError(try harness.producer.admitForOutput(proof))
        }
        XCTAssertEqual(harness.producer.coordinator.audioServiceRegistryUsage.admittedProofs, 0)
    }

    func testEOFMustBeActualDrainThroughExactFinalSourceID() throws {
        let harness = try DolbyProducerTestHarness()
        _ = try harness.proof(id: 1, sample: 0)
        _ = try harness.proof(id: 2, sample: 1_536)
        XCTAssertThrowsError(try harness.producer.requireSourceDrained(throughFrameID: 2))
        try harness.producer.finishSourceInput()
        XCTAssertNoThrow(try harness.producer.requireSourceDrained(throughFrameID: 2))
        XCTAssertThrowsError(try harness.producer.requireSourceDrained(throughFrameID: 1))
        XCTAssertThrowsError(try harness.proof(id: 3, sample: 3_072))
    }

    func testCancellationAndPoisonCannotBeSealedAsSourceEOF() throws {
        for cancel in [false, true] {
            let harness = try DolbyProducerTestHarness()
            _ = try harness.proof(id: 1, sample: 0)
            if cancel { harness.producer.cancel() } else { harness.producer.invalidateSourceInput() }
            XCTAssertThrowsError(try harness.producer.finishSourceInput())
            XCTAssertThrowsError(try harness.producer.requireSourceDrained(throughFrameID: 1))
        }
    }

    func testUnsupportedServiceDoesNotBecomeOutputAdmission() throws {
        for (streamType, bsmod, joc): (UInt8, UInt8, Bool) in [(1, 0, false), (0, 2, false), (0, 0, true)] {
            let harness = try DolbyProducerTestHarness()
            let data = Task16EAC3Fixture.make(blockCount: 6, streamType: streamType,
                substreamID: 0, bsid: 16, bsmod: bsmod, convsync: nil, hasJOC: joc)
            XCTAssertThrowsError(try harness.proof(id: 1, sample: 0, payload: data))
            XCTAssertNil(harness.producer.outputPlanBinding)
        }
    }

    func testProofCannotBeConsumedByDifferentProducer() throws {
        let first = try DolbyProducerTestHarness()
        let second = try DolbyProducerTestHarness()
        let proof = try first.proof(id: 1, sample: 0)
        XCTAssertThrowsError(try second.producer.admitForOutput(proof))
        XCTAssertNoThrow(try first.producer.admitForOutput(proof))
    }

    func testSourceGenerationAndHeaderDriftPoisonOneProducer() throws {
        let harness = try DolbyProducerTestHarness()
        _ = try harness.proof(id: 1, sample: 0)
        XCTAssertThrowsError(try harness.proof(id: 2, sample: 1_536, generation: 2))
        XCTAssertThrowsError(try harness.producer.finishSourceInput())
    }
}

final class DolbyProducerTestHarness {
    let source: AudioTrackDescriptor
    let copies: HLSAudioCopyOwnership
    let producer: DolbyAudioSourceProducer
    private var timeline: HLSTimelineCoordinator?

    init(sourceDescriptor: AudioTrackDescriptor? = nil) throws {
        source = sourceDescriptor ?? AudioTrackDescriptor(streamIndex: 1, codec: .eac3,
            timeBase: MediaRational(num: 1, den: 48_000)!, sampleRate: 48_000,
            channelLayout: .init(channelCount: 2, nativeMask: 3), extradata: Data(),
            metadata: .init(role: .main, service: .independentMain, dispositions: [.default]))
        copies = HLSAudioCopyOwnership(maximumCompressedBytes: 8 * 1_024 * 1_024,
            maximumPCMBytes: 1_024, capacity: 256)
        let executor = PlaybackControlExecutor(allocator: PlaybackIdentityAllocator(),
            applyIngress: { _ in .applied }, applyTerminalIngress: { _ in },
            applyOutputControl: { _, _ in .rejected })
        producer = try DolbyAudioSourceProducer(tracks: .init(selectedProgramID: 7, video: nil, audio: source),
            binding: .init(outputLifecycleEpoch: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 1), itemGeneration: .init(rawValue: 1),
                mediaEpoch: .init(rawValue: 1), publicationParticipantID: .init(rawValue: 1),
                renditionIdentity: .init(rawValue: 1), writerIdentity: .init(rawValue: 1)),
            sharedControlExecutor: executor, copyOwnership: copies)
    }

    func authorization() throws -> CompressedAudioCandidatePlanAuthorization {
        let output = try XCTUnwrap(producer.outputPlanBinding)
        let parser = ScriptedFFmpegParserFactory { handle, _, bytes, pts, _, _ in
            try handle.emit(AssemblerTestFixtures.parsedAudioFrame(bytes: bytes, pts: pts,
                sampleRate: 48_000, channels: 2, frameSamples: 1_536, nativeMask: 3))
        }
        let timeline = HLSTimelineCoordinator(parserFactory: parser, compressedAudioOutputPlanBinding: output)
        self.timeline = timeline
        _ = try timeline.consume(.tracks(.init(selectedProgramID: 7, video: nil, audio: source)))
        let bytes = Task16EAC3Fixture.make(blockCount: 6, streamType: 0, substreamID: 0,
            bsid: 16, bsmod: 0, convsync: nil, hasJOC: false)
        _ = try timeline.consume(.packet(.init(streamIndex: 1, codec: .audio(.eac3), data: bytes,
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid, duration: .invalid,
            isKey: false, isCorrupt: false)))
        return try XCTUnwrap(producer.coordinator.authorizeCompressedCandidate(
            try XCTUnwrap(timeline.makeCompressedAudioCandidatePlan())))
    }

    func proof(id: UInt64, sample: Int64, blocks: Int = 6, convsync: Bool? = nil,
               generation: UInt64 = 1, payload: Data? = nil) throws -> DolbyAudioFrameProof {
        let bytes = payload ?? Task16EAC3Fixture.make(blockCount: blocks, streamType: 0,
            substreamID: 0, bsid: 16, bsmod: 0, convsync: convsync, hasJOC: false)
        let tail = HLSAudioCopyTail(try XCTUnwrap(copies.compressedInput.acquire(bytes: bytes.count)))
        let framed = FramedCompressedAudioFrame(payload: bytes,
            presentationTimeStamp: CMTime(value: sample, timescale: 48_000),
            parserSampleCount: Int32(blocks * 256), parserSampleRate: 48_000,
            parserChannelLayout: source.channelLayout, containerMarkedCorrupt: false, hlsCopyTail: tail)
        let inspected = try EAC3AudioCodecProfile().inspect(framed, source: source)
        return try producer.makeProof(id: id, generation: .init(rawValue: generation),
            framed: framed, inspected: inspected)
    }
}
