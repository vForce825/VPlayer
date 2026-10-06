// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class CompressedAudioRouteTests: XCTestCase {
    func testSourceLCDecisionIsIndependentOfVideoProcessing() {
        for hasVideo in [false, true] {
            for priming: HLSSourceAudioPriming in [.notSignaledPreserveTimestamps,
                .explicit(leadingSamples: 0, trailingSamples: 0)] {
                let facts = Self.aac(priming: priming)
                XCTAssertEqual(HLSAudioProcessingPolicy.select(source: facts,
                    capabilities: .init(compressedAudioCodecs: [.aac]), hasVideo: hasVideo), .passthrough(.aac))
            }
        }
    }
    func testUnknownOrNonzeroSourceTrimCannotUseOutputEncoderCalibration() {
        for priming: HLSSourceAudioPriming in [.unknown, .explicit(leadingSamples: 1, trailingSamples: 0),
            .explicit(leadingSamples: 0, trailingSamples: 1)] {
            XCTAssertEqual(HLSAudioProcessingPolicy.select(source: Self.aac(priming: priming),
                capabilities: .init(compressedAudioCodecs: [.aac]), hasVideo: true), .compatibleAAC)
        }
    }
    func testMissingAACCapabilityConfigurationAndLayoutChooseCompatibility() {
        XCTAssertEqual(HLSAudioProcessingPolicy.select(source: Self.aac(), capabilities: .init(),
            hasVideo: false), .compatibleAAC)
        for facts in [Self.aac(config: Data()), Self.aac(config: Data([0x2B, 0x11, 0x88, 0x00])),
                      Self.aac(mask: 0), Self.aac(mask: 4), Self.aac(validated: false)] {
            XCTAssertEqual(HLSAudioProcessingPolicy.select(source: facts,
                capabilities: .init(compressedAudioCodecs: [.aac]), hasVideo: false), .compatibleAAC)
        }
    }
    func testDolbyCodecSetAloneIsNeverConfigurationAdmission() {
        for codec: AudioCodec in [.ac3, .eac3] {
            let facts = Self.dolby(codec)
            XCTAssertEqual(HLSAudioProcessingPolicy.select(source: facts,
                capabilities: .init(compressedAudioCodecs: [codec]), hasVideo: true), .compatibleAAC)
            let candidate = HLSCompressedAudioAdmissionCandidate(codec: codec, profile: facts.profile,
                sampleRate: 48_000, channelCount: 6, channelMask: 0x60F,
                decoderConfiguration: Data(), outputRouteIdentifier: "test-original-route",
                requiresAACCompatibilityRendition: false)
            let capabilities = HLSOutputCapabilities(compressedAudioCodecs: [codec],
                compressedAudioAdmissionCandidates: [candidate])
            XCTAssertEqual(HLSAudioProcessingPolicy.select(source: facts,
                capabilities: capabilities, hasVideo: true), .passthrough(codec))
            XCTAssertTrue(capabilities.verifiedCompressedAudioConfigurations.isEmpty,
                "A route candidate still requires real first-writer and emitted-init proof")
        }
    }
    func testRequiredMissingAACSiblingDoesNotHideLaterEligibleConfiguration() {
        let facts = Self.dolby(.ac3)
        func configuration(required: Bool) -> HLSVerifiedCompressedAudioConfiguration {
            .init(codec: .ac3, profile: 8, sampleRate: 48_000, channelCount: 6,
                channelMask: 0x60F, decoderConfiguration: Data(), outputRouteIdentifier: "test-route",
                requiresAACCompatibilityRendition: required)
        }
        XCTAssertEqual(HLSAudioProcessingPolicy.select(source: facts, capabilities:
            .init(compressedAudioCodecs: [.ac3], verifiedCompressedAudioConfigurations: [configuration(required: true)]),
            hasVideo: true), .compatibleAAC)
        XCTAssertEqual(HLSAudioProcessingPolicy.select(source: facts, capabilities:
            .init(compressedAudioCodecs: [.ac3], verifiedCompressedAudioConfigurations:
                [configuration(required: true), configuration(required: false)]),
            hasVideo: true), .passthrough(.ac3))
    }
    private static func aac(priming: HLSSourceAudioPriming = .notSignaledPreserveTimestamps,
                            config: Data = Data([0x11, 0x90]), mask: UInt64 = 3,
                            validated: Bool = true) -> HLSSourceAudioFacts {
        .init(codec: .aac, profile: 1, sampleRate: 48_000, channelCount: 2, channelMask: mask,
            decoderConfiguration: config, priming: priming, service: .independentMain,
            formatValidated: validated)
    }
    private static func dolby(_ codec: AudioCodec) -> HLSSourceAudioFacts {
        .init(codec: codec, profile: codec == .ac3 ? 8 : 16, sampleRate: 48_000,
            channelCount: 6, channelMask: 0x60F, priming: .notSignaledPreserveTimestamps,
            service: .independentMain, formatValidated: true)
    }
}
