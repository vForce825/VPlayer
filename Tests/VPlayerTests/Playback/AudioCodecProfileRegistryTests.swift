// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AudioToolbox
import CoreMedia
import Foundation
import XCTest
@testable import VPlayerPlayback

final class AudioCodecProfileRegistryTests: XCTestCase {
    func testDecodeBreakReasonIsFixedPublicUInt8Domain() {
        let reasons: [AudioDecodeBreakReason] = [
            .corruptPacket, .framingReset, .invalidFrame,
        ]
        XCTAssertEqual(reasons.map(\.rawValue), [0, 1, 2])
        XCTAssertNil(AudioDecodeBreakReason(rawValue: 3))
    }

    func testRegistryContainsExactlyApprovedAdapterBackedCodecs() throws {
        XCTAssertEqual(
            AudioCodecProfileRegistry.approvedCodecs,
            [VPlayerPlayback.AudioCodec.aac, .mp1, .mp2, .mp3, .ac3, .eac3]
        )

        for codec in AudioCodecProfileRegistry.approvedCodecs {
            let source = makeSource(
                codec: codec,
                extradata: codec == .aac ? Data([0x11, 0x90]) : Data()
            )
            XCTAssertEqual(
                try AudioCodecProfileRegistry.profile(for: source).codec,
                codec
            )
        }
    }

    func testAACCodecSelectsLCHEv1AndHEv2FromExplicitASC() throws {
        let cases: [(Data, AudioCodecProfileID, AudioFormatID, Int32)] = [
            (Data([0x11, 0x90]), .aacLC, kAudioFormatMPEG4AAC, 1_024),
            (Data([0x2B, 0x11, 0x88, 0x00]), .heAACv1, kAudioFormatMPEG4AAC_HE, 2_048),
            (Data([0xEB, 0x09, 0x88, 0x00]), .heAACv2, kAudioFormatMPEG4AAC_HE_V2, 2_048),
        ]

        for (asc, profileID, formatID, sampleCount) in cases {
            let source = makeSource(codec: .aac, extradata: asc)
            let inspected = try AudioCodecProfileRegistry.profile(for: source).inspect(
                FramedCompressedAudioFrame(
                    payload: Data([0x21, 0x22]),
                    presentationTimeStamp: .zero,
                    parserSampleCount: nil,
                    parserSampleRate: nil,
                    parserChannelLayout: nil,
                    containerMarkedCorrupt: false
                ),
                source: source
            )

            XCTAssertEqual(inspected.systemFormat.profileID, profileID)
            XCTAssertEqual(inspected.systemFormat.formatID, formatID)
            XCTAssertEqual(inspected.sampleCount, sampleCount)
            XCTAssertEqual(inspected.systemFormat.magicCookie, coreAudioCookie(for: asc))
        }
    }

    func testUnsupportedFramingFailsWithoutEnteringRenderer() throws {
        let tracks = try AssemblerTestFixtures.audioTracks(
            extradata: Data([0x11, 0x90])
        )
        var events: [AudioAssemblerEvent] = []
        let subject = try CompressedAudioAssembler(
            trackSet: tracks,
            generationProvider: { MediaGeneration(rawValue: 1) },
            eventSink: { events.append($0) },
            formatState: AssemblyFormatState(trackSet: tracks)
        )

        try subject.push(AssemblerTestFixtures.audioPacket(
            data: Data([0x56, 0xE0, 0x00]),
            codec: .aac
        ))

        XCTAssertEqual(events.compactMap(\.decodeBreakReason), [.invalidFrame])
        XCTAssertTrue(events.compactMap(\.frame).isEmpty)
        XCTAssertTrue(events.compactMap(\.configuration).isEmpty)
    }

    private func makeSource(
        codec: VPlayerPlayback.AudioCodec,
        extradata: Data
    ) -> AudioTrackDescriptor {
        AudioTrackDescriptor(
            streamIndex: 1,
            codec: codec,
            timeBase: MediaRational(num: 1, den: 90_000)!,
            sampleRate: 48_000,
            channelLayout: AudioChannelLayout(channelCount: 2, nativeMask: 3),
            extradata: extradata
        )
    }

    private func coreAudioCookie(for asc: Data) -> Data {
        Data([
            0x03, UInt8(23 + asc.count), 0x00, 0x00, 0x00,
            0x04, UInt8(15 + asc.count), 0x40, 0x15,
            0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x05, UInt8(asc.count),
        ]) + asc + Data([0x06, 0x01, 0x02])
    }
}

private extension AudioAssemblerEvent {
    var configuration: CompressedAudioRenderConfiguration? {
        guard case let .format(value) = self else { return nil }
        return value
    }

    var frame: CompressedAudioFrame? {
        guard case let .frame(value) = self else { return nil }
        return value
    }

    var decodeBreakReason: AudioDecodeBreakReason? {
        guard case let .decodeBreak(reason) = self else { return nil }
        return reason
    }
}
