// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class NativeHLSCapabilitiesTests: XCTestCase {
    func testExactOwnedNativeDolbyCandidatesRemainIndependentOfGeneratedWriterProof() throws {
        for codec in [AudioCodec.ac3, .eac3] {
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
        for codec in [AudioCodec.ac3, .eac3] {
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
    private func evidence(model: String = "AppleTV11,1", hdr: Bool = true, playable: Bool = true) -> NativeHLSPlatformEvidence {
        .init(model: model, hardwareH264: true, hardwareHEVC: true, hdrEligible: hdr, playable: { _ in playable })
    }
    private func route(_ ports: PlaybackRoutePorts) -> PlaybackRouteSemanticIdentity {
        .init(ports: ports, backend: .hlsAVPlayer, outputConfigurationIncarnation: .init(rawValue: 1), endpointTopologyToken: .init(rawValue: 1))
    }
    private func facts(codec: AudioCodec, profile: Int32? = nil, sampleRate: Int32 = 48_000, mask: UInt64? = nil,
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
