// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreMedia
import Foundation
import VPlayerCore
import XCTest
@testable import VPlayerPlayback

final class SourceAACPublicationTests: XCTestCase {
    func testSourceAACWireDeclarationMatchesAACWithoutClaimingEncoderAuthority() throws {
        XCTAssertEqual(HLSAudioCodec.sourceAAC.codecs, HLSAudioCodec.aac.codecs)
        XCTAssertEqual(HLSAudioCodec.sourceAAC.groupPrefix, HLSAudioCodec.aac.groupPrefix)
        var declaration = try Task19.declaration()
        let encoded = try XCTUnwrap(HLSPlaylistSerializer.master(declaration)).raw
        declaration.audio[0].codec = .sourceAAC
        XCTAssertEqual(try HLSPlaylistSerializer.master(declaration)?.raw, encoded)
    }

    func testEncodedCallbackCannotBeRelabeledAsSourceAAC() async throws {
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: .zero))
        let track = try await Task19Track(id: 2, mediaType: .audio, boundary: boundary)
        defer { track.stopWriter() }
        var declaration = try Task19.declaration(audioOnly: true)
        declaration.audio[0].codec = .sourceAAC
        let store = SealedMediaStore(token: Task19.token, itemGeneration: 19)
        defer { store.close() }
        let candidate = try store.registerAudioCandidate(initialization: track.initialization,
            proof: track.proof, declaration: declaration)
        XCTAssertThrowsError(try HLSPublicationCoordinator(store: store,
            participants: [.init(initialization: track.initialization, proof: track.proof,
                relay: track.relay, candidateTicket: candidate.ticket, candidate: candidate,
                aacTerminalBinding: track.aacTerminalBinding)], declaration: declaration,
            anchor: .init(mediaOrigin: .init(value: 0, timescale: 1), utcMilliseconds: 0)))
        _ = track.relay.releaseForControl(track.initialization)
    }

    func testGenuineSourcePublicationKeepsRootAndRejectsRetirement() async throws {
        let fixture = try await SourceAACPublicationFixture.make()
        defer { fixture.close() }
        let snapshot = try XCTUnwrap(fixture.publisher.visible)
        XCTAssertTrue(snapshot.sourceAACTerminalBindings[2] === fixture.root)
        XCTAssertTrue(snapshot.aacTerminalBindings.isEmpty)
        XCTAssertTrue(snapshot.aacTimelineMappings.isEmpty)
        XCTAssertNotNil(fixture.root.finalSeal)
        XCTAssertTrue(fixture.root.isCurrent)
        XCTAssertTrue(try XCTUnwrap(snapshot.media[2]).isFinal)
        XCTAssertEqual(snapshot.media[2]?.effectivePlaybackHorizon, fixture.root.finalSeal?.writtenEnd)
        let last = try XCTUnwrap(fixture.packets.last)
        XCTAssertNotNil(fixture.store.sourceAACProof(for: HLSResourceKey(last.object)))
        fixture.timeline.retireCompressedGeneration()
        XCTAssertFalse(fixture.root.isCurrent)
        XCTAssertNil(fixture.store.sourceAACProof(for: HLSResourceKey(last.object)))
    }

    func testSourceAACProgramDateTimeUsesAcceptedCallbackCoordinatesInTheAnchorDomain() async throws {
        let fixture = try await SourceAACPublicationFixture.make()
        defer { fixture.close() }
        let snapshot = try XCTUnwrap(fixture.publisher.visible)
        let playlist = try XCTUnwrap(snapshot.media[2])
        var starts: [UInt64: ExactMediaTime] = [:]
        for resource in playlist.resources {
            let packet = try XCTUnwrap(fixture.packets.first {
                $0.receipt.logicalSequence == resource.logicalSequence
                    && $0.object.binding.mediaEpoch.rawValue == resource.mediaEpoch
            })
            let evidence = try XCTUnwrap(packet.object.publicationEvidence?.sourceAAC)
            XCTAssertTrue(evidence.matches(packet.object))
            XCTAssertTrue(packet.receipt.matches(media: packet.object, proof: fixture.proof))
            XCTAssertEqual(evidence.writtenRange, packet.receipt.presentationRange)
            // Only this callback's authenticated writer offset converts the
            // native receipt back to the anchor domain. AVAssetReader's output
            // translation is not evidence for this offset, which may be zero.
            let offset = try XCTUnwrap(evidence.timelineOffset)
            starts[resource.logicalSequence] = try packet.receipt.presentationRange.start.subtracting(offset)
        }
        XCTAssertGreaterThan(starts.count, 3)
        XCTAssertEqual(try XCTUnwrap(starts[0]), fixture.root.configuration.firstPresentationTime)
        try Task19ProgramDateTimeChecks.assertDates(snapshot, participantID: 2, starts: starts)
    }

    func testPhysicalWindowFinishDoesNotAuthorizeSourceEOF() async throws {
        let fixture = try await SourceAACPublicationFixture.make(finishSource: false)
        defer { fixture.close() }
        XCTAssertNil(fixture.root.finalSeal)
        XCTAssertThrowsError(try fixture.publisher.publish(ticket: fixture.publisher.ticket,
            now: 1_000_000_000, naturalEnd: true))
        XCTAssertFalse(try XCTUnwrap(fixture.publisher.visible?.media[2]).isFinal)
    }

    func testSourceMediaCannotUseGenericOrEncoderSeal() async throws {
        let fixture = try await SourceAACPublicationFixture.make()
        defer { fixture.close() }
        let packet = try XCTUnwrap(fixture.packets.first)
        let mediaEvidence = CompletedMediaBodyEvidenceState(itemGeneration: 19,
            renditionIdentity: fixture.proof.binding.renditionIdentity, mediaEpoch: 1,
            resourceIdentity: packet.object.backing.identity, sealedDigest: packet.object.digest,
            sealedBodyLength: packet.object.bytes.count)
        let initEvidence = CompletedInitBodyEvidenceState(itemGeneration: 19,
            renditionIdentity: fixture.proof.binding.renditionIdentity, mediaEpoch: 1,
            resourceIdentity: fixture.initialization.backing.identity, sealedDigest: fixture.initialization.digest,
            sealedBodyLength: fixture.initialization.bytes.count)
        XCTAssertThrowsError(try SealedDecodeCoverageMap.seal(media: packet.object, proof: fixture.proof,
            receipt: packet.receipt, initialization: fixture.initialization, evidence: mediaEvidence,
            initializationEvidence: initEvidence))
        let sourceMap = try SealedDecodeCoverageMap.sealSourceAAC(media: packet.object, proof: fixture.proof,
            receipt: packet.receipt, initialization: fixture.initialization, initializationProof: fixture.proof,
            binding: fixture.root, evidence: mediaEvidence, initializationEvidence: initEvidence)
        XCTAssertEqual(sourceMap.maximumSampleCount, 320)
        XCTAssertTrue(sourceMap.sourceAACProof?.binding === fixture.root)
        XCTAssertLessThanOrEqual(sourceMap.applicationChargeableBytes + 4_096,
            LoopbackStorageLayout.current.mediaMapReservationBytes)
        fixture.timeline.retireCompressedGeneration()
        XCTAssertFalse(try XCTUnwrap(sourceMap.sourceAACProof).isCurrent)
        XCTAssertThrowsError(try SealedDecodeCoverageMap.sealSourceAAC(media: packet.object, proof: fixture.proof,
            receipt: packet.receipt, initialization: fixture.initialization, initializationProof: fixture.proof,
            binding: fixture.root, evidence: mediaEvidence, initializationEvidence: initEvidence))
    }

    func testHTTPSourceTimelineRequiresCompletedBytesAndSameCurrentRoot() async throws {
        let fixture = try await SourceAACPublicationFixture.make()
        defer { fixture.close() }
        let snapshot = try XCTUnwrap(fixture.publisher.visible)
        let server = try await LoopbackHTTPServer.start(store: fixture.store,
            declaration: fixture.declaration, publishedSnapshot: snapshot,
            sessionCapability: fixture.session, now: { 1_000_000_000 }, logger: { _ in })
        let evidenceSource = try LoopbackAVPlayerPreparationEvidenceSource.make(server: server)
        defer {
            evidenceSource.retirePreparation()
            let ticket = server.closeAdmission()
            try? server.drain(cleanupTicket: ticket)
            try? server.retire(cleanupTicket: ticket)
        }
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: fixture.proof.binding.outputLifecycleEpoch,
            itemGeneration: 19)
        let request = try server.makeAVPlayerPreparationRequest(item: item,
            publicationSequence: snapshot.publicationSequence)
        XCTAssertEqual(request.audioParticipants.first?.codec, .sourceAAC)
        XCTAssertTrue(request.audioParticipants.first?.sourceAACBinding === fixture.root)
        XCTAssertNil(request.audioParticipants.first?.terminalBinding)
        XCTAssertNil(fixture.store.currentFinalPublication(matching: fixture.writer.binding))
        XCTAssertNil(server.completedPublicationCapability(itemURL: request.itemURL, itemGeneration: 19,
            publicationSequence: snapshot.publicationSequence))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let playlist = try XCTUnwrap(snapshot.media[2])
        let urls = [request.itemURL] + (try (playlist.initializationResources + playlist.resources).map {
            try XCTUnwrap(URL(string: server.path(for: $0), relativeTo: server.baseURL)?.absoluteURL)
        })
        for url in urls {
            var get = URLRequest(url: url); get.setValue("close", forHTTPHeaderField: "Connection")
            let (bytes, response) = try await session.data(for: get)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(bytes.isEmpty)
        }
        let completed = try XCTUnwrap(server.frozenCompletedPublication(itemURL: request.itemURL,
            itemGeneration: 19, publicationSequence: snapshot.publicationSequence,
            preparationOwner: evidenceSource.preparationOwner))
        let selection = try XCTUnwrap(completed.audioSelectionCapability)
        let timeline: PlayerItemTimelineMappingAuthority
        switch try server.makePlayerItemTimelineMappingAuthority(endpointAuthority: nil,
            completedPublication: completed, itemURL: request.itemURL, item: item,
            publicationSequence: snapshot.publicationSequence, expectedSelection: selection) {
        case .ready(let value): timeline = value
        case .invalid, .waitingForSelection: return XCTFail("Genuine completed source bytes must issue the source timeline")
        }
        XCTAssertTrue(timeline.sourceAACBinding === fixture.root)
        XCTAssertNil(timeline.aacEndpointReceipt)
        XCTAssertNil(timeline.aacPrefixReceipt)
        XCTAssertEqual(timeline.writtenPhysicalBase, timeline.writtenEffectiveBase)
        XCTAssertTrue(timeline.matches(itemURL: request.itemURL, item: item,
            publicationSequence: snapshot.publicationSequence, selection: selection))
        let final = try XCTUnwrap(fixture.store.currentFinalPublication(matching: fixture.writer.binding))
        XCTAssertTrue(fixture.store.validatesSourceAACFinal(final, binding: fixture.root),
            "A near-EOF pause needs completed final publication plus the exact genuine source EOF")
        let firstKey = try XCTUnwrap(playlist.resources.first)
        let map = try XCTUnwrap(fixture.store.decodeCoverageMap(for: firstKey))
        let body = try XCTUnwrap(server.completedEvidence(for: firstKey))
        let range = try XCTUnwrap(map.samples.first).presentationRange
        XCTAssertTrue(try map.isCovered(by: body, requested: range))
        XCTAssertTrue(try fixture.store.preparationCoverageCanFreeze(owner: evidenceSource.preparationOwner,
            rendition: fixture.proof.binding.renditionIdentity, requested: range))
        fixture.timeline.retireCompressedGeneration()
        XCTAssertFalse(try map.isCovered(by: body, requested: range))
        XCTAssertFalse(try fixture.store.preparationCoverageCanFreeze(owner: evidenceSource.preparationOwner,
            rendition: fixture.proof.binding.renditionIdentity, requested: range))
        XCTAssertFalse(fixture.store.validatesSourceAACFinal(final, binding: fixture.root))
        XCTAssertFalse(timeline.matches(itemURL: request.itemURL, item: item,
            publicationSequence: snapshot.publicationSequence, selection: selection))
        if case .ready = try server.makePlayerItemTimelineMappingAuthority(endpointAuthority: nil,
            completedPublication: completed, itemURL: request.itemURL, item: item,
            publicationSequence: snapshot.publicationSequence, expectedSelection: selection) {
            XCTFail("A cached timeline must not outlive its retired source root")
        }
    }

}

/// Synthetic AAC is encoded once with Apple's real converter, then treated as a
/// source packet stream. The remux writer and callback path are production ones;
/// no callback, publication, or EOF receipt is manufactured by this fixture.
final class SourceAACPublicationFixture: @unchecked Sendable {
    let timeline: HLSTimelineCoordinator
    let writer: SegmentedFMP4Writer
    let root: SourceAACWriterTerminalBinding
    let store: SealedMediaStore
    let publisher: HLSPublicationCoordinator
    let declaration: HLSItemDeclaration
    let packets: [Task19Packet]
    let initialization: SealedMediaObject
    let proof: EpochFormatProof
    let relay: SegmentReportRelay
    let session: LoopbackSessionToken

    private init(timeline: HLSTimelineCoordinator, writer: SegmentedFMP4Writer,
                 store: SealedMediaStore, publisher: HLSPublicationCoordinator,
                 declaration: HLSItemDeclaration, packets: [Task19Packet],
                 initialization: SealedMediaObject, proof: EpochFormatProof,
                 relay: SegmentReportRelay, session: LoopbackSessionToken) throws {
        self.timeline = timeline; self.writer = writer; self.store = store
        self.publisher = publisher; self.declaration = declaration; self.packets = packets
        self.initialization = initialization; self.proof = proof; self.relay = relay
        self.session = session; root = try XCTUnwrap(writer.sourceAACTerminalBinding)
    }

    static func make(finishSource: Bool = true, loopbackSession: LoopbackSessionToken? = nil,
                     binding suppliedBinding: FMP4WriterBinding? = nil, diagnostics: SourceAACFixtureDiagnostics? = nil) async throws -> SourceAACPublicationFixture {
        let observer: any AACCalibrationObserver
        if let diagnostics { observer = diagnostics }
        else { observer = AACDefaultCalibrationObserver() }
        diagnostics?.record("calibration-begin")
        let request = try AACRenditionRequest(layout: .init(labels: [.l, .r]),
            capabilityVersion: "source-aac-publication-native-v1")
        let calibration = try await AACPrimingCalibrator(observer: observer).calibrate(plan: .build([request]))
        diagnostics?.record("calibration-return")
        let encoder = try XCTUnwrap(calibration.encoders.first)
        diagnostics?.record("input-encode-begin")
        let encoded = try encoder.encodeEpoch((0..<(8_192 * 2)).map {
            sin(Float($0) * 0.025) * 0.2
        })
        diagnostics?.record("input-encode-return")
        let buffer = try XCTUnwrap(encoded.buffers.first(where: {
            CMSampleBufferGetNumSamples($0) == 1
        }))
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
        var payload = Data(count: CMBlockBufferGetDataLength(block))
        let length = payload.count
        XCTAssertEqual(payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }, noErr)
        diagnostics?.record("input-copy-complete")
        let copies = HLSAudioCopyOwnership(maximumCompressedBytes: 1_048_576,
            maximumPCMBytes: 1_024, capacity: 512)
        let timeline = HLSTimelineCoordinator(hlsAudioCopyOwnership: copies)
        let asc = Data([0x11, 0x90])
        _ = try timeline.consume(.tracks(.init(selectedProgramID: nil, video: nil,
            audio: .init(streamIndex: 1, codec: .aac, timeBase: MediaRational(num: 1, den: 48_000)!,
                sampleRate: 48_000, channelLayout: .init(channelCount: 2, nativeMask: 3), extradata: asc))))
        func unit(_ index: Int) throws -> HLSTimedAudioAccessUnit {
            let events = try timeline.consume(.packet(.init(streamIndex: 1, codec: .audio(.aac), data: payload,
                presentationTimeStamp: CMTime(value: 480_000 + Int64(index) * 1_024, timescale: 48_000),
                decodeTimeStamp: .invalid, duration: .invalid, isKey: true, isCorrupt: false)))
            return try XCTUnwrap(events.compactMap {
                if case .audioSample(let value) = $0 { return value }; return nil
            }.first)
        }
        let first = try unit(0)
        let binding = suppliedBinding ?? Task19.binding(id: 2, writer: 989_101)
        let configuration = try SourceAACWriterConfiguration(first: first,
            source: .init(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2, channelMask: 3,
                decoderConfiguration: asc, priming: .notSignaledPreserveTimestamps,
                service: .independentMain, formatValidated: true), binding: binding)
        let boundary = try SegmentBoundaryCoordinator(mode: .audioOnly(epochStart: first.timing.presentationTimeStamp.cmTime))
        try boundary.registerAudioRendition(binding.renditionIdentity, accessUnit: .aac(sampleRate: 48_000),
            firstPhysicalStart: first.timing.presentationTimeStamp.cmTime,
            firstEffectiveStart: first.timing.presentationTimeStamp.cmTime)
        let sink = SourceAACPublicationCollector()
        let relay = SegmentReportRelay(binding: binding, limits: .audio, capacity: 16, objectSink: sink.collect)
        let writer = try SegmentedFMP4Writer(binding: binding, trackKind: .aac,
            sourceFormatHint: configuration.sourceFormatHint, boundarySession: boundary.session,
            compressedFormatConfiguration: nil, relay: relay,
            systemFactory: AVAssetSegmentedFMP4SystemWriterFactory(), sourceAACConfiguration: configuration)
        try writer.start(at: first.timing.presentationTimeStamp.cmTime)
        do {
            diagnostics?.record("source-append-begin")
            try await writer.appendSourceAACAwaitingReadiness(.init(timed: first,
                configuration: configuration, binding: binding), boundary: boundary)
            for index in 1..<290 {
                if index == 145 { diagnostics?.record("source-append-145-complete") }
                try await writer.appendSourceAACAwaitingReadiness(.init(timed: unit(index),
                    configuration: configuration, binding: binding), boundary: boundary)
            }
            diagnostics?.record("source-append-290-complete")
            diagnostics?.record("source-finish-begin")
            if finishSource {
                _ = try timeline.consume(.endOfStream)
                _ = try await writer.finishSourceAAC()
            } else { _ = try await writer.finish() }
            diagnostics?.record("source-finish-return")
            let objects = sink.takeAll()
            let initialization = try XCTUnwrap(objects.first(where: { $0.kind == .initialization }))
            let proof = try FinalFMP4Validator(binding: binding, mediaType: .audio).validateInitialization(initialization)
            let validator = SegmentTimelineValidator(proof: proof, firstLogicalSequence: 0)
            let packets = try objects.filter { $0.kind == .media }.sorted {
                $0.logicalSequence < $1.logicalSequence
            }.map { Task19Packet(object: $0, receipt: try validator.validate($0, using: proof), relay: relay) }
            let session = try loopbackSession ?? LoopbackSessionToken.generateSystemCapability()
            let store = SealedMediaStore(loopbackSession: session, itemGeneration: 19)
            var declaration = try Task19.declaration(audioOnly: true)
            declaration.token = session.value; declaration.audio[0].codec = .sourceAAC
            let candidate = try store.registerAudioCandidate(initialization: initialization,
                proof: proof, declaration: declaration)
            let publisher = try HLSPublicationCoordinator(store: store,
                participants: [.init(initialization: initialization, proof: proof, relay: relay,
                    candidateTicket: candidate.ticket, candidate: candidate,
                    sourceAACTerminalBinding: writer.sourceAACTerminalBinding)], declaration: declaration,
                anchor: .init(mediaOrigin: first.timing.presentationTimeStamp, utcMilliseconds: 0))
            for packet in (finishSource ? packets : Array(packets.dropLast())) {
                _ = try publisher.offer(packet.object, receipt: packet.receipt, relay: relay,
                    ticket: publisher.ticket, now: 0, naturalEndTail: finishSource)
            }
            if finishSource {
                _ = try publisher.publish(ticket: publisher.ticket, now: 1_000_000_000, naturalEnd: true)
            }
            diagnostics?.record("source-publication-complete")
            return try .init(timeline: timeline, writer: writer, store: store, publisher: publisher,
                declaration: declaration, packets: packets, initialization: initialization,
                proof: proof, relay: relay, session: session)
        } catch {
            diagnostics?.record("source-error-before-cleanup", error: error)
            _ = await writer.cancelAwaitingCompletion(); timeline.retireCompressedGeneration(); throw error
        }
    }

    func close() {
        publisher.close(); timeline.retireCompressedGeneration(); _ = writer.cancel()
        for packet in packets { _ = relay.releaseForControl(packet.object) }
        _ = relay.releaseForControl(initialization)
    }
}

private final class SourceAACPublicationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [SealedMediaObject] = []
    func collect(_ object: SealedMediaObject) { lock.withLock { objects.append(object) } }
    func takeAll() -> [SealedMediaObject] {
        lock.withLock { let values = objects; objects.removeAll(); return values }
    }
}

/// Test-only scalar observations. No native object, URL, error text or authority escapes.
final class SourceAACFixtureDiagnostics: AACCalibrationObserver, @unchecked Sendable {
    private let started = ContinuousClock.now
    private let attempt: Int
    private let lock = NSLock()
    private struct Event: Equatable {
        let stage: String
        let index: Int
        let elapsed: Int64
        let category: String
        let code: Int
    }
    private var records: [Event] = []
    private var firstError: Event?
    private var lastError: Event?
    private var truncated = false
    private var errorFlushes = 0
    private var terminalFlushes = 0
    private var initializationWriters = Set<ObjectIdentifier>()
    init(attempt: Int) { self.attempt = attempt }
    func record(_ stage: String, index: Int = 0, error: (any Error)? = nil) {
        let duration = started.duration(to: .now).components
        let elapsed = max(0, min(3_600_000, duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000))
        var category = "none"
        var code = 0
        if let error {
            let native = error as NSError
            code = max(-2_147_483_648, min(2_147_483_647, native.code))
            if error is CancellationError { category = "cancelled" }
            else if let failure = error as? AACRenditionFailure {
                switch failure {
                case .framework(let status), .frameworkProperty(let status, _): category = "aac-framework"; code = Int(status)
                default: category = "other"
                }
            } else if native.domain == AVFoundationErrorDomain { category = "avfoundation" }
            else if native.domain == NSOSStatusErrorDomain { category = "osstatus" }
            else { category = "other" }
        }
        let event = Event(stage: stage, index: index, elapsed: elapsed, category: category, code: code)
        let snapshot = lock.withLock { () -> ([Event], Bool)? in
            if records.count == 64 { records.removeFirst(); truncated = true }
            records.append(event)
            if error != nil {
                if firstError == nil { firstError = event }
                lastError = event
            }
            // Keep observations off SDK callback stdout. Flush on error before
            // the caller's cleanup, or after real retirement, with fixed limits.
            if error != nil, errorFlushes < 4 { errorFlushes += 1 }
            else if stage == "retire-return", terminalFlushes < 2 { terminalFlushes += 1 }
            else { return nil }
            var values = records
            if let firstError, !values.contains(firstError) { values.insert(firstError, at: 0) }
            if let lastError, !values.contains(lastError) { values.append(lastError) }
            return (values, truncated)
        }
        if let (values, truncated) = snapshot {
            for value in values {
                print("SOURCE_AAC_FIXTURE_STAGE attempt=\(attempt) stage=\(value.stage) index=\(value.index) elapsed-ms=\(value.elapsed) category=\(value.category) code=\(value.code)")
            }
            if truncated {
                print("SOURCE_AAC_FIXTURE_STAGE attempt=\(attempt) stage=diagnostic-truncated index=0 elapsed-ms=\(elapsed) category=none code=0")
            }
        }
    }
    func cookie(_ value: Data, at stage: AACCookieStage) -> Data {
        if case .finalizedPass(let pass) = stage { record("calibration-pass-\(pass)-encoded") }
        return value
    }
    func completedPass(_ pass: Int, lane: AACOwnedCallLane) { record("calibration-pass-\(pass)-complete") }
    func loopbackPhase(_ phase: AACLoopbackPhase, lane: AACOwnedCallLane) {
        switch phase {
        case .loadedTracks: record("calibration-tracks-loaded")
        case .createReader: record("calibration-reader-create")
        }
    }
    func willDispose() { record("calibration-dispose") }
    func writerSegment(initialization: Bool, writerIdentity: ObjectIdentifier) {
        guard initialization else { return }
        let ordinal = lock.withLock { () -> Int? in
            guard initializationWriters.count < 2,
                  initializationWriters.insert(writerIdentity).inserted else { return nil }
            return initializationWriters.count
        }
        if let ordinal { record("calibration-native-init", index: ordinal) }
    }
}
