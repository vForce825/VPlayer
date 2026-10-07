// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

@MainActor
final class HLSPlaybackPlanTests: XCTestCase {
    func testOrdinaryMasterKeepsNativeAndScopedHeadersChooseProxy() throws {
        for managed in [false, true] {
            let source = try source(master: true, managed: managed, declaration: "CODECS=\"avc1.640028,mp4a.40.2\",RESOLUTION=1920x1080,FRAME-RATE=30.000,VIDEO-RANGE=SDR")
            let plan = try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source), capabilities: capabilities())
            XCTAssertEqual(plan.transport, managed ? .proxy : .native)
            XCTAssertEqual(plan.video, .source); XCTAssertEqual(plan.audio, .source)
            XCTAssertNil(plan.selectedServiceURL)
        }
    }

    func testRec601KeepsNativeOrProxyWithoutEnteringGeneratedColorPipeline() throws {
        for primaries: UInt16 in [5, 6] {
            for transfer: UInt16 in [1, 6] {
                for matrix: UInt16 in [5, 6] {
                    let color = (try XCTUnwrap(DemuxColorPrimaries(rawValue: primaries)),
                        try XCTUnwrap(DemuxColorTransfer(rawValue: transfer)),
                        try XCTUnwrap(DemuxColorMatrix(rawValue: matrix)))
                    let format = video(color: color)
                    for managed in [false, true] {
                        let source = try source(master: true, managed: managed)
                        let plan = try HLSPlaybackPlanner.makePlan(source: source,
                            facts: facts(source, video: format), capabilities: capabilities())
                        XCTAssertEqual(plan.transport, managed ? .proxy : .native)
                        XCTAssertEqual(plan.video, .source)
                    }
                    let raw = try source(raw: true)
                    for scan in [HLSScanEvidence.progressive, .interlaced, .unknown, .contradictory] {
                        XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: raw,
                            facts: facts(raw, video: video(scan: scan, color: color)), capabilities: capabilities()))
                    }
                    let original = try source(master: true)
                    for scan in [HLSScanEvidence.interlaced, .unknown, .contradictory] {
                        XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: original,
                            facts: facts(original, video: video(scan: scan, color: color)), capabilities: capabilities()))
                    }
                }
            }
        }
    }

    func testRec601NativeColorDoesNotWidenMixedGamutsOrHDR() throws {
        for color: (DemuxColorPrimaries, DemuxColorTransfer, DemuxColorMatrix) in [
            (.bt470BG, .bt709, .bt709), (.bt709, .bt709, .smpte170M),
            (.smpte170M, .pq, .smpte170M), (.bt470BG, .hlg, .bt470BG),
            (.bt470BG, .bt2020, .bt470BG), (.smpte170M, .bt2020_12, .smpte170M)
        ] {
            let source = try source(master: true)
            XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source,
                facts: facts(source, video: video(color: color)), capabilities: capabilities()))
        }
    }

    func testDeclaredCodecAndScalarContradictionsNeverCollapseMaster() throws {
        let declarations = ["CODECS=\"avc1.4d4028,mp4a.40.2\"", "CODECS=\"avc1.640029,mp4a.40.2\"",
            "CODECS=\"avc1.640028,mp4a.40.5\"", "CODECS=\"avc1.640028,unknown\"", "CODECS=\"avc1.640028\"",
            "RESOLUTION=1280x720", "FRAME-RATE=24.000", "FRAME-RATE=120.000", "VIDEO-RANGE=HLG"]
        for declaration in declarations {
            let source = try source(master: true, declaration: declaration)
            XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source), capabilities: capabilities()), declaration)
        }
    }

    func testHEVCFullDeclarationIncludesSampleEntryTierCompatibilityAndConstraints() throws {
        let good = "hvc1.2.4.L120.B0"
        let format = video(codec: .hevc)
        XCTAssertEqual(HLSDeclaredCodec(good)?.matches(video: format), true)
        for bad in ["hvc1.1.4.L120.B0", "hvc1.2.2.L120.B0", "hvc1.2.4.H120.B0", "hvc1.2.4.L123.B0",
                    "hvc1.2.4.L120.B1", "hev1.2.4.L120.B0", "hvc1.A2.4.L120.B0", "hvc1"] {
            XCTAssertNotEqual(HLSDeclaredCodec(bad)?.matches(video: format), true, bad)
        }
        let source = try source(master: true, declaration: "CODECS=\"\(good),mp4a.40.2\"")
        XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, video: format, container: .fragmentedMP4), capabilities: capabilities()).transport, .native)
        for container in [HLSMediaFacts.Container.mpegTS, .isoBMFF] {
            XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, video: format, container: container), capabilities: capabilities()))
        }
    }

    func testUnknownScanNeverBecomesRemuxAndInterlaceDecisionIsIndependentOfAudio() throws {
        let source = try source(raw: true)
        for scan in [HLSScanEvidence.unknown, .contradictory] {
            XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, video: video(scan: scan)), capabilities: capabilities()))
        }
        let remux = try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source), capabilities: capabilities())
        XCTAssertEqual(remux.transport, .generated); XCTAssertEqual(remux.video, .remux); XCTAssertEqual(remux.audio, .passthrough(.aac))
        let interlaced = try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, video: video(scan: .interlaced)), capabilities: capabilities())
        XCTAssertEqual(interlaced.video, .deinterlaceAndEncode); XCTAssertEqual(interlaced.audio, .passthrough(.aac))
        let unknownAudio = HLSSourceAudioFacts(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2)
        let converted = try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, audio: unknownAudio), capabilities: capabilities())
        XCTAssertEqual(converted.video, .remux); XCTAssertEqual(converted.audio, .compatibleAAC)
    }

    func testNativeDolbyProposalIsOwnerScopedAndIndependentOfGeneratedWriterEvidence() throws {
        let source = try source(master: true, declaration: "CODECS=\"avc1.640028,ac-3\"")
        let owner = try XCTUnwrap(source.context.owner), track = dolby()
        let proposal = HLSNativeAudioAdmissionCandidate(owner: owner, codec: .ac3, profile: 8, sampleRate: 48_000,
            channelCount: 6, channelMask: 0x3F, decoderConfiguration: Data(), outputRouteIdentifier: "owned-route")
        let admitted = capabilities(native: [proposal])
        XCTAssertTrue(admitted.verifiedCompressedAudioConfigurations.isEmpty)
        XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, audio: track), capabilities: admitted).transport, .native)
        XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, audio: track), capabilities: capabilities()))
        let other = try sourceContext()
        XCTAssertFalse(proposal.matches(track, owner: try XCTUnwrap(other.owner)))
    }

    func testGeneratedDolbySkipsMissingAACSiblingInEitherCapabilityOrder() throws {
        let source = try source(raw: true), track = dolby()
        func configuration(_ requiresSibling: Bool) -> HLSVerifiedCompressedAudioConfiguration {
            .init(codec: .ac3, profile: 8, sampleRate: 48_000, channelCount: 6, channelMask: 0x3F,
                decoderConfiguration: Data(), outputRouteIdentifier: requiresSibling ? "needs-sibling" : "usable", requiresAACCompatibilityRendition: requiresSibling)
        }
        for values in [[configuration(true), configuration(false)], [configuration(false), configuration(true)]] {
            let plan = try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, audio: track), capabilities: capabilities(verified: values))
            XCTAssertEqual(plan.audio, .passthrough(.ac3)); XCTAssertEqual(plan.compressedAudioConfiguration?.outputRouteIdentifier, "usable")
        }
        let fallback = try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, audio: track), capabilities: capabilities(verified: [configuration(true)]))
        XCTAssertEqual(fallback.audio, .compatibleAAC); XCTAssertNil(fallback.compressedAudioConfiguration)
        let candidate = HLSCompressedAudioAdmissionCandidate(codec: .ac3, profile: 8, sampleRate: 48_000, channelCount: 6,
            channelMask: 0x3F, decoderConfiguration: Data(), outputRouteIdentifier: "trial", requiresAACCompatibilityRendition: false)
        let trial = try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, audio: track), capabilities: capabilities(candidates: [candidate]))
        XCTAssertEqual(trial.audio, .passthrough(.ac3)); XCTAssertNil(trial.compressedAudioConfiguration)
        XCTAssertEqual(trial.compressedAudioAdmissionCandidate, candidate)
    }

    func testAudioOnlyGeneratedServiceAndStaleFacts() throws {
        let source = try source(raw: true)
        let facts = HLSCompatibilityFacts(source: source, media: [.init(url: source.responseURL, container: .mpegTS, video: nil,
            audio: [aac()], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 100)
        let plan = try HLSPlaybackPlanner.makePlan(source: source, facts: facts, capabilities: capabilities())
        XCTAssertEqual(plan.transport, .generated); XCTAssertEqual(plan.video, .source); XCTAssertEqual(plan.audio, .passthrough(.aac))
        let next = ResolvedPlaybackSource(context: source.context, responseURL: source.responseURL, generation: source.generation + 1, topology: source.topology)
        XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: next, facts: facts, capabilities: capabilities()))
    }

    func testEveryAlternateAudioFormatIsRequiredByItsParentDeclaration() throws {
        let context = try sourceContext()
        let videoURL = URL(string: "https://example.test/video")!, audioURL = URL(string: "https://example.test/audio")!
        func graph(_ codecs: String) throws -> HLSManifestGraph {
            let root = try HLSManifestGraph.parse(data: Data(("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"English\",URI=\"audio\",CHANNELS=\"2\"\n" +
                "#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"\(codecs)\",AUDIO=\"audio\"\nvideo\n").utf8), responseURL: context.entryURL)
            var documents = root.documents
            for url in [videoURL, audioURL] {
                documents.merge(try HLSManifestGraph.parse(data: Data("#EXTM3U\n#EXTINF:1,\nsegment\n".utf8), responseURL: url).documents) { old, _ in old }
            }
            return .init(rootURL: context.entryURL, documents: documents, aliases: [:])
        }
        for completeDeclaration in [false, true] {
            let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1,
                topology: .hls(try graph(completeDeclaration ? "avc1.640028,mp4a.40.2" : "avc1.640028")))
            let media: [HLSMediaFacts] = [.init(url: videoURL, container: .mpegTS, video: video(), audio: [], hasUnsupportedTracks: false),
                .init(url: audioURL, container: .mpegTS, video: nil, audio: [aac()], hasUnsupportedTracks: false)]
            let facts = HLSCompatibilityFacts(source: source, media: media, complete: true, inspectedBytes: 100)
            if completeDeclaration {
                XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: source, facts: facts, capabilities: capabilities()).transport, .native)
            } else { XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: facts, capabilities: capabilities())) }
            let missing = HLSCompatibilityFacts(source: source, media: [media[0]], complete: true, inspectedBytes: 100)
            XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: missing, capabilities: capabilities()))
        }
    }

    func testBroadCodecProfileCapabilityCannotFillUnknownVideoScalars() throws {
        let source = try source(master: true)
        let unknownFormat = HLSVideoFacts(codec: .h264, profile: 100, scan: .progressive, parameterSetsValidated: true)
        XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source, video: unknownFormat), capabilities: capabilities()))
        let broad = HLSOutputCapabilities(videoProfiles: [.h264: [100]], nativeAudioCodecs: [.aac], supportsGenerated: true)
        XCTAssertThrowsError(try HLSPlaybackPlanner.makePlan(source: source, facts: facts(source), capabilities: broad))
    }

    func testProbeMetadataProjectsOnlyConfirmedSourceFacts() throws {
        for raw in [false, true] {
            let source = try source(raw: raw)
            let information = try XCTUnwrap(HLSNativeSourceDependencies.probedMediaInformation(
                source: source, facts: facts(source, video: video(scan: .interlaced))))
            XCTAssertTrue(information.isSourceProbe)
            XCTAssertEqual(information.width, 1_920)
            XCTAssertEqual(information.height, 1_080)
            XCTAssertEqual(information.scanMode, .interlaced)
            XCTAssertEqual(information.sourceFrameRate, MediaRational(num: 30, den: 1))
            XCTAssertNil(information.outputFrameRate)
            XCTAssertFalse(information.isSmoothMotionEnhanced)
        }
    }

    func testProbeMetadataPreservesUnknownScanAndRate() throws {
        let source = try source(raw: true)
        let video = HLSVideoFacts(codec: .h264, profile: 100, scan: .unknown,
            parameterSetsValidated: true, width: 1_920, height: 1_080)
        let information = try XCTUnwrap(HLSNativeSourceDependencies.probedMediaInformation(
            source: source, facts: facts(source, video: video)))
        XCTAssertEqual(information.width, 1_920)
        XCTAssertNil(information.scanMode)
        XCTAssertNil(information.sourceFrameRate)
        XCTAssertNil(information.outputFrameRate)
    }

    func testProbeMetadataRejectsAmbiguousIncompleteUnvalidatedAndForeignFacts() throws {
        let source = try source(), valid = facts(source)
        let master = try self.source(master: true)
        XCTAssertNil(HLSNativeSourceDependencies.probedMediaInformation(source: master, facts: facts(master)),
            "Even a single declared master variant has no selected-output authority")
        let foreign = try self.source()
        XCTAssertNil(HLSNativeSourceDependencies.probedMediaInformation(source: source, facts: facts(foreign)))
        let successor = ResolvedPlaybackSource(context: source.context, responseURL: source.responseURL,
            generation: source.generation + 1, topology: source.topology)
        XCTAssertNil(HLSNativeSourceDependencies.probedMediaInformation(source: successor, facts: valid))
        for invalid in [
            HLSCompatibilityFacts(source: source, media: valid.media, complete: false, inspectedBytes: 100),
            HLSCompatibilityFacts(source: source, media: valid.media + valid.media, complete: true, inspectedBytes: 100),
            HLSCompatibilityFacts(source: source, media: valid.media, complete: true, inspectedBytes: 0),
            HLSCompatibilityFacts(source: source, media: [.init(url: URL(string: "https://other.invalid/media")!,
                container: .mpegTS, video: video(), audio: [], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 100),
            HLSCompatibilityFacts(source: source, media: [.init(url: source.responseURL,
                container: .mpegTS, video: video(), audio: [], hasUnsupportedTracks: true)], complete: true, inspectedBytes: 100),
            facts(source, video: .init(codec: .h264, profile: 100, scan: .contradictory,
                parameterSetsValidated: false, width: 1_920, height: 1_080))
        ] {
            XCTAssertNil(HLSNativeSourceDependencies.probedMediaInformation(source: source, facts: invalid))
        }
    }

    func testProbeMetadataStillFitsExistingFixedEventPayload() {
        XCTAssertLessThanOrEqual(MemoryLayout<PlaybackPipelineEventStorage.MediaPayload>.stride,
            PlaybackPipelineEventStorage.payloadStride)
        PlaybackPipelineEventStorage.validateLayout()
    }

    private func source(master: Bool = false, raw: Bool = false, managed: Bool = false, declaration: String = "") throws -> ResolvedPlaybackSource {
        let context = try sourceContext(attributes: managed ? ["User-Agent": "fixture"] : [:])
        if raw { return .init(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data([0x47]))) }
        let child = URL(string: "https://example.test/media")!
        let media = try HLSManifestGraph.parse(data: Data("#EXTM3U\n#EXTINF:1,\nsegment\n".utf8), responseURL: master ? child : context.entryURL)
        if !master { return .init(context: context, responseURL: context.entryURL, generation: 1, topology: .hls(media)) }
        let suffix = declaration.isEmpty ? "" : "," + declaration
        let root = try HLSManifestGraph.parse(data: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\(suffix)\n\(child.absoluteString)\n".utf8), responseURL: context.entryURL)
        return .init(context: context, responseURL: context.entryURL, generation: 1,
            topology: .hls(.init(rootURL: context.entryURL, documents: root.documents.merging(media.documents) { old, _ in old }, aliases: [:])))
    }
    private func facts(_ source: ResolvedPlaybackSource, video: HLSVideoFacts? = nil, audio: HLSSourceAudioFacts? = nil,
                       container: HLSMediaFacts.Container = .mpegTS) -> HLSCompatibilityFacts {
        let urls: [URL]
        if case let .hls(graph) = source.topology { urls = graph.orderedDocuments.filter { $0.kind == .media }.map(\.responseURL) }
        else { urls = [source.responseURL] }
        return .init(source: source, media: urls.map { .init(url: $0, container: container, video: video ?? self.video(),
            audio: [audio ?? aac()], hasUnsupportedTracks: false) }, complete: true, inspectedBytes: 100)
    }
    private func video(codec: VideoCodec = .h264, scan: HLSScanEvidence = .progressive,
                       color: (DemuxColorPrimaries, DemuxColorTransfer, DemuxColorMatrix) = (.bt709, .bt709, .bt709)) -> HLSVideoFacts {
        .init(codec: codec, profile: codec == .h264 ? 100 : 2, scan: scan, parameterSetsValidated: true,
            configurationFingerprint: Data(repeating: 1, count: 32), width: 1920, height: 1080, chromaFormat: 1,
            bitDepth: codec == .h264 ? 8 : 10, level: codec == .h264 ? 40 : 120, compatibilityFlags: codec == .h264 ? 0 : 0x20000000,
            constraintIndicatorFlags: codec == .h264 ? nil : 0xB00000000000, tier: .main, frameRate: MediaRational(num: 30, den: 1),
            videoRange: .sdr, colorPrimaries: color.0, colorTransfer: color.1, colorMatrix: color.2, sampleEntry: codec == .h264 ? nil : "hvc1")
    }
    private func aac() -> HLSSourceAudioFacts { .init(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2, channelMask: 3,
        decoderConfiguration: Data([0x11,0x90]), priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true) }
    private func dolby() -> HLSSourceAudioFacts { .init(codec: .ac3, profile: 8, sampleRate: 48_000, channelCount: 6, channelMask: 0x3F,
        priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true) }
    private func capabilities(native: [HLSNativeAudioAdmissionCandidate] = [], verified: [HLSVerifiedCompressedAudioConfiguration] = [],
                              candidates: [HLSCompressedAudioAdmissionCandidate] = []) -> HLSOutputCapabilities {
        .init(videoProfiles: [.h264: [100], .hevc: [2]], videoFormats: [VideoCodec.h264, .hevc].map {
            .init(codec: $0, profiles: $0 == .h264 ? [100] : [2], maximumLevel: $0 == .h264 ? 42 : 123,
                maximumWidth: 1920, maximumHeight: 1080, maximumFrameRate: MediaRational(num: 60, den: 1)!,
                bitDepths: [8,10], chromaFormats: [1], tiers: [.main], videoRanges: [.sdr]) },
            nativeAudioCodecs: [.aac,.ac3,.eac3], nativeAudioAdmissionCandidates: native, compressedAudioCodecs: [.aac,.ac3,.eac3],
            verifiedCompressedAudioConfigurations: verified, compressedAudioAdmissionCandidates: candidates,
            supportsWebVTT: true, supportsGenerated: true)
    }
}
