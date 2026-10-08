// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import XCTest
@testable import VPlayerPlayback

final class NativeHLSCapabilitiesTests: XCTestCase {
    func testExactOwnedNativeDolbyCandidatesRemainIndependentOfGeneratedWriterProof() throws {
        for codec in [VPlayerPlayback.AudioCodec.ac3, .eac3] {
            let value = try facts(codec: codec)
            let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: evidence())
            XCTAssertTrue(result.nativeAudioCodecs.contains(codec))
            let native = try XCTUnwrap(result.nativeAudioAdmissionCandidates.first)
            XCTAssertTrue(native.matches(try XCTUnwrap(value.media.first?.audio.first), owner: try XCTUnwrap(value.owner)))
            XCTAssertTrue(result.verifiedCompressedAudioConfigurations.isEmpty, "Public system queries do not mint emitted writer proof")
            XCTAssertEqual(result.compressedAudioAdmissionCandidates.count, 1, "Generated writer trial remains a distinct candidate")
            let other = PlaybackSourceOwner(backendIdentity: try XCTUnwrap(value.owner).backendIdentity,
                prepareNonce: 2, outputLifecycleNonce: 2)
            XCTAssertFalse(native.matches(try XCTUnwrap(value.media.first?.audio.first), owner: other))
        }
    }
    func testWrongRouteMissingMIMEAndUnknownDolbyProfileCannotGrantNativeTrial() throws {
        for codec in [VPlayerPlayback.AudioCodec.ac3, .eac3] {
            let value = try facts(codec: codec)
            for ports in [PlaybackRoutePorts.hdmi, [.airPlay, .bluetooth]] {
                let result = NativeHLSCapabilities.make(facts: value, route: route(ports), evidence: evidence())
                XCTAssertTrue(result.nativeAudioAdmissionCandidates.isEmpty)
                XCTAssertTrue(result.compressedAudioAdmissionCandidates.isEmpty)
            }
            XCTAssertTrue(NativeHLSCapabilities.make(facts: value, route: route(.airPlay),
                evidence: evidence(playable: false)).nativeAudioCodecs.isEmpty)
            XCTAssertTrue(NativeHLSCapabilities.make(facts: try facts(codec: codec, profile: -1), route: route(.airPlay),
                evidence: evidence()).nativeAudioAdmissionCandidates.isEmpty)
        }
    }
    func testDocumentedHEVCEnvelopeRequiresActualHDRAndExactFormatEvidence() throws {
        let hdr = video(range: .hlg, rate: 50)
        let value = try facts(codec: .aac, video: hdr)
        XCTAssertEqual(NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: evidence()).videoFormats.count, 1)
        XCTAssertTrue(NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: evidence(hdr: false)).videoFormats.isEmpty)
        XCTAssertTrue(NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: evidence(model: "AppleTV6,2")).videoFormats.isEmpty,
            "First generation envelope does not admit 50fps HDR")
        XCTAssertTrue(NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: evidence(model: "simulator")).videoFormats.isEmpty)
        XCTAssertTrue(NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: evidence(playable: false)).videoFormats.isEmpty)
        XCTAssertTrue(NativeHLSCapabilities.make(facts: try facts(codec: .aac, video: video(range: nil, rate: nil)),
            route: route(.airPlay), evidence: evidence()).videoFormats.isEmpty)
    }
    func testAACNativeAdmissionRequiresActualLCConfigRateAndSemanticLayout() throws {
        let good = try facts(codec: .aac)
        XCTAssertTrue(NativeHLSCapabilities.make(facts: good, route: route(.airPlay), evidence: evidence()).nativeAudioCodecs.contains(.aac))
        let wrong = try facts(codec: .aac, sampleRate: 44_100)
        XCTAssertFalse(NativeHLSCapabilities.make(facts: wrong, route: route(.airPlay), evidence: evidence()).nativeAudioCodecs.contains(.aac))
        let unknown = try facts(codec: .aac, mask: 0)
        XCTAssertFalse(NativeHLSCapabilities.make(facts: unknown, route: route(.airPlay), evidence: evidence()).nativeAudioCodecs.contains(.aac))
    }
    func testPlaylistContainerAndMediaCodecNamespacesKeepCompatibleTSNativeOrProxy() throws {
        for container in [HLSMediaFacts.Container.mpegTS, .fragmentedMP4] {
            for managed in [false, true] {
                let (source, value) = try mimeSource(managed: managed, container: container)
                let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: mimeEvidence())
                let plan = try HLSPlaybackPlanner.makePlan(source: source, facts: value, capabilities: result)
                XCTAssertEqual(plan.transport, managed ? .proxy : .native)
                XCTAssertEqual(plan.video, .source)
                XCTAssertEqual(plan.audio, .source)
                XCTAssertTrue(result.nativeAudioCodecs.contains(.aac), "44.1kHz LC with matching ASC remains supported")
            }
        }
    }

    func testMediaCodecCombinationDenialCannotBorrowPassingSibling() throws {
        let (source, value) = try mimeSource()
        for denied in ["application/vnd.apple.mpegurl", "video/mp4; codecs=\"avc1.640028,mp4a.40.2\"",
                       "video/mp4; codecs=\"avc1.640028\"", "audio/mp4; codecs=\"mp4a.40.2\""] {
            let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: mimeEvidence(denied: denied))
            XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: source, facts: value, capabilities: result).transport, .generated, denied)
        }
        let original = try XCTUnwrap(value.media.first)
        let sibling = HLSMediaFacts(url: URL(string: "https://example.test/sibling")!, container: .fragmentedMP4,
            video: video(range: .hlg, rate: 50), audio: original.audio, hasUnsupportedTracks: false)
        let mixed = HLSCompatibilityFacts(source: source, media: [original, sibling], complete: true, inspectedBytes: 376)
        let result = NativeHLSCapabilities.make(facts: mixed, route: route(.airPlay),
            evidence: mimeEvidence(denied: "video/mp4; codecs=\"avc1.640028,mp4a.40.2\""))
        XCTAssertTrue(result.videoFormats.isEmpty, "A passing sibling cannot lend its broad envelope to a rejected source codec combination")
        XCTAssertTrue(result.nativeAudioCodecs.isEmpty)
    }

    func testFragmentedMP4CombinedQueryAndHEVCTransportRestrictionRemainRequired() throws {
        let (source, value) = try mimeSource(container: .fragmentedMP4)
        let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay),
            evidence: mimeEvidence(denied: "video/mp4; codecs=\"avc1.640028,mp4a.40.2\""))
        XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: source, facts: value, capabilities: result).transport, .generated)
        let hevcTS = HLSCompatibilityFacts(source: source, media: [.init(url: source.responseURL, container: .mpegTS,
            video: video(range: .hlg, rate: 50), audio: try XCTUnwrap(value.media.first).audio, hasUnsupportedTracks: false)],
            complete: true, inspectedBytes: 188)
        let restricted = NativeHLSCapabilities.make(facts: hevcTS, route: route(.airPlay), evidence: mimeEvidence())
        XCTAssertTrue(restricted.videoFormats.isEmpty)
        XCTAssertTrue(restricted.nativeAudioCodecs.isEmpty)
    }

    func testMediaMIMEGateKeepsUnsupportedContainerTracksAndVideoFactsClosed() throws {
        for container in [HLSMediaFacts.Container.unknown, .isoBMFF, .webVTT] {
            let (_, value) = try mimeSource(container: container)
            let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: mimeEvidence())
            XCTAssertTrue(result.videoFormats.isEmpty)
            XCTAssertTrue(result.nativeAudioCodecs.isEmpty)
        }
        let (source, value) = try mimeSource()
        let original = try XCTUnwrap(value.media.first)
        let unsupported = HLSCompatibilityFacts(source: source, media: [.init(url: original.url, container: .mpegTS,
            video: original.video, audio: original.audio, hasUnsupportedTracks: true)], complete: true, inspectedBytes: 188)
        let result = NativeHLSCapabilities.make(facts: unsupported, route: route(.airPlay), evidence: mimeEvidence())
        XCTAssertTrue(result.videoFormats.isEmpty)
        XCTAssertTrue(result.nativeAudioCodecs.isEmpty)
        for model in ["simulator", "unknown", "AppleTV999,1"] {
            let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: mimeEvidence(model: model))
            XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: source, facts: value, capabilities: result).transport, .generated)
        }
    }

    func testAudioOnlyTSUsesValidatedHLSContractAndGeneratedDolbySurvivesVideoDenial() throws {
        let (source, value) = try mimeSource()
        let audio = try XCTUnwrap(value.media.first?.audio.first)
        let audioOnly = HLSCompatibilityFacts(source: source, media: [.init(url: source.responseURL, container: .mpegTS,
            video: nil, audio: [audio], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 188)
        let admitted = NativeHLSCapabilities.make(facts: audioOnly, route: route(.airPlay), evidence: mimeEvidence())
        XCTAssertTrue(admitted.nativeAudioCodecs.contains(.aac))
        let denied = NativeHLSCapabilities.make(facts: audioOnly, route: route(.airPlay),
            evidence: mimeEvidence(denied: "audio/mp4; codecs=\"mp4a.40.2\""))
        XCTAssertTrue(denied.nativeAudioCodecs.isEmpty)
        for codec in [VPlayerPlayback.AudioCodec.ac3, .eac3] {
            let value = try facts(codec: codec, video: video(range: .hlg, rate: 50))
            let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: mimeEvidence(model: "simulator"))
            XCTAssertTrue(result.videoFormats.isEmpty)
            XCTAssertTrue(result.nativeAudioAdmissionCandidates.isEmpty)
            XCTAssertEqual(result.compressedAudioAdmissionCandidates.count, 1,
                "Generated Dolby trial remains audio-scoped when native video is unavailable")
            XCTAssertTrue(result.compressedAudioCodecs.contains(codec))
        }
    }

    func testStandaloneTSCannotBorrowTheHLSCarriageContract() throws {
        let (playlist, original) = try mimeSource()
        let direct = ResolvedPlaybackSource(context: playlist.context, responseURL: playlist.responseURL,
            generation: playlist.generation, topology: .media(Data([0x47])))
        let value = HLSCompatibilityFacts(source: direct, media: original.media, complete: true, inspectedBytes: 188)
        let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: mimeEvidence())
        XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: direct, facts: value, capabilities: result).transport, .generated)
    }

    func testTransportStreamCorrectionDoesNotAdmitUnverifiedDolbyCombination() throws {
        let (source, original) = try mimeSource()
        for codec in [VPlayerPlayback.AudioCodec.ac3, .eac3] {
            let dolby = try XCTUnwrap(try facts(codec: codec).media.first?.audio.first)
            let value = HLSCompatibilityFacts(source: source, media: [.init(url: source.responseURL, container: .mpegTS,
                video: original.media.first?.video, audio: [dolby], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 188)
            let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: mimeEvidence())
            XCTAssertTrue(result.videoFormats.isEmpty)
            XCTAssertTrue(result.nativeAudioCodecs.isEmpty)
            XCTAssertTrue(result.nativeAudioAdmissionCandidates.isEmpty)
            XCTAssertEqual(result.compressedAudioAdmissionCandidates.count, 1)
        }
    }

    func testMixedFirstGenerationHDRCannotBorrowSDRSiblingEnvelope() throws {
        let (source, original) = try mimeSource()
        let audio = try XCTUnwrap(original.media.first?.audio.first)
        let sdr = HLSVideoFacts(codec: .hevc, profile: 2, scan: .progressive, parameterSetsValidated: true,
            width: 3_840, height: 2_160, chromaFormat: 1, bitDepth: 10, level: 153,
            compatibilityFlags: 0x20000000, constraintIndicatorFlags: 0xB00000000000,
            tier: .main, frameRate: MediaRational(num: 60, den: 1), videoRange: .sdr,
            colorPrimaries: .bt709, colorTransfer: .bt709, colorMatrix: .bt709, sampleEntry: "hvc1")
        let media = [sdr, video(range: .hlg, rate: 50)].enumerated().map { index, video in
            HLSMediaFacts(url: URL(string: "https://example.test/variant-\(index)")!, container: .fragmentedMP4,
                video: video, audio: [audio], hasUnsupportedTracks: false)
        }
        let mixed = HLSCompatibilityFacts(source: source, media: media, complete: true, inspectedBytes: 376)
        let result = NativeHLSCapabilities.make(facts: mixed, route: route(.airPlay), evidence: mimeEvidence(model: "AppleTV6,2"))
        XCTAssertTrue(result.videoFormats.isEmpty)
        XCTAssertTrue(result.nativeAudioCodecs.isEmpty)
    }

    func testCurrentSDKPublicMIMEQueriesKeepHLSAndCodecNamespacesSeparate() throws {
        let (source, value) = try mimeSource()
        let bare = AVURLAsset.isPlayableExtendedMIMEType("application/vnd.apple.mpegurl")
        let mp4 = AVURLAsset.isPlayableExtendedMIMEType("video/mp4; codecs=\"avc1.640028,mp4a.40.2\"")
        let ts = AVURLAsset.isPlayableExtendedMIMEType("video/mp2t; codecs=\"avc1.640028,mp4a.40.2\"")
        let qualifiedPlaylist = AVURLAsset.isPlayableExtendedMIMEType("application/vnd.apple.mpegurl; codecs=\"avc1.640028,mp4a.40.2\"")
        print("NATIVE_HLS_PUBLIC_MIME sdk-runtime=true bare-hls=\(bare) mp4=\(mp4) ts-bmff-codecs=\(ts) playlist-bmff-codecs=\(qualifiedPlaylist)")
        XCTAssertTrue(bare); XCTAssertTrue(mp4)
        // Only the documented model/hardware envelope is injected for simulator
        // coverage. Every MIME answer above and below comes from the real SDK.
        let evidence = NativeHLSPlatformEvidence(model: "AppleTV14,1", hardwareH264: true, hardwareHEVC: true,
            hdrEligible: true, playable: { AVURLAsset.isPlayableExtendedMIMEType($0) })
        let result = NativeHLSCapabilities.make(facts: value, route: route(.airPlay), evidence: evidence)
        XCTAssertEqual(try HLSPlaybackPlanner.makePlan(source: source, facts: value, capabilities: result).transport, .native)
    }

    private func mimeEvidence(denied: String? = nil, model: String = "AppleTV14,1") -> NativeHLSPlatformEvidence {
        .init(model: model, hardwareH264: true, hardwareHEVC: true, hdrEligible: true, playable: { mime in
            if mime == denied { return false }
            return mime == "application/vnd.apple.mpegurl" || mime.hasPrefix("video/mp4; codecs=") ||
                mime.hasPrefix("audio/mp4; codecs=")
        })
    }
    private func mimeSource(managed: Bool = false, container: HLSMediaFacts.Container = .mpegTS) throws
        -> (ResolvedPlaybackSource, HLSCompatibilityFacts) {
        let context = try sourceContext(attributes: managed ? ["Authorization": "Bearer fixture"] : [:])
        let graph = try HLSManifestGraph.parse(data: Data("#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\nsegment.ts\n".utf8), responseURL: context.entryURL)
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .hls(graph))
        let video = HLSVideoFacts(codec: .h264, profile: 100, scan: .progressive, parameterSetsValidated: true,
            configurationFingerprint: Data(repeating: 1, count: 32), width: 1_920, height: 1_080,
            chromaFormat: 1, bitDepth: 8, level: 40, compatibilityFlags: 0, tier: .main,
            frameRate: MediaRational(num: 30, den: 1), videoRange: .sdr,
            colorPrimaries: .bt709, colorTransfer: .bt709, colorMatrix: .bt709)
        let audio = HLSSourceAudioFacts(codec: .aac, profile: 1, sampleRate: 44_100, channelCount: 2,
            channelMask: 3, decoderConfiguration: Data([0x12, 0x10]), priming: .notSignaledPreserveTimestamps,
            service: .independentMain, formatValidated: true)
        return (source, .init(source: source, media: [.init(url: source.responseURL, container: container,
            video: video, audio: [audio], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 188))
    }

    private func evidence(model: String = "AppleTV11,1", hdr: Bool = true, playable: Bool = true) -> NativeHLSPlatformEvidence {
        .init(model: model, hardwareH264: true, hardwareHEVC: true, hdrEligible: hdr, playable: { _ in playable })
    }
    private func route(_ ports: PlaybackRoutePorts) -> PlaybackRouteSemanticIdentity {
        .init(ports: ports, backend: .hlsAVPlayer, outputConfigurationIncarnation: .init(rawValue: 1), endpointTopologyToken: .init(rawValue: 1))
    }
    private func facts(codec: VPlayerPlayback.AudioCodec, profile: Int32? = nil, sampleRate: Int32 = 48_000, mask: UInt64? = nil,
                       video: HLSVideoFacts? = nil) throws -> HLSCompatibilityFacts {
        let context = try sourceContext()
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data()))
        let audio = HLSSourceAudioFacts(codec: codec, profile: profile ?? (codec == .aac ? 1 : codec == .ac3 ? 8 : 16),
            sampleRate: sampleRate, channelCount: codec == .aac ? 2 : 6, channelMask: mask ?? (codec == .aac ? 3 : 0x3F),
            decoderConfiguration: codec == .aac ? Data([0x11, 0x90]) : Data(),
            priming: .notSignaledPreserveTimestamps, service: .independentMain, formatValidated: true)
        return .init(source: source, media: [.init(url: source.responseURL, container: .fragmentedMP4,
            video: video, audio: [audio], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 188)
    }
    private func video(range: HLSVideoRange?, rate: Int32?) -> HLSVideoFacts {
        .init(codec: .hevc, profile: 2, scan: .progressive, parameterSetsValidated: true,
            configurationFingerprint: Data([1]), width: 3_840, height: 2_160, chromaFormat: 1, bitDepth: 10, level: 153,
            parserProgressiveFrames: 2, compatibilityFlags: 0x20000000, constraintIndicatorFlags: 0xB00000000000,
            tier: .main, frameRate: rate.flatMap { MediaRational(num: $0, den: 1) }, videoRange: range,
            colorPrimaries: range == nil ? nil : .bt2020, colorTransfer: range == nil ? nil : .hlg,
            colorMatrix: range == nil ? nil : .bt2020Nonconstant, sampleEntry: "hvc1")
    }
}

@MainActor
extension NativeHLSCapabilitiesTests {
    func testNativeAACMatchesCompleteLCConfigurationsWithAbsentSBRExtension() throws {
        for (rate, base): (Int32, [UInt8]) in [(44_100, [0x12, 0x10]), (48_000, [0x11, 0x90])] {
            let configurations = [Data(base), Data(base + [0x56, 0xE5, 0])]
            var digest: Data?
            for sourceConfiguration in configurations {
                let sourceAudio = nativeAACSource(configuration: sourceConfiguration, rate: rate)
                let (_, expected) = try nativeAACExpected(sourceAudio)
                for selectedConfiguration in configurations {
                    let parsed = try AudioSpecificConfig.parse(selectedConfiguration)
                    XCTAssertEqual(parsed.kind, .aacLC)
                    XCTAssertEqual(parsed.outputSampleRate, rate)
                    for cookie in [selectedConfiguration, parsed.coreAudioMagicCookie] {
                        let format = try nativeAACFormat(cookie: cookie, rate: rate)
                        let selected = try SystemNativeHLSAssetInspector.audioFacts(format, expected: expected)
                        XCTAssertEqual(selected.0, sourceAudio, "The original source configuration must stay byte-for-byte intact")
                        if let digest { XCTAssertEqual(selected.1, digest) }
                        else { digest = selected.1 }
                    }
                }
            }
        }
    }

    func testNativeAACIdentityRejectsHEAndIncompleteOrUnsupportedLCConfigurations() throws {
        let rejectedBytes: [[UInt8]] = [
            [0x2B, 0x11, 0x88, 0], [0xEB, 0x09, 0x88, 0], // explicit HE-AAC v1/v2
            [0x0B, 0x90], [0x11, 0x80], [0x16, 0x90], // object type, PCE, reserved rate
            [0x11, 0x94], [0x11, 0x92], [0x11, 0x91], // frame length, core coder, extension
            [0x11, 0x90, 0x56], [0x11, 0x90, 0x56, 0xE5],
            [0x11, 0x90, 0x56, 0xE5, 0x80], [0x11, 0x90, 0x56, 0xE5, 1],
            [0x11, 0x90, 0], [0x11, 0x90, 0x56, 0xE5, 0, 0]
        ]
        for bytes in rejectedBytes {
            XCTAssertThrowsError(try NativeAACDecoderConfiguration.LCIdentity(configuration: Data(bytes)))
        }
        let ordinary = try NativeAACDecoderConfiguration.LCIdentity(configuration: Data([0x11, 0x90]))
        let extended = try NativeAACDecoderConfiguration.LCIdentity(configuration: Data([0x11, 0x90, 0x56, 0xE5, 0]))
        XCTAssertEqual(ordinary, extended)
        XCTAssertEqual(ordinary.canonicalBytes, extended.canonicalBytes)
        for distinct in [Data([0x12, 0x10]), Data([0x11, 0x88]), Data([0x17, 0x80, 0x5D, 0xC0, 0x10])] {
            let other = try NativeAACDecoderConfiguration.LCIdentity(configuration: distinct)
            XCTAssertNotEqual(ordinary, other, "Different rate, layout, or unproven frequency representation must stay distinct")
            XCTAssertNotEqual(ordinary.canonicalBytes, other.canonicalBytes)
        }
    }

    func testNativeAACIdentityHandlesSlicedValidatedLCConfigurations() throws {
        let ordinary = Data([0x11, 0x90])
        let identity = try NativeAACDecoderConfiguration.LCIdentity(configuration: ordinary)
        let format = try nativeAACFormat(cookie: ordinary)
        for configuration in [ordinary, ordinary + Data([0x56, 0xE5, 0])] {
            let prefixed = Data([0xAA, 0xBB]) + configuration
            let sliced = prefixed.dropFirst(2)
            XCTAssertEqual(sliced.startIndex, 2)
            XCTAssertEqual(try AudioSpecificConfig.parse(sliced).kind, .aacLC)
            XCTAssertEqual(try NativeAACDecoderConfiguration.LCIdentity(configuration: sliced), identity)
            let source = nativeAACSource(configuration: sliced)
            let (_, expected) = try nativeAACExpected(source)
            XCTAssertEqual(try SystemNativeHLSAssetInspector.audioFacts(format, expected: expected).0, source)
        }
    }

    func testNativeAACEquivalenceKeepsSourceFormatRateAndExactLayoutGuards() throws {
        let format = try nativeAACFormat(cookie: Data([0x11, 0x90, 0x56, 0xE5, 0]))
        for source in [
            nativeAACSource(profile: 4), nativeAACSource(validated: false), nativeAACSource(service: .unknown),
            nativeAACSource(rate: 44_100), nativeAACSource(channels: 1), nativeAACSource(mask: 0xC),
            nativeAACSource(configuration: Data([0x12, 0x10])),
            nativeAACSource(configuration: Data([0x11, 0x90, 0x56, 0xE5, 0x80])),
            nativeAACSource(configuration: Data([0x17, 0x80, 0x5D, 0xC0, 0x10]))
        ] {
            let (_, expected) = try nativeAACExpected(source)
            XCTAssertThrowsError(try SystemNativeHLSAssetInspector.audioFacts(format, expected: expected))
        }
        let (_, expected) = try nativeAACExpected(nativeAACSource())
        let wrongRate = try nativeAACFormat(cookie: Data([0x12, 0x10]), rate: 44_100)
        let wrongLayout = try nativeAACFormat(cookie: Data([0x11, 0x90]), mask: 0xC)
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.audioFacts(wrongRate, expected: expected))
        XCTAssertThrowsError(try SystemNativeHLSAssetInspector.audioFacts(wrongLayout, expected: expected))
        for formatID in [kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2] {
            let he = try nativeAACFormat(cookie: Data([0x11, 0x90]), formatID: formatID)
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(he)?.pointee.mFormatID, formatID)
            XCTAssertThrowsError(try SystemNativeHLSAssetInspector.audioFacts(he, expected: expected),
                "A selected HE decoder must never borrow the LC comparison identity")
        }
    }

    func testNativeAACEquivalenceKeepsExplicitSDKFrameLengthContradictions() throws {
        let (_, expected) = try nativeAACExpected(nativeAACSource())
        for frames in [UInt32(0), 1_024, 960, 2_048] {
            let format = try nativeAACFormat(cookie: Data([0x11, 0x90, 0x56, 0xE5, 0]), framesPerPacket: frames)
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mFramesPerPacket, frames)
            if frames == 0 || frames == 1_024 {
                XCTAssertNoThrow(try SystemNativeHLSAssetInspector.audioFacts(format, expected: expected))
            } else {
                XCTAssertThrowsError(try SystemNativeHLSAssetInspector.audioFacts(format, expected: expected))
            }
        }
    }

    func testNativeAACEquivalentSelectionDigestPreservesTransitionIdentityGuards() throws {
        let (source, facts) = try nativeAACExpected(nativeAACSource())
        let sourceOwner = try XCTUnwrap(source.context.owner)
        let plan = HLSPlaybackPlan(owner: sourceOwner, resolutionGeneration: source.generation, transport: .native,
            video: .source, audio: .source, selectedServiceURL: nil, formatFingerprint: facts.formatFingerprint)
        let owned = try HLSOwnedSourcePlan(source: source, facts: facts, plan: plan, resolver: URLSessionPlaybackSourceResolver(),
            sourceCharge: HLSApplicationLifetimeCharge(bytes: 1_024), factsCharge: HLSApplicationLifetimeCharge(bytes: 1_024))
        let physical = NSObject(), selection = NSObject(), replacement = NSObject()
        let item = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: .init(backendIdentity: sourceOwner.backendIdentity,
            outputNonce: sourceOwner.outputLifecycleNonce), itemGeneration: 1)
        let first = try SystemNativeHLSAssetInspector.audioFacts(nativeAACFormat(cookie: Data([0x11, 0x90])), expected: facts)
        let next = try SystemNativeHLSAssetInspector.audioFacts(nativeAACFormat(cookie: Data([0x11, 0x90, 0x56, 0xE5, 0])), expected: facts)
        func snapshot(_ digest: Data, identity: AVPlayerItemInstanceIdentity, physicalID: ObjectIdentifier) throws -> NativeHLSSelectionSnapshot {
            try .init(item: identity, physicalItem: physicalID, audioSelection: ObjectIdentifier(selection), video: nil,
                audio: first.0, audioConfigurationDigest: digest, observedFrameRate: nil, sourceOwner: owned,
                retention: HLSApplicationLifetimeCharge(bytes: 8 * 1_024))
        }
        let prior = try snapshot(first.1, identity: item, physicalID: ObjectIdentifier(physical))
        XCTAssertTrue(try snapshot(next.1, identity: item, physicalID: ObjectIdentifier(physical)).permitsTransition(from: prior))
        for configuration in [Data([0x12, 0x10]), Data([0x11, 0x88]), Data([0x17, 0x80, 0x5D, 0xC0, 0x10])] {
            let identity = try NativeAACDecoderConfiguration.LCIdentity(configuration: configuration)
            let digest = Data(SHA256.hash(data: identity.canonicalBytes))
            XCTAssertFalse(try snapshot(digest, identity: item, physicalID: ObjectIdentifier(physical)).permitsTransition(from: prior))
        }
        let differentItem = AVPlayerItemInstanceIdentity(outputLifecycleEpoch: item.outputLifecycleEpoch, itemGeneration: 2)
        XCTAssertFalse(try snapshot(next.1, identity: differentItem, physicalID: ObjectIdentifier(physical)).permitsTransition(from: prior))
        XCTAssertFalse(try snapshot(next.1, identity: item, physicalID: ObjectIdentifier(replacement)).permitsTransition(from: prior))
    }

    private func nativeAACSource(configuration: Data = Data([0x11, 0x90]), profile: Int32 = 1, rate: Int32 = 48_000,
        channels: Int32 = 2, mask: UInt64 = 3, service: HLSSourceAudioService = .independentMain,
        validated: Bool = true) -> HLSSourceAudioFacts {
        .init(codec: .aac, profile: profile, sampleRate: rate, channelCount: channels, channelMask: mask,
            decoderConfiguration: configuration, priming: .notSignaledPreserveTimestamps, service: service, formatValidated: validated)
    }

    private func nativeAACExpected(_ audio: HLSSourceAudioFacts) throws -> (ResolvedPlaybackSource, HLSCompatibilityFacts) {
        let context = try sourceContext()
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL, generation: 1, topology: .media(Data()))
        return (source, .init(source: source, media: [.init(url: source.responseURL, container: .mpegTS,
            video: nil, audio: [audio], hasUnsupportedTracks: false)], complete: true, inspectedBytes: 188))
    }

    private func nativeAACFormat(cookie: Data, rate: Int32 = 48_000, mask: UInt32 = 3,
        framesPerPacket: UInt32 = 1_024, formatID: AudioFormatID = kAudioFormatMPEG4AAC) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: formatID,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var layout = AudioToolbox.AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: mask)
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: MemoryLayout<AudioToolbox.AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: cookie.count, magicCookie: bytes.baseAddress, extensions: nil, formatDescriptionOut: &format)
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }
}
