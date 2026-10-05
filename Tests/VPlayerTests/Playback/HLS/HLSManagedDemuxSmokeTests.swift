// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSManagedDemuxSmokeTests: XCTestCase {
    func testFixturePublishesReadyOriginBeforeAuthenticatedRangeAndHEADRequests() async throws {
        let bytes = Data("ordinary fixture body".utf8)
        let origin = try NativeHLSHTTPFixture(resources: [
            "/media.ts": .init(data: bytes, contentType: "video/mp2t")], credential: "fixture credential")
        let client = URLSession(configuration: .ephemeral)
        var failure: (any Error)?
        do {
            let url = origin.url("media.ts")
            XCTAssertGreaterThan(try XCTUnwrap(url.port), 0)
            _ = try PlaybackSourceOrigin(url)
            var request = URLRequest(url: url)
            request.setValue("fixture credential", forHTTPHeaderField: "Authorization")
            request.setValue("bytes=1-4", forHTTPHeaderField: "Range")
            let ranged = try await client.data(for: request)
            let response = try XCTUnwrap(ranged.1 as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode, 206)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 1-4/\(bytes.count)")
            XCTAssertEqual(ranged.0, bytes.subdata(in: 1..<5))
            request.httpMethod = "HEAD"
            let headed = try await client.data(for: request)
            XCTAssertEqual((headed.1 as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual((headed.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "4")
            XCTAssertTrue(headed.0.isEmpty)
            XCTAssertEqual(origin.authenticatedCount, 2)
            XCTAssertEqual(origin.deniedCount, 0)
        } catch { failure = error }
        client.invalidateAndCancel()
        await origin.close()
        if let failure { throw failure }
    }

    func testManagedTSMediaPlaylistReachesRealPinnedFFmpegWithTypedSegmentSuffix() async throws {
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "progressive-h264-aac", withExtension: "ts")))
        try await runManagedMedia(header: nil, media: bytes, duration: 4, expectedSuffix: "ts")
    }

    func testManagedRealWriterFMP4MAPAndSegmentReachPinnedFFmpegWithoutExtensionOverride() async throws {
        // Produce ordinary in-memory media with the real native writer from the
        // committed TS; no FFmpeg muxer or generated fixture file is involved.
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "task22-progressive-h264-aac-16s", withExtension: "ts")))
        let origin = try NativeHLSHTTPFixture(resources: ["/source.ts": .init(data: bytes, contentType: "video/mp2t")])
        let capture = ManagedVideoFragmentCapture()
        let authority = try SystemHLSMediaGraphAuthority(lifecycle: AudioServiceLeaseTestHarness.makeLifecycle(outputNonce: 71_008))
        authority.publicationForTesting.installBeforeReceiveForTesting { capture.consume($0) }
        let assembler = HLSMediaGraphAssembler(sourceURL: origin.url("source.ts"), applicationLedger: .shared,
            graph: SystemHLSDeliveryGraph(authority: authority))
        var failure: (any Error)?
        do {
            let prefix = try await assembler.startUntilPlayablePrefix()
            guard capture.snapshot != nil else { throw HLSSourceError.incompleteEvidence }
            (prefix.evidenceSource as? LoopbackAVPlayerPreparationEvidenceSource)?.retirePreparation()
        } catch { failure = error }
        let retired = await assembler.retireAndAwaitReceipt()
        XCTAssertTrue(retired)
        await origin.close()
        if let failure { throw failure }
        let sample = try XCTUnwrap(capture.snapshot)
        // Exercise the same closed source-admission boundary on the actual native
        // writer bytes. Do not weaken it or substitute a hand-written MP4.
        let combined = sample.header + sample.media
        var container: Int32 = 0, usable = 0
        let admission = combined.withUnsafeBytes { bytes in
            vp_source_admit_container(bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count, 0, &container, &usable)
        }
        XCTAssertEqual(admission, 0,
            "Native FMP4 source admission status=\(admission) kind=\(container); " +
            "ordinary-init-prefix=\(sample.header.prefix(4_096).base64EncodedString()) " +
            "ordinary-media-prefix=\(sample.media.prefix(2_048).base64EncodedString())")
        guard admission == 0 else { throw HLSSourceError.unsupportedMedia }
        try await runManagedMedia(header: sample.header, media: sample.media, duration: sample.duration, expectedSuffix: "mp4")
    }

    private func runManagedMedia(header: Data?, media: Data, duration: Double, expectedSuffix: String) async throws {
        let map = header == nil ? "" : "#EXT-X-MAP:URI=\"initialization\"\n"
        let playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(duration)))\n\(map)#EXTINF:\(duration),\npart\n#EXT-X-ENDLIST\n"
        var resources: [String: NativeHLSHTTPFixture.Resource] = [
            "/media": .init(data: Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl"),
            "/part": .init(data: media, contentType: header == nil ? "video/mp2t" : "video/mp4")]
        if let header { resources["/initialization"] = .init(data: header, contentType: "video/mp4") }
        let origin = try NativeHLSHTTPFixture(resources: resources, credential: "demux fixture")
        let resolver = URLSessionPlaybackSourceResolver()
        var proxy: HLSProxySession?
        let ioQueue = DispatchQueue(label: "org.vplayer.tests.managed-demux-io")
        let demux = FFmpegDemuxer(timeoutUS: 5_000_000, ioQueue: ioQueue)
        let count = ManagedDemuxCounts()
        var stage = "resolve"
        var failure: (any Error)?
        do {
            let context = try sourceContext(url: origin.url("media"), attributes: ["Authorization": "demux fixture"])
            let sourceCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.sourceRetention)
            let source = try await resolver.resolve(context, reason: .initial)
            let factsCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
            stage = "source-facts"
            let facts = try await HLSCompatibilityProbe().inspect(source, retainingFacts: factsCharge)
            let owner = try XCTUnwrap(context.owner)
            let plan = HLSPlaybackPlan(owner: owner, resolutionGeneration: source.generation, transport: .generated,
                video: .remux, audio: .source, selectedServiceURL: source.responseURL, formatFingerprint: facts.formatFingerprint)
            let owned = HLSOwnedSourcePlan(source: source, facts: facts, plan: plan, resolver: resolver,
                sourceCharge: sourceCharge, factsCharge: factsCharge)
            stage = "proxy-start"
            let live = try await HLSByteProxy.start(source: source,
                lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver,
                sourceRetention: sourceCharge, manifestAuthority: owned.makeProxyManifestAuthority(), useGeneratedSelectedService: true)
            proxy = live
            stage = "rewritten-manifest"
            let response = try await URLSession.shared.data(from: live.itemURL)
            let rewritten = try XCTUnwrap(HLSManifestGraph.parse(data: response.0, responseURL: live.itemURL).document(for: live.itemURL))
            XCTAssertEqual(rewritten.kind, .media)
            XCTAssertEqual(rewritten.segments.first?.resource.url.pathExtension, expectedSuffix)
            if header != nil { XCTAssertEqual(rewritten.segments.first?.initialization?.url.pathExtension, "mp4") }
            stage = "media-range-readback"
            // The same open-ended Range request used by FFmpeg must preserve
            // every byte before stream selection is allowed to count as coverage.
            let resource = try XCTUnwrap(rewritten.segments.first?.resource.url)
            var request = URLRequest(url: resource)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let readback = try await URLSession.shared.data(for: request)
            XCTAssertEqual((readback.1 as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(readback.0, media)
            guard (readback.1 as? HTTPURLResponse)?.statusCode == 206, readback.0 == media else {
                throw HLSSourceError.incompleteEvidence
            }
            stage = "pinned-demux"
            try demux.start(url: live.itemURL, sink: count.receive)
            let deadline = ContinuousClock.now + .seconds(10)
            while !count.snapshot.terminal, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let result = count.snapshot
            guard result.terminal, result.endOfStream, result.failure == nil, result.videoPackets > 0 else {
                XCTFail("Real FFmpeg HLS demux rejected managed \(expectedSuffix): \(String(describing: result.failure))")
                throw HLSSourceError.incompleteEvidence
            }
            if header == nil {
                XCTAssertGreaterThan(result.audioPackets, 0)
                guard result.audioPackets > 0 else { throw HLSSourceError.incompleteEvidence }
            }
            XCTAssertEqual(origin.deniedCount, 0)
            XCTAssertGreaterThan(origin.authenticatedCount, 2)
            guard origin.deniedCount == 0, origin.authenticatedCount > 2 else { throw HLSSourceError.incompleteEvidence }
            print("MANAGED_HLS_PINNED_DEMUX container=\(expectedSuffix) video=\(result.videoPackets) audio=\(result.audioPackets) eof=true")
        } catch {
            XCTFail("Managed \(expectedSuffix) failed at \(stage): \(error); " +
                "proxy-io=\(String(describing: proxy?.observedIO)) origin-requests=\(origin.requestCount)")
            failure = error
        }
        demux.cancel()
        // The original injected serial I/O queue joins the native run/destroy tail.
        await withCheckedContinuation { continuation in ioQueue.async { continuation.resume() } }
        await resolver.invalidate()
        if let proxy { let joined = await proxy.retire(); XCTAssertTrue(joined) }
        await origin.close()
        if let failure { throw failure }
    }
}

private final class ManagedDemuxCounts: @unchecked Sendable {
    struct Snapshot { var videoPackets = 0, audioPackets = 0; var terminal = false, endOfStream = false; var failure: String? }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    func receive(_ event: DemuxEvent) {
        lock.withLock {
            switch event {
            case let .packet(packet):
                switch packet.codec { case .video: value.videoPackets += 1; case .audio: value.audioPackets += 1 }
            case .endOfStream: value.terminal = true; value.endOfStream = true
            case .cancelled: value.terminal = true
            case let .failure(error): value.failure = String(describing: error); value.terminal = true
            default: break
            }
        }
    }
}

private final class ManagedVideoFragmentCapture: @unchecked Sendable {
    struct Snapshot { let header: Data, media: Data, duration: Double }
    private let lock = NSLock()
    private var writer: FMP4WriterIdentity?
    private var header: Data?, result: Snapshot?
    var snapshot: Snapshot? { lock.withLock { result } }
    func consume(_ object: SealedMediaObject) {
        guard object.publicationEvidence?.format.codec.hasPrefix("avc") == true else { return }
        lock.withLock {
            guard result == nil, object.bytes.count <= 4 * 1_024 * 1_024 else { return }
            if object.kind == .initialization, header == nil {
                header = object.bytes.withUnsafeBytes { Data($0) }; writer = object.writerIdentity
            } else if object.kind == .media, object.writerIdentity == writer, let header,
                      let duration = object.report.duration, duration.isNumeric, duration.seconds > 0 {
                result = .init(header: header, media: object.bytes.withUnsafeBytes { Data($0) }, duration: duration.seconds)
            }
        }
    }
}
