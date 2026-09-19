// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import XCTest
@testable import VPlayerPlayback

final class PlaybackBackendSelectionTests: XCTestCase {
    func testAirPlayTakesPriorityOverEveryOtherPortForLongFormAudio() throws {
        for companion in allNonAirPlayCombinations {
            XCTAssertEqual(
                try PlaybackBackendSelection.select(
                    ports: companion.union(.airPlay),
                    actualPolicy: .longFormAudio
                ),
                .hlsAVPlayer
            )
        }
    }

    func testAirPlayWithDefaultPolicyThrowsTypedErrorForEveryMixedRoute() {
        for companion in allNonAirPlayCombinations {
            XCTAssertThrowsError(try PlaybackBackendSelection.select(
                ports: companion.union(.airPlay),
                actualPolicy: .default
            )) { error in
                XCTAssertEqual(
                    error as? PlaybackBackendSelectionError,
                    .airPlayLongFormUnavailable
                )
            }
        }
    }

    func testEveryNonAirPlayPortCombinationUsesSampleBufferForEitherPolicy() throws {
        let nonEmptyCombinations: [PlaybackRoutePorts] = [
            .hdmi, .bluetooth, .builtIn, .other,
            [.hdmi, .bluetooth], [.hdmi, .builtIn], [.hdmi, .other],
            [.bluetooth, .builtIn], [.bluetooth, .other], [.builtIn, .other],
            [.hdmi, .bluetooth, .builtIn], [.hdmi, .bluetooth, .other],
            [.hdmi, .builtIn, .other], [.bluetooth, .builtIn, .other],
            [.hdmi, .bluetooth, .builtIn, .other],
        ]

        for ports in nonEmptyCombinations {
            XCTAssertEqual(
                try PlaybackBackendSelection.select(ports: ports, actualPolicy: .longFormAudio),
                .sampleBuffer
            )
            XCTAssertEqual(
                try PlaybackBackendSelection.select(ports: ports, actualPolicy: .default),
                .sampleBuffer
            )
        }
    }

    func testEmptyRouteDoesNotSelectBackendForEitherPolicy() throws {
        XCTAssertNil(try PlaybackBackendSelection.select(ports: [], actualPolicy: .longFormAudio))
        XCTAssertNil(try PlaybackBackendSelection.select(ports: [], actualPolicy: .default))
    }

    func testOptionSetNormalizesOrderingAndDuplicates() {
        let ordered: PlaybackRoutePorts = [.hdmi, .airPlay, .bluetooth]
        let reordered: PlaybackRoutePorts = [.bluetooth, .hdmi, .airPlay, .hdmi]

        XCTAssertEqual(ordered, reordered)
    }

    func testSemanticIdentityIncludesOnlyPortsBackendAndOpaqueIncarnations() {
        let baseline = PlaybackRouteSemanticIdentity(
            ports: [.hdmi, .airPlay],
            backend: .hlsAVPlayer,
            outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 7),
            endpointTopologyToken: EndpointTopologyToken(rawValue: 11)
        )

        XCTAssertEqual(baseline, PlaybackRouteSemanticIdentity(
            ports: [.airPlay, .hdmi],
            backend: .hlsAVPlayer,
            outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 7),
            endpointTopologyToken: EndpointTopologyToken(rawValue: 11)
        ))
        XCTAssertNotEqual(baseline, PlaybackRouteSemanticIdentity(
            ports: [.airPlay],
            backend: .hlsAVPlayer,
            outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 7),
            endpointTopologyToken: EndpointTopologyToken(rawValue: 11)
        ))
        XCTAssertNotEqual(baseline, PlaybackRouteSemanticIdentity(
            ports: [.hdmi, .airPlay],
            backend: .sampleBuffer,
            outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 7),
            endpointTopologyToken: EndpointTopologyToken(rawValue: 11)
        ))
        XCTAssertNotEqual(baseline, PlaybackRouteSemanticIdentity(
            ports: [.hdmi, .airPlay],
            backend: .hlsAVPlayer,
            outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 8),
            endpointTopologyToken: EndpointTopologyToken(rawValue: 11)
        ))
        XCTAssertNotEqual(baseline, PlaybackRouteSemanticIdentity(
            ports: [.hdmi, .airPlay],
            backend: .hlsAVPlayer,
            outputConfigurationIncarnation: OutputConfigurationIncarnation(rawValue: 7),
            endpointTopologyToken: EndpointTopologyToken(rawValue: 12)
        ))
    }

    func testEndpointTopologyTokenDoesNotExposeItsValueThroughDiagnosticsOrMirror() {
        let token = EndpointTopologyToken(rawValue: 8_675_309)

        XCTAssertEqual(String(describing: token), "<redacted>")
        XCTAssertEqual(String(reflecting: token), "<redacted>")
        XCTAssertTrue(Array(Mirror(reflecting: token).children).isEmpty)
    }
}

private let allNonAirPlayCombinations: [PlaybackRoutePorts] = [
    [],
    .hdmi,
    .bluetooth,
    .builtIn,
    .other,
    [.hdmi, .bluetooth],
    [.hdmi, .builtIn],
    [.hdmi, .other],
    [.bluetooth, .builtIn],
    [.bluetooth, .other],
    [.builtIn, .other],
    [.hdmi, .bluetooth, .builtIn],
    [.hdmi, .bluetooth, .other],
    [.hdmi, .builtIn, .other],
    [.bluetooth, .builtIn, .other],
    [.hdmi, .bluetooth, .builtIn, .other],
]
