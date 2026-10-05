// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CommonCrypto
import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class HLSCompatibilityProbeTests: XCTestCase {
    func testOrdinaryProgressiveTSHasActualRateSPSColorAndLCConfiguration() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "progressive-h264-aac", withExtension: "ts"))
        let facts = try await FFmpegHLSContainerInspector().inspect(data: Data(contentsOf: url), url: url, deadline: HLSMonotonicClock.deadline(seconds: 10))
        XCTAssertEqual(facts.container, .mpegTS)
        XCTAssertEqual(facts.video?.width, 1280); XCTAssertEqual(facts.video?.height, 720)
        XCTAssertEqual(facts.video?.scan, .progressive); XCTAssertEqual(facts.video?.parameterSetsValidated, true)
        XCTAssertEqual(facts.video?.frameRate, MediaRational(num: 25, den: 1))
        XCTAssertEqual(facts.video?.videoRange, .sdr); XCTAssertEqual(facts.video?.colorPrimaries, .bt709)
        XCTAssertEqual(facts.audio.first?.decoderConfiguration, Data([0x11, 0x90]))
        XCTAssertEqual(facts.audio.first?.priming, .notSignaledPreserveTimestamps)
        XCTAssertEqual(facts.audio.first?.formatValidated, true)
    }
    func testFMP4FactsComeFromRealInitAndMedia() async throws {
        let input = try sourceFixture("progressive-init.mp4") + sourceFixture("progressive-0.m4s")
        let facts = try await FFmpegHLSContainerInspector().inspect(data: input, url: URL(string: "https://example.test/media")!, deadline: HLSMonotonicClock.deadline(seconds: 10))
        XCTAssertEqual(facts.container, .fragmentedMP4)
        XCTAssertEqual(facts.video?.scan, .progressive); XCTAssertEqual(facts.video?.parameterSetsValidated, true)
        XCTAssertEqual(facts.video?.configurationFingerprint.count, 32)
        XCTAssertEqual(facts.audio.first?.formatValidated, true)
    }
    func testLargeOrdinaryAccessUnitAdmissionAndExplicitLocalLimit() async throws {
        for name in ["large-au.ts", "large-au.mp4", "large-au-limit.mp4"] {
            let bytes = try sourceFixture(name)
            XCTAssertLessThan(bytes.count, HLSCompatibilityProbe.maximumBytes)
            let facts = try await FFmpegHLSContainerInspector().inspect(data: bytes, url: URL(string: "https://example.test/media")!, deadline: HLSMonotonicClock.deadline(seconds: 10))
            XCTAssertEqual(facts.video?.width, 3840); XCTAssertEqual(facts.video?.height, 2160)
            XCTAssertEqual(facts.video?.parameterSetsValidated, true)
        }
        do {
            _ = try await FFmpegHLSContainerInspector().inspect(data: sourceFixture("large-au-over-limit.mp4"), url: URL(string: "https://example.test/media")!, deadline: HLSMonotonicClock.deadline(seconds: 10))
            XCTFail("sample larger than the explicit local AU bound was admitted")
        } catch { XCTAssertEqual(error as? HLSSourceError, .unsupportedMedia) }
    }
    func testExplicitPrefixIsNotACompleteFiniteTSFile() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "task22-progressive-h264-aac-16s", withExtension: "ts"))
        let whole = try Data(contentsOf: url)
        XCTAssertGreaterThan(whole.count, 1_048_576)
        let prefix = Data(whole.prefix(1_048_576))
        let inspector = FFmpegHLSContainerInspector()
        let facts = try await inspector.inspect(data: prefix, url: url, deadline: HLSMonotonicClock.deadline(seconds: 10), completeness: .prefix)
        XCTAssertEqual(facts.video?.scan, .progressive); XCTAssertEqual(facts.audio.first?.formatValidated, true)
        do { _ = try await inspector.inspect(data: prefix, url: url, deadline: HLSMonotonicClock.deadline(seconds: 10)); XCTFail("finite truncation was relabeled a prefix") }
        catch { XCTAssertEqual(error as? HLSSourceError, .unsupportedMedia) }
    }
    func testLCAndGenuineHEInitialWindowCannotShareFabricatedLCFacts() throws {
        for name in ["aac-lc.adts", "aac-implicit-sbr-signaling.adts"] {
            let bytes = try sourceFixture(name)
            var offset = 0, count = 0
            while count < 8 && offset + 7 <= bytes.count {
                let length = (Int(bytes[offset+3] & 3) << 11) | (Int(bytes[offset+4]) << 3) | Int(bytes[offset+5] >> 5)
                guard length >= 7, length <= bytes.count-offset, offset+length <= 65_536 else { throw HLSSourceError.incompleteEvidence }
                offset += length; count += 1
            }
            XCTAssertEqual(count, 8)
            var format = VPFFSourceAACFormat()
            let prefix = Data(bytes.prefix(offset))
            let result = prefix.withUnsafeBytes { p in
                vp_ffmpeg_inspect_adts_format(p.bindMemory(to: UInt8.self).baseAddress, p.count, 500_000, { _ in 0 }, nil, &format)
            }
            if name == "aac-lc.adts" {
                XCTAssertEqual(result, 0); XCTAssertEqual(format.profile, 1); XCTAssertEqual(format.sample_rate, 48_000)
            } else {
                // The preparation job separately proves genuine HE decoding and
                // expanded rate in these exact first eight complete AUs.
                let rates: [Int32] = [96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350]
                let index = Int((bytes[2] >> 2) & 15)
                guard index < rates.count else { return XCTFail("invalid ordinary HE fixture frequency") }
                XCTAssertFalse(result == 0 && format.profile == 1 && format.sample_rate == rates[index])
            }
        }
    }
    private func sourceFixture(_ name: String) throws -> Data {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SourcePlanning", withExtension: nil))
        return try Data(contentsOf: root.appendingPathComponent(name))
    }
}

private struct SourceFactInspector: HLSContainerInspecting {
    func inspect(data: Data, url: URL, deadline: UInt64) async throws -> HLSMediaFacts {
        HLSMediaFacts(url: url, container: .mpegTS, video: nil, audio: [HLSSourceAudioFacts(codec: .aac, profile: 1,
            sampleRate: 48_000, channelCount: 2, channelMask: 3, decoderConfiguration: Data([0x11,0x90]),
            priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true)], hasUnsupportedTracks: false)
    }
}

extension HLSCompatibilityProbeTests {
    func testVideoColorProjectionPreservesExplicitMatrixZero() throws {
        let identity = HLSSourceVideoProjection.colorCode(0)
        XCTAssertEqual(try HLSSourceVideoProjection.reconcile(parameterSet: Int32(0), container: identity, parser: identity), 0)
        XCTAssertThrowsError(try HLSSourceVideoProjection.reconcileColor(parameterSet: DemuxColorMatrix.bt709,
            container: 0, parser: 1)) { error in
            guard case HLSSourceVideoProjection.Failure.contradictory = error else { return XCTFail("lost explicit container identity matrix") }
        }
        XCTAssertThrowsError(try HLSSourceVideoProjection.reconcileColor(parameterSet: DemuxColorMatrix.bt709,
            container: 1, parser: 0)) { error in
            guard case HLSSourceVideoProjection.Failure.contradictory = error else { return XCTFail("lost explicit parser identity matrix") }
        }
        // The existing supported matrix model does not include identity. Agreement
        // preserves that declaration, but cannot validate it as a supported format.
        XCTAssertThrowsError(try HLSSourceVideoProjection.reconcileColor(parameterSet: Optional<DemuxColorMatrix>.none,
            container: 0, parser: 0)) { error in
            guard case HLSSourceVideoProjection.Failure.unsupportedColor = error else { return XCTFail("identity matrix gained supported evidence") }
        }
    }

    func testVideoColorProjectionKeepsUnobservedParserAndUnspecifiedUnknown() throws {
        // C emits the codec's unspecified sentinel (2) when no parser ran.
        XCTAssertEqual(try HLSSourceVideoProjection.reconcileColor(parameterSet: DemuxColorPrimaries.bt709, container: 1, parser: 2), .bt709)
        XCTAssertEqual(try HLSSourceVideoProjection.reconcileColor(parameterSet: DemuxColorTransfer.bt709, container: 1, parser: 2), .bt709)
        XCTAssertEqual(try HLSSourceVideoProjection.reconcileColor(parameterSet: DemuxColorMatrix.bt709, container: 1, parser: 2), .bt709)
        XCTAssertNil(try HLSSourceVideoProjection.reconcileColor(parameterSet: Optional<DemuxColorPrimaries>.none, container: 2, parser: 2))
        XCTAssertNil(try HLSSourceVideoProjection.reconcileColor(parameterSet: Optional<DemuxColorTransfer>.none, container: 2, parser: 2))
        XCTAssertNil(try HLSSourceVideoProjection.reconcileColor(parameterSet: Optional<DemuxColorMatrix>.none, container: 2, parser: 2))
    }

    func testVideoColorProjectionDoesNotDropUnsupportedPresentCodes() {
        for code in [Int32(0), 3, 255, 65_536, -1] {
            XCTAssertEqual(HLSSourceVideoProjection.colorCode(code), code)
            XCTAssertThrowsError(try HLSSourceVideoProjection.reconcileColor(parameterSet: DemuxColorPrimaries.bt709, container: code, parser: 2)) { error in
                guard case HLSSourceVideoProjection.Failure.contradictory = error else { return XCTFail("present primaries code disappeared") }
            }
            XCTAssertThrowsError(try HLSSourceVideoProjection.reconcileColor(parameterSet: DemuxColorTransfer.bt709, container: code, parser: 2)) { error in
                guard case HLSSourceVideoProjection.Failure.contradictory = error else { return XCTFail("present transfer code disappeared") }
            }
            XCTAssertThrowsError(try HLSSourceVideoProjection.reconcileColor(parameterSet: Optional<DemuxColorPrimaries>.none, container: code, parser: 2)) { error in
                guard case HLSSourceVideoProjection.Failure.unsupportedColor = error else { return XCTFail("unsupported primaries gained supported evidence") }
            }
            XCTAssertThrowsError(try HLSSourceVideoProjection.reconcileColor(parameterSet: Optional<DemuxColorTransfer>.none, container: code, parser: 2)) { error in
                guard case HLSSourceVideoProjection.Failure.unsupportedColor = error else { return XCTFail("unsupported transfer gained supported evidence") }
            }
        }
    }
}

extension HLSCompatibilityProbeTests {
    func testPaidRealInitializationInspectionProducesOnlyBoundPlaintextIdentity() async throws {
        for fragmented in [false, true] {
            let item = try initializationCase(fragmented: fragmented, ranged: !fragmented)
            let charge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
            let facts = try await HLSCompatibilityProbe(transport: item.transport).inspect(item.source, retainingFacts: charge)
            let receipts = facts.initializationReceipts
            XCTAssertEqual(receipts.count, 1)
            XCTAssertLessThanOrEqual(receipts.count, HLSInitializationReceipts.maximumCount)
            XCTAssertEqual(receipts.plaintextByteCount(source: item.source, originalMediaURL: item.mediaURL,
                originalResource: item.map, originalEncryption: .none), item.header.count)
            XCTAssertTrue(receipts.matches(plaintext: item.header, source: item.source, originalMediaURL: item.mediaURL,
                originalResource: item.map, originalEncryption: .none, replacementRange: item.map.range, replacementEncryption: .none))
            let legacyFacts = HLSCompatibilityFacts(source: item.source, media: facts.media, complete: facts.complete, inspectedBytes: facts.inspectedBytes)
            XCTAssertEqual(legacyFacts.formatFingerprint, facts.formatFingerprint)
            XCTAssertEqual(legacyFacts.initializationReceipts.count, 0)
            XCTAssertFalse(String(reflecting: receipts).contains("secret"))
            XCTAssertEqual(facts.media.first?.container, fragmented ? .fragmentedMP4 : .mpegTS)
        }
    }

    func testInitializationReceiptRejectsOwnerGenerationRoleDeclarationAndByteMismatch() async throws {
        let item = try initializationCase(fragmented: false, ranged: true, laterMap: true)
        let charge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
        let receipts = try await HLSCompatibilityProbe(transport: item.transport).inspect(item.source, retainingFacts: charge).initializationReceipts
        func matches(_ bytes: Data, source: ResolvedPlaybackSource? = nil, mediaURL: URL? = nil,
                     resource: HLSManifestGraph.Resource? = nil, range: HLSByteRange? = nil,
                     encryption: HLSManifestGraph.Encryption = .none) -> Bool {
            receipts.matches(plaintext: bytes, source: source ?? item.source, originalMediaURL: mediaURL ?? item.mediaURL,
                originalResource: resource ?? item.map, originalEncryption: .none,
                replacementRange: range ?? item.map.range, replacementEncryption: encryption)
        }
        let otherOwner = ResolvedPlaybackSource(context: try sourceContext(), responseURL: item.source.responseURL,
            generation: item.source.generation, topology: item.source.topology)
        let nextGeneration = ResolvedPlaybackSource(context: item.source.context, responseURL: item.source.responseURL,
            generation: item.source.generation + 1, topology: item.source.topology)
        XCTAssertFalse(matches(item.header, source: otherOwner))
        XCTAssertFalse(matches(item.header, source: nextGeneration))
        XCTAssertFalse(matches(item.header, mediaURL: URL(string: "https://example.test/another-role")!))
        XCTAssertFalse(matches(item.header, resource: .init(url: URL(string: "https://example.test/later-init?sig=secret")!, range: nil)))
        XCTAssertFalse(matches(item.header, range: .init(offset: 1, length: Int64(item.header.count))))
        XCTAssertFalse(matches(item.header, range: .init(offset: 0, length: Int64(item.header.count + 1))))
        XCTAssertFalse(matches(item.header, encryption: .aes128(keyURL: URL(string: "https://example.test/key")!, iv: Data(repeating: 0, count: 16))))
        var changed = item.header
        changed[0] ^= 1
        XCTAssertFalse(matches(changed))
        XCTAssertFalse(matches(Data(item.header.dropLast())))
        XCTAssertNil(receipts.plaintextByteCount(source: item.source, originalMediaURL: item.mediaURL,
            originalResource: .init(url: URL(string: "https://example.test/later-init?sig=secret")!, range: nil), originalEncryption: .none))
        let requests = await item.transport.requests
        XCTAssertFalse(requests.contains { $0.url.path == "/later-init" })
    }

    func testLegacyAndInjectedInspectionCannotMintInitializationReceipts() async throws {
        let item = try initializationCase(fragmented: false)
        let probe = HLSCompatibilityProbe(transport: item.transport)
        let legacy = try await probe.inspect(item.source)
        XCTAssertEqual(legacy.initializationReceipts.count, 0)
        let charge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
        let injected = try await HLSCompatibilityProbe(transport: item.transport, inspector: SourceFactInspector())
            .inspect(item.source, retainingFacts: charge)
        XCTAssertEqual(injected.initializationReceipts.count, 0)
        let rawSource = ResolvedPlaybackSource(context: item.source.context, responseURL: item.mediaURL,
            generation: item.source.generation, topology: .media(item.header + item.sample))
        let rawFacts = try await probe.inspect(rawSource, retainingFacts: charge)
        XCTAssertEqual(rawFacts.initializationReceipts.count, 0)
        let insufficient = try HLSApplicationLifetimeCharge(bytes: 1)
        do {
            _ = try await probe.inspect(item.source, retainingFacts: insufficient)
            XCTFail("unpaid receipt metadata was admitted")
        } catch { XCTAssertEqual(error as? HLSSourceError, .capacity) }
    }

    func testInitializationReceiptRetainsOriginalParentRoleDeclarations() async throws {
        let item = try initializationCase(fragmented: false)
        guard case let .hls(mediaGraph) = item.source.topology else { return XCTFail("missing media graph") }
        let masterURL = URL(string: "https://example.test/master?sig=secret")!
        func source(bandwidth: Int) throws -> ResolvedPlaybackSource {
            let master = try HLSManifestGraph.parse(data: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)\n\(item.mediaURL.absoluteString)\n".utf8), responseURL: masterURL)
            let documents = master.documents.merging(mediaGraph.documents) { first, _ in first }
            return ResolvedPlaybackSource(context: item.source.context, responseURL: masterURL, generation: item.source.generation,
                topology: .hls(HLSManifestGraph(rootURL: masterURL, documents: documents, aliases: [:])))
        }
        let original = try source(bandwidth: 1000)
        let charge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
        let facts = try await HLSCompatibilityProbe(transport: item.transport).inspect(original, retainingFacts: charge)
        XCTAssertNotNil(facts.initializationReceipts.plaintextByteCount(source: original, originalMediaURL: item.mediaURL,
            originalResource: item.map, originalEncryption: .none))
        XCTAssertNil(facts.initializationReceipts.plaintextByteCount(source: try source(bandwidth: 2000), originalMediaURL: item.mediaURL,
            originalResource: item.map, originalEncryption: .none))
    }

    func testInitializationReceiptAliasRetainsTheExistingFactsChargeUntilLastRelease() async throws {
        let item = try initializationCase(fragmented: false)
        weak var retained: HLSApplicationLifetimeCharge?
        var alias: HLSInitializationReceipts?
        do {
            let charge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
            retained = charge
            let facts = try await HLSCompatibilityProbe(transport: item.transport).inspect(item.source, retainingFacts: charge)
            alias = facts.initializationReceipts
        }
        XCTAssertNotNil(retained)
        XCTAssertEqual(alias?.count, 1)
        alias = nil
        XCTAssertNil(retained)
    }

    func testEncryptedInitializationReceiptIdentifiesInspectedPlaintextAcrossKeyLocatorRotation() async throws {
        let item = try initializationCase(fragmented: false, encryptedMap: true)
        let charge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
        let facts = try await HLSCompatibilityProbe(transport: item.transport).inspect(item.source, retainingFacts: charge)
        XCTAssertEqual(facts.initializationReceipts.plaintextByteCount(source: item.source, originalMediaURL: item.mediaURL,
            originalResource: item.map, originalEncryption: item.encryption), item.header.count)
        let renewedProtection = HLSManifestGraph.Encryption.aes128(keyURL: URL(string: "https://example.test/new-key?sig=rotated")!,
            iv: Data(repeating: 1, count: 16))
        XCTAssertTrue(facts.initializationReceipts.matches(plaintext: item.header, source: item.source, originalMediaURL: item.mediaURL,
            originalResource: item.map, originalEncryption: item.encryption, replacementRange: nil, replacementEncryption: renewedProtection))
        XCTAssertFalse(facts.initializationReceipts.matches(plaintext: item.header, source: item.source, originalMediaURL: item.mediaURL,
            originalResource: item.map, originalEncryption: item.encryption, replacementRange: nil, replacementEncryption: .none))
        let ciphertext = try encryptInitialization(item.header)
        XCTAssertFalse(facts.initializationReceipts.matches(plaintext: ciphertext, source: item.source, originalMediaURL: item.mediaURL,
            originalResource: item.map, originalEncryption: item.encryption, replacementRange: nil, replacementEncryption: renewedProtection))
    }

    func testInitializationReceiptCardinalityAdmissionPrecedesResourceLoading() async throws {
        let context = try sourceContext()
        let names = (0...HLSInitializationReceipts.maximumCount).map { "media\($0)" }
        let master = try HLSManifestGraph.parse(data: Data(("#EXTM3U\n" + names.map { "#EXT-X-STREAM-INF:BANDWIDTH=1\n\($0)\n" }.joined()).utf8), responseURL: context.entryURL)
        var documents = master.documents
        for name in names {
            let child = URL(string: "https://example.test/\(name)")!
            let media = try HLSManifestGraph.parse(data: Data("#EXTM3U\n#EXT-X-MAP:URI=\"init\"\n#EXTINF:1,\nsegment\n".utf8), responseURL: child)
            documents.merge(media.documents) { old, _ in old }
        }
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1,
            topology: .hls(HLSManifestGraph(rootURL: context.entryURL, documents: documents, aliases: [:])))
        let transport = SourceTestTransport(responses: [:])
        let charge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
        do {
            _ = try await HLSCompatibilityProbe(transport: transport, inspector: SourceFactInspector()).inspect(source, retainingFacts: charge)
            XCTFail("unbounded retained initialization metadata was admitted")
        } catch { XCTAssertEqual(error as? HLSSourceError, .graphLimit) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func initializationCase(fragmented: Bool, ranged: Bool = false, laterMap: Bool = false, encryptedMap: Bool = false) throws ->
        (source: ResolvedPlaybackSource, transport: SourceTestTransport, mediaURL: URL, map: HLSManifestGraph.Resource,
         encryption: HLSManifestGraph.Encryption, header: Data, sample: Data) {
        let header: Data
        let sample: Data
        if fragmented {
            header = try sourceFixture("progressive-init.mp4")
            sample = try sourceFixture("progressive-0.m4s")
        } else {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "progressive-h264-aac", withExtension: "ts"))
            let bytes = try Data(contentsOf: url)
            // The public TS fixture begins with its ordinary SDT/PAT/PMT packets.
            // Partitioning preserves every original byte and all coded timestamps.
            header = Data(bytes.prefix(188 * 3)); sample = Data(bytes.dropFirst(188 * 3))
        }
        let context = try sourceContext(url: URL(string: "https://example.test/media?sig=secret")!)
        let mapURL = URL(string: "https://example.test/init?sig=secret")!
        let segmentURL = URL(string: "https://example.test/segment")!
        let byteRange = ranged ? ",BYTERANGE=\"\(header.count)@0\"" : ""
        let keyURL = URL(string: "https://example.test/key?sig=secret")!
        let keyLine = encryptedMap ? "#EXT-X-KEY:METHOD=AES-128,URI=\"\(keyURL.absoluteString)\",IV=0x00000000000000000000000000000000\n" : ""
        let clearSegment = encryptedMap ? "#EXT-X-KEY:METHOD=NONE\n" : ""
        var text = "#EXTM3U\n\(keyLine)#EXT-X-MAP:URI=\"\(mapURL.absoluteString)\"\(byteRange)\n\(clearSegment)#EXTINF:1,\n\(segmentURL.absoluteString)\n"
        if laterMap { text += "#EXT-X-MAP:URI=\"https://example.test/later-init?sig=secret\"\n#EXTINF:1,\nlater-segment\n" }
        let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: context.entryURL)
        let first = try XCTUnwrap(graph.documents[context.entryURL]?.segments.first)
        let map = try XCTUnwrap(first.initialization)
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 7, topology: .hls(graph))
        let transportedHeader = try encryptedMap ? encryptInitialization(header) : header
        let transport = SourceTestTransport(responses: [mapURL: HLSResourceResponse(responseURL: mapURL, data: transportedHeader),
            keyURL: HLSResourceResponse(responseURL: keyURL, data: Data(0..<16)),
            segmentURL: HLSResourceResponse(responseURL: segmentURL, data: sample)])
        return (source, transport, context.entryURL, map, first.initializationEncryption, header, sample)
    }

    private func encryptInitialization(_ plaintext: Data) throws -> Data {
        // Ordinary in-memory test input only; no generated/persisted fixture or
        // production encryption/minting interface is added.
        let key = Data(0..<16), iv = Data(repeating: 0, count: 16)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { target in
            plaintext.withUnsafeBytes { input in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, input.count,
                    target.baseAddress, target.count, &written)
            } } }
        }
        guard status == kCCSuccess else { throw HLSSourceError.unsupportedMedia }
        output.removeSubrange(written..<output.count)
        return output
    }
}
